# Cmp & Sort (排序与比较)

内置在 SA 标准库中的集合排序算法及通用比较原语。它们在运行时实现了高效率的原地排序以及二分查找所需的基础构建。

## 导入
```sa
@import "sa_std/cmp.sars"
@import "sa_std/sort.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何对无符号长整型进行三路判定，并展示了对一块内存切片数据执行就地快速排序的过程：

```sa
@import "sa_std/cmp.sars"
@import "sa_std/sort.sars"
@import "sa_std/core/slice.sars"

@main() -> i32:
L_ENTRY:
    // 1. 三路比较 50 与 20 的大小
    EXPAND CMP_U64 cmp_res, 50, 20
    // cmp_res 预期为 1 (表示大于)
    !cmp_res

    // 2. 准备无序的栈数组进行原地排序测试
    arr = stack_alloc 24
    store arr+0, 99 as u64
    store arr+8, 11 as u64
    store arr+16, 55 as u64

    // 3. 构建切片视图
    EXPAND SLICE_NEW sort_slice, arr, 3

    // 4. 执行基于 O(N log N) 的混合快速堆排序操作
    EXPAND SORT_SLICE_U64 sort_slice
    
    // 5. 排序后验证首个元素是否为最小值 11
    EXPAND SLICE_TRY_GET_U64 ok, val, sort_slice, 0
    br ok -> L_GET_OK, L_FAIL

L_GET_OK:
    // val 必定为 11
    !val
    !ok
    !sort_slice
    return 0

L_FAIL:
    !ok
    !val
    !sort_slice
    return 1
```

## 核心 API 索引说明

### `CMP_U64 %out_res, %lhs, %rhs`
无符号数比较。
- 若 `%lhs` $<$ `%rhs`：输出 `%out_res = -1`。
- 若 `%lhs` $==$ `%rhs`：输出 `%out_res = 0`。
- 若 `%lhs` $>$ `%rhs`：输出 `%out_res = 1`。

### `SORT_SLICE_U64 %slice_reg`
对 `%slice_reg` 切片内的 U64 数组进行就地排序。底层基于零外部堆空间开销的原地交换实现，在大数据排序时极为轻量。
