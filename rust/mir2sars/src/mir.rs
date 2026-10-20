//! mir2sa::mir.
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// mir.json schema (same keys as the retired prototype so old JSON keeps working)
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone)]
pub struct MirFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    pub functions: Vec<Function>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Function {
    pub name: String,
    #[serde(default)]
    pub locals: Vec<serde_json::Value>,
    #[serde(default)]
    pub params: Vec<String>,
    /// Byte size of each by-value aggregate param (0 for scalars/pointers).
    /// A callee returning a param-derived aggregate copies it out so the
    /// caller does not share (and double-free) the argument's storage.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub param_aggs: Vec<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ret: Option<String>,
    #[serde(default = "default_sig_ok")]
    pub sig_ok: bool,
    pub blocks: Vec<Block>,
}

pub fn default_sig_ok() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Block {
    pub id: String,
    #[serde(default)]
    pub statements: Vec<Stmt>,
    #[serde(default = "default_return")]
    pub terminator: Term,
}

pub fn default_return() -> Term {
    Term::Return { ret: None }
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "kind")]
pub enum Stmt {
    Assign { dest: String, #[serde(default)] dest_place: Option<String>, #[serde(default, skip_serializing_if = "Option::is_none")] dest_proj: Option<PlaceProj>, rvalue: Rvalue },
    StorageLive { local: String },
    StorageDead { local: String },
    Nop { text: String },
    SetDisc { place: String, variant: u32, #[serde(default, skip_serializing_if = "Option::is_none")] place_full: Option<String>, #[serde(default)] offset: u64, #[serde(default, skip_serializing_if = "Option::is_none")] ty: Option<String> },
    UnsupportedStmt { text: String },
}

#[derive(Serialize, Deserialize, Clone)]
pub struct AdtLayout {
    pub size: u64,
    #[serde(default)]
    pub offsets: Vec<u64>,
}

/// A `Vec` operation inlined by the backend: the data/capacity/length word
/// offsets and the element size.
#[derive(Serialize, Deserialize, Clone)]
pub struct VecShim {
    pub kind: String,
    pub ptr_off: u64,
    pub cap_off: u64,
    pub len_off: u64,
    pub elem_size: u64,
    /// SA type of the element (the store width).
    #[serde(default)]
    pub elem_ty: String,
}

/// A primitive method inlined by the backend: the kind and the operand types.
#[derive(Serialize, Deserialize, Clone)]
pub struct PrimShim {
    pub kind: String,
    pub tys: Vec<String>,
}

/// `slice::len` / `str::len`: the fat pointer's length word offset.
#[derive(Serialize, Deserialize, Clone)]
pub struct SliceLen {
    pub len_off: u64,
}

/// `&[T]` / `&Vec<T>` -> `std::slice::Iter<'_, T>`: the element size plus the
/// data/length word offsets of the source aggregate. Used to inline
/// `IntoIterator::into_iter` and `Iterator::next`.
#[derive(Serialize, Deserialize, Clone)]
pub struct SliceIter {
    pub elem_size: u64,
    pub ptr_off: u64,
    pub len_off: u64,
}

/// An `Option` method inlined by the backend: the discriminant's offset and
/// type plus the payload's offset and type.
#[derive(Serialize, Deserialize, Clone)]
pub struct OptShim {
    pub kind: String,
    pub tag_off: u64,
    pub tag_ty: String,
    pub payload_off: u64,
    pub payload_ty: String,
    /// The variant index that carries the payload (`Some` / `Ok`).
    #[serde(default)]
    pub present: u32,
}

/// An unsizing coercion to a fat pointer: the pointer's size, the offset of
/// its length word and the source length.
#[derive(Serialize, Deserialize, Clone)]
pub struct CoerceInfo {
    pub size: u64,
    pub len_off: u64,
    pub len: u64,
}

/// Niche-encoded enum construction: the niche value and its slot.
#[derive(Serialize, Deserialize, Clone)]
pub struct NicheStore {
    pub offset: u64,
    pub value: u64,
    pub ty: String,
}

/// Enum variant construction: discriminant value plus the tag slot's byte
/// offset and integer width (rustc `TagEncoding::Direct` only).
#[derive(Serialize, Deserialize, Clone)]
pub struct EnumTag {
    pub variant: u32,
    pub offset: u64,
    pub ty: String,
}

/// Callee signature for typed `@extern` decls (bare `()` decls mismatch
/// any call with args: CapabilityMismatch). Absent when unresolvable.
#[derive(Serialize, Deserialize, Clone)]
pub struct CallSig {
    #[serde(default)]
    pub params: Vec<String>,
    #[serde(default = "default_sig_ret")]
    pub ret: String,
}

pub fn default_sig_ret() -> String {
    "i32".to_string()
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "kind")]
pub enum Rvalue {
    Use { op: Operand },
    Ref {
        place: String,
        #[serde(rename = "mut", default, skip_serializing_if = "is_false")] mut_: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")] via: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")] zst: bool,
        /// The referenced local is memory-resident in this ABI (ADT/tuple/
        /// array storage holds an address): `&place` is the address already in
        /// `place`, so lowering emits `dest = place` instead of `dest = &place`.
        #[serde(default, skip_serializing_if = "is_false")] agg: bool,
        /// Byte offset when borrowing a projected place (`&(*p).f`): the
        /// address is `ptr_add place, offset` (not `&place`).
        #[serde(default)] offset: u64,
        #[serde(default, skip_serializing_if = "is_false")] projected: bool,
        /// Value type of the borrowed place (projected borrows only).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ty: Option<String>,
    },
    Call {
        func: String,
        #[serde(default)] args: Vec<Operand>,
        #[serde(default, skip_serializing_if = "Option::is_none")] sig: Option<CallSig>,
        /// An `Option` method the backend inlines (the receiver's
        /// discriminant layout).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        opt_shim: Option<OptShim>,
        /// `slice::len` / `str::len`: the fat pointer's length word.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        slice_len: Option<SliceLen>,
        /// A `PartialEq::ne` call: the named local `eq` to call instead, and
        /// negate its result.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        negate_eq: Option<String>,
    },
    BinOp {
        op: String,
        left: Box<Operand>,
        right: Box<Operand>,
        /// Operand signedness (ordered comparisons, division, shifts).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        signed: Option<bool>,
    },
    UnOp { op: String, operand: Box<Operand> },
    Cast {
        op: Box<Operand>,
        ty: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        castkind: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        src_ty: Option<String>,
        /// An unsizing coercion to a fat pointer: the pointer's size, the
        /// offset of its length word and the source length.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        coerce: Option<CoerceInfo>,
    },
    Aggregate {
        elems: Vec<Operand>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        layout: Option<AdtLayout>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag: Option<EnumTag>,
        /// Niche-encoded enum construction: the niche value written into the
        /// niche slot (the niche variant has no payload).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        niche_store: Option<NicheStore>,
        /// SA types of the elements (from the ADT's field types): a pointer
        /// field is stored as `ptr`, not as a `u64` slot.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        elem_tys: Option<Vec<String>>,
    },
    Discriminant {
        place: String,
        #[serde(default)]
        offset: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ty: Option<String>,
        /// Niche-encoded tag (`Option<&T>`, ...): the discriminant has no
        /// stored slot; it is the niche field's value.
        #[serde(default, skip_serializing_if = "is_false")]
        niche: bool,
        /// Byte offset of the niche field (niche discriminants only).
        #[serde(default)]
        niche_offset: u64,
        /// Variant index of the niche (e.g. `None`) and of the untagged one.
        #[serde(default)]
        none_variant: u32,
        #[serde(default)]
        some_variant: u32,
    },
    RawPtr { place: String, #[serde(rename = "mut", default, skip_serializing_if = "is_false")] mut_: bool },
    Repeat { op: Box<Operand>, len: String },
    ThreadLocal { def: String },
    Unsupported { text: String },
}

/// Constant field projection for an aggregate place operand (`_1.0`,
/// `(*_2).b`, ...). `rsc_driver` collapses a projected place to its base
/// local in `place` (so other passes keep a real register); `proj` carries the
/// byte offset and SA value type so lowering can emit a `load base+off as ty`
/// instead of reusing the base aggregate pointer. Absent for plain locals and
/// pure-deref places (old fixtures stay byte-compatible).
#[derive(Serialize, Deserialize, Clone)]
pub struct PlaceProj {
    pub offset: u64,
    pub ty: String,
    /// Full projected place text for provenance (comment only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
    /// A dynamic index (`a[i]`): the index register and the element size.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<(String, u64)>,
    /// The base register holds a fat pointer: load it before adding the
    /// offset (a slice's elements live behind its data word).
    #[serde(default, skip_serializing_if = "is_false")]
    pub deref_base: bool,
    /// The word the base register is loaded from (a `Vec`'s data pointer).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_off: Option<u64>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "kind")]
pub enum Operand {
    Move {
        place: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proj: Option<PlaceProj>,
    },
    Copy {
        place: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proj: Option<PlaceProj>,
    },
    /// A constant aggregate (`&Enum::Variant(..)`): the const's own
    /// construction, materialized like an inline aggregate.
    ConstAgg {
        elems: Vec<Operand>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        layout: Option<AdtLayout>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag: Option<EnumTag>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        niche_store: Option<NicheStore>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        elem_tys: Option<Vec<String>>,
    },
    Const {
        value: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        str_bytes: Option<Vec<u64>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        str_len: Option<u64>,
        /// A constant aggregate (`&Enum::Variant(..)`): the const's own
        /// construction, materialized like an inline aggregate.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agg: Option<Box<Rvalue>>,
        /// A string/slice literal is a fat pointer (data word + length).
        #[serde(default, skip_serializing_if = "is_false")]
        str_fat: bool,
    },
    /// Join-ambiguous use inserted by `version.rs`: two or more reaching
    /// definitions with no dominance order (needs phi nodes, which SA lacks).
    /// Never renders to a real read: `const_needs_loud` maps it loud, and
    /// both lower and coverage count it through the shared predicate.
    Conflict {
        place: String,
        /// The projection the read had (a field read keeps its offset).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proj: Option<PlaceProj>,
    },
}

impl Operand {
    /// Field-projection metadata when this operand reads through an aggregate
    /// place (see [`PlaceProj`]); `None` for constants, joins and plain locals.
    pub fn proj(&self) -> Option<&PlaceProj> {
        match self {
            Operand::Move { proj, .. } | Operand::Copy { proj, .. } => proj.as_ref(),
            _ => None,
        }
    }
}

/// Max string-literal bytes materialized inline per `&str` field (byte-wise
/// `store`s; longer literals stay loud UNSUPPORTED).
pub const STR_INLINE_MAX: u64 = 64;

#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "kind")]
pub enum Term {
    Goto { target: String },
    /// `ret` is the resolved return register (MIR returns through local `_0`,
    /// renamed by `version.rs`); `None` when unresolved and
    /// `__VERSION_CONFLICT__` when a join gives two reaching versions.
    Return {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ret: Option<String>,
    },
    Resume,
    Call {
        func: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        func_raw: Option<String>,
        #[serde(default)]
        args: Vec<Operand>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        dest: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<CallSig>,
        /// An `Option` method the backend inlines (the receiver's
        /// discriminant layout).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        opt_shim: Option<OptShim>,
        /// `slice::len` / `str::len`: the fat pointer's length word.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        slice_len: Option<SliceLen>,
        /// `&[T]` / `&Vec<T>` slice iteration: element size and word offsets.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        slice_iter: Option<SliceIter>,
        /// A `PartialEq::ne` call: the local `eq` to call instead, negated.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        negate_eq: Option<String>,
        /// A primitive method inlined by the backend (`abs`, `min`, `max`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        prim_shim: Option<PrimShim>,
        /// A `Vec` operation inlined by the backend.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        vec_shim: Option<VecShim>,
    },
    Drop { place: String, target: String },
    SwitchInt { discr: Box<Operand>, #[serde(default)] targets: Vec<(String, String)>, otherwise: String },
    Assert { cond: Box<Operand>, target: String, #[serde(default, skip_serializing_if = "Option::is_none")] msg: Option<String>, #[serde(default, skip_serializing_if = "Option::is_none")] expected: Option<bool> },
    Unreachable,
    InlineAsm {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        template: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        options: Option<String>,
        #[serde(default)]
        modifiers: bool,
        #[serde(default)]
        inout: bool,
        #[serde(default)]
        outs: Vec<String>,
        #[serde(default)]
        ins: Vec<Operand>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },
    Unsupported { text: String },
}

pub fn is_false(b: &bool) -> bool {
    !b
}
