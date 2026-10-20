//! rsc_driver::emit.
use crate::place::{place_name, place_proj, place_via};
use crate::tyinfo::{aggregate_layout, fn_operand_sig, operand_ty_short, str_const_bytes, ty_sa_sig_opt};
use crate::util::{bb_name, esc, local_name, sanitize, trunc};
use rustc_ast::ast::InlineAsmTemplatePiece;
use rustc_hir::def::DefKind;
use rustc_middle::mir::{Body, BorrowKind, Const, ConstOperand, InlineAsmOperand, Local, Operand, Rvalue, StatementKind, TerminatorKind};
use rustc_middle::ty::{ConstKind, PseudoCanonicalInput, Ty, TyCtxt, TyKind};
use rustc_middle::ty;
use std::fmt::Write as _;

/// Emit a projected operand: base local in `place` (for every other pass) plus
/// `proj { offset, ty, via }` so lowering can `load base+off as ty` instead of
/// reusing the base aggregate. Plain locals keep the exact old JSON shape.
fn write_proj_operand<'a>(
    kind: &str,
    s: &str,
    tcx: TyCtxt<'a>,
    body: &Body<'a>,
    p: &rustc_middle::mir::Place<'a>,
    into: &mut String,
) {
    match place_proj(tcx, body, p) {
        Some(pi) => {
            into.push_str("{\"kind\": \"");
            into.push_str(kind);
            into.push_str("\", \"place\": \"");
            esc(s, into);
            write!(
                into,
                "\", \"proj\": {{\"offset\": {}, \"ty\": \"",
                pi.offset
            )
            .unwrap();
            esc(&pi.ty, into);
            into.push_str("\", \"via\": \"");
            esc(&pi.via, into);
            into.push('"');
            if pi.deref_base {
                into.push_str(", \"deref_base\": true");
            }
            if let Some((idx, size)) = crate::place::place_dynamic_index(tcx, body, p) {
                write!(into, ", \"index\": [\"{}\", {}]", idx, size).unwrap();
            }
            into.push_str("}}");
        }
        None => {
            into.push_str("{\"kind\": \"");
            into.push_str(kind);
            into.push_str("\", \"place\": \"");
            esc(s, into);
            into.push_str("\"}");
        }
    }
}

pub fn operand_json<'a>(op: &Operand<'a>, tcx: TyCtxt<'a>, body: &Body<'a>, into: &mut String) {
    match op {
        Operand::Copy(p) => {
            let (s, _) = place_name(p);
            write_proj_operand("Copy", &s, tcx, body, p, into);
        }
        Operand::Move(p) => {
            let (s, _) = place_name(p);
            write_proj_operand("Move", &s, tcx, body, p, into);
        }
        Operand::Constant(c) => {
            // A constant aggregate (`&Enum::Variant(..)`) is emitted as its
            // own construction so the backend can materialize it.
            if let Some(agg) = const_agg_json(tcx, c, into) {
                let _ = agg;
                return;
            }
            let v = const_value_text(c);
            into.push_str("{\"kind\": \"Const\", \"value\": \"");
            esc(&v, into);
            into.push('"');
            // String-literal payload rides along only when resolvable;
            // absent fields keep old fixtures byte-compatible.
            if let Some((bytes, len)) = str_const_bytes(tcx, &c.const_) {
                into.push_str(", \"str_bytes\": [");
                for (i, b) in bytes.iter().enumerate() {
                    if i > 0 {
                        into.push_str(", ");
                    }
                    write!(into, "{}", b).unwrap();
                }
                write!(into, "], \"str_len\": {}", len).unwrap();
            }
            into.push('}');
        }
        Operand::RuntimeChecks(_) => {
            // Session-flag query operand (e.g. overflow-checks enabled?).
            // No SA const can name it: loud marker const, counted as APPROX.
            into.push_str("{\"kind\": \"Const\", \"value\": \"0 /*RuntimeChecks-unsupported*/\"}");
        }
    }
}

/// An unsizing coercion `&[T; N]` -> `&[T]`: the fat pointer's size, the
/// offset of its length word and the source length.
fn unsize_info<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    op: &Operand<'tcx>,
    target: Ty<'tcx>,
) -> Option<(u64, u64, u64)> {
    use rustc_middle::ty::TypingEnv;
    let src_ty = match op {
        Operand::Copy(p) | Operand::Move(p) => p.ty(&body.local_decls, tcx).ty,
        _ => return None,
    };
    let (elem_ty, len) = match src_ty.kind() {
        TyKind::Ref(_, t, _) => match t.kind() {
            TyKind::Array(e, l) => (*e, l),
            _ => return None,
        },
        _ => return None,
    };
    let n = len.try_to_target_usize(tcx)?;
    // The target's layout: a slice is a (data pointer, length) pair.
    let env = TypingEnv::fully_monomorphized();
    let layout = tcx
        .layout_of(PseudoCanonicalInput {
            typing_env: env,
            value: target,
        })
        .ok()?;
    let len_off = layout.fields.offset(1).bytes();
    let _ = elem_ty;
    Some((layout.size.bytes(), len_off, n as u64))
}

/// SA types of an aggregate's elements (the ADT variant's field types).
fn agg_elem_tys<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    place: &rustc_middle::mir::Place<'tcx>,
    kind: &rustc_middle::mir::AggregateKind<'tcx>,
    n: usize,
) -> Option<Vec<String>> {
    use rustc_middle::mir::AggregateKind;
    use rustc_middle::ty::TypingEnv;
    let (def, vi, args) = match kind {
        AggregateKind::Adt(def, vi, args, ..) => (*def, *vi, args),
        _ => return None,
    };
    let env = TypingEnv::fully_monomorphized();
    let variant = tcx.adt_def(def).variant(vi);
    if variant.fields.len() != n {
        return None;
    }
    let mut out = Vec::with_capacity(n);
    for f in variant.fields.iter() {
        let fty = tcx.normalize_erasing_regions(env, f.ty(tcx, args));
        out.push(crate::tyinfo::ty_sa_sig_opt(fty)?);
    }
    let _ = place;
    Some(out)
}

