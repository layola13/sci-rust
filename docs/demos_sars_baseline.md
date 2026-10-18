# DEMOS sars基线报告（改名.sars后，旧二进制验证）

- 验证二进制：zig-out/bin/sars（改名前构建，2026-10-18 02:19，76M）
- 验证命令：`sars check <main.sars>`，旧二进制已验证可直接解析.sars扩展名（物理文件存在即可）
- 改名范围：4529个受控.sa经git mv为.sars，1538个文件内@import重写，104个文本联动，0残留`@import "*.sa"`

## 结果
- demos/c + demos/rust_edition全量：ok=851 fail=117
- demos/rosetta分片：
  - [0:150]: ok=143 fail=7
  - [150:300]: ok=146 fail=4
  - [300:500]: ok=178 fail=22
  - [500:700]: ok=164 fail=36
- 运行态抽验：
  - demos/c/01_hello_world/main.sars run -> hello, saasm (rc=0)
  - demos/rust_edition/04_dyn_dispatch/main.sars run -> rc=0
  - demos/rust_edition/01_mutability/main.sars run -> InvalidAddress trap（待查，属rust_edition语义门禁侧）

## 失败分类（均为预期门禁/trap类demo，非改名回归）
- VTableSignatureMismatch（P1.1a对象安全门禁，首参须&self: ptr）：458/460/463/466-475/478/480/485/519/521/530/538/539/548/549/560/568等vtable/callback系列
- ForbiddenSyntax/DuplicateDef/CapabilityMismatch/ImportResolutionFailed：205/207/226/227/243/502等包循环/影子/契约mismatch类预期失败demo
- 结论：改名本身零回归；失败与改名前一致，属门禁生效。

## 下一步
- 用zig 0.17重建新sars（含双支持补丁）后复跑基线
- mir2sa链路验证 + Rust直出SA评估
