# S1 — 参考 tsgosa 新建 gosa（go2sa）链路解析

- 参考源：`tsgosa` = microsoft/TypeScript 原生 Go 版（`internal/*: parser/binder/checker`），`satsgo` 在其上叠 `internal/saemit/*.go` 做 `ts→sa`（subset gate + SA-ASM 发射 + `sa.mod/src/build.sh` 脚手架）。
- satsgo 管线（`satsgo/SA_TS_TO_SA_DESIGN.md`）：`.ts → tsgo parser → subset gate("ts"中间件) → internal/saemit → .sai+sa.mod+subset-report.txt → sci sa build → .exe/.wasm`；stdlib 零模拟，全投影 `sci/sa_std`，无符号定位拒绝。
- gosa 映射（`gosa/AGENTS.md` 六铁律，与 tsgosa 同构，前端换 Go）：
  - `.go --[parser+types: go/parser+go/types]--> 分析 --[middle: desugar]--> 中转 --[emit: SA text+sci宏]--> .sa+subset-report.txt --[sci sa build]--> .exe/.wasm`
  - 单文件口径 `TranspileSA`（`main` 包优先）；只改已有文件（`internal/go2sa/*.go` + `cmd/go2sa/main.go` 薄 CLI）；SA 形状以 `tsgosa/demos/*.sai` 为范本（`!t` 释放、`@import` 映射、`EXPAND` 宏）；`sci/sa_std` 现货符号直接映射，无符号定位拒绝。
- 门禁同构：`demos/run.sh`（`main.go→go2sa --sa→main.sa→sa build-exe→diff expected.stdout`；`--check` 逐字节比对，`.sa` 禁手改；`expect.refused` 指纹拒收）。
- 结论：gosa 不是另起 lowering 体系，而是 tsgosa 链路的 Go 前端替换；S2d 已按此落地（详见 S2）。
