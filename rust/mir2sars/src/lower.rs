//! mir2sa::lower.
use std::process::ExitCode;

use crate::asm::{asm_inout_passthrough, asm_mov_copy, is_plain_local};
use crate::mir::*;
use crate::render::*;
use crate::render_util::{assert_panic_code, assign_loud_const, build_constmap, call_sig_loud, checked_arith_helper, const_needs_loud, diverging_panic_code, flat_comment, is_diverging_panic_call, is_overflow_assert, loud_const_kind, loud_operand_reason, render_call_arg, render_operand, sa_ident, sa_label, unreachable_panic_code};
use crate::spill::{build_spill_for, spill_slot};

/// Placeholder bind for loud paths: an unbound dest gets `= 0` so
/// downstream uses stay parseable (the function is already flagged loud).
/// Already-bound dests keep their first value (no-op here).
pub fn bind_placeholder(
    out: &mut Vec<String>,
    bound: &mut std::collections::BTreeSet<String>,
    dest: &Option<String>,
) {
    if let Some(d) = dest {
        if !bound.contains(d) {
            out.push(format!("    {} = 0", d));
            bound.insert(d.clone());
        }
    }
}

/// Mirror a placeholder bind into the spill slot (keeps reloads parseable).
/// No-op when the dest is not spilled.
pub fn spill_placeholder(
    out: &mut Vec<String>,
    spill: &crate::spill::SpillMap,
    dest: &Option<String>,
) {
    if let Some(d) = dest {
        if let Some(ty) = spill.get(d) {
            let slot = crate::spill::spill_slot(d);
            out.push(format!("    mut {} = stack_alloc 8", slot));
            out.push(format!("    store {}+0, {} as {}", slot, d, ty));
        }
    }
}

