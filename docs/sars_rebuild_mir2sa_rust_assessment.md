# sars重建 + DEMOS + mir2sa + Rust直出评估（2026-10-18）

## 1. sars重建（zig 0.17.0, ReleaseSafe）
- 构建：`zig build -Doptimize=ReleaseSafe` EXIT 0，产物 `zig-out/bin/sars` 20M（2026-10-18 03:06）。
- 旧二进制76M（02:19，改名前构建）已退役；新二进制含双支持补丁（f6a07c7c + 1e3da032修复）。
- 验证：
  - `sars check demos/c/01_hello_world/main.sars` → check ok 5 instr
  - `sars run demos/c/01_hello_world/main.sars` → hello, saasm
  - rust_edition 5/5 check PASS（01_mutability/02_borrow_mut/03_immutable_trap/04_dyn_dispatch/05_cell）
  - demos/c全量：847/963 check PASS（失败116为预期门禁：VTableSignatureMismatch/ForbiddenSyntax/DuplicateDef/CapabilityMismatch类trap demo）
  - rosetta[0:100]：99/100 PASS

## 2. DEMOS测试结论
- 改名零回归：tracked .sa=0，tracked .sars=4529，物理盘.sa=0；`@import "*.sa"`残留0。
- 双支持生效：`.sa`与`.sars`均可check（hi.sa/hi.sars同为35 instr PASS）。
- 失败分类与改名前基线一致，属P1.1a对象安全门禁与预期trap类demo，非改名引入。

## 3. mir2sa链路（外部独立Rust工程）
- 位置：`/content/sa_all/sarust/rsc/mir2sa`（纯Rust parse+lower，14模块约5862行）+ `rsc/driver`（rustc_private真劫持）。
- 状态：真跑通（TEST_LOG T0-T5）：cargo demo → rsc_driver劫持MIR（APPROX=0）→ mir2sa lower → .sa，保真对账DRIVER_FIDELITY_OK / CORPUS_FIDELITY_OK。
- 与本仓对接验证（新sars）：
  - `examples/hi.sa` → check ok 35 instr（.sa/.sars双扩展名同PASS）
  - `examples/corpus.sa` → UseAfterMove trap（Referee层预期，parse-trap归零后下一阶段工作）
  - `examples/real_driver.sa` → ForbiddenSyntax（旧产物含未lower完全的占位行，属mir2sa侧待修，不阻塞本仓）
- 输出扩展名：mir2sa当前`--out <out.sa>`；本仓双支持下`.sa`仍可消费，建议后续mir2sa默认改出`.sars`（仅改名，不改落法），保持前向兼容。

## 4. 是否马上在sci-rust内新增Rust工程直出SA？JEV裁决：否（选项a）
- 理由：
  1. mir2sa已在sarust独立Rust工程真跑通，重复新建造成双维护（lower落法/STD_MAP/保真计数需两边同步）。
  2. sci-rust是Zig编译器仓，混入Cargo workspace会污染`zig build`指纹与CI（rustc_private nightly pin、sysroot直调build.sh与zig构建范式冲突）。
  3. 当前瓶颈不在“有无Rust工程”，而在Referee层trap收敛（corpus UseAfterMove类）与mir2sa占位行lower完备度，新建工程零增益。
- 决策：暂不在sci-rust新建Rust工程；保持`外部mir2sa + 本仓适配文档（docs/rust_edition_mir2sa.md）`结构；仅当mir2sa需消费本仓`sars` Rust Edition新语义（&mut strict/Copy elision/Cell豁免）时，以文档对齐表驱动，不以代码搬迁驱动。
- 触发新建工程的门槛（任一满足再议）：mir2sa需随sars同版本原子发布；CI要求单仓`zig build + cargo test`一键闭环；mir2sa落法与sla/sars分叉到需共享Zig AST库。
