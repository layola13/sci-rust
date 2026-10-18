# SA 语言 FAQ：为什么我们刻意不保留这些特性？

> SA (safe asm, 安全汇编) 是一门面向机器验证与 LLM 代码生成的线性所有权语言。它刻意抛弃了传统编程语言为人类设计的大量语法糖和关键字。本文档解释每一个"为什么没有"。与插件交付相关的能力现在作为独立工程存在，不作为语言本体的默认组成部分。

---

## 控制流类

### Q: 为什么没有 `if` / `else`？

**A**: SA 用 `br cond -> L_TRUE, L_FALSE` 替代。

原因：
- `if/else` 需要嵌套大括号 `{}`，LLM 生成长代码时极易产生闭合错误
- 嵌套结构需要 AST 树来表达，违反 SA "零 AST、纯线性扫描" 的核心原则
- `br` 是不可再分解的原子操作；`if/else` 是 `br` 的组合模式

```
// 传统: if (x > 0) { sum += x; } else { sum -= x; }
// SA:
cond = sgt x, 0
br cond -> L_POS, L_NEG
L_POS:
    sum = add sum, x
    jmp L_NEXT
L_NEG:
    sum = sub sum, x
    jmp L_NEXT
L_NEXT:
```

### Q: 为什么没有 `while` / `for` / `loop`？

**A**: SA 用 `L_LABEL: + jmp + br` 替代。

原因：
- 循环是 `jmp` 回边 + 条件 `br` 的组合模式
- 显式 Label 让 Referee 的 Gas 计数器能精确识别回边（标记 `unbounded`）
- LLM 生成扁平 Label 比生成嵌套循环错误率更低

```
// 传统: while (i < len) { ... i += 1; }
// SA:
L_COND:
    cond = ult i, len
    br cond -> L_BODY, L_END
L_BODY:
    // ...
    i = add i, 1
    jmp L_COND
L_END:
```

### Q: 为什么没有 `match` / `switch`？

**A**: SA 用 `load tag + eq + br` 链替代。

原因：
- `match` 需要模式匹配语义（解构、穷尽性检查），这是类型系统的工作
- SA 没有类型系统，只有内存块和偏移量
- 前端（smrustc / LLM）负责把 `match` 展平为 tag 比较链

```
// 传统: match shape { Circle(r) => ..., Rect(w,h) => ... }
// SA:
tag = load s+0 as u32
is_c = eq tag, 0
br is_c -> L_CIRCLE, L_CHECK_RECT
L_CHECK_RECT:
    is_r = eq tag, 1
    br is_r -> L_RECT, L_MISS
L_MISS:
    panic(106)
```

---

## 错误处理类

### Q: 为什么没有 `try`（Zig）/ `try-catch`（Java/C++）？

**A**: SA 用 `?` 操作符替代（等价于 Rust 的 `?` / Zig 的 `try`）。

原因：
- `try` 和 `?` 语义完全相同：检查错误 → 成功则继续 → 失败则早返回
- SA 只保留一种形态，避免同义词膨胀
- Flattener 把 `?` 展平为 `br + early return`，Referee 看到的是纯粹的分支跳转

```
// Zig:  const v = try read_file(path);
// Rust: let v = read_file(path)?;
// SA:
res = call @read_file(&path)
v = ? res
```

### Q: 为什么没有 `catch`（Zig/Java）？

**A**: SA 用 `br` 手动分支替代。

原因：
- `catch` 是"错误处理"（不传播，就地处理）
- 在 SA 里就是检查 status + 跳转到处理 Label
- 不需要新关键字，已有原语完全覆盖

```
// Zig: const v = read_file(path) catch |err| { log(err); return 0; };
// SA:
res = call @read_file(&path)
status = load res+0 as u32
ok = eq status, 0
br ok -> L_OK, L_CATCH
L_CATCH:
    err = load res+4 as u32
    call @log(err)
    return 0
L_OK:
    v = load res+4 as i32
```

### Q: 为什么没有 `throw` / `raise`？

**A**: SA 用 `panic(code)` / `panic_msg(code, *s, len)` 替代不可恢复错误，用 Fallible ABI（`-> T!`）替代可恢复错误。

原因：
- `throw` 需要 unwinding 栈展开机制，这是极其复杂的运行时基建
- SA 的错误模型是显式的：可恢复错误走 `{status, value}` 返回值；不可恢复错误走 `panic` 直接终止
- 没有隐式的异常传播路径，Referee 能精确校验每条路径的所有权状态

### Q: 为什么不直接用整数错误码？

**A**: SA 对外发布的是结构化 `TrapReport`，不是裸整数。公开识别名是 `trap`，不是 enum ordinal。

原因：
- `Trap` 名称是稳定公开标识；枚举顺序不是公开数值代码，也不允许从顺序反推语义
- 裸整数无法携带 `line` / `source_line` / `register` / `expected_mask` / `actual_mask` / `upstream_loc` / `message` / `hint`
- stage-local Zig `error{}` 只服务于实现细节；进入 CLI / Referee 边界后要收敛为 JSON-first 诊断
- `ErrorMsg` / `ErrorBundle` 那种主消息 + note/hint 的组织方式，只有结构化输出才保得住
- 总目录见 [`docs/errorcode.md`](./errorcode.md)

---

## 类型系统类

### Q: 为什么没有 `struct` / `class`？

**A**: SA 用 `alloc N + #def FIELD = +offset` 替代。

原因：
- `struct` 是"给一块连续内存的字段起名字"的语法糖
- SA 直接暴露物理本质：一块 N 字节的内存 + 偏移量字典
- 没有类型系统意味着没有类型推导、没有泛型展开、没有 trait 求解——编译器复杂度降低 90%

```
// 传统: struct Vec3 { x: f32, y: f32, z: f32 }
// SA:
#def Vec3_SIZE = 12
#def Vec3_x    = +0
#def Vec3_y    = +4
#def Vec3_z    = +8
v = alloc Vec3_SIZE
store v+Vec3_x, 1.0 as f32
```

### Q: 为什么没有泛型 `<T>`？

**A**: 前端在降级到 SA 之前必须完成单态化。

原因：
- 泛型是"代码复印机"——让人类少写重复代码
- 机器不需要复印机，它只需要最终复印出来的具体代码
- SA 看到的永远是 `@max_i32` / `@max_f32` 这样的具体函数，没有 `<T>`

### Q: 为什么没有 Trait / Interface？

**A**: 静态分发 = 单态化（前端展开）；动态分发 = `@const VTable + call_indirect`。

原因：
- Trait 是人类为了让不同类型响应相同行为而发明的抽象
- 在机器层面，只有"函数指针数组"（VTable）和"直接调用具体函数"
- SA 不需要理解"多态"，它只需要执行 `call_indirect fn_ptr(data_ptr)`

### Q: 为什么没有 `enum` 关键字？

**A**: SA 用 `[tag(4B) | payload(max_variant_size)]` 内存布局 + `load tag + br` 替代。

原因：
- `enum` 在底层就是"标签联合"（tagged union）
- SA 直接暴露这个物理结构，不需要语法糖来包装

---

## 所有权与借用类

### Q: 为什么没有 `&mut`？只有 `&`？

**A**: 共享读 vs 独占写由 Referee 的 `Locked_Read` / `Locked_Mut` 位掩码在**运行时上下文**内动态决定，不在语法层区分。

原因：
- Rust 的 `&mut` 是给人类看的"这个借用会写入"的声明
- SA 的 Referee 不需要人类告诉它——当借用视图对源内存执行 `store` 时，Referee 自动将源寄存器标记为 `Locked_Mut`
- 如果已有其它读借用存在，Referee 直接 Trap `ReadWriteConflict`
- 少一个前缀 = 少一种签名形态 = LLM 生成错误率更低

### Q: 为什么没有生命周期标注 `'a`？

**A**: SA 刻意不做跨函数借用图追踪。这是前端（R20）的责任。

原因：
- 生命周期推导（NLL/Polonius）是 Rust 编译器中最复杂的部分（数十万行代码）
- SA 的 Referee 只做**函数内**的线性扫描，O(1) 位运算
- 跨函数的借用安全由前端保证——如果前端降级错了，运行时会段错误
- 这是 SA 的**安全下限缺口**，但换来了编译器复杂度的数量级下降

### Q: 为什么没有 `drop` / `defer`？

**A**: SA 用显式 `!reg` 替代。

原因：
- `drop` / `defer` 是"作用域退出时自动执行"的隐式机制

### Q: 为什么没有 `Cell` / `RefCell` / `Rc` / `Arc` / `Weak` 作为内建类型？

**A**: 它们应该作为布局字典 + 宏模式实现，而不是语言内建语义。

原因：
- `Cell` 本质上只是一个受 Referee 约束的单字段 `store`
- `RefCell` 需要一个显式借用计数器，错误路径必须能直接分支到 Trap，而不是依赖隐式借用图
- `Rc` / `Arc` / `Weak` 本质是控制块 + 双计数器模型，不需要新增类型系统，只需要稳定的头部布局和 `clone` / `drop` 宏
- `Waker` 和 trait object 本质是 vtable 调度问题，SA 已经用胖指针和 `call_indirect` / 等价间接调用覆盖了这类物理模型
- 把这些模式固定成宏和 `.sal` 布局，能让 LLM 生成的代码保持扁平、可验证、可审计，而不是在语言层重新发明 Rust

补充实现约束：
- `Cell` 只需要一个数据槽，宏层面就是 `load` / `store` 包装，不应引入额外生命周期语义。
- `RefCell` 必须显式预留 `borrows` 计数，借用失败走调用方提供的错误标签，释放时必须显式写回 0。
- `Rc` / `Weak` 必须用 Strong / Weak 双计数控制块表示，`Rc::drop` 的末尾要级联到 `Weak::drop`，由 Weak 决定是否真正释放整块内存。
- `Weak::upgrade` 不能在 Strong 为 0 时“修复”对象，只能返回 null 和失败标志。
- `dyn Trait` / `Waker` 需要独立的胖指针布局和 vtable 宏；trait 对象的 `data` / `vtable` 槽位必须显式命名，避免把多态语义藏进隐式类型系统。
- `STRUCT_COPY` / `STRUCT_EQ_FIELD` / `STRUCT_EQ4` / `DISPATCH` 这类宏属于标准库层面的扁平化助手，不引入新语义，只做布局已知前提下的文本展开。
- `sa_std/rust_core.sa` 与 `sa_std/core/sa_core.sa` 是兼容入口，不是额外的类型系统边界；真正的正确性仍由前端布局和 Referee 共同保证。

### Q: 那 `Cell` / `RefCell` / `Rc` / `Arc` / `Weak` 的正确性由谁负责？

**A**: 前端负责布局与语义降级，SA / Referee 负责物理一致性与边界约束。

原因：
- 前端需要保证控制块对齐、字段偏移、强弱计数初值、以及 `Weak::upgrade` / `Rc::drop` 的级联顺序
- Referee 只验证已展开的指令流是否满足借用、释放、逃逸与对齐规则
- 如果前端把这些模式展开错了，SA 不会替它“猜”出正确语义；它只会按 Trap 暴露错误
- SA 的核心哲学是"所有状态显式可见"——如果你分配了内存，你必须在每个退出路径上显式 `!reg`
- 前端（R20）负责在每个 `}` 对应的位置插入 `!reg`
- Referee 在函数出口检查：任何 `Active` 寄存器未释放 → `Trap: MemoryLeak`

---

## 并发与异步类

### Q: 为什么没有 `async` / `await`？

**A**: 前端必须做 CPS（Continuation-Passing Style）转换，把 async 函数展平为状态机结构体 + poll 函数。

### Q: `bc2sa` 能不能直接当作 C/C++ 的静态漏洞扫描器？

**A**: 不能把它当成全量扫描器，但它可以作为一个保守的 bitcode 入口护栏，拦住一类可静态证明的固定边界越界。

原因：
- `bc2sa` 的主职责仍然是把 LLVM bitcode 逆向翻译成 SA，不是完整证明 C 语义安全。
- 对于 `alloca [N x T]` + 常量 `getelementptr` 这类完全静态可判定的越界，`bc2sa` 现在可以直接报 `SA-CLI-019` / `StaticMemoryOverflow`。
- 对于变量偏移、复杂指针运算、跨调用链的别名分析，`bc2sa` 仍然保守拒绝或退回 `UnsupportedInstruction`，不做伪精确分析。

```c
void hack_me(void) {
    char buffer[8];
    buffer[10] = 'A';
}
```

如果这段代码先被 Clang 压成 bitcode，`bc2sa` 可以在翻译入口按固定边界判定直接拒绝，而不是输出一份看似正常、实际上已经越界的 SA。

原因：
- `async/await` 需要"可暂停栈帧"概念，破坏 SA "所有状态显式可见" 的核心哲学
- Referee 的 O(1) 线性扫描无法处理"暂停后恢复"的非线性控制流
- 把 CPS 转换留给前端，SA 本身保持绝对扁平
- v0.3 提供 `libsa_async` 宏模板缓解膨胀（R26）

### Q: 为什么没有 `thread::spawn` / `go` / goroutine？

**A**: 线程是操作系统的调度单元，不是语言特性。

