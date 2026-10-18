# S13 — go2sa S2n：for-range slice desugar（gosa `5c243c7`）

- 范围：`for i[,v] := range s`（slice 头变量）；`_`/单变量/双变量 + break/continue 复用；map/string/chan/`=` 形式一律拒收。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - desugar 到已验证 C 式 for 形状：`i=0 → load len → slt → body(v快照s[i]) → post i+1`；
    `L_for_top/body/post/end` + `loopStack/nestIsFor` 复用（range 内 break/continue 定向正确）。
  - range 变量复用已声明槽（`!x + add 0,0` 重置，不重复 declare）；`_ + _` 双空白拒收；`_i` 隐式索引槽。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet ./internal/... ./cmd/...` 0；`run.sh` 14×（13 PASS + 09 拒收）；
  `--check` 14/14；新 `demos/14_range`（双变量求和+单变量break+空白continue）SA 与 native 一致（`63/1/40`）；
  旧 `.sa` 仅 S2n 头再生。
- 推送：gosa `b66abea → 5c243c7` 已推 origin；sci-rust 本节 S13。
