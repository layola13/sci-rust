# Option 与 Result

用于表达一个结果的存在与否 (`Option`)，以及可能发生失败或成功的返回状态 (`Result`)。

## 导入
```sa
@import "sa_std/core/option.sars"
@import "sa_std/core/result.sars"
```

## 核心宏与完整用法示例

### Option 分支判断示例

```sa
@import "sa_std/core/option.sars"

@main() -> i32:
L_ENTRY:
    // 假设某操作返回了一个布尔标志，我们将其模拟为一个状态变量
    // 在 SA 的扁平设计中，可直接基于宏判断是否具有值
    opt_val = add 0, 1 // 模拟 Some
    
    EXPAND OPTION_IS_SOME is_some, opt_val
    br is_some -> L_SOME, L_NONE

L_SOME:
    !is_some
    !opt_val
    return 0

L_NONE:
    !is_some
    !opt_val
    return 1
```

### Result 异常分支跳转示例

```sa
@import "sa_std/core/result.sars"

@main() -> i32:
L_ENTRY:
    // 模拟一个错误码返回（SA 标准库的成功为 0，错误非 0）
    status = add 0, 0 // 成功
    
    EXPAND RESULT_IS_OK is_ok, status
    br is_ok -> L_SUCCESS, L_ERROR

L_SUCCESS:
    !is_ok
    !status
    return 0

L_ERROR:
    !is_ok
    !status
    return 99
```

## 核心 API 索引说明

由于 SA 在内核实现层摒弃了臃肿的高级 ADT 联合体对象，因此这套判断宏能够极快地把值条件编译展开为 `br` 跳转。

### `OPTION_IS_SOME %out_bool, %opt_reg`
若 `%opt_reg` 不为零（表示持有有效载荷），将 `%out_bool` 设为 `1`。

### `OPTION_IS_NONE %out_bool, %opt_reg`
若 `%opt_reg` 为零，将 `%out_bool` 设为 `1`。

---

### `RESULT_IS_OK %out_bool, %res_reg`
如果输入状态码 `%res_reg` 等于 0 (`SA_STD_OK`)，则 `%out_bool` 为 `1`。

### `RESULT_IS_ERR %out_bool, %res_reg`
如果输入状态码 `%res_reg` 不等于 0，则 `%out_bool` 为 `1`。