原因：
- SA 不负责"创建"线程，它只负责保证多线程环境下的数据竞态安全
- 仿射状态机天生保证：同一内存块不能同时被两个 `&`（写）借用
- 启动线程通过 `@extern` 调用宿主 API（如 `pthread_create`）
- 所有权的 `^` Move 保证数据从一个线程移交到另一个线程时，源线程不再访问

### Q: 为什么没有 `Mutex` / `RwLock`？

**A**: SA 提供原子原语（`atomic_rmw_*` / `cmpxchg` / `fence`），Mutex 是用这些原语**在 SA 层手搓**的数据结构；标准库里已经提供了 `sa_std/sync/mutex.sa` 作为可复用宏封装。

原因：
- `Mutex` 是"原子操作 + 等待队列"的组合模式
- SA 只提供不可再分解的原子操作
- 用户/前端用 `atomic_rmw_xchg` + `br` 循环就能实现 spinlock

---

## 内存管理类

### Q: 为什么没有垃圾回收（GC）？

**A**: SA 的仿射类型系统保证：每块内存恰好被释放一次。不需要 GC。

原因：
- Referee 在编译期验证所有 `alloc` 都有对应的 `!reg`
- 如果漏了 → `Trap: MemoryLeak`
- 如果多释放了 → `Trap: UseAfterMove`
- 零运行时开销，零 GC 暂停

### Q: 为什么没有智能指针（`Box` / `Rc` / `Arc`）作为内建类型？

**A**: 这些都是用 SA 原语**手搓**的数据结构（见 demo 案例 10、24）。

原因：
- `Box<T>` = `alloc N` + `!reg`（堆分配 + 显式释放）
- `Rc<T>` = `alloc` + `atomic_rmw_add/sub` + 条件 `!reg`
- SA 不内建任何复合数据结构，只提供原子积木

---

## 模块与组织类

### Q: 为什么没有 `mod` / `use` 风格模块树？

**A**: SA 用 `@extern` 声明外部符号 + `@import` 引入接口文件（v0.4）。

原因：
- `mod` 树是 Rust 的编译单元组织方式，需要全局模块解析
- SA 的每个 `.sa` 文件是独立的编译单元，通过 `@extern` 声明依赖
- 最后由 `zig cc` 链接器合并所有 `.o` 文件
- v0.4 的 `.sai` 接口文件提供更结构化的模块契约（R28）

### Q: `sa_std` 是手写 SA 标准库，还是外部标准库？

**A**: `io` / `fs` / `net` / `fmt` / `process` / `term` / `time` 是 SA-facing facade，真实实现由 Zig-backed `libsa_std` 提供。仓库内已附带静态归档 `artifacts/sa_std/libsa_std.a`，它由 `zig build sa-std-static -Doptimize=Debug` 生成，源码位于 `src/runtime/sa_std.zig`，ABI 头文件位于 `src/runtime/sa_std.h`。

原因：
- SA 侧的 `.sa` 模块入口只用 `@import` 组合布局 `.sal` 与接口 `.sai`
- `.sai` 只声明 `@extern` 签名，Referee 仍能检查调用点的所有权前缀
- `.sal` 只声明显式内存布局和常量，不隐藏句柄或缓冲区
- API 不使用 trait/generic；文件、socket、进程和格式化缓冲区都用显式 `ptr` 句柄，并要求显式 `close` / `free` / `flush`
- `sa_std_process_run` / `sa_std_process_spawn` 接收 `SaProcessArgv` 记录数组；SA 侧先用 `#def SaProcessArgv_*` 声明布局，再通过 `@import "process.sal"` / `@import "process.sai"` 组合调用
- `sa_std_process_spawn_stream` 会返回 live stdout/stderr 句柄，适合直接接 `epoll` 或流式消费
- `sa_term_raw_enter` / `sa_term_raw_leave` 管理 raw mode session，`sa_term_winsize` 读取窗口大小，`sa_term_epoll_*` 则提供 Linux-first 的事件循环面
- 旧 demo 的 `sa_print_bytes(&msg, len)` 保留为兼容符号，等价于 Zig-backed stdout 写入

### Q: 如果我要写实时 TUI 或事件循环，应该优先用哪些接口？

**A**: 先把终端切进 raw mode，再把 stdin、子进程 stdout/stderr 和网络 fd 全部扔进 `epoll`。最小组合是 `sa_term_raw_enter` / `sa_term_raw_leave`、`sa_term_winsize`、`sa_term_epoll_create` / `sa_term_epoll_ctl` / `sa_term_epoll_wait`，以及 `sa_std_process_spawn_stream`。

原因：
- raw mode 让按键成为单字符事件，而不是等回车才交给程序
- `SaTermWinsize` 让你在窗口 resize 时重绘布局
- `epoll` 让键盘、pipe 和 socket 共用同一个事件循环，不需要轮询多个来源
- `sa_std_process_spawn_stream` 返回的 stdout/stderr 句柄可以直接注册进 `epoll`，非常适合 Claude Code 这类流式 UI

### Q: 为什么没有 `pub` / `private` 可见性？

**A**: SA 的所有函数默认对链接器可见。不需要的函数不 `@export` 即可。

原因：
- 可见性控制是人类团队协作的社会契约
- SA 的隔离机制是物理级的：气闸舱（`@ffi_wrapper`）控制 unsafe 边界，接口文件（`.sai`）控制 API 契约
- 链接器层面，未被引用的函数会被死代码消除

---

## 语法糖类

### Q: 为什么没有 `a.b.c` 属性访问？

**A**: SA 用 `load reg+offset` 替代。出现 `.` 直接 `Trap: ForbiddenSyntax`。

原因：
- `a.b.c` 需要类型系统来解析每一层的字段偏移
- SA 没有类型系统，偏移量由 `#def` 字典提供
- 显式偏移让 LLM 和 Referee 都能一眼看清内存访问模式

### Q: 为什么没有运算符优先级（`a + b * c`）？

**A**: SA 的 `#mode compact`（v0.2 R24）只允许单行一个中缀操作符。

> **📌 2026-07-01 更新：`#mode compact` 已被外部 SLA 插件（`sa_plugin_sla`）替代。**
> SLA 提供了完整的 Rust 风格语言前端（泛型、模式匹配、trait、闭包等），拥有完整的表达式解析器（含优先级和比较操作符），远超 `#mode compact` 的 8 条白名单中缀糖能力。SA 核心主线不再实现 `#mode compact`。
> 详见 `~/projects/sa_plugins/sa_plugin_sla`。

原因：
- 优先级需要表达式树解析，违反"零 AST"原则
- `a + b * c` 的歧义（是 `(a+b)*c` 还是 `a+(b*c)`？）是 bug 的温床
- 强制拆成多行：`tmp = mul b, c; res = add a, tmp`

### Q: 为什么没有通用字符串字面量 `"hello"`？

**A**: SA 不把 `"hello"` 直接提升为通用指针表达式。静态只读字节序列的正规写法仍然是 `@const NAME = utf8:"hello"`。

补充：`*"..."` 只作为调用参数里的窄语义特例，且必须是 `arg.prefix == .raw` 的场景。它表示匿名只读字节常量的指针，不隐含长度，不隐含 NUL，也不替代 `@const`。

原因：
- 字符串在底层就是一段字节数组
- SA 不隐藏这个事实：你必须显式构造胖指针 `[data_ptr | len]`
- `@const` 提供零运行时开销的静态字节存储

---

## 包管理与零信任类

> 完整设计文档见 [`docs/package_management.md`](./package_management.md)。

### Q: 为什么不建造 crates.io / npm 式的中心化包注册中心？

**A**: SA 直接用 URL（如 `github.com/xiaoming/sa-ecs`）作为命名空间，不建造任何中央 registry。

原因：
- **运营成本**：crates.io / npm 需要持续投入服务器、人工审核、安全应急
- **抢注风险**：短名称（如 `react-router` vs `react-ruter`）是 typosquatting 攻击温床
- **单点故障**：一个中心化 registry 倒了，整个生态瘫痪
- **去中心化天然就有**：GitHub / GitLab / 内网 Git / 私有 Bitbucket 都是合法包源
- 黑客要伪造一个包，必须先黑进对应组织账号 —— **门槛拉高几个数量级**

### Q: 为什么没有 SemVer 版本范围（`^1.2.0`）？

**A**: SA 的 `sa.mod` 只接受**绝对哈希钉版**，没有版本范围、没有 SAT 求解器。

```
require github.com/xiaoming/sa-ecs @v1.2.0 sha256:8f4e2d...
```

原因：
- SemVer Resolution 是依赖地狱的根源（每次拉包结果可能不同）
- 跑 SAT 求解器极其耗时
- 黑客覆盖 `v1.2.0` tag 释放毒包 → 自动升级 → 全球中招
- SA 只做一件事：去 URL 拉源码 → 算 SHA-256 → 差一比特 → Fatal Error 物理熔断

### Q: 为什么 `sa fetch` 不允许执行 `postinstall` 之类的钩子？

**A**: `sa fetch` 是**绝对图灵不完备**的"哑下载器"，只做 HTTP/Git 文本下载与解压。

原因：
- npm 的 `postinstall` 是 event-stream / colors.js 等灾难的源头
- 黑客只要等你敲下 `npm install`，他们的代码就在你电脑上跑了
- SA 生态系统**没有任何**生命周期钩子（Hooks / Scripts / Build 脚本）
- 拉下来的源码是静态文本，不主动塞进编译/运行管线就毫无杀伤力

### Q: 为什么默认拉到项目本地 `sa_vendor/` 而不是全局缓存？

**A**: SA 的默认行为是**绝对便携**：拷进 U 盘到任何一台装了编译器的离线电脑上敲 `sa build` 就能瞬间编译。

原因：
- "在我机器上能跑" = 部署到 CI 时崩溃，根源就是依赖了隐式宿主机状态
- 全局路径在 CI / 无管理员权限服务器上经常因权限问题报错
- 项目自包含 = 真正的"绿色软件"
- 仍然提供 `sa fetch -g` 给那些清楚知道自己在做什么的开发者（如本地 50 个微服务共用底层库）

### Q: `.sab` 和 `.sa` 有什么区别？什么时候用 `.sab`？

**A**: `.sab` 是 SA 二进制指令包，是 Y 形双输入架构的二进制路径。

**区别**：
| 维度 | `.sa` 文本 | `.sab` 二进制 |
|---|---|---|
| 形态 | UTF-8 文本，人类可读写 | 二进制格式（magic `"SAB\x00"`，v4.0） |
| 解析方式 | Flattener 逐行分类 + 宏展开 + `@import` 解析 | `sab.zig::decodeModule()` 直接解码 |
| 宏系统 | ✅ 完整支持 | ❌ 不支持（展开已在编码前完成） |
| `@import` | ✅ 递归解析依赖树 | ❌ 不支持（依赖已在编码时解析） |
| 优缺点 | 灵活、可读，但解析慢 | 结构化、解码快（≈文本 1/10 耗时），但不可读 |

**什么时候用 `.sab`**：
- **编译缓存**：`sa build --emit-sab` 同时产出 `.sab`，下次编译直接加载二进制，跳过宏展开
- **发布产物**：插件链产出结构化指令流（如 SLA 前端），直接写 SAB 格式，避免暴露原始源码
- **链式传递**：编译器 A 接收 SAB 输入，解码后直接送给 Referee，不走文本路径

**什么时候用 `.sa`**：
- **手写源码**：人类或 LLM 生成
- **需要宏展开**：使用 `[MACRO]` / `EXPAND` / `[REP]` 的代码
- **含 `@import`**：依赖其他模块的文件

### Q: 为什么不允许分发预编译二进制（`.so` / `.dll` / wheels）？

**A**: SA 的包管理**绝对不接受**任何编译产物分发，只接受纯文本 `.sa` 源码。

原因：
- C++ / Python 包管理为啥难搞？因为牵扯不同平台的二进制黑盒
- 二进制黑盒里如果藏了后门，杀毒软件根本扫不出来
- Zig 编译器有 32 核心瞬时并行能力，全源码白盒编译速度根本不是瓶颈
- 源码层一切 `@sys_*` 调用一览无余，`sa fetch` 顺便就能跑 X 光扫描

如果检测到拉取目录包含 `.so/.dll/.dylib/.a/.lib/.whl/.node` → `Trap: PrecompiledArtifactRejected`。

### Q: 为什么每个包默认是"绝对零权限"？

**A**: SA 把权限粒度从 Deno 的"进程级"降维到"模块级微沙箱"。

```
require github.com/util/string-utils @v1.0.0 sha256:...
                                                 # 缺省 = grants []，绝对零权限
require github.com/org/sa-net        @v1.0.0 sha256:... grants [net_tx, net_rx]
                                                 # 显式声明，才解锁 @sys_net_*
```

原因：
- Deno 的 `--allow-net` 是进程级的：一旦给了，所有第三方包都顺带获得
- 黑客在合法的字符串处理库里偷偷加一行 `@sys_net_tx` → 数据被偷发
- SA 的解法：编译器扫到任何越权 `@sys_*` 调用 → `Trap: UnauthorizedPrimitive`，**连机器码都不生成**
- 第三方代码被**物理超度**为人畜无害的纯算力

### Q: 引入第三方包时怎么知道它危险不危险？

**A**: `sa fetch` 出厂自带 X 光扫描，几毫秒内打印冷酷的体检报告：

