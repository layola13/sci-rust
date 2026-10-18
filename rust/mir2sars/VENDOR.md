# VENDOR说明：rust/mir2sars 来源与同步策略

- 来源：`/content/sa_all/sarust/rsc/mir2sa`（binary-only crate，无lib目标，不可path依赖，只能vendor拷贝）。
- 拷贝内容：`src/*.rs` 14个模块全量（5862行，含单测），`tests/fixtures/hi.mir.json`。
- 本仓改动（仅适配层，不改lower落法）：
  - crate/bin改名 `mir2sa` → `mir2sars`，usage文本默认 `--out <out.sars>`。
  - 其余lower语义与上游逐行一致；上游演进时以本文件为基准做三方diff后同步。
- 同步命令：
  `diff -r /content/sa_all/sarust/rsc/mir2sa/src rust/mir2sars/src`
- 验证（2026-10-18，cargo 1.99.1 / sars 20M）：
  - `cargo build --manifest-path rust/Cargo.toml` → OK（1 warning沿上游）
  - `cargo test` → 67 passed, 0 failed
  - `mir2sars lower hi.mir.json --out /tmp/hi_vendor.sars` → UNSUPPORTED=2, `sars check` → ok 47 instr
