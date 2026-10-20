//! macros_app: bin crate that calls into `macros_lib` across the crate
//! boundary. `sars run` must resolve the callees via `@import "macros_lib.sars"`
//! (not `@extern`), and `panic!` folds to native `panic(code)` — so the
//! program runs with no broker.
use macros_lib::{double, plus_two, first_byte, first_or, iter_ref_sum, iter_ref_sum_vec, iter_rev_sum, iter_enum_sum, iter_step_sum, iter_take_sum, iter_zip_sum, slice_opt_sum, iter_sum, iter_sum_vec, option_is_some, option_or, range_sum, shape_area, slice_sum, sum, sum_vec, total, weight, Kind, Shape};

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
    if iter_sum(&xs) != 10 {
        panic!("bad iter sum");
    }
    let mut vs: Vec<i32> = Vec::new();
    vs.push(4);
    vs.push(6);
    if iter_sum_vec(&vs) != 10 {
        panic!("bad iter sum vec");
    }
    if iter_ref_sum(&xs) != 10 {
        panic!("bad iter ref sum");
    }
    if iter_ref_sum_vec(&vs) != 10 {
        panic!("bad iter ref sum vec");
    }
    if slice_opt_sum(&xs) != 7 {
        panic!("bad slice opt sum");
    }
    if iter_rev_sum(&xs) != 10 {
        panic!("bad iter rev sum");
    }
    if iter_take_sum(&xs) != 3 {
        panic!("bad iter take sum");
    }
    if iter_step_sum(&xs, 2) != 4 {
        panic!("bad iter step sum");
    }
    if iter_step_sum(&xs, 1) != 10 {
        panic!("bad iter step sum one");
    }
    if iter_step_sum(&xs, 10) != 1 {
        panic!("bad iter step sum past end");
    }
    if iter_enum_sum(&xs) != 16 {
        panic!("bad iter enum sum");
    }
    let ys = [4, 3, 2, 1];
    if iter_zip_sum(&xs, &ys) != 20 {
        panic!("bad iter zip sum");
    }
    let ys2 = [4, 3];
    if iter_zip_sum(&xs, &ys2) != 10 {
        panic!("bad iter zip short");
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
