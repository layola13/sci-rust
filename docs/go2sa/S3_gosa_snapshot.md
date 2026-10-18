# S3 — gosa 快照指针（go2sa 编译目标，不 vendor 源码）

- gosa 独立仓：`https://github.com/layola13/gosa`（JEV 裁决：仅文档 + 指针，不 vendor；sci-rust 无 third_party/vendor 惯例）。
- 快照：`HEAD=9690602`（`s2d: C式for(init;cond;post)+++/-- + 05_for pass`）；tracked 24 文件（`git archive HEAD` 约 71KB）。
- 复现：
  - `git clone https://github.com/layola13/gosa && cd gosa`
  - `export PATH=$PATH:/tmp/go/bin`（Go 1.24.0）+ 后端 `/content/sa_all/sci/zig-out/bin/sa`
  - `/tmp/go/bin/go vet ./...` → exit 0；`bash demos/run.sh --check` → 5×SA-CLEAN；`bash demos/run.sh` → 5×PASS。
- CLI：`go2sa --sa [--out <dir>] <file.go> [...]`（exit 2 用法/IO，1 拒收，0 通过）；输出 `.sa + subset-report.txt` 供 `sci sa build`。
- 前置小节：S0 浅克隆取证（`/content/go shallow=true dfc6f7db`）→ S1 tsgosa 参考链路 → S2 MVP 门禁（本目录）。
- Go 源码（`/content/go`）与 gosa 源码均只留指针，不进 sci-rust 本仓。
