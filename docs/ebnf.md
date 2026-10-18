# SA-ASM EBNF

This document mirrors design appendix C and acts as the canonical syntax
reference for the current SA-ASM contract.

```ebnf
program        = { toplevel } ;
toplevel       = def | loc | macro_def | func_def | ffi_wrapper_def | extern_decl | export_def ;
def            = "#def" IDENT "=" LITERAL ;
loc            = "#loc" STRING ":" NUMBER ":" NUMBER ;
func_def       = "@" IDENT "(" [ param_list ] ")" [ "->" [ "^" ] type [ "!" ] ] ":" { line } ;
ffi_wrapper_def= "@ffi_wrapper" IDENT "(" [ param_list ] ")" [ "->" type [ "!" ] ] ":" { line } ;
extern_decl    = "@extern" IDENT "(" [ param_list ] ")" [ "->" type ] ;
export_def     = "@export" IDENT "(" [ param_list ] ")" [ "->" type [ "!" ] ] ":" { line } ;
param          = [ "&" | "^" | "*" ] IDENT [ ":" type ] ;
type           = "i8"|...|"u64"|"f32"|"f64"|"ptr"|"v128" ;
line           = label | inst | native ;
inst           = alloc | load | store | op | jmp | br | call | return | take
               | release | move | borrow | rawcast | assume_safe | assume_borrow
               | atomic_load | atomic_store | cmpxchg | fence | try_op | panic_op ;
try_op         = IDENT "=" "?" IDENT ;
panic_op       = "panic" "(" LITERAL ")" ;
atomic_load    = IDENT "=" "atomic_load" IDENT "+" LITERAL [ AtomicOrd ] ;
atomic_store   = "atomic_store" IDENT "+" LITERAL "," operand [ AtomicOrd ] ;
cmpxchg        = IDENT "=" "cmpxchg" IDENT "+" LITERAL "," operand "," operand [ AtomicOrd ] ;
fence          = "fence" [ AtomicOrd ] ;
AtomicOrd      = "relaxed" | "acquire" | "release" | "acq_rel" | "seq_cst" ;
rawcast        = IDENT "=" "*" IDENT ;
assume_safe    = IDENT "=" "assume_safe" IDENT ;
assume_borrow  = IDENT "=" "assume_borrow" IDENT [ "," "mut" ] ;
```

---

## 14. 附录 F：Rust Edition 扩展（sci-rust / sars）

二进制改名：`sa` -> `sars`（`--version` 输出 `sars x.y.z`，`usage:` 前缀同步；
daemon argv[0] 归一化接受新旧名）。

CLI 开关（`--edition rust` 等价于三开关全开）：

```
--default-immutable
--rust-strict-mut
--rust-copy-elision
--edition rust | 2024-rust | rust-edition
```

语法糖（全部降级为既有 IR，零后端改动）：

```ebnf
mut_alloc      = "mut" IDENT "=" "alloc" LITERAL ;
mut_stack      = "mut" IDENT "=" "stack_alloc" LITERAL ;
borrow_mut     = IDENT "=" "&mut" IDENT ;
borrow_long    = IDENT "=" "borrow" [ "mut" ] IDENT ;
```

语义：

* 默认不可变：`x = alloc N` 在 `--default-immutable` 下初始 mask 为
  `Active|Immutable (0x101)`；`mut x = alloc N` 显式可变（`0x01`）。
  `load` 从 Immutable 源读取时目标继承 Immutable。
* 严格独占借用：`r = &mut x` / `r = borrow mut x` 为显式独占借用；
  `--rust-strict-mut` 下经共享 `&` 借用写回报 `ReadWriteConflict`，
  必须改写为 `&mut`。
* Copy 省略：`--rust-copy-elision`（`--edition rust` 隐含）下 ephemeral
  标量在 `move`/`assign` 中不被消费，可多次使用。