```
[SA-SECURE] Fetching github.com/org/image-parser @v1.2.0 ... Done (12ms)

>> SECURITY AUDIT REPORT (image-parser)
------------------------------------------------------------
[X-Ray Scan] Found 3 capability requests in AST:
  ! @sys_mem_slice  (Used in src/decoder.sa:45)
  ! @sys_io_read    (Used in src/loader.sa:12)
  ! @sys_net_tx     (Used in src/telemetry.sa:8) -> [CRITICAL WARNING]

[Evaluation] 
  Trust Score: 15 / 100 (HIGH RISK - Network exfiltration possible)
```

信用分等级：
| 分数 | 等级 | 含义 |
|---|---|---|
| 100 | Pure Compute | 无任何 `@sys_*`，纯数学 |
| 80 | 内存分配 | 仅 `@sys_mem_*` |
| 50 | 本地 IO | 含 `@sys_io_*` |
| ≤ 20 | HIGH RISK | 含 `@sys_net_*` 或跨核心绑定 |

报告会**直接撕下**所有开源包的伪装：开发者只想下个本地图片解析库，结果 AST 里赫然发现 `@sys_net_tx` —— 它在偷偷收集用户数据！

### Q: 引入了高危包，编译器会自动删源码吗？

**A**: **不会**。SA 不会粗暴剥夺开发者的"数字主权"。但它通过**极致摩擦**让你忽略风险的代价大到可怕。

机制：
1. 源码照常落盘到 `sa_vendor/`
2. 编译器在内存中标记为 `BLOCKED_RISK`，阻塞编译管线
3. 终端清屏，弹出**审判台**，列出所有越权权限 + 源码位置
4. 必须**完整输入**仓库 URL 字符串（如 `github.com/hacker/bad-lib`）才能解锁
5. 不接受 `y/n` 简写、不接受裁剪
6. 非 TTY 环境（管道 / `yes |`）→ `Trap: MissingTtyForConfirmation` 立刻退出
7. 输入错误或 `Ctrl+C` → 进程当场物理死亡

多输几次后，开发者会被逼着 fork 净化或更换依赖。**用极致的交互摩擦力，硬生生逼着开发者去净化他们的依赖树**。

### Q: 那我每次 build 都要重新输一遍 URL，太烦了！能不能记住？

**A**: 不能写盘。但**可以**写到 `sa.lock` 的"机器码哈希"里。

逻辑：
1. 你输入 URL 通过审判台 → 编译器立刻把这个包单独编出 SA-ASM 机器码
2. 计算机器码 SHA-256 → 写入项目本地的 `sa.lock`：

```
dependency "github.com/hacker/bad-lib" {
    version: "v1.2.0"
    source_sha:                "8f4e2d..."
    approved_machine_code_hash: "a1b2c3..."
}
```

3. 下次 `sa build`：编译器在内存中重新生成机器码，与 `sa.lock` 比对：
   - **一致** → 静默放行（增量 AOT 红利）
   - **不一致** → 重弹审判台

为什么锁机器码不锁源码？因为黑客可能用复杂宏混淆，源码字节看似没变但执行逻辑变了。**机器码序列变化骗不了人**。

### Q: 这个豁免能写到 `sa.mod` 吗？让团队共享？

**A**: **绝对不行**。这是设计中最严格的一条：

> 风险只属于**当前终端、此时此刻、那一个人**。

原因：允许写入 `sa.mod` 会通过 Git 横向传播：

```
开发者 A 本地敲下确认 → 写入 sa.mod
       ↓
push 到 GitHub
       ↓
开发者 B、CI/CD 拉代码 → 自动继承高危豁免
       ↓
毒包在生产环境无声运行
```

**`sa.lock` 的机器码哈希也只属于当前项目**：哪怕同一台机器上两个项目都依赖同一个高危包，开发者必须**各自**面对一次审判台、**各自**输入 URL、**各自**生成物理隔离的 `sa.lock`。

### Q: 为什么禁止全局机器码缓存复用？

**A**: 防止"信任污染（Trust Contamination）"。

| 场景 | 风险 |
|---|---|
| 爬虫项目引入网络库 → `@sys_net_tx` 合理 | 可放行 |
| 加密钱包项目引入**同一**网络库 | 物理防线被无声击穿 |

如果允许全局缓存复用，钱包项目的编译器会读全局缓存说"哦这段机器码之前确权过了，放行" —— **加密钱包的物理防线直接被无声无息击穿**。

SA 的解法：每个项目都是物理孤岛（Air-Gap），机器码缓存绝不出全局路径，`approved_machine_code_hash` 只在项目本地的 `sa.lock`。

### Q: GitHub Actions 没有 TTY，怎么处理审判台？

**A**: SA 编译器自动探测 CI 模式（`CI=true` / `GITHUB_ACTIONS=true` / `isatty=false`），切换到双轨制：

#### 默认：冷酷熔断（Fail-Safe）
- 发现未审计高危依赖 → 打印权限列表 → 退出码 1 → 流水线爆红
- 黑客 PR 第一秒被拒
- 必须显式加 `sa build --allow-unaudited-risks` 才能放行

#### 选项：染色放行（Tainted Pass）
- 不卡死流水线，照常输出二进制 / WASM
- 产物元数据段被注入 `TAINTED_UNAUDITED_CODE` 标记
- 编译日志输出醒目 ASCII 警告 Banner
- `$GITHUB_STEP_SUMMARY` 自动钉一张"高风险资产看板"
- 任何团队成员打开 PR 第一眼就看到，不需要去翻几万行日志
- **染色无法被 `--release` 移除**：运行时 stderr 强行打印三行红字警告

### Q: 内网 / 断网企业怎么用 SA 包管理？

**A**: SA 的零信任设计天然兼容空气间隙（Air-Gapped）环境。

#### 方案 1：全源码入库（Vendor Committal）
```bash
# 在桥接机（有外网）
sa fetch                       # 拉到 ./sa_vendor/

# 把 sa_vendor/ + sa.mod + sa.lock 全部提交到内网私有 Git
git add sa_vendor sa.mod sa.lock
git commit -m "vendor deps for offline build"

# 内网 CI
sa build --offline             # 编译器完全切断网络模块
```

由于 SA 所有依赖都是极简纯文本，提交到 Git 无压力（对比 `node_modules` 几 GB 的二进制黑洞）。

#### 方案 2：URL 镜像劫持（环境变量）
```dockerfile
# Dockerfile / Kubernetes / GitHub Actions
ENV SA_MIRROR_GITHUB_COM=gitlab.corp.local/mirror
ENV SA_MIRROR_GITLAB_COM=gitlab.corp.local/proxy
```

容器销毁 → 规则灰飞烟灭，硬盘无任何垃圾。**严禁**全局配置文件。

### Q: 单机开发者如何安全地为 Linux/Windows/macOS 同时发布？

**A**: SA 的信任锚点是**平台无关的源码 SHA**，不是机器码。

工作流：
1. 开发者在 Mac 上跑 `sa fetch` + 审计 + 输入 URL → `sa.mod` 锁定源码 SHA
2. 推到 GitHub Actions
3. Ubuntu / Windows / macOS Runner 各自拉代码
4. 三个平台的 SA 编译器**各自**算源码 SHA → 与 `sa.mod` 比对 → 一致则放行
5. 各自生成对应平台的机器码

**开发者审的是"逻辑"，CI 负责"翻译"，两者在源码 SHA 处完美交接**。

如果是级场景，加上 `sa build --all-targets --lock-only`：Zig 在轻薄笔记本上几秒内推导出全平台机器码哈希全部写进 `sa.lock`。

### Q: 怎么防御传递依赖（A 依赖 B，B 依赖 C）的投毒？

**A**: SA 引入扁平的全树哈希记录 `sa.sum`：

```
// sa.sum —— 整棵依赖树的哈希拍平
github.com/xiaoming/sa-ecs   @v1.2.0   sha256:8f4e2d...
github.com/org/sa-net        @main     sha256:c3a1b9...
github.com/transitive/dep    @v0.1.0   sha256:ddee01...   // 间接依赖
```

任何子树包源码字节变化 → 顶层 `sa.sum` 哈希不匹配 → **整棵树物理熔断**。

### Q: 安全审计企业级怎么用？

**A**: 传统流程：安全团队拿着 Snyk 之类的扫描工具去扫几万行源码 → 几天才能审完一个包。

SA 流程：安全主管打开 `sa.mod` 扫一眼 `grants` 列表：

| 看到的 | 结论 |
|---|---|
| `grants []` 或不写 | 这是纯算力库，闭眼放行 |
| `grants [io_read]` | 只能读本地文件，不能联网或写入 |
| `grants [net_tx]` | 这个包能联网，必须人肉审计 X 光报告 |

不管这个包源码写得多么诡异，只要在 `sa.mod` 里被定义为零权限或受限权限，它就**绝对无法**调用越权原语。第三方包被**物理超度**为透明的、关在笼子里的物理切片。

### Q: 如果黑客攻破 GitHub 账号覆盖了 v1.2.0 tag 怎么办？

**A**: SA 的源码 SHA 和机器码 SHA 双轨核验直接物理熔断。

1. 黑客覆盖 tag → 上游源码字节变化
2. 编译器拉源码 → 算 SHA → 与 `sa.mod` 锁定的 `sha256:...` 不一致
3. 立刻 `Fatal Error: UpstreamShaMismatch` 物理熔断
4. 即使开发者本地已确权过 → 机器码哈希也对不上 `sa.lock` → 重弹审判台

没有你的手动确认和修改 `sa.mod` / `sa.lock`，**任何更新都无法潜入**。

### Q: SA 的包管理为什么强调"零隐式状态"？

**A**: 因为隐式状态是工程灾难的根源。

| 隐式状态来源 | 引发的问题 |
|---|---|
| `~/.cargo/config` 全局配置 | "在我机器上能跑"症 |
| `$NPM_TOKEN` / `$GOPRIVATE` | CI 上突然失败 |
| `node_modules` 跨项目幽灵复用 | 升级一个项目影响另一个 |
| npm `package.json` 的 `scripts` | 投毒入口 |
| `postinstall` 全局副作用 | SSH 密钥被偷 |

SA 把所有状态收敛到三处：
1. **项目本地** `sa.mod` / `sa.lock` / `sa.sum`（提交到 Git）
2. **进程级**环境变量（用完即毁）
3. **进程内存**的临时审判通过状态（进程退出蒸发）

这就是真正的**绿色软件**和**零信任编译**。

---

## 总结：SA 的设计哲学

| 原则 | 含义 |
|---|---|
| **零 AST** | 任何需要树结构才能表达的语法都不引入 |
| **线性扫描** | Referee 从头到尾扫一遍，不回溯 |
| **O(1) 位掩码** | 所有权校验是位运算，不是图论 |
| **前端责任制** | 高级语义的降级由前端完成，SA 只做事后校验 |
| **只保留原子操作** | 如果一个特性可以被已有原语组合表达，就不引入新关键字 |
| **显式优于隐式** | 宁可代码冗长，也不允许隐式行为（Drop、类型推导、生命周期推导） |

**SA 不是为人类手写设计的语言。** 它是为机器（LLM / smrustc 前端）生成、为 Referee 验证、为 LLVM 发射而设计的**中间协议**。人类偶尔需要阅读它（调试时），但不应该把它当作日常编程语言使用。

---

# SA vs Go / Zig / Rust：对比分析

> 以下对比基于 SA v0.2 规范。SA 不是这三门语言的"替代品"——它是一个**不同层次**的工具。但既然你问了，我们就诚实地比。

---

## 定位对比

| 维度 | Go | Zig | Rust | SA |
|---|---|---|---|---|
| **设计目标** | 简单、快速编译、并发 | 系统级、零开销抽象、可审计 | 安全、零开销、表达力 | 机器验证、LLM 生成、O(1) 所有权校验 |
| **主要受众** | 后端工程师 | 系统/嵌入式工程师 | 全栈系统工程师 | LLM / 编译器前端 / 沙盒裁判 |
| **类型系统** | 静态、简单 | 静态、comptime 泛型 | 静态、复杂（Trait + 生命周期） | **无**（只有 ptr + 原生数值） |
| **内存管理** | GC | 手动（Allocator 显式） | 所有权 + 借用检查器 | 仿射掩码（编译期 O(1) 位运算） |
| **编译速度** | 极快（秒级） | 快（秒级） | 慢（十秒到分钟级） | **前端+Referee 毫秒级**；LLVM 后端秒级 |
| **运行时** | 重（GC + goroutine 调度器） | 无 | 无（但有 panic handler） | 无（Release 模式零运行时代码） |
| **二进制体积** | 大（~10MB+） | 小（~100KB+） | 中（~1MB+） | 小（Hello World ≤ 48KB wasm / ≤ 800KB exe） |

---

## 性能对比

### 编译速度

