# RefCell & Cell

用于提供“内部可变性”。在 SA 的线性所有权下，即使你持有不可变借用，也可以在运行期通过 `RefCell` 动态发起临时读写借用（由运行时借用计数保护），或者用 `Cell` 直接进行简单值覆盖。

## 导入
```sa
@import "sa_std/core/refcell.sars"
@import "sa_std/core/cell.sars"
```

## 核心宏与完整用法示例

### RefCell 运行时多重借用冲突校验示例

```sa
@import "sa_std/core/refcell.sars"

@main() -> i32:
L_ENTRY:
    // 1. 新建一个值为 88 的 RefCell 包装
    EXPAND REFCELL_NEW cell, 88

    // 2. 借用只读指针。如果此时有人在进行修改，将跳入 L_ERR_BORROW
    EXPAND REFCELL_BORROW ok1, r_ptr1, cell, L_ERR_BORROW
    
    // 3. 再次借用另一个只读指针 (允许多重只读借用)
    EXPAND REFCELL_BORROW ok2, r_ptr2, cell, L_ERR_BORROW

    // 读取并校验借用出的数据
    val1 = load r_ptr1+0 as u64
    val2 = load r_ptr2+0 as u64
    
    // 4. 清理只读借用，减少借用引用数
    !val1
    !val2
    !ok1
    !ok2
    !r_ptr1
    !r_ptr2

    // 5. 独占借用进行修改
    EXPAND REFCELL_BORROW_MUT mut_ok, w_ptr, cell, L_ERR_MUT
    store w_ptr+0, 99 as u64
    !mut_ok
    !w_ptr

    !cell
    return 0

L_ERR_BORROW:
    !cell
    return 1

L_ERR_MUT:
    !cell
    return 2
```

### Cell 简单直接赋值示例

```sa
@import "sa_std/core/cell.sars"

@main() -> i32:
L_ENTRY:
    // Cell 适合小的值复制操作
    EXPAND CELL_NEW val_cell, 10
    
    // 取值
    EXPAND CELL_GET v1, val_cell
    
    // 设值
    EXPAND CELL_SET val_cell, 20
    
    // 替换并返回老值
    EXPAND CELL_REPLACE old_v, val_cell, 30
    
    !v1
    !old_v
    !val_cell
    return 0
```

## 核心 API 索引说明

### `REFCELL_NEW %out_cell, %value`
分配 `RefCell`，初始借用状态为 `0` (无任何借用)。

### `REFCELL_BORROW %out_ok, %out_borrow, %cell_reg, %err_label`
不可变只读借用。只要内部借用状态 $\ge 0$ (没有可变写锁定)，即可借用成功且内部借用计数自增 1，否则跳转到 `%err_label` 并设 `%out_ok` 为 `0`。

### `REFCELL_BORROW_MUT %out_ok, %out_borrow, %cell_reg, %err_label`
可变写借用。只有内部无任何借用（借用状态为 `0`）才允许进行写锁定，会将状态置为 `-1`。若失败则跳转到 `%err_label`。

---

### `CELL_NEW %out_cell, %value`
创建无需引用计数跟踪的 `Cell` 对象。

### `CELL_GET %out_value, %cell_reg`
提取其内部当前最新的数值。

### `CELL_SET %cell_reg, %new_value`
向内部数据块直接覆盖写入新值。

### `CELL_REPLACE %out_old, %cell_reg, %new_value`
原子替换，写入新值 `%new_value` 并在 `%out_old` 中吐出原来的历史值。
