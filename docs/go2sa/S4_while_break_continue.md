# S4 — go2sa S2e：while 式 for + break/continue（gosa `e7d1ae9`）

- 范围：`for cond { }`（无 init/post）+ 无标号 `break/continue`；`for { }`（无 cond）仍拒收；标号 break/continue 拒收；for 外 break/continue 拒收。
- 实现（`gosa/internal/go2sa/lower.go`，铁律 1/5/6：只改已有 lowering + 薄 CLI）：
  - `loopTarget{top,post,end}` + `loopStack`：continue 跳 `L_for_post_*`（有 post）/ `L_for_top_*`（while 无 post），break 跳 `L_for_end_*`。
  - `L_for_post_*` 标签恒发射（空 post 即空标签，continue 落点统一）。
  - `term` terminated 跟踪（对标 satsgo `terminated`/tsgosa step2）：branch 置位；`lowerBlock` 遇终结后语句定位拒收；
    `lowerIfStmt` 终结臂吞默认 `jmp L_end`（修 `EXPAND IF_ELSE` 后双 jmp 导致的 `FallthroughForbidden`）。
  - 独立 `i++/j--` 语句补分发（`lowerStmt += IncDecStmt`）。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`，2026-10-18）：
  - `go vet ./...` → 0；`demos/run.sh` → 6×PASS；`--check` → 6×SA-CLEAN。
  - 新 fixture `demos/06_while`（while + continue 跳 3 + break 停 8 + `j%2` 过滤求和）：SA 输出与 `go run` native 逐字节一致（`1 2 4 5 6 7 9 / 9`）。
  - 旧 demo `.sa` 再生：仅 S2e 头 + `L_for_post_*` 标签（语义不变，e2e 全过）。
- 推送：gosa `9690602 → e7d1ae9` 已推 origin；sci-rust 本节 `S4` 文档。