/// Map each register that is (or is a plain copy of) a by-value aggregate
/// param to that aggregate's byte size. A `_0 = <such reg>` return would
/// otherwise hand the caller a pointer to the caller's own argument storage,
/// which the caller then frees twice (once as the local, once as the result).
pub fn param_agg_sizes(f: &Function) -> std::collections::BTreeMap<String, u64> {
    let mut m: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
    for (i, _) in f.params.iter().enumerate() {
        m.insert(format!("_{}", i + 1), f.param_aggs.get(i).copied().unwrap_or(0));
    }
    let mut changed = true;
    while changed {
        changed = false;
        for b in &f.blocks {
            for st in &b.statements {
                if let Stmt::Assign { dest, rvalue, dest_proj: None, .. } = st {
                    let src = match rvalue {
                        Rvalue::Use { op } => match op {
                            Operand::Move { place, proj: None }
                            | Operand::Copy { place, proj: None } => Some(place.clone()),
                            Operand::Conflict { place, .. } => Some(place.clone()),
                            _ => None,
                        },
                        Rvalue::Ref { place, agg: true, .. } => Some(place.clone()),
                        _ => None,
                    };
                    if let Some(src) = src {
                        if let Some(&sz) = m.get(&src) {
                            if sz > 0 && !m.contains_key(dest) {
                                m.insert(dest.clone(), sz);
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
    }
    m
}

/// Registers a statement reads (value uses; the dest is not a use).
fn stmt_uses(st: &Stmt) -> Vec<String> {
    let mut out = Vec::new();
    match st {
        Stmt::Assign { dest_place, dest_proj, rvalue, .. } => {
            out.extend(rvalue_uses(rvalue));
            // A field store reads the base register; a plain assignment does
            // not read its own destination.
            if dest_proj.is_some() {
                if let Some(dp) = dest_place {
                    out.push(dp.clone());
                }
            }
        }
        Stmt::SetDisc { place, .. } => out.push(place.clone()),
        _ => {}
    }
    out
}

/// Collect the operand-level reads of an rvalue.
fn rvalue_uses(rv: &Rvalue) -> Vec<String> {
    let mut out = Vec::new();
    let mut push_op = |op: &Operand| {
        if let Operand::Move { place, .. } | Operand::Copy { place, .. } = op {
            out.push(place.clone());
        }
    };
    match rv {
        Rvalue::Use { op } => push_op(op),
        Rvalue::Call { args, .. } => args.iter().for_each(&mut push_op),
        Rvalue::BinOp { left, right, .. } => {
            push_op(left);
            push_op(right);
        }
        Rvalue::UnOp { operand, .. } => push_op(operand),
        Rvalue::Cast { op, .. } => push_op(op),
        Rvalue::Aggregate { elems, .. } => elems.iter().for_each(&mut push_op),
        Rvalue::Repeat { op, .. } => push_op(op),
        Rvalue::Ref { place, .. } | Rvalue::RawPtr { place, .. } => out.push(place.clone()),
        Rvalue::Discriminant { place, .. } => out.push(place.clone()),
        _ => {}
    }
    out
}

/// Registers a terminator reads (value uses; the call dest is a def).
fn term_uses(t: &Term) -> Vec<String> {
    let mut out = Vec::new();
    let mut push_op = |op: &Operand| {
        if let Operand::Move { place, .. } | Operand::Copy { place, .. } = op {
            out.push(place.clone());
        }
    };
    match t {
        Term::SwitchInt { discr, .. } => push_op(discr),
        Term::Call { args, .. } => args.iter().for_each(&mut push_op),
        Term::Assert { cond, .. } => push_op(cond),
        Term::Drop { place, .. } => out.push(place.clone()),
        Term::InlineAsm { ins, .. } => ins.iter().for_each(&mut push_op),
        _ => {}
    }
    out
}

/// Registers a statement reads, with whether the read consumes the register
/// (a Move/take ends the register's life: releasing it afterwards would
/// double-release).
fn stmt_uses_moves(st: &Stmt) -> Vec<(String, bool)> {
    let mut out: Vec<(String, bool)> = Vec::new();
    let mut push_op = |op: &Operand, consuming: bool| {
        match op {
            Operand::Move { place, .. } => out.push((place.clone(), consuming)),
            Operand::Copy { place, .. } => out.push((place.clone(), false)),
            _ => {}
        }
    };
    match st {
        Stmt::Assign { dest_place, dest_proj, rvalue, .. } => {
            match rvalue {
                Rvalue::Use { op } => push_op(op, true),
                Rvalue::Aggregate { elems, .. } => {
                    for e in elems {
                        push_op(e, true);
                    }
                }
                Rvalue::Cast { op, .. } => push_op(op, true),
                Rvalue::Ref { place, .. } | Rvalue::RawPtr { place, .. } => {
                    out.push((place.clone(), false))
                }
                Rvalue::Discriminant { place, .. } => out.push((place.clone(), false)),
                _ => {}
            }
            if dest_proj.is_some() {
                if let Some(dp) = dest_place {
                    out.push((dp.clone(), false));
                }
            }
        }
        Stmt::SetDisc { place, .. } => out.push((place.clone(), false)),
        _ => {}
    }
    out
}

/// Borrow temporaries (`Rvalue::Ref` of a non-aggregate place) hold a live
/// borrow. Rust ends a borrow at its last use; SA has no scopes, so the
/// borrow is released explicitly. Without the release the borrowed register
/// stays locked and a join that merges a borrowing path with a non-borrowing
/// one sees mismatched states (`PhiStateConflict`).
///
/// Returns `(block, statement) -> registers to release after that statement`.
fn plan_borrow_releases(
    f: &Function,
) -> std::collections::HashMap<(usize, usize), Vec<String>> {
    use std::collections::HashMap;
    // dest -> borrowed source, plus the statement that defines it.
    let mut borrow_src: HashMap<String, String> = HashMap::new();
    let mut borrow_def: HashMap<String, (usize, usize)> = HashMap::new();
    let mut borrowed_by: HashMap<String, Vec<String>> = HashMap::new();
    for (bi, b) in f.blocks.iter().enumerate() {
        for (si, st) in b.statements.iter().enumerate() {
            if let Stmt::Assign { dest, rvalue: Rvalue::Ref { place, agg, zst, mut_, projected, ty, .. }, .. } = st {
                // A shared borrow of a plain place lowers to a value copy
                // (a buffer, no lock) unless the place is pointer-valued
                // (then it is a real reborrow that locks the source).
                // Projected borrows lower to `ptr_add` (an interior
                // pointer): releasing one consumes its base, which would
                // poison the phi state, so they are left alone.
                if *mut_ || (!*projected && !*agg && !*zst && ty.as_deref() == Some("ptr")) {
                    // A mid-function release must be reached by every path
                    // that reaches a join, or the borrow's state differs
                    // there (`PhiStateConflict`). The release is therefore
                    // only planned when the borrow ends the function (its
                    // last use is the return); otherwise the exit free
                    // releases it.
                    borrow_src.insert(dest.clone(), place.clone());
                    borrow_def.insert(dest.clone(), (bi, si));
                    borrowed_by.entry(place.clone()).or_default().push(dest.clone());
                }
            }
        }
    }
    // Value uses per register. Statement sites use the statement index;
    // terminator uses use `usize::MAX` (nothing may follow a terminator, so
    // the release goes right after the terminator's call line).
    let mut uses: HashMap<String, Vec<(usize, usize)>> = HashMap::new();
    let mut consuming: HashMap<String, bool> = HashMap::new();
    for (bi, b) in f.blocks.iter().enumerate() {
        for (si, st) in b.statements.iter().enumerate() {
            for (u, c) in stmt_uses_moves(st) {
                uses.entry(u.clone()).or_default().push((bi, si));
                if c {
                    consuming.insert(u, true);
                }
            }
        }
        for u in term_uses(&b.terminator) {
            uses.entry(u).or_default().push((bi, usize::MAX));
        }
    }
    let mut out: HashMap<(usize, usize), Vec<String>> = HashMap::new();
    for (dest, src) in &borrow_src {
        // A borrow of a borrow is released together with its borrower.
        if borrowed_by.contains_key(dest) {
            continue;
        }
        let sites = uses.get(dest).cloned().unwrap_or_default();
        // A borrow whose last use consumes it (a take/move) is already
        // finished: releasing it again would double-release the register.
        if consuming.get(dest).copied().unwrap_or(false) {
            continue;
        }
        // A borrow release only clears the lock on the borrowed register (the
        // borrow view itself stays alive), so it is state-safe on every path:
        // the register is Active afterwards, and a join sees Active vs
        // Uninitialized (allowed). Releasing after the last use therefore
        // unblocks joins that merge a borrowing path with a plain one.
        let ends_function = sites
            .iter()
            .all(|(bi, _)| matches!(f.blocks[*bi].terminator, Term::Return { .. }));
        let _ = ends_function;
        let site = match sites.iter().max().cloned() {
            Some(s) => s,
            // Never read: release right where it was created.
            None => match borrow_def.get(dest) {
                Some(d) => *d,
                None => continue,
            },
        };
        // Chain: the borrow and the borrow(s) it holds, released outermost
        // first (releasing an inner borrow while it is still borrowed traps).
        let mut chain = vec![dest.clone()];
        let mut cur = src.clone();
        let mut guard = 0;
        while let Some(s) = borrow_src.get(&cur) {
            chain.push(cur.clone());
            cur = s.clone();
            guard += 1;
            if guard > 8 {
                break;
            }
        }
        // Inner members must be dead at the release point.
        let mut keep: Vec<String> = Vec::new();
        for (i, m) in chain.iter().enumerate() {
            if i == 0 {
                keep.push(m.clone());
                continue;
            }
            let later = uses
                .get(m)
                .map(|v| v.iter().any(|s| *s > site))
                .unwrap_or(false);
            if !later {
                keep.push(m.clone());
            }
        }
        out.entry(site).or_default().extend(keep);
    }
    out
}

/// A derived `PartialEq` comparison inlined into a value compare.
///
/// Rust's derived `PartialEq` for primitives calls
/// `<T as std::cmp::PartialEq>::eq`, a std function the SA runtime cannot
/// provide. When both arguments are borrows of a projected field, the
/// comparison is exactly a compare of the two field values, so it is
/// inlined: load both fields and compare.
struct InlineEq {
    left: (String, u64, String),
    right: (String, u64, String),
    ne: bool,
}

/// Resolve a borrow of a projected field to `(base, offset, type)`: the
/// value the borrow designates.
fn resolve_borrow_field(
    defs: &std::collections::HashMap<String, Rvalue>,
    place: &str,
) -> Option<(String, u64, String)> {
    let Rvalue::Ref {
        place: q,
        projected: false,
        agg: false,
        zst: false,
        ..
    } = defs.get(place)?
    else {
        return None;
    };
    let Rvalue::Ref {
        place: r,
        offset,
        projected: true,
        ty: Some(t),
        ..
    } = defs.get(q)?
    else {
        return None;
    };
    Some((r.clone(), *offset, t.clone()))
}

/// Plan the inlined primitive comparisons of one function: block index ->
/// comparison, plus the registers whose borrow statements become dead (they
/// are skipped so no borrow/interior pointer is materialized).
fn plan_inline_eq(
    f: &Function,
) -> (
    std::collections::HashMap<usize, InlineEq>,
    std::collections::HashSet<String>,
) {
    use std::collections::{HashMap, HashSet};
    let mut defs: HashMap<String, Rvalue> = HashMap::new();
    for b in &f.blocks {
        for st in &b.statements {
            if let Stmt::Assign { dest, rvalue, .. } = st {
                if matches!(rvalue, Rvalue::Ref { .. }) {
                    defs.insert(dest.clone(), rvalue.clone());
                }
            }
        }
    }
    // Use counts (statements + terminators): a borrow may only be skipped
    // when the inlined call is its single user.
    let mut uses: HashMap<String, usize> = HashMap::new();
    for b in &f.blocks {
        for st in &b.statements {
            for u in stmt_uses(st) {
                *uses.entry(u).or_insert(0) += 1;
            }
        }
        for u in term_uses(&b.terminator) {
            *uses.entry(u).or_insert(0) += 1;
        }
    }
    let mut calls: HashMap<usize, InlineEq> = HashMap::new();
    let mut skip: HashSet<String> = HashSet::new();
    for (bi, b) in f.blocks.iter().enumerate() {
        let Term::Call { func, func_raw, args, .. } = &b.terminator else {
            continue;
        };
        let raw = func_raw.clone().unwrap_or_default();
        if !raw.contains("std::cmp::PartialEq") && !func.contains("as_std_cmp_PartialEq") {
            continue;
        }
        let ne = raw.contains("PartialEq::ne") || func.ends_with("_ne");
        if args.len() != 2 {
            continue;
        }
        let mut resolved = [None, None];
        for (i, arg) in args.iter().enumerate() {
            let place = match arg {
                Operand::Move { place, .. } | Operand::Copy { place, .. } => place,
                _ => {
                    resolved = [None, None];
                    break;
                }
            };
            let r = resolve_borrow_field(&defs, place);
            if r.is_none() {
                resolved = [None, None];
                break;
            }
            resolved[i] = r;
        }
        let (Some(l), Some(r)) = (resolved[0].clone(), resolved[1].clone()) else {
            continue;
        };
        if l.2 != r.2 {
            continue;
        }
        // The borrows feeding the comparison become dead.
        let mut dead = true;
        for arg in args.iter() {
            if let Operand::Move { place, .. } | Operand::Copy { place, .. } = arg {
                if uses.get(place).copied().unwrap_or(0) != 1 {
                    dead = false;
                }
                if let Some(Rvalue::Ref { place: q, .. }) = defs.get(place) {
                    if uses.get(q).copied().unwrap_or(0) != 1 {
                        dead = false;
                    }
                }
            }
        }
        if !dead {
            continue;
        }
        for arg in args.iter() {
            if let Operand::Move { place, .. } | Operand::Copy { place, .. } = arg {
                skip.insert(place.clone());
                if let Some(Rvalue::Ref { place: q, .. }) = defs.get(place) {
                    skip.insert(q.clone());
                }
            }
        }
        calls.insert(bi, InlineEq { left: l, right: r, ne });
    }
    (calls, skip)
}

/// Materialize projected reads inside composite rvalues.
///
/// SA has no nested load expressions in value positions, so a field read used
/// by an arithmetic op or a call argument (`*w * *h`) must be loaded into a
/// temp first. Plain assignments already lower a projected read to a load.
fn materialize_projected_operands(f: &Function) -> Function {
    let mut out = f.clone();
    for bi in 0..out.blocks.len() {
        let mut stmts: Vec<Stmt> = Vec::with_capacity(out.blocks[bi].statements.len());
        let mut counter = 0usize;
        for st in out.blocks[bi].statements.drain(..) {
            let dest = match &st {
                Stmt::Assign { dest, .. } => dest.clone(),
                _ => String::new(),
            };
            let mut prelude: Vec<Stmt> = Vec::new();
            let mut st2 = st;
            if let Stmt::Assign { rvalue, .. } = &mut st2 {
                let mut ops: Vec<&mut Operand> = match rvalue {
                    Rvalue::BinOp { left, right, .. } => vec![left.as_mut(), right.as_mut()],
                    Rvalue::UnOp { operand, .. } => vec![operand.as_mut()],
                    Rvalue::Cast { op, .. } => vec![op.as_mut()],
                    Rvalue::Call { args, .. } => args.iter_mut().collect(),
                    Rvalue::Aggregate { elems, .. } => elems.iter_mut().collect(),
                    _ => vec![],
                };
                for op in ops.into_iter() {
                    let pj = match op.proj() {
                        Some(p) => p.clone(),
                        None => continue,
                    };
                    let base = match op {
                        Operand::Move { place, .. } | Operand::Copy { place, .. } => place.clone(),
                        _ => continue,
                    };
                    let tmp = format!("{}_p{}", dest, counter);
                    counter += 1;
                    prelude.push(Stmt::Assign {
                        dest: tmp.clone(),
                        dest_place: None,
                        dest_proj: None,
                        rvalue: Rvalue::Use {
                            op: Operand::Copy {
                                place: base,
                                proj: Some(pj),
                            },
                        },
                    });
                    *op = Operand::Copy {
                        place: tmp,
                        proj: None,
                    };
                }
            }
            stmts.extend(prelude);
            stmts.push(st2);
        }
        // Terminator operands (switch discriminant, call args, assert cond).
        let mut prelude: Vec<Stmt> = Vec::new();
        let mut counter = 0usize;
        {
            let mut ops: Vec<&mut Operand> = match &mut out.blocks[bi].terminator {
                Term::SwitchInt { discr, .. } => vec![discr.as_mut()],
                Term::Call { args, .. } => args.iter_mut().collect(),
                // An overflow assert is folded (the checked macro traps), so
                // its condition is never read: materializing it would copy
                // the checked-arithmetic result and consume it.
                Term::Assert { cond, msg, .. }
                    if !crate::render_util::is_overflow_assert(msg.as_deref().unwrap_or("")) =>
                {
                    vec![cond.as_mut()]
                }
                _ => vec![],
            };
            for op in ops.into_iter() {
                let pj = match op.proj() {
                    Some(p) => p.clone(),
                    None => continue,
                };
                let base = match op {
                    Operand::Move { place, .. } | Operand::Copy { place, .. } => place.clone(),
                    _ => continue,
                };
                let tmp = format!("_t{}_p{}", bi, counter);
                counter += 1;
                prelude.push(Stmt::Assign {
                    dest: tmp.clone(),
                    dest_place: None,
                    dest_proj: None,
                    rvalue: Rvalue::Use {
                        op: Operand::Copy {
                            place: base,
                            proj: Some(pj),
                        },
                    },
                });
                *op = Operand::Copy {
                    place: tmp,
                    proj: None,
                };
            }
        }
        stmts.extend(prelude);
        out.blocks[bi].statements = stmts;
    }
    out
}

/// Layout facts for a `for` loop over `Range<T>`: the iterator shim reads
/// the range's cursor/end fields and builds the `Option<(T,)>` result.
#[derive(Clone)]
struct IterNextCtx {
    cur_off: u64,
    end_off: u64,
    tag_off: u64,
    tag_ty: String,
    payload_off: u64,
    payload_ty: String,
    signed: bool,
    /// `Rev<Range<T>>` iterates downwards: the cursor is the upper bound and
    /// the payload is `cursor - 1`.
    descending: bool,
}

/// True for std's `IntoIterator::into_iter` on a range.
fn is_into_iter_call(func: &str) -> bool {
    func.contains("as_std_iter_IntoIterator_into_iter")
}

/// True for std's `Iterator::next` on a range.
fn is_next_call(func: &str) -> bool {
    func.contains("as_std_iter_Iterator_next")
}

/// Collect the layout facts a range iterator shim needs: the range's field
/// offsets (from the aggregate that feeds `into_iter`), the `Option` tag
/// (from the discriminant read) and its payload (the projected read).
/// Also returns the registers to skip (the `&mut self` borrow temp: copying
/// it would consume the iterator, which the loop carries across iterations)
/// and the iterator register to use instead.
fn find_iter_ctx(f: &Function) -> Option<(IterNextCtx, std::collections::HashSet<String>, String)> {
    // The range aggregate: the argument of the `into_iter` call.
    let mut range_offsets: Option<Vec<u64>> = None;
    let mut elem_ty = "i32".to_string();
    for b in &f.blocks {
        for st in &b.statements {
            if let Stmt::Assign { rvalue: Rvalue::Aggregate { layout, elem_tys, .. }, .. } = st {
                if let Some(l) = layout {
                    if l.offsets.len() >= 2 {
                        range_offsets = Some(l.offsets.clone());
                        if let Some(ts) = elem_tys {
                            if let Some(t) = ts.first() {
                                elem_ty = t.clone();
                            }
                        }
                    }
                }
            }
        }
    }
    let offsets = range_offsets?;
    // The `Option` tag: the discriminant read.
    let mut tag = None;
    let mut payload = None;
    for b in &f.blocks {
        for st in &b.statements {
            match st {
                Stmt::Assign { rvalue: Rvalue::Discriminant { offset, ty, .. }, .. } => {
                    if let Some(t) = ty {
                        tag = Some((*offset, t.clone()));
                    }
                }
                Stmt::Assign { rvalue: Rvalue::Use { op }, .. } => {
                    if let Some(pj) = op.proj() {
                        // The payload read is the projected one that names the
                        // `Some` variant (`((_6 as Some).0: i32)`).
                        if let Some(via) = &pj.via {
                            if via.contains("Some") {
                                payload = Some((pj.offset, pj.ty.clone()));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    let (tag_off, tag_ty) = tag?;
    // The payload read is absent when the loop body ignores the value
    // (`for _ in 0..n`): the shim still stores the cursor (harmless).
    let (payload_off, payload_ty) = payload.unwrap_or((tag_off + 4, elem_ty.clone()));
    // The `next` call's argument: a `&mut self` borrow temp over the
    // iterator local. The borrow temp is skipped (its copy would consume the
    // loop-carried iterator) and the iterator register is used directly.
    let mut skip = std::collections::HashSet::new();
    let mut iter_reg = String::new();
    let mut descending = false;
    for b in &f.blocks {
        if let Term::Call { func, args, .. } = &b.terminator {
            if !is_next_call(func) {
                continue;
            }
            descending = func.contains("Rev") || func.contains("rev");
            let arg_place = match args.first() {
                Some(Operand::Move { place, .. }) | Some(Operand::Copy { place, .. }) => {
                    place.clone()
                }
                _ => continue,
            };
            for bb in &f.blocks {
                for st in &bb.statements {
                    if let Stmt::Assign { dest, rvalue: Rvalue::Ref { place, agg, .. }, .. } = st {
                        if *dest == arg_place && *agg {
                            skip.insert(dest.clone());
                            iter_reg = place.clone();
                        }
                    }
                }
            }
        }
    }
    if iter_reg.is_empty() {
        return None;
    }
    Some((
        IterNextCtx {
            cur_off: offsets[0],
            end_off: offsets[1],
            tag_off,
            tag_ty,
            payload_off,
            payload_ty,
            signed: elem_ty.starts_with('i'),
            descending,
        },
        skip,
        iter_reg,
    ))
}

/// A join-ambiguous local (`Operand::Conflict`) lowered through a stack slot:
/// versions are stored on the incoming frontier, the use site loads the slot.
struct JoinSlot {
    slot: String,
    ty: String,
    /// (frontier block, version register to store) pairs.
    frontier: Vec<(usize, String)>,
    /// Use site (block index) replaced by a slot load.
    use_block: usize,
    local: String,
    /// The projection the joined read had (a field read): the slot holds the
    /// base address, so the read loads it before adding the offset.
    proj: Option<PlaceProj>,
    /// A discriminant read: the tag's byte offset and its SA type. The slot
    /// holds the tag (computed per path), not the local's value.
    discr: Option<(u64, String)>,
}

fn is_scalar_ty(t: &str) -> bool {
    matches!(
        t,
        "i8" | "i16" | "i32" | "i64" | "isize" | "u8" | "u16" | "u32" | "u64" | "usize"
            | "f32" | "f64" | "char" | "ptr"
    )
}

/// The projection a conflicted read had (a field read keeps its offset).
fn conflict_proj(op: &Operand) -> Option<PlaceProj> {
    match op {
        Operand::Conflict { proj, .. } => proj.clone(),
        _ => None,
    }
}

fn op_if_conflict(op: &Operand) -> Option<&str> {
    match op {
        Operand::Conflict { place, .. } => Some(place),
        _ => None,
    }
}

fn conflict_ops(st: &Stmt) -> Vec<&Operand> {
    match st {
        Stmt::Assign { rvalue, .. } => match rvalue {
            Rvalue::Use { op } => vec![op],
            Rvalue::Call { args, .. } => args.iter().collect(),
            Rvalue::BinOp { left, right, .. } => vec![left.as_ref(), right.as_ref()],
            Rvalue::UnOp { operand, .. } => vec![operand.as_ref()],
            Rvalue::Cast { op, .. } => vec![op.as_ref()],
            Rvalue::Aggregate { elems, .. } => elems.iter().collect(),
            Rvalue::Repeat { op, .. } => vec![op.as_ref()],
            _ => vec![],
        },
        _ => vec![],
    }
}

fn conflict_ops_term(t: &Term) -> Vec<&Operand> {
    match t {
        Term::SwitchInt { discr, .. } => vec![discr.as_ref()],
        Term::Call { args, .. } => args.iter().collect(),
        Term::Assert { cond, .. } => vec![cond.as_ref()],
        Term::InlineAsm { ins, .. } => ins.iter().collect(),
        _ => vec![],
    }
}

fn conflict_ops_mut(st: &mut Stmt) -> Vec<&mut Operand> {
    match st {
        Stmt::Assign { rvalue, .. } => match rvalue {
            Rvalue::Use { op } => vec![op],
            Rvalue::Call { args, .. } => args.iter_mut().collect(),
            Rvalue::BinOp { left, right, .. } => vec![left.as_mut(), right.as_mut()],
            Rvalue::UnOp { operand, .. } => vec![operand.as_mut()],
            Rvalue::Cast { op, .. } => vec![op.as_mut()],
            Rvalue::Aggregate { elems, .. } => elems.iter_mut().collect(),
            Rvalue::Repeat { op, .. } => vec![op.as_mut()],
            _ => vec![],
        },
        _ => vec![],
    }
}

fn conflict_ops_term_mut(t: &mut Term) -> Vec<&mut Operand> {
    match t {
        Term::SwitchInt { discr, .. } => vec![discr.as_mut()],
        Term::Call { args, .. } => args.iter_mut().collect(),
        Term::Assert { cond, .. } => vec![cond.as_mut()],
        Term::InlineAsm { ins, .. } => ins.iter_mut().collect(),
        _ => vec![],
    }
}

/// Nearest versioned definition of `local` in block `p` (or the block itself).
fn version_def(blocks: &[Block], p: usize, local: &str) -> Option<String> {
    let vp = format!("{}_v", local);
    let b = &blocks[p];
    for st in b.statements.iter().rev() {
        if let Stmt::Assign { dest, dest_proj: None, .. } = st {
            if dest == local || dest.starts_with(&vp) {
                return Some(dest.clone());
            }
        }
    }
    if let Term::Call { dest: Some(d), .. } = &b.terminator {
        if d == local || d.starts_with(&vp) {
            return Some(d.clone());
        }
    }
    None
}

/// Collect the version-defining frontier that reaches `u` for `local`.
fn join_frontier(
    preds: &[Vec<usize>],
    blocks: &[Block],
    u: usize,
    local: &str,
) -> Option<Vec<(usize, String)>> {
    use std::collections::HashSet;
    let mut out = Vec::new();
    let mut seen: HashSet<usize> = HashSet::new();
    let mut stack: Vec<usize> = preds.get(u).cloned().unwrap_or_default();
    if stack.is_empty() {
        return None;
    }
    while let Some(p) = stack.pop() {
        if !seen.insert(p) {
            continue;
        }
        if let Some(ver) = version_def(blocks, p, local) {
            out.push((p, ver));
            continue;
        }
        let ps = preds.get(p)?;
        if ps.is_empty() {
            // Reached the entry without a definition on this path.
            return None;
        }
        stack.extend(ps.iter().copied());
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Plan stack-slot routing for join-ambiguous scalar locals.
fn plan_join_slots(f: &Function) -> Vec<JoinSlot> {
    use std::collections::{HashMap, HashSet};
    let idx: HashMap<&str, usize> = f
        .blocks
        .iter()
        .enumerate()
        .map(|(i, b)| (b.id.as_str(), i))
        .collect();
    let mut preds: Vec<Vec<usize>> = vec![Vec::new(); f.blocks.len()];
    for (pi, b) in f.blocks.iter().enumerate() {
        let mut add = |t: &str| {
            if let Some(&ti) = idx.get(t) {
                preds[ti].push(pi);
            }
        };
        match &b.terminator {
            Term::Goto { target } => add(target),
            Term::SwitchInt { targets, otherwise, .. } => {
                for (_, t) in targets {
                    add(t);
                }
                add(otherwise);
            }
            Term::Call { target: Some(t), .. } => add(t),
            Term::Assert { target, .. } => add(target),
            Term::Drop { target, .. } => add(target),
            Term::InlineAsm { target: Some(t), .. } => add(t),
            _ => {}
        }
    }
    let types = crate::spill::place_types(f);
    let mut sites: Vec<(usize, String, Option<PlaceProj>)> = Vec::new();
    // Discriminant reads of a join-ambiguous local: the tag differs per
    // path, so the read is routed through a slot holding the tag.
    let mut discr_sites: Vec<(usize, String, u64, String)> = Vec::new();
    for (bi, b) in f.blocks.iter().enumerate() {
        for st in &b.statements {
            if let Stmt::Assign { rvalue: Rvalue::Discriminant { place, offset, ty, niche, .. }, .. } = st {
                if !*niche {
                    if let (Some(local), Some(ty)) = (place.strip_suffix("__CONFLICT"), ty.as_ref()) {
                        discr_sites.push((bi, local.to_string(), *offset, ty.clone()));
                    }
                }
            }
            for op in conflict_ops(st) {
                if let Some(p) = op_if_conflict(op) {
                    sites.push((bi, p.to_string(), conflict_proj(op)));
                }
            }
        }
        for op in conflict_ops_term(&b.terminator) {
            if let Some(p) = op_if_conflict(op) {
                sites.push((bi, p.to_string(), conflict_proj(op)));
            }
        }
    }
    let mut seen: HashSet<(usize, String)> = HashSet::new();
    let mut out = Vec::new();
    for (u, local, proj) in sites {
        if !seen.insert((u, local.clone())) {
            continue;
        }
        let frontier = match join_frontier(&preds, &f.blocks, u, &local) {
            Some(x) if !x.is_empty() => x,
            _ => continue,
        };
        let mut ty: Option<String> = None;
        let mut ok = true;
        for (_, ver) in &frontier {
            match types.get(ver) {
                Some(t) if is_scalar_ty(t) => match &ty {
                    Some(prev) if prev != t => {
                        ok = false;
                        break;
                    }
                    None => ty = Some(t.clone()),
                    _ => {}
                },
                _ => {
                    ok = false;
                    break;
                }
            }
        }
        if !ok {
            continue;
        }
        out.push(JoinSlot {
            slot: format!("{}_phi{}_spill", local, u),
            ty: ty.unwrap(),
            frontier,
            use_block: u,
            local,
            discr: None,
            proj,
        });
    }
    for (u, local, offset, tag_ty) in discr_sites {
        if !seen.insert((u, local.clone())) {
            continue;
        }
        let frontier = match join_frontier(&preds, &f.blocks, u, &local) {
            Some(x) if !x.is_empty() => x,
            _ => continue,
        };
        out.push(JoinSlot {
            slot: format!("{}_dtag{}_spill", local, u),
            ty: tag_ty.clone(),
            frontier,
            use_block: u,
            local,
            discr: Some((offset, tag_ty)),
            proj: None,
        });
    }
    out
}

/// Replace planned `Operand::Conflict` uses with slot loads.
fn apply_join_slots(f: &mut Function, plans: &[JoinSlot]) {
    use std::collections::{HashMap, HashSet};
    let planned: HashSet<(usize, String)> =
        plans.iter().map(|p| (p.use_block, p.local.clone())).collect();
    let by_site: HashMap<(usize, String), &JoinSlot> = plans
        .iter()
        .map(|p| ((p.use_block, p.local.clone()), p))
        .collect();
    for bi in 0..f.blocks.len() {
        let mut rewrite = |op: &mut Operand| {
            if let Operand::Conflict { place, .. } = op {
                if planned.contains(&(bi, place.clone())) {
                    let plan = by_site.get(&(bi, place.clone())).unwrap();
                    // A field read of the joined value: the slot holds the
                    // base address, so it is loaded before the offset.
                    let pj = conflict_proj(op);
                    *op = Operand::Copy {
                        place: plan.slot.clone(),
                        proj: Some(match pj {
                            Some(p) => PlaceProj {
                                offset: p.offset,
                                ty: p.ty.clone(),
                                via: p.via.clone(),
                                index: p.index.clone(),
                                deref_base: true,
                            },
                            None => PlaceProj {
                                offset: 0,
                                ty: plan.ty.clone(),
                                via: None,
                                index: None,
                                deref_base: false,
                            },
                        }),
                    };
                }
            }
        };
        for st in f.blocks[bi].statements.iter_mut() {
            // A join-ambiguous discriminant reads the tag from the slot.
            if let Stmt::Assign { rvalue: Rvalue::Discriminant { place, offset, ty, .. }, .. } = st {
                if let Some(local) = place.strip_suffix("__CONFLICT") {
                    if let Some(plan) = plans
                        .iter()
                        .find(|p| p.use_block == bi && p.local == local && p.discr.is_some())
                    {
                        *place = plan.slot.clone();
                        *offset = 0;
                        *ty = Some(plan.ty.clone());
                    }
                }
            }
            for op in conflict_ops_mut(st) {
                rewrite(op);
            }
        }
        for op in conflict_ops_term_mut(&mut f.blocks[bi].terminator) {
            rewrite(op);
        }
    }
}

/// Return-phi plan: see `lower_function`. Returns the join block indices
/// lowered via the shared slot, plus `pred -> _0-version` stores to emit
/// before the unconditional jump into a join.
fn plan_return_phi(
    f: &Function,
) -> (std::collections::HashSet<usize>, std::collections::HashMap<usize, String>) {
    use std::collections::{HashMap, HashSet};
    let idx: HashMap<&str, usize> = f
        .blocks
        .iter()
        .enumerate()
        .map(|(i, b)| (b.id.as_str(), i))
        .collect();
    let mut preds: HashMap<usize, Vec<(usize, bool)>> = HashMap::new();
    for (pi, b) in f.blocks.iter().enumerate() {
        let mut add = |t: &str, uncond: bool| {
            if let Some(&ti) = idx.get(t) {
                preds.entry(ti).or_default().push((pi, uncond));
            }
        };
        match &b.terminator {
            Term::Goto { target } => add(target, true),
            // A call with a target always continues to it (unless it
            // diverges), so the edge is unconditional.
            Term::Call { target: Some(t), .. } => add(t, true),
            Term::SwitchInt { targets, otherwise, .. } => {
                for (_, t) in targets {
                    add(t, false);
                }
                add(otherwise, false);
            }
            Term::Call { target: Some(t), .. } => add(t, false),
            Term::Assert { target, .. } => add(target, false),
            Term::Drop { target, .. } => add(target, false),
            Term::InlineAsm { target: Some(t), .. } => add(t, false),
            _ => {}
        }
    }
    let mut joins = HashSet::new();
    let mut pred_ret = HashMap::new();
    for (bi, b) in f.blocks.iter().enumerate() {
        if !matches!(&b.terminator, Term::Return { ret: Some(r) } if r == "__VERSION_CONFLICT__") {
            continue;
        }
        let ps = match preds.get(&bi) {
            Some(p) if !p.is_empty() => p,
            _ => continue,
        };
        if ps.iter().any(|(_, uncond)| !*uncond) {
            continue;
        }
        let mut map = HashMap::new();
        let mut ok = true;
        for (pi, _) in ps {
            let pb = &f.blocks[*pi];
            let reg = pb
                .statements
                .iter()
                .rev()
                .find_map(|st| match st {
                    Stmt::Assign { dest, dest_proj: None, .. } if dest.starts_with("_0") => {
                        Some(dest.clone())
                    }
                    _ => None,
                })
                .or_else(|| match &pb.terminator {
                    Term::Call { dest: Some(d), .. } if d.starts_with("_0") => Some(d.clone()),
                    _ => None,
                });
            match reg {
                Some(r) => {
                    map.insert(*pi, r);
                }
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if ok {
            joins.insert(bi);
            pred_ret.extend(map);
        }
    }
    (joins, pred_ret)
}

pub fn lower_function(f: &Function, unsup: &mut Vec<String>) -> String {
    // Join-ambiguous scalar locals (`Operand::Conflict` from version.rs) are
    // routed through a per-use stack slot: versions stored on the frontier,
    // a slot load at the use. Rewrite first so rendering stays unaware.
    let join_slots = plan_join_slots(f);
    let mut owned = f.clone();
    if !join_slots.is_empty() {
        apply_join_slots(&mut owned, &join_slots);
    }
    // Projected reads in value positions become loads into temps.
    let owned = materialize_projected_operands(&owned);
    let f = &owned;
    // Typed header: MIR arg locals `_1..` bind here (bare `@f()` would leave
    // them unbound: UnknownRegister). Ret defaults to i32 (old fixtures).
    let mut head = format!("@{}(", sa_ident(&f.name));
    for (i, t) in f.params.iter().enumerate() {
        if i > 0 {
            head.push_str(", ");
        }
        head.push_str(&format!("_{}: {}", i + 1, t));
    }
    head.push_str(&format!(") -> {}:", f.ret.as_deref().unwrap_or("i32")));
    let mut out = vec![head];
    // Unrepresentable signature parts fall back to `ptr` above: counted loud
    // here to mirror coverage (parse-clean output, honest accounting).
    if !f.sig_ok {
        unsup.push("FnSig".to_string());
        out.push("    // UNSUPPORTED fn-sig: unrepresentable param/return type (ptr fallback)".to_string());
    }
    // `match`-arm joins that return `_0` have two reaching versions and no
    // phi in SA. When every predecessor reaches the join unconditionally and
    // defines a `_0` version, route it through one stack slot (return-phi).
    let (ret_joins, pred_ret) = plan_return_phi(f);
    if !ret_joins.is_empty() {
        out.push("    mut _ret_phi_spill = stack_alloc 8".to_string());
    }
    // Borrow temporaries are released after their last use (see
    // `plan_borrow_releases`): SA has no lexical scopes, and a still-locked
    // borrow makes a later join see mismatched states.
    let borrow_releases = plan_borrow_releases(f);
    // Value types of every local (used by the join-slot type check).
    let _borrow_types = crate::spill::place_types(f);
    // Derived `PartialEq` on primitives: inlined as a value compare (std's
    // `PartialEq::eq` is not runnable here).
    let (inline_eq, inline_skip) = plan_inline_eq(f);
    // `for i in a..b`: the range iterator protocol is inlined.
    let (iter_ctx, iter_skip, iter_reg) = match find_iter_ctx(f) {
        Some((c, s, r)) => (Some(c), s, r),
        None => (None, std::collections::HashSet::new(), String::new()),
    };
    let mut block_stores: std::collections::HashMap<usize, Vec<(String, String, String)>> =
        std::collections::HashMap::new();
    // Discriminant slots hold the TAG (computed per path), not the local's
    // value: the frontier loads the tag from the path's version first.
    let mut discr_stores: std::collections::HashMap<usize, Vec<(String, String, u64, String)>> =
        std::collections::HashMap::new();
    for p in &join_slots {
        out.push(format!("    mut {} = stack_alloc 8", p.slot));
        for (fb, ver) in &p.frontier {
            match p.discr.as_ref() {
                Some((offset, tag_ty)) => {
                    discr_stores
                        .entry(*fb)
                        .or_default()
                        .push((p.slot.clone(), ver.clone(), *offset, tag_ty.clone()));
                }
                None => {
                    block_stores
                        .entry(*fb)
                        .or_default()
                        .push((p.slot.clone(), ver.clone(), p.ty.clone()));
                }
            }
        }
    }
    // RPO emission order (see order.rs): SA checks def-before-use textually.
    // Bound seeds come from dominators (see order::dom_seeds): a rebind of
    // a seeded dest is a same-path redefinition and goes loud.
    let seeds = crate::order::dom_seeds(&f.blocks, f.params.len());
    // Borrow-end plan (see borrow_end.rs): NLL-dead borrowers end just
    // before their source is dropped. Pure MIR-level, shared with coverage.
    let doms = crate::order::dom_sets(&f.blocks);
    let borrow_plan = crate::borrow_end::plan_drops(&f.blocks, &doms);
    // Block line ranges (for drop-glue insertion afterwards).
    let mut block_ranges: Vec<(usize, usize, usize)> = vec![];
    // Const-propagation map (RPO order: defs precede dominated uses).
    // Literals re-materialize at use sites instead of moving shared temps.
    let order = crate::order::rpo_order(&f.blocks);
    let mut cmap = build_constmap(
        order
            .iter()
            .flat_map(|bi| f.blocks[*bi].statements.iter().map(move |st| (f.blocks[*bi].id.as_str(), st))),
    );
    // Spill map for multi-use shared values (reload slots instead of
    // moving shared temps twice). Built over MIR statements once.
    let spill = build_spill_for(f);
    // Locals defined but never read: a byte-literal store into one of them
    // would allocate a payload nobody can free (see spill::dead_locals).
    let dead = crate::spill::dead_locals(&f.blocks, f.params.len());
    // Block ranges close when the NEXT block starts, never inside the loop:
    // a loud terminator arm `continue`s, and its lines still define registers
    // that drop.rs must see (missing them under-freed every exit, which the
    // Referee reports as a leak as soon as a register holds a real
    // allocation). Opening here keeps the range closable after a `continue`.
    let mut open_block: Option<usize> = None;
    // Checked `*WithOverflow` dests hold a bare scalar: the `EXPAND` macro
    // already traps on overflow, so the (value, flag) tuple's projections
    // (`_d.0`, `_d.1`) must collapse back onto `_d`, never `load _d+off`.
    let mut scalarized: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Aggregate param/alias byte sizes: a `_0 = <alias>` return copies out
    // instead of sharing the caller's argument storage.
    let param_aggs = param_agg_sizes(f);
    let mut block_start = vec![0usize; f.blocks.len()];
    for bi in order {
        let b = &f.blocks[bi];
        let start = out.len();
        if let Some(prev) = open_block.take() {
            block_ranges.push((prev, block_start[prev], out.len()));
        }
        block_start[bi] = start;
        out.push(format!("{}:", sa_label(&b.id)));
        open_block = Some(bi);
        // Per-block bound set: repeats go loud and keep the first value
        // (skip the line). Exclusive-branch joins stay legal (never seeded).
        let mut bound = seeds[bi].clone();
        let mut mv_idx = 0usize;
        for (si, st) in b.statements.iter().enumerate() {
            match st {
                Stmt::Assign { dest, dest_place, dest_proj, rvalue } => {
                    // Borrows that only feed an inlined primitive comparison
                    // are dead: the comparison loads the fields directly.
                    if inline_skip.contains(dest) {
                        continue;
                    }
                    // The iterator's `&mut self` borrow temp is skipped too:
                    // copying it would consume the loop-carried iterator.
                    if iter_skip.contains(dest) {
                        continue;
                    }
                    // Return of a by-value aggregate that is (a copy of) a
                    // param: copy it out so the caller owns a distinct
                    // allocation (otherwise the result aliases the caller's
                    // argument local and both get freed -> double-free).
                    if dest == "_0" {
                        let src = match rvalue {
                            Rvalue::Use { op } => match op {
                                Operand::Move { place, proj: None }
                                | Operand::Copy { place, proj: None } => Some(place.clone()),
                                Operand::Conflict { place, .. } => Some(place.clone()),
                                _ => None,
                            },
                            Rvalue::Ref { place, agg: true, .. } => Some(place.clone()),
                            _ => None,
                        };
                        if let Some(src) = src {
                            if let Some(&sz) = param_aggs.get(&src) {
                                if sz > 0 {
                                    out.push(format!("    _0 = alloc {}", sz));
                                    out.push(format!("    call @sa_mem_copy(&_0, &{}, {})", src, sz));
                                    bound.insert("_0".to_string());
                                    continue;
                                }
                            }
                        }
                    }
                    // Field store (`_1.0 = <val>`): write through the base
                    // register's storage as a typed `store`; the base local is
                    // not rebound.
                    if let Some(pj) = dest_proj {
                        let val: String = match rvalue {
                            Rvalue::Use { op } => match op {
                                Operand::Move { place, proj } | Operand::Copy { place, proj } => {
                                    if proj.is_some() && !scalarized.contains(place) {
                                        // Read the source field first, then store.
                                        let t = format!("{}_fs", dest);
                                        out.push(format!("    {} = load {}+{} as {}", t, place, proj.as_ref().map(|p| p.offset).unwrap_or(0), proj.as_ref().map(|p| p.ty.clone()).unwrap_or_else(|| "i64".to_string())));
                                        t
                                    } else {
                                        render_operand(op)
                                    }
                                }
                                Operand::Const { .. } => render_operand(op),
                                _ => render_operand(op),
                            },
                            _ => {
                                // Compound rvalue: materialize into `dest`, then store.
                                let line = render_rvalue(rvalue, dest, dest_place.as_deref(), unsup, &b.id, &mut mv_idx, &cmap, &spill);
                                for l in line.split('\n') {
                                    out.push(format!("    {}", l));
                                }
                                dest.clone()
                            }
                        };
                        out.push(format!("    store {}+{}, {} as {}", dest, pj.offset, val, pj.ty));
                        bound.insert(dest.clone());
                        continue;
                    }
                    // Trailing `//` is ForbiddenSyntax: the Assign arm never
                    // appends provenance comments (they live in mir.json).
                    if bound.contains(dest) {
                        unsup.push(format!("{}:{} Rebind", b.id, dest));
                        out.push(format!("    // UNSUPPORTED rebind -> {} (already bound; keeping first value)", dest));
                        continue;
                    }
                    // Unresolvable const values go loud (never raw Debug).
                    let before = unsup.len();
                    // A dead byte-literal store allocates a payload that
                    // nothing can read or free; skip the definition (no use
                    // can reach the unbound register).
                    let dead_literal = dead.contains(dest)
                        && matches!(
                            rvalue,
                            Rvalue::Use { op: Operand::Const { str_bytes: Some(_), .. } }
                        );
                    if dead_literal {
                        out.push(format!("    // dead byte-literal store {} (no reads; not materialized)", dest));
                    } else if let Some(why) = assign_loud_const(rvalue) {
                        unsup.push(format!("{}:{} ConstValue", b.id, dest));
                        out.push(format!("    // UNSUPPORTED const-value -> {}: {}", dest, flat_comment(&why)));
                    } else {
                        // A projected read of a checked-arithmetic dest is a
                        // read of its bare scalar, not a field load.
                        let collapsed;
                        let rvalue_eff: &Rvalue = match rvalue {
                            Rvalue::Use { op } if op.proj().is_some() => {
                                let base = match op {
                                    Operand::Move { place, .. } | Operand::Copy { place, .. } => place,
                                    _ => "",
                                };
                                if scalarized.contains(base) {
                                    let op2 = match op {
                                        Operand::Move { place, .. } => Operand::Move { place: place.clone(), proj: None },
                                        Operand::Copy { place, .. } => Operand::Copy { place: place.clone(), proj: None },
                                        other => other.clone(),
                                    };
                                    collapsed = Rvalue::Use { op: op2 };
                                    &collapsed
                                } else {
                                    rvalue
                                }
                            }
                            _ => rvalue,
                        };
                        let line = render_rvalue(rvalue_eff, dest, dest_place.as_deref(), unsup, &b.id, &mut mv_idx, &cmap, &spill);
                        // Record the scalarized dest so later blocks collapse
                        // its tuple projections too.
                        if let Rvalue::BinOp { op, .. } = rvalue {
                            if checked_arith_helper(op).is_some() {
                                scalarized.insert(dest.clone());
                            }
                        }
                        for l in line.split('\n') {
                            out.push(format!("    {}", l));
                        }
                        // Spilled dests need their slot allocated at the
                        // definition. Most render arms already emit it; this
                        // covers the remaining arms (BinOp/UnOp/Discriminant/
                        // RawPtr/Repeat/...) without duplicating it.
                        if let Some(ty) = spill.get(dest) {
                            let slot = spill_slot(dest);
                            let prefix = format!("{} = ", slot);
                            let emitted = line
                                .split('\n')
                                .any(|l| l.trim_start().starts_with(&prefix));
                            if !emitted {
                                out.push(format!("    mut {} = stack_alloc 8", slot));
                                out.push(format!("    store {}+0, {} as {}", slot, dest, ty));
                            }
                        }
                    }
                    if unsup.len() > before && !dead_literal {
                        // Loud paths bind nothing: a `0` placeholder keeps
                        // downstream uses parseable (function already flagged).
                        // Feed the constmap so later Copies re-materialize
                        // the marker instead of moving it (UseAfterMove).
                        out.push(format!("    {} = 0", dest));
                        cmap.insert(dest.clone(), "0".to_string());
                        // Spilled dests mirror the placeholder into the slot
                        // so reloads stay parseable too.
                        spill_placeholder(&mut out, &spill, &Some(dest.clone()));
                    }
                    bound.insert(dest.clone());
                }
                Stmt::StorageLive { local } => out.push(format!("    // StorageLive {}", local)),
                Stmt::StorageDead { local } => out.push(format!("    // StorageDead {}", local)),
                Stmt::Nop { text } => out.push(format!("    // nop: {}", text)),
                Stmt::SetDisc { place, variant, offset, ty, .. } => {
                    // Enum tag: offset/width from rustc layout (driver). Falls
                    // back to the v1 assumption (`+0 as i64`) when unknown.
                    out.push("    // set-discriminant (enum tag)".to_string());
                    match ty {
                        Some(t) => out.push(format!("    store {}+{}, {} as {}", place, offset, variant, t)),
                        None => out.push(format!("    store {}+0, {} as i64", place, variant)),
                    }
                }
                Stmt::UnsupportedStmt { text } => {
                    unsup.push(format!("{}: UnsupportedStmt", b.id));
                    out.push(format!("    // UNSUPPORTED stmt: {}", text));
                }
            }
            // Borrow release: end the borrow right after its last use.
            if let Some(list) = borrow_releases.get(&(bi, si)) {
                for r in list {
                    out.push(format!("    !{}", r));
                }
            }
        }
        // Join-slot frontier: the versioned value is defined here (or in an
        // ancestor); publish it for the later use-site load.
        if let Some(list) = block_stores.get(&bi) {
            for (slot, ver, ty) in list {
                out.push(format!("    store {}+0, {} as {}", slot, ver, ty));
            }
        }
        if let Some(list) = discr_stores.get(&bi) {
            for (slot, ver, offset, tag_ty) in list {
                let tmp = format!("{}_tag", slot);
                out.push(format!("    {} = load {}+{} as {}", tmp, ver, offset, tag_ty));
                out.push(format!("    store {}+0, {} as {}", slot, tmp, tag_ty));
            }
        }
        match &b.terminator {
            Term::Goto { target } => {
                if let Some(reg) = pred_ret.get(&bi) {
                    out.push(format!(
                        "    store _ret_phi_spill+0, {} as {}",
                        reg,
                        f.ret.as_deref().unwrap_or("i32")
                    ));
                }
                out.push(format!("    jmp {}", sa_label(target)))
            }
            Term::Return { ret } => {
                // Return-value fidelity: `return <reg>` is legal and consumes
                // the reg (probe r4; `return 0` leaks it, probe r5). Fall back
                // to the `0` marker when unresolved, void, conflicting, or not
                // definitely bound here — the marker is always parse-clean.
                let is_void = f.ret.as_deref() == Some("void");
                if !is_void && ret_joins.contains(&bi) && !bound.contains("_0") {
                    let retty = f.ret.as_deref().unwrap_or("i32");
                    out.push(format!("    _0 = load _ret_phi_spill+0 as {}", retty));
                    out.push("    return _0".to_string());
                    bound.insert("_0".to_string());
                    continue;
                }
                let live = ret.as_deref().filter(|_| !is_void).filter(|r| {
                    *r != "__VERSION_CONFLICT__" && bound.contains(*r)
                });
                match live {
                    Some(r) => out.push(format!("    return {}", r)),
                    None => {
                        if ret.as_deref() == Some("__VERSION_CONFLICT__") {
                            unsup.push(format!("{}: ReturnConflict", b.id));
                            out.push("    // UNSUPPORTED return-value: version conflict at join (multiple reaching defs)".to_string());
                        }
                        out.push("    return 0".to_string());
                    }
                }
            }
            Term::Resume => {
                out.push("    // MIR Resume (cleanup path)".to_string());
                out.push("    panic(\"unwind-resume\")".to_string());
            }
            Term::Call { func, func_raw, args, dest, target, sig, opt_shim, slice_len, negate_eq } => {
                // `PartialEq::ne`: call the local `eq` and negate.
                if let Some(eq_name) = negate_eq {
                    let d = dest.as_deref().unwrap_or("_0");
                    let (pre, a) = crate::render::render_call_args(args, &spill, d);
                    let tmp = format!("{}_ne", d);
                    for l in pre {
                        out.push(l);
                    }
                    out.push(format!("    {} = call @{}({})", tmp, eq_name, a.join(", ")));
                    out.push(format!("    {} = ne {}, 0", d, tmp));
                    bound.insert(d.to_string());
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => {
                            out.push("    // diverging call".to_string());
                            out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                        }
                    }
                    continue;
                }
                // `slice::len` / `str::len`: the fat pointer's length word.
                if let Some(sl) = slice_len {
                    let d = dest.as_deref().unwrap_or("_0");
                    let recv = args
                        .first()
                        .map(|a| match a {
                            Operand::Move { place, .. } | Operand::Copy { place, .. } => {
                                place.clone()
                            }
                            _ => "0".to_string(),
                        })
                        .unwrap_or_else(|| "0".to_string());
                    out.push(format!("    {} = load {}+{} as u64", d, recv, sl.len_off));
                    bound.insert(d.to_string());
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => {
                            out.push("    // diverging call".to_string());
                            out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                        }
                    }
                    continue;
                }
                // `Option::is_some` / `is_none` / `unwrap_or`: inline the
                // discriminant test (std's symbol cannot run here).
                if let Some(sh) = opt_shim {
                    let d = dest.as_deref().unwrap_or("_0");
                    if let Some(lines) = crate::layout::plan_option_shim(d, &b.id, args, sh) {
                        for l in lines {
                            out.push(l);
                        }
                        bound.insert(d.to_string());
                        match target {
                            Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                            None => {
                                out.push("    // diverging call".to_string());
                                out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                            }
                        }
                        continue;
                    }
                }
                // `for i in a..b`: std's iterator protocol is inlined here
                // (the SA runtime has no std `Iterator::next`).
                if func.contains("core_str_impl_str_as_bytes") {
                    // `str::as_bytes` reinterprets the fat pointer: the
                    // identity here (the callee dereferences the same
                    // data/length pair).
                    let src = args
                        .first()
                        .map(|a| match a {
                            Operand::Move { place, .. } | Operand::Copy { place, .. } => {
                                place.clone()
                            }
                            _ => "0".to_string(),
                        })
                        .unwrap_or_else(|| "0".to_string());
                    let d = dest.as_deref().unwrap_or("_0");
                    out.push(format!("    {} = {}", d, src));
                    bound.insert(d.to_string());
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => {
                            out.push("    // diverging call".to_string());
                            out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                        }
                    }
                    continue;
                }
                if func.contains("as_std_iter_Iterator_rev") {
                    // `Range::rev()` builds a `Rev<Range<T>>`, a newtype over
                    // the range: it shares the range's storage, so it is the
                    // identity here (the direction is handled by `next`).
                    let src = args
                        .first()
                        .map(|a| match a {
                            Operand::Move { place, .. } | Operand::Copy { place, .. } => {
                                place.clone()
                            }
                            _ => "0".to_string(),
                        })
                        .unwrap_or_else(|| "0".to_string());
                    let d = dest.as_deref().unwrap_or("_0");
                    out.push(format!("    {} = {}", d, src));
                    bound.insert(d.to_string());
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => {
                            out.push("    // diverging call".to_string());
                            out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                        }
                    }
                    continue;
                }
                if is_into_iter_call(func) {
                    // `into_iter(range)` is the identity for a range.
                    let src = args
                        .first()
                        .map(|a| match a {
                            Operand::Move { place, .. } | Operand::Copy { place, .. } => {
                                place.clone()
                            }
                            _ => "0".to_string(),
                        })
                        .unwrap_or_else(|| "0".to_string());
                    let d = dest.as_deref().unwrap_or("_0");
                    out.push(format!("    {} = {}", d, src));
                    bound.insert(d.to_string());
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => {
                            out.push("    // diverging call".to_string());
                            out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                        }
                    }
                    continue;
                }
                if is_next_call(func) {
                    let iter = if iter_reg.is_empty() {
                        args.first()
                            .map(|a| match a {
                                Operand::Move { place, .. } | Operand::Copy { place, .. } => {
                                    place.clone()
                                }
                                _ => "0".to_string(),
                            })
                            .unwrap_or_else(|| "0".to_string())
                    } else {
                        iter_reg.clone()
                    };
                    let d = dest.as_deref().unwrap_or("_0");
                    if let Some(ctx) = iter_ctx.clone() {
                        let lbl_some = format!("L_iter_some_{}", b.id);
                        let lbl_none = format!("L_iter_none_{}", b.id);
                        let lbl_end = format!("L_iter_end_{}", b.id);
                        let cur = format!("_iter_cur_{}", b.id);
                        let end = format!("_iter_endv_{}", b.id);
                        let cmp = format!("_iter_cmp_{}", b.id);
                        let ret = format!("_iter_ret_{}", b.id);
                        let inc = format!("_iter_inc_{}", b.id);
                        // Ascending: the cursor is the lower bound, the
                        // payload is the cursor and it advances. Descending
                        // (`Rev`): the cursor is the upper bound, the payload
                        // is `cursor - 1` and it retreats.
                        let (cur_off, bound_off) = if ctx.descending {
                            (ctx.end_off, ctx.cur_off)
                        } else {
                            (ctx.cur_off, ctx.end_off)
                        };
                        out.push(format!("    {} = load {}+{} as {}", cur, iter, cur_off, ctx.payload_ty));
                        out.push(format!("    {} = load {}+{} as {}", end, iter, bound_off, ctx.payload_ty));
                        out.push(format!(
                            "    {} = {} {}, {}",
                            cmp,
                            match (ctx.descending, ctx.signed) {
                                (false, true) => "slt",
                                (false, false) => "ult",
                                (true, true) => "sgt",
                                (true, false) => "ugt",
                            },
                            cur,
                            end
                        ));
                        out.push(format!("    mut {} = alloc 8", ret));
                        out.push(format!("    br {} -> {}, {}", cmp, lbl_some, lbl_none));
                        out.push(format!("{}:", lbl_some));
                        out.push(format!("    store {}+{}, 1 as {}", ret, ctx.tag_off, ctx.tag_ty));
                        if ctx.descending {
                            out.push(format!(
                                "    {} = sub {}, 1",
                                inc,
                                cur
                            ));
                            out.push(format!(
                                "    store {}+{}, {} as {}",
                                ret, ctx.payload_off, inc, ctx.payload_ty
                            ));
                            out.push(format!(
                                "    store {}+{}, {} as {}",
                                iter, cur_off, inc, ctx.payload_ty
                            ));
                        } else {
                            out.push(format!(
                                "    store {}+{}, {} as {}",
                                ret, ctx.payload_off, cur, ctx.payload_ty
                            ));
                            out.push(format!("    {} = add {}, 1", inc, cur));
                            out.push(format!(
                                "    store {}+{}, {} as {}",
                                iter, cur_off, inc, ctx.payload_ty
                            ));
                        }
                        out.push(format!("    jmp {}", lbl_end));
                        out.push(format!("{}:", lbl_none));
                        out.push(format!("    store {}+{}, 0 as {}", ret, ctx.tag_off, ctx.tag_ty));
                        out.push(format!("    jmp {}", lbl_end));
                        out.push(format!("{}:", lbl_end));
                        out.push(format!("    {} = {}", d, ret));
                        bound.insert(d.to_string());
                        match target {
                            Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                            None => {
                                out.push("    // diverging call".to_string());
                                out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                            }
                        }
                        continue;
                    }
                }
                // Inlined primitive comparison (derived `PartialEq`).
                if let Some(ie) = inline_eq.get(&bi) {
                    let (lb, lo, lt) = &ie.left;
                    let (rb, ro, rt) = &ie.right;
                    let v1 = format!("_ie{}_l", bi);
                    let v2 = format!("_ie{}_r", bi);
                    out.push(format!("    {} = load {}+{} as {}", v1, lb, lo, lt));
                    out.push(format!("    {} = load {}+{} as {}", v2, rb, ro, rt));
                    let d = dest.as_deref().unwrap_or("_0");
                    out.push(format!(
                        "    {} = {} {}, {}",
                        d,
                        if ie.ne { "ne" } else { "eq" },
                        v1,
                        v2
                    ));
                    bound.insert(d.to_string());
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => {
                            out.push("    // diverging call".to_string());
                            out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                        }
                    }
                    continue;
                }
                if let Some(raw) = func_raw {
                    out.push(format!("    // MIR: {}", flat_comment(raw)));
                }
                // Diverging Rust panic entry points (`panic_fmt`, `begin_panic`,
                // ...) never return: lower directly to a native `panic(code)`
                // so `sars run` stays broker-free (no `@extern` for a call
                // that can never come back). Counted loudly for honesty.
                if target.is_none() && is_diverging_panic_call(func, func_raw.as_deref()) {
                    unsup.push(format!("{}: DivergingPanicFolded", b.id));
                    out.push(format!(
                        "    // diverging panic call folded: {} aborts natively ({} )",
                        sa_ident(func),
                        flat_comment(func_raw.as_deref().unwrap_or("")),
                    ));
                    if let Some(d) = dest {
                        if !bound.contains(d) {
                            out.push(format!("    {} = 0", d));
                            bound.insert(d.clone());
                        }
                    }
                    out.push(format!("    panic({})", diverging_panic_code(&b.id)));
                    continue;
                }
                // Rebound call dests keep the first value (bare call preserves
                // side effects; control preserved below).
                let rebind = dest.as_deref().is_some_and(|d| bound.contains(d));
                if rebind {
                    unsup.push(format!("{}: Rebind", b.id));
                    out.push(format!("    // UNSUPPORTED rebind -> {} (already bound; keeping first value)", dest.as_deref().unwrap_or("_0")));
                }
                if let Some(kind) = args.iter().find_map(loud_const_kind) {
                    unsup.push(format!("{}: Call{}", b.id, kind));
                    out.push(format!(
                        "    // UNSUPPORTED call-args: {} (control preserved)",
                        loud_operand_reason(args.iter().find(|a| loud_const_kind(a).is_some()).unwrap()).unwrap_or_default()
                    ));
                    bind_placeholder(&mut out, &mut bound, dest);
                    spill_placeholder(&mut out, &spill, dest);
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => out.push(format!("    panic({})", unreachable_panic_code(&b.id))),
                    }
                    continue;
                }
                // Calls without a resolvable signature but with args cannot
                // get a typed `@extern` decl (bare `()` mismatches any args:
                // CapabilityMismatch), so they go loud (control preserved).
                if call_sig_loud(sig, args) {
                    unsup.push(format!("{}: CallNoSig", b.id));
                    out.push("    // UNSUPPORTED call-sig: unresolvable callee signature (control preserved)".to_string());
                    bind_placeholder(&mut out, &mut bound, dest);
                    spill_placeholder(&mut out, &spill, dest);
                    match target {
                        Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                        None => out.push(format!("    panic({})", unreachable_panic_code(&b.id))),
                    }
                    continue;
                }
                let (prelude, a) = crate::render::render_call_args(args, &spill, dest.as_deref().unwrap_or("_0"));
                for l in prelude {
                    out.push(l);
                }
                // Void calls bind nothing (`_x = call @void()` is InvalidSyntax):
                // the unit dest gets an exact `0` marker (unit carries no data).
                let is_void = sig.as_ref().is_some_and(|s| s.ret == "void");
                if rebind {
                    out.push(format!("    call @{}({})", sa_ident(func), a.join(", ")));
                } else if is_void {
                    out.push(format!("    call @{}({})", sa_ident(func), a.join(", ")));
                    if let Some(d) = dest {
                        out.push(format!("    // unit call result (exact: () carries no data)"));
                        out.push(format!("    {} = 0", d));
                        bound.insert(d.clone());
                    }
                } else {
                    out.push(format!("    {} = call @{}({})", dest.as_deref().unwrap_or("_0"), sa_ident(func), a.join(", ")));
                    if let Some(d) = dest {
                        bound.insert(d.clone());
                        // Spilled call dests get their slot setup inline.
                        if let Some(ty) = spill.get(d) {
                            let slot = spill_slot(d);
                            out.push(format!("    mut {} = stack_alloc 8", slot));
                            out.push(format!("    store {}+0, {} as {}", slot, d, ty));
                        }
                    }
                }
                // Borrow release after a terminator call: the borrow's last
                // use is this call, so the borrow ends here. A `!` may not
                // follow the jump, so it goes right after the call line.
                if let Some(list) = borrow_releases.get(&(bi, usize::MAX)) {
                    for r in list {
                        out.push(format!("    !{}", r));
                    }
                }
                match target {
                    Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                    None => {
                        // Diverging call: panic diverges without ending the
                        // SA function textually (bare `unreachable` would).                        out.push("    // diverging call".to_string());
                        out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                    }
                }
            }
            Term::Drop { place, target } => {
                // Conflicted drops carry a marker (see version.rs): loud here,
                // control preserved via the original target.
                if place == "__VERSION_CONFLICT__" {
                    unsup.push(format!("{}: DropConflict", b.id));
                    out.push("    // UNSUPPORTED drop: version conflict at join (multiple reaching defs)".to_string());
                } else if borrow_plan.cleanup.contains(&bi) {
                    // Cleanup duplicate (see borrow_end.rs phase 2): the main
                    // path already freed this place and the unwind path never
                    // runs, so no second `!p` (Referee scans past `return`).
                    out.push(format!("    // cleanup drop {} (omitted: main path owns the release)", place));
                } else {
                    // Borrow-end (see borrow_end.rs): NLL-dead borrowers end
                    // here so `!p` doesn't trap BorrowConflict. Unresolvable
                    // sites stay loud (old shape, honest count).
                    if borrow_plan.loud.contains(&bi) {
                        unsup.push(format!("{}: DropBorrowLive", b.id));
                        out.push(format!("    // UNSUPPORTED drop-borrow-live -> {} (borrow outlives; not provably endable)", place));
                    }
                    if let Some(ends) = borrow_plan.ends.get(&bi) {
                        for r in ends {
                            out.push(format!("    !{}", r));
                        }
                    }
                    out.push(format!("    !{}", place));
                }
                out.push(format!("    jmp {}", sa_label(target)));
            }
            Term::SwitchInt { discr, targets, otherwise } => {
                // Single-move fan-out: a Move discriminant must be bound once,
                // otherwise every `br ^p` arm would move `p` again. Each arm
                // compares via `eq` + two-target `br` (inline `==` is
                // ForbiddenSyntax); fallthrough lands on per-arm labels.
                // Unresolvable const discriminants go loud (control preserved).
                if const_needs_loud(discr) {
                    let kind = loud_const_kind(discr).unwrap_or("ConstValue");
                    unsup.push(format!("{}: Switch{}", b.id, kind));
                    out.push("    // UNSUPPORTED switch-discr: unresolvable const (control preserved)".to_string());
                    out.push(format!("    jmp {}", sa_label(otherwise)));
                    continue;
                }
                let d = match discr.as_ref() {
                    Operand::Move { place, .. } => {
                        // The discriminant is read by every arm's compare, so
                        // it must stay live across the fan-out. A copy would
                        // be released only on the fall-through path (the arm
                        // sections are emitted inside this block), leaving the
                        // register's state different at the join; reading the
                        // place directly keeps one definition on all paths.
                        place.clone()
                    }
                    _ => render_operand(discr),
                };
                for (i, (v, t)) in targets.iter().enumerate() {
                    // Else-edge of the previous arm lands here (col-0 label),
                    // so the chain falls through arm by arm.
                    if i > 0 {
                        out.push(format!("{}:", sa_label(&format!("sw_{}_{}", b.id, i - 1))));
                    }
                    let e = format!("_sw_{}_eq_{}", b.id, i);
                    out.push(format!("    {} = eq {}, {}", e, d, v));
                    if i + 1 < targets.len() {
                        out.push(format!("    br {} -> {}, {}", e, sa_label(t), sa_label(&format!("sw_{}_{}", b.id, i))));
                    } else {
                        out.push(format!("    br {} -> {}, {}", e, sa_label(t), sa_label(otherwise)));
                    }
                }
                // No-arm switch (empty targets): straight to otherwise.
                if targets.is_empty() {
                    out.push(format!("    jmp {}", sa_label(otherwise)));
                }
            }
            Term::Assert { cond, target, msg, expected } => {
                // Overflow asserts are folded: the accompanying
                // `*WithOverflow` already expanded to `sa_std/num.sal`'s
                // checked macro, which traps on overflow. Comparing the flag
                // here would test the VALUE register (the pair is collapsed),
                // i.e. nonsense. Counted loudly so the folding stays visible.
                let msg_text = msg.as_deref().unwrap_or("");
                if is_overflow_assert(msg_text) {
                    unsup.push(format!("{}: OverflowAssertFolded", b.id));
                    out.push(format!(
                        "    // overflow assert folded: {} traps inside sa_std/num.sal ({} )",
                        sa_label(target),
                        flat_comment(msg_text)
                    ));
                    out.push(format!("    jmp {}", sa_label(target)));
                    continue;
                }
                // `assert cond` is not an SA instruction: compare against the
                // expected bit, branch to target, else numeric panic (the msg
                // rides as a comment; codes are 1500+bb deterministic).
                // Unresolvable const conditions go loud (control preserved).
                if const_needs_loud(cond) {
                    let kind = loud_const_kind(cond).unwrap_or("ConstValue");
                    unsup.push(format!("{}: Assert{}", b.id, kind));
                    out.push("    // UNSUPPORTED assert-cond: unresolvable const (control preserved)".to_string());
                    out.push(format!("    jmp {}", sa_label(target)));
                    continue;
                }
                let c = match cond.as_ref() {
                    Operand::Move { place, .. } => {
                        let tmp = format!("_as_{}", b.id);
                        out.push(format!("    {} = {}", tmp, place));
                        tmp
                    }
                    _ => render_operand(cond),
                };
                let e = format!("_as_{}_eq", b.id);
                out.push(format!("    {} = eq {}, {}", e, c, if expected.unwrap_or(true) { 1 } else { 0 }));
                out.push(format!("    br {} -> {}, {}", e, sa_label(target), sa_label(&format!("as_{}_fail", b.id))));
                out.push(format!("{}:", sa_label(&format!("as_{}_fail", b.id))));
                match msg {
                    Some(m) => {
                        out.push(format!("    // assert failed: {}", flat_comment(m)));
                        out.push(format!("    panic({})", assert_panic_code(&b.id)));
                    }
                    None => {
                        out.push("    // assert failed".to_string());
                        out.push(format!("    panic({})", assert_panic_code(&b.id)));
                    }
                }
            }
            Term::Unreachable => {
                out.push("    // MIR unreachable (diverging path)".to_string());
                out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
            }
            Term::InlineAsm { text, template, options, modifiers, inout, outs, ins, target } => {
                let t = template.as_deref();
                let o = options.as_deref();
                match asm_mov_copy(t, o, *modifiers, *inout, outs, ins) {
                    Some((dest, src)) => {
                        if bound.contains(&dest) {
                            unsup.push(format!("{}:{} Rebind", b.id, dest));
                            out.push(format!("    // UNSUPPORTED rebind -> {} (already bound; keeping first value)", dest));
                        } else {
                            out.push("    // inline-asm mov (exact reg copy)".to_string());
                            out.push(format!("    {} = {}", dest, src));
                            bound.insert(dest);
                        }
                    }
                    None => match asm_inout_passthrough(t, o, *modifiers, *inout, outs, ins) {
                        Some((None, None)) => {
                            out.push("    // inline-asm inout passthrough (value-stable escape, sla-117)".to_string());
                        }
                        Some((Some(dest), Some(src))) => {
                            if bound.contains(&dest) {
                                unsup.push(format!("{}:{} Rebind", b.id, dest));
                                out.push(format!("    // UNSUPPORTED rebind -> {} (already bound; keeping first value)", dest));
                            } else {
                                out.push("    // inline-asm inout passthrough (value-stable escape)".to_string());
                                out.push(format!("    {} = {}", dest, src));
                                bound.insert(dest);
                            }
                        }
                        _ => {
                            unsup.push(format!("{}: InlineAsm", b.id));
                            out.push(format!("    // UNSUPPORTED inline-asm: {} (no SA equivalent; extern/intrinsic TBD)", flat_comment(text)));
                            // Single plain-local out gets a placeholder so
                            // downstream uses stay parseable.
                            if outs.len() == 1 && is_plain_local(outs[0].trim()) && !bound.contains(&outs[0]) {
                                out.push(format!("    {} = 0", outs[0].trim()));
                                bound.insert(outs[0].trim().to_string());
                            }
                        }
                    },
                }
                // Explicit fallthrough: RPO reordering breaks MIR adjacency.
                // No target (naked/noreturn): panic diverges without ending
                // the SA function textually (bare `unreachable` would).
                match target {
                    Some(t) => out.push(format!("    jmp {}", sa_label(t))),
                    None => {
                        out.push("    // noreturn/naked asm (diverging path)".to_string());
                        out.push(format!("    panic({})", unreachable_panic_code(&b.id)));
                    }
                }
            }
            Term::Unsupported { text } => {
                unsup.push(format!("{}: UnsupportedTerm", b.id));
                out.push(format!("    // UNSUPPORTED terminator: {}", text));
            }
        }
    }
    if let Some(prev) = open_block {
        let e = out.len();
        block_ranges.push((prev, block_start[prev], e));
    }
    // Drop glue (see drop.rs): exit-anchored releases over emitted lines.
    // Insertion runs over original block indices (dom_sets keying), from
    // last to first so earlier indices stay valid.
    {
        let n = f.blocks.len();
        let mut lines_by_orig: Vec<Vec<String>> = vec![vec![]; n];
        let mut range_by_orig: Vec<(usize, usize)> = vec![(0, 0); n];
        for (bi, s, e) in &block_ranges {
            lines_by_orig[*bi] = out[*s..*e].to_vec();
            range_by_orig[*bi] = (*s, *e);
        }
        let mut ptr_params: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for (i, t) in f.params.iter().enumerate() {
            if t == "ptr" {
                ptr_params.insert(format!("_{}", i + 1));
            }
        }
        // Registers that merely alias a pointer param (`_3 = _1` when a
        // by-value aggregate is forwarded) borrow the caller's storage; they
        // must not be exit-freed (double-free → InvalidAddress). Propagate
        // transitively over plain `dest = src` copies.
        {
            let mut changed = true;
            while changed {
                changed = false;
                for b in &f.blocks {
                    for st in &b.statements {
                        if let crate::mir::Stmt::Assign { dest, rvalue, .. } = st {
                            let src = match rvalue {
                                crate::mir::Rvalue::Use { op } => match op {
                                    crate::mir::Operand::Move { place, .. }
                                    | crate::mir::Operand::Copy { place, .. }
                                    | crate::mir::Operand::Conflict { place, .. } => Some(place.clone()),
                                    _ => None,
                                },
                                // `agg` refs (`dest = place`) copy the pointer
                                // rather than taking a new borrow.
                                crate::mir::Rvalue::Ref { place, agg: true, .. } => Some(place.clone()),
                                _ => None,
                            };
                            if let Some(src) = src {
                                if ptr_params.contains(&src) && ptr_params.insert(dest.clone()) {
                                    changed = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        let mut frees = crate::drop::exit_frees(&lines_by_orig, &doms, f.params.len(), &ptr_params);
        let mut tfrees = crate::drop::temp_frees(&lines_by_orig);
        // A temp already released at an exit keeps that release (the exit list
        // is dominance-verified, the block-local one is heuristic). Filter in
        // ONE direction only: cross-filtering both ways would drop a register
        // that appears in both lists from both.
        let temp_freed: std::collections::BTreeSet<String> =
            tfrees.values().flatten().cloned().collect();
        for v in frees.values_mut() {
            v.retain(|r| !temp_freed.contains(r));
        }
        let exit_freed: std::collections::BTreeSet<String> =
            frees.values().flatten().cloned().collect();
        for v in tfrees.values_mut() {
            v.retain(|r| !exit_freed.contains(r));
        }
        let mut order_desc: Vec<usize> = (0..n).collect();
        order_desc.sort_by_key(|b| std::cmp::Reverse(range_by_orig[*b].0));
        // Descending by block start: an insertion shifts later positions, so
        // sweeping from the end keeps the remaining `range_by_orig` valid.
        for bi in order_desc {
            let mut fs: Vec<&String> = vec![];
            if let Some(v) = frees.get(&bi) {
                fs.extend(v.iter());
            }
            if let Some(v) = tfrees.get(&bi) {
                fs.extend(v.iter());
            }
            // Synthesized string/slice buffers (`_str_*`) are heap
            // allocations the drop planner cannot see (they are not MIR
            // registers): release them with the other exit frees. The fat
            // pointer (`_fat_*`) is moved into the call that consumes it, so
            // it must NOT be released here.
            let extra: Vec<String> = {
                let (s, e) = range_by_orig[bi];
                let mut extra: Vec<String> = Vec::new();
                for line in out[s..e].iter() {
                    for tok in line.split(|c: char| !(c.is_alphanumeric() || c == '_')) {
                        if tok.starts_with("_str_")
                            && !extra.iter().any(|x| x == tok)
                        {
                            extra.push(tok.to_string());
                        }
                    }
                }
                extra
            };
            for r in &extra {
                if !fs.iter().any(|x| x.as_str() == r.as_str()) {
                    fs.push(r);
                }
            }
            if fs.is_empty() {
                continue;
            }
            let (s, e) = range_by_orig[bi];
            // The jump/return is the block's last line: insert before it (a
            // label-less line may not follow a terminator).
            let pos = e.saturating_sub(1).max(s);
            for (k, r) in fs.iter().enumerate() {
                out.insert(pos + k, format!("    !{}", r));
            }
        }
    }
    // A spill slot is declared at its first def, but a second def of the same
    // local (e.g. both arms assigning a spilled temp) re-emits the slot's
    // `stack_alloc`. Re-declaring a stack slot traps (RegisterRedefinition),
    // so keep only the first declaration; later defs already `store` into it.
    {
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut dedup = Vec::with_capacity(out.len());
        for line in out.drain(..) {
            let t = line.trim();
            if let Some(slot) = t
                .strip_prefix("mut ")
                .and_then(|r| r.strip_suffix(" = stack_alloc 8"))
            {
                if seen.insert(slot.to_string()) {
                    dedup.push(line);
                }
                continue;
            }
            dedup.push(line);
        }
        out = dedup;
    }
    let mut s = out.join("\n");
    s.push('\n');
    s
}

pub fn collect_externs(mir: &MirFile) -> std::collections::BTreeMap<String, Option<(Vec<String>, String)>> {
    // sla convention (cf. sa_plugin_sla emitExternDecl): every called-but-
    // undefined symbol gets an `@extern` decl so the module is closed.
    // Signatures are per first-seen call site (monomorphic MIR gives one sig
    // per DefId; name truncation collisions keep the first, documented).
    // Signatures are unknown at MIR level; map them to sci/sa_std per STD_MAP.md.
    // Locally-defined functions are NOT externs (mir2sars fix: same-crate
    // callees like `add` must not get a shadowing `@extern` decl).
    let mut defined = std::collections::BTreeSet::new();
    for f in &mir.functions {
        defined.insert(crate::render_util::sa_ident(&f.name));
    }
    let mut set = std::collections::BTreeMap::new();
    for f in &mir.functions {
        for b in &f.blocks {
            for st in &b.statements {
                if let Stmt::Assign { rvalue: Rvalue::Call { func, sig, opt_shim, slice_len, .. }, .. } = st {
                    let name = sa_ident(func);
                    if defined.contains(&name) {
                        continue;
                    }
                    // An inlined `Option`/`slice` method is not an extern.
                    if opt_shim.is_some() || slice_len.is_some() {
                        continue;
                    }
                    set.entry(name).or_insert_with(|| {
                        sig.as_ref().map(|s| (s.params.clone(), s.ret.clone()))
                    });
                }
            }
            if let Term::Call { func, func_raw, sig, target, opt_shim, slice_len, .. } = &b.terminator {
                let name = sa_ident(func);
                if defined.contains(&name) {
                    continue;
                }
                // An inlined `Option`/`slice` method is not an extern.
                if opt_shim.is_some() || slice_len.is_some() {
                    continue;
                }
                // Diverging panic calls lower to native `panic(code)` (see
                // the Term::Call arm above): no `@extern` needed, and
                // emitting one would force `sars run` through a broker for
                // a call that never returns.
                if target.is_none() && is_diverging_panic_call(func, func_raw.as_deref()) {
                    continue;
                }
                set.entry(name).or_insert_with(|| {
                    sig.as_ref().map(|s| (s.params.clone(), s.ret.clone()))
                });
            }
        }
    }
    set
}

/// `@extern` decl text: typed params when known, bare `()` otherwise
/// (bare decls only match zero-arg calls; the rest go loud at use sites).
pub fn extern_decl(name: &str, sig: &Option<(Vec<String>, String)>) -> String {
    match sig {
        Some((params, ret)) => {
            let ps: Vec<String> = params
                .iter()
                .enumerate()
                .map(|(i, t)| format!("_a{}: {}", i, t))
                .collect();
            format!("@extern {}({}) -> {}", name, ps.join(", "), ret)
        }
        None => format!("@extern {}()", name),
    }
}

pub fn cmd_lower(args: &[String]) -> ExitCode {
    let (mut input, mut out, mut strict) = (None, None, false);
    // Cross-crate deps: `<dep mir.json>=<import path written into .sars>`.
    // Callees provided by a dep become `@import` instead of `@extern`, so a
    // cargo workspace links its crates instead of hitting the broker.
    let mut deps: Vec<(String, String)> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--out" => { i += 1; out = args.get(i).cloned(); }
            "--dep" => {
                i += 1;
                if let Some(spec) = args.get(i) {
                    if let Some((mir, imp)) = spec.split_once('=') {
                        deps.push((mir.to_string(), imp.to_string()));
                    }
                }
            }
            "--strict" => strict = true,
            s if !s.starts_with("--") && input.is_none() => input = Some(s.to_string()),
            _ => {}
        }
        i += 1;
    }
    let (input, out) = match (input, out) {
        (Some(a), Some(b)) => (a, b),
        _ => { eprintln!("usage: mir2sars lower <mir.json> --out <out.sars> [--strict] [--dep <dep.mir.json>=<import.sars>]"); return ExitCode::from(2); }
    };
    let text = match std::fs::read_to_string(&input) {
        Ok(t) => t,
        Err(e) => { eprintln!("read {}: {}", input, e); return ExitCode::from(2); }
    };
    let mir: MirFile = match serde_json::from_str(&text) {
        Ok(m) => m,
        Err(e) => { eprintln!("bad mir.json: {}", e); return ExitCode::from(2); }
    };
    // SSA versioning (see version.rs): same transform coverage applies.
    let mir = MirFile {
        source: mir.source.clone(),
        functions: mir.functions.iter().map(crate::version::version_function).collect(),
    };
    let mut unsup = vec![];
    // Bodies joined by "\n"; each body already ends with one trailing newline.
    // sla convention: `@extern` decls for all called-but-undefined symbols.
    let mut bodies: Vec<String> = mir.functions.iter().map(|f| lower_function(f, &mut unsup)).collect();
    let mut exts = collect_externs(&mir);
    if bodies.iter().any(|b| b.contains("sa_mem_set")) {
        // Repeat lowering emits `call @sa_mem_set` directly (not via Rvalue::Call).
        // Signature mirrors `sci/sa_std/core/mem.sa` (`&dst: ptr, val: u8, count: u64 -> void`).
        exts.insert(
            "sa_mem_set".to_string(),
            Some((vec!["ptr".to_string(), "u8".to_string(), "u64".to_string()], "void".to_string())),
        );
    }
    if bodies.iter().any(|b| b.contains("sa_mem_copy")) {
        // Return-copy of a param-derived aggregate emits `call @sa_mem_copy`.
        // Signature mirrors `sa_std/core/mem.sars` (`&dst: ptr, &src: ptr,
        // count: u64 -> void`).
        exts.insert(
            "sa_mem_copy".to_string(),
            Some((vec!["ptr".to_string(), "ptr".to_string(), "u64".to_string()], "void".to_string())),
        );
    }
    if bodies.iter().any(|b| b.contains("sa_thread_local_slot")) {
        // ThreadLocal lowering emits `call @sa_thread_local_slot` directly
        // (registry lives in sci/sa_std/thread_local.sai: `(key: u64) -> ptr`).
        exts.insert(
            "sa_thread_local_slot".to_string(),
            Some((vec!["u64".to_string()], "ptr".to_string())),
        );
    }
    let joined = bodies.join("\n");
    // Cross-crate: a callee exported by a `--dep` crate is imported, not
    // declared `@extern` (an `@extern` would force broker resolution at run).
    let mut dep_imports: Vec<String> = Vec::new();
    if !deps.is_empty() {
        let mut provided = std::collections::BTreeMap::<String, String>::new();
        for (dep_mir, import_path) in &deps {
            // Cross-crate callees from another crate reach MIR as
            // `<crate>_<fn>` (sanitized `crate::fn`); the dep's own mir.json
            // names them `<fn>`. Accept both, deriving `<crate>` from the
            // `<crate>.mir.json` filename produced by rsc_driver.
            let crate_name = std::path::Path::new(dep_mir)
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.trim_end_matches(".mir.json").to_string())
                .filter(|n| !n.is_empty());
            if let Ok(text) = std::fs::read_to_string(dep_mir) {
                if let Ok(dep) = serde_json::from_str::<MirFile>(&text) {
                    for f in &dep.functions {
                        let name = sa_ident(&f.name);
                        provided.insert(name.clone(), import_path.clone());
                        if let Some(c) = &crate_name {
                            provided.insert(format!("{}_{}", c, name), import_path.clone());
                        }
                    }
                }
            }
        }
        let names: Vec<String> = exts.keys().cloned().collect();
        for name in names {
            if !joined.contains(&format!("call @{name}(")) && !joined.contains(&format!("call @{name} ")) {
                continue;
            }
            if let Some(imp) = provided.get(&name) {
                exts.remove(&name);
                if !dep_imports.contains(imp) {
                    dep_imports.push(imp.clone());
                }
            }
        }
    }
    let mut sa_compat = String::from("@import \"sa_std/io/print.sai\"\n@import \"sa_std/num.sal\"\n");
    for imp in &dep_imports {
        sa_compat += &format!("@import \"{}\"\n", imp);
    }
    sa_compat += "\n";
    if !exts.is_empty() {
        sa_compat += "// MIR callees (map to sci/sa_std per STD_MAP.md):\n";
        for (e, sig) in &exts {
            // Dead extern guard: the call site may have gone loud (const
            // args, rebind, no-sig) and emitted no `call @e` at all — an
            // unreferenced `@extern` still forces `sars run` to resolve it
            // through a broker. Only declare what the bodies reference.
            if !joined.contains(&format!("call @{e}(")) && !joined.contains(&format!("call @{e} ")) {
                continue;
            }
            sa_compat += &extern_decl(e, sig);
            sa_compat += "\n";
        }
        sa_compat += "\n";
    }
    sa_compat += &bodies.join("\n");
    if std::fs::write(&out, &sa_compat).is_err() {
        eprintln!("write {}", out);
        return ExitCode::from(2);
    }
    println!("wrote {} UNSUPPORTED={}", out, unsup.len());
    for u in &unsup {
        eprintln!("  UNSUPPORTED: {}", u);
    }
    if strict && !unsup.is_empty() {
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

