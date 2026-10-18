# IO 流读写 (Input & Output)

SA 提供了处理字节数据流输入与输出的功能，封装在 `sa_std/io.sa` 及其关联系列模块中。支持对字节数组的原地游标操作、系统外设的读写暴露以及为提高 IO 效能设立的缓冲流封装。

## 导入
```sa
@import "sa_std/io.sars"
@import "sa_std/io/buf_reader.sars"
@import "sa_std/io/buf_writer.sars"
```

## 核心宏与完整用法示例

### 极速控制台交互：基础 PRINT 宏

由于 SA-ASM 无自动字符串拆箱等高层级设施，基础控制台常常由直接给定文本块（通常是 `utf8` 定义或内存动态 `String`）大小进行的调用执行。

```sa
@import "sa_std/io.sars"

@const GREETING = utf8:"Hello, World!\n"

@main() -> i32:
L_ENTRY:
    // 输出静态字节串，14是包含换行符在内的准确字节数
    EXPAND PRINT GREETING, 14
    
    // PRINTLN 等价于执行 PRINT 并额外推入回车符
    EXPAND PRINTLN GREETING, 14
    
    return 0
```

### IO Cursor (字节内流游标处理)

游标就像是把你申请的内存当成了虚拟硬盘文件一般。你只要维护游标实例，底层代码就会安全管理目前你“读取或写入到了哪一个字节”。对于防止封包溢出的手动序列化具有关键作用。

```sa
@import "sa_std/io.sars"

@main() -> i32:
L_ENTRY:
    // 1. 设置一个源字节片（模拟传入的原始封包内容）
    src_buf = stack_alloc 10
    store src_buf+0, 65 as u8 // 'A'
    store src_buf+1, 66 as u8 // 'B'
    store src_buf+2, 67 as u8 // 'C'

    // 2. 为这段内容建立内部字节游标包装
    EXPAND IO_CURSOR_NEW cur, src_buf, 3
    
    // 3. 准备一块新内存尝试通过流读入获取数据
    dst_buf = stack_alloc 10
    
    // 从游标执行读取 (预计：读取游标内部的头2个字节，放到目标中。成功读到长度也应是2)
    EXPAND IO_CURSOR_READ ok, read_len, cur, dst_buf, 2
    br ok -> L_READ_OK, L_FAIL

L_READ_OK:
    // 游标已偏移，read_len 必须为 2
    !read_len
    !ok
    
    // 获取 dst_buf 被读入的数据进行业务消费
    val = load dst_buf+0 as u8
    !val
    
    // 继续读（预计只会再读取到 1 个字节的数据，游标被全部消耗）
    EXPAND IO_CURSOR_READ ok2, read_len2, cur, dst_buf, 5
    !read_len2
    !ok2

    !cur
    !dst_buf
    !src_buf
    return 0

L_FAIL:
    !ok
    !read_len
    !cur
    !dst_buf
    !src_buf
    return 1
```

## 核心 API 索引说明

### `PRINT %msg_ptr, %len`
输出字节流至 `stdout`。没有行尾结尾换行符修饰。

### `PRINTLN %msg_ptr, %len`
同 `PRINT`，但自动换行。

### `IO_CURSOR_NEW %out_cursor, %data_ptr, %data_len`
为预分配好的缓冲区构建流式游标状态机对象，内含原始指针与长度上限。

### `IO_CURSOR_READ %out_ok, %out_len, %cursor_reg, %dst_ptr, %dst_cap`
将数据从游标对象推进复制到 `%dst_ptr` 目标内存去。它具备完整的防越界安全特性并返回最终成功推进的真实字节数。

### `IO_CURSOR_WRITE %out_ok, %out_len, %cursor_reg, %src_ptr, %src_len`
以增量填入方式推送到游标对象原本包装的内存中，直到达到预定义容量上限。

### 扩展缓冲流 (BufReader / BufWriter)

当对系统级文件句柄或物理流通道作碎块级别的处理时，如果一字节一发就会频繁产生极高的 syscall 开销（参见问题改进档案对 IO 单个调用的瓶颈梳理）。此时可创建缓冲对象：

- `BUF_WRITER_NEW %out_writer, %raw_stream`
- `BUF_WRITER_WRITE %out_ok, %out_written, %writer_reg, %data_ptr, %data_len`
- `BUF_WRITER_FLUSH %out_ok, %writer_reg`
（底层直到触发 FLUSH，或装载到达缓冲最大长度才会统一发出 syscall 以降本提效。）
