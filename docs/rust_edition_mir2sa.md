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
- 按值聚合返回：`rsc_driver` 为每个函数输出 `param_aggs`（按值聚合参数
  的字节数）；被调用方在 `_0 = <来自参数的聚合>` 处改为 `_0 = alloc N` +
  `call @sa_mem_copy(&_0, &src, N)`，复制出一份独立分配。因此
  `fn f(p: Pair) -> Pair { p }`、`fn f(p) -> Pair { let q = p; q }`、
  `fn make() -> Pair { Pair{..} }` 均可 check+run（caller 只释放自己的
  local 与结果各一次）。
- 枚举（direct tag）：`rsc_driver` 的 `discr_info` 按 rustc layout 输出
  判别式 `offset`/`ty`（`u8/u16/u32/u64`，仅 `TagEncoding::Direct`），
  `SetDisc` 同样带 `offset`/`ty`；`place_proj` 消费 `Downcast` 变体，按
  `variants[vi].field_offsets` 给出**绝对** payload 偏移。构造侧
  `enum_agg_layout` 输出 enum 大小与各字段绝对偏移，`Aggregate` JSON 附带
  `tag {variant, offset, ty}`；mir2sars 降为 `mut _agg = alloc size` +
  逐字段 `store` + tag `store`（含 0 字段的 unit 变体）。因此 3 变体
  `E::{A(i32),B(i32,i32),C}` 的构造、tag 分派、变体字段读取均可
  check+run（已验证 `pick`/`sum` 与 unit `C`）。
- `match` 汇合返回：各臂给 `_0` 不同版本、汇合块 `return _0` 时，
  `version.rs` 的 `ReturnConflict` 由 `plan_return_phi` 下沉——所有前驱都
  以无条件 `jmp` 到达、且各自定一个 `_0` 版本时，前驱 `store _ret_phi_spill`
  并在汇合块 `load` 后 `return`（无 phi，单栈槽）。非此形状仍 loud。
- 枚举 **niche tag**（`Option<&T>`/`Box<T>` 等）尚无 niche 专用判别式
  计算：`discr_info` 返回 None，driver 标 `niche: true`，mir2sars 输出
  `UNSUPPORTED niche discriminant` 占位（不再静默按 `+0 as i64` 读）。
- spill 槽去重：同一 local 可能被多个 def 重复声明 `mut *_spill =
  stack_alloc 8`（会触发 `RegisterRedefinition`）；`lower_function` 末尾
  只保留首个声明（后续 def 仍 `store` 到该槽）。
- 通用 join 槽（phi 替代）：`version.rs` 标出的 `Operand::Conflict`（join
  处同一 local 有多个到达版本）若类型为标量，`plan_join_slots` 找到每个
  到达版本的前沿块，改走栈槽：前沿 `store <local>_phi<N>_spill+0, <ver>`，
  use 点 `load <local>_phi<N>_spill+0 as ty`。因此
  `match` 各臂给同一局部量赋值、join 后再使用（如 `let mut r; match e {...}
  r`）不再 loud。
- 投影借用地址：`&(*p).f` / `&local.f` 原先退化成 `&p`（取寄存器地址，
  语义错）。driver 现在为 `Rvalue::Ref` 输出 `offset`/`projected`，
  mir2sars 降为 `ptr_add base, off`（ISA 已有 `ptr_add`）。
- `place_types` 现在按 `proj.ty` 定型（字段读是字段类型，不是基址的
  `ptr`），join 槽与 spill 的类型判定更准。
- 借用生命周期：SA 无词法作用域，`&x` 会把源寄存器锁住；join 处若一条
  路径持锁、另一条没有，就报 `PhiStateConflict`。因此普通借用（`&x`，
  borrow view）在**最后一次使用后**显式 `!` 释放（只清锁、不消耗寄存器）；
  投影借用（`ptr_add` 产生的 interior pointer）不释放（释放会消耗基址
  寄存器，污染 phi 状态）。
- 派生 `PartialEq`（枚举/结构体）：`<T as std::cmp::PartialEq>::eq` 是
  std 函数，SA 运行时无法提供。当两个实参都是「字段投影借用」时，
  `plan_inline_eq` 直接内联为字段值比较（`load` 两个字段 + `eq`），
  并跳过只为该调用服务的借用语句（不产生借用/interior pointer）。
  因此 `#[derive(PartialEq)] enum` 可 check+run。
- `call` 终结符的边是**无条件**的（除分歧调用外都会跳到 target），
  return-phi 计划据此把 `call → join` 也当作无条件边。
- 仍未覆盖：niche tag 枚举（`Option<&T>` 等）——判别式无存储槽，需要
  niche 专用计算（当前显式 loud）。

