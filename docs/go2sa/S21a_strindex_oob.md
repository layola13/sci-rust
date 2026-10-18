# S21a — go2sa S2u补环：string索引越界拒收fixture（gosa `f9ad9f0`）

- 范围：`const c="hello"; c[5]` 编译期越界拒收fixture `demos/24_strindex_oob`（`main.go` + `expect.refused`，无新lowering、无`.sa`进仓）。
- 实证（Go 1.24.0本体）：变量串`s[5]`编译通过（运行时panic）；const/字面量`c[5]/"hello"[5]`编译拒收`invalid argument: index 5 out of bounds [0:5]`。
- 拒收路径：go2sa P1 `go/types`门禁先于S2u `staticStrLen+constIndex`守卫触发；本节指纹为P1原文：`go/types:` + `index 5 out of bounds`（S2u守卫`go2sa S2u string index %d out of range`对字面量/const直连场景仍为后备）。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 24×（19 PASS + 5拒收）；`--check` 24/24。
- 推送：gosa `a87a350 → f9ad9f0`已推origin；sci-rust本节S21a。
