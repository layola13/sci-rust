# DEMOS sars批量验证 S3（新sars 20M，改名.sars后）

## 通过率
| 目录 | PASS | FAIL | TOTAL |
|---|---|---|---|
| demos/c | 847 | 116 | 963 |
| demos/rosetta | 845 | 116 | 961 |
| demos/js | 796 | 164 | 960 |
| demos/support | 17 | 26 | 43 |
| demos/compare | 42 | 0 | 42 |
| demos/rust_edition | 5 | 0 | 5 |

- run抽验：`demos/c/01_hello_world` → hello, saasm；`rust_edition/04_dyn_dispatch` → rc=0。

## 失败定性（全部预期，非改名回归）
- demos/c 116 fail = 110×VTableSignatureMismatch + 2×ForbiddenSyntax + 2×DuplicateDef + 1×ImportResolutionFailed + 1×CapabilityMismatch。
  - VTableSignatureMismatch是P1.1a对象安全门禁（verifier.zig:670-671：vtable slot首参须`&self: ptr` borrow）；
    老demo如`114_callback_from_c`用`@add_one(x: i32)`旧写法被拦，属预期；
    新范式`rust_edition/04_dyn_dispatch`用`@button_draw(&self: ptr)`全过。
  - ForbiddenSyntax/DuplicateDef/CapabilityMismatch/ImportResolutionFailed是包循环/影子/契约mismatch类预期失败demo（205/207/226/227/243/502）。
- demos/support 26 fail全部是负例fixture（BorrowConflict/ConstMutation/MemoryLeak/UseAfterMove/PhiStateConflict等各1个trap，属测试资产）。
- demos/js 164 fail待下节按trap分类复核（本节只记录数）。