/// A constant as the backend's `Val(Scalar(..), ty)` text. A typed const
/// (`Ty(usize, 3_usize)`) carries its value separately; the Debug text of the
/// const alone is not a value the backend can use.
fn const_value_text(c: &ConstOperand<'_>) -> String {
    use rustc_middle::ty::ConstKind;
    if let rustc_middle::mir::Const::Ty(ty, ct) = &c.const_ {
        if let ConstKind::Value(val) = ct.kind() {
            if let Some(s) = val.try_to_scalar() {
                // The backend parses `Val(Scalar(0x..), ty)`.
                if let rustc_middle::mir::interpret::Scalar::Int(i) = s {
                    return format!("Val(Scalar(0x{:016x}), {})", i, ty);
                }
                return format!("Val({}, {})", s, ty);
            }
        }
    }
    trunc(format!("{:?}", c.const_), 60)
}

/// Emit a constant aggregate's construction (the const's own MIR), so the
/// backend materializes it like an inline aggregate. Returns None when the
/// const is not an aggregate the driver can describe.
fn const_agg_json<'tcx>(tcx: TyCtxt<'tcx>, c: &ConstOperand<'tcx>, into: &mut String) -> Option<()> {
    use rustc_hir::def::DefKind;
    let rustc_middle::mir::Const::Unevaluated(uv, _) = &c.const_ else {
        return None;
    };
    // A promoted const (`&Enum::Variant(..)`) still has an inspectable
    // body: the anonymous const's MIR holds the promotion.
    // A promoted const (`&Enum::Variant(..)`) lives in the enclosing
    // function's promoted bodies; a plain const has its own MIR.
    let ctfe: &Body = if uv.promoted.is_some() {
        let promoted = tcx.promoted_mir(uv.def);
        match promoted.raw.first() {
            Some(b) => b,
            None => return None,
        }
    } else {
        if !matches!(
            tcx.def_kind(uv.def),
            DefKind::Const | DefKind::AssocConst | DefKind::AnonConst | DefKind::Ctor(..)
        ) {
            return None;
        }
        tcx.mir_for_ctfe(uv.def)
    };
    // The const's body assigns its value to `_0`.
    let mut agg: Option<(&rustc_middle::mir::Place<'tcx>, &Rvalue<'tcx>)> = None;
    'outer: for b in ctfe.basic_blocks.iter() {
        for st in b.statements.iter() {
            if let rustc_middle::mir::StatementKind::Assign(assign) = &st.kind {
                let (p, rvalue) = &**assign;
                if matches!(rvalue, Rvalue::Aggregate(..)) {
                    agg = Some((p, rvalue));
                    break 'outer;
                }
            }
        }
    }
    let (place, rv) = agg?;
    let layout = match rv {
        Rvalue::Aggregate(kind, ops) => {
            aggregate_layout(tcx, tcx.param_env(uv.def), &ctfe, kind, &place, ops.len())
        }
        _ => None,
    };
    let mut buf = String::new();
    rvalue_json(rv, tcx, &ctfe, &place, layout.as_ref(), None, &mut buf);
    let relabeled = buf.replace("\"kind\": \"Aggregate\"", "\"kind\": \"ConstAgg\"");
    into.push_str(&relabeled);
    Some(())
}

/// Short scalar name for a cast operand's type (int/uint/float/bool/char,

