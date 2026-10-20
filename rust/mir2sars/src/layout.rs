//! mir2sa::layout.
use crate::const_util::{array_elem_size, const_array_elem, const_elem_ty, sa_scalar_ty, scalar_hex_value};
use crate::mir::{AdtLayout, EnumTag, NicheStore, Operand, STR_INLINE_MAX};

/// `(((*_46).1: ...).0: [i32; 3])` lowers to sla-style `alloc` + `store`
/// (cf. `sci/sa_std/alloc/vec.sa`: `buf = alloc bytes`,
/// `store base+off, v as u64`). Returns SA lines or None (caller keeps it
/// UNSUPPORTED: non-const elems, unknown layout, count mismatch).
pub fn lower_array_init(bid: &str, dest_place: &str, elems: &[Operand]) -> Option<Vec<String>> {
    let lb = dest_place.rfind('[')?;
    let rb = dest_place[lb..].find(']')? + lb;
    let inner = &dest_place[lb + 1..rb];
    let mut parts = inner.split(';');
    let ty = parts.next()?.trim();
    let n: usize = parts.next()?.trim().parse().ok()?;
    if parts.next().is_some() || n != elems.len() {
        return None;
    }
    let size = array_elem_size(ty)?;
    let sa_ty = sa_scalar_ty(ty);
    let mut vals = Vec::with_capacity(elems.len());
    for e in elems {
        match e {
            Operand::Const { value, .. } => {
                vals.push(const_array_elem(value, ty, size)?);
            }
            Operand::Conflict { .. } => return None, // join-ambiguous: loud.
            _ => return None, // Moves/Copies must stay visible; never hide them in a store.
        }
    }
    let base = format!("_agg_{}", bid);
    let mut lines = vec![
        format!("// aggregate {} init {}", dest_place.trim(), inner.trim()),
        format!("mut {} = alloc {}", base, n * size),
    ];
    for (i, v) in vals.iter().enumerate() {
        lines.push(format!("store {}+{}, {} as {}", base, i * size, v, sa_ty));
    }
    Some(lines)
}

pub fn align_agg_offset(offset: usize, size: usize) -> usize {
    // Mirrors sla alignAggregateOffset: only 8-byte fields force alignment.
    if size == 8 { (offset + 7) & !7 } else { offset }
}

