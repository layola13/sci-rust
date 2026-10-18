# Box

`Box` 提供最直接的、唯一拥有的堆空间分配包装 (Heap Allocation)。当对象要在不同作用域移交、或占用栈空间过大时应当使用 Box。

## 导入
```sa
@import "sa_std/core/box.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何将数据推入堆分配的 Box，将其转移，并最终释放其底层堆空间：

```sa
@import "sa_std/core/box.sars"

@main() -> i32:
L_ENTRY:
    // 1. 在堆上分配一个 Box，包装数字 777
    EXPAND BOX_NEW my_box, 777

    // 2. 将 Box 转换为底层裸指针（Box 被消耗释放）
    EXPAND BOX_INTO_RAW raw_ptr, my_box
    
    // 3. 读取裸指针中的内容并做运算
    val = load raw_ptr+0 as u64
    new_val = add val, 3
    store raw_ptr+0, new_val as u64
    
    // 4. 将裸指针重新打包回 Box 进行生命周期接管
    EXPAND BOX_FROM_RAW restored_box, raw_ptr
    
    // 5. 销毁并释放整个 Box 堆内存
    EXPAND BOX_FREE restored_box

    !new_val
    !val
    return 0
```

## 核心 API 索引说明

### `BOX_NEW %out_box, %value`
分配 8 字节 (u64 位) 宽的堆块并填充数据，返回包装变量。

### `BOX_INTO_RAW %out_ptr, %box_reg`
提取 Box 底层的物理内存首地址，并**销毁**当前 Box 所有权寄存器，转由裸指针变量接管。

### `BOX_FROM_RAW %out_box, %raw_ptr`
输入一个现存的裸指针所有权，构建并返回一个被 Box 生命周期防线覆盖的受管对象。

### `BOX_FREE %box_reg`
析构 Box，归还其包装的数据所占用的堆空间给内存管理器。