pub fn rvalue_json<'tcx>(
    rv: &Rvalue<'tcx>,
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    place: &rustc_middle::mir::Place<'tcx>,
    layout: Option<&(u64, Vec<u64>)>,
    niche_store: Option<(u64, u64, String)>,
    into: &mut String,
) {
    match rv {
        Rvalue::Use(op, _) => {
            into.push_str("{\"kind\": \"Use\", \"op\": ");
            operand_json(op, tcx, body, into);
            into.push('}');
        }
        Rvalue::Ref(_, kind, p) => {
            let (s, _) = place_name(p);
            let m = matches!(kind, BorrowKind::Mut { .. });
            write!(into, "{{\"kind\": \"Ref\", \"place\": \"{}\"", s).unwrap();
            if m {
                into.push_str(", \"mut\": true");
            }
            if let Some(via) = place_via(p) {
                into.push_str(", \"via\": \"");
                esc(&via, into);
                into.push('"');
            }
            // Zero-sized borrows need no storage (the value carries no
            // data); the backend binds a null marker instead of a borrow.
            if crate::tyinfo::place_is_zst(tcx, body, p) {
                into.push_str(", \"zst\": true");
            }
            // Memory-resident aggregates (ADT/tuple/array) are represented as
            // an address in this ABI: `&local` is that same address, not a
            // borrow of the register holding it.
            let pty = p.ty(&body.local_decls, tcx).ty;
            if matches!(pty.kind(), TyKind::Adt(..) | TyKind::Tuple(..) | TyKind::Array(..)) {
                into.push_str(", \"agg\": true");
            }
            // Borrow of a projected place (`&(*p).f`, `&local.f`): the address
            // is the base plus the field offset, not the base register.
            match crate::place::place_proj(tcx, body, p) {
                Some(pi) => {
                    let (off, ty) = (pi.offset, pi.ty);
                    write!(
                        into,
                        ", \"offset\": {}, \"projected\": true, \"ty\": \"{}\"",
                        off, ty
                    )
                    .unwrap();
                }
                None => {
                    // A plain borrow's value type (the backend copies the
                    // borrowed value into a buffer for a shared reference).
                    let pty = p.ty(&body.local_decls, tcx).ty;
                    if let Some(t) = crate::tyinfo::ty_sa_sig_opt(pty) {
                        write!(into, ", \"ty\": \"{}\"", t).unwrap();
                    }
                }
            }
            into.push('}');
        }
        Rvalue::RawPtr(kind, p) => {
            let (s, _) = place_name(p);
            let m = matches!(kind, rustc_middle::mir::RawPtrKind::Mut);
            write!(into, "{{\"kind\": \"RawPtr\", \"place\": \"{}\"", s).unwrap();
            if m {
                into.push_str(", \"mut\": true");
            }
            into.push('}');
        }
        Rvalue::Repeat(op, len) => {
            into.push_str("{\"kind\": \"Repeat\", \"op\": ");
            operand_json(op, tcx, body, into);
            into.push_str(", \"len\": \"");
            esc(&trunc(format!("{:?}", len), 40), into);
            into.push_str("\"}");
        }
        Rvalue::ThreadLocalRef(did) => {
            into.push_str("{\"kind\": \"ThreadLocal\", \"def\": \"");
            esc(&trunc(tcx.def_path_str(*did), 100), into);
            into.push_str("\"}");
        }
        Rvalue::BinaryOp(op, box_ops) => {
            into.push_str("{\"kind\": \"BinOp\", \"op\": \"");
            into.push_str(&format!("{:?}", op));
            into.push_str("\", \"left\": ");
            operand_json(&box_ops.0, tcx, body, into);
            into.push_str(", \"right\": ");
            operand_json(&box_ops.1, tcx, body, into);
            // Ordered comparisons, division and shifts depend on the
            // operand's signedness: the SA ISA has separate signed and
            // unsigned mnemonics (`slt`/`ult`, `sdiv`/`udiv`, ...).
            let ty = operand_ty_short(tcx, body, &box_ops.0);
            let signed = ty.starts_with('i') || ty.starts_with('f');
            into.push_str(", \"signed\": ");
            into.push_str(if signed { "true" } else { "false" });
            into.push('}');
        }
        Rvalue::UnaryOp(op, o) => {
            into.push_str("{\"kind\": \"UnOp\", \"op\": \"");
            into.push_str(&format!("{:?}", op));
            into.push_str("\", \"operand\": ");
            operand_json(o, tcx, body, into);
            into.push('}');
        }
        Rvalue::Cast(kind, op, ty) => {
            into.push_str("{\"kind\": \"Cast\", \"op\": ");
            operand_json(op, tcx, body, into);
            into.push_str(", \"ty\": \"");
            esc(&trunc(format!("{:?}", ty), 60), into);
            into.push_str("\", \"castkind\": \"");
            esc(&trunc(format!("{:?}", kind), 40), into);
            into.push_str("\", \"src_ty\": \"");
            esc(&operand_ty_short(tcx, body, op), into);
            into.push('"');
            // An unsizing coercion `&[T; N]` -> `&[T]`: the target is a fat
            // pointer (data word + length), built from the array's address.
            if let Some((size, len_off, len)) = unsize_info(tcx, body, op, *ty) {
                write!(
                    into,
                    ", \"coerce\": {{\"size\": {}, \"len_off\": {}, \"len\": {}}}",
                    size, len_off, len
                )
                .unwrap();
            }
            into.push('}');
        }
        Rvalue::Aggregate(kind, ops) => {
            let elems_len = ops.len();
            into.push_str("{\"kind\": \"Aggregate\", \"elems\": [");
            for (i, o) in ops.iter().enumerate() {
                if i > 0 {
                    into.push_str(", ");
                }
                operand_json(o, tcx, body, into);
            }
            into.push_str("]");
            if let Some((size, offsets)) = layout {
                write!(into, ", \"layout\": {{\"size\": {}, \"offsets\": [", size).unwrap();
                for (i, o) in offsets.iter().enumerate() {
                    if i > 0 {
                        into.push_str(", ");
                    }
                    write!(into, "{}", o).unwrap();
                }
                into.push_str("]}");
            }
            // Enum construction: discriminant + tag slot (Direct encoding).
            if let rustc_middle::mir::AggregateKind::Adt(_, vi, _, _, _) = &**kind {
                if let Some((toff, tty)) = discr_info(tcx, body, place) {
                    write!(
                        into,
                        ", \"tag\": {{\"variant\": {}, \"offset\": {}, \"ty\": \"{}\"}}",
                        vi.as_u32(), toff, tty
                    )
                    .unwrap();
                }
            }
            // Element types (from the variant's field types): the backend
            // needs them to type the stores (a pointer field is not a u64).
            if let Some(tys) = agg_elem_tys(tcx, body, place, kind, elems_len) {
                into.push_str(", \"elem_tys\": [");
                for (i, t) in tys.iter().enumerate() {
                    if i > 0 {
                        into.push_str(", ");
                    }
                    into.push('"');
                    into.push_str(t);
                    into.push('"');
                }
                into.push(']');
            }
            // Niche construction: the niche variant stores the niche value.
            if let Some((noff, nval, nty)) = niche_store {
                write!(
                    into,
                    ", \"niche_store\": {{\"offset\": {}, \"value\": {}, \"ty\": \"{}\"}}",
                    noff, nval, nty
                )
                .unwrap();
            }
            into.push('}');
        }
        Rvalue::Discriminant(p) => {
            let (s, _) = place_name(p);
            match discr_info(tcx, body, p) {
                Some((off, t)) => write!(
                    into,
                    "{{\"kind\": \"Discriminant\", \"place\": \"{}\", \"offset\": {}, \"ty\": \"{}\"}}",
                    s, off, t
                )
                .unwrap(),
                None if niche_enum(tcx, body, p) => match niche_info(tcx, body, p) {
                    Some((off, nv, uv)) => write!(
                        into,
                        "{{\"kind\": \"Discriminant\", \"place\": \"{}\", \"niche\": true, \"niche_offset\": {}, \"none_variant\": {}, \"some_variant\": {}}}",
                        s, off, nv, uv
                    )
                    .unwrap(),
                    None => write!(
                        into,
                        "{{\"kind\": \"Discriminant\", \"place\": \"{}\", \"niche\": true}}",
                        s
                    )
                    .unwrap(),
                },
                None => write!(into, "{{\"kind\": \"Discriminant\", \"place\": \"{}\"}}", s).unwrap(),
            }
        }
        other => {
            into.push_str("{\"kind\": \"Unsupported\", \"text\": \"");
            esc(&trunc(format!("{:?}", other), 120), into);
            into.push_str("\"}");
        }
    }
}

