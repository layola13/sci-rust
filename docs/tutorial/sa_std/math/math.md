# Math & Hash (底层数学与散列)

提供了高级数学计算指令的统一入口与数据散列哈希（Hash）能力。

## 导入
```sa
@import "sa_std/math.sars"
@import "sa_std/hash.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何获取两个数值间的最大与最小值，以及对输入内存切片进行散列运算生成唯一哈希指纹的过程：

```sa
@import "sa_std/math.sars"
@import "sa_std/hash.sars"
@import "sa_std/core/slice.sars"

@main() -> i32:
L_ENTRY:
    // 1. 获取 20 和 90 之间的最大值 (预期 max_val=90)
    EXPAND MATH_MAX_U64 max_val, 20, 90

    // 2. 获取 20 和 90 之间的最小值 (预期 min_val=20)
    EXPAND MATH_MIN_U64 min_val, 20, 90

    // 3. 准备一段需要哈希的数据
    buf = stack_alloc 16
    store buf+0, 1111 as u64
    store buf+8, 2222 as u64
    EXPAND SLICE_NEW data_slice, buf, 2

    // 4. 对切片数据进行散列运算，获得唯一的 u64 散列值
    EXPAND HASH_SLICE hash_val, data_slice
    
    // 5. 对单一 U64 整数进行极速散列运算
    EXPAND HASH_U64 int_hash_val, 999
    
    !int_hash_val
    !hash_val
    !data_slice
    !min_val
    !max_val
    return 0
```

## 核心 API 索引说明

### `MATH_MIN_U64 %out_res, %a, %b`
将较小的一个数值输出至 `%out_res`。

### `MATH_MAX_U64 %out_res, %a, %b`
将较大的一个数值输出至 `%out_res`。

### `HASH_U64 %out_hash, %value`
根据内建散列算法对 %value 进行位打乱混淆，提供极速随机散列输出。

### `HASH_SLICE %out_hash, %slice_reg`
为整段内存块视图（由 `%slice_reg` 指定的首指针和长度）执行内容一致性哈希计算，常见于 HashMap 查找定位。
