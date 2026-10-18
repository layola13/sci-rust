# S21b — go2sa S2u补环：string索引写拒收fixture（gosa `108501c`）

- 范围：`s := "hello"; s[0] = 120`只读拒收fixture `demos/25_strindex_store`（`main.go` + `expect.refused`，无新lowering、无`.sa`进仓）。
- 实证（Go 1.24.0本体）：`s[0] = 120`编译拒收`cannot assign to s[0] (neither addressable nor a map index expression)`。
- 拒收路径：go2sa P1 `go/types`门禁先于S2u `lowerIndexStore`守卫触发；本节指纹为P1原文：`go/types:` + `cannot assign to s[0]`（S2u守卫`go2sa S2u string index is read-only`仍为后备）。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 25×（19 PASS + 6拒收）；`--check` 25/25。
- 推送：gosa `f9ad9f0 → 108501c`已推origin；sci-rust本节S21b。
