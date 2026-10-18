//! arith: zero-extern arithmetic demo for the end-to-end run check.
//! MIR has no calls, so `sars run` executes with no broker needed.
#[allow(dead_code)]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

fn main() {
    let x = 20i32;
    let y = 22i32;
    let z = add(x, y);
    if z == 42 { return; }
    panic!("bad arith");
}
