# Char & Ascii (字符处理)

提供了针对单个 ASCII 字符进行分类判定与转码的快速宏工具。

## 导入
```sa
@import "sa_std/char.sars"
@import "sa_std/ascii.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何对一个字符进行大小写判断、数字字符判定，并将其强转为对应小写的过程：

```sa
@import "sa_std/ascii.sars"

@main() -> i32:
L_ENTRY:
    // 1. 定义字符 'G' 的 ASCII 码：71
    char_g = add 0, 71

    // 2. 验证是否为大写字母 (预期 is_upper=1)
    EXPAND ASCII_IS_UPPER is_upper, char_g
    br is_upper -> L_UPPER_OK, L_FAIL

L_UPPER_OK:
    !is_upper

    // 3. 将大写 'G' 转换为小写 'g' (ASCII 码应当为 103)
    EXPAND ASCII_TO_LOWER lower_g, char_g
    
    // 4. 验证其是否变成了小写 (预期 is_lower=1)
    EXPAND ASCII_IS_LOWER is_lower, lower_g
    br is_lower -> L_LOWER_OK, L_FAIL_LOWER

L_LOWER_OK:
    !is_lower
    !lower_g

    // 5. 校验字符 '9' (ASCII 码 57) 是否是数字
    EXPAND ASCII_IS_DIGIT is_digit, 57
    br is_digit -> L_DIGIT_OK, L_FAIL_DIGIT

L_DIGIT_OK:
    !is_digit
    !char_g
    return 0

L_FAIL_DIGIT:
    !is_digit
    !char_g
    return 3

L_FAIL_LOWER:
    !lower_g
    !char_g
    return 2

L_FAIL:
    !is_upper
    !char_g
    return 1
```

## 核心 API 索引说明

### `ASCII_IS_LOWER %out_bool, %char_val`
若输入的 `%char_val` 对应 ASCII 码在 `a`~`z` (97~122) 范围内，则 `%out_bool` 输出为 `1`。

### `ASCII_IS_UPPER %out_bool, %char_val`
若输入的 `%char_val` 对应 ASCII 码在 `A`~`Z` (65~90) 范围内，则 `%out_bool` 输出为 `1`。

### `ASCII_IS_DIGIT %out_bool, %char_val`
判断是否是 `0`~`9` (48~57) 数字字符。

### `ASCII_TO_LOWER %out_char, %char_val`
如果输入的是大写 ASCII 码，转换并输出为对应的 ASCII 小写值；若不是大写字母，直接输出原值。