/// Generic Adt (struct/tuple/range/enum-payload) lowering to sla-style
/// `alloc` + per-field `store` (cf. `sci/sa_std/alloc/vec.sa`).
/// Layout mirrors `sa_plugin_sla` tuple/struct ABI (packed except 8-byte
/// alignment). Move elements stay visible as `^p`; Const elements are
/// decimalized; unknown-typed Moves/Copies default to 8-byte `u64` slots
/// (sla `else => 8`). Zero-sized Consts (`Val(ZeroSized, …)`: PhantomData,
/// PhantomPinned) occupy 0 bytes and emit no store (exact, per Rust layout).
/// `&str` literal Consts (driver-resolved `str_bytes`, ≤64B) materialize an
/// inline byte buffer plus a (ptr,len) fat-pointer double store per slice.sal.
/// Returns SA lines bound to `dest`, or None.
pub fn lower_adt_init(
    bid: &str,
    dest: &str,
    dest_place: &str,
    elems: &[Operand],
    layout: Option<&AdtLayout>,
    tag: Option<&EnumTag>,
    niche_store: Option<&NicheStore>,
    elem_tys: Option<&[String]>,
) -> Option<Vec<String>> {
    if elems.len() < 2 && tag.is_none() && niche_store.is_none() && layout.is_none() {
        return None;
    }
    let mut plans: Vec<FieldPlan> = Vec::with_capacity(elems.len());
    for e in elems {
        match e {
            Operand::ConstAgg { .. } => return None, // a nested const aggregate: loud.
            Operand::Conflict { .. } => return None, // join-ambiguous: loud.
            Operand::Const { value, .. } if value.trim_start().starts_with("Val(ZeroSized") => {
                plans.push(FieldPlan::Store { text: None, sa_ty: "u8", size: 0 });
            }
            Operand::Const { value, str_bytes, str_len, .. } => {
                if str_bytes.is_some() {
                    plans.push(plan_str_field(value, str_bytes.as_ref(), *str_len)?);
                    continue;
                }
                let (ty, size) = const_elem_ty(value)?;
                let rendered = match ty {
                    "bool" => {
                        if value.trim() == "true" {
                            "1".to_string()
                        } else if value.trim() == "false" {
                            "0".to_string()
                        } else {
                            let n = scalar_hex_value(value, "bool")?;
                            ((n != 0) as u8).to_string()
                        }
                    }
                    _ => const_array_elem(value, ty, size)?,
                };
                plans.push(FieldPlan::Store { text: Some(rendered), sa_ty: sa_scalar_ty(ty), size });
            }
            Operand::Move { place, .. } => {
                let (sa_ty, size) = elem_ty(elem_tys, plans.len());
                plans.push(FieldPlan::Store { text: Some(format!("^{}", place)), sa_ty, size });
            }
            Operand::Copy { place, .. } => {
                let (sa_ty, size) = elem_ty(elem_tys, plans.len());
                plans.push(FieldPlan::Store { text: Some(place.clone()), sa_ty, size });
            }
        }
    }
    // v1 footprint (also the all-zero-sized detector).
    let mut v1_total = 0usize;
    for p in &plans {
        v1_total = align_agg_offset(v1_total, p.align_size());
        v1_total += p.size();
    }
    if v1_total == 0 && tag.is_none() && niche_store.is_none() {
        // All fields zero-sized: no storage, bind a null marker (exact).
        // (An enum unit variant still needs storage for its tag.)
        return Some(vec![
            format!("// aggregate Adt init @ {} (all fields zero-sized)", dest_place.trim()),
            format!("{} = 0", dest),
        ]);
    }
    // p_layout v2: driver-supplied rustc offsets win when the arity matches.
    // They may be non-ascending (reordered fields) or non-zero-based (enum
    // payload after the tag gap) — both exact, used verbatim. Per-element
    // rendering still comes from the v1 plans above (Const decimalized via
    // its own suffix, Move/Copy as u64 slots with `^` visible).
    let (total, offsets, origin) = match layout {
        Some(l) if l.offsets.len() == elems.len() && l.size > 0 => {
            (l.size as usize, l.offsets.iter().map(|o| *o as usize).collect(), "p_layout v2: rustc layout")
        }
        _ => {
            let mut v1 = Vec::with_capacity(plans.len());
            let mut off = 0usize;
            for p in &plans {
                off = align_agg_offset(off, p.align_size());
                v1.push(off);
                off += p.size();
            }
            (off, v1, "p_layout v1: sla tuple/struct ABI")
        }
    };
    // Never under-allocate against the heuristic (e.g. Move slots assumed 8B
    // while the true field is smaller); over-allocation is harmless slack.
    let total = v1_total.max(total);
    let base = format!("_agg_{}", bid);
    let mut lines = vec![
        format!("// aggregate Adt init @ {} ({})", dest_place.trim(), origin),
        format!("mut {} = alloc {}", base, total),
    ];
    for (i, p) in plans.iter().enumerate() {
        match p {
            FieldPlan::Store { text: Some(v), sa_ty, .. } => {
                lines.push(format!("store {}+{}, {} as {}", base, offsets[i], v, sa_ty));
            }
            FieldPlan::Store { text: None, .. } => {}
            FieldPlan::StrLit { bytes } => {
                // Byte buffer + fat-pointer (ptr,len) per slice.sal layout.
                let buf = format!("_str_{}_{}", bid, i);
                lines.push(format!("mut {} = alloc {}", buf, bytes.len()));
                for (j, b) in bytes.iter().enumerate() {
                    lines.push(format!("store {}+{}, {} as u8", buf, j, b));
                }
                lines.push(format!("store {}+{}, {} as ptr", base, offsets[i], buf));
                lines.push(format!("store {}+{}, {} as u64", base, offsets[i] + 8, bytes.len()));
            }
        }
    }
    if let Some(n) = niche_store {
        // Niche variant: the niche value lives in the niche slot.
        lines.push(format!(
            "store {}+{}, {} as {}",
            base, n.offset, n.value, n.ty
        ));
    }
    if let Some(t) = tag {
        let tag_end = t.offset + match t.ty.as_str() {
            "u8" | "i8" => 1,
            "u16" | "i16" => 2,
            "u64" | "i64" => 8,
            _ => 4,
        };
        if (tag_end as usize) > total {
            // Defensive: storage was sized from the enum layout; never write
            // past it. (Mismatch would be a driver bug, not silent corruption.)
            return None;
        }
        lines.push(format!("store {}+{}, {} as {}", base, t.offset, t.variant, t.ty));
    }
    lines.push(format!("{} = {}", dest, base));
    Some(lines)
}

