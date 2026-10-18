# Vec (动态数组)

`Vec` 是 SA 应用程序中最常用的动态容器之一，功能对标 C++ 的 `std::vector`。

`Vec` 内部实现了均摊 `O(1)` 的基于两倍容量的扩容机制（有效消除线性追加时的性能恶化）。底层所有容量与字节相乘的计算均由安全的数学宏防卫（如 `NUM_U64_CHECKED_MUL`），发生溢出计算时将主动拒绝并触发 panic 阻断。

## 导入
```sa
@import "sa_std/vec.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何初始化数组，插入、读取、安全索引检查、尾部弹出数据以及最后的垃圾回收：

```sa
@import "sa_std/vec.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化一个新的数组
    EXPAND VEC_NEW my_vec

    // 2. 追加无符号整型数据 (参数: 数组, 数据, 元素大小)
    EXPAND VEC_PUSH my_vec, 100, 8
    EXPAND VEC_PUSH my_vec, 200, 8
    EXPAND VEC_PUSH_U64 my_vec, 300 // 针对 U64 的高效简化宏

    // 3. 获取长度与容量
    EXPAND VEC_LEN len, my_vec
    EXPAND VEC_CAPACITY cap, my_vec

    // 4. 尝试安全获取有效下标 1 处的元素 (结果预计 ok=1, val=200)
    EXPAND VEC_TRY_GET_U64 ok1, val1, my_vec, 1
    br ok1 -> L_GET_1_OK, L_FAIL

L_GET_1_OK:
    // 5. 尝试安全获取越界下标 99 处的元素 (结果预计 ok=0)
    EXPAND VEC_TRY_GET_U64 ok2, val2, my_vec, 99
    br ok2 -> L_GET_99_OK, L_EXPECTED_OOB

L_EXPECTED_OOB:
    !ok2
    !val2

    // 6. 安全读取第一个和最后一个元素
    EXPAND VEC_TRY_FIRST_U64 f_ok, first_val, my_vec
    EXPAND VEC_TRY_LAST_U64 l_ok, last_val, my_vec

    // 7. 安全弹出一个数据
    EXPAND VEC_TRY_POP_U64 pop_ok, popped_val, my_vec

    // 8. 检查是否为空
    EXPAND VEC_IS_EMPTY empty_flag, my_vec

    // 9. 清空容器 (重置 len=0, 但保留底层已分配内存的 capacity 空间)
    EXPAND VEC_CLEAR my_vec

    // 10. 销毁并释放整个容器
    EXPAND VEC_FREE my_vec

    !empty_flag
    !pop_ok
    !popped_val
    !l_ok
    !last_val
    !f_ok
    !first_val
    !ok1
    !val1
    !len
    !cap
    return 0

L_GET_99_OK:
    !ok2
    !val2
    !ok1
    !val1
    !len
    !cap
    EXPAND VEC_FREE my_vec
    return 99

L_FAIL:
    !ok1
    !val1
    !len
    !cap
    EXPAND VEC_FREE my_vec
    return 1
```

## 核心 API 索引说明与微型示例

### `VEC_NEW %out_vec`
在堆上建立一个新的 `Vec` 控制字头部，初始容量和长度为 `0`。

### `VEC_PUSH %vec_reg, %value, %elem_size`
向尾部压入 `%value`。在计算扩容大小期间会触发 `NUM_U64_CHECKED_MUL` 保护以防止溢出攻击。

### `VEC_PUSH_U64 %vec_reg, %value`
固定以 8 字节为大小压入 `%value` 的高层简化宏。

### `VEC_TRY_GET_U64 %out_ok, %out_value, %vec_reg, %index`
安全带界检索。若 `%index` $\ge$ 数组长度，`%out_ok` 返回 `0`。

### `VEC_TRY_FIRST_U64 %out_ok, %out_value, %vec_reg`
### `VEC_TRY_LAST_U64 %out_ok, %out_value, %vec_reg`
无越界恐慌地提取首/尾元素，提取失败则 `%out_ok = 0`。

### `VEC_TRY_POP_U64 %out_ok, %out_value, %vec_reg`
弹出尾部，数组长度递减。

### `VEC_LEN %out_len, %vec_reg`
提取数组控制块中记录的实际存入元素数量。

### `VEC_CAPACITY %out_cap, %vec_reg`
提取数组当前持有的最大底层容量。

### `VEC_CLEAR %vec_reg`
将控制块中的长度字段覆写为 `0`，不清空底层堆，保留复用空间。

### `VEC_FREE %vec_reg`
销毁容器：释放底层元素占用的内存，并最终归还数组自身的控制块堆地址。
