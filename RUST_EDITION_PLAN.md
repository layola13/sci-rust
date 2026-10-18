# SA Rust化改造总方案（sci-rust Edition）

> 基线：`sci`（Zig实现，766M）已完整复制为 `sci-rust`。本方案只改语义/校验层，不重写Zig编译器。

## 1. SA底层现状（取证结论）

### 1.1 五层架构
- `src/common/capability.zig:3-84`：CapabilityMask u16 + TRUTH_TABLE（17条）。Active=0x01, Locked_Read=0x02, Locked_Mut=0x04, Consumed=0x08, Immutable=0x0100, InteriorPtr=0x0200。
- `src/verifier.zig`（7231行，179符号）：唯一权威borrow checker。`readCheck:2643` / `writeCheck:2663` / `assignValue:2697` / `verifyBody:3076` + Phi-merge `statesCompatibleForJoin:808` + Interior树。
- `src/referee/table.zig:20`：轻量CapabilityTable（masks/origins/lock_refs/flags），`verifier.zig`是超集，不要双改。
- `src/common/instruction.zig:246-301`：Operand union + InstKind（alloc/stack_alloc/load/store/borrow/move_/release/call_indirect/try_/panic等）。
- `src/common/signature.zig:40`：FunctionSig + ParamSpec{cap: CapPrefix}，CapPrefix={by_value=0,borrow=1,move=2,raw=3}。即`&x/^x/*x`前缀。
- `src/flattener.zig`（7548行）：宏+import+`#def`展开，无借用语义，只做降级。

### 1.2 可变性现状：默认可变
- `verifier.zig:3360` `.alloc => assignValue(..., maskOf(.active))`，`stack_alloc:3371`同。`store:3400`走`writeCheck`。
- Immutable位仅`@const`用（`const_decl.zig:504`，`verifier.zig:556 isImmutable/isImmutableConst:560`，`writeCheck:2678 constTrap`）。
- `demos/c/02_mutability/main.sa`实证：SA语法层**无`&mut`**，`r2=&x + store`靠“后续store推导独占借用”，`store r2`时把origin从Locked_Read翻转为Locked_Mut（`verifier.zig:3410-3416`）。这是最大Rust偏离点。
- `docs/default_immutable_switch_evaluation.md`已给出最小patch：alloc/stack_alloc按`opts.default_immutable`取`0x101`，load传播Immutable，TRUTH_TABLE补`0x101+release_own`，CLI加`--default-immutable`，emit_llvm/interp零改动。

### 1.3 Trait现状：只有vtable字面量，无trait系统
- `const_decl.zig:451 parseVTable` + `instruction.zig:243 VTableLiteral`：`@const BUTTON_VT = vtable { draw = @button_draw }`。
- `demos/c/07_trait_vtable/main.sa`：手工fat pointer（DATA+VTABLE=16B）+ `call_indirect`，无`trait/impl/dyn`关键字，无object safety、无关联类型、无blanket、无Send/Sync、无Drop。
- `cli.zig:4709 markSabReachableVtableConst`只做可达剪枝。

### 1.4 Interior现状
- `106_cell_interior_mut`：Cell只是“约定可写”，Verifier无Interior豁免。Rust的`Cell/RefCell/UnsafeCell`三件套缺失。

## 2. Rust借用清单（都要）

| Rust特性 | SA现状 | 借用方式 |
|---|---|---|
| `let`默认不可变/`let mut` | alloc默认0x01 | alloc默认0x101，`mut x = alloc`显式可变 |
| `&T` / `&mut T` | `&x`共享，`=&x`独占但语法隐晦 | 引入`&mut x`显式语法，保留`=&`为别名 |
| NLL/Flow borrow | 全函数scope锁计数 | 复用locks[]+Phi snapshot，不引入lifetime标注 |
| move默认/`Copy` opt-in | `^x`显式move，标量也需`!` | 保持`^`显式（ASM层不能隐式），标量加`Copy`免release |
| `Cell/RefCell` | 无 | Immutable + InteriorPtr位豁免writeCheck |
| `trait/impl/dyn` | 手工vtable | 新顶层`trait/impl/dyn`，降级为现有vtable+fat pointer |
| 关联类型/GAT雏形 | 无 | `type Output`单关联类型先行 |
| `Drop` | `!x`手动 | `impl Drop`自动在merge点注入`!`（复用SLA的auto-`!`思想） |
| `Send/Sync` marker | 无 | `VerifyOptions` + 函数属性，不做线程证明只做跨线程move拦截 |
| `Result?` | `try_ ? + Fallible 0x80`已有 | 直接复用，不另造 |
| Edition迁移 | 无 | `--edition=2024-rust` + `--default-immutable`双开关 |

