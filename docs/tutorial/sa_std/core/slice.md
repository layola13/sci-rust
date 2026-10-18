# Slice (内存切片)

切片 (Slice) 代表对一段连续内存（如 `Vec` 内部缓存、静态数组）的一个只读/可读写视图。切片仅包含了起始指针和长度信息，并不拥有底层数据的所有权。

## 导入
```sa
@import "sa_std/core/slice.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序演示了如何为一块已分配的内存构建切片，并展示了在安全切片防护下的数据读取与修改（如果越界会被分支安全拦截）：

```sa
@import "sa_std/core/slice.sars"

@main() -> i32:
L_ENTRY:
    // 1. 在栈上申请一块内存，存放 3 个 U64 数据 (24 字节)
    buf = stack_alloc 24
    store buf+0, 100 as u64
    store buf+8, 200 as u64
    store buf+16, 300 as u64

    // 2. 建立包含这 3 个元素的 Slice 视图
    EXPAND SLICE_NEW view_slice, buf, 3

    // 3. 安全获取索引为 1 的元素 (应该成功)
    EXPAND SLICE_TRY_GET_U64 ok1, val1, view_slice, 1
    br ok1 -> L_GET_1_OK, L_FAIL

L_GET_1_OK:
    // 4. 安全获取索引为 5 的元素 (应该越界失败)
    EXPAND SLICE_TRY_GET_U64 ok2, val2, view_slice, 5
    br ok2 -> L_GET_5_OK, L_EXPECTED_OUT_OF_BOUNDS

L_EXPECTED_OUT_OF_BOUNDS:
    !ok2
    !val2
    
    // 5. 判定切片是否为空
    EXPAND SLICE_IS_EMPTY is_empty, view_slice
    
    !is_empty
    !val1
    !ok1
    !view_slice
    return 0

L_GET_5_OK:
    !ok2
    !val2
    !val1
    !ok1
    !view_slice
    return 99

L_FAIL:
    !ok1
    !val1
    !view_slice
    return 1
```

## 核心 API 索引说明

### `SLICE_NEW %slice_reg, %data_ptr, %length`
构造结构：存储起指针 `%data_ptr` 和长度 `%length` 至切片中。

### `SLICE_TRY_GET_U64 %out_ok, %out_value, %slice_reg, %index`
安全边界读。校验 `%index` $<$ 长度。成功则 `%out_ok` 设为 `1` 并通过首地址偏移取值；失败时 `%out_ok` 设为 `0`， `%out_value` 设为 `0`。

### `SLICE_TRY_GET_MUT_PTR_U64 %out_ok, %out_ptr, %slice_reg, %index`
安全边界获取可写裸指针。若在切片长度边界内，则 `%out_ptr` 为可修改的偏移指针，`%out_ok` 为 `1`。

### `SLICE_TRY_FIRST_U64 %out_ok, %out_value, %slice_reg`
提取切片首个值。等价于执行 `SLICE_TRY_GET_U64` 索引 `0`。

### `SLICE_TRY_LAST_U64 %out_ok, %out_value, %slice_reg`
提取切片尾部值。若切片长度为 0，则 `%out_ok` 为 `0`。

### `SLICE_IS_EMPTY %out_bool, %slice_reg`
提取 `%slice_reg` 里的长度，判断是否等于 `0` 并输出结果。