/// SA type and byte size of an element (from the driver-reported field
/// types; unknown types fall back to an 8-byte `u64` slot).
fn elem_ty(elem_tys: Option<&[String]>, idx: usize) -> (&'static str, usize) {
    let t = match elem_tys {
        Some(ts) => match ts.get(idx) {
            Some(t) => t.as_str(),
            None => return ("u64", 8),
        },
        None => return ("u64", 8),
    };
    match t {
        "i8" | "u8" => ("u8", 1),
        "i16" | "u16" => ("u16", 2),
        "i32" | "u32" => ("u32", 4),
        "i64" | "u64" | "usize" | "isize" => ("u64", 8),
        "f32" => ("f32", 4),
        "f64" => ("f64", 8),
        "ptr" => ("ptr", 8),
        _ => ("u64", 8),
    }
}

/// One aggregate field's lowering plan.
pub enum FieldPlan {
    /// Single `store` (text None = ZST, occupies 0B, emits nothing).
    Store { text: Option<String>, sa_ty: &'static str, size: usize },
    /// `&str` literal: byte buffer + fat-pointer (ptr,len) double store.
    /// 16B wide, 8B aligned (Slice_ptr=+0, Slice_len=+8 per slice.sal).
    StrLit { bytes: Vec<u64> },
}

impl FieldPlan {
    fn size(&self) -> usize {
        match self {
            FieldPlan::Store { size, .. } => *size,
            FieldPlan::StrLit { .. } => 16,
        }
    }
    fn align_size(&self) -> usize {
        match self {
            FieldPlan::Store { size, .. } => *size,
            FieldPlan::StrLit { .. } => 8,
        }
    }
}

/// Plan a `&str` literal field: byte buffer preamble + (ptr,len) stores.
/// Gate: driver-resolved bytes, len within STR_INLINE_MAX, counts agree.
/// Anything else -> None (caller stays loud UNSUPPORTED).
pub fn plan_str_field(value: &str, str_bytes: Option<&Vec<u64>>, str_len: Option<u64>) -> Option<FieldPlan> {
    let bytes = str_bytes?;
    let len = str_len?;
    if len > STR_INLINE_MAX || bytes.len() as u64 != len {
        return None;
    }
    // Sanity: the Debug text must name a string slice (never trust blindly).
    if !(value.contains("str") || value.contains("Slice")) {
        return None;
    }
    Some(FieldPlan::StrLit { bytes: bytes.clone() })
}

/// Plan a byte-literal const in VALUE position (`_x = &[u8; K]`): inline the
/// payload into a fresh buffer and bind its (thin) address.
///
/// SIZED pointees only: `&[u8; K]` is a thin pointer, so one register holds
/// it. A `str` / `[u8]` pointee is a FAT pointer (ptr+len) and cannot live in
/// one SA register — those stay loud (the aggregate path stores the pair into
/// a field instead). Gate: driver-resolved bytes, len within STR_INLINE_MAX,
/// counts agree, and the Debug text names a sized `[u8; K]` pointee.
pub fn plan_const_bytes(
    dest: &str,
    bid: &str,
    idx: usize,
    value: &str,
    str_bytes: Option<&Vec<u64>>,
    str_len: Option<u64>,
    fat: bool,
) -> Option<Vec<String>> {
    let bytes = str_bytes?;
    let len = str_len?;
    if len == 0 || len > STR_INLINE_MAX || bytes.len() as u64 != len {
        return None;
    }
    // A sized byte array pointee (`[u8; 12]`) or a str/slice literal.
    let tight: String = value.chars().filter(|c| !c.is_whitespace()).collect();
    if !tight.contains("[u8;") && !tight.contains("str") {
        return None;
    }
    let buf = format!("_str_{}_{}", bid, idx);
    let mut lines = vec![format!("mut {} = alloc {}", buf, bytes.len())];
    for (j, b) in bytes.iter().enumerate() {
        lines.push(format!("store {}+{}, {} as u8", buf, j, b));
    }
    if fat {
        // A fat pointer (data word + length word), the `&str` / `&[u8]`
        // shape the callee dereferences.
        let fatreg = format!("_fat_{}_{}", bid, idx);
        lines.push(format!("mut {} = alloc 16", fatreg));
        lines.push(format!("store {}+0, {} as ptr", fatreg, buf));
        lines.push(format!("store {}+8, {} as u64", fatreg, len));
        lines.push(format!("{} = {}", dest, fatreg));
    } else {
        lines.push(format!("{} = {}", dest, buf));
    }
    Some(lines)
}

/// An `Option` method inlined: the discriminant test (and the payload for
/// `unwrap_or`).
/// A primitive method inlined: `abs`, `min`, `max`.
///
/// The operands are read from a frame slot, so no register is consumed on
/// only one path (a join would see mismatched states).
pub fn plan_prim_shim(
    dest: &str,
    bid: &str,
    args: &[Operand],
    sh: &crate::mir::PrimShim,
) -> Option<Vec<String>> {
    let arg_reg = |i: usize| -> Option<String> {
        match args.get(i)? {
            Operand::Move { place, .. } | Operand::Copy { place, .. } => Some(place.clone()),
            // A constant argument renders as its literal value.
            Operand::Const { value, .. } => crate::render_util::const_scalar_text(value),
            _ => None,
        }
    };
    let ty = |i: usize| -> String { sh.tys.get(i).cloned().unwrap_or_else(|| "i64".to_string()) };
    match sh.kind.as_str() {
        "abs" => {
            let x = arg_reg(0)?;
            let slot = format!("_prim_slot_{}", bid);
            let neg = format!("_prim_neg_{}", bid);
            let val = format!("_prim_v_{}", bid);
            let abs = format!("_prim_abs_{}", bid);
            let lbl_neg = format!("L_prim_neg_{}", bid);
            let lbl_pos = format!("L_prim_pos_{}", bid);
            let lbl_end = format!("L_prim_end_{}", bid);
            let mut lines = Vec::new();
            lines.push(format!("mut {} = stack_alloc 8", slot));
            lines.push(format!("store {}+0, {} as {}", slot, x, ty(0)));
            lines.push(format!(
                "{} = {} {}, 0",
                neg,
                if ty(0).starts_with('u') { "ult" } else { "slt" },
                x
            ));
            lines.push(format!("br {} -> {}, {}", neg, lbl_neg, lbl_pos));
            lines.push(format!("{}:", lbl_neg));
            lines.push(format!("{} = load {}+0 as {}", val, slot, ty(0)));
            lines.push(format!("{} = sub 0, {}", abs, val));
            lines.push(format!("{} = {}", dest, abs));
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_pos));
            lines.push(format!("{} = load {}+0 as {}", dest, slot, ty(0)));
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_end));
            Some(lines)
        }
        "min" | "max" => {
            let a = arg_reg(0)?;
            let b = arg_reg(1)?;
            let slot_a = format!("_prim_sa_{}", bid);
            let slot_b = format!("_prim_sb_{}", bid);
            let lbl_a = format!("L_prim_a_{}", bid);
            let lbl_b = format!("L_prim_b_{}", bid);
            let lbl_end = format!("L_prim_end_{}", bid);
            let cmp = format!("_prim_cmp_{}", bid);
            let mut lines = Vec::new();
            lines.push(format!("mut {} = stack_alloc 8", slot_a));
            lines.push(format!("mut {} = stack_alloc 8", slot_b));
            lines.push(format!("store {}+0, {} as {}", slot_a, a, ty(0)));
            lines.push(format!("store {}+0, {} as {}", slot_b, b, ty(1)));
            lines.push(format!(
                "{} = {} {}, {}",
                cmp,
                if ty(0).starts_with('u') { "ult" } else { "slt" },
                a,
                b
            ));
            lines.push(format!("br {} -> {}, {}", cmp, lbl_a, lbl_b));
            lines.push(format!("{}:", lbl_a));
            if sh.kind == "min" {
                lines.push(format!("{} = load {}+0 as {}", dest, slot_a, ty(0)));
            } else {
                lines.push(format!("{} = load {}+0 as {}", dest, slot_b, ty(1)));
            }
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_b));
            if sh.kind == "min" {
                lines.push(format!("{} = load {}+0 as {}", dest, slot_b, ty(1)));
            } else {
                lines.push(format!("{} = load {}+0 as {}", dest, slot_a, ty(0)));
            }
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_end));
            Some(lines)
        }
        _ => None,
    }
}