| 阶段 | Go | Zig | Rust | SA |
|---|---|---|---|---|
| 词法+语法分析 | ~100ms | ~200ms | ~500ms | **~5ms**（逐行扫描，零 AST） |
| 类型检查 | ~200ms | ~300ms | ~2-5s（Trait 求解） | **0ms**（无类型系统） |
| 借用检查 | N/A | N/A | ~1-3s（NLL/Polonius） | **~10ms**（O(1) 位掩码线性扫描） |
| 优化+代码生成 | ~500ms（SSA） | ~1-3s（LLVM） | ~5-30s（LLVM） | ~1-5s（LLVM，与 Rust 共享瓶颈） |
| **端到端（10K 行）** | **~1s** | **~2-4s** | **~10-30s** | **~2-6s**（前端极快，LLVM 是瓶颈） |

**SA 的编译速度优势**：
- 前端（Flattener + Referee）比 Rust 快 **100-1000x**，因为没有类型推导和借用图分析
- 端到端受限于 LLVM 后端，与 Zig 同一数量级
- `sa run`（解释执行）模式下**零编译延迟**，适合开发期极速迭代

### 运行时性能

| 场景 | Go | Zig | Rust | SA |
|---|---|---|---|---|
| 纯计算（数学/循环） | 慢（GC 暂停 + 逃逸分析失败时堆分配） | **最快**（零开销） | **最快**（零开销） | **最快**（LLVM O3 产出与 Zig/Rust 等价） |
| 内存分配密集 | 慢（GC 压力） | 快（手动 Allocator） | 快（所有权自动 Drop） | 快（显式 `alloc` + `!reg`，LLVM 优化等价） |
| 函数调用 | 中（interface 有间接调用开销） | **最快**（内联） | **最快**（内联） | **最快**（LLVM 内联等价） |
| 缓存友好度 | 差（GC 碎片化） | **最好**（手动布局） | 好（但 Vec/Box 有间接层） | **最好**（显式 `#def` 偏移 = 精确控制布局） |

**SA 的运行时性能结论**：
- Release 模式下，SA 产出的机器码**与 Zig/Rust 等价**（因为都走 LLVM O3）
- SA 的优势不在"比 Rust 更快"，而在"**编译期验证成本低 100x**，运行时性能不打折"
- 对比 Go：SA 没有 GC 暂停、没有逃逸分析失败、没有 interface 间接调用——纯计算场景快 2-10x

### 内存开销

| 维度 | Go | Zig | Rust | SA |
|---|---|---|---|---|
| 运行时元数据 | 重（type info + GC bitmap） | 零 | 少（vtable 指针） | 零（Release 模式无 Referee 代码） |
| 栈帧大小 | 大（goroutine 初始 8KB） | 最小 | 小 | 最小（`stack_alloc` 精确控制） |
| 堆碎片化 | 高（GC 不紧凑） | 低（手动控制） | 低 | 低（显式 `alloc`/`!reg`） |

---

## 并发对比

### 并发模型

| 维度 | Go | Zig | Rust | SA |
|---|---|---|---|---|
| **原生并发原语** | goroutine + channel | 无（用 std.Thread） | 无（用 std::thread + async） | 无（用 `@extern` 调宿主 API） |
| **数据竞争防护** | 运行时 race detector（可选） | 无（靠程序员） | 编译期 Send/Sync trait | **编译期仿射掩码**（同一内存不能同时被两个写借用） |
| **共享内存安全** | 不保证（靠 channel 约定） | 不保证 | 保证（借用检查器） | **保证**（Referee 掩码 + 气闸舱隔离） |
| **异步模型** | goroutine（M:N 调度） | 无原生 async | async/await（状态机） | 无原生 async（前端 CPS 展平） |
| **原子操作** | `sync/atomic` 包 | `@atomicRmw` 内建 | `std::sync::atomic` | `atomic_rmw_*` / `cmpxchg` / `fence` |

### SA 的并发安全保证

SA 的仿射状态机**天然防止数据竞争**：

```
// 线程 A 拥有 data 的所有权
data = alloc 1024
// ...

// 把 data Move 给线程 B
call @thread_spawn(^data)
// 此刻 data.mask == Consumed
// 线程 A 再访问 data → Trap: UseAfterMove

// 线程 B 内部：
@worker(^data: ptr):
    // data 在这里是 Active，线程 B 独占
    !data
    return
```

**对比 Go**：Go 的 goroutine 可以随意共享内存，race detector 只在运行时检测（且有性能开销）。SA 在**编译期**就阻断了数据竞争。

**对比 Rust**：Rust 用 `Send`/`Sync` trait 在类型系统层保证。SA 用更简单的机制——仿射掩码（`^` Move 后源变为 Consumed）——达到等价效果，但不需要复杂的 trait 求解器。

**对比 Zig**：Zig 完全不保证并发安全，靠程序员自律。SA 比 Zig 严格。

### SA 的并发局限

| 局限 | 说明 | 缓解 |
|---|---|---|
| 无原生 goroutine/async | 并发调度完全交给宿主 | `@extern` 调用 OS/runtime API |
| 无原生 channel 关键字 | 需要手搓或用 FFI | 用 `sa_std/sync/mpsc.sa` + `atomic_rmw_*` + 共享 buffer 实现 |
| 无 M:N 调度器 | SA 不管线程如何调度 | 宿主（Go runtime / tokio / libuv）负责 |
| async 膨胀 40x | CPS 转换代码量大 | v0.3 `libsa_async` 宏模板（R26） |

---

## SA 的独特优势（Go/Zig/Rust 都没有的）

### 1. O(1) 编译期所有权验证

| 语言 | 借用检查复杂度 | 实现代码量 |
|---|---|---|
| Rust | O(N³)（NLL 图论） | ~200,000 行 |
| SA | O(N)（线性扫描 + 位运算） | ≤ 2,500 行 |

SA 的 Referee 是一个**极简状态机**：每条指令只需一次哈希查找 + 一次位 AND/OR。没有图论、没有约束求解、没有回溯。

### 2. LLM 原生友好

| 维度 | Go/Zig/Rust | SA |
|---|---|---|
| 嵌套结构 | 深层 `{}` 嵌套 | 零嵌套（Label + jmp） |
| 闭合错误 | LLM 常见 bug | 不可能发生 |
| 类型推导 | LLM 需要理解上下文 | 无类型系统，每行自包含 |
| 错误反馈 | 人类可读散文 | 结构化 JSON（机器可直接消费） |
| 自修复闭环 | 需要人类介入 | Trap JSON → LLM 自动定位 → 重新生成 |

### 3. 气闸舱 FFI（比 Rust 的 unsafe 更严格）

| 维度 | Rust | SA |
|---|---|---|
| unsafe 粒度 | 块级（`unsafe { ... }`） | **函数级**（`@ffi_wrapper`） |
| unsafe 扩散 | 可以在任何函数内随意开启 | 只能在专门标记的函数内 |
| 审计成本 | 需要搜索所有 `unsafe` 块 | 只需审查 `@ffi_wrapper` 函数列表 |
| 违规检测 | 编译器不阻止 unsafe 内的逻辑错误 | Referee O(1) 强制校验函数标志位 |

### 4. 函数级并行编译（天然支持）

| 维度 | Go | Zig | Rust | SA |
|---|---|---|---|---|
| 编译单元 | 包（package） | 文件 | crate | **函数** |
| 跨单元依赖 | 类型检查需要 | 类型检查需要 | Trait 求解需要 | **零**（Referee 逐函数独立） |
| 并行编译 | 包级并行 | 文件级并行 | crate 级并行 | **函数级并行**（v0.4 R30） |
| 增量编译 | 包级 | 文件级 | 函数级（但受 trait 约束） | **函数级**（无约束） |

### 5. 确定性 Gas 计量（沙盒安全）

Go/Zig/Rust 都没有内建的"执行步数预估"能力。SA 的 Referee 在编译期就能输出 `GasReport`：

```json
{
  "max_alloc_bytes": 4096,
  "max_instruction_steps": "bounded(1200)",
  "max_call_depth": 3,
  "has_unbounded_loop": false
}
```

这让 SA 天然适合作为**LLM 代码沙盒**——在执行前就能判断代码是否会失控。

### 6. 零运行时开销的内存安全

| 语言 | 内存安全保证 | 运行时开销 |
|---|---|---|
| Go | GC 保证 | **高**（GC 暂停 + 写屏障） |
| Zig | 不保证 | 零 |
| Rust | 编译期保证 | 零 |
| SA | 编译期保证 | **零**（且验证器本身比 Rust 简单 100x） |

---

## 诚实的劣势（当前 v0.1 状态，非永久限制）

| 维度 | 当前状态 | 路线图 |
|---|---|---|
| **人类可写性** | 手写较冗长 | `#mode compact` ~~（v0.2）~~+ `libsa_async`（v0.3）缓解；已由外部 SLA 插件（`sa_plugin_sla`）提供完整 Rust 风格语法替代 |
| **标准库** | 仅 `@sys_*` 基础原语 | v0.5+ 逐步添加 `sa_std`（网络/JSON/哈希表/排序） |
| **生态系统** | 无第三方库 | 通过 C-ABI FFI 桥接任何现有库；LLM 可直接手搓 |
| **跨函数安全** | 不保证（前端责任） | `libsa_scope` helper + v0.3 `--debug-san` 运行期检测 |
| **async 体验** | 40x 膨胀 | v0.3 `libsa_async` 宏模板降到 ~13x |
| **调试体验** | 依赖 `#loc` + DWARF | v0.1 已支持 `-g` 产出 DWARF |

---

## 什么时候该用 SA？

SA 是一门**全平台、全场景**的独立系统语言。通过 `sa build-exe` 产出原生二进制，通过 `sa build-wasm` 产出浏览器/边缘可执行的 WASM 模块——覆盖从前端到后端、从嵌入式到云端的全部场景。

| 场景 | SA 适合度 | 说明 |
|---|---|---|
| LLM 独立生成完整应用 | ✅ **核心目标** | SA 的设计初衷：LLM 不依赖第三方库，用 `@sys_*` 原语 + 手搓数据结构独立完成 app |
| 沙盒执行不信任的代码 | ✅ | Gas 计量 + O(1) 验证 + 气闸舱 |
| 编译器中间表示（IR） | ✅ | 比 LLVM bitcode 多了所有权验证 |
| ECS 游戏引擎核心 | ✅ | 精确内存布局 + 并行调度 |
| 嵌入式/WASM 极小体积 | ✅ | 无运行时、无 GC、≤ 48KB |
| **前端 Web 应用** | ✅ | `sa build-wasm` 产出 `.wasm`，浏览器直接加载执行；可操作 DOM（通过 `@extern` 调 JS 桥接）或纯计算模块 |
| Web 后端 API 服务 | ✅ **可行** | 通过 `@sys_*` 网络原语（v0.5 路线图）或 FFI 桥接现有 HTTP 库；LLM 可直接用 SA 手搓 HTTP 解析器 |
| 日常应用开发 | ✅ **可行** | LLM 生成 SA 代码的场景下完全可行；人类手写时建议开启 `#mode compact` ~~降低心智负担~~（已由外部 SLA 插件提供完整 Rust 风格语法替代） |
| 快速原型 | ✅ **可行** | `sa run` 毫秒级启动，LLM 生成 → Referee 验证 → 立即执行的闭环比 Python 更安全 |
| 需要标准库功能 | ✅ **路线图中** | v0.5+ 将逐步添加 `sa_std` 库（网络/JSON/哈希表/排序/DOM 绑定等），以 `.sa` 宏文件形式提供 |
| 移动端/IoT | ✅ | WASM 跑在任何支持 WASI 的 runtime 上；原生二进制可交叉编译到 ARM |

**SA 的产出覆盖全平台**：

```
                    sa build-exe
.sa 源码 ──────────────────────────► .exe (Windows/Linux/macOS/ARM)
     │
     │              sa build-wasm
     └────────────────────────────────► .wasm (浏览器/Node.js/Deno/边缘计算/IoT)
     │
     │              sa build-obj
     └────────────────────────────────► .o (嵌入任何 C/C++/Rust/Go/Zig 工程)
     │
     │              sa run
     └────────────────────────────────► 直接执行（开发期零编译延迟）
```

**SA 的愿景**：不是"某些场景用 SA，其它场景用别的语言"，而是**LLM 用 SA 独立完成一切**。`@sys_*` 原语提供操作系统接口，`sa_std` 提供常用数据结构，LLM 的千亿参数提供业务逻辑——三者组合可以覆盖任何应用场景。

**当前状态 vs 愿景**：
- v0.1：`@sys_*` 覆盖文件读写 + 终端打印 + 进程控制（足够写 CLI 工具和编译器）
- v0.5+：添加网络 socket、HTTP 解析、JSON 编解码、哈希表、动态数组等标准库
- 终极：LLM 评测标准 = "给定需求描述，LLM 用 SA 独立产出可运行的完整应用，零人工干预"

---

## 一句话总结

> **SA 是为 LLM 时代设计的独立系统语言。**
>
> 它让 AI 能以极低成本生成内存安全的代码，通过 O(1) 位掩码验证正确性，通过 LLVM 产出与 Zig/Rust 等价性能的机器码。它不依赖任何宿主、不依赖任何第三方库——LLM + SA + `@sys_*` 原语就能独立完成一个完整应用。
>
> 与 Go/Zig/Rust 的关系不是"替代"，而是"可互操作的独立选择"。SA 可以独立运行，也可以通过 C-ABI 与任何语言协作。

---

# SA 中如何写单元测试？

