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
- niche tag 枚举（`Option<&T>` 等）：判别式没有存储槽，由 niche 字段的值
  决定（空指针 = niche 变体）。driver 输出 `niche_offset`/`none_variant`/
  `some_variant`，mir2sars 降为「读 niche 槽 + 与 0 比较」；构造侧
  `niche_store` 把 niche 值写入槽内，单字段 niche 枚举也按聚合物化
  （`alloc` + `store`），因此 `Option<&T>` 可 check+run。
- switch 判别式不再复制到临时寄存器：各臂直接读判别式 place，避免临时量
  只在「落空路径」被释放导致 join 处寄存器状态不一致（`PhiStateConflict`）。
- 单字段 ADT 聚合（`struct W(i32)`、niche 枚举）现在也按聚合物化
  （`alloc` + `store`），局部量持有聚合地址（与 `agg: true` 借用一致），
  按值传参/返回因此正确。
- 解引用投影（`*p`）：driver 的 `place_proj` 之前只保留含字段的投影，
  纯解引用被丢掉（读到的是基址寄存器而非其指向的值）。现在保留
  （offset 0 + 被指类型），`match` 分支里的 `*w * *h` 因此正确。
- 值位置上的投影读（算术/调用实参）先物化成临时量
  （`materialize_projected_operands`）：SA 的值位置不能嵌套 load。
- 有序比较/除法/移位按**有符号性**分派：driver 输出操作数的有符号性，
  mir2sars 选 `slt/ult`、`sdiv/udiv`、`ashr/lshr` 等 ISA 助记符，
  `while i < n` 这类循环因此可运行（之前 loud）。
- 关联函数（impl 方法、派生 `Shape::eq`）用完整路径命名
  （`Shape_as_std_cmp_PartialEq_eq`）：不同 impl 的同名方法不再互相混淆，
  跨 crate 调用仍用短名（与 `--dep` 导入一致）。
- 聚合借用（`&local`）从属主的 spill 槽重载，不再把聚合存储的所有权
  转给借用方：同一聚合被借用两次不再 UseAfterMove。
- 共享引用（`&x`）：SA 的 `&x` 语义是「重借用 x 里的指针」，标量不能直接
  取地址。因此 `&scalar` 降为「把值复制进缓冲区 + 传缓冲区地址」
  （`alloc` + `store`，借用结束时释放）；指针值的借用仍是 reborrow。
  `fn deref(x: &i32) -> i32 { *x }` 因此可运行。
- 聚合元素类型：driver 按 ADT 字段类型输出 `elem_tys`，mir2sars 据此给
  每个字段 `store` 定型（`&i32` 字段存 `ptr`，不再当 `u64` 槽）。
- 常量聚合（`&Enum::Variant(..)`）：driver 取该常量自身的 MIR，把它的
  构造（`Aggregate`）输出为 `ConstAgg`，mir2sars 像内联聚合一样物化。
- 借用释放不再重复释放：借用的最后一次使用若是**消耗性**的（take/move），
  借用已随取走结束，不再额外 `!`（否则双重释放）。
- `&T as PartialEq` 的调用解析：std 的 `impl PartialEq for &T` 只是转发到
  `T::eq`，driver 现在把这种调用解析到**本 crate 的派生实现**（否则是一个
  跑不了的 std 符号）。
- 借用释放只在「借用到函数返回为止」时插入：中途释放只发生在部分路径上，
  join 处会看到「已释放 vs 仍存活」的状态冲突；其余情况由函数出口统一释放。
- 带类型的常量（`Ty(usize, 3_usize)`）现在按值输出
  （`Val(Scalar(0x..), usize)`）：此前它们的 Debug 文本不是后端能解析的值，
  数组长度这类比较会走 loud。
- 调用实参若是**溢出(spill)过的值**，现在从槽重载到临时量再传入
  （`load` 表达式不是合法实参位）；否则实参会「移动」属主，调用方再借用
  同一属主就会 UseAfterMove / join 状态冲突。
- **提升常量**（promoted const，如 `&Enum::Variant(..)`）：driver 从
  `tcx.promoted_mir` 取出该提升体的 MIR，把它的构造输出为 `ConstAgg`，
  mir2sars 像内联聚合一样物化（此前是 loud，调用方会读到空指针）。
- **数组下标** `a[i]`：driver 解析 `Index` 投影（索引局部量 + 元素大小），
  mir2sars 降为 `mul index, size` + `ptr_add base, off` + `load`（ISA 的
  `ptr_add` 接受寄存器偏移 ✓）。MIR 的 `BoundsCheck` 断言折叠成 panic ✓。
