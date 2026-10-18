//! arith: same-crate call + overflow-checked arithmetic demo for the
//! end-to-end check. `main` calls local `add`/`sub`/`mul` (no `@extern`
//! for same-crate callees); the bad-arith `panic!` folds to native
//! `panic(code)`, so `sars run` executes with no broker needed
//! (zero `@extern`).
#[allow(dead_code)]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[allow(dead_code)]
fn sub(a: i32, b: i32) -> i32 {
    a - b
}

#[allow(dead_code)]
fn mul(a: i32, b: i32) -> i32 {
    a * b
}

fn main() {
    let z = add(20i32, 22i32);
    if z != 42 {
        panic!("bad add");
    }
    let d = sub(50i32, 8i32);
    if d != 42 {
        panic!("bad sub");
    }
    let m = mul(6i32, 7i32);
    if m != 42 {
        panic!("bad mul");
    }
}
