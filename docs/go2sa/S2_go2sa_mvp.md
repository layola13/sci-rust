# S2 — gosa go2sa MVP 门禁核验（S1→S2d）

- gosa 仓：`github.com/layola13/gosa`（`go 1.24`，`HEAD=9690602 s2d`），工作树干净。
- 实现（`internal/go2sa/`，`cmd/go2sa/main.go` 薄 CLI）：
  - `go2sa.go`：`TranspileSA`（`go/parser` 解析，定位拒收）+ `RunSA`（`go2sa --sa [--out dir] <file.go>`；exit 2 用法/IO，1 拒收，0 通过）。
  - `lower.go`（S2d，561 行）：`package main + import "fmt" + func main` 子集 → SA 文本：
    S2a `main+Println(string|i32)`；S2b `var/:=` + i32 赋值 + Println 变量；S2c i32 比较 + `if/else(EXPAND IF_ELSE)`；
    S2d C 式 `for(init;cond;post)` + `++/--`。其余一律定位拒收（铁律 4）。
- SA 形状（对标 tsgosa）：`@import "sa_std/..."` + `@const utf8` 字符串池 + `@main()->i32` + `!t` 释放；`Println(i32)` 经 `sext+@sa_fmt_i64_into+@sa_print_bytes`。
- 门禁（2026-10-18 实测，Go 1.24.0 + `sci/zig-out/bin/sa`）：
  - `go vet ./...` → exit 0。
  - `demos/run.sh --check` → `01_hello/02_arith/03_vars/04_ifelse/05_for SA-CLEAN`，`pass=5 fail=0`。
  - `demos/run.sh`（e2e：`go2sa --sa → main.sa → sa build-exe → diff expected.stdout`）→ 5×`PASS`，`pass=5 fail=0`。
- 演进：`a462e5c S1 skeleton → 7d06ddf S2a → 3e28d02 S2b → 376889f S2c → 9690602 S2d`。
