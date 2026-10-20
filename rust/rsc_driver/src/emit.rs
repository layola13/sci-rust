//! rsc_driver::emit.
use crate::place::{place_name, place_proj, place_via};
use crate::tyinfo::{aggregate_layout, fn_operand_sig, operand_ty_short, str_const_bytes, ty_sa_sig_opt};
use crate::util::{bb_name, esc, local_name, sanitize, trunc};
use rustc_ast::ast::InlineAsmTemplatePiece;
use rustc_hir::def::DefKind;
use rustc_middle::mir::{Body, BorrowKind, Const, ConstOperand, InlineAsmOperand, Local, Operand, Rvalue, StatementKind, TerminatorKind};
use rustc_middle::ty::{ConstKind, TyCtxt, TyKind};
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
        Some((off, ty, via)) => {
            into.push_str("{\"kind\": \"");
            into.push_str(kind);
            into.push_str("\", \"place\": \"");
            esc(s, into);
            write!(into, "\", \"proj\": {{\"offset\": {}, \"ty\": \"", off).unwrap();
            esc(&ty, into);
            into.push_str("\", \"via\": \"");
            esc(&via, into);
            into.push_str("\"}}");
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
            let v = trunc(format!("{:?}", c.const_), 60);
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

/// Short scalar name for a cast operand's type (int/uint/float/bool/char,

pub fn rvalue_json<'tcx>(
    rv: &Rvalue<'tcx>,
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    layout: Option<&(u64, Vec<u64>)>,
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
            into.push_str("\"}");
        }
        Rvalue::Aggregate(_kind, ops) => {
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
            into.push('}');
        }
        Rvalue::Discriminant(p) => {
            let (s, _) = place_name(p);
            write!(into, "{{\"kind\": \"Discriminant\", \"place\": \"{}\"}}", s).unwrap();
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
fn name_from_def(tcx: TyCtxt<'_>, def_id: rustc_span::def_id::DefId) -> (String, String) {
    let full = tcx.def_path_str(def_id);
    let short = full.rsplit("::").next().unwrap_or(&full).to_string();
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
                    if let Some((off, ty, via)) = place_proj(tcx, body, place) {
                        write!(into, ", \"dest_proj\": {{\"offset\": {}, \"ty\": \"", off).unwrap();
                        esc(&ty, into);
                        into.push_str("\", \"via\": \"");
                        esc(&via, into);
                        into.push_str("\"}");
                    }
                    into.push_str(", \"rvalue\": ");
                    // p_layout v2 goes only on multi-operand aggregates.
                    let layout = match rv {
                        Rvalue::Aggregate(kind, ops) if ops.len() > 1 => {
                            aggregate_layout(tcx, param_env, body, kind, place, ops.len())
                        }
                        _ => None,
                    };
                    rvalue_json(rv, tcx, body, layout.as_ref(), into);
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
                    write!(into, "\", \"variant\": {}}}", variant_index.as_u32()).unwrap();
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
