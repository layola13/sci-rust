# BinaryHeap (优先队列)

提供了一个基于动态二叉堆数据结构实现的优先队列。最大（或根据自定比较函数的最小）的元素总是被保证存放在堆顶，可以以 `O(log N)` 的极快时间复杂度进行拉取与出栈。

在堆结构的排序推入（`sift_up`）与弹出重组（`sift_down`）中，SA 标准库同样对其内部分页计算做足了防越界与重分配防溢出防护。

## 导入
```sa
@import "sa_std/binary_heap.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了通过优先队列对杂乱顺序的数字进行入堆，然后验证它是否依照“大根堆”规则进行弹出的正确性：

```sa
@import "sa_std/binary_heap.sars"

@main() -> i32:
L_ENTRY:
    // 1. 新建一个优先队列堆
    EXPAND BINARY_HEAP_NEW bh

    // 2. 依次压入无序的数据
    // 在推入时内部会自动完成 sift_up 操作，进行向上的堆结构平衡
    EXPAND BINARY_HEAP_PUSH bh, 100, 8
    EXPAND BINARY_HEAP_PUSH bh, 200, 8
    EXPAND BINARY_HEAP_PUSH bh, 50, 8

    // 3. 弹取优先级最大元素（预期是最大值：200）
    EXPAND BINARY_HEAP_TRY_POP_U64 ok1, val1, bh
    br ok1 -> L_POP1_OK, L_FAIL

L_POP1_OK:
    // val1 必定为 200
    !val1
    !ok1
    
    // 4. 第二次弹出（预期次大值：100）
    EXPAND BINARY_HEAP_TRY_POP_U64 ok2, val2, bh
    br ok2 -> L_POP2_OK, L_FAIL

L_POP2_OK:
    // val2 必定为 100
    !val2
    !ok2

    // 5. 释放释放整个堆结构内存
    EXPAND BINARY_HEAP_FREE bh
    return 0

L_FAIL:
    EXPAND BINARY_HEAP_FREE bh
    return 1
```

## 核心 API 索引说明

### `BINARY_HEAP_NEW %out_heap`
生成优先队列对象以及内部包裹的线性缓冲区结构。

### `BINARY_HEAP_PUSH %heap_reg, %value, %elem_size`
向堆内部推入数据，触发向上冒泡并根据数值（或函数）比较进行替换层级，将优先级较高的元素往顶端移。

### `BINARY_HEAP_TRY_POP_U64 %out_ok, %out_value, %heap_reg`
提取最优先元素（如果队列空返回 `%out_ok=0`）。提取走后，触发向下的 `sift_down` 调整，重修恢复内部的平衡二叉树特性。

### `BINARY_HEAP_FREE %heap_reg`
销毁优先队列持有的数组缓冲区和队列首地址。