# S17 — go2sa S2r：float 拒收指纹固化（gosa `66ce22d`）

- 范围：float 字面/签名/const 三拒收 fixture（真 Go 本体形）；lowering 未动（S2q 形状全继承），版号 S2r 为门禁侧。
- 探针结论（Go 1.24.0）：
  - `x := 1.5` → `S2i assignment rhs needs i32` + 连锁 undeclared（18 fixture 指纹 `needs i32`）。
  - `func add(a float64...)` → `S2i params must be int`（19 fixture 指纹 `must be int`）。
  - `const Pi = 3.14` → `S2q const must be int/bool/string literal`（20 fixture 指纹）。
  - struct 字段/容器元（slice/map）同样既有门禁拒收（`must be int|bool` / `slice elem must be int`）。
- 门禁：`run.sh` 20×（16 PASS + 09/18/19/20 拒收）；`--check` 同 20/20；无 `.sa` 再生。
- 推送：gosa `13be5f5 → 66ce22d` 已推 origin；sci-rust 本节 S17。
