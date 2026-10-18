# S8 — go2sa S2i：P2 types.Info 类型驱动 i32（gosa `f1fbbb7`）

- 范围：`types.Info.Types` 透入 lowering，替代手写 `isIntType` 语法检查；P1 门不变；lowering 形状不变。
- 实现（`internal/go2sa/{go2sa.go,lower.go}`，只改已有文件）：
  - `TranspileSA` 建 `Types map` 并传 `saLowerFile(fset, f, info)`；`saGen.types` 透入各函数子 scope。
  - `isI32Expr`：typed `int` 或 untyped 常量（`UntypedInt/UntypedRune` 及可默认 int 的无类型值）判 i32；`requireI32` 统一入口拒收。
  - 签名 `checkFuncSig` 走 `types.Defs` 对象（param/result 为 `Basic.Int` 才过）；表达式入口统一 `requireI32`：
    var 初值/赋值 rhs/return 值/switch tag/case 值；`isIntType` 仅留 fallback。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 9×（8 PASS + 09 拒收）；
  `--check` 9/9；`string+1` 探针仍由 P1 `go/types: mismatched types` 拒收；旧 `.sa` 仅 S2i 头再生。
- 推送：gosa `16515ae → f1fbbb7` 已推 origin；sci-rust 本节 S8。
