# S19 — go2sa S2t：string 拼接 `+`（gosa `ed8668c`）

- 范围：二元/链式 `+`（字面/变量/const 全组合）+ 声明/赋值/打印/len 链路；非 string 侧一律拒收（无隐式 int→string）。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - SA 现货（`sci/sa_std/string.sa`）：`EXPAND STR_CONCAT out,l,r`（底层 `sa_string_concat` + Slice 头）；
    导入 sci 后端 `.sa`（`string.sa` + `core/slice.sa`）。
  - `isStrAdd/isStrOperand`（递归链式）+ `lowerStrConcat`（双头 `lowerStrHead` + temp 头释放）；
    `lowerStrHead` 支持 BinaryExpr/const；声明/赋值入口同步 `isStrConcat`；`strVarsSet` 补 concat 标记（根因：曾 delete 清标记）。
  - 中途 checkout 回滚教训：调试用仓内单测临时文件，绝不 checkout 跟踪文件；重做改单次小 patch 落量。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 22×（18 PASS + 4 拒收）；
  `--check` 22/22；新 `demos/22_concat`（字面/变量/链式/len）SA 与 native 一致（`foobar/hello, world/abc/foobar!/7`）；
  旧 `.sa` 仅 S2t 头再生。
- 推送：gosa `38bec7c → ed8668c` 已推 origin；sci-rust 本节 S19。
