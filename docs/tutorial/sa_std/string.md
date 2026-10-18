# String (动态字符串)

在 SA 中，动态处理且具有内存增长特性的可变长字符串数据由 `String` 容器提供。它可以像动态数组 `Vec` 一样被操作和维护。

## 导入
```sa
@import "sa_std/string.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何初始化、追加内容、取字符和计算长度并最后释放堆内垃圾的完整链路：

```sa
@import "sa_std/string.sars"
@import "sa_std/core/slice.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化空字符串容器
    EXPAND STRING_NEW my_str

    // 2. 准备我们要附加的静态字节并变成一个能够读取的切片
    hello = utf8:"Hello"
    EXPAND SLICE_NEW hello_slice, &hello, 5
    
    world = utf8:", World"
    EXPAND SLICE_NEW world_slice, &world, 7

    // 3. 将这两个切片连续推入字符串内容之中
    EXPAND STRING_PUSH_STR my_str, hello_slice
    EXPAND STRING_PUSH_STR my_str, world_slice

    // 4. 追加一个单个字符：使用 '!' 的 ASCII 码：33
    EXPAND STRING_PUSH_CHAR my_str, 33

    // 5. 获取整段动态字符串拥有的真实字节长度，此时预估应为 13
    EXPAND STRING_LEN str_length, my_str
    
    // 释放相关依赖
    !str_length
    !world_slice
    !hello_slice

    // 6. 销毁和释放内存以防堆分配泄漏
    EXPAND STRING_FREE my_str
    return 0
```

## 核心 API 索引说明

### `STRING_NEW %out_str`
分配并初始化在堆上的包装块记录，准备随时可扩容接收数据序列。

### `STRING_PUSH_STR %str_reg, %slice_reg`
执行块级别的切片连结动作，将包含内容首指针和长度信息的 `%slice_reg` 包含的所有字节数据填入字符串最后并动态扩展容器堆存储区。

### `STRING_PUSH_CHAR %str_reg, %char_val`
执行单字操作。往内容尾部压入一个 U64 承载的单字节 / UTF-8 等宽字符。

### `STRING_LEN %out_len, %str_reg`
提取存储头部控制块中的有效字符长度（字节数）。

### `STRING_FREE %str_reg`
销毁 `String` 对象本身的外壳及所包揽持有的缓冲字符存储。