> SA 不内建 `test` 关键字（不像 Rust 的 `#[test]` 或 Zig 的 `test "name"`）。这是刻意的——SA 是中间协议，不是日常开发语言。但你仍然需要测试用 SA 写的代码。以下是三种测试模式。

---

## 模式 1：`sa run` 驱动的断言测试（推荐）

最简单的方式：写一个 `.sa` 测试文件，用 `@sys_exit(code)` 表达 pass/fail。

```
// tests/test_add.sa
@main:
L_ENTRY:
    a = 3
    b = 4
    result = add a, b
    expected = 7
    ok = eq result, expected
    br ok -> L_PASS, L_FAIL

L_PASS:
    call @sys_exit(0)          // exit code 0 = pass

L_FAIL:
    call @sys_exit(1)          // exit code != 0 = fail
```

运行：
```bash
sa run tests/test_add.sa
echo $?   # 0 = pass, 非零 = fail
```

**优点**：零依赖，任何 CI 都能跑。
**缺点**：每个测试一个文件，无法在一个文件里跑多个用例。

---

## 模式 2：多用例测试文件（用 Label 组织）

一个文件里放多个测试用例，用 `panic` 标记失败位置：

```
// tests/test_math.sa

#def PANIC_ASSERT = 103

@assert_eq(actual: i64, expected: i64):
L_ENTRY:
    ok = eq actual, expected
    br ok -> L_OK, L_FAIL
L_OK:
    return
L_FAIL:
    panic(PANIC_ASSERT)

@main:
L_ENTRY:
    // Test 1: add
    r1 = add 3, 4
    call @assert_eq(r1, 7)

    // Test 2: sub
    r2 = sub 10, 3
    call @assert_eq(r2, 7)

    // Test 3: mul
    r3 = mul 6, 7
    call @assert_eq(r3, 42)

    // All passed
    call @sys_exit(0)
```

运行：
```bash
sa run tests/test_math.sa
# exit 0 = all pass
# panic 103 = 某个 assert_eq 失败（stderr 会打印 panic code）
```

**优点**：一个文件多个用例，失败时 panic code 指向断言。
**缺点**：第一个失败就终止，无法看到后续用例结果。

---

## 模式 3：测试 harness 脚本（批量运行）

用 shell/Python 脚本批量运行 `.sa` 测试文件：

```bash
#!/bin/bash
# run_tests.sh
PASS=0
FAIL=0

for test_file in tests/test_*.sa; do
    sa run "$test_file" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "PASS: $test_file"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $test_file"
        FAIL=$((FAIL + 1))
    fi
done

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
```

**优点**：每个测试独立进程，一个失败不影响其它。
**缺点**：每个测试都要启动一次 `sa run`（但 SA 的解释器启动极快，毫秒级）。

---

## 模式 4：Referee 验证测试（编译期断言）

有些测试不需要运行——只需要验证 Referee 是否正确 Trap：

```
// tests/must_trap/double_borrow.sa
// 预期：Referee 应该返回 Trap: DoubleMutableBorrow

@main:
L_ENTRY:
    x = alloc 8
    r1 = &x
    store r1+0, 42 as i32     // r1 写入 → x 变为 Locked_Mut
    r2 = &x                    // ❌ 此时 x 已 Locked_Mut，再借用应 Trap
    !r1
    !r2
    !x
    return
```

测试脚本：
```bash
# 预期 sa build-obj 失败并输出特定 Trap
output=$(sa build-obj tests/must_trap/double_borrow.sa -o /dev/null 2>&1)
echo "$output" | grep -q '"trap":"DoubleMutableBorrow"' && echo "PASS" || echo "FAIL"
```

**优点**：测试 Referee 本身的正确性，不需要运行代码。
**缺点**：只能测试"应该失败"的场景。

---

## 模式 5：`@export` + 外部测试框架（与 C/Zig/Rust 测试集成）

把 SA 函数编译为 `.o`，用 Zig/Rust/C 的测试框架调用：

```
// lib.sa
@export sa_add(a: i32, b: i32) -> i32:
L_ENTRY:
    r = add a, b
    return r
```

```zig
// test_lib.zig（Zig 测试）
const sa = @cImport(@cInclude("sa_exports.h"));
// 或直接链接 .o

test "sa_add works" {
    try std.testing.expectEqual(@as(i32, 7), sa.sa_add(3, 4));
}
```

构建：
```bash
sa build-obj lib.sa -o lib.o
zig test test_lib.zig --object lib.o
```

**优点**：复用成熟测试框架（Zig test / Rust #[test] / Google Test）。
**缺点**：需要额外的构建步骤。

---

## 测试辅助宏（推荐放入 `sa_core.sa`）

为了减少测试样板代码，建议在标准库宏文件中提供：

```
// sa_core.sa（标准测试宏）

[MACRO] ASSERT_EQ %cond, %actual, %expected, %ok_label, %fail_label
    %cond = eq %actual, %expected
    br %cond -> %ok_label, %fail_label
[END_MACRO]

[MACRO] ASSERT_TRUE %cond, %ok_label, %fail_label
    br %cond -> %ok_label, %fail_label
[END_MACRO]

[MACRO] ASSERT_NE %cond, %actual, %unexpected, %ok_label, %fail_label
    %cond = ne %actual, %unexpected
    br %cond -> %ok_label, %fail_label
[END_MACRO]
```

使用：
```
@import "sa_core.sars"

@main:
L_ENTRY:
    r = add 3, 4
    EXPAND ASSERT_EQ assert_eq_cond_0, r, 7, L_ASSERT_EQ_0_OK, L_ASSERT_EQ_0_FAIL
L_ASSERT_EQ_0_FAIL:
    panic(103)
L_ASSERT_EQ_0_OK:

    s = mul 6, 7
    EXPAND ASSERT_EQ assert_eq_cond_1, s, 42, L_ASSERT_EQ_1_OK, L_ASSERT_EQ_1_FAIL
L_ASSERT_EQ_1_FAIL:
    panic(103)
L_ASSERT_EQ_1_OK:

    call @sys_exit(0)
```

---

## 为什么 SA 不内建 `test` 关键字？

| 原因 | 说明 |
|---|---|
| **定位不同** | SA 是中间协议，不是日常开发语言。测试驱动方是宿主，不是语言本身 |
| **零 AST 原则** | `test "name" { ... }` 需要嵌套块语法，违反 R3 扁平化 |
| **前端责任** | smrustc 前端有自己的测试框架（Zig test）；LLM 生成的代码由 Referee Trap 验证 |
| **已有等价物** | `@main` + `panic(PANIC_ASSERT)` + `@sys_exit(0)` 完全覆盖测试语义 |
| **不增加编译器复杂度** | 内建 `test` 需要测试发现、过滤、报告机制——这些是构建工具的职责 |

---

## 测试最佳实践总结

| 测试类型 | 推荐模式 | 适用场景 |
|---|---|---|
| 单函数逻辑 | 模式 2（多用例 + `ASSERT_EQ` 宏） | 日常开发 |
| Referee 行为 | 模式 4（must_trap 预期失败） | 验证所有权规则 |
| 集成/端到端 | 模式 3（批量脚本） | CI 流水线 |
| 与外部库交互 | 模式 5（`@export` + Zig/Rust 测试） | FFI 桥接验证 |
| 性能基准 | `sa run` + 外部计时 | 回归检测 |

---

## CI 集成示例

```yaml
# .github/workflows/sa-test.yml
name: SA Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2
      - name: Build sa CLI
        run: zig build -Doptimize=ReleaseFast
      - name: Run SA unit tests
        run: |
          for f in tests/test_*.sa; do
            echo "Testing: $f"
            ./zig-out/bin/sa run "$f" || exit 1
          done
      - name: Run must-trap tests
        run: |
          for f in tests/must_trap/*.sa; do
            echo "Trap test: $f"
            ./zig-out/bin/sa build-obj "$f" -o /dev/null 2>&1 | grep -q '"trap"' || exit 1
          done
      - name: Build and test exported functions
        run: |
          ./zig-out/bin/sa build-obj lib.sa -o lib.o
          zig test tests/test_exports.zig --object lib.o
```

---

# 重要澄清：SA 是独立语言，不是宿主语言的附庸

> **SA 不依赖任何宿主。** 它是一门完全独立的编程语言，拥有自己的：
> - CLI 工具链（`sa run` / `build-exe` / `build-wasm` / `build-obj`）
> - 内建系统原语（`@sys_print` / `@sys_read_file` / `@sys_write_file` / `@sys_exit` / `@sys_argv` / `@sys_argc`）
> - 独立可执行文件产出（不需要 Go/Rust/Zig 运行时）
> - 内存解释器（`sa run` 直接执行，零外部依赖）
>
> SA 可以**独立完成一个完整应用**：读文件、处理数据、写文件、打印输出、返回退出码。
>
> 与其它语言的互操作是**可选能力**，不是必需依赖。

---

# SA 如何与 Rust / Go / Zig / C++ 配合使用？

SA 通过标准 **C-ABI**（`.o` 目标文件 + 函数符号）与任何语言无缝互操作。不需要特殊的绑定生成器、不需要 IDL、不需要 protobuf。

---

## 通用原则

```
┌─────────────┐     C-ABI (.o)      ┌─────────────┐
│  SA 模块    │ ◄──────────────────► │ 其它语言    │
│  (.sa)   │     @extern / @export│ (Rust/Go/   │
│             │                      │  Zig/C++)   │
└─────────────┘                      └─────────────┘
         │                                    │
         ▼                                    ▼
    sa build-obj                    各自编译器
         │                                    │
         ▼                                    ▼
      module.o                           other.o / .a
         │                                    │
         └──────────── zig cc ────────────────┘
                          │
                          ▼
                    final_binary.exe
```

**SA 侧**：
- `@export` 函数 → 产出无名称修饰的 C-ABI 符号
- `@extern` 声明 → 引用外部语言提供的 C-ABI 符号

**其它语言侧**：
- 暴露 `extern "C"` / `#[no_mangle]` / `export` 函数
- 调用 SA 导出的符号（就像调用普通 C 函数）

---

## SA + Rust

### SA 调用 Rust

```rust
// rust_lib/src/lib.rs
#[no_mangle]
pub extern "C" fn rust_hash(data: *const u8, len: usize) -> u64 {
    use std::hash::{Hash, Hasher};
    use std::collections::hash_map::DefaultHasher;
    let slice = unsafe { std.slice::from_raw_parts(data, len) };
    let mut hasher = DefaultHasher::new();
    slice.hash(&mut hasher);
    hasher.finish()
}
```

```
// sa_app.sa
@extern rust_hash(*data: ptr, len: u64) -> u64

@ffi_wrapper hash_buffer(buf: &ptr, len: u64) -> u64:
L_ENTRY:
    data = load buf+0 as ptr
    raw = *data
    result = call @rust_hash(raw, len)
    return result
```

构建：
```bash
# 编译 Rust 为静态库
cd rust_lib && cargo build --release
# 编译 SA 为目标文件
sa build-obj sa_app.sa -o sa_app.o
# 链接
zig cc sa_app.o target/release/librust_lib.a -o app.exe -lpthread -ldl
```

### Rust 调用 SA

```
// sa_math.sa
@export sa_dot_product(a: &ptr, b: &ptr, len: u64) -> f64:
L_ENTRY:
    sum = 0.0
    i = 0
    jmp L_COND
L_COND:
    c = ult i, len
    br c -> L_BODY, L_END
L_BODY:
    off = mul i, 8
    av = ptr_add a, off
    bv = ptr_add b, off
    x = load av+0 as f64
    y = load bv+0 as f64
    p = fmul x, y
    sum = fadd sum, p
    i = add i, 1
    jmp L_COND
L_END:
    return sum
```

```rust
// rust_app/src/main.rs
extern "C" {
    fn sa_dot_product(a: *const f64, b: *const f64, len: u64) -> f64;
}

fn main() {
    let a = [1.0, 2.0, 3.0];
    let b = [4.0, 5.0, 6.0];
    let result = unsafe { sa_dot_product(a.as_ptr(), b.as_ptr(), 3) };
    println!("dot product = {}", result);  // 32.0
}
```

构建：
```bash
sa build-obj sa_math.sa -o sa_math.o
cd rust_app && RUSTFLAGS="-L .. -l static=sa_math" cargo build
```

---

## SA + Go

### SA 调用 Go

```go
// go_lib/lib.go
package main

import "C"

//export go_compress
func go_compress(data *C.char, len C.int, out *C.char, out_cap C.int) C.int {
    // ... 压缩逻辑 ...
    return compressed_len
}

func main() {}
```

```
// sa_app.sa
@extern go_compress(*data: ptr, len: i32, *out: ptr, out_cap: i32) -> i32

@ffi_wrapper compress(input: &ptr, input_len: u64) -> ^ptr:
L_ENTRY:
    out = alloc 4096
    data = load input+0 as ptr
    raw_data = *data
    raw_out = *out
    result_len = call @go_compress(raw_data, input_len, raw_out, 4096)
    return ^out
```

构建：
```bash
# Go 编译为 C 静态库
cd go_lib && go build -buildmode=c-archive -o libgo_lib.a
# SA 编译
sa build-obj sa_app.sa -o sa_app.o
# 链接
zig cc sa_app.o libgo_lib.a -o app.exe -lpthread
```