/// SA-level type name for signatures: scalars normalized (`bool`->`u8`,
/// `usize`->`u64`, `char`->`u32`), unit->`void`, everything else (`&`/`*`,
/// ADT, slices, tuples, fn) is an opaque `ptr` handle (existing sla

/// The fn item a call-target const denotes: `(DefId, monomorphized args)`.
/// `args` is `None` for alias consts, which carry no generic arguments here.
fn fn_item_of<'tcx>(
    tcx: TyCtxt<'tcx>,
    c: &Const<'tcx>,
) -> Option<(rustc_span::def_id::DefId, Option<ty::GenericArgsRef<'tcx>>)> {
    let _ = tcx;
    match c {
        Const::Unevaluated(uv, _) => Some((uv.def, Some(uv.args))),
        Const::Ty(_, ct) => match ct.kind() {
            ConstKind::Value(ty::Value { ty, .. }) => match ty.kind() {
                TyKind::FnDef(def_id, args) => Some((*def_id, Some(args.skip_binder()))),
                _ => None,
            },
            ConstKind::Alias(_, alias) => Some((
                match alias.kind {
                    ty::AliasConstKind::Free { def_id } => def_id,
                    ty::AliasConstKind::Projection { def_id } => def_id,
                    ty::AliasConstKind::InherentImpl { def_id } => def_id,
                    ty::AliasConstKind::InherentSelf { def_id } => def_id,
                    ty::AliasConstKind::Anon { def_id } => def_id,
                },
                None,
            )),
            _ => None,
        },
        Const::Val(_, ty) => match ty.kind() {
            TyKind::FnDef(def_id, args) => Some((*def_id, Some(args.skip_binder()))),
            _ => None,
        },
    }
}

/// Short `(name, full)` for a fn item whose *monomorphized instance* is in the
/// local crate. `None` for std/core/alloc/proc_macro instances and anything
/// that cannot be resolved (the caller then keeps the Debug name).
fn local_instance_name<'tcx>(
    tcx: TyCtxt<'tcx>,
    def_id: rustc_span::def_id::DefId,
    args: Option<ty::GenericArgsRef<'tcx>>,
) -> Option<(String, String)> {
    let args = args?;
    let env = ty::TypingEnv::fully_monomorphized();
    let inst = ty::Instance::try_resolve(tcx, env, def_id, args).ok().flatten()?;
    let id = inst.def_id();
    let krate = tcx.crate_name(id.krate);
    let k = krate.as_str();
    if k != "std" && k != "core" && k != "alloc" && k != "proc_macro" {
        if matches!(tcx.def_kind(id), DefKind::Fn | DefKind::AssocFn) {
            return Some(name_from_def(tcx, id));
        }
    }
    // `<&T as PartialEq>::eq` (std's blanket impl) delegates to `T::eq`:
    // resolve the local type's own impl so the call reaches the derived
    // function instead of an unrunnable std symbol.
    if let Some(local) = local_partial_eq_impl(tcx, def_id, args) {
        return Some(name_from_def(tcx, local));
    }
    None
}

/// The local `PartialEq::eq` implementation for the pointee of a
/// `&T as PartialEq` call (the derived `impl PartialEq for T`).
fn local_partial_eq_impl<'tcx>(
    tcx: TyCtxt<'tcx>,
    def_id: rustc_span::def_id::DefId,
    args: ty::GenericArgsRef<'tcx>,
) -> Option<rustc_span::def_id::DefId> {
    if !tcx.def_path_str(def_id).contains("PartialEq") {
        return None;
    }
    let self_ty = args.first()?.as_type()?;
    let pointee = match self_ty.kind() {
        TyKind::Ref(_, t, _) => *t,
        _ => return None,
    };
    let adt = match pointee.kind() {
        TyKind::Adt(d, _) => *d,
        _ => return None,
    };
    let adt = adt.did();
    for owner in tcx.hir_body_owners() {
        let did = owner.to_def_id();
        if !matches!(tcx.def_kind(did), DefKind::AssocFn) {
            continue;
        }
        if tcx.item_name(did) != rustc_span::symbol::sym::eq {
            continue;
        }
        let parent = tcx.parent(did);
        if !matches!(tcx.def_kind(parent), DefKind::Impl { .. }) {
            continue;
        }
        // The impl's own type: the derived `impl PartialEq for E` has `E`
        // as its self type (the method name already pins it to `eq`).
        let impl_self = tcx
            .normalize_erasing_regions(
                ty::TypingEnv::fully_monomorphized(),
                tcx.type_of(parent).instantiate_identity(),
            );
        if let TyKind::Adt(d, _) = impl_self.kind() {
            if d.did() == adt {
                return Some(did);
            }
        }
    }
    None
}

pub fn fn_operand_name<'a>(tcx: TyCtxt<'a>, op: &Operand<'a>) -> (String, String) {
    // Prefer `a_b_c` path names; fall back to Debug text.
    if let Operand::Constant(c) = op {
        let c: &ConstOperand<'_> = c;
        // A call target is a (possibly trait) fn item. Resolve it to the
        // monomorphized instance first: a derived/trait method reaches MIR as
        // `FnDef(core::cmp::PartialEq::eq, [Pair, Pair])`, whose *impl* lives
        // in the local crate and whose own mir.json entry is named `eq` — the
        // trait def's crate (core) would otherwise force the Debug fallback
        // and the caller would reference a mangled symbol that no crate
        // defines. Local-crate instances use the short def name so a caller
        // and the callee's own mir.json agree and `mir2sars --dep` can link
        // them; std/core/alloc/proc_macro keep the Debug-derived name (the key
        // the STD_MAP/broker side expects).
        if let Some((def_id, args)) = fn_item_of(tcx, &c.const_) {
            if let Some(name) = local_instance_name(tcx, def_id, args) {
                return name;
            }
            // No instance (e.g. a bare trait def): fall back to the def's own
            // crate test.
            if matches!(tcx.def_kind(def_id), DefKind::Fn | DefKind::AssocFn) {
                let krate = tcx.crate_name(def_id.krate);
                let k = krate.as_str();
                if k != "std" && k != "core" && k != "alloc" && k != "proc_macro" {
                    return name_from_def(tcx, def_id);
                }
            }
        }
    }
    let dbg = trunc(format!("{:?}", op), 100);
    (sanitize(&dbg), dbg)
}

