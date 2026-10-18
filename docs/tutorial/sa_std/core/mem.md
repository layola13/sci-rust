# Mem (内存操作)

提供系统级的底层内存复制、重置。带有内置防止空指针读写的边界保护。

## 导入
```sa
@import "sa_std/core/mem.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何向一块栈分配的局部内存块填充初值，并利用 `MEM_COPY` 完整备份其内容（若遇到非法空指针入参会被阻断并 Panic）：

```sa
@import "sa_std/core/mem.sars"

@main() -> i32:
L_ENTRY:
    // 1. 申请 16 字节的局部源内存，16 字节的目标内存
    src_buf = stack_alloc 16
    dst_buf = stack_alloc 16

    // 2. 将源内存的数据全部设为单字节 'A' (对应 65)
    EXPAND MEM_SET src_buf, 65, 16

    // 3. 将源内存的数据拷贝到目标内存中
    // 底层会进行 nil/NULL 检查保护，若 src_buf/dst_buf 意外为空，则会断言 panic(1701/1702)
    EXPAND MEM_COPY dst_buf, src_buf, 16

    // 4. 读取目标内存的第一个字节校验
    first_char = load dst_buf+0 as u8
    
    !first_char
    return 0
```

## 核心 API 索引说明

### `MEM_COPY %dst_ptr, %src_ptr, %byte_count`
将自 `%src_ptr` 开始的 `%byte_count` 字节的数据拷贝到 `%dst_ptr`。
- 安全保障：当 `%byte_count` 非 0 且 `dst` 为 null 时，抛出 `panic(1701)`；`src` 为 null 时，抛出 `panic(1702)`。

### `MEM_SET %dst_ptr, %val_u8, %byte_count`
向 `%dst_ptr` 后的连续 `%byte_count` 字节填充 `%val_u8` 数据。
- 安全保障：当 `%byte_count` 非 0 且 `dst` 为 null 时，抛出 `panic(1703)`。

### 字长获取宏

#### `MEM_SIZE_OF_BOOL %out_size`
#### `MEM_SIZE_OF_U8 %out_size`
#### `MEM_SIZE_OF_U64 %out_size`
#### `MEM_SIZE_OF_PTR %out_size`
将对应底层数据类型的系统字长大小输出到 `%out_size` 寄存器。
