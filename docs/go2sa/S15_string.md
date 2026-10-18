# S15 — go2sa S2p：string 变量（gosa `e17cc90`）

- 范围：string 变量声明/赋值（字面/变量拷贝）+ `Println(string var)` + `len(string var)`；
  拼接/索引/切片/比较一律定位拒收（后续）。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - 16B `{ptr,len}` 头（复用 Println 字面形状）：声明/赋值建头拷贝（`alloc 16 + load ptr/len + store`）；
    `strVars` 跟踪（声明/赋值同步）；`isStrTypeOf` types 驱动分发打印（变量走 `emitPrintStrHead`，字面保持旧径）。
  - `len(string var)` 复用头 `+8` 装载；`lowerStrHead` 统一字面/变量建头；子 scope 继承 strVars。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 16×（15 PASS + 09 拒收）；
  `--check` 16/16；新 `demos/16_string`（声明/打印/len/拷贝/重赋）SA 与 native 一致（`hello/5/hello/world!/6/hello`）；
  旧 `.sa` 仅 S2p 头再生。
- 推送：gosa `62b4f9b → e17cc90` 已推 origin；sci-rust 本节 S15。
