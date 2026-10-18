# S10 — go2sa S2k：struct 类型/构造/字段读写（gosa `7da493c`）

- 范围：顶层 `type Name struct { f int|bool; ... }`（8B 槽布局）+ `T{k:v}/T{v,...}` 构造（缺字段零值）
  + `p.F` 读 + `p.F = v` 写；嵌入/tag/泛型/非 struct 类型/方法一律定位拒收。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - `collectStructType` 收布局（`structs` 表 + `structInfo{fields,off,size}`）；子 scope 继承 structs 表。
  - SA 现货形状（peer_findn/satsgo LayoutTable）：`alloc size` + `store base+off,v as u64` + `load base+off as u64`；
    构造 temp 以 `add` 拷贝进变量槽后释 temp；字段 store 无重绑定；`structVars` 跟踪变量 struct 身份。
  - P1 go/types 门先行；P2 `requireI32` 对 struct 右值豁免（struct 优先判）。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 11×（10 PASS + 09 拒收）；
  `--check` 11/11；新 `demos/11_struct`（keyed/positional 构造 + 字段读写 + bool 字段分支）SA 与 native 一致（`3/4/14/3/7/8`）；
  旧 `.sa` 仅 S2k 头再生。
- 推送：gosa `7f347c3 → 7da493c` 已推 origin；sci-rust 本节 S10。