* Cell 内部可变：`InteriorPtr` 派生指针豁免 Immutable 写保护
  （`isImmutableConst` 对 `hasInteriorPtr` 返回 false）。
* vtable 对象安全：slot 方法首参必须为 `&self: ptr`（borrow），否则
  `VTableSignatureMismatch (1024)`。`sa_std/dyn.sa` 提供 `DYN_NEW` /
  `DYN_DATA` / `DYN_VTABLE` / `DYN_FREE` / `TRAIT_DISPATCH` 宏，
  fat pointer 布局固定 16B `[data:8][vtable:8]`。

真值表新增（`src/common/capability.zig`）：

| 当前 mask | 操作 | 合法? | 新 mask | Trap |
|---|---|---|---|---|
| `0x101` (Active\|Immutable) | `release_own` | ✅ | `0x08` (Consumed) | — |
| `0x101` | `borrow_read` | ✅ | `0x102` | — |
| `0x102` | `borrow_read_again` | ✅ | `0x102` | — |
| `0x102` | `borrow_mut` | ❌ | — | `ReadWriteConflict` |
```

---

## 12. 附录 D：Capability Mask 真值表（扩展版）

旧版真值表全部保留，新增气闸舱行（见前版）与 Fallible 行：

| 当前 mask | 操作 | 合法? | 新 mask | Trap |
|---|---|---|---|---|
| `0x80` (Fallible) | `?` 展平后 | ✅ | 提取后的 value → `0x01`；status 路径走 early return | — |
| `0x01`（非 Fallible） | `?` | ❌ | — | `FallibleContractMismatch` |
| 原子指令同地址冲突 ordering | RMW | ❌ | — | `AtomicOrderingMismatch` |
| 其余见旧版 | — | — | — | — |

---

## 13. 附录 E：关键设计决策（校准版）

| 决策 | 旧版 | 本版 | 理由 |
|---|---|---|---|
| 后端中继 | Zig 源码 | LLVM bitcode + WASM 直出 | 跳过 Zig 前端，白嫖 O3 |
| 编译速度叙事 | "物理极限" | MVP 默认 O1；O3 只是选项 | LLVM O3 仍是秒级瓶颈，诚实 |
| Referee LOC | ≤ 1500 | ≤ 2500 MVP / 1500 stretch | 加入气闸舱 + Phi + 原子 + 错误传播后 1500 不现实 |
| AutoBevy 1M ±30% | 最低优先级 | post-MVP stretch | 依赖 SIMD + 并行调度，12 周难达成 |
| LLM 零训练 80% | KPI | Pilot 实测 baseline | 无证据时不预设数字 |
| 调试信息 | 未提 | `#loc` + DWARF + `-g` | 生产语言硬需求 |
| 错误传播 | 未提 | `!` 后缀 + `?` + `panic` | 避免每个前端各造一套返回协议 |
| SIMD/浮点/原子 ISA | 未定义 | 首轮就定义 | AutoBevy 这类后续场景必备 |
| 前端合约 | 隐含 | R20 显式合约 + `libsa_scope` helper | 避免"机械映射"误导，划清责任 |
| 名称 | SA-ASM | SA | 命名简化 |

---

**文档终态**：本设计覆盖需求文档 33 条 Requirements（R1–R24 MVP + R25–R27 v0.3 + R28–R30 v0.4 + R31–R32 v0.5 + R33 v0.6）的全部契约，含 **32+ 条形式化 Property**、5 层测试策略、完整的 LLVM bitcode / WASM 映射表、气闸舱隔离、前端降级合约、`libsa_scope` helper、v0.2 `#mode compact`（由外部 SLA 插件 `sa_plugin_sla` 替代，主线不再实现）、v0.3 VTable 签名校验 + `libsa_async` + 诊断级别、v0.4 并行开发基建、v0.5 包管理 + 布局标签校验 + `sa_std` 标准库、v0.6 Referee 形式化验证 + FPGA 硬件化。
