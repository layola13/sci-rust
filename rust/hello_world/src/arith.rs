//! arith: same-crate call + overflow-checked arithmetic demo for the
//! end-to-end check. `main` calls local `add` (no `@extern` for same-crate
//! callees); the bad-arith `panic!` folds to native `panic(code)`, so
//! `sars run` executes with no broker needed (zero `@extern`).
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
