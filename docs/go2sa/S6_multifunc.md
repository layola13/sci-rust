# S6 — go2sa S2g：多函数 i32 参数/返回值 + 调用 + return（gosa `ca4c1b4`）

- 范围：顶层 `func name(a int, ...) [int]`（`main()` 无参无结果）；直接调用本地函数；值函数结果须使用、void 函数须语句调用；
  方法/多返回值/非 int 签名/变参/标签 break 等一律定位拒收。
- 实现（`gosa/internal/go2sa/lower.go`，只改已有 lowering）：
  - SA 现货形状（`sci/demos/compare/peer_findn.sa`）：`@name(p: i32,...) -> i32|void:` + `t = call @f(args)` / `call @f(args)` + `return v` / `return` / main `ret 0`。
  - 二阶段：先收函数表（签名 `checkFuncSig`）再逐函数隔离发射（`curFunc/funcs`）；`main` 缺失/重复/签名错拒收；值函数缺尾 return 拒收。
  - 线性释放（修 `MemoryLeak/UseAfterMove/FallthroughForbidden`）：call-temp 登记单次消费释放；
    `return v` 移交所有权不 `!`；终结函数不落尾部 `!`；switch tag 遇 call-temp 转隐式 var 复用；Println 先发射后释放。
- 门禁（Go 1.24.0 + `sci/zig-out/bin/sa`）：`go vet` 0；`run.sh` 8×PASS；`--check` 8×SA-CLEAN。
  新 `demos/08_funcs`（`add` 值调用 + `printTwice` void 调用 + 嵌套 `add(1,2)`）：SA 与 native 一致（`42/3/7/8`）；旧 `.sa` 仅 S2g 头再生。
- 推送：gosa `ebecb67 → ca4c1b4` 已推 origin；sci-rust 本节 S6。