### Go 调用 SA（通过 cgo）

```
// sa_fast.sa
@export sa_fibonacci(n: i32) -> i64:
L_ENTRY:
    a = 0
    b = 1
    i = 0
    jmp L_COND
L_COND:
    c = slt i, n
    br c -> L_BODY, L_END
L_BODY:
    tmp = add a, b
    a = b
    b = tmp
    i = add i, 1
    jmp L_COND
L_END:
    return a
```

```go
// main.go
package main

/*
#cgo LDFLAGS: -L. -lsa_fast
int64_t sa_fibonacci(int32_t n);
*/
import "C"
import "fmt"

func main() {
    result := C.sa_fibonacci(40)
    fmt.Printf("fib(40) = %d\n", result)  // 102334155
}
```

构建：
```bash
sa build-obj sa_fast.sa -o sa_fast.o
ar rcs libsa_fast.a sa_fast.o
go build -o app main.go
```

---

## SA + Zig

### SA 调用 Zig

```zig
// zig_lib/src/lib.zig
export fn zig_sort(data: [*]i32, len: usize) void {
    const slice = data[0..len];
    std.sort.sort(i32, slice, {}, std.sort.asc(i32));
}
```

```
// sa_app.sa
@extern zig_sort(*data: ptr, len: u64)

@ffi_wrapper sort_array(arr: &ptr, len: u64):
L_ENTRY:
    data = load arr+0 as ptr
    raw = *data
    call @zig_sort(raw, len)
    return
```

构建：
```bash
# Zig 编译为静态库
cd zig_lib && zig build-lib -OReleaseFast
# SA 编译
sa build-obj sa_app.sa -o sa_app.o
# 链接（zig cc 天然兼容 Zig 产物）
zig cc sa_app.o zig_lib/zig-out/lib/libzig_lib.a -o app.exe
```

### Zig 调用 SA

```zig
// main.zig
const sa = @cImport({});
extern fn sa_fibonacci(n: i32) i64;

pub fn main() !void {
    const result = sa_fibonacci(40);
    std.debug.print("fib(40) = {}\n", .{result});
}
```

构建：
```bash
sa build-obj sa_fast.sa -o sa_fast.o
zig build-exe main.zig --object sa_fast.o
```

---

## SA + C/C++

以下 `#include` 仅出现在宿主 C/C++ 示例中；SA 自身统一使用 `@import`。

### SA 调用 C/C++

```c
// c_lib.c
// C/C++ 宿主示例仍可使用 `#include`
#include <math.h>
double c_sqrt(double x) { return sqrt(x); }
```

```
// sa_app.sa
@extern c_sqrt(*x: f64) -> f64    // 注意：按值传 f64 也可以

@ffi_wrapper safe_sqrt(val: f64) -> f64:
L_ENTRY:
    // f64 按值传递，不需要裸指针
    result = call @c_sqrt(val)
    return result
```

实际上对于按值传递的原生数值，不需要气闸舱：

```
// 更简洁：f64 按值传递不涉及指针，可以直接 @extern
@extern c_sqrt(x: f64) -> f64

@compute(val: f64) -> f64:
L_ENTRY:
    result = call @c_sqrt(val)
    return result
```

### C/C++ 调用 SA

```c
// main.c
// C/C++ 宿主示例仍可使用 `#include`
#include <stdio.h>

// SA 导出的函数
extern int sa_fibonacci(int n);
extern double sa_dot_product(const double* a, const double* b, unsigned long len);

int main() {
    printf("fib(40) = %lld\n", (long long)sa_fibonacci(40));

    double a[] = {1.0, 2.0, 3.0};
    double b[] = {4.0, 5.0, 6.0};
    printf("dot = %f\n", sa_dot_product(a, b, 3));
    return 0;
}
```

构建：
```bash
sa build-obj sa_math.sa -o sa_math.o
gcc main.c sa_math.o -o app -lm
# 或用 zig cc
zig cc main.c sa_math.o -o app -lm
```

---

## 互操作规则速查

| 场景 | SA 侧 | 其它语言侧 | 链接方式 |
|---|---|---|---|
| SA 调用外部（涉及指针） | `@extern f(*p: ptr)` + `@ffi_wrapper` | `extern "C" fn f(p: *T)` | `zig cc sa.o lib.a` |
| SA 调用外部（纯值） | `@extern f(x: i32) -> i32` | `extern "C" fn f(x: i32) -> i32` | 同上 |
| 外部调用 SA | `@export f(x: i32) -> i32` | `extern int f(int x);` | 同上 |
| SA 独立运行 | `@main` + `@sys_*` | 不需要 | `sa run` 或 `sa build-exe` |

---

## 关键点

1. **SA 是独立语言**：`sa run hello.sa` 就能跑，不需要任何其它语言的运行时
2. **互操作是可选的**：只有当你需要复用现有库（如 Rust std、Go 网络栈、C++ 引擎）时才用 `@extern` + `@ffi_wrapper`
3. **链接器是 `zig cc`**：它能链接任何 C-ABI 兼容的 `.o` / `.a` / `.so`，无论来源是什么语言
4. **气闸舱保护**：所有涉及外部指针的操作必须在 `@ffi_wrapper` 内，SA 核心逻辑保持绝对安全
5. **按值传递不需要气闸舱**：`@extern c_sqrt(x: f64) -> f64` 这种纯值函数可以直接调用，不涉及指针安全问题

---

# SA 在高可靠性 /  / 航空场景的定位

> 以下回应基于 DO-178C（航空机载系统）、MISRA C/C++（汽车安全）、以及军方软件审计标准的视角。

---

## SA 为什么天然适合高可靠性系统？

| 需求 | SA 的对应能力 | 对比 Rust/C |
|---|---|---|
| **可形式化验证** | Referee ≤ 2500 行 Zig，可翻译为 Coq/Lean4 并机器证明健全性（R33） | Rust 借用检查器 ~200K 行，无法完整形式化验证 |
| **WCET 可预测** | Gas Metering 在编译期输出 `max_instruction_steps`；`unbounded` 循环被标记拒绝（R11） | C/Rust 无内建 WCET 分析 |
| **失效隔离** | `@ffi_wrapper` 气闸舱物理隔离遗留 C 代码（R13） | Rust 的 `unsafe` 块可随处出现，审计成本高 |
| **零隐式控制流** | 无 GC、无隐式 Drop、无异常展开、无 async 魔法 | Go 有 GC；Rust 有隐式 Drop + panic unwinding |
| **确定性执行** | 每条指令的行为完全由当前 CapabilityMask 决定，无全局状态 | C++ 有 UB；Go 有 goroutine 调度不确定性 |
| **代码可审计性** | 扁平 Label + jmp/br，人类一眼可追踪执行路径 | 嵌套 if/else/match 需要心理压栈 |
| **硬件化潜力** | Referee 的位掩码逻辑可直接映射为 FPGA 硬件电路（R33.6） | Rust 编译器无法硬件化 |

---

## SA 当前的级缺口（诚实评估）

| 缺口 | 风险 | 缓解路线 |
|---|---|---|
| 无类型系统 → 类型混淆 | 把 f64 坐标误当 i32 标志位，Referee 不拦截 | R32 布局标签 + `--strict-tags` 强制模式（v0.5） |
| 前端合约脆弱 | 前端漏发 `!reg` → Referee Trap → 编译失败 | `libsa_scope` helper（R20.8）+ 形式化验证的前端（v0.6+） |
| 缺乏形式化语义证明 | 军方不信任"测试通过率 99.9%"，要求数学证明 | R33 Coq/Lean4 形式化验证（v0.6） |
| LLM 生成的代码不可信 | LLM 幻觉 / 提示词注入 / 数据中毒 | SA 不强制依赖 LLM；场景用经过形式化验证的确定性前端 |
| 无成熟工具链生态 | 军方需要 IDE、调试器、静态分析器 | v0.1 已有 DWARF 调试支持；工具链逐步完善 |

---

## 关键澄清：SA 不依赖 LLM

> **SA 是独立语言，LLM 是可选的代码生成方式。**
>
> 在场景下：
> - ❌ 不用 LLM 生成代码（不可信）
> - ✅ 用经过形式化验证的确定性前端（如 smrustc 的子集版本）降级高级语言到 SA
> - ✅ 用 SA 的 Referee 作为"IR 防火墙"——无论代码来源是什么，只要通过 Referee 就是内存安全的
> - ✅ 用 Gas Metering 保证 WCET 约束
> - ✅ 用 `--strict-tags` 保证类型不混淆

---

## 场景的推荐架构

```
┌─────────────────────────────────────────────────────────┐
│  高级语言源码（Ada SPARK / 受限 Rust 子集 / 受限 C）    │
└─────────────────────┬───────────────────────────────────┘
                      │ 形式化验证的确定性前端
                      ▼
┌─────────────────────────────────────────────────────────┐
│  SA 指令流（.sa）                                     │
│  - 所有 alloc 带 tag（--strict-tags）                    │
│  - 所有循环有 Gas 上界                                   │
│  - 所有 FFI 在气闸舱内                                   │
└─────────────────────┬───────────────────────────────────┘
                      │ Referee（2500 行，Coq 证明健全性）
                      ▼
┌─────────────────────────────────────────────────────────┐
│  已验证指令流（绝对内存安全 + WCET 有界 + 类型不混淆）   │
└─────────────────────┬───────────────────────────────────┘
                      │ LLVM-C bitcode Emitter
                      ▼
┌─────────────────────────────────────────────────────────┐
│  原生机器码（ARM / x86 / FPGA bitstream）                │
└─────────────────────────────────────────────────────────┘
```

---

## 为什么 SA 比 Rust 更适合军方审计？

| 维度 | Rust | SA |
|---|---|---|
| 借用检查器代码量 | ~200,000 行（无法完整审计） | ≤ 2,500 行（可逐行审计 + 形式化证明） |
| 编译器可信度 | 依赖 rustc 正确（无法证明） | Referee 可被 Coq 机器证明健全 |
| 隐式行为 | Drop trait、panic unwinding、async 状态机 | 零隐式行为（所见即所得） |
| WCET 分析 | 需要外部工具（如 AbsInt aiT） | 内建 Gas Metering（R11） |
| 硬件化 | 不可能 | Referee 可映射为 FPGA 电路（R33.6） |
| 认证成本 | 极高（需审计整个 rustc） | 极低（只需审计 2500 行 + 验证 Coq 证明） |

---

## 一句话定位

> **在/航空/医疗场景下，SA 不是替代 Ada 或 C 让人类手写的语言。它是一个"IR 防火墙"——无论上游用什么语言写代码，只要经过 SA 的 Referee，就能获得数学可证明的内存安全保证 + WCET 约束 + 类型不混淆（`--strict-tags`）。**
>
> 军方可以把那 2500 行 Referee 审查得底朝天，甚至烧进 FPGA 做硬件级验证。这是 Rust 永远做不到的。

---

# SA vs Ada/SPARK：合作关系，不是竞争关系

> Ada/SPARK 是/航空领域 40 年的黄金标准。SA 不是来替代它的——SA 是来**与它组成双层防线**的。

---

## 两种完全不同的安全哲学

| 维度 | Ada/SPARK | SA |
|---|---|---|
| **守护什么** | 业务逻辑正确性（范围不越界、合约满足、信息流安全） | 内存物理安全（无 UAF / Double-Free / 泄漏 / 类型混淆）+ WCET 有界 |
| **怎么证明** | 合约 + SMT 求解器（GNATprove） | 仿射掩码 O(1) 位运算 + Coq 定理证明（v0.6） |
| **验证器复杂度** | GNAT 编译器 ~数百万行 | Referee ≤ 2500 行 |
| **可审计性** | 困难（编译器太大） | 极易（2500 行可逐行审计 / 可烧 FPGA） |
| **人类友好度** | 高（为人类设计） | 低（为机器设计） |
| **LLM 友好度** | 低（语法冗长、上下文依赖重） | 极高（扁平、无嵌套、自包含） |

**核心区别**：Ada/SPARK 在**源码层**证明"程序做了正确的事"。SA 在 **IR 层**证明"程序不会做危险的事"。两者守护的是不同层次的安全。

---

## 全维度对比

| 维度 | Ada/SPARK | SA | 说明 |
|---|---|---|---|
| 类型系统 | 极强（范围类型 + 子类型 + 判别式） | 无（ptr + 原生数值 + 可选 tag） | Ada 在业务逻辑层碾压 |
| 内存安全 | 受限指针模型（无指针算术） | 仿射掩码 + InteriorPtr | SA 更底层更可证明 |
| WCET 分析 | 需外部工具（AbsInt aiT） | 内建 Gas Metering（R11） | SA 内建 |
| 形式化验证 | SPARK 合约 + GNATprove | Referee Coq 证明（R33） | 不同方法论，互补 |
| 并发安全 | Ravenscar Profile | 仿射掩码防竞态 | Ada 更成熟 |
| 运行时性能 | 中（范围检查有开销） | 最快（LLVM O3，零运行时检查） | SA 更快 |
| 二进制体积 | 中（~500KB+ 含 runtime） | 小（≤ 48KB wasm） | SA 更小 |
| 遗留 C 对接 | 需要 binding 层 | 气闸舱 `@ffi_wrapper` | SA 更干净 |
| 硬件化 | 不可能（编译器太复杂） | Referee 可烧 FPGA（R33.6） | SA 独有 |
| 认证成本 | 高（需审计 GNAT） | 低（只审计 2500 行） | SA 更低 |
| 生态成熟度 | 40 年积累 | 零（2026 新生） | Ada 碾压 |

---

## 最强组合：Ada/SPARK → SA → 机器码

SA 与 Ada/SPARK 不是竞争关系，是**合作关系**。两者组合形成双层防线：

```
┌─────────────────────────────────────────────────────────┐
│  Ada/SPARK 源码                                          │
│  - 人类写，带合约（Pre/Post）+ 范围类型                  │
│  - GNATprove 证明：业务逻辑正确                          │
│  - 保证：高度不越界、速度不溢出、状态机转移合法          │
└─────────────────────┬───────────────────────────────────┘
                      │ 确定性前端降级（Ada → SA）
                      ▼
