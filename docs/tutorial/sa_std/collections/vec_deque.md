# VecDeque (双端队列)

允许在队列的头部和尾部实现均摊 `O(1)` 时间复杂度插入与弹出。非常适合用来做循环缓冲区和广度优先遍历等对首尾高频操作有诉求的业务系统。

和 `Vec` 类似，由于涉及大量数学偏移与折叠缓冲计算，整个组件已经全面部署安全防卫计算边界来防止越界漏洞。

## 导入
```sa
@import "sa_std/vec_deque.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了新建双端队列、从首尾两侧交替推入和弹出数据，并在无数据时执行安全异常跳出的验证：

```sa
@import "sa_std/vec_deque.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化双端队列
    EXPAND VEC_DEQUE_NEW dq

    // 2. 从队尾压入数据 (容器，数值，字节大小)
    EXPAND VEC_DEQUE_PUSH_BACK dq, 99, 8
    
    // 3. 从队头压入数据
    EXPAND VEC_DEQUE_PUSH_FRONT dq, 11, 8

    // 当前队列实际状态： [11, 99]

    // 4. 从队头弹出一个数据，预期弹出刚从 front 压入的 11
    EXPAND VEC_DEQUE_TRY_POP_FRONT_U64 f_ok, f_val, dq
    br f_ok -> L_FRONT_OK, L_FAIL

L_FRONT_OK:
    // f_val == 11
    !f_val
    !f_ok
    
    // 5. 从队尾弹出一个数据，预期弹出之前从 back 压入的 99
    EXPAND VEC_DEQUE_TRY_POP_BACK_U64 b_ok, b_val, dq
    br b_ok -> L_BACK_OK, L_FAIL

L_BACK_OK:
    !b_val
    !b_ok
    
    // 6. 队列已空，此时再次尝试弹出会命中预期的空判断
    EXPAND VEC_DEQUE_TRY_POP_BACK_U64 b_ok2, b_val2, dq
    br b_ok2 -> L_FAIL, L_EXPECTED_EMPTY

L_EXPECTED_EMPTY:
    !b_val2
    !b_ok2
    
    // 7. 释放
    EXPAND VEC_DEQUE_FREE dq
    return 0

L_FAIL:
    // 不符合测试预期而跳至失败处理
    EXPAND VEC_DEQUE_FREE dq
    return 1
```

## 核心 API 索引说明

### `VEC_DEQUE_NEW %out_deque`
创建一个支持环形数组管理头部尾部的分配结构。

### `VEC_DEQUE_PUSH_BACK %deque_reg, %value, %elem_size`
向队尾（Ring buffer 后向）压入值。

### `VEC_DEQUE_PUSH_FRONT %deque_reg, %value, %elem_size`
向队首（Ring buffer 前向）压入值。

### `VEC_DEQUE_TRY_POP_BACK_U64 %out_ok, %out_value, %deque_reg`
若队列有元素，从队尾取出 `%out_value` 并将 `%out_ok` 置 `1`。

### `VEC_DEQUE_TRY_POP_FRONT_U64 %out_ok, %out_value, %deque_reg`
若队列有元素，从队首取出 `%out_value` 并将 `%out_ok` 置 `1`。

### `VEC_DEQUE_FREE %deque_reg`
销毁环状数据区及外壳内存。