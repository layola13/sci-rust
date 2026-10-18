# Num (安全算术宏)

使用原生 SA 指令（如 `add`, `mul`）直接运算，如果在业务上不受控有极高可能会导致硬件字长的不可逆溢出与截断（例如恶意负载构造引发的高额负数绕回骗开内存检测，造成致命 OOM 分配等）。

为此，SA 在 `sa_std/num.sa` 专门封装了具有运行时检测的条件判断宏。最新版本的编译器和标准库正是因为使用这套宏，极大地杜绝了内部的诸如“缓冲增长容量的溢出分配”类内核级安全漏洞。

**凡涉及业务计数、金融计算与大小估算，请务必将其视为防御性编程的核心支柱来使用。**

## 导入
```sa
@import "sa_std/num.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何执行一系列无符号整数加减乘运算，并通过分支机制去安全应对发生上溢（Overflow）或下溢（Underflow）的错误控制块流程：

```sa
@import "sa_std/num.sars"

@main() -> i32:
L_ENTRY:
    a = add 0, 10
    b = add 0, 20
    
    // 1. 安全加法：a + b (预期 ok=1)
    EXPAND NUM_U64_CHECKED_ADD add_ok, add_res, a, b
    br add_ok -> L_ADD_OK, L_FAIL

L_ADD_OK:
    // 2. 模拟一场严重超出 U64 上限的恶劣计算！
    evil_num = sub 0, 1 // 通过负数绕回生成 U64 MAX 伪造溢出
    
    // 3. 将原数字加上非法超大数字（这在原生 CPU add 必定会丢包）
    // 我们的检测宏能敏锐识别，并反馈为 ok=0 跳往错误分支
    EXPAND NUM_U64_CHECKED_ADD evil_ok, evil_res, add_res, evil_num
    br evil_ok -> L_FAIL, L_EXPECTED_OVERFLOW

L_EXPECTED_OVERFLOW:
    !evil_ok
    !evil_res
    
    // 4. 模拟一次引发硬件下溢的恶劣计算：尝试从 10 减去 20
    EXPAND NUM_U64_CHECKED_SUB sub_ok, sub_res, a, b
    br sub_ok -> L_FAIL, L_EXPECTED_UNDERFLOW

L_EXPECTED_UNDERFLOW:
    !sub_ok
    !sub_res
    !evil_num
    !add_ok
    !add_res
    !a
    !b
    return 0

L_FAIL:
    // 所有不符合上述严格数学预期的都会归结到这儿跳出错误
    return 1
```

## 核心 API 索引说明

这套宏的共同特点是带有 `%out_ok` 参数：如果发生溢出、下溢或者非法除 0 等安全错误，则返回 `0` 并且终止计算；成功计算的话返回 `1`。

### `NUM_U64_CHECKED_ADD %out_ok, %out_res, %lhs, %rhs`
无符号长整型安全加法。

### `NUM_U64_CHECKED_SUB %out_ok, %out_res, %lhs, %rhs`
无符号长整型安全减法，当减数大于被减数时防下溢并置 `%out_ok=0`。

### `NUM_U64_CHECKED_MUL %out_ok, %out_res, %lhs, %rhs`
无符号长整型安全乘法。

### `NUM_U64_CHECKED_DIV %out_ok, %out_res, %lhs, %rhs`
无符号长整型除法。提供被除数为 `0` （Division by Zero）的除零内核级拦截。