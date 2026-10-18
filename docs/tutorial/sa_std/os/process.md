# Env 与 Process

提供了与操作系统环境变量交互及创建子进程的功能。

## 导入
```sa
@import "sa_std/env.sars"
@import "sa_std/process.sars"
```

## Env 核心宏与完整用法示例

下面的完整程序演示了如何设置一个局部的环境变量，然后又将其读取出来进行验证的步骤：

```sa
@import "sa_std/env.sars"
@import "sa_std/core/slice.sars"
@import "sa_std/string.sars"

@main() -> i32:
L_ENTRY:
    // 1. 设置环境变量 MY_VAR = 999
    key = utf8:"MY_VAR"
    val = utf8:"999"
    
    EXPAND SLICE_NEW k_slice, &key, 6
    EXPAND SLICE_NEW v_slice, &val, 3
    
    EXPAND ENV_SET set_ok, k_slice, v_slice
    br set_ok -> L_SET_OK, L_FAIL

L_SET_OK:
    !set_ok

    // 2. 尝试读取刚刚设置的变量
    EXPAND ENV_GET get_ok, got_str, k_slice
    br get_ok -> L_GET_OK, L_FAIL

L_GET_OK:
    // got_str 内容应为 "999"
    EXPAND STRING_FREE got_str
    !get_ok
    !k_slice
    !v_slice
    return 0

L_FAIL:
    !k_slice
    !v_slice
    return 1
```

## Process 核心宏与完整用法示例

下面的程序演示了如何安全调用外部的命令，并且等待子进程完成以捕获最终退出码：

```sa
@import "sa_std/process.sars"
@import "sa_std/vec.sars"
@import "sa_std/core/slice.sars"

@main() -> i32:
L_ENTRY:
    // 1. 准备要执行的可执行程序路径
    cmd = utf8:"/bin/ls"
    EXPAND SLICE_NEW cmd_slice, &cmd, 7
    
    // 2. 准备空参数数组
    EXPAND VEC_NEW args_vec

    // 3. 安全启动子进程
    EXPAND PROCESS_SPAWN spawn_ok, proc, cmd_slice, args_vec
    br spawn_ok -> L_SPAWN_OK, L_SPAWN_FAIL

L_SPAWN_OK:
    !spawn_ok
    
    // 4. 等待子进程完成，返回最终退出状态码
    EXPAND PROCESS_WAIT wait_ok, exit_code, proc
    
    !wait_ok
    !exit_code
    !cmd_slice
    EXPAND VEC_FREE args_vec
    return 0

L_SPAWN_FAIL:
    !spawn_ok
    !cmd_slice
    EXPAND VEC_FREE args_vec
    return 99
```

## 核心 API 索引说明

### `ENV_GET %out_ok, %out_str, %key_slice`
从环境变量表读取特定键的数据到 `%out_str` 关联的 `String` 中。若不存在则 `%out_ok = 0`。

### `ENV_SET %out_ok, %key_slice, %val_slice`
将 `%key_slice` 和 `%val_slice` 指向的数据注册至系统当前运行环境。

### `PROCESS_SPAWN %out_ok, %out_proc, %cmd_slice, %args_vec`
拉起子进程。
- **安全性保护**：为了避开诸如命令行注入（Command Injection）等攻击漏洞，在传入参数时进行了强隔离，并限制了有害环境变量（如 `LD_PRELOAD` 等）的透传。

### `PROCESS_WAIT %out_ok, %out_exit_code, %proc_reg`
同步等待 `%proc_reg` 所指向的子进程退出，并在 `%out_exit_code` 里接收进程返回值。
