# SA (safe asm, 安全汇编) 语言入门指南

SA 是一门面向机器验证和 LLM 代码生成的线性所有权汇编语言。它保留汇编式的显式控制力，同时用 Referee 在编译期检查所有权、借用、释放和 FFI 边界。

本页只覆盖当前工具链已经支持的入门路径。SAX、Netx、插件化 HTTP 等主题属于后续设计或高级文档，不建议作为第一份可复制教程使用。

---

## 1. 安装与验证

本仓库的编译器用 Zig 构建。当前开发环境使用 Zig `0.14.1`。

```bash
zig version
zig build
```

构建完成后，可以直接使用仓库里的二进制：

```bash
./zig-out/bin/sa version
./zig-out/bin/sa --help
```

如果你已经通过安装脚本把 `sa` 加入了 `PATH`，也可以直接运行：

```bash
sa version
sa --help
```

当前 CLI 的常用命令包括：

```text
sa run <file.sa>
sa build <file.sa>
sa build-exe <file.sa>
sa build-obj <file.sa>
sa build-wasm <file.sa>
sa test <file.sa>
sa layout ...
sa bc2sa <file.bc>
```

---

## 2. 第一个程序

新建 `hello.sa`：

```sa
@import "sa_std/io/print.sai"

@const HELLO = utf8:"hello, sa\n"

@main() -> i32:
L_ENTRY:
    call @sa_print_bytes(&HELLO, 10)
    return 0
```

运行：

```bash
sa run hello.sa
```

构建本地可执行文件：

```bash
sa build-exe hello.sa -o hello
./hello
```

也可以构建对象文件或 WASM：

```bash
sa build-obj hello.sa -o hello.o
sa build-wasm hello.sa -o hello.wasm
```

注意当前 SA 函数头使用冒号结尾，不使用 `{}`：

```sa
@main() -> i32:
L_ENTRY:
    return 0
```

---

## 3. 五个所有权符号

Referee 的核心输入是五个符号。

`=` 绑定或分配：

```sa
p = alloc 8
```

`&` 借用，不转移所有权：

```sa
view = &p
!view
```

`!` 显式释放拥有的资源或结束借用：

```sa
!p
```

`^` 移动所有权，移动后原寄存器不可再用：

```sa
call @consume(^p)
```

`*` 逃逸为裸指针，只能在 `@ffi_wrapper` 内使用：

```sa
raw = *p
```

入门时最重要的规则是：分配出来的 `alloc`、未消费的临时寄存器、以及借用视图都要在返回前处理干净。否则 Referee 会报 `MemoryLeak`、`UseAfterMove`、`PhiStateConflict` 等错误。

---

## 4. 内存布局

SA 没有 `struct` 关键字。结构体布局用 `#def` 明确表示：

```sa
#def Point_SIZE = 8
#def Point_x = +0
#def Point_y = +4

@make_point(x: i32, y: i32) -> ^ptr:
L_ENTRY:
    p = alloc Point_SIZE
    store p+Point_x, x as i32
    store p+Point_y, y as i32
    !x
    !y
    return p
```

当布局变复杂时，优先使用 `sa layout` 生成偏移常量，避免手算：

```bash
sa layout --name Point --fields "x:i32, y:i32"
```

---

## 5. 扁平控制流

SA 没有 `if` / `while` / `for`。控制流只用标签、`br` 和 `jmp`。

分支示例：

```sa
@abs_i32(x: i32) -> i32:
L_ENTRY:
    is_non_negative = sge x, 0
    br is_non_negative -> L_POS, L_NEG

L_POS:
    !is_non_negative
    return x

L_NEG:
    ans = sub 0, x
    !is_non_negative
    return ans
```

循环通常用 `stack_alloc` 保存循环变量，避免在回边上重绑定同一个寄存器：

```sa
@count_to_ten() -> i32:
L_ENTRY:
    i_slot = stack_alloc 8
    store i_slot+0, 0 as u64
    jmp L_CHECK

L_CHECK:
    i = load i_slot+0 as u64
    keep_going = ult i, 10
    br keep_going -> L_BODY, L_DONE

L_BODY:
    next = add i, 1
    store i_slot+0, next as u64
    !next
    !i
    !keep_going
    jmp L_CHECK

L_DONE:
    !i
    !keep_going
    return 0
```

`stack_alloc` 这类栈上临时值会在函数结束时自然失效，不需要也不应该显式 `!` 释放。

`jump` 不是当前指令名；请使用 `jmp`。

---

## 6. 标准库宏

`sa_std` 由三类文件组成：

- `.sai`：外部 ABI 声明，例如 `@extern`。
- `.sal`：布局和常量，例如 `#def Vec_SIZE = 24`。
- `.sa`：SA 实现和 `[MACRO]` 宏。

当前宏调用写法是 `EXPAND NAME ...`，宏定义写法是 `[MACRO] ... [END_MACRO]`，不是 `@macro`。

Vec 示例：

```sa
@import "sa_std/vec.sars"

@main() -> i32:
L_ENTRY:
    EXPAND VEC_NEW vec
    EXPAND VEC_PUSH vec, 11, 8
    EXPAND VEC_PUSH vec, 22, 8
    EXPAND VEC_LEN len, vec
    ok = eq len, 2
    !len
    EXPAND VEC_FREE vec
    br ok -> L_OK, L_ERR

L_OK:
    !ok
    return 0

L_ERR:
    !ok
    return 1
```

打印宏示例：

```sa
@import "sa_std/io.sars"

@const MSG = utf8:"done"

@main() -> i32:
L_ENTRY:
    EXPAND PRINTLN MSG, 4
    return 0
```

---

## 7. 可失败返回与 `?`

返回类型后缀 `!` 表示 fallible 返回。`?` 会展开为“成功时取值，失败时早退”的控制流。

```sa
@ok() -> i32!:
L_ENTRY:
    return 7

@main() -> i32!:
L_ENTRY:
    res = call @ok()
    value = ? res
    !res
    return value
```

安全要点：如果 `?` 之前已经有活跃分配，早退路径也必须能清理它，否则会触发 `EarlyReturnLeak`。

---

## 8. FFI 气闸舱

裸指针逃逸、`assume_safe`、`assume_borrow` 只能出现在 `@ffi_wrapper` 中。普通函数里写 `raw = *box` 会触发 `IllegalUnsafeContext`，所以这类操作只应在专门的 FFI 包装层出现。本教程先不展开具体例子。

---

## 9. 下一步

建议按这个顺序继续读：

1. `docs/tutorial/02_basics.md`
2. `docs/tutorial/03_control_flow.md`
3. `docs/tutorial/04_ownership.md`
4. `docs/tutorial/06_std_library.md`
5. `docs/unit_test_framework.md`

网络、SAX、数据库和外部插件文档仍然有设计稿性质。阅读时请以当前源码和测试为准，尤其是 `sa_std/`、`tests/*.sa`、`tests/cli_smoke.zig`。
