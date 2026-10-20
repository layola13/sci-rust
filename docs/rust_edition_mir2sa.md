# mir2sa → sars Rust Edition 对齐说明

`sarust/rsc/mir2sa`（MIR → SA 后端）与本仓库 `sars --edition rust`
的落法对齐表。MIR 侧 borrowck 已验证，`sars` 侧 Referee 复验。

| MIR (rustc) | sars SA（`--edition rust`） | 备注 |
|---|---|---|
| `let x` 不可变绑定 | `x = alloc N`（默认 `0x101`） | 无需 `mut` 即 ConstMutation 拦截写 |
| `let mut x` | `mut x = alloc N`（`0x01`） | 显式可变 |
| `&x` 共享借用 | `r = &x`（borrow/read） | 多共享允许 |
| `&mut x` 独占借用 | `r = &mut x` / `r = borrow mut x` | `--rust-strict-mut` 下共享写直接 trap |
| `Copy` 标量多次使用 | ephemeral scalar + `--rust-copy-elision` | `move`/`assign` 不消费 |
| `Cell` 内部可变 | `InteriorPtr` 豁免 Immutable 写保护 | `isImmutableConst` 对派生指针放行 |
| `trait` 方法（`&self`） | vtable slot 首参 `&self: ptr` | 否则 `VTableSignatureMismatch (1024)` |
| `dyn Trait` fat object | `sa_std/dyn.sars`：16B `[data][vtable]` + `DYN_NEW/DYN_FREE` | `TRAIT_DISPATCH` 宏做 slot 分发 |
| `drop(x)` | `!x` | Copy 标量在 edition 下可省略 |
| 聚合字段读 `_1.0` | `_d = load _1+off as ty` | driver `place_proj` 出 layout offset |
| 聚合字段写 `_1.0 = v` | `store _1+off, v as ty` | 透写 storage，不改绑 base local |
| 检查算术 dest `(_d.0,_d.1)` | 折叠回 `_d` | `EXPAND` 宏已 trap，无元组实体 |
| 后端 alloc / stack_alloc | 一律 `mut …` | edition 默认不可变，否则 ConstMutation |
| ptr 参数 / 指针别名拷贝 | 不 exit-free | 否则跨帧 double-free（InvalidAddress） |

`sars` 二进制（原 `sa`）用法：

```
sars check --edition rust main.sars
sars build-exe --edition rust main.sars -o main
```

负例速查：`demos/rust_edition/03_immutable_trap`（ConstMutation）、
`demos/rust_edition/02_borrow_mut`（strict &mut）、
`demos/rust_edition/04_dyn_dispatch`（dyn）、
`demos/rust_edition/05_cell`（Cell）。

## 完整 cargo 工程（workspace → .sars）

真实 rustc 负责全部 front-end（含宏展开），`rsc_driver` 既可作为
独立 `rustc`、也可作为 cargo 的 `RUSTC_WORKSPACE_WRAPPER`：

```
# rsc_driver 作为 wrapper：每个 workspace crate 落一个 mir.json，
# 同时返回 Compilation::Continue，让 rustc 照常产出 rlib/bin。
RUSTC_WORKSPACE_WRAPPER=rust/rsc_driver/target/rsc_driver \
RSC_OUT_DIR=<out> cargo build
```

随后逐 crate lower，依赖通过 `@import` 链接而非 `@extern`：

```
mir2sars lower <out>/macros_lib.mir.json --out <out>/macros_lib.sars
mir2sars lower <out>/macros_app.mir.json  --out <out>/macros_app.sars \
    --dep <out>/macros_lib.mir.json=macros_lib.sars
sars check --edition rust --project-root <repo> <out>/macros_app.sars
sars run   --edition rust --project-root <repo> <out>/macros_app.sars
```

一键回归：`rust/cargo_demo/run.sh`（2 crate workspace：`macro_rules!`
跨 crate + `#[derive(Clone, Copy)]`，`sars check` 181 instr / `sars run`
exit 0，无 broker）。

已知 gap（lower 质量，非宏展开）：
- 聚合**字段投影**已实现：`rsc_driver/src/place.rs::place_proj` 输出
  `(offset, ty, via)`，mir2sars 读侧降为 `_d = load base+off as ty`、
  写侧降为 `store base+off, val as ty`（`dest_proj`）。聚合参数/局部字段
  读写、派生 `PartialEq`（同 crate `@eq` 解析）均可运行。
- 指针别名安全：`ptr` 参数与其别名拷贝（`_3 = _1`、`agg` ref）不参与
  exit-free，避免释放调用方 storage。
- 仍未覆盖：**按值聚合“返回一个来自参数的值”**会与调用方 local 共享
  storage，调用方对 result 与 local 各释放一次 → double-free
  （`fn f(p: Pair) -> Pair { p }`）。被调用方返回**自有 local** 的聚合
  则正常（`fn make() -> Pair { Pair{..} }`）。枚举 `Downcast` 投影仍折叠。