- **循环携带的局部量**：在循环里被读取的局部量（数组、结构体地址等）现在
  会被溢出(spill)到槽，使用点重载：否则循环体里的拷贝会「移动」属主，
  下一轮迭代就变成 UseAfterMove / join 状态冲突。
- **切片** `&[T]`：按插件的 Dyn/胖指针模型（数据字 + 长度字，一个
  16 字节聚合）实现——driver 输出 unsizing 强制转换的目标布局与源长度，
  mir2sars 构造胖指针；切片元素访问时先加载数据字再叠加下标
  （`deref_base`）。`&[T; N]` -> `&[T]` 的强制转换因此可运行。
- **字符串字面量**（`&str`）：按同一套胖指针模型实现——driver 标记
  `str_fat`（`&str`/`&[u8]` 是胖指针，`&[u8; N]` 是瘦指针），mir2sars 把
  字节缓冲 + 长度字构造成胖指针；`str::as_bytes` 是恒等（同一胖指针）。
  字节缓冲在函数出口释放（胖指针本身被调用方消费）。
- `Option`/`Result` 方法（`is_some`/`is_none`/`is_ok`/`is_err`/`unwrap_or`）：
  driver 解析接收者的判别式布局（tag 偏移/类型、带载荷的变体索引、载荷
  偏移/类型）并输出 `opt_shim`，mir2sars 内联为「读判别式 + 比较」
  （`unwrap_or` 用分支实现，ISA 没有 `select`）。这些 std 符号不再需要
  broker。
- `slice::len` / `str::len`：胖指针的长度字（driver 给出偏移，mir2sars 内联
  为一次 load）——循环里按切片长度迭代的常见写法因此可运行。
- cargo 演示工程（`rust/cargo_demo`）现在覆盖：跨 crate 的**枚举 + match**、
  **切片**（胖指针 + 动态下标 + `len`）与 **`Option` 方法**（`is_some`/
  `unwrap_or`），全部经 `cargo -> MIR -> .sars -> sars run` 跑通。
- `unwrap_or` 的默认值放在**帧槽**里读（而不是拷贝）：拷贝会在一条路径上
  消耗寄存器，join 处两条路径的状态就不一致（`PhiStateConflict`）。
- **在分支里赋值、随后读取**的值（`let o = if c { Some(x) } else { None };`
  之后 `match o`）：版本阶段保留冲突信息（`Operand::Conflict` 带上投影），
  join 槽机制按路径计算**判别式**（各分支把 tag 写进槽）与**基址**
  （字段读先从槽里取地址再加偏移）。因此分支里造出的 `Option`/枚举
  之后可以 `match`。
- 仍未覆盖：**泛型函数/泛型枚举**里的 `T: PartialEq`（泛型 MIR 的类型未知，
  字段偏移依赖具体类型）。
- 仍未覆盖：`!=`（`PartialEq::ne` 是 std 的默认方法，转发到 `eq`）；把它
  改写成本地 `eq` 会与派生 `eq` 内部的 `!=` 递归，故仍保留为 std 符号。
- 仍未覆盖：**泛型枚举**的字段比较：泛型函数的 MIR 里局部类型仍是 `T`，
  字段偏移依赖具体类型（无法静态解析），派生 `PartialEq` 的字段比较因此
  仍是 loud。
- `for i in a..b`（`Range<T>`）：std 的迭代器协议在 mir2sars 内联——
  `IntoIterator::into_iter` 退化为恒等，`Iterator::next` 展开为「读游标/
  上界 → 比较 → 构造 `Option<(T,)>` → 游标加一」的 SA 代码（布局取自
  MIR：range 字段偏移、判别式偏移与类型、payload 偏移）。`&mut self`
  借用临时量被跳过（它的拷贝会消耗循环携带的迭代器）。
  `for _ in 0..n`（循环体不读值）也支持（payload 偏移可缺省）。
- `.rev()` 适配器：`Range::rev()` 产生 `Rev<Range<T>>`（range 的 newtype，
  共享同一块存储）→ 退化为恒等；`Rev::next` 用降序游标（游标是上界，
  产出 `cursor - 1`）内联。
- 仍未覆盖：`for` 遍历 **非 range** 迭代器（`Vec`/切片/`iter()`）与
  `.step_by()`/`.take()` 等其他适配器——需要 std 的容器迭代器实现。