## 3. 改造总方案（4期）

### P0 默认不可变（1周，最小闭环）
1. `VerifyOptions`加`default_immutable: bool=false` + CLI `--default-immutable` / `--edition=rust`。
2. `capability.zig` TRUTH_TABLE补2条：`0x101+release_own->0x00`，`0x101+borrow_read->Locked_Read|Immutable`。
3. `verifier.zig:3360/3371`按开关取mask；`load:3381`若src Immutable则dst继承`0x101`（而非当前只给Active）。
4. 显式可变声明：`mut x = alloc 8` / `mut y = stack_alloc 8` -> 0x01；普通`x = alloc` -> 0x101。解析层只多一个`mut`前缀，不动EBNF大结构。
5. 显式独占借用：`r = &mut x`新增，与`r = =&x`等价；`writeCheck`对`Locked_Read->Locked_Mut`的隐式翻转（3410行）在rust edition下**报错**，强制写`&mut`。
6. sa_std迁移：500-1500行store加`=&/!`对，或包一层`MUTABLE_STORE`宏；先跑`sa check --default-immutable sa_std/alloc/vec.sa`计数ConstMutation(1036)定迁移量。
7. 门禁：默认门`73/78 pass`不变；rust门`--default-immutable`下348/380 demo中预期新增~200 ConstMutation trap，逐个修或标`mut`。

### P1 Trait体系（2-3周，核心增值）
```
// 新语法（全部降级为现有vtable+call_indirect，零后端改动）
trait Draw { fn draw(&self: ptr) -> i32; }
impl Draw for Button { fn draw(&self: ptr) -> i32: ... }
d = alloc dyn Draw_SIZE   // = alloc 16 (data+ vtable)，Verifier记Fallible外的新Dyn位或复用BorrowView组合
store d+DATA, button as ptr
store d+VTABLE, &Button_Draw_VT as ptr
r = call_dyn d.draw(&d)   // 降级：load vtable+slot + call_indirect
```
- `const_decl.zig`扩展`parseVTable`做签名校验（slot arity vs trait decl，不匹配报`TraitSignMismatch`）。
- object safety：含`^self`按值取所有权的方法不可进vtable（Verifier在collectConstVtables:662拦截）。
- blanket impl暂禁（`impl<T: Draw> ...`报`ForbiddenSyntax`），只允许具体类型impl + 单关联类型。
- `Drop`：`impl Drop for T`在`finalizeLeaks + Phi merge`处自动注入`!`，复用SLA 1.4节auto-cleanup逻辑。
- marker：`@trusted_send/@trusted_sync`函数属性，无属性的类型跨`spawn`按值传参直接trap。

### P2 所有权收紧（与P1并行）
- 标量`Copy`：`i32/u64/f64`等`load`产物（EphemeralScalar flag）免`!`，`--edition=rust`下`finalizeLeaks`跳过Copy类。
- `Cell[T]`：`store`到`InteriorPtr(0x200)`寄存即使Immutable也放行；`RefCell`运行时borrow flag（复用lock_refs计数）+ `BorrowConflict` trap。
- NLL：不动lifetime语法，靠现有`lock_refs[source]-=1 → Active`（table.zig:226）+ label snapshot merge实现提前释放；只修一处：`releaseBorrow`后origin立即恢复Active即NLL已成立。

### P3 工具链/生态
- `sa check/build-exe/test --edition=rust`统一入口；旧版默认mutable零改动。
- `rsc/mir2sa`（sarust已跑通MIR->SA）直接受益：MIR的`Move/Copy/Drop/&mut`与新SA 1:1，不再靠“推导”。
- 文档：EBNF加`mut_decl/trait_decl/impl_decl/dyn_alloc/call_dyn` 5产生式；`default_immutable_evaluation.md`升级为Edition spec。

## 4. 落地顺序与验收
1. P0 patch（~20行Zig）+ `vec.sa`试点 -> `sa check --default-immutable` ConstMutation计数收敛。
2. `02_mutability`改写为`mut x` + `&mut`显式版；`106_cell`加Interior豁免；`07_trait_vtable`改写为trait/impl/dyn糖。
3. 全量demo重跑：目标rust edition下348/380同样绿（trap类demo预期行为不变）。
4. 不做：泛型单态化（SLA已做）、lifetime标注、blanket/specialization（留v0.6）。

## 5. 风险
- sa_std迁移量最大，分包灰度，先`alloc/vec/hash`三件套。
- 隐式`Locked_Read->Locked_Mut`翻转是现有demo依赖，rust edition下必须设为error，需逐demo修。
- Trait只做静态vtable，不碰async/executor（cli.zig:3187已声明不支持）。
