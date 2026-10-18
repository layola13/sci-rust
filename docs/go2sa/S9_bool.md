# S9 — go2sa S2j：bool 按 i32(0/1)（gosa `7f347c3`）

- 范围：`true/false` 字面 + bool 变量/参数/返回值（i32 承载，SA 形状不变）+ `!` + `&&`/`||`（无短路展开）
  + 值语境比较（`==/!=/</<=/>/>=` 进 lowerI32）+ `Println(bool)` 打 Go 真假词；其余拒收不变。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - `isI32Expr/isIntParam/isIntResult/isBoolType` 纳入 `Bool/UntypedBool`；`lowerI32.Ident` 先判真假字面；
    `!x` → `eq x,0`；`&&` → 归一 `mul`，`||` → 归一 `add`（复用 S2f 多值合并形状，无自造 `or`）；
    比较六算子进值语境（`lowerCond` 复用同一发射）。
  - `Println(bool)` types 驱动分发：`emitPrintBool`（`ne归一+EXPAND IF_ELSE` 打 `true/false` 常量 + 换行），int 保持数字形状。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 10×（9 PASS + 09 拒收）；
  `--check` 10/10；新 `demos/10_bool`（bool 函数/运算/分支/循环条件）SA 与 native 一致（`true/false/true/true/true/false/1`）；
  旧 `.sa` 仅 S2j 头再生。
- 推送：gosa `f1fbbb7 → 7f347c3` 已推 origin；sci-rust 本节 S9。
