# S0 — golang 源码浅克隆取证 (`/content/go`)

- 位置：`/content/go`（gosa 只读移植源，不进 gosa/sci-rust 本仓）。
- 远端：`origin https://github.com/golang/go.git (fetch/push)`。
- 浅克隆：`git rev-parse --is-shallow-repository` → `true`。
- HEAD：`dfc6f7db9bd75868ffb5cbc9501a2f4899122d2f 2026-10-07 cmd/compile: save and restore base.Pos some places where it's set`。
- 分支：`master...origin/master`（干净，无本地修改）。
- 底座存在性（go2sa 前端依赖）：
  - `src/go/parser/`：`parser.go resolver.go interface.go` 等存在。
  - `src/cmd/compile/internal/`：`ir/ gc/ escape/ inline/` 等存在。
- 用途：gosa 优先用标准库 `go/parser` + `go/types` 做前端（`TranspileSA`），不整体搬迁 Go 源码。
- 取证时间：2026-10-18；取证方式：`git -C /content/go rev-parse/log/remote/status + ls src/...`。
