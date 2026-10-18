# S18 — go2sa S2s：array[N]int 定长（gosa `38bec7c`）

- 范围：`var a [N]int`（零值）+ `a := [N]int{v...}`（positional/keyed，缺值零）+ 索引读写 + `len`；
  非 int 元/非 const 长/越界/多余值/多维一律拒收；`append(array)` 由 P1 types 门天然拒收。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - 复用 slice 16B 头 + `N*8` 缓冲（`arrayLens` 记定长，`sliceVars` 标记复用索引/len/append 路径）；
    `arrayTypeOf/arrayLenOf(constIndex)`（types 常量 + 字面回退）；`lowerArrayDecl` 建头 + 逐元 store。
  - 声明（`var` 空/有值）与 `:=` 字面双入口；`isSliceVar` 统一索引/len/append 分发；子 scope 继承 arrayLens。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 21×（17 PASS + 4 拒收）；
  `--check` 21/21；新 `demos/21_array`（零值/字面/keyed/len 循环）SA 与 native 一致（`15/3/30/300/15`）；
  旧 `.sa` 仅 S2s 头再生。
- 推送：gosa `66ce22d → 38bec7c` 已推 origin；sci-rust 本节 S18。
