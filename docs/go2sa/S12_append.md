# S12 — go2sa S2m：append 单值增长拷贝（gosa `b66abea`）

- 范围：`append(s, v)` 单值（返回新头，需 `s = append(s, v)` 回接）；spread/多值一律定位拒收（P2 后续）。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - `lowerAppend`：`load len/buf → newlen=len+1 → alloc newbuf/newhead → L_ap_top/body/end 循环拷贝旧元`
    `→ tail store v → head{ptr,len}`；buf/nb 即释；`isAppendCall` 豁免 requireI32；`sliceVarsSet` 纳入 append。
  - SA 形状复用 satsgo `push` 增长拷贝 + S2l 头/槽（16B 头 + 8B int 槽）；循环标签 `L_ap_*` 独立命名空间。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 13×（12 PASS + 09 拒收）；
  `--check` 13/13；新 `demos/13_append`（0 长起 append+len/索引/循环）SA 与 native 一致（`2/30/10/20/30/3`）；
  旧 `.sa` 仅 S2m 头再生。
- 推送：gosa `58fac0f → b66abea` 已推 origin；sci-rust 本节 S12。