/// `(short, full)` for a named item: last path segment, sanitized for SA.
///
/// A method or associated function can share its short name with another
/// impl (`Shape::eq` and `Point::eq` are both `eq`): the caller would then
/// not resolve to a unique local function, so those use the full path.
fn name_from_def(tcx: TyCtxt<'_>, def_id: rustc_span::def_id::DefId) -> (String, String) {
    let full = tcx.def_path_str(def_id);
    // An associated function (an impl method, e.g. a derived `Shape::eq`)
    // can share its short name with another impl: use the full path so
    // callers resolve to a unique local function. Plain functions keep the
    // short name (a cross-crate callee is imported under that name).
    let is_assoc = matches!(tcx.def_kind(def_id), DefKind::AssocFn);
    let short = if is_assoc {
        full.clone()
    } else {
        full.rsplit("::").next().unwrap_or(&full).to_string()
    };
    let clean: String = {
        let mut s = String::new();
        let mut sep = true;
        for ch in short.chars() {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                s.push(ch);
                sep = false;
            } else if !sep {
                s.push('_');
                sep = true;
            }
        }
        while s.ends_with('_') {
            s.pop();
        }
        s
    };
    (clean, trunc(full, 100))
}

/// Absolute payload offsets for an enum variant construction: the enum's
/// storage size plus each field's absolute offset from `variants[vi]`.
fn enum_agg_layout<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    dest: &rustc_middle::mir::Place<'tcx>,
    kind: &rustc_middle::mir::AggregateKind<'tcx>,
    n: usize,
) -> Option<(u64, Vec<u64>)> {
    use rustc_abi::{TagEncoding, Variants};
    use rustc_middle::mir::AggregateKind;
    use rustc_middle::ty::TypingEnv;
    let vi = match kind {
        AggregateKind::Adt(_, vi, ..) => *vi,
        _ => return None,
    };
    let env = TypingEnv::fully_monomorphized();
    let ty = dest.ty(&body.local_decls, tcx).ty;
    let layout = tcx
        .layout_of(rustc_middle::ty::PseudoCanonicalInput { typing_env: env, value: ty })
        .ok()?;
    match &layout.variants {
        // Struct-like ADT: plain field offsets.
        Variants::Single { .. } => {
            if !matches!(
                layout.fields,
                rustc_abi::FieldsShape::Arbitrary { .. } | rustc_abi::FieldsShape::Array { .. }
            ) {
                return None;
            }
            let mut offsets = Vec::with_capacity(n);
            for i in 0..n {
                offsets.push(layout.fields.offset(i).bytes());
            }
            Some((layout.size.bytes(), offsets))
        }
        Variants::Multiple { tag_encoding, variants, .. } => {
            // Niche encoding: the payload of the untagged variant lives in
            // the niche field (same slot as the niche value).
            let vi = match tag_encoding {
                TagEncoding::Direct => vi,
                TagEncoding::Niche { untagged_variant, .. } => {
                    if vi != *untagged_variant {
                        // The niche variant carries no payload.
                        return Some((layout.size.bytes(), Vec::new()));
                    }
                    vi
                }
            };
            let v = variants.raw.get(vi.as_usize())?;
            let mut offsets = Vec::with_capacity(n);
            for i in 0..n {
                offsets.push(v.field_offsets.raw.get(i)?.bytes());
            }
            Some((layout.size.bytes(), offsets))
        }
        _ => None,
    }
}

/// Niche store for a niche-encoded enum construction: the niche variant
/// (`None`) has no payload, so the niche value (0 for a pointer niche) is
/// written into the niche slot.
fn niche_store_info<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    dest: &rustc_middle::mir::Place<'tcx>,
    kind: &rustc_middle::mir::AggregateKind<'tcx>,
) -> Option<(u64, u64, String)> {
    use rustc_abi::{TagEncoding, Variants};
    use rustc_middle::mir::AggregateKind;
    use rustc_middle::ty::TypingEnv;
    let vi = match kind {
        AggregateKind::Adt(_, vi, ..) => *vi,
        _ => return None,
    };
    let env = TypingEnv::fully_monomorphized();
    let ty = dest.ty(&body.local_decls, tcx).ty;
    let layout = tcx
        .layout_of(rustc_middle::ty::PseudoCanonicalInput { typing_env: env, value: ty })
        .ok()?;
    let (untagged, niche_variants, niche_start, tag_field) = match &layout.variants {
        Variants::Multiple {
            tag_encoding:
                TagEncoding::Niche {
                    untagged_variant,
                    niche_variants,
                    niche_start,
                },
            tag_field,
            ..
        } => (
            *untagged_variant,
            niche_variants.clone(),
            *niche_start,
            *tag_field,
        ),
        _ => return None,
    };
    if vi == untagged || niche_variants.start != vi {
        return None;
    }
    if niche_start != 0 {
        return None;
    }
    let off = layout.fields.offset(tag_field.as_usize()).bytes();
    Some((off, 0, "ptr".to_string()))
}

/// True when the place's type is a multi-variant enum whose tag is encoded
/// in another field's niche (no stored discriminant slot).
fn niche_enum<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    p: &rustc_middle::mir::Place<'tcx>,
) -> bool {
    use rustc_abi::{TagEncoding, Variants};
    use rustc_middle::ty::TypingEnv;
    let env = TypingEnv::fully_monomorphized();
    match tcx.layout_of(rustc_middle::ty::PseudoCanonicalInput {
        typing_env: env,
        value: p.ty(&body.local_decls, tcx).ty,
    }) {
        Ok(layout) => matches!(
            layout.variants,
            Variants::Multiple { tag_encoding: TagEncoding::Niche { .. }, .. }
        ),
        Err(_) => false,
    }
}

