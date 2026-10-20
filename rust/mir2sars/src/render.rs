//! mir2sa::render.
use crate::asm::{cast_dst_short, lower_cast, CastLower};
use crate::const_util::{repeat_plan, sa_scalar_ty};
use crate::layout::{lower_adt_init, lower_array_init, tls_key};
use crate::mir::*;
use crate::render_util::*;

/// Operand text for a spilled source: a `load` from its slot. None when the
/// operand is not a spilled register (constants, spills absent).
/// Call arguments: a spilled value reloads from its slot into a temp (a
/// plain copy would move the register; a reload expression is not a valid
/// argument position).
pub fn render_call_args(
    args: &[Operand],
    spill: &crate::spill::SpillMap,
    prefix: &str,
) -> (Vec<String>, Vec<String>) {
    let mut prelude = Vec::new();
    let mut out = Vec::new();
    for (i, op) in args.iter().enumerate() {
        let mut plain = true;
        if op.proj().is_none() {
            if let Operand::Move { place, .. } | Operand::Copy { place, .. } = op {
                if let Some(t) = spill.get(place) {
                    let tmp = format!("{}_ca{}", prefix, i);
                    prelude.push(format!(
                        "{} = load {}+0 as {}",
                        tmp,
                        crate::spill::spill_slot(place),
                        t
                    ));
                    out.push(tmp);
                    plain = false;
                }
            }
        }
        if plain {
            out.push(crate::render_util::render_call_arg(op));
        }
    }
    (prelude, out)
}

pub fn spill_reg(op: &Operand, spill: &crate::spill::SpillMap) -> Option<String> {
    let place = match op {
        Operand::Move { place, .. } | Operand::Copy { place, .. } => place,
        _ => return None,
    };
    // A projected read is a field load, never a whole-register spill reload.
    if op.proj().is_some() {
        return None;
    }
    let t = spill.get(place)?;
    Some(format!("load {}+0 as {}", crate::spill::spill_slot(place), t))
}

/// Slot setup lines for a spilled dest: its later Copy-uses reload from the
/// slot instead of moving the register (a moved register traps
/// UseAfterMove). Empty when the dest is not spilled.
fn dest_slot_lines(dest: &str, spill: &crate::spill::SpillMap) -> Vec<String> {
    match spill.get(dest) {
        Some(t) => {
            let s = crate::spill::spill_slot(dest);
            vec![format!("mut {} = stack_alloc 8", s), format!("store {}+0, {} as {}", s, dest, t)]
        }
        None => vec![],
    }
}

/// The same slot setup as one text blob (for single-line renderings).
fn dest_slot_suffix(dest: &str, spill: &crate::spill::SpillMap) -> String {
    let lines = dest_slot_lines(dest, spill);
    if lines.is_empty() {
        String::new()
    } else {
        format!("\n{}", lines.join("\n"))
    }
}

