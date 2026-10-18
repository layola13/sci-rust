# S20 — go2sa S2u：string 索引 `s[i]` 读字节为 i32（gosa `a87a350`）

- 范围：`s[i]` 读（const 索引 + 变量/循环动态索引）→ byte(uint8) → i32（Println/赋值/算术走 i32 链路）；`s[i]=` 写拒收（只读）；`int(s[i])` 转换不支持（按铁律 4 拒收，不静默支持）。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - `isI32Expr` 补 `gotypes.Uint8`（byte 即 uint8）；`lowerIndexLoad` 遇 `isStrTypeOf(n.X)` 分发 `lowerStrIndexLoad`。
  - `staticStrLen`（字面量 `strconv.Unquote` + const string）+ `constIndex` 做编译期越界拒收；`lowerStrIndexLoad` 复用 16B 串头 + slice 槽 load：`load head+0 as ptr; ptr_add base,ix; load addr+0 as u8; !addr`（头 temp `t_*` 才释放，变量寄存器不释放）。
  - 泄漏修复：`ptr_add` 产生的 `addr` 必须 `!addr`（对照 `sci/demos/c/04_loop/main.sa` `slot = ptr_add arr, i … !slot`；slice lowering 复用 base 无此问题）；`lowerIndexStore` 遇 string 直接 `read-only` 拒收。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 23×（19 PASS + 4 拒收）；
  `--check` 23/23；新 `demos/23_strindex`（`s[0]/s[1]/s[4]/len + for 循环 s[i]`）SA 与 native 一致（`104/101/111/5/104/101/108/108/111`）；
  旧 `.sa` 仅 S2u 头再生。
- 推送：gosa `ed8668c → a87a350` 已推 origin；sci-rust 本节 S20。
