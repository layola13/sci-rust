//! macros_app: bin crate that calls into `macros_lib` across the crate
//! boundary. `sars run` must resolve the callees via `@import "macros_lib.sars"`
//! (not `@extern`), and `panic!` folds to native `panic(code)` — so the
//! program runs with no broker.
use macros_lib::{double, plus_two, first_or, option_is_some, option_or, shape_area, slice_sum, sum, sum_vec, total, weight, Kind, Shape};

fn main() {
    let x = double(20);
    if x != 40 {
        panic!("bad double");
    }
    let y = plus_two(40);
    if y != 42 {
        panic!("bad plus_two");
    }
    let a = macros_lib::answer!();
    if a != 42 {
        panic!("bad answer macro");
    }
    if sum(20, 22) != 42 {
        panic!("bad sum");
    }
    let c = Shape::Circle(3);
    let r = Shape::Rect(2, 5);
    if shape_area(&c) != 6 {
        panic!("bad circle");
    }
    if shape_area(&r) != 10 {
        panic!("bad rect");
    }
    let xs = [1, 2, 3, 4];
    if slice_sum(&xs) != 10 {
        panic!("bad slice sum");
    }
    if !option_is_some(Some(7)) {
        panic!("bad is_some");
    }
    if option_is_some(None) {
        panic!("bad is_some none");
    }
    if option_or(Some(7), 0) != 7 {
        panic!("bad unwrap_or some");
    }
    if option_or(None, -1) != -1 {
        panic!("bad unwrap_or none");
    }
}
