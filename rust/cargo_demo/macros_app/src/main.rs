//! macros_app: bin crate that calls into `macros_lib` across the crate
//! boundary. `sars run` must resolve the callees via `@import "macros_lib.sars"`
//! (not `@extern`), and `panic!` folds to native `panic(code)` — so the
//! program runs with no broker.
use macros_lib::{double, plus_two, sum};

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
}
