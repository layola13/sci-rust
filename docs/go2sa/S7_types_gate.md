# S7 — go2sa S2h：go/types P1 类型门（gosa `16515ae`）

- 范围（JEV 裁决拆分，P2/P3 后续）：仅 P1 `types.Config.Check` 类型门；lowering 保持 S2g 不动。
- 实现（`gosa/internal/go2sa/go2sa.go`，`TranspileSA`）：
  - `go/parser` 去 `SkipObjectResolution`（全对象解析）→ `importer.Default()`（gc export 数据，`fmt` 可用）→ `types.Config.Check("main", fset, [f], info)`。
  - 类型错（未定义变量/arity/类型失配）一律定位拒收（`go/types: ...` 前缀，行列来自 `scanner.ErrorList`），先于 lowering。
  - JEV 仲裁 h2 着陆（`go list -export fmt` 验证可行）；`Defs/Uses` 表已建，P2 可直接消费。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0（全仓 vet 噪声系拒收 fixture 预期报错）；
  `run.sh` 9×（8 PASS + `09_typerefuse` refused-as-expected）；`--check` 同 9/9。
  新 `demos/09_typerefuse`（`undefined_var` 真 Go 本体形）：门禁拒收且指纹 `go/types:` + `undefined: undefined_var` 全中。
  旧 `.sa` 仅 S2h 头再生。
- 推送：gosa `ca4c1b4 → 16515ae` 已推 origin；sci-rust 本节 S7。