┌─────────────────────────────────────────────────────────┐
│  SA 指令流（--strict-tags）                              │
│  - Referee 证明：内存物理安全                            │
│  - 保证：无 UAF、无 Double-Free、无泄漏、无类型混淆     │
│  - Gas Metering 保证：WCET 有界                          │
│  - 气闸舱保证：遗留 C 代码隔离                           │
└─────────────────────┬───────────────────────────────────┘
                      │ LLVM-C bitcode Emitter
                      ▼
┌─────────────────────────────────────────────────────────┐
│  原生机器码 / FPGA bitstream                             │
│  - LLVM O3 优化：零运行时开销                            │
│  - 或：Referee 硬件化为 FPGA 电路                        │
└─────────────────────────────────────────────────────────┘
```

**双层防线的安全保证**：

| 层 | 谁负责 | 证明什么 | 证明方法 |
|---|---|---|---|
| Ada/SPARK 层 | GNATprove | 业务逻辑正确（范围、合约、信息流） | SMT 求解器 |
| SA 层 | Referee | 内存物理安全 + WCET 有界 | O(1) 位掩码 + Coq 定理 |
| 双层组合 | 两者互补 | **即使 Ada 前端有 bug，SA 仍守住物理安全底线** | — |

---

## 为什么军方应该同时用两者？

### 单独用 Ada/SPARK 的风险
- GNAT 编译器本身有 bug 怎么办？（编译器是数百万行的复杂软件）
- 如果编译器错误地生成了 UAF 的机器码，Ada 的合约证明**救不了你**
- 军方无法完整审计 GNAT 编译器

### 单独用 SA 的风险
- SA 不证明业务逻辑（高度不越界、导弹不偏航）
- 内存安全 ≠ 程序正确

### 组合使用的优势
- Ada/SPARK 保证"程序做了正确的事"
- SA 保证"即使前端有 bug，物理层也不会崩溃"
- 军方只需审计 2500 行 Referee（而非整个 GNAT）
- Referee 可以烧进 FPGA 做**硬件级**内存安全守护

---

## 代码对比：同一个飞控函数

### Ada/SPARK 层（人类写）
```ada
type Altitude is range 0 .. 50_000;
type Velocity is digits 6 range -500.0 .. 500.0;

procedure Update_Altitude (
   Alt : in out Altitude;
   Vel : in Velocity;
   Dt  : in Duration)
with
   Pre  => Alt + Altitude(Vel * Float(Dt)) in Altitude'Range,
   Post => (if Vel >= 0.0 then Alt >= Alt'Old else Alt <= Alt'Old)
is
begin
   Alt := Alt + Altitude(Vel * Float(Dt));
end Update_Altitude;
-- GNATprove 证明：Alt 永远在 0..50_000 范围内
```

### SA 层（前端自动降级产出）
```
#tag FlightState
#def FS_alt = +0
#def FS_vel = +8

@update_altitude(state: &ptr tag FlightState, vel: f64, dt: f64):
L_ENTRY:
    alt = load state+FS_alt as f64
    delta = fmul vel, dt
    new_alt = fadd alt, delta
    store state+FS_alt, new_alt as f64
    return
// Referee 证明：state 不会 UAF / Double-Free / 泄漏
// Referee 证明：state 标签是 FlightState（不会被误当其它结构体）
// Gas 证明：此函数 WCET 有界（无循环）
```

**两层各守各的**：
- Ada 保证 `new_alt` 在 `0..50_000` 范围内
- SA 保证 `state` 指针在物理层安全

---

## SA 能为 Ada 生态带来什么？

| Ada 的痛点 | SA 的解法 |
|---|---|
| GNAT 编译器太大无法审计 | SA Referee 2500 行可完整审计 |
| 无法证明编译器产出的机器码正确 | SA 在 IR 层做第二道验证 |
| 对接遗留 C 代码困难 | SA 气闸舱物理隔离 |
| 无内建 WCET 分析 | SA Gas Metering 内建 |
| 无法硬件化验证器 | SA Referee 可烧 FPGA |
| 编译器认证成本极高 | SA 认证只需审计 2500 行 |

---

## 一句话定位

> **Ada/SPARK 是飞行员的安全带（防止操作错误）。SA 是飞机的结构强度（防止物理解体）。两者缺一不可。**
>
> SA 与 Ada 的关系是**合作**，不是竞争。Ada 守住业务逻辑的天空，SA 守住内存物理的大地。组合使用时，安全保证是乘法关系，不是加法。

---

# LLM 写 SA 时的两个痛点与工具链缓解

> 基于 LLM 自回归 Token 预测的底层机制，SA 对 LLM 来说是"母语级"的语言。但有两个真实痛点需要工具链补齐。

---

## 痛点 1：偏移量算术（LLM 不是计算器）

**问题**：LLM 在计算复杂结构体的字节偏移量时极易出错，尤其是混合类型对齐（如 `i32` 后跟 `f64` 需要 4 字节 padding）。

**示例**：
```
// LLM 容易算错的场景
#def Entity_id    = +0     // u32, 4 bytes
#def Entity_pos_x = +4     // ❌ 错！f64 需要 8 字节对齐，应该是 +8
```

**解法**：`sa layout` 工具（R7b）

```bash
sa layout --name Entity --fields "id:u32, pos_x:f64, pos_y:f64, hp:i32"
```

输出：
```
#def Entity_SIZE  = 32
#def Entity_id    = +0     // u32, 4 bytes
                           // 4 bytes padding
#def Entity_pos_x = +8    // f64, 8 bytes
#def Entity_pos_y = +16   // f64, 8 bytes
#def Entity_hp    = +24   // i32, 4 bytes
                           // 4 bytes tail padding
```

**LLM 工作流**：
1. LLM 决定需要一个结构体
2. 调用 `sa layout` 获取正确的 `#def` 字典
3. 把字典粘贴到源码顶部
4. 用常量名写代码（`load ptr+Entity_pos_x as f64`）
5. **永远不需要手算偏移量**

---

## 痛点 2：复杂分支路径漏释放 `!reg`

**问题**：当函数有 5+ 个分支路径和 3+ 个临时分配时，LLM 容易在某条罕见路径（如错误处理分支）忘记 `!reg`。

**示例**：
```
@process(data: &ptr) -> i32!:
L_ENTRY:
    buf1 = alloc 64
    buf2 = alloc 128
    res = call @step1(&buf1)
    ok = ? res
    br ok -> L_STEP2, L_ERR

L_ERR:
    !buf1
    // ❌ LLM 忘了 !buf2 → Trap: MemoryLeak
    return 1

L_STEP2:
    // ...
```

**解法**：SA 的设计精髓——**Referee 毫秒级抓住错误，LLM 根据 Trap 自修复**。

```json
{"trap":"MemoryLeak","line":8,"register":"buf2","message":"live registers remain at function exit"}
```

LLM 看到这个 JSON，瞬间知道在 `L_ERR` 分支补上 `!buf2`。

**额外缓解**：`libsa_scope` helper（R20.8）可以帮助前端/LLM 自动追踪当前作用域的活跃寄存器，在每个退出点自动生成释放指令。

---

## 为什么 SA 是 LLM 的"母语"？

| LLM 的弱点 | 传统语言的痛苦 | SA 的解法 |
|---|---|---|
| 注意力衰减（长距离括号匹配） | 深层 `{}` 嵌套 → 闭合错误 | 零嵌套（Label + jmp） |
| 不擅长全局推理 | 类型推导 + 生命周期图论 | 无类型系统，万物 `ptr` |
| 不是计算器 | 手算偏移量 | `sa layout` 工具 |
| 容易遗漏边缘路径 | 隐式 Drop 掩盖问题 | Referee 显式 Trap + JSON 反馈 |
| 自回归本质（逐 token 生成） | 需要回看上下文才能决定当前行 | 每行自包含，只需看前一行状态 |

**SA + LLM 的闭环**：
```
LLM 生成 SA 代码
    → 偏移量用 sa layout 保证正确
    → 忘记 !reg？Referee 毫秒级 Trap
    → JSON 错误精确到行号
    → LLM 补一行 !reg
    → 编译通过
    → 整个循环 < 1 秒
```

这比传统语言的"LLM 写代码 → 编译器报一堆人类都看不懂的错误 → LLM 彻底迷路"强一万倍。

---

## 附录 D：SA 零信任列式数据库（sa-db）常见问题

### D1. sa-db 是什么？为什么不用 SQLite / DuckDB？

**Q**：SA 已经有包管理了，为什么还要做数据库？

**A**：sa-db 不是"又一个数据库"，而是 SA 包管理在数据维度上的同构延伸。核心区别：

| 维度 | SQLite / DuckDB | sa-db |
|---|---|---|
| **查询语言** | SQL 字符串（运行时解析） | 预编译 SA-ASM 模块（编译期） |
| **权限模型** | 用户级 GRANT/REVOKE | 模块级 `grants` 声明（源码透明） |
| **版本控制** | 无 | SHA-256 锁版（源码 + 机器码） |
| **隔离** | 进程级沙箱 | CPU MMU 级物理隔离 |
| **并发** | 锁 / MVCC | `atomic_rmw_add` 单点 + 无锁读 |
| **架构** | 通用 | SA 专属（复用 Referee、`#def`、`grants`） |

**为什么选择 sa-db**：
- 零 SQL 字符串 = 零注入漏洞
- 预编译 = 编译期就能验证权限
- 与包管理同构 = 统一的信任模型
- 物理隔离 = 越权自动 SIGSEGV 熔断

### D2. 如何定义表 Schema？

**Q**：`.sadb-schema` 文件怎么写？

**A**：纯文本 `#def` 常量，继承 `docs/ebnf.md` 的语法：

```sa
// flash_sale.sadb-schema
#def MAX_ROWS = 1000000
#def COL_ID_STRIDE        8   // u64
#def COL_PRICE_STRIDE     4   // f32
#def COL_INVENTORY_STRIDE 4   // u32
#def COL_STATUS_STRIDE    1   // u8
#def TABLE_ROW_BYTES = 17     // 8 + 4 + 4 + 1
```

编译：`sa db init flash_sale.sadb-schema` → 生成 `flash_sale.sai`（纯文本副本）

**支持的列类型**：`i8..u64 / f32 / f64 / ptr / blob_handle`（无 `struct` / `array` / `string`）

### D3. 如何写查询模块？

**Q**：`.query.sa` 怎么写？能用 SQL 吗？

**A**：纯 SA-ASM，无 SQL。完整范式见 `docs/database.md` §7：

```sa
@import "flash_sale.sadb-schema"

@query_heavy_discount(
    &col_id: ptr,
    &col_price: ptr,
    &col_inventory: ptr,
    len: u64,
    &result_buf: ptr
) -> u64:
    grants [db_read:flash_sale, db_alloc_blob:result_arena]

L_ENTRY:
    idx = 0
    res_idx = 0
    jmp L_COND

L_COND:
    cond = ult idx, len
    br cond -> L_BODY, L_EXIT

L_BODY:
    // 读取库存，检查是否 < 100
    offset_inv = mul idx, COL_INVENTORY_STRIDE
    inv = load col_inventory+offset_inv as u32
    is_low = ult inv, 100
    br is_low -> L_CHECK_PRICE, L_NEXT
    
L_CHECK_PRICE:
    !is_low
    // 读取价格，检查是否 > 1000
    offset_price = mul idx, COL_PRICE_STRIDE
    price = load col_price+offset_price as f32
    is_expensive = fcmp_gt price, 1000.0
    br is_expensive -> L_MATCH, L_NEXT
    
L_MATCH:
    !is_expensive
    // 写入结果
    offset_res = mul res_idx, 8
    store result_buf+offset_res, idx as u64
    res_idx = add res_idx, 1
    !offset_res

L_NEXT:
    !is_expensive
    !is_low
    !offset_inv
    !offset_price
    idx = add idx, 1
    !cond
    jmp L_COND

L_EXIT:
    !cond
    !idx
    !col_id
    !col_price
    !col_inventory
    !len
    !result_buf
    return res_idx
```

**关键点**：
- 无 `if/else/while/for/{}`，仅 `L_LABEL:` + `jmp/br`
- 每个寄存器显式 `!` 释放（Referee 强制）
- `grants` 声明权限白名单（编译期校验）

### D4. 权限 X 光扫描是什么？

**Q**：`grants [db_read:flash_sale, db_write:logs]` 怎么工作？

