# S5 — go2sa S2f：switch tag/case/default（gosa `ebecb67`）

- 范围：`switch tag { case v,...: ...; default: ... }`；`Init`/`tag-less`/`fallthrough` 拒收；case 值须 i32 可比；Go 隐式 break（臂尾自动跳 switch end）。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - guard 链（对标 satsgo switch test/body 链）：每 case `eq tag,v`（多值 `ne归一+add` 合并，规避自造 `or`）→ `EXPAND IF_ELSE` 分臂；
    臂尾非终结自动 `jmp L_switch_end`，空 `L_switch_next` 串下一 guard；default 落链尾。
  - `nestIsFor[]` 排序 for/switch 嵌套：break 定向最内层（for 内 switch 的 break 不再误跳 for）。
  - `switchStack[]` + 退栈三点同步；case 体内 `fallthrough` 预扫拒收；for 内 `continue` 不受 switch 影响。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：
  - `go vet` 0；`demos/run.sh` 7×PASS；`--check` 7×SA-CLEAN。
  - 新 `demos/07_switch`（多值 `case 2,3` + default + for 内 switch continue/break）：SA 输出与 native 一致（`20/99/1/3/4/5`）。
  - 旧 `.sa` 仅 S2f 头再生。
- 推送：gosa `e7d1ae9 → ebecb67` 已推 origin；sci-rust 本节 S5。
