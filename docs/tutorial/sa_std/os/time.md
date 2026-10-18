# Time (时间与日期)

处理系统时间、单调时钟与休眠。

## 导入
```sa
@import "sa_std/time.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何获取休眠前后的毫秒时间戳差，从而测算执行延迟：

```sa
@import "sa_std/time.sars"

@main() -> i32:
L_ENTRY:
    // 1. 记录开始时间
    EXPAND TIME_NOW_UNIX_MS start_time

    // 2. 线程休眠 50 毫秒
    EXPAND TIME_SLEEP_MS 50

    // 3. 记录结束时间
    EXPAND TIME_NOW_UNIX_MS end_time

    // 4. 计算经历的时间差
    diff = sub end_time, start_time

    !diff
    !end_time
    !start_time
    return 0
```

## 核心 API 索引说明

### `TIME_NOW_UNIX_MS %out_u64`
提取系统时钟（基于 `CLOCK_REALTIME`），将距离 1970 年的毫秒差写给 `%out_u64`。

### `TIME_SLEEP_MS %ms_u64`
使调用该操作的当前进程线程进入阻挂状态（Syscall `nanosleep`）。如果睡眠期间遭到操作系统信号打断，底层会自动进行循环补偿直到睡够指定毫秒。