**A**：Referee 在注册查询模块时执行 X 光扫描：

1. **遍历指令流**：扫描所有 `load` / `store` / `atomic_rmw_*` 指令
2. **权限校验**：
   - `load <col_base>+offset` → 检查 `db_read:flash_sale` 白名单
   - `store <col_base>+offset` → 检查 `db_write:logs` 白名单
   - `atomic_rmw_add <cursor>+0` → 检查 `db_atomic_cursor:logs`
3. **违规处理**：返回 `Trap: DbCapabilityEscalation`，附源码位置

**例子**：查询模块声明 `grants [db_read:flash_sale]`，但代码里有 `store col_logs+offset, ...`，编译直接砸穿报错。

### D5. 如何执行查询？

**Q**：怎么调用查询模块？

**A**：两种方式：

**方式 1：CLI**
```bash
sa db register heavy_users.query.sa
# 输出：Hash: a1b2c3d4e5f6...

sa db exec a1b2c3d4e5f6 --params params.bin
```

**方式 2：代码内**
```sa
@main() -> i32:
L_ENTRY:
    // 注入列基址、参数，调用查询模块
    result = call @exec_qmod(a1b2c3d4e5f6, args)
    !args
    return result
```

### D6. 越权写入会怎样？

**Q**：如果查询模块尝试越权修改只读列，会发生什么？

**A**：三层防线：

1. **编译期**：Referee X 光扫描检查权限白名单 → `Trap: DbCapabilityEscalation`
2. **运行时**：mmap 标记为 `PROT_READ`（只读） → CPU 拒绝写入
3. **硬件**：CPU 触发 SIGSEGV 信号 → 宿主进程捕获 → `Trap: DbMemoryGuardViolation` → 进程终止

**没有逃脱的可能**。

### D7. Blob Arena 是什么？

**Q**：变长文本（评价、聊天记录）怎么存储？

**A**：独立的 Blob Arena（Bump Allocator）：

```
<table>.blob.0.bin    // 第 0 个 Blob 段（256 MB mmap）
<table>.blob.1.bin    // 第 1 个 Blob 段
```

**blob_handle 位布局**：
```
blob_handle = u64 = (seg_id:24 << 40) | offset:40

seg_id:  段号（0–16777215）
offset:  段内偏移（0–1099511627775）
```

**特点**：
- 纯追加分配（无碎片）
- 删除标记墓碑（1 字节标志位）
- 段死亡比例 ≥ 50% 时整段重写
- 整段 mmap 视为单个 `alloc`，单次 `!arena` 释放

**为什么不用 Free-List**：Free-List 需要维护空闲链表，破坏"显式所有权释放"的语义。

### D8. 并发模型是什么？

**Q**：多个 Insert 同时写入，会不会冲突？

**A**：无锁并发设计：

**写入串行化点**：唯一的 `atomic_rmw_add global_len, 1`
- 所有 Insert 竞争这个原子操作
- 每个 Insert 拿到唯一的行号
- 然后各自计算偏移、写入数据（无锁）

**读无锁**：所有查询模块拿到 snapshot epoch 的 mmap 只读视图
- 查询开始时记录当前 epoch
- 数据库注入该 epoch 的列基址
- 查询在只读视图上执行，无需加锁
- 同时进行的 Insert 写入新行，不影响查询

**跨行事务**：可选乐观锁
- 每行 8 字节 `version` 列
- Update 时用 `cmpxchg` 尝试原子更新版本号
- 失败返回 `Trap: DbConcurrencyConflict`

**为什么不用 MVCC**：
- 违反 SoA 顺序写（版本链破坏列的连续性）
- 引入 GC（与"显式所有权"冲突）
- 与 Bump Arena 冲突（无法支持版本链）

### D9. 冷热分层怎么工作？

**Q**：数据怎么自动从 RAM 降到 S3？

**A**：三层存储：

| 温度 | 时间范围 | 存储 | 访问方式 |
|---|---|---|---|
| **热** | 最近 7 天 | RAM（MemTable + 最新段） | 直接内存访问 |
| **温** | 7 天 – 1 月 | NVMe（mmap） | 零拷贝 mmap 映射 |
| **冷** | 1 年+ | S3（Zstd 压缩） | 按需解压（体积压至 10–15%） |

**分层策略**：后台线程定期扫描段的 mtime，自动降温。

**压缩**：Zstd 字典压缩，体积可压至原大小 10–15%。

### D10. 为什么不用 WAL？

**Q**：没有 WAL，崩溃恢复怎么保证一致性？

**A**：sa-db 采用等价方案：

1. **快照 epoch**：每个 MemTable 刷盘时记录全局 epoch 号
2. **不可变段**：段一旦落盘，物理上不可改
3. **原子游标**：`global_len` 用 `atomic_rmw_add` 自增，保证一致性
4. **恢复**：重启时扫描 `.meta` 文件，重建 MemTable 状态

**为什么不用 WAL**：与"零隐式状态"哲学冲突。WAL 是隐式的后台日志，违反 SA 的"所有状态显式可见"原则。

### D11. 与包管理的关系？

**Q**：表 schema 和查询模块怎么分发？需要 `sadb.mod` 吗？

**A**：复用 `sa.mod`，无需单独 `sadb.mod`：

```
// sa.mod
require_db_table github.com/x/y @v1.0 sha256:... grants [db_read:tbl_a]
require_db_query github.com/x/y @v1.0 sha256:... grants [db_read:tbl_a, db_write:tbl_b]
```

**同构关系**：
- **身份**：URL（`github.com/x/y`）
- **版本锁定**：SHA-256（源码哈希）
- **权限声明**：`grants` 白名单
- **源码透明**：纯文本 `.sadb-schema` + `.query.sa`
- **零权限默认**：缺省 `grants []`

### D12. 性能目标是多少？

**Q**：sa-db 能跑多快？

**A**：性能基线（单线程）：

| 操作 | 目标 |
|---|---|
| Insert 吞吐 | ≥ 1M rows/sec |
| 1 亿行列扫描 | ≤ 200 ms（AVX-512 启用） |
| Query 延迟 | ≤ 10 ms（p99） |
| 抢购场景 | 1KW TPS 扣减（双 11 demo） |

**为什么这么快**：
- SoA 列式 + 顺序写 = 缓存友好
- 预编译查询 = 无解析开销
- 无锁并发 = 无争用
- 物理隔离 = CPU 直接执行

---

**更多信息**：见 `docs/database.md`（完整设计文档）、`requirements.md` R34（需求）、`design.md` §5（架构）、`tasks.md` v0.6（实现计划）。

---

## 架构与生态边界类

### Q: 为什么 `sa_std` 只有 JSON，不支持 YAML/XML 等其他序列化格式？

**A**: 为了保证标准库的极致精简和零 C 库污染。

原因：
- SA 缺乏高级类型系统，处理动态树状结构（如 JSON/YAML）需要 FFI 桥接到底层。
- Zig 标准库内置了极度优秀的 `std.json`，可以实现零依赖的 JSON 极速流式解析。
- 而 YAML、XML 等格式如果放入核心，则必须在编译期静态链接 `libyaml`、`expat` 等臃肿的 C 库。
- 因此，JSON 作为现代 Web 血液被唯一内置，而 YAML/XML/TOML 被明确剥离为外围生态中的 Package/Plugin，供用户按需引入。

### Q: Plugin (插件) 和 Package (包) 有什么区别？

**A**: 它们运作在完全不同的维度。

- **Plugin (插件，如 `sa_plugin_deno` / `sa_plugin_http_client` / `sa_plugin_pkg`)**：用于扩展 **SA 宿主与 native capability**。它们是独立工程，交付 `sap.json + .so + .sa + .sai + .sal`，既可提供 CLI/Agent skills，也可通过 `@extern` 给 SA 业务代码调用。
- **Package (包，如第三方 `libyaml`)**：用于扩展 **用户编写的业务代码**。它们在运行期/展开期通过 `sa fetch` 拉取，供业务逻辑 `@import` 使用。

插件必须维护公开 ABI 契约：

- `sap.json`：插件工程清单，声明 artifact、接口文件、skills、permissions、ABI 和插件依赖。
- `.so`：实际导出的 C-ABI 符号。
- `.sai`：SA 编译期看到的 `@extern` 签名。
- `.sal`：宏、布局、slot 装配和 facade。
- smoke：检查 `.sai` 中每个符号都存在于 `.so`。

如果插件目标是替代 Deno/Bun 这类 runtime，它不应 shell out 到被替代 runtime，而应逐步实现 native replacement surface，并维护 `API_COVERAGE.md` 标记 `implemented` / `planned_native` / `stub_unsupported` / `type_only`。

### Q: SA 目前有哪些文件后缀和清单？

**A**: 当前应固定为五类入口。

| 文件 | 用途 |
| --- | --- |
| `.sa` | SA-ASM 文本源码，实现函数、宏调用和可验证指令（走 Flattener 路径）。 |
| `.sab` | SA 二进制指令包，结构化指令数据（走 SAB Decoder 路径，跳过 Flattener）。 |
| `.sai` | SA Interface，声明 `@extern` 等外部 ABI。 |
| `.sal` | SA Layout，声明布局常量、结构偏移、slot 装配和薄宏 facade。 |
| `sa.mod` | SA Package manifest，管理普通源码包依赖、hash、permissions 和插件需求。 |
| `sap.json` | SA Plugin manifest，管理 native 插件 artifact、接口文件、skills、permissions、ABI 和插件依赖。 |

### Q: 为什么 `sci` 编译器要在输出里提供 `compile_tokens` 和 `instruction_count`？

**A**: 这是构建 "Agent-First Toolchain" 的核心。

原因：
- SA 的目标用户不仅仅是人类，更是 LLM Agent。
- 输出精确的 `compile_tokens` (展开消耗) 和 `instruction_count` (生成的物理指令数) 提供了一个完美的量化评价标准。
- 这使得 Agent 在编写代码时，可以把指令数当作 "损失函数 (Loss Function)"，通过多轮自我博弈 (Self-Play) 写出消耗最低、性能最极致的汇编代码。

### Q: SA 没有泛型和复杂的 Trait，怎么重构 Bevy/ECS 这种高度抽象的框架？

**A**: 采用 **“逻辑降级”** 与 **“工具驱动生成”** 策略。

核心思路：
1. ** smrustc 前端预计算**：不要让 SA 在编译期去“猜”偏移量。上游编译器（如 smrustc）或代码生成工具直接计算好组件在 Arena 中的物理偏移。
2. **文本宏作为代码脚手架**：利用 SA 的 `[MACRO]` 进行批量函数展开。虽然 SA 宏是纯文本的，但配合 `sa layout` 生成的 `#def` 常量，可以生成 100% 静态、零推导、极速编译的代码。
3. **牺牲“人类易读性”，换取“极致性能”**：Bevy 在 Rust 中依赖类型系统做借用冲突检查（极其缓慢）。在 SA 中，我们通过宏直接发射“已经算对”的位掩码掩码。Referee 仅做物理一致性检查。
4. **Variadic 降级**：目前变长参数需通过上游工具生成重复的 `EXPAND` 行。未来计划引入极简变长宏支持，进一步简化生成端压力。

结论：SA 的设计初衷不是在宏里重建 Lisp，而是作为一段**已验证机器码的文本描述符**。

---

## 宏驱动高级特性类 (Macro-Driven Features)

### Q: 既然不扩展 ISA，SA-ASM 怎么实现类似 Rust 的高级特性（如动态分发、枚举、RAII）？

**A**: 通过**纯宏（`[MACRO]`）+ 静态校验强化**，确立了“Zero-ISA 扩展”的演进路线。

原因：
- **Zero-ISA 原则**：增加 `call_indirect` 或原生 `enum` 会破坏底层虚拟机和 LLVM 后端的一一对应。
- **解法 1（动态分发）**：针对缺乏函数指针的问题，通过宏 `[MACRO] DISPATCH` 生成**去功能化 (Defunctionalization)** 的静态路由树 (`eq` + `br` 链)。以 O(log N) 的极低开销模拟 `dyn Trait`，且便于 Referee 进行完整的所有权追踪。
- **解法 2（安全枚举与模式匹配）**：通过标准宏 `[MACRO] MATCH_RESULT` 自动对内存 Layout 进行安全解包和**穷尽性匹配 (Exhaustive Match)**，向开发者隐藏易错的裸指针偏移计算，防止内存安全漏洞。
- **解法 3（细粒度借用）**：针对结构体整块锁死的痛点，强化 `referee.zig` 对 `ptr_add` 的识别。让编译器认识到 `ptr_add obj, 4` 和 `ptr_add obj, 8` 是独立互不干涉的，实现**字段级借用 (Disjoint Field Borrows)**。
- **解法 4（RAII 自动清理）**：通过规范化的 `[MACRO] DROP_AND_RETURN` 宏，把资源清理 `!` 与 `return` 强制捆绑。不引入运行时的 `defer`，而是通过编译期约束防止由于提前返回导致的内存或文件描述符泄漏。
- **解法 5（跨线程安全边界）**：针对并发通信场景，在 `verifier.zig` 层面增加对 Capability 的**静态多线程逃逸校验**。提供类似 Rust `Send / Sync` 的机制，保障跨核数据投递不发生 Data Race。