/// Byte offset + SA integer type of an enum's discriminant (tag), when it is
/// stored directly (no niche). `None` for non-enums, single-variant enums and
/// niche-encoded tags (whose memory value maps to the variant non-trivially).
fn discr_info<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    p: &rustc_middle::mir::Place<'tcx>,
) -> Option<(u64, String)> {
    use rustc_abi::{TagEncoding, Variants};
    use rustc_middle::ty::TypingEnv;
    let env = TypingEnv::fully_monomorphized();
    let layout = tcx
        .layout_of(rustc_middle::ty::PseudoCanonicalInput {
            typing_env: env,
            value: p.ty(&body.local_decls, tcx).ty,
        })
        .ok()?;
    match layout.variants {
        Variants::Multiple { tag, tag_encoding: TagEncoding::Direct, tag_field, .. } => {
            let off = layout.fields.offset(tag_field.as_usize()).bytes();
            let t = match tag.size(&tcx).bytes() {
                1 => "u8",
                2 => "u16",
                4 => "u32",
                8 => "u64",
                _ => return None,
            };
            Some((off, t.to_string()))
        }
        _ => None,
    }
}

/// Niche-encoded discriminant (e.g. `Option<&T>`): the variant is decided by
/// the niche field's value, not by a stored tag. Returns
/// `(niche field offset, none variant, some variant)` for the simple shape
/// (one niche variant, one untagged variant, pointer niche whose value is 0).
fn niche_info<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    p: &rustc_middle::mir::Place<'tcx>,
) -> Option<(u64, u32, u32)> {
    use rustc_abi::{TagEncoding, Variants};
    use rustc_middle::ty::TypingEnv;
    let env = TypingEnv::fully_monomorphized();
    let layout = tcx
        .layout_of(rustc_middle::ty::PseudoCanonicalInput {
            typing_env: env,
            value: p.ty(&body.local_decls, tcx).ty,
        })
        .ok()?;
    let (untagged, niche_variants, niche_start, tag_field) = match &layout.variants {
        Variants::Multiple {
            tag_encoding:
                TagEncoding::Niche {
                    untagged_variant,
                    niche_variants,
                    niche_start,
                },
            tag_field,
            ..
        } => (
            *untagged_variant,
            niche_variants.clone(),
            *niche_start,
            *tag_field,
        ),
        _ => return None,
    };
    // Only the simple shape: exactly one niche variant (the `None` one).
    if niche_variants.last != niche_variants.start {
        return None;
    }
    if niche_start != 0 {
        return None;
    }
    let nv = niche_variants.start.as_u32();
    let uv_idx = untagged;
    let uv = untagged.as_u32();
    // The niche field must be a pointer (null is the niche value).
    let ty = p.ty(&body.local_decls, tcx).ty;
    let (def, args) = match ty.kind() {
        TyKind::Adt(def, args) => (*def, args),
        _ => return None,
    };
    let fld = def.variants()[uv_idx].fields.raw.first()?;
    let fty = tcx.normalize_erasing_regions(env, fld.ty(tcx, args));
    if !matches!(fty.kind(), TyKind::Ref(..) | TyKind::RawPtr(..)) {
        return None;
    }
    let off = layout.fields.offset(tag_field.as_usize()).bytes();
    Some((off, nv, uv))
}

/// Byte size of a by-value aggregate type (Adt/tuple/array), else 0. Used for
/// `param_aggs` so a callee can copy a param-derived aggregate on return.
fn ty_agg_size<'tcx>(tcx: TyCtxt<'tcx>, ty: ty::Ty<'tcx>) -> u64 {
    use rustc_middle::ty::{PseudoCanonicalInput, TypingEnv};
    match ty.kind() {
        TyKind::Adt(..) | TyKind::Tuple(..) | TyKind::Array(..) => {
            let typing_env = TypingEnv::fully_monomorphized();
            tcx.layout_of(PseudoCanonicalInput { typing_env, value: ty })
                .map(|l| l.size.bytes())
                .unwrap_or(0)
        }
        _ => 0,
    }
}

/// Unique SA name of a local function (definition and call sites agree).
pub fn local_fn_name(tcx: TyCtxt<'_>, def_id: rustc_span::def_id::DefId) -> String {
    name_from_def(tcx, def_id).0
}

