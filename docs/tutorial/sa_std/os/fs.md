# Fs (文件系统)

SA 的文件系统模块提供了安全的文件和目录操作原语。最新版本在底层引入了严格的安全沙箱机制：无论是文件读取还是目录拷贝，都会自动校验是否存在跨目录（如 `../` 逃逸）或不安全的符号链接跟随（Symbolic Link Escape）。

## 导入
```sa
@import "sa_std/fs.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何将一段数据切片写入文件，然后再将其读取回来进行完整的内容验证：

```sa
@import "sa_std/fs.sars"
@import "sa_std/core/slice.sars"
@import "sa_std/string.sars"

@main() -> i32:
L_ENTRY:
    // 1. 准备要写入的文件路径和测试数据
    path_bytes = utf8:"test_output.txt"
    test_data = utf8:"SA FS Test Data"
    
    EXPAND SLICE_NEW data_slice, &test_data, 15

    // 2. 将数据切片写入文件
    EXPAND FS_WRITE write_ok, &path_bytes, data_slice
    br write_ok -> L_WRITE_OK, L_FAIL

L_WRITE_OK:
    !write_ok

    // 3. 再次读取该文件内容为 String 容器
    EXPAND FS_READ_TO_STRING read_ok, read_str, &path_bytes
    br read_ok -> L_READ_OK, L_FAIL

L_READ_OK:
    // read_str 包含了我们刚才写入的数据
    EXPAND STRING_LEN read_len, read_str
    
    // 释放资源
    !read_len
    EXPAND STRING_FREE read_str
    !read_ok
    !data_slice
    return 0

L_FAIL:
    !data_slice
    return 1
```

## 核心 API 索引说明与微型示例

### `FS_READ_TO_STRING %out_ok, %out_str, %path_ptr`
读取整个文件的内容到 `%out_str` 关联的 `String` 对象中。
- **安全性保护**：底层在解析路径时，对路径是否含有 `%00` 截断、`../` 以及是否超越了沙箱声明前缀进行严格判定，若发生泄露则 `%out_ok` 会返回 `0`。

### `FS_WRITE %out_ok, %path_ptr, %data_slice`
将 `%data_slice` 里的字节缓冲直接写入文件 `%path_ptr`。如果文件不存在将新建，已存在将覆盖。

### `FS_OPEN_DIR %out_ok, %out_dir, %path_ptr`
安全打开一个物理目录对象并保存句柄至 `%out_dir`。
- **安全性保护**：底层打开时会自动以 `NO_FOLLOW`（不追踪符号链接）参数进行目录挂载，彻底拦截因为恶意符号链接逃逸到系统上层其它私密目录的行径。
