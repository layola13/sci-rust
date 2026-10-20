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

#[derive(Clone, Copy)]
pub struct Pair {
    pub a: i32,
    pub b: i32,
}

/// An enum with a payload: exercised end-to-end (construction, `match`, and
/// the discriminant) across the crate boundary.
#[derive(Clone, Copy, PartialEq)]
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