pub fn body_json<'tcx>(
    tcx: TyCtxt<'tcx>,
    param_env: ty::ParamEnv<'tcx>,
    name: &str,
    body: &Body<'tcx>,
    into: &mut String,
) {
    into.push_str("{\"name\": \"");
    esc(name, into);
    into.push_str("\", \"locals\": [], ");
    // Callee-visible signature: MIR arg locals `_1..=_arg_count` plus the
    // return-place type, mapped to SA tys (opaque `ptr` fallback). The
    // backend declares typed params from these (bare `@f()` leaves MIR
    // params unbound, which is UnknownRegister).
    into.push_str("\"params\": [");
    let mut sig_ok = true;
    for i in 1..=body.arg_count {
        if i > 1 {
            into.push_str(", ");
        }
        let ty = body.local_decls[Local::from_u32(i as u32)].ty;
        match ty_sa_sig_opt(ty) {
            Some(t) => write!(into, "\"{}\"", t).unwrap(),
            None => {
                sig_ok = false;
                into.push_str("\"ptr\"");
            }
        }
    }
    let ret_ty = body.local_decls[Local::from_u32(0)].ty;
    let ret = ty_sa_sig_opt(ret_ty);
    if ret.is_none() {
        sig_ok = false;
    }
    // Byte size of each by-value aggregate param (0 = scalar/pointer). A
    // callee that returns a param-derived aggregate must copy it out so the
    // caller does not share (and double-free) the argument's storage.
    into.push_str("], \"param_aggs\": [");
    for i in 1..=body.arg_count {
        if i > 1 {
            into.push_str(", ");
        }
        let ty = body.local_decls[Local::from_u32(i as u32)].ty;
        write!(into, "{}", ty_agg_size(tcx, ty)).unwrap();
    }
    write!(into, "], \"ret\": \"{}\"", ret.unwrap_or_else(|| "ptr".to_string())).unwrap();
    write!(into, ", \"sig_ok\": {}", sig_ok).unwrap();
    into.push_str(", \"blocks\": [");
    for (bi, data) in body.basic_blocks.iter_enumerated() {
        if bi.index() > 0 {
            into.push_str(", ");
        }
        into.push_str("{\"id\": \"");
        into.push_str(&bb_name(bi));
        into.push_str("\", \"statements\": [");
        let mut first = true;
        for st in &data.statements {
            if !first {
                into.push_str(", ");
            }
            first = false;
            match &st.kind {
                StatementKind::Assign(boxed) => {
                    let (place, rv) = &**boxed;
                    let (short, full) = place_name(place);
                    into.push_str("{\"kind\": \"Assign\", \"dest\": \"");
                    into.push_str(&short);
                    into.push_str("\", \"dest_place\": \"");
                    esc(&full, into);
                    into.push('"');
                    // Field store (`_1.0 = ...`): carry the byte offset + SA type
                    // so lowering emits `store base+off, val as ty` instead of
                    // rebinding the base local.
                    if let Some(pi) = place_proj(tcx, body, place) {
                        let (off, ty, via) = (pi.offset, pi.ty, pi.via);
                        write!(into, ", \"dest_proj\": {{\"offset\": {}, \"ty\": \"", off).unwrap();
                        esc(&ty, into);
                        into.push_str("\", \"via\": \"");
                        esc(&via, into);
                        into.push_str("\"}");
                    }
                    into.push_str(", \"rvalue\": ");
                    // p_layout v2 goes only on multi-operand aggregates.
                    let layout = match rv {
                        // ADT aggregates (structs, tuples-as-ADT, enums): the
                        // absolute field offsets come from the type's layout,
                        // so a one-field aggregate is materialized too (its
                        // local holds the aggregate's address).
                        Rvalue::Aggregate(kind, ops)
                            if matches!(&**kind, rustc_middle::mir::AggregateKind::Adt(..)) =>
                        {
                            enum_agg_layout(tcx, body, place, kind, ops.len())
                        }
                        Rvalue::Aggregate(kind, ops) if ops.len() > 1 => {
                            aggregate_layout(tcx, param_env, body, kind, place, ops.len())
                        }
                        _ => None,
                    };
                    let niche_store = match rv {
                        Rvalue::Aggregate(kind, ops) => {
                            niche_store_info(tcx, body, place, kind).filter(|_| ops.is_empty())
                        }
                        _ => None,
                    };
                    rvalue_json(rv, tcx, body, place, layout.as_ref(), niche_store, into);
                    into.push('}');
                }
                StatementKind::StorageLive(l) => {
                    write!(into, "{{\"kind\": \"StorageLive\", \"local\": \"{}\"}}", local_name(*l)).unwrap();
                }
                StatementKind::StorageDead(l) => {
                    write!(into, "{{\"kind\": \"StorageDead\", \"local\": \"{}\"}}", local_name(*l)).unwrap();
                }
                // Runtime nops (analysis/coverage/counter only): exact kind,
                // backend renders a comment and does NOT count them.
                other @ (StatementKind::Nop | StatementKind::ConstEvalCounter | StatementKind::Coverage(_)) => {
                    into.push_str("{\"kind\": \"Nop\", \"text\": \"");
                    esc(&trunc(format!("{:?}", std::mem::discriminant(other)), 40), into);
                    into.push_str("\"}");
                }
                StatementKind::SetDiscriminant { place, variant_index } => {
                    let (s, full) = place_name(place);
                    write!(into, "{{\"kind\": \"SetDisc\", \"place\": \"{}\", \"place_full\": \"", s).unwrap();
                    esc(&full, into);
                    into.push('"');
                    if let Some((off, t)) = discr_info(tcx, body, place) {
                        write!(into, ", \"offset\": {}, \"ty\": \"{}\"", off, t).unwrap();
                    }
                    write!(into, ", \"variant\": {}}}", variant_index.as_u32()).unwrap();
                }
                other => {
                    into.push_str("{\"kind\": \"UnsupportedStmt\", \"text\": \"");
                    esc(&trunc(format!("{:?}", other), 120), into);
                    into.push_str("\"}");
                }
            }
        }
        into.push_str("], \"terminator\": ");
        let t = match &data.terminator {
            Some(t) => &t.kind,
            None => {
                into.push_str("{\"kind\": \"Return\"}");
                into.push_str("}");
                continue;
            }
        };
        match t {
            TerminatorKind::Goto { target, .. } => {
                write!(into, "{{\"kind\": \"Goto\", \"target\": \"{}\"}}", bb_name(*target)).unwrap();
            }
            TerminatorKind::SwitchInt { discr, targets } => {
                into.push_str("{\"kind\": \"SwitchInt\", \"discr\": ");
                operand_json(discr, tcx, body, into);
                into.push_str(", \"targets\": [");
                let mut fi = true;
                for (v, t) in targets.iter() {
                    if !fi {
                        into.push_str(", ");
                    }
                    fi = false;
                    write!(into, "[\"{}\", \"{}\"]", v, bb_name(t)).unwrap();
                }
                write!(into, "], \"otherwise\": \"{}\"}}", bb_name(targets.otherwise())).unwrap();
            }
            TerminatorKind::Return => into.push_str("{\"kind\": \"Return\"}"),
            TerminatorKind::Unreachable => into.push_str("{\"kind\": \"Unreachable\"}"),
            TerminatorKind::UnwindResume => into.push_str("{\"kind\": \"Resume\"}"),
            TerminatorKind::FalseEdge { real_target, .. } => {
                write!(into, "{{\"kind\": \"Goto\", \"target\": \"{}\"}}", bb_name(*real_target)).unwrap();
            }
            TerminatorKind::FalseUnwind { real_target, .. } => {
                write!(into, "{{\"kind\": \"Goto\", \"target\": \"{}\"}}", bb_name(*real_target)).unwrap();
            }
            TerminatorKind::Drop { place, target, .. } => {
                let (s, _) = place_name(place);
                write!(into, "{{\"kind\": \"Drop\", \"place\": \"{}\", \"target\": \"{}\"}}", s, bb_name(*target)).unwrap();
            }
            TerminatorKind::Call { func, args, destination, target, .. } => {
                let (fname, fraw) = fn_operand_name(tcx, func);
                into.push_str("{\"kind\": \"Call\", \"func\": \"");
                esc(&fname, into);
                into.push_str("\", \"func_raw\": \"");
                esc(&fraw, into);
                into.push_str("\", \"args\": [");
                for (i, a) in args.iter().enumerate() {
                    if i > 0 {
                        into.push_str(", ");
                    }
                    operand_json(&a.node, tcx, body, into);
                }
                into.push(']');
                // Callee signature for typed `@extern` decls (bare `()` decls
                // mismatch any call with args: CapabilityMismatch). Absent
                // when unresolvable; the backend goes loud for such calls.
                match fn_operand_sig(tcx, func) {
                    Some((params, ret)) => {
                        into.push_str(", \"sig\": {\"params\": [");
                        for (i, p) in params.iter().enumerate() {
                            if i > 0 {
                                into.push_str(", ");
                            }
                            write!(into, "\"{}\"", p).unwrap();
                        }
                        write!(into, "], \"ret\": \"{}\"}}", ret).unwrap();
                    }
                    None => into.push_str(", \"sig\": null"),
                }
                let (ds, _) = place_name(destination);
                write!(into, ", \"dest\": \"{}\"", ds).unwrap();
                match target {
                    Some(t) => write!(into, ", \"target\": \"{}\"", bb_name(*t)).unwrap(),
                    None => into.push_str(", \"target\": null"),
                }
                into.push('}');
            }
            TerminatorKind::Assert { cond, target, msg, expected, .. } => {
                into.push_str("{\"kind\": \"Assert\", \"cond\": ");
                operand_json(cond, tcx, body, into);
                into.push_str(", \"target\": \"");
                into.push_str(&bb_name(*target));
                into.push_str("\", \"msg\": \"");
                esc(&trunc(format!("{:?}", msg), 80), into);
                write!(into, "\", \"expected\": {}", expected).unwrap();
                into.push_str("}");
            }
            TerminatorKind::InlineAsm { template, operands, options, targets, .. } => {
                // v2 structured capture (spans stripped for hermetic fixtures).
                // mir2sa gates exact patterns on these fields (`mov` reg-copy,
                // comment-only inout passthrough); everything else stays loud.
                let mut joined = String::new();
                let mut modifiers = false;
                for p in template.iter() {
                    match p {
                        InlineAsmTemplatePiece::String(s) => joined.push_str(s),
                        InlineAsmTemplatePiece::Placeholder { operand_idx, modifier, .. } => {
                            if modifier.is_some() {
                                modifiers = true;
                            }
                            write!(joined, "{{{}}}", operand_idx).unwrap();
                        }
                    }
                }
                let mut outs: Vec<String> = vec![];
                let mut ins: Vec<String> = vec![];
                let mut inout = false;
                for op in operands.iter() {
                    match op {
                        InlineAsmOperand::Out { place: Some(p), .. } => {
                            outs.push(place_name(p).0);
                        }
                        InlineAsmOperand::Out { place: None, .. } => {
                            outs.push("_proj".to_string());
                        }
                        InlineAsmOperand::In { value, .. } => {
                            let mut tmp = String::new();
                            operand_json(value, tcx, body, &mut tmp);
                            ins.push(tmp);
                        }
                        InlineAsmOperand::InOut { in_value, out_place, .. } => {
                            // Single-register passthrough (sla-117 shape): the
                            // value flows in and back out through one reg.
                            inout = true;
                            match out_place {
                                Some(p) => outs.push(place_name(p).0),
                                None => outs.push("_proj".to_string()),
                            }
                            let mut tmp = String::new();
                            operand_json(in_value, tcx, body, &mut tmp);
                            ins.push(tmp);
                        }
                        InlineAsmOperand::Const { .. } => {
                            ins.push("{\"kind\": \"Const\", \"value\": \"asm-operand-const\"}".to_string());
                        }
                        InlineAsmOperand::SymFn { .. } => {
                            ins.push("{\"kind\": \"Const\", \"value\": \"asm-operand-symfn\"}".to_string());
                        }
                        InlineAsmOperand::SymStatic { .. } => {
                            ins.push("{\"kind\": \"Const\", \"value\": \"asm-operand-symstatic\"}".to_string());
                        }
                        InlineAsmOperand::Label { .. } => {
                            ins.push("{\"kind\": \"Const\", \"value\": \"asm-operand-label\"}".to_string());
                        }
                    }
                }
                into.push_str("{\"kind\": \"InlineAsm\", \"text\": \"");
                esc(&trunc(format!("asm {:?} operands={}", template, operands.len()), 120), into);
                into.push_str("\", \"template\": \"");
                esc(&trunc(joined, 120), into);
                into.push_str("\", \"options\": \"");
                esc(&trunc(format!("{:?}", options), 80), into);
                into.push_str(&format!("\", \"modifiers\": {}, \"inout\": {}, \"outs\": [", modifiers, inout));
                for (i, o) in outs.iter().enumerate() {
                    if i > 0 {
                        into.push_str(", ");
                    }
                    write!(into, "\"{}\"", o).unwrap();
                }
                into.push_str("], \"ins\": [");
                for (i, s) in ins.iter().enumerate() {
                    if i > 0 {
                        into.push_str(", ");
                    }
                    into.push_str(s);
                }
                into.push_str("]");
                // First target is the fallthrough destination (absent for
                // naked/noreturn asm). RPO block ordering needs it explicit:
                // SA has no implicit fallthrough across reordered blocks.
                match targets.first() {
                    Some(t) => write!(into, ", \"target\": \"{}\"", bb_name(*t)).unwrap(),
                    None => into.push_str(", \"target\": null"),
                }
                into.push('}');
            }
            other => {
                into.push_str("{\"kind\": \"Unsupported\", \"text\": \"");
                esc(&trunc(format!("{:?}", other), 120), into);
                into.push_str("\"}");
            }
        }
        into.push('}');
    }
    into.push_str("]}");
}
