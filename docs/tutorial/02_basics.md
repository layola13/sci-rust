# 02. Hello SA: 基础语法与指令

在这一章，我们将编写第一个 SA 程序，并理解它的基本结构。

## 你的第一个 SA 程序
创建一个名为 `hello.sa` 的文件，输入以下内容：

```sa
@main() -> i32:
L_ENTRY:
    x = add 0, 10
    y = add 0, 20
    sum = add x, y
    !x
    !y
    return sum
```

## 顶级声明 (Top-level Declarations)

一个完整的 SA 文件不仅包含指令，还包含控制全局行为的顶级声明。

### 1. 模块导入 (`@import`)
SA 使用 `@import` 引入其他文件的内容（包括宏、常量和函数声明）。

```sa
@import "sa_std/io.sars"
@import "../my_lib.sars"
```
- **路径**：支持相对路径和标准库路径。
- **作用**：被导入的文件中的所有 `@export` 函数和宏将在当前文件可用。

### 2. 常量定义 (`@const`)
用于定义全局不可变的原始数据，通常用于字符串或字节数组。

```sa
@const GREETING = utf8:"Hello, SA!"
@const MAGIC_BYTES = bytes:[0xDE, 0xAD, 0xBE, 0xEF]
```

### 3. 外部函数声明 (`@extern`)
当你需要调用由运行时（如 Zig 或 C）提供的函数时，使用 `@extern`。这告诉编译器该函数的符号将在链接阶段解决。

```sa
@extern sa_std_println(&msg: ptr, len: u64) -> i32!
```
- **注意**：返回类型末尾的 `!` 表示 fallible 返回，例如 `i32!` 或 `^ptr!`。

---

## 核心概念

### 1. 虚拟寄存器 (Virtual Registers)
SA 不使用 `eax` 或 `rax` 这种物理寄存器名，而是使用有意义的变量名（如 `x`, `sum`）。
- **静态单赋值 (SSA)**：在一个逻辑块内，一个名称通常只被赋值一次。
- **类型推导**：SA 会根据赋值语句自动推导类型（如 `i32`, `u64`, `ptr`）。

### 2. 指令与底层宏 (Instructions & Macros)
SA 的指令采用 `结果 = 指令 操纵数` 的形式。常用指令包括：
- `add`, `sub`, `mul`, `sdiv`, `udiv`：算术运算。
- 考虑到安全性，强烈推荐使用带溢出检查的宏：`NUM_U64_CHECKED_ADD`, `NUM_U64_CHECKED_MUL`。如果产生溢出将通过分支跳转到错误处理块。
- `and`, `or`, `xor`：逻辑运算。
- `eq`, `ne`, `slt`, `sgt`, `ult`, `ugt`：比较运算。

### 3. 销毁指令 (`!`)
这是 SA 最独特的符号。由于 SA 强制执行线性所有权，每一个被创建的寄存器都必须被**消费**（作为返回、作为参数传走）或被**销毁**（使用 `!`）。
- 如果你忘记销毁一个未使用的寄存器，编译器（Referee）会报错，从而防止内存泄漏。

## 编译并运行
使用 `sa run` 命令直接执行：

```bash
sa run hello.sa
echo $?  # 输出应该是 30
```

## 练习
1. 修改程序，计算 `(10 + 5) * 2`。
2. 尝试删掉 `!x` 这一行，看看编译器会给出什么错误信息。
