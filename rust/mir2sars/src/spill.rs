//! mir2sa::spill — reload slots for multi-use values.
//!
//! SA `=` moves (single-assignment): `_X = Copy _Y` traps UseAfterMove when
//! `_Y` is read again later. Shared reads inside call args / BinOp operands /
//! stores / eq are fine (non-consuming) — only plain-assign copies need help.
//!
//! For values whose TYPE IS KNOWN, spill to a slot once and reload per copy:
//! - synthetic buffers (`_agg_*`, `_rep_*`): always `ptr` (we generate them);
//! - call dests with resolvable sig ret: mapped store-ty (u64/i64/u32/...).
//! Moves stay direct (single exact transfer); only Copy-uses reload, so the
//! transform is order-independent (loads never touch the source reg).
//! Slots are always 8 bytes (all store-tys fit; slack is harmless).
//! Everything else (computed scalars, params, borrows) stays loud — the
//! general program needs driver locals widths (spill) and SSA versioning.

use std::collections::{BTreeMap, BTreeSet};

use crate::asm::scalar_width_bits;
use crate::mir::{Operand, Rvalue, Stmt, Term};

/// Spill slots: base/dest reg -> SA store type (`ptr`, `u64`, `i32`, …).
pub type SpillMap = BTreeMap<String, String>;

/// MIR/SA type text -> SA value type (width-carrying). None when the type
/// cannot be represented as an SA value (fat pointers, 128-bit ints, void).
pub fn sa_type_of(ty: &str) -> Option<String> {
    let t = ty.trim();
    if t.is_empty() || t == "?" || t == "void" || t == "()" {
        return None;
    }
    if t == "ptr" || t.starts_with('*') || t.starts_with('&') {
        return Some("ptr".to_string());
    }
    match crate::asm::scalar_width_bits(t) {
        Some(w) if w != 128 => Some(crate::const_util::sa_scalar_ty(t).to_string()),
        _ => None,
    }
}

/// Const operand type from the driver's Debug text
/// (`Val(Scalar(0x00000001), i32)`) or the `-Zunpretty` text form (`1_i32`).
/// None for fat pointers and zero-sized values (no SA value type).
pub fn const_operand_ty(value: &str) -> Option<String> {
    let v = value.trim();
    if v.starts_with("Val(ZeroSized") {
        return None;
    }
    if let Some((_, rest)) = v.rsplit_once(", ") {
        let ty = rest.trim().trim_end_matches(')').trim();
        return sa_type_of(ty);
    }
    if let Some((_, suf)) = v.rsplit_once('_') {
        return sa_type_of(suf);
    }
    None
}

