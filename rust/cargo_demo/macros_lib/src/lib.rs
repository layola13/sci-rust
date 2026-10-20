//! macros_lib: `macro_rules!` + derive surface for the cargo -> MIR -> .sars
//! slice. rustc expands both before `rsc_driver` ever sees MIR, so the
//! lowering stage only has to handle the expanded scalar bodies.
//!
//! Keep the *called* surface scalar-only: MIR field projections on an
//! aggregate param are still a documented place-lowering gap
//! (rsc_driver/src/place.rs collapses `_1.0`/`_1.1` to `_1`), so struct
//! field reads go loud at verify time. Derive output is exercised by
//! expanding here even though the app only calls the scalars.

/// Generate `pub fn $name(a: i32) -> i32 { a $op 2 }`.
#[macro_export]
macro_rules! twice_op {
    ($name:ident, $op:tt) => {
        pub fn $name(a: i32) -> i32 {
            a $op 2
        }
    };
}

twice_op!(double, *);
twice_op!(plus_two, +);

/// Cross-crate macro expansion: `macros_lib::answer!()` -> `42`.
#[macro_export]
macro_rules! answer {
    () => {
        42
    };
}

pub fn sum(a: i32, b: i32) -> i32 {
    a + b
}

#[derive(Clone, Copy, Debug)]
pub struct Pair {
    pub a: i32,
    pub b: i32,
}

/// An enum with a payload: exercised end-to-end (construction, `match`, and
/// the discriminant) across the crate boundary.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Shape {
    Circle(i32),
    Rect(i32, i32),
    Empty,
}

pub fn shape_area(s: &Shape) -> i32 {
    match s {
        Shape::Circle(r) => *r * 2,
        Shape::Rect(w, h) => *w * *h,
        Shape::Empty => 0,
    }
}

/// A slice parameter: the fat pointer plus dynamic indexing.
pub fn slice_sum(xs: &[i32]) -> i32 {
    let mut total = 0;
    let mut i = 0;
    while i < xs.len() {
        total += xs[i];
        i += 1;
    }
    total
}

/// `Option::is_some` on a parameter: the discriminant test is inlined by the
/// backend (std's symbols cannot run here).
pub fn option_is_some(v: Option<i32>) -> bool {
    v.is_some()
}

/// `Option::unwrap_or` on a parameter.
pub fn option_or(v: Option<i32>, default: i32) -> i32 {
    v.unwrap_or(default)
}

/// A small "report" pipeline: builds a vector, walks a range, and folds an
/// enum. Exercises the container/enum/match/loop surface end to end.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kind {
    Small,
    Medium,
    Large,
}

pub fn weight(k: Kind) -> i32 {
    match k {
        Kind::Small => 1,
        Kind::Medium => 10,
        Kind::Large => 100,
    }
}

/// Sum of the weights of the given kinds.
pub fn total(kinds: &[Kind]) -> i32 {
    let mut sum = 0;
    let mut i = 0;
    while i < kinds.len() {
        sum += weight(kinds[i]);
        i += 1;
    }
    sum
}

/// A vector built by the caller; the library reads it back.
pub fn sum_vec(v: &Vec<i32>) -> i32 {
    let mut sum = 0;
    let mut i = 0;
    while i < v.len() {
        sum += v[i];
        i += 1;
    }
    sum
}

/// `Option` handling: `is_some` / `unwrap_or` are inlined by the backend.
pub fn first_or(v: &Vec<i32>, default: i32) -> i32 {
    if v.is_empty() {
        default
    } else {
        v[0]
    }
}

/// `for` over a slice reference: `slice::Iter` walks the data..data+len pair.
pub fn iter_sum(xs: &[i32]) -> i32 {
    let mut total = 0;
    for x in xs {
        total += *x;
    }
    total
}

/// `for` over `&Vec` (deref coercion to a slice): the idiomatic Rust form.
pub fn iter_sum_vec(v: &Vec<i32>) -> i32 {
    let mut total = 0;
    for x in v {
        total += *x;
    }
    total
}

/// `for` over `slice::iter()` (an explicit adapter call).
pub fn iter_ref_sum(xs: &[i32]) -> i32 {
    let mut total = 0;
    for x in xs.iter() {
        total += *x;
    }
    total
}

/// `for` over `Vec::iter()` (the adapter borrows the `Vec`).
pub fn iter_ref_sum_vec(v: &Vec<i32>) -> i32 {
    let mut total = 0;
    for x in v.iter() {
        total += *x;
    }
    total
}

/// Slice accessors returning `Option<&T>` (`first`/`last`/`get`).
pub fn slice_opt_sum(xs: &[i32]) -> i32 {
    let mut total = 0;
    if let Some(x) = xs.first() {
        total += *x;
    }
    if let Some(x) = xs.last() {
        total += *x;
    }
    if let Some(x) = xs.get(1) {
        total += *x;
    }
    if let Some(x) = xs.get(99) {
        total += *x;
    }
    total
}

/// A `for` loop over a range, and a string literal read by byte.
pub fn range_sum(n: i32) -> i32 {
    let mut total = 0;
    for i in 0..n {
        total += i;
    }
    total
}

pub fn first_byte(s: &str) -> u8 {
    s.as_bytes()[0]
}
