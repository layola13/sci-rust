# Path (路径处理)

提供用于处理系统文件路径的文本规则，包含解析、拼接、规范化等操作。

## 导入
```sa
@import "sa_std/path.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何将目录前缀与文件名进行安全合并，并检验最终生成的路径是否为绝对路径：

```sa
@import "sa_std/path.sars"
@import "sa_std/core/slice.sars"
@import "sa_std/string.sars"

@main() -> i32:
L_ENTRY:
    // 1. 定义基本目录和子路径
    base = utf8:"/var/log"
    append = utf8:"nginx/error.log"

    EXPAND SLICE_NEW base_slice, &base, 8
    EXPAND SLICE_NEW append_slice, &append, 15

    // 2. 拼接路径，得到 "/var/log/nginx/error.log" 动态字符串
    EXPAND PATH_JOIN full_path, base_slice, append_slice

    // 3. 将得到的字符串转化为切片进行绝对路径检测
    EXPAND STRING_LEN full_len, full_path
    
    // 获取 String 内部缓冲区指针
    EXPAND VEC_AS_PTR inner_ptr, full_path
    EXPAND SLICE_NEW path_slice, inner_ptr, full_len

    // 检测其是否是绝对路径 (预估为 1)
    EXPAND PATH_IS_ABSOLUTE is_abs, path_slice
    br is_abs -> L_ABS_OK, L_FAIL

L_ABS_OK:
    // 4. 清理所有临时资源
    !is_abs
    !path_slice
    !inner_ptr
    !full_len
    EXPAND STRING_FREE full_path
    !base_slice
    !append_slice
    return 0

L_FAIL:
    !is_abs
    !path_slice
    !inner_ptr
    !full_len
    EXPAND STRING_FREE full_path
    !base_slice
    !append_slice
    return 1
```

## 核心 API 索引说明

### `PATH_JOIN %out_str, %base_slice, %append_slice`
将 `%base_slice` 路径切片与 `%append_slice` 路径切片进行合并。会自动消除冗余的连接斜杠。

### `PATH_IS_ABSOLUTE %out_bool, %path_slice`
根据操作系统的不同，检测 `%path_slice` 是否是绝对路径形式（如 Linux 的 `/` 起始或 Windows 的 `C:` 起始）。若是则输出 `%out_bool = 1`。

### `PATH_CANONICALIZE %out_ok, %out_str, %path_slice`
根据实际的文件系统状态解析并输出 `%path_slice` 的规范化路径到 `%out_str`，剔除其中所有的软链接和相对部分 `..`。
- **安全性保护**：最新重构版本在解析结束后，会自动针对预设的安全根目录执行判定，确保没有越出沙箱。
