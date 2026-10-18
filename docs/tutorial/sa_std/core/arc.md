# Arc (Atomic Reference Counting)

`Arc` 提供了线程安全的共享所有权。当多个线程需要读取同一个堆上的数据时，`Arc` 可以保证数据存活直到最后一个使用者释放。

SA 的 `Arc` 包含底层溢出检查保护（强、弱引用计数防止下溢和上溢）。

## 导入
```sa
@import "sa_std/core/arc.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序演示了如何初始化 `Arc`、在分支/克隆中复制强引用计数、安全读取数据，最后在不产生泄露的前提下完整递减释放整个堆结构：

```sa
@import "sa_std/core/arc.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化一个新的 Arc，将数值 42 堆分配包装
    EXPAND ARC_NEW main_arc, 42

    // 2. 将强引用计数增加 1 (在多线程派发或变量传递时常用)
    EXPAND ARC_CLONE main_arc

    // 3. 读取 Arc 数据值进行验证
    EXPAND ARC_GET original_val, main_arc
    
    // 4. 尝试获取其独占的可变指针进行就地修改。
    // 因为当前强引用计数为 2 (我们执行过 CLONE)，此修改操作预计必定失败
    EXPAND ARC_GET_MUT mut_ok, mut_ptr, main_arc
    br mut_ok -> L_SHOULD_NOT_HAPPEN, L_EXPECTED_FAIL

L_EXPECTED_FAIL:
    // 释放失败返回的相关资源
    !mut_ok
    !mut_ptr
    
    // 5. 递减一个强引用，恢复到只有 1 个强引用的独占状态
    EXPAND ARC_DECREMENT_STRONG_COUNT main_arc
    
    // 6. 再次尝试获取可变指针进行就地修改
    EXPAND ARC_GET_MUT mut_ok_2, mut_ptr_2, main_arc
    br mut_ok_2 -> L_MUT_WRITE_OK, L_MUT_WRITE_FAIL

L_MUT_WRITE_OK:
    // 成功独占修改，写入新值 100
    store mut_ptr_2+0, 100 as u64
    !mut_ok_2
    !mut_ptr_2
    
    // 7. 读取新值并校验
    EXPAND ARC_GET updated_val, main_arc
    
    // 8. 彻底销毁这唯一的强引用，释放 ArcBox 底层内存
    EXPAND ARC_DECREMENT_STRONG_COUNT main_arc

    !original_val
    !updated_val
    return 0

L_MUT_WRITE_FAIL:
    !mut_ok_2
    !mut_ptr_2
    !original_val
    EXPAND ARC_DECREMENT_STRONG_COUNT main_arc
    return 1

L_SHOULD_NOT_HAPPEN:
    !mut_ok
    !mut_ptr
    !original_val
    EXPAND ARC_DECREMENT_STRONG_COUNT main_arc
    EXPAND ARC_DECREMENT_STRONG_COUNT main_arc
    return 99
```

## 核心 API 索引说明

### `ARC_NEW %out_arc, %value`
在堆上分配 `ArcBox` 存储元数据及具体数据，初始强引用和弱引用计数为 `1`。

### `ARC_CLONE %arc_reg`
以原子操作增加该 Arc 实例的强引用计数，检测到 `u64::MAX` 溢出时会直接 `panic(1501)`。

### `ARC_GET %out_value, %arc_reg`
以只读方式，获取 Arc 内部保存的 `u64` 数据字。

### `ARC_DECREMENT_STRONG_COUNT %arc_reg`
以原子操作递减强引用。若减后计数为 0，则执行底层的内存垃圾回收和释放过程。

### `ARC_GET_MUT %out_ok, %out_ptr, %arc_reg`
若满足强引用为 1 且弱引用为 1，则 `%out_ok` 返回 `1`，`%out_ptr` 为指向内部数据的可变裸指针；否则 `%out_ok` 为 `0`。

### `ARC_TRY_UNWRAP %out_ok, %out_value, %arc_reg`
若强引用计数唯一 (为 1)，直接析构包装结构，把内部实际的值输出至 `%out_value` 并将 `%out_ok` 设为 `1`。否则，不改变计数，`%out_ok` 为 `0`。