/// A `Vec` operation inlined: `new`, `push`, `len`, `is_empty`.
///
/// The vector's words are read from the receiver; `push` grows the buffer
/// when it is full (a fresh allocation, the old one is left to the frame).
pub fn plan_vec_shim(
    dest: &str,
    bid: &str,
    args: &[Operand],
    sh: &crate::mir::VecShim,
) -> Option<Vec<String>> {
    let arg_reg = |i: usize| -> Option<String> {
        match args.get(i)? {
            Operand::Move { place, .. } | Operand::Copy { place, .. } => Some(place.clone()),
            Operand::Const { value, .. } => crate::render_util::const_scalar_text(value),
            _ => None,
        }
    };
    let esz = sh.elem_size.max(1);
    match sh.kind.as_str() {
        "new" => {
            // `Vec::new()` -> an empty vector with a small initial buffer
            // (the data pointer stays valid, so a later grow can copy from it).
            let buf = format!("_vec_new_{}", bid);
            let data = format!("_vec_data_{}", bid);
            let mut lines = Vec::new();
            lines.push(format!("mut {} = alloc 24", buf));
            lines.push(format!("mut {} = alloc {}", data, 4 * esz));
            lines.push(format!("store {}+{}, {} as ptr", buf, sh.ptr_off, data));
            lines.push(format!("store {}+{}, 4 as u64", buf, sh.cap_off));
            lines.push(format!("store {}+{}, 0 as u64", buf, sh.len_off));
            lines.push(format!("{} = {}", dest, buf));
            Some(lines)
        }
        "len" => {
            let v = arg_reg(0)?;
            lines_push_load(dest, &v, sh.len_off, "u64")
        }
        "is_empty" => {
            let v = arg_reg(0)?;
            let tmp = format!("_vec_len_{}", bid);
            let mut lines = vec![format!("{} = load {}+{} as u64", tmp, v, sh.len_off)];
            lines.push(format!("{} = eq {}, 0", dest, tmp));
            Some(lines)
        }
        "index" => {
            // `v[i]`: the element at `data + i * elem_size`. The MIR's
            // bounds check runs before this call, so the index is in range.
            let v = arg_reg(0)?;
            let idx = arg_reg(1)?;
            let ety = if sh.elem_ty.is_empty() { "u64".to_string() } else { sh.elem_ty.clone() };
            let data = format!("_vec_data_{}", bid);
            let slot = format!("_vec_slot_{}", bid);
            let addr = format!("_vec_addr_{}", bid);
            let mut lines = Vec::new();
            lines.push(format!("{} = load {}+{} as ptr", data, v, sh.ptr_off));
            lines.push(format!("{} = mul {}, {}", slot, idx, esz));
            lines.push(format!("{} = ptr_add {}, {}", addr, data, slot));
            // `Index::index` returns a *reference* to the element.
            lines.push(format!("{} = {}", dest, addr));
            let _ = ety;
            Some(lines)
        }
        "push" => {
            // `push(&mut v, x)`: grow when full, then append.
            let v = arg_reg(0)?;
            let x = arg_reg(1)?;
            let len = format!("_vec_len_{}", bid);
            let cap = format!("_vec_cap_{}", bid);
            let data = format!("_vec_data_{}", bid);
            let lbl_grow = format!("L_vec_grow_{}", bid);
            let lbl_app = format!("L_vec_app_{}", bid);
            let lbl_end = format!("L_vec_end_{}", bid);
            let mut lines = Vec::new();
            lines.push(format!("{} = load {}+{} as u64", len, v, sh.len_off));
            lines.push(format!("{} = load {}+{} as u64", cap, v, sh.cap_off));
            lines.push(format!("{} = load {}+{} as ptr", data, v, sh.ptr_off));
            lines.push(format!(
                "{} = eq {}, {}",
                format!("_vec_full_{}", bid),
                len,
                cap
            ));
            lines.push(format!(
                "br {} -> {}, {}",
                format!("_vec_full_{}", bid),
                lbl_grow,
                lbl_app
            ));
            lines.push(format!("{}:", lbl_grow));
            // new capacity (in elements): double, at least one
            let newcap = format!("_vec_ncap_{}", bid);
            lines.push(format!("{} = mul {}, 2", newcap, cap));
            lines.push(format!("{} = add {}, 1", newcap, newcap));
            let newbytes = format!("_vec_nbytes_{}", bid);
            lines.push(format!("{} = mul {}, {}", newbytes, newcap, esz));
            let newbuf = format!("_vec_buf_{}", bid);
            lines.push(format!("mut {} = alloc {}", newbuf, newbytes));
            // copy the live elements into the fresh buffer
            let copybytes = format!("_vec_cbytes_{}", bid);
            lines.push(format!("{} = mul {}, {}", copybytes, len, esz));
            lines.push(format!(
                "call @sa_mem_copy(&{}, &{}, {})",
                newbuf, data, copybytes
            ));
            lines.push(format!("store {}+{}, {} as ptr", v, sh.ptr_off, newbuf));
            lines.push(format!("store {}+{}, {} as u64", v, sh.cap_off, newcap));
            lines.push(format!("{} = {}", data, newbuf));
            lines.push(format!("jmp {}", lbl_app));
            lines.push(format!("{}:", lbl_app));
            let slot = format!("_vec_slot_{}", bid);
            lines.push(format!("{} = mul {}, {}", slot, len, esz));
            let addr = format!("_vec_addr_{}", bid);
            lines.push(format!("{} = ptr_add {}, {}", addr, data, slot));
            let ety = if sh.elem_ty.is_empty() { "u64".to_string() } else { sh.elem_ty.clone() };
            lines.push(format!("store {}+0, {} as {}", addr, x, ety));
            lines.push(format!("{} = add {}, 1", format!("_vec_len2_{}", bid), len));
            lines.push(format!("store {}+{}, {} as u64", v, sh.len_off, format!("_vec_len2_{}", bid)));
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_end));
            Some(lines)
        }
        _ => None,
    }
}