pub fn render_rvalue(
    rv: &Rvalue,
    dest: &str,
    dest_place: Option<&str>,
    unsup: &mut Vec<String>,
    bid: &str,
    mv_idx: &mut usize,
    cmap: &std::collections::HashMap<String, String>,
    spill: &crate::spill::SpillMap,
) -> String {
    match rv {
        Rvalue::Use { op } => {
            // Aggregate field projection: read through the base register with a
            // typed load (`load base+off as ty`) instead of reusing the base
            // pointer. Must run before the spill/const-map paths, which reason
            // about whole-register values.
            if let Some(pj) = op.proj() {
                if let Operand::Move { place, .. } | Operand::Copy { place, .. } = op {
                    // The base may be a fat pointer (a slice): load its data
                    // word first, then apply the (dynamic) index.
                    let (base, prelude) = if pj.deref_base {
                        let bp = format!("{}_b", dest);
                        (bp.clone(), format!("{} = load {}+0 as ptr\n", bp, place))
                    } else {
                        (place.clone(), String::new())
                    };
                    if let Some((idx, size)) = &pj.index {
                        // A dynamic index (`a[i]`): the address is
                        // `base + index * elem_size`.
                        let ix = format!("{}_ix", dest);
                        let ptr = format!("{}_p", dest);
                        return format!(
                            "{prelude}{ix} = mul {idx}, {size}\n{ptr} = ptr_add {base}, {ix}\n{dest} = load {ptr}+{} as {}{}",
                            pj.offset,
                            pj.ty,
                            dest_slot_suffix(dest, spill)
                        );
                    }
                    return format!(
                        "{prelude}{} = load {}+{} as {}{}",
                        dest, base, pj.offset, pj.ty, dest_slot_suffix(dest, spill)
                    );
                }
            }
            // Spilled shared values reload (never move the slot source).
            if let Some(t) = spill_reg(op, spill) {
                return format!("{} = {}{}", dest, t, dest_slot_suffix(dest, spill));
            }
            // Const-propagated literals re-materialize instead of moving a
            // shared temp (a second move of the temp would trap UseAfterMove).
            // Sound: literals carry no control or ownership dependence.
            match op {
                Operand::Move { place, .. } | Operand::Copy { place, .. } => {
                    if let Some(lit) = cmap.get(place) {
                        return format!("{} = {}{}", dest, lit, dest_slot_suffix(dest, spill));
                    }
                    format!("{} = {}{}", dest, render_operand(op), dest_slot_suffix(dest, spill))
                }
                // Byte-literal const in value position: inline the payload
                // and bind its thin address (fat pointees stay loud).
                Operand::ConstAgg { elems, layout, tag, niche_store, elem_tys } => {
                    // A constant aggregate is materialized like an inline one.
                    if let Some(mut lines) = crate::layout::lower_adt_init(
                        bid,
                        dest,
                        dest_place.unwrap_or(dest),
                        elems,
                        layout.as_ref(),
                        tag.as_ref(),
                        niche_store.as_ref(),
                        elem_tys.as_deref(),
                    ) {
                        crate::spill::spill_slot_lines(&mut lines, bid, spill);
                        return lines.join("\n");
                    }
                    unsup.push(format!("{}:{} ConstAggregate", bid, dest));
                    return format!("// UNSUPPORTED const aggregate -> {}\n{} = 0", dest, dest);
                }
                Operand::Const { value, str_bytes, str_len, agg, str_fat } => {
                    // A constant aggregate is materialized like an inline one.
                    if let Some(rv) = agg {
                        if let Rvalue::Aggregate { elems, layout, tag, niche_store, elem_tys } = rv.as_ref() {
                            if let Some(mut lines) = crate::layout::lower_adt_init(
                                bid,
                                dest,
                                dest_place.unwrap_or(dest),
                                elems,
                                layout.as_ref(),
                                tag.as_ref(),
                                niche_store.as_ref(),
                                elem_tys.as_deref(),
                            ) {
                                crate::spill::spill_slot_lines(&mut lines, bid, spill);
                                return lines.join("\n");
                            }
                            unsup.push(format!("{}:{} ConstAggregate", bid, dest));
                            return format!("// UNSUPPORTED const aggregate -> {}\n{} = 0", dest, dest);
                        }
                    }
                    if let Some(mut lines) = crate::layout::plan_const_bytes(
                        dest, bid, *mv_idx, value, str_bytes.as_ref(), *str_len, *str_fat,
                    ) {
                        *mv_idx += 1;
                        // Spilled dests keep a slot so their Copy-uses reload
                        // instead of moving the buffer address.
                        if let Some(t) = spill.get(dest) {
                            let s = crate::spill::spill_slot(dest);
                            lines.push(format!("mut {} = stack_alloc 8", s));
                            lines.push(format!("store {}+0, {} as {}", s, dest, t));
                        }
                        return lines.join("\n");
                    }
                    format!("{} = {}", dest, render_operand(op))
                }
                // Conflict sentinels never reach here (intercepted loud
                // upstream); the fallback keeps rendering total.
                _ => format!("{} = {}", dest, render_operand(op)),
            }
        }
        Rvalue::Ref { place, mut_, via, zst, agg, offset, projected, ty } => {
            // Zero-sized borrows carry no data: null marker (exact).
            // Trailing `//` is ForbiddenSyntax: provenance goes full-line
            // (the Assign arm indents each line of multi-line returns).
            if *zst {
                return format!("// zero-sized borrow (no storage)\n{} = 0", dest);
            }
            let mut lines = vec![];
            if *mut_ {
                lines.push("// mut-borrow (Phase1: & + Referee)".to_string());
            }
            if let Some(v) = via {
                lines.push(format!("// via {}", flat_comment(v)));
            }
            // Memory-resident aggregate local: `place` already names the
            // storage address, so `&place` is `place` (a `&place` would take
            // the address of the register holding the pointer).
            if *projected {
                // `&(*p).f` (or `&local.f`): interior address via ptr_add.
                lines.push(format!("{} = ptr_add {}, {}", dest, place, offset));
            } else if !*mut_ && ty.as_deref() != Some("ptr") {
                // A shared reference to a plain value: SA's `&x` reborrows the
                // POINTER in `x`, so a scalar reference needs the value in
                // memory. Copy it into a buffer and hand out its address
                // (the buffer is released with the borrow). A pointer-valued
                // place is already an address: `&x` is a reborrow of it.
                let sty = ty.clone().unwrap_or_else(|| "u64".to_string());
                let buf = format!("{}_refbuf", dest);
                lines.push(format!("mut {} = alloc 8", buf));
                lines.push(format!("store {}+0, {} as {}", buf, place, sty));
                lines.push(format!("{} = {}", dest, buf));
            } else if *agg {
                // Memory-resident aggregate: `place` already names the
                // storage address. Reload it from the owner's spill slot
                // when there is one: a plain copy would transfer the
                // allocation's ownership, so a second borrow of the same
                // owner would use a moved value.
                match spill.get(place) {
                    Some(t) => lines.push(format!(
                        "{} = load {}+0 as {}",
                        dest,
                        crate::spill::spill_slot(place),
                        t
                    )),
                    None => lines.push(format!("{} = {}", dest, place)),
                }
            } else {
                lines.push(format!("{} = &{}", dest, place));
            }
            // Spilled borrow temps keep a slot: their MIR Copy-uses reload,
            // so the later `drop(b)` still finds `b` bound.
            if let Some(t) = spill.get(dest) {
                let s = crate::spill::spill_slot(dest);
                lines.push(format!("mut {} = stack_alloc 8", s));
                lines.push(format!("store {}+0, {} as {}", s, dest, t));
            }
            lines.join("\n")
        }
        Rvalue::Call { func, args, sig, opt_shim, slice_len, negate_eq } => {
            // `PartialEq::ne`: call the local `eq` and negate.
            if let Some(eq_name) = negate_eq {
                let a: Vec<String> = args.iter().map(render_call_arg).collect();
                let tmp = format!("{}_ne", dest);
                return format!(
                    "{} = call @{}({})\n{} = ne {}, 0",
                    tmp,
                    eq_name,
                    a.join(", "),
                    dest,
                    tmp
                );
            }
            // `slice::len` / `str::len`: the fat pointer's length word.
            if let Some(sl) = slice_len {
                let recv = args
                    .first()
                    .map(|a| match a {
                        Operand::Move { place, .. } | Operand::Copy { place, .. } => place.clone(),
                        _ => "0".to_string(),
                    })
                    .unwrap_or_else(|| "0".to_string());
                return format!("{} = load {}+{} as u64", dest, recv, sl.len_off);
            }
            // `Option::is_some` / `is_none` / `unwrap_or`: inline the
            // discriminant test (std's symbol cannot run here).
            if let Some(sh) = opt_shim {
                if let Some(lines) = crate::layout::plan_option_shim(dest, bid, args, sh) {
                    return lines.join("\n");
                }
            }
            // `Range::rev()` builds a `Rev<Range<T>>`, a newtype over the
            // range: the adapter shares the range's storage, so it is the
            // identity here (the iteration direction is handled by the
            // `next` shim).
            if func.contains("as_std_iter_Iterator_rev") {
                let a: Vec<String> = args.iter().map(render_call_arg).collect();
                return format!("{} = {}", dest, a.first().cloned().unwrap_or_else(|| "0".to_string()));
            }
            if call_sig_loud(sig, args) {
                unsup.push(format!("{}:{} CallNoSig", bid, dest));
                return format!("// UNSUPPORTED call-sig -> {}: unresolvable callee signature", dest);
            }
            let (prelude, a) = render_call_args(args, spill, dest);
            let mut s = if prelude.is_empty() {
                String::new()
            } else {
                format!("{}\n", prelude.join("\n"))
            };
            s.push_str(&format!("{} = call @{}({})", dest, sa_ident(func), a.join(", ")));
            // Spilled call dests get their slot setup inline.
            if let Some(ty) = spill.get(dest) {
                let slot = crate::spill::spill_slot(dest);
                s.push_str(&format!("\nmut {} = stack_alloc 8\nstore {}+0, {} as {}", slot, slot, dest, ty));
            }
            s
        }
        Rvalue::BinOp { op, left, right, signed } => {
            // `*WithOverflow` yields a (value, flag) PAIR, which this backend
            // cannot hold in one register. rustc always follows it with an
            // `Assert(Overflow(..))` on the flag, so the value alone is what
            // the program observes: expand the sa_std/num.sal checked macro,
            // which computes the exact value and traps on overflow (the assert is
            // folded there, see lower.rs). Panic-on-overflow is Rust's
            // `overflow-checks` behaviour, not an invention.
            if let Some(helper) = checked_arith_helper(op) {
                let (pl, lt) = bind_move_operand(left, bid, mv_idx);
                let (pr, rt) = bind_move_operand(right, bid, mv_idx);
                let mut lines = pl;
                lines.extend(pr);
                lines.push(format!("EXPAND {} {}, {}, {}", helper, dest, lt, rt));
                return lines.join("\n");
            }
            let (pl, lt) = bind_move_operand(left, bid, mv_idx);
            let (pr, rt) = bind_move_operand(right, bid, mv_idx);
            match binop_mnemonic(op, signed.unwrap_or(true)) {
                Some(m) => {
                    let mut lines = pl;
                    lines.extend(pr);
                    lines.push(format!("{} = {} {}, {}", dest, m, lt, rt));
                    lines.join("\n")
                }
                None => {
                    unsup.push(format!("{}:{} BinOp-{}", bid, dest, op));
                    format!("// UNSUPPORTED binop -> {}: {}({}, {})", dest, op, flat_comment(&lt), flat_comment(&rt))
                }
            }
        }
        Rvalue::UnOp { op, operand } => {
            // Fat-pointer metadata lives at offset 8 of the (ptr,len) pair —
            // the same layout `slice.sal` uses for string fields — so the meta
            // read is an exact `load p+8` (no mnemonic exists for it).
            if *op == "PtrMetadata" {
                let mut idx = 0usize;
                let (pre, t) = bind_move_operand(operand, bid, &mut idx);
                let mut lines = pre;
                lines.push(format!("{} = load {}+8 as u64", dest, t));
                return lines.join("\n");
            }
            let mut idx = 0usize;
            let (pre, t) = bind_move_operand(operand, bid, &mut idx);
            match unop_mnemonic(op) {
                Some(m) => {
                    let mut lines = pre;
                    lines.push(format!("{} = {} {}", dest, m, t));
                    lines.join("\n")
                }
                None => {
                    unsup.push(format!("{}:{} UnOp-{}", bid, dest, op));
                    format!("// UNSUPPORTED unop -> {}: {}({})", dest, op, flat_comment(&t))
                }
            }
        }
        Rvalue::Cast { op, ty, castkind, src_ty, coerce } => {
            // An unsizing coercion `&[T; N]` -> `&[T]`: build the fat
            // pointer (data word + length) the target expects.
            if let Some(c) = coerce {
                let (size, len_off, len) = (c.size, c.len_off, c.len);
                let (pre, ot) = bind_move_operand(op, bid, mv_idx);
                let mut lines = pre;
                let fat = format!("{}_fat", dest);
                lines.push(format!("    mut {} = alloc {}", fat, size));
                lines.push(format!("    store {}+0, {} as ptr", fat, ot));
                lines.push(format!("    store {}+{}, {} as u64", fat, len_off, len));
                lines.push(format!("    {} = {}", dest, fat));
                return lines.join("\n");
            }
            let dst = cast_dst_short(ty);
            // Spilled sources reload instead of moving (pointer-copy chains
            // reuse one value 2-3 times, and a borrow temp must stay bound
            // for its own later `!b`; `sa check` traps the plain assign as
            // UseAfterMove / UnknownRegister).
            let reload = spill_reg(op, spill);
            let (mut pre, ot) = match &reload {
                Some(t) => (vec![], t.clone()),
                None => bind_move_operand(op, bid, mv_idx),
            };
            // SA emission type for conversions (`as TY`).
            let emit_ty = if dst == "ptr" {
                "ptr".to_string()
            } else {
                sa_scalar_ty(dst.trim()).to_string()
            };
            // Spilled cast dests get their slot setup here (same shape as the
            // repeat/aggregate synthetic bases).
            let slot = |pre: &mut Vec<String>| {
                if let Some(t) = spill.get(dest) {
                    let s = crate::spill::spill_slot(dest);
                    pre.push(format!("mut {} = stack_alloc 8", s));
                    pre.push(format!("store {}+0, {} as {}", s, dest, t));
                }
            };
            match (castkind.as_deref(), src_ty.as_deref()) {
                (Some(k), Some(s)) => match lower_cast(k, s, &dst) {
                    Some(CastLower::Copy) => {
                        pre.push(format!("{} = {}", dest, ot));
                        slot(&mut pre);
                        pre.join("\n")
                    }
                    Some(CastLower::Convert(m)) => {
                        // The conversion operand must be a REGISTER: a
                        // reload expression cannot be nested (`zext load ..
                        // as u8 as i32` is UnknownRegister, sla-201 shape),
                        // so bind the reload to a temp first.
                        match &reload {
                            Some(t) => {
                                let tmp = format!("_mv_{}_{}", bid, mv_idx);
                                *mv_idx += 1;
                                pre.push(format!("{} = {}", tmp, t));
                                pre.push(format!("{} = {} {} as {}", dest, m, tmp, emit_ty));
                            }
                            None => pre.push(format!("{} = {} {} as {}", dest, m, ot, emit_ty)),
                        }
                        slot(&mut pre);
                        pre.join("\n")
                    }
                    None => {
                        unsup.push(format!("{}:{} Cast-{}", bid, dest, k.split('(').next().unwrap_or(k)));
                        format!("// UNSUPPORTED cast -> {}: {} as {} (src {})", dest, flat_comment(&ot), flat_comment(ty), flat_comment(s))
                    }
                },
                // Old-schema fixture without kind fields: legacy loud path.
                _ => {
                    unsup.push(format!("{}:{} Cast", bid, dest));
                    format!("// UNSUPPORTED cast -> {}: {} as {}", dest, flat_comment(&ot), flat_comment(ty))
                }
            }
        }
        Rvalue::Discriminant { place, offset, ty, niche, niche_offset, none_variant, some_variant } => {
            // Tag may sit at a non-zero offset (rustc layout); the driver
            // resolves both the offset and the tag's integer width. Fall back
            // to the legacy `+0 as i64` when the driver could not.
            if *niche {
                // Niche tag (`Option<&T>`): the variant follows from the niche
                // field's value (null pointer => the niche variant).
                if *none_variant == 0 && *some_variant == 1 {
                    format!(
                        "// niche discriminant: 0 = null (None), 1 = payload (Some)\n{}_n = load {}+{} as ptr\n{} = ne {}_n, 0",
                        dest, place, niche_offset, dest, dest
                    )
                } else {
                    // Other niche shapes stay honest.
                    unsup.push(format!("{}:{} NicheDiscriminant", bid, dest));
                    format!("// UNSUPPORTED niche discriminant ({})\n{} = 0", place.trim(), dest)
                }
            } else {
                match ty {
                    Some(t) => format!("{} = load {}+{} as {}", dest, place, offset, t),
                    None => format!("{} = load {}+0 as i64", dest, place),
                }
            }
        }
        Rvalue::RawPtr { place, .. } => {
            // Thin-pointer reborrow is a plain copy (exact); fat cases stay
            // approximate under the base-local collapse (documented).
            format!("{} = {}", dest, place)
        }
        Rvalue::Repeat { op, len } => {
            match op.as_ref() {
                Operand::Const { value, .. } => match repeat_plan(value, len) {
                    Some((v, total)) => {
                        let mut s = format!(
                            "// repeat [{}; {}]\n_rep_{} = alloc {}\ncall @sa_mem_set(&_rep_{}, {}, {})\n{} = _rep_{}",
                            value, len, bid, total, bid, v, total, dest, bid
                        );
                        // Spilled repeat buffers get their slot setup here
                        // (same shape as aggregate bases).
                        let base = format!("_rep_{}", bid);
                        if let Some(ty) = spill.get(&base) {
                            let slot = crate::spill::spill_slot(&base);
                            s.push_str(&format!("\nmut {} = stack_alloc 8\nstore {}+0, {} as {}", slot, slot, base, ty));
                        }
                        s
                    }
                    None => {
                        unsup.push(format!("{}:{} Repeat", bid, dest));
                        format!("// UNSUPPORTED repeat -> {}: [{}; {}]", dest, render_operand(op), len)
                    }
                },
                _ => {
                    unsup.push(format!("{}:{} Repeat", bid, dest));
                    format!("// UNSUPPORTED repeat -> {}: [{}; {}] (non-const elem needs loop)", dest, render_operand(op), len)
                }
            }
        }

        Rvalue::ThreadLocal { def } => {
            // Lowered to the shared registry (sci/sa_std/thread_local.sai).
            format!("// thread-local registry slot\n{} = call @sa_thread_local_slot({})", dest, tls_key(def))
        }
        Rvalue::Aggregate { elems, layout, tag, niche_store, elem_tys } => {
            if elems.is_empty() && tag.is_none() && niche_store.is_none() {
                format!("// zero-elem aggregate (unit/niche; tag via SetDisc when present)\n{} = 0", dest)
            } else if elems.len() == 1 && tag.is_none() && niche_store.is_none() && layout.is_none() {
                // Spilled shared buffers reload like plain Uses.
                if let Some(t) = spill_reg(&elems[0], spill) {
                    return format!(
                        "// single-elem aggregate (spill reload)\n{} = {}",
                        dest, t
                    );
                }
                format!("// single-elem aggregate (exact)\n{} = {}", dest, render_operand(&elems[0]))
            } else if let Some(place) = dest_place {
                // Array fast path first (exact [T; N] all-const, incl. ManuallyDrop backing).
                if let Some(mut lines) = lower_array_init(bid, place, elems) {
                    crate::spill::spill_slot_lines(&mut lines, bid, spill);
                    lines.join("\n")
                } else if let Some(mut lines) = lower_adt_init(bid, dest, place, elems, layout.as_ref(), tag.as_ref(), niche_store.as_ref(), elem_tys.as_deref()) {
                    crate::spill::spill_slot_lines(&mut lines, bid, spill);
                    lines.join("\n")
                } else {
                    let e: Vec<String> = elems.iter().map(render_operand).collect();
                    unsup.push(format!("{}:{} Aggregate", bid, dest));
                    format!("// UNSUPPORTED multi-elem aggregate -> {} @ {}: {}",
                            dest, place.trim(), e.join(", "))
                }
            } else {
                let e: Vec<String> = elems.iter().map(render_operand).collect();
                unsup.push(format!("{}:{} Aggregate", bid, dest));
                format!("// UNSUPPORTED multi-elem aggregate -> {}: {}", dest, e.join(", "))
            }
        }
        Rvalue::Unsupported { text } => {
            unsup.push(format!("{}:{} Unsupported", bid, dest));
            format!("// UNSUPPORTED rvalue -> {}: {}", dest, text)
        }
    }
}