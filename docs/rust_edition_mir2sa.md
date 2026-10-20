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
跨 crate + `#[derive(Clone, Copy)]`，`sars check` 4076 instr / `sars run`
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
- 聚合借用（`&local`）降为 `ptr_add owner, 0`（interior view），不再把
  聚合存储的所有权转给借用方：同一聚合被借用两次不再 UseAfterMove，
  借用结束也不会释放属主。interior/投影借用不产生锁，因此不做显式
  借用释放（函数出口释放时也会跳过）。
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
- `Option`/`Result` 方法（`is_some`/`is_none`/`is_ok`/`is_err`/`unwrap_or`/
  `unwrap`）：driver 解析接收者的判别式布局（tag 偏移/类型、**带载荷的变体
  索引**、载荷偏移/类型）并输出 `opt_shim`，mir2sars 内联为「读判别式 +
  与带载荷变体索引比较」（`unwrap_or`/`unwrap` 用分支实现，ISA 没有
  `select`；`unwrap` 失败时 panic 只带代码，消息需要格式化栈）。
- `slice::len` / `str::len`：胖指针的长度字（driver 给出偏移，mir2sars 内联
  为一次 load）——循环里按切片长度迭代的常见写法因此可运行。
- cargo 演示工程（`rust/cargo_demo`）现在覆盖：`macro_rules!` 宏 ✓、跨 crate
  调用 ✓、**枚举 + match** ✓、**切片**（胖指针 + 动态下标 + `len`）✓、
  **`Vec`**（`new`/`push`/`len`/`is_empty`/下标）✓、**`Option` 方法**
  （`is_some`/`unwrap_or`/`unwrap`）✓、**`for` 循环** ✓、**字符串字面量**
  （胖指针 + `as_bytes()[0]`）✓，全部经 `cargo -> MIR -> .sars -> sars run`
  跑通。
- `unwrap_or` 的默认值放在**帧槽**里读（而不是拷贝）：拷贝会在一条路径上
  消耗寄存器，join 处两条路径的状态就不一致（`PhiStateConflict`）。
- **在分支里赋值、随后读取**的值（`let o = if c { Some(x) } else { None };`
  之后 `match o`）：版本阶段保留冲突信息（`Operand::Conflict` 带上投影），
  join 槽机制按路径计算**判别式**（各分支把 tag 写进槽）与**基址**
  （字段读先从槽里取地址再加偏移）。因此分支里造出的 `Option`/枚举
  之后可以 `match`。
- **借用释放**改为在最后一次使用之后释放（不再只在函数出口释放）：释放
  borrow view 只清除源寄存器的锁（自身仍存活），因此各路径状态一致，
  join 处不再出现「已锁 vs 未初始化」的冲突——派生 `Debug`/`Clone` 这类
  实现内部的借用因此可以验证通过。
- 字符串缓冲的所有权：字节缓冲（`_str_*`）若被**拷贝**进寄存器，所有权随之转移
  （SA 的赋值消耗源），出口不能再释放（否则双重释放）；只被存进胖指针的缓冲
  仍归自己所有，出口释放。
- **原始数值方法**（`i32::abs`、`core::cmp::min`/`max`）内联为 SA 代码：
  操作数放进帧槽再比较（避免只在一条路径上消耗寄存器），有符号性由
  driver 按操作数类型给出（`slt`/`ult`）。
- **`Vec<T>` 基础操作**（`new`/`push`/`len`/`is_empty`）内联为 SA 代码：
  driver 按**字段名**递归解析 `Vec` 的嵌套布局（`RawVec { inner: RawVecInner
  { ptr, cap } }` + `len`），后端据此读写三个字；`push` 满了就重新分配并用
  `sa_mem_copy` 搬运旧元素（新 `Vec` 预分配一个小缓冲，指针始终有效）。
- **`Vec` 下标** `v[i]`：rustc 把 `Vec` 的下标编译成 `Index::index` 调用，
  后端内联为「读数据指针 + 下标 * 元素大小 + 取地址」（返回**元素引用**，
  与 Rust 的 `Index` 语义一致；越界检查由 MIR 的 `BoundsCheck` 断言负责）。
- `Vec` 布局按**字段名递归**解析（现代 rustc 的 `Vec` 把字藏在
  `RawVec { inner: RawVecInner { ptr, cap, .. } }` 里，且布局会重排字段，
  所以不能按字段下标匹配）。
- **Rust `Copy` 语义**：SA 的赋值会消耗源寄存器，而 Rust 的 `Copy` 值复制后
  仍然有效；「只在一条路径上复制」会让 join 处看到「已消耗 vs 仍存活」的
  状态冲突。因此标量（含被 MIR 当作 move 的标量）现在会被溢出到槽，
  复制变成重载（不消耗）；参数的槽在函数序言里初始化。