fn lines_push_load(dest: &str, v: &str, off: u64, ty: &str) -> Option<Vec<String>> {
    Some(vec![format!("{} = load {}+{} as {}", dest, v, off, ty)])
}

pub fn plan_option_shim(
    dest: &str,
    bid: &str,
    args: &[Operand],
    sh: &crate::mir::OptShim,
) -> Option<Vec<String>> {
    let recv = match args.first() {
        Some(Operand::Move { place, .. }) | Some(Operand::Copy { place, .. }) => place.clone(),
        _ => return None,
    };
    let tag = format!("_opt_tag_{}", bid);
    let mut lines = vec![format!(
        "{} = load {}+{} as {}",
        tag, recv, sh.tag_off, sh.tag_ty
    )];
    match sh.kind.as_str() {
        "is_some" => {
            // The payload variant (`Some` / `Ok`) carries the value; the
            // discriminant holds its index.
            lines.push(format!("{} = eq {}, {}", dest, tag, sh.present));
            Some(lines)
        }
        "is_none" => {
            lines.push(format!("{} = ne {}, {}", dest, tag, sh.present));
            Some(lines)
        }
        "unwrap_or" => {
            let dflt = match args.get(1) {
                Some(Operand::Move { place, .. }) | Some(Operand::Copy { place, .. }) => place.clone(),
                Some(Operand::Const { value, .. }) => {
                    crate::render_util::const_scalar_text(value)?
                }
                _ => return None,
            };
            let payload = format!("_opt_val_{}", bid);
            let sel = format!("_opt_sel_{}", bid);
            let slot = format!("_opt_defslot_{}", bid);
            let lbl_some = format!("L_opt_some_{}", bid);
            let lbl_none = format!("L_opt_none_{}", bid);
            let lbl_end = format!("L_opt_end_{}", bid);
            lines.push(format!("{} = eq {}, {}", sel, tag, sh.present));
            // The default is read (not moved) on both paths: a plain copy
            // would consume the register on one path only, and the join would
            // see mismatched states. A frame slot keeps it readable.
            lines.push(format!("mut {} = stack_alloc 8", slot));
            lines.push(format!("store {}+0, {} as u64", slot, dflt));
            lines.push(format!("br {} -> {}, {}", sel, lbl_some, lbl_none));
            lines.push(format!("{}:", lbl_some));
            lines.push(format!(
                "{} = load {}+{} as {}",
                payload, recv, sh.payload_off, sh.payload_ty
            ));
            lines.push(format!("{} = {}", dest, payload));
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_none));
            lines.push(format!("{} = load {}+0 as u64", dest, slot));
            lines.push(format!("jmp {}", lbl_end));
            lines.push(format!("{}:", lbl_end));
            Some(lines)
        }
        _ => None,
    }
}

/// FNV-1a 64 of a ThreadLocal def path: the u64 key passed to
/// `sa_thread_local_slot` (see `sci/sa_std/thread_local.sai`). Keeps .sa
/// string-free; collisions across a crate's few TLS statics are impractical.
pub fn tls_key(def: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in def.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}