/// SA type of a place, when the MIR lets us infer it.
///
/// Params carry their SA type directly; locals are inferred from the rvalue
/// that defines them (const / call / cast / ref / aggregate / discriminant).
/// A place whose type cannot be inferred is absent from the map: callers
/// then keep the place loud instead of guessing a width.
pub fn place_types(f: &crate::mir::Function) -> BTreeMap<String, String> {
    let mut types: BTreeMap<String, String> = BTreeMap::new();
    for (i, t) in f.params.iter().enumerate() {
        if let Some(sa) = sa_type_of(t) {
            types.insert(format!("_{}", i + 1), sa);
        }
    }
    // Definitions may chain (`_1 = Move(_3)`): iterate to a fixed point.
    for _ in 0..16 {
        let mut changed = false;
        for b in &f.blocks {
            for st in &b.statements {
                if let Stmt::Assign { dest, rvalue, .. } = st {
                    if types.contains_key(dest) {
                        continue;
                    }
                    if let Some(t) = rvalue_type(rvalue, &types) {
                        types.insert(dest.clone(), t);
                        changed = true;
                    }
                }
            }
            if let Term::Call { dest: Some(d), sig, .. } = &b.terminator {
                if !types.contains_key(d) {
                    if let Some(s) = sig {
                        if let Some(t) = sa_type_of(&s.ret) {
                            types.insert(d.clone(), t);
                            changed = true;
                        }
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
    types
}

/// SA type of the value an rvalue defines (None when unknown).
fn rvalue_type(rv: &Rvalue, types: &BTreeMap<String, String>) -> Option<String> {
    match rv {
        Rvalue::Use { op } => match op {
            Operand::Const { value, str_bytes, .. } => {
                if str_bytes.is_some() {
                    // Byte-literal payload: the value is a buffer address.
                    return Some("ptr".to_string());
                }
                const_operand_ty(value)
            }
            // A projected read (`load base+off as ty`) has the field type, not
            // the base local's type (which is usually `ptr` for an aggregate).
            Operand::Copy { place, proj } | Operand::Move { place, proj } => match proj {
                Some(pj) => Some(pj.ty.clone()),
                None => types.get(place).cloned(),
            },
            _ => None,
        },
        Rvalue::Ref { .. } | Rvalue::RawPtr { .. } | Rvalue::Repeat { .. } => {
            Some("ptr".to_string())
        }
        Rvalue::Call { sig, .. } => sig.as_ref().and_then(|s| sa_type_of(&s.ret)),
        Rvalue::Cast { ty, .. } => {
            let dst = crate::asm::cast_dst_short(ty);
            if dst == "ptr" {
                Some("ptr".to_string())
            } else {
                sa_type_of(&dst)
            }
        }
        // Aggregates lower to a materialized buffer (pointer value).
        Rvalue::Aggregate { .. } => Some("ptr".to_string()),
        // The enum tag lives at offset 0 and is read as i64.
        Rvalue::Discriminant { .. } => Some("i64".to_string()),
        Rvalue::BinOp { left, .. } => match left.as_ref() {
            Operand::Copy { place, .. } | Operand::Move { place, .. } => types.get(place).cloned(),
            _ => None,
        },
        Rvalue::UnOp { operand, .. } => match operand.as_ref() {
            Operand::Copy { place, .. } | Operand::Move { place, .. } => types.get(place).cloned(),
            _ => None,
        },
        Rvalue::ThreadLocal { .. } => Some("ptr".to_string()),
        _ => None,
    }
}

/// Place name of a place operand (None for constants).
fn operand_place(op: &Operand) -> Option<String> {
    match op {
        Operand::Move { place, .. } | Operand::Copy { place, .. } | Operand::Conflict { place, .. } => {
            Some(place.clone())
        }
        _ => None,
    }
}

/// Blocks that are part of a loop (a block that can reach itself). A local
/// read inside a loop is carried across iterations: its copies must not
/// consume the register, or the next iteration reads a moved value.
fn loop_blocks(blocks: &[crate::mir::Block]) -> BTreeSet<usize> {
    use std::collections::{HashMap, HashSet};
    let idx: HashMap<&str, usize> = blocks
        .iter()
        .enumerate()
        .map(|(i, b)| (b.id.as_str(), i))
        .collect();
    let mut succs: Vec<Vec<usize>> = vec![Vec::new(); blocks.len()];
    for (i, b) in blocks.iter().enumerate() {
        let mut add = |t: &str| {
            if let Some(&ti) = idx.get(t) {
                succs[i].push(ti);
            }
        };
        match &b.terminator {
            crate::mir::Term::Goto { target } => add(target),
            crate::mir::Term::SwitchInt { targets, otherwise, .. } => {
                for (_, t) in targets {
                    add(t);
                }
                add(otherwise);
            }
            crate::mir::Term::Call { target: Some(t), .. } => add(t),
            crate::mir::Term::Assert { target, .. } => add(target),
            crate::mir::Term::Drop { target, .. } => add(target),
            crate::mir::Term::InlineAsm { target: Some(t), .. } => add(t),
            _ => {}
        }
    }
    // A block is in a loop when it can reach itself (transitively).
    let mut in_loop = BTreeSet::new();
    for start in 0..blocks.len() {
        let mut seen: HashSet<usize> = HashSet::new();
        let mut stack: Vec<usize> = succs[start].clone();
        let mut reaches_self = false;
        while let Some(b) = stack.pop() {
            if b == start {
                reaches_self = true;
                break;
            }
            if !seen.insert(b) {
                continue;
            }
            stack.extend(succs[b].iter().copied());
        }
        if reaches_self {
            in_loop.insert(start);
            // Every block reachable from it is part of the same loop.
            let mut seen2: HashSet<usize> = HashSet::new();
            let mut st2: Vec<usize> = vec![start];
            while let Some(b) = st2.pop() {
                if !seen2.insert(b) {
                    continue;
                }
                in_loop.insert(b);
                st2.extend(succs[b].iter().copied());
            }
        }
    }
    in_loop
}

/// Rust `Copy` semantics: a place Rust copies stays valid after the read,
/// but SA `=` CONSUMES its source, so the second copy of the same place
/// traps UseAfterMove. Spill such places to a slot and reload at every use
/// (the reload is a plain read: the source register stays live).
///
/// A place is spilled when it is copied AND either
/// - copied more than once, or
/// - copied and also used later (a use after the copy would read a
///   consumed register), or
/// - MIR-dropped (the drop glue releases the place: a consumed register
///   cannot be released).
///
/// A place that is MOVED is owned, not copied: it keeps the direct move
/// lowering (spilling it would drop the ownership transfer).
pub fn copy_spill(blocks: &[crate::mir::Block], types: &BTreeMap<String, String>) -> SpillMap {
    // Uses per place: (consuming, position). Position is the emission order
    // (block index * 4096 + statement index) so "used after" is decidable.
    let mut uses: BTreeMap<String, Vec<(bool, usize)>> = BTreeMap::new();
    let mut dropped: BTreeSet<String> = BTreeSet::new();
    let mut copied: BTreeSet<String> = BTreeSet::new();
    let mut moved: BTreeSet<String> = BTreeSet::new();
    let def_count = definition_counts(blocks);
    let in_loop = loop_blocks(blocks);
    for (bi, b) in blocks.iter().enumerate() {
        for (si, st) in b.statements.iter().enumerate() {
            let pos = bi * 4096 + si;
            if let Stmt::Assign { rvalue, .. } = st {
                match rvalue {
                    Rvalue::Use { op } => {
                        if let Some(p) = operand_place(op) {
                            // A plain assign consumes its source register.
                            note_use(&mut uses, &p, true, pos);
                            match op {
                                Operand::Copy { .. } => {
                                    copied.insert(p);
                                }
                                Operand::Move { .. } => {
                                    moved.insert(p);
                                }
                                _ => {}
                            }
                        }
                    }
                    Rvalue::Cast { op, .. } => {
                        if let Some(p) = operand_place(op) {
                            note_use(&mut uses, &p, true, pos);
                        }
                    }
                    Rvalue::RawPtr { place, .. } => {
                        note_use(&mut uses, place, true, pos);
                    }
                    Rvalue::Aggregate { elems, .. } => {
                        for e in elems {
                            if let Some(p) = operand_place(e) {
                                // A one-element aggregate lowers to a plain
                                // assign (consuming); a multi-element one
                                // stores into a buffer (only the explicitly
                                // moved elements are consumed).
                                note_use(&mut uses, &p, elems.len() == 1, pos);
                            }
                        }
                    }
                    Rvalue::BinOp { left, right, .. } => {
                        for o in [left.as_ref(), right.as_ref()] {
                            if let Some(p) = operand_place(o) {
                                note_use(&mut uses, &p, false, pos);
                            }
                        }
                    }
                    Rvalue::UnOp { operand, .. } => {
                        if let Some(p) = operand_place(operand) {
                            note_use(&mut uses, &p, false, pos);
                        }
                    }
                    Rvalue::Ref { place, agg, .. } => {
                        note_use(&mut uses, place, false, pos);
                        // Borrowing a memory-resident aggregate reads its
                        // address without consuming the owner: a copy-like
                        // use, so the owner can spill (and be borrowed
                        // again) instead of being moved by the first borrow.
                        if *agg {
                            copied.insert(place.clone());
                        }
                    }
                    Rvalue::Discriminant { place, .. } => {
                        note_use(&mut uses, place, false, pos);
                    }
                    Rvalue::Repeat { op, .. } => {
                        if let Some(p) = operand_place(op) {
                            note_use(&mut uses, &p, false, pos);
                        }
                    }
                    _ => {}
                }
            }
        }
        match &b.terminator {
            Term::Call { args, .. } => {
                let pos = bi * 4096 + 4095;
                for a in args {
                    if let Some(p) = operand_place(a) {
                        note_use(&mut uses, &p, false, pos);
                    }
                }
            }
            Term::SwitchInt { discr, .. } => {
                let pos = bi * 4096 + 4095;
                if let Some(p) = operand_place(discr) {
                    note_use(&mut uses, &p, false, pos);
                }
            }
            Term::Assert { cond, .. } => {
                let pos = bi * 4096 + 4095;
                if let Some(p) = operand_place(cond) {
                    note_use(&mut uses, &p, false, pos);
                }
            }
            Term::Drop { place, .. } => {
                dropped.insert(place.clone());
                note_use(&mut uses, place, false, bi * 4096 + 4095);
            }
            _ => {}
        }
    }
    let mut map = SpillMap::new();
    for (place, sites) in &uses {
        // Only Copy places qualify: a moved place is owned, not copied.
        if !copied.contains(place) || moved.contains(place) {
            continue;
        }
        // The slot setup is emitted at the definition site, so only
        // single-def places can spill (params have no definition and
        // multi-def locals would redefine the same slot).
        if def_count.get(place).copied().unwrap_or(0) != 1 {
            continue;
        }
        let first_consuming = sites.iter().find(|(c, _)| *c).map(|(_, p)| *p);
        let used_after_copy = match first_consuming {
            Some(p) => sites.iter().any(|(_, q)| *q > p),
            None => false,
        };
        // A place read inside a loop is carried across iterations: a copy in
        // the loop body would consume the register, and the next iteration
        // would read a moved value (or the join would see mismatched states).
        let loop_carried = sites.iter().any(|(_, p)| in_loop.contains(&(p / 4096)));
        let needs = sites.len() > 1 || used_after_copy || dropped.contains(place) || loop_carried;
        if !needs {
            continue;
        }
        if let Some(ty) = types.get(place) {
            map.insert(place.clone(), ty.clone());
        }
    }
    map
}

/// Record one use of a place.
fn note_use(
    uses: &mut BTreeMap<String, Vec<(bool, usize)>>,
    place: &str,
    consuming: bool,
    pos: usize,
) {
    uses.entry(place.to_string()).or_default().push((consuming, pos));
}

/// SA store type for a call-result spill slot, from the callee sig ret.
/// None when unmappable (caller goes loud through existing paths).
pub fn call_spill_ty(ret: &str) -> Option<String> {
    let t = ret.trim();
    if scalar_width_bits(t).is_some() {
        return Some(if t == "bool" {
            "u8".to_string()
        } else if t == "usize" {
            "u64".to_string()
        } else if t == "isize" {
            "i64".to_string()
        } else {
            t.to_string()
        });
    }
    if t == "ptr" || t.starts_with('*') || t.starts_with('&') {
        return Some("ptr".to_string());
    }
    None
}

/// SA store type for a cast dest's spill slot, from the MIR target type.
/// Pointer spellings collapse to `ptr`, scalars map through `sa_scalar_ty`
/// (bool->u8, usize->u64). None when the cast does not lower to a scalar
/// (struct/enum/fn targets: no SA slot type) — caller stays direct.
pub fn cast_spill_ty(ty: &str) -> Option<String> {
    let dst = crate::asm::cast_dst_short(ty);
    if dst == "ptr" {
        return Some("ptr".to_string());
    }
    crate::const_util::sa_scalar_ty(dst.trim());
    crate::asm::scalar_width_bits(&dst)
        .filter(|w| *w != 128)
        .map(|_| crate::const_util::sa_scalar_ty(&dst).to_string())
}

/// Copy-use positions that need reload (plain-assign moves of shared reads):
/// Assign-Use RHS, single-elem aggregate elems, and cast operands. All other
/// Copy positions render shared reads inline (non-consuming) and need nothing.
/// Cast operands matter for pointer-copy chains (Box deref null/align checks
/// copy the same pointer 2-3 times — corpus f_box/f_raw/f_underscore).
fn copy_use_targets(st: &Stmt) -> Vec<String> {
    match st {
        Stmt::Assign { rvalue, .. } => match rvalue {
            Rvalue::Use { op } => match op {
                Operand::Copy { place, .. } => vec![place.clone()],
                _ => vec![],
            },
            Rvalue::Aggregate { elems, .. } if elems.len() == 1 => match &elems[0] {
                Operand::Copy { place, .. } => vec![place.clone()],
                _ => vec![],
            },
            Rvalue::Cast { op, .. } => match op.as_ref() {
                Operand::Copy { place, .. } => vec![place.clone()],
                _ => vec![],
            },
            // Borrowing a memory-resident aggregate (`&local`) reads its
            // address without consuming the owner. Reloading it from the
            // owner's spill slot keeps the owner alive (a plain `= place`
            // would transfer the allocation's ownership).
            Rvalue::Ref { place, agg: true, .. } => vec![place.clone()],
            _ => vec![],
        },
        _ => vec![],
    }
}

/// Positions that CONSUME their operand reg (plain assign of one place).
/// MIR Move on a Copy-typed local still leaves the local valid, but SA `=`
/// moves, so the reg would be gone before its own `!b` release.
fn consuming_use_targets(st: &Stmt) -> Vec<String> {
    match st {
        Stmt::Assign { rvalue, .. } => match rvalue {
            Rvalue::Use { op } => match op {
                Operand::Move { place, .. } => vec![place.clone()],
                _ => vec![],
            },
            Rvalue::Aggregate { elems, .. } if elems.len() == 1 => match &elems[0] {
                Operand::Move { place, .. } => vec![place.clone()],
                _ => vec![],
            },
            Rvalue::Cast { op, .. } => match op.as_ref() {
                Operand::Move { place, .. } => vec![place.clone()],
                _ => vec![],
            },
            _ => vec![],
        },
        _ => vec![],
    }
}

/// Definitions per register (Assign dests and call dests).
fn definition_counts(blocks: &[crate::mir::Block]) -> BTreeMap<String, usize> {
    let mut def_count: BTreeMap<String, usize> = BTreeMap::new();
    for b in blocks {
        for st in &b.statements {
            // A field store (`dest_proj`) writes through the base local's
            // storage; it does not (re)define the base register.
            if let Stmt::Assign { dest, dest_proj: None, .. } = st {
                *def_count.entry(dest.clone()).or_insert(0) += 1;
            }
        }
        if let Term::Call { dest: Some(d), .. } = &b.terminator {
            *def_count.entry(d.clone()).or_insert(0) += 1;
        }
    }
    def_count
}

/// Build the spill map for one function, including the general Copy-value
/// spill (`copy_spill`). Existing typed spills win: they already cover
/// call/cast/borrow/byte-literal shapes whose value type is known exactly.
pub fn build_spill_for(f: &crate::mir::Function) -> SpillMap {
    let mut map = build_spill(&f.blocks);
    let types = place_types(f);
    for (place, ty) in copy_spill(&f.blocks, &types) {
        map.entry(place).or_insert(ty);
    }
    map
}

/// Build the spill map for one function: synth bases (`_agg_*`, `_rep_*`
/// defs) and call dests (with mappable sig ret) that have at least one
/// Copy-use elsewhere in the function.
///
/// Soundness gates (violations trap downstream instead):
/// - SINGLE-DEF only: multi-def regs need versioning (each def would emit
///   its own slot setup = slot redefinition; uses can't pick a slot).
///   Multi-def falls back to rebind-loud/UAM paths (honest, counted).
/// - Copy-uses only (moves stay direct single transfers).
pub fn build_spill(blocks: &[crate::mir::Block]) -> SpillMap {
    // Copy-use targets across the whole function.
    let mut copies: BTreeSet<String> = BTreeSet::new();
    // Consuming (Move) uses: these need a slot for the SOURCE to survive.
    let mut consuming: BTreeSet<String> = BTreeSet::new();
    for b in blocks {
        for st in &b.statements {
            copies.extend(copy_use_targets(st));
            consuming.extend(consuming_use_targets(st));
        }
    }
    if copies.is_empty() && consuming.is_empty() {
        return BTreeMap::new();
    }
    // Definition counts (Assign dests + Call dests): only single-def regs
    // may spill (multi-def needs versioning; per-def slot setups would
    // redefine the slot and uses couldn't pick one).
    let mut def_count: BTreeMap<String, usize> = BTreeMap::new();
    for b in blocks {
        for st in &b.statements {
            // A field store (`dest_proj`) writes through the base local's
            // storage; it does not (re)define the base register.
            if let Stmt::Assign { dest, dest_proj: None, .. } = st {
                *def_count.entry(dest.clone()).or_insert(0) += 1;
            }
        }
        if let Term::Call { dest: Some(d), .. } = &b.terminator {
            *def_count.entry(d.clone()).or_insert(0) += 1;
        }
    }
    let single = |r: &str| def_count.get(r).copied().unwrap_or(0) == 1;
    let mut map = SpillMap::new();
    for b in blocks {
        for st in &b.statements {
            if let Stmt::Assign { dest, rvalue: Rvalue::Call { sig, .. }, .. } = st {
                if copies.contains(dest) && single(dest) {
                    if let Some(s) = sig {
                        if let Some(t) = call_spill_ty(&s.ret) {
                            map.insert(dest.clone(), t);
                        }
                    }
                }
            }
        }
        if let Term::Call { dest: Some(d), sig, .. } = &b.terminator {
            if copies.contains(d) && single(d) {
                if let Some(s) = sig {
                    if let Some(t) = call_spill_ty(&s.ret) {
                        map.insert(d.clone(), t);
                    }
                }
            }
        }
    }
    // Synthetic bases: any `_agg_*`/`_rep_*` reg with a Copy-use spills
    // as `ptr` (we generate these buffers; always pointer-valued).
    for c in &copies {
        if (c.starts_with("_agg_") || c.starts_with("_rep_")) && !map.contains_key(c) {
            map.insert(c.clone(), "ptr".to_string());
        }
    }
    // Cast dests: pointer copies (Box deref null/align chains copy the same
    // pointer several times). Only casts that lower to a real value get a
    // slot — a loud cast binds a `0` placeholder and gains nothing.
    for b in blocks {
        for st in &b.statements {
            if let Stmt::Assign { dest, rvalue: Rvalue::Cast { ty, castkind, src_ty, .. }, .. } = st {
                if copies.contains(dest) && single(dest) && !map.contains_key(dest) {
                    let dst = crate::asm::cast_dst_short(ty);
                    let lowers = match (castkind.as_deref(), src_ty.as_deref()) {
                        (Some(k), Some(s)) => {
                            crate::asm::lower_cast(k, s, &dst).is_some()
                        }
                        _ => false,
                    };
                    if lowers {
                        if let Some(t) = cast_spill_ty(ty) {
                            map.insert(dest.clone(), t);
                        }
                    }
                }
            }
        }
    }
    // Borrow dests: `b = &p` is pointer-valued, and a plain assign of `b`
    // (Aggregate/Use/Cast RHS) CONSUMES the reg. The later release (`drop(b)`
    // or the borrow-end insertion before `drop(p)`) then reads a reg the
    // Referee no longer has — UnknownRegister, not UseAfterMove. Spilling
    // keeps `b` bound and reloads at the consuming use. ZST borrows emit
    // `= 0` (no pointer) and are skipped.
    for b in blocks {
        for st in &b.statements {
            if let Stmt::Assign { dest, rvalue: Rvalue::Ref { zst: false, .. }, .. } = st {
                let used = copies.contains(dest) || consuming.contains(dest);
                if used && single(dest) && !map.contains_key(dest) {
                    map.insert(dest.clone(), "ptr".to_string());
                }
            }
        }
    }
    // Byte-literal const dests (`_x = <&[u8; K] payload>`): the value is a
    // buffer address (known `ptr`). MIR Copy-uses of a Copy-typed local lower
    // to plain assigns, which consume the reg — a later `Copy` (or the
    // borrow-end release) would then read a reg the Referee dropped.
    for b in blocks {
        for st in &b.statements {
            if let Stmt::Assign { dest, rvalue: Rvalue::Use { op: Operand::Const { value, str_bytes, str_len, .. } }, .. } = st {
                let inlineable =
                    crate::layout::plan_const_bytes(dest, "bb", 0, value, str_bytes.as_ref(), *str_len, false)
                        .is_some();
                let used = copies.contains(dest) || consuming.contains(dest);
                if inlineable && used && single(dest) && !map.contains_key(dest) {
                    map.insert(dest.clone(), "ptr".to_string());
                }
            }
        }
    }
    map
}

/// Locals that are DEFINED but never READ anywhere in the function.
///
/// Only consulted for byte-literal materialization: a dead `_2 = &"..."` would
/// otherwise allocate a real payload buffer that nobody frees (the old loud
/// path bound the null marker `0`, which the Referee does not count as a
/// leak — so this used to hide). Dropping the dead definition removes the
/// allocation instead of the symptom. MIR Drop/borrow uses count as reads:
/// this set is only used where no other consumer can exist.
pub fn dead_locals(blocks: &[crate::mir::Block], n_params: usize) -> BTreeSet<String> {
    use crate::mir::{Operand, Rvalue, Stmt, Term};
    let mut defined: BTreeSet<String> = BTreeSet::new();
    let mut read: BTreeSet<String> = BTreeSet::new();
    let note = |op: &Operand, defined: &mut BTreeSet<String>, read: &mut BTreeSet<String>| {
        let place = match op {
            Operand::Move { place, .. } | Operand::Copy { place, .. } | Operand::Conflict { place, .. } => {
                place.as_str()
            }
            _ => return,
        };
        if defined.contains(place) {
            read.insert(place.to_string());
        }
    };
    for b in blocks {
        for st in &b.statements {
            match st {
                Stmt::Assign { dest, dest_proj, rvalue, .. } => {
                    match rvalue {
                        Rvalue::Use { op } => note(op, &mut defined, &mut read),
                        Rvalue::Repeat { op, .. } => note(op, &mut defined, &mut read),
                        Rvalue::UnOp { operand, .. } | Rvalue::Cast { op: operand, .. } => {
                            note(operand, &mut defined, &mut read)
                        }
                        Rvalue::Call { args, .. } => {
                            for a in args {
                                note(a, &mut defined, &mut read)
                            }
                        }
                        Rvalue::BinOp { left, right, .. } => {
                            note(left, &mut defined, &mut read);
                            note(right, &mut defined, &mut read);
                        }
                        Rvalue::Aggregate { elems, .. } => {
                            for e in elems {
                                note(e, &mut defined, &mut read)
                            }
                        }
                        Rvalue::Ref { place, .. }
                        | Rvalue::Discriminant { place, .. }
                        | Rvalue::RawPtr { place, .. } => {
                            if defined.contains(place.as_str()) {
                                read.insert(place.clone());
                            }
                        }
                        _ => {}
                    }
                    // A field store writes through the base storage; it does
                    // not define the base register.
                    if dest_proj.is_none() {
                        defined.insert(dest.clone());
                    }
                }
                Stmt::SetDisc { place, .. } => {
                    if defined.contains(place.as_str()) {
                        read.insert(place.clone());
                    }
                }
                _ => {}
            }
        }
        match &b.terminator {
            Term::Call { args, .. } => {
                for a in args {
                    note(a, &mut defined, &mut read)
                }
            }
            Term::Drop { place, .. } => {
                if defined.contains(place.as_str()) {
                    read.insert(place.clone());
                }
            }
            Term::SwitchInt { discr, .. } => note(discr, &mut defined, &mut read),
            Term::Assert { cond, .. } => note(cond, &mut defined, &mut read),
            Term::InlineAsm { ins, .. } => {
                for a in ins {
                    note(a, &mut defined, &mut read)
                }
            }
            _ => {}
        }
    }
    // Params are always live (the header binds them).
    for i in 1..=n_params {
        defined.remove(&format!("_{}", i));
    }
    defined.retain(|d| !read.contains(d));
    defined
}

/// Slot register name for a spilled base/dest.
pub fn spill_slot(reg: &str) -> String {
    format!("{}_spill", reg)
}

/// Append spill-slot setup lines for this block's synthetic bases
/// (`_agg_{bid}`, `_rep_{bid}`) when the spill map contains them.
/// Appended at the end (always after the base alloc): order-safe.
pub fn spill_slot_lines(lines: &mut Vec<String>, bid: &str, spill: &SpillMap) {
    for base in [format!("_agg_{}", bid), format!("_rep_{}", bid)] {
        if let Some(ty) = spill.get(&base) {
            let slot = spill_slot(&base);
            // Stack slot: the slot's lifetime is the function frame, so the
            // exit leak check does not see it (a heap slot would leak here).
            lines.push(format!("mut {} = stack_alloc 8", slot));
            lines.push(format!("store {}+0, {} as {}", slot, base, ty));
        }
    }
}

#[cfg(test)]
mod spill_tests {
    use super::*;

    #[test]
    fn call_spill_ty_maps() {
        assert_eq!(call_spill_ty("ptr"), Some("ptr".to_string()));
        assert_eq!(call_spill_ty("u64"), Some("u64".to_string()));
        assert_eq!(call_spill_ty("bool"), Some("u8".to_string()));
        assert_eq!(call_spill_ty("usize"), Some("u64".to_string()));
        assert_eq!(call_spill_ty("?"), None);
    }

    #[test]
    fn synth_base_spills_as_ptr() {
        use crate::mir::{Block, Rvalue, Term};
        let use_agg = Stmt::Assign {
            dest: "_3".to_string(),
            dest_place: Some("_3".to_string()),
            dest_proj: None,
            rvalue: Rvalue::Use { op: Operand::Copy { place: "_agg_bb0".to_string(), proj: None } },
        };
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![use_agg],
            terminator: Term::Return { ret: None },
        }];
        let m = build_spill(&blocks);
        assert_eq!(m.get("_agg_bb0"), Some(&"ptr".to_string()));
    }

    #[test]
    fn no_copies_no_spill() {
        use crate::mir::{Block, Term};
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![],
            terminator: Term::Return { ret: None },
        }];
        assert!(build_spill(&blocks).is_empty());
    }

    fn cast_copy(dest: &str, place: &str, ty: &str) -> Stmt {
        Stmt::Assign {
            dest: dest.to_string(),
            dest_place: Some(dest.to_string()),
            dest_proj: None,
            rvalue: Rvalue::Cast {
                op: Box::new(Operand::Copy { place: place.to_string(), proj: None }),
                ty: ty.to_string(),
                castkind: Some("PtrToPtr".to_string()),
                src_ty: Some("*".to_string()),
                coerce: None,
            },
        }
    }

    fn borrow_ref(dest: &str, place: &str) -> Stmt {
        Stmt::Assign {
            dest: dest.to_string(),
            dest_place: Some(dest.to_string()),
            dest_proj: None,
            rvalue: Rvalue::Ref {
                place: place.to_string(),
                mut_: false,
                via: None,
                zst: false,
                agg: false,
                offset: 0,
                projected: false,
                ty: None,
            },
        }
    }

    #[test]
    fn cast_spill_ty_maps() {
        assert_eq!(cast_spill_ty("*const std::vec::Vec<i32>"), Some("ptr".to_string()));
        assert_eq!(cast_spill_ty("usize"), Some("u64".to_string()));
        assert_eq!(cast_spill_ty("bool"), Some("u8".to_string()));
        assert_eq!(cast_spill_ty("std::string::String"), None);
        assert_eq!(cast_spill_ty("i128"), None, "128-bit has no SA slot type");
    }

    #[test]
    fn cast_dest_spills_when_copy_used() {
        use crate::mir::{Block, Term};
        // f_box shape: _7 = cast(copy _6), _12 = cast(copy _6) — pointer-copy
        // chain: the second plain assign would trap UseAfterMove.
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                borrow_ref("_6", "_1"),
                cast_copy("_7", "_6", "*const ()"),
                cast_copy("_12", "_6", "*const ()"),
            ],
            terminator: Term::Return { ret: None },
        }];
        let m = build_spill(&blocks);
        assert_eq!(m.get("_6"), Some(&"ptr".to_string()));
        assert!(!m.contains_key("_7"), "single use needs no slot");
    }

    #[test]
    fn borrow_dest_spills_when_consumed() {
        use crate::mir::{Block, Rvalue, Term};
        // main shape: _78 = &_79; _77 = Aggregate([Move(_78)]) — the later
        // `!_78` (borrow-end) must still find the reg bound.
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                borrow_ref("_78", "_79"),
                Stmt::Assign {
                    dest: "_77".to_string(),
                    dest_place: Some("_77".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Aggregate {
                        elems: vec![Operand::Move { place: "_78".to_string(), proj: None }],
                        layout: None,
                        tag: None,
                        niche_store: None,
                        elem_tys: None,
                    },
                },
            ],
            terminator: Term::Return { ret: None },
        }];
        assert_eq!(build_spill(&blocks).get("_78"), Some(&"ptr".to_string()));
    }

    #[test]
    fn unused_borrow_dest_does_not_spill() {
        use crate::mir::{Block, Term};
        // Only call-arg uses (non-consuming) -> no slot needed.
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![borrow_ref("_5", "_6")],
            terminator: Term::Call {
                func: "f".to_string(),
                func_raw: None,
                args: vec![Operand::Move { place: "_5".to_string(), proj: None }],
                dest: Some("_7".to_string()),
                target: Some("bb1".to_string()),
                sig: None,
            opt_shim: None,
            slice_len: None,
            negate_eq: None,
            },
        }];
        assert!(!build_spill(&blocks).contains_key("_5"));
    }

    #[test]
    fn byte_const_dest_spills_when_copied() {
        use crate::mir::{Block, Rvalue, Term};
        // b64 shape: `_1 = <&[u8; 3] payload>` then two plain-assign copies.
        // Without a slot the second copy is a UseAfterMove.
        let bytes = vec![77u64, 97, 110];
        let konst = Operand::Const {
            value: "Val(Scalar(alloc1), &'{erased} [u8; 3_usize])".to_string(),
            str_bytes: Some(bytes),
            str_len: Some(3),
            agg: None,
        str_fat: false,
        };
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                Stmt::Assign {
                    dest: "_1".to_string(),
                    dest_place: Some("_1".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Use { op: konst.clone() },
                },
                Stmt::Assign {
                    dest: "_4".to_string(),
                    dest_place: Some("_4".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Use { op: Operand::Copy { place: "_1".to_string(), proj: None } },
                },
                Stmt::Assign {
                    dest: "_11".to_string(),
                    dest_place: Some("_11".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Use { op: Operand::Copy { place: "_1".to_string(), proj: None } },
                },
            ],
            terminator: Term::Return { ret: None },
        }];
        let m = build_spill(&blocks);
        assert_eq!(m.get("_1"), Some(&"ptr".to_string()));
        // Rendered shape: buffer + slot, copies reload.
        let mut idx = 0usize;
        let mut unsup = vec![];
        let line = crate::render::render_rvalue(
            &Rvalue::Use { op: konst },
            "_1", Some("_1"), &mut unsup, "bb0", &mut idx,
            &std::collections::HashMap::new(), &m,
        );
        assert!(unsup.is_empty());
        assert_eq!(
            line,
            "mut _str_bb0_0 = alloc 3\nstore _str_bb0_0+0, 77 as u8\nstore _str_bb0_0+1, 97 as u8\n\
             store _str_bb0_0+2, 110 as u8\n_1 = _str_bb0_0\nmut _1_spill = stack_alloc 8\nstore _1_spill+0, _1 as ptr"
        );
    }

    #[test]
    fn copy_spill_spills_multi_copy_local() {
        use crate::mir::{Block, Rvalue, Term};
        let copy = |dest: &str| Stmt::Assign {
            dest: dest.to_string(),
            dest_place: Some(dest.to_string()),
            dest_proj: None,
            rvalue: Rvalue::Use { op: Operand::Copy { place: "_2".to_string(), proj: None } },
        };
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                Stmt::Assign {
                    dest: "_2".to_string(),
                    dest_place: Some("_2".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Use {
                        op: Operand::Const {
                            value: "42_u64".to_string(),
                            str_bytes: None,
                            str_len: None,
            agg: None, str_fat: false,
                        },
                    },
                },
                copy("_3"),
                copy("_4"),
            ],
            terminator: Term::Return { ret: None },
        }];
        let mut types = BTreeMap::new();
        types.insert("_2".to_string(), "u64".to_string());
        assert_eq!(copy_spill(&blocks, &types).get("_2"), Some(&"u64".to_string()));
    }

    #[test]
    fn copy_spill_skips_params_and_unknown_types() {
        use crate::mir::{Block, Rvalue, Term};
        let copy = |dest: &str, place: &str| Stmt::Assign {
            dest: dest.to_string(),
            dest_place: Some(dest.to_string()),
            dest_proj: None,
            rvalue: Rvalue::Use { op: Operand::Copy { place: place.to_string(), proj: None } },
        };
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                copy("_2", "_1"),
                copy("_3", "_1"),
                copy("_4", "_9"),
                copy("_5", "_9"),
            ],
            terminator: Term::Return { ret: None },
        }];
        let mut types = BTreeMap::new();
        types.insert("_1".to_string(), "u64".to_string());
        // `_1` is a param (zero defs): the header binds it, no slot setup
        // exists. `_9` has no inferred type: cannot pick a slot width.
        assert!(copy_spill(&blocks, &types).is_empty());
    }

    #[test]
    fn fat_byte_const_dest_spills_as_ptr() {
        use crate::mir::{Block, Rvalue, Term};
        // A `&str` literal is a fat pointer (data + length), materialized into
        // a buffer: the dest holds a pointer, so it spills like any other
        // pointer-valued dest (its uses reload instead of moving it).
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                Stmt::Assign {
                    dest: "_1".to_string(),
                    dest_place: Some("_1".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Use {
                        op: Operand::Const {
                            value: "Val(Slice { alloc_id: alloc1, meta: 3 }, &'{erased} str)".to_string(),
                            str_bytes: Some(vec![104, 105, 33]),
                            str_len: Some(3),
                            agg: None,
                            str_fat: false,
                        },
                    },
                },
                Stmt::Assign {
                    dest: "_4".to_string(),
                    dest_place: Some("_4".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Use { op: Operand::Copy { place: "_1".to_string(), proj: None } },
                },
            ],
            terminator: Term::Return { ret: None },
        }];
        assert!(build_spill(&blocks).contains_key("_1"));
    }

    #[test]
    fn zst_borrow_never_spills() {
        use crate::mir::{Block, Rvalue, Term};
        let blocks = vec![Block {
            id: "bb0".to_string(),
            statements: vec![
                Stmt::Assign {
                    dest: "_6".to_string(),
                    dest_place: Some("_6".to_string()),
                    dest_proj: None,
                    rvalue: Rvalue::Ref {
                        place: "_1".to_string(),
                        mut_: false,
                        via: None,
                        zst: true,
                        agg: false,
                        offset: 0,
                        projected: false,
                        ty: None,
                    },
                },
                cast_copy("_7", "_6", "usize"),
            ],
            terminator: Term::Return { ret: None },
        }];
        assert!(!build_spill(&blocks).contains_key("_6"));
    }
}
