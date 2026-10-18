# S14 — go2sa S2o：map[int]int 经 btree（gosa `62b4f9b`）

- 范围：`make(map[int]int)` + `m[k]=v` + `m[k]`（缺键 0）+ `len(m)` + `delete(m,k)`；
  非 int 键值/composite literal/双值读/遍历一律定位拒收。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - SA 现货（`sci/demos/rosetta/81_kv_store/main.sa` + `sci/sa_std/{btree_map.sa,core/slice.sa}`）：
    `EXPAND BTREE_MAP_NEW/INSERT` + `call @sa_btree_map_try_get/len/remove` + `SLICE_NEW`；
    导入用 sci 后端 `.sa` 后缀（sci-rust `.sars` 不被 sci `sa` 解析）。
  - int 键编码 8B 切片（`alloc 8 → store → alloc 16 → SLICE_NEW`）；读写/删后释 key/slot；
    len/load 返回登记 call-temp；`mapVars` 跟踪（声明/赋值同步）；索引读写优先分发 map 再 slice。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 15×（14 PASS + 09 拒收）；
  `--check` 15/15；新 `demos/15_map`（写/读/len/改/删）SA 与 native 一致（`10/20/2/30/1/20`）；旧 `.sa` 仅 S2o 头再生。
- 推送：gosa `5c243c7 → 62b4f9b` 已推 origin；sci-rust 本节 S14。
