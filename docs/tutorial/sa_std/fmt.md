# Fmt (格式化)

SA 运行时提供的对基本数据类型与自定义内存结构进行格式化的底层支持。相比于高级语言中的 `printf("%d")`，SA 使用显式寄存器配置的缓冲区写入或 `String` 扩增风格。

## 导入
```sa
@import "sa_std/fmt.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何将一个正整数和一个带有符号的负整数转换成动态字符串内容并最终输出：

```sa
@import "sa_std/fmt.sars"
@import "sa_std/string.sars"
@import "sa_std/io.sars"

@main() -> i32:
L_ENTRY:
    // 1. 新建动态字符串
    EXPAND STRING_NEW out_str

    // 2. 格式化无符号整型 4096 (写入 out_str)
    EXPAND FMT_U64_TO_STRING ok1, out_str, 4096
    br ok1 -> L_OK1, L_FAIL

L_OK1:
    !ok1
    
    // 3. 追加一个空格字符：ASCII 码 32
    EXPAND STRING_PUSH_CHAR out_str, 32

    // 4. 格式化带符号负整数 -777
    neg_num = sub 0, 777
    EXPAND FMT_I64_TO_STRING ok2, out_str, neg_num
    br ok2 -> L_OK2, L_FAIL

L_OK2:
    !ok2
    !neg_num

    // 5. 打印最终格式化拼装好的字符串
    EXPAND STRING_LEN out_len, out_str
    EXPAND VEC_AS_PTR inner_ptr, out_str
    EXPAND PRINTLN inner_ptr, out_len

    !inner_ptr
    !out_len
    EXPAND STRING_FREE out_str
    return 0

L_FAIL:
    EXPAND STRING_FREE out_str
    return 1
```

## 核心 API 索引说明

### `FMT_U64_TO_STRING %out_ok, %str_reg, %value`
将 64 位无符号长整型转化为对应的 ASCII 文本，拼装并追加至 `%str_reg` 关联的字符串尾端。

### `FMT_I64_TO_STRING %out_ok, %str_reg, %value`
同上，但可以安全解析带符号数值（若为负数会在缓冲区前置写入 `-`）。

### `FMT_F64_TO_STRING %out_ok, %str_reg, %value`
将 64 位双精度浮点数转化为对应的文本（在 `fmt.sa` 的对应高层依赖中实现）。如果传入了非数值或者溢出值，会自动写入 `NaN` 或 `Infinity`。
