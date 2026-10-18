# S16 — go2sa S2q：const 求值内联（gosa `13be5f5`）

- 范围：顶层 `const N = lit` + 局部 `const x = lit`（int/bool/string 字面，types 求值内联）；
  iota/表达式/类型越界一律定位拒收；const 重赋/`++` 拒收；局部 var 遮蔽顶层 const。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - `constVals` 存求值（int/bool 文本，string 原串）+ `topConsts/localConsts` 遮蔽/不可变；
    `collectConst/evalConst`（types Types/Value，`UntypedInt/Bool` 归一）+ `lowerLocalConst/pinLocalConst`（局部落槽 pin）。
  - `lowerI32.Ident` 命中内联（int/bool 直返，string 经 `lowerConstStr` 建头）；`isStr/BoolTypeOf` 识别 const；
    `emitPrintStrHead` temp 头释放（`t_` 前缀判）；中途回滚教训：变量头不可 `!`（UseAfterMove）。
  - 中途 checkout 回滚后精益重做：不存 AST 指针，只存求值串（避递归路径问题；go/constant Kind：Bool=1/String=2/Int=3）。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 17×（16 PASS + 09 拒收）；
  `--check` 17/17；新 `demos/17_const`（顶层/局部/条件/循环）SA 与 native 一致（`42/top/hi/41`）；旧 `.sa` 仅 S2q 头再生。
- 推送：gosa `e17cc90 → 13be5f5` 已推 origin；sci-rust 本节 S16。
