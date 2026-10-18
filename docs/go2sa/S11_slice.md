# S11 — go2sa S2l：slice make/索引读写/len（gosa `58fac0f`）

- 范围：`[]int`（16B `{ptr,len}` 头 + int 8B 缓冲，satsgo 数组形状）+ `make([]int,n[,cap])` + `s[i]` 读写 + `len(s)`；
  append/切片/range/多维/拷贝一律定位拒收（P2 后续）。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - `lowerMakeSlice`：`mul n,8 → alloc buf → alloc 16 head → store ptr/len`（变长 alloc 经 SA 现货探针验证 BUILD=0）；
    buf/nb 即释；`sliceVars` 跟踪头变量（声明/赋值拷贝释放同步，struct 同形）。
  - `lowerIndexLoad/Store`：`load head+0 → mul i,8 → add → load/store +0 as u64`；`lowerLen`：`load head+8`。
  - `lowerCallValue` 前置分发 make/len；`=`/`:=` 右值 make 豁免 requireI32；索引/长度入口类型门。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 12×（11 PASS + 09 拒收）；
  `--check` 12/12；新 `demos/12_slice`（make+写+读+len 循环求和）SA 与 native 一致（`5/10/30/60`）；旧 `.sa` 仅 S2l 头再生。
- 推送：gosa `7da493c → 58fac0f` 已推 origin；sci-rust 本节 S11。