- 仍未覆盖：`println!`/`format!` 的**格式化栈**（`Argument::new_display`、
  `Arguments::new`、`io::_print` 都是 std 符号）——`panic!` 路径已折叠为
  原生 `panic(code)` ✓，但主动打印仍需 std 符号。
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
- `for x in &slice` / `for x in &vec`（`std::slice::Iter`）：`into_iter`
  用数据/长度字（偏移由 rustc layout 给出：切片 `0/8`，`Vec` 用字段名
  解析出 `8/16`）构造 `Iter { ptr, end }`；`next` 比较 `cur < end`，产出
  当前元素指针（niche `Option<&T>`：0 = None），并按 `elem_size` 推进。
  已用 `iter_sum(&[i32])` / `iter_sum_vec(&Vec<i32>)` 端到端验证。
- `slice::iter(&[T])` / `Vec::iter()`：`iter` 按同一套数据/长度字构造
  `Iter`；`Vec::iter()` 先经 `Deref::deref` 内联出 `&[T]` 胖指针
  （`_deref_data_`/`_deref_len_`，字段名解析偏移），再走 `slice::iter`。
  已用 `iter_ref_sum` / `iter_ref_sum_vec` 端到端验证。
- `slice::first`/`last`/`get`：返回 `Option<&T>`（niche 指针，0 = None），
  `first` 判 `len != 0` 取 data，`last` 取 `data + (len-1)*elem_size`，
  `get` 先做 `idx < len` 再取地址。`Vec::first()`/`last()` 经
  `Deref::deref` 同样内联。已用 `slice_opt_sum`（含越界 `get(99)`）与
  `vec_ends_sum` 端到端验证。
- `Vec::pop()`：长度非零时先 `len -= 1`，再从 `data + len*elem_size` 读
  末元素，写入 `Option<T>`（无 niche 的标量：`tag@0` 宽度同 `elem_size`、
  payload@`elem_size`，槽大小 `2*elem_size`；`Option<i32>` 即 tag u32、
  payload@4）；长度为
  零时只写 `None` 判别式。已用 `vec_pop_sum`、`vec_u8_pop_sum`
  （`Option<u8>` 的窄 tag/payload）及弹空后的 `is_empty()` 验证。
- `slice::Iter::rev()`：`rev` 把 `Iter { ptr, end }` 换成
  `{ ptr: end, end: ptr }`；`Rev::next` 从末尾前移（`sub cur, elem_size`，
  `ugt cur, base`），复用 niche `Option<&T>`。已用 `iter_rev_sum`
  端到端验证。
- `.take(n)`：构造 `Take { iter, n }`（拷贝内层 `Iter` 两字 + 计数，
  偏移/大小取自 rustc layout）；`Take::next` 同时判 `n != 0` 与
  `cur < end`，产出后计数减一。已用 `iter_take_sum` 端到端验证。
- `.step_by(n)`：构造 `StepBy { iter, step_minus_one, first_take }`；
  首次 `next` 产出头元素，之后按 `step_minus_one * elem_size` 直接跳到
  下一个目标（切片可随机访问，无需逐元素走），越界即 None。
  `n == 0` 保持 std 的 panic 行为。已用 `iter_step_sum` 在 `n=1/2/10`
  下端到端验证。
- `.enumerate()`：构造 `Enumerate { iter, count }`；`next` 产出
  `(count, &T)`（`Option` 的 niche 指针仍在 payload 的 +8），计数自增。
  已用 `iter_enum_sum` 端到端验证。
- `.zip(other)`：构造 `Zip { a, b, .. }`，拷贝两个 `Iter` 的两字状态；
  `next` 先推进 `a`、再推进 `b`，两者都有元素时产出 `(&A, &B)`，
  否则 None（`a` 已消耗的元素不回退，与 std 一致）。已用
  `iter_zip_sum` 覆盖等长与短第二序列。
- niche 判别式偏移改为读取未标记变体字段的 `largest_niche.offset`，
  从而支持 `Option<(usize, &T)>` / `Option<(&A, &B)>` 这类 niche
  嵌在 payload 元组内的情况。
- 退出释放不再释放 niche 判别式读出的 `<reg>_n` 载荷指针（它指向调用方
  存储，不拥有该分配），也不释放容器 shim 读出的 `_vec_data_`（缓冲基址）
  与 `_vec_addr_`（元素内部地址）。
- `.map(closure)`：构造 `Map { iter, .. }`，拷贝内层 `Iter` 两字，闭包为
  ZST；`next` 先判内层游标，再以 `(env=0, elem_ptr)` 调用闭包，把结果写成
  `Option<Output>`（无 niche 标量：`tag@0` 宽度同输出大小，payload 紧随）。
  闭包函数名按 `DefId` 去重（`closure_0__25` 这类），避免同名冲突。
  已用 `iter_map_sum` 端到端验证。
- `.filter(predicate)`：构造 `Filter { iter, .. }`；`next` 循环推进内层
  `Iter`，把当前元素指针的地址作为 `&&T` 传给谓词（临时 8 字节槽），
  为真时产出 `Option<&T>`（niche 指针），否则继续。已用
  `iter_filter_sum` 端到端验证。
- 仍未覆盖：其它闭包适配器（如 `filter_map`/`flat_map`/`map_while`）。

