# Mpsc (多生产者单消费者通道)

提供异步与跨线程通讯的主流方案——基于 Channel 管道进行缓冲推送和获取。

`Mpsc` 的底层内存已经在构建时全面引入了安全数学计算宏的强校验保护。针对海量管道缓冲上限和每个数据块长度所产生的乘法运算 (`NUM_U64_CHECKED_MUL` 与 `NUM_U64_CHECKED_ADD`) 能有效截断计算上的极大数字假象，避免随之发生的致命 OOM（Out Of Memory）与段错误内存覆写。

## 导入
```sa
@import "sa_std/sync/mpsc.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了 MPSC 管道如何建立、进行多轮发送，并被单方消费者以非阻塞的方式源源不断地进行消化：

```sa
@import "sa_std/sync/mpsc.sars"

@main() -> i32:
L_ENTRY:
    // 1. 创建一个容量为 100 的 MPSC 通道
    EXPAND MPSC_NEW chan, 100
    
    // 2. 发送方进行生产消息 (假设发送了两条消息)
    EXPAND MPSC_SEND send_ok1, chan, 42
    EXPAND MPSC_SEND send_ok2, chan, 99
    
    // 断言发送应当成功
    !send_ok1
    !send_ok2
    
    // 3. 消费方尝试非阻塞拉取数据
    // 预期取出的是先进先出的 42
    EXPAND MPSC_TRY_RECV recv_ok1, msg1, chan
    br recv_ok1 -> L_RECV_1_OK, L_FAIL

L_RECV_1_OK:
    // 必定输出 42
    !msg1
    !recv_ok1
    
    // 取出第二条数据
    EXPAND MPSC_TRY_RECV recv_ok2, msg2, chan
    br recv_ok2 -> L_RECV_2_OK, L_FAIL

L_RECV_2_OK:
    // 必定输出 99
    !msg2
    !recv_ok2
    
    // 4. 再次取数据（预期队列已空，无法获取）
    EXPAND MPSC_TRY_RECV recv_ok3, msg3, chan
    br recv_ok3 -> L_FAIL, L_EXPECTED_EMPTY

L_EXPECTED_EMPTY:
    !recv_ok3
    !msg3
    
    // 5. 将队列予以销毁，完成收尾清理
    EXPAND MPSC_FREE chan
    return 0

L_FAIL:
    EXPAND MPSC_FREE chan
    return 1
```

## 核心 API 索引说明

### `MPSC_NEW %out_chan, %cap`
根据 `%cap` 的容量创建通讯管道结构与环形阵列缓冲。如果请求了超越体系界限的 `%cap` 参数而产生上溢或底层内存申请容量超标，则会抛出 `panic(1401)` 等进行防御截流。

### `MPSC_SEND %out_ok, %chan_reg, %message`
线程安全地通过原子计算槽位推入 `%message` 到发送缓存区。只有当容量被占满时 `%out_ok` 会返回 `0` 并且拒绝写入。

### `MPSC_TRY_RECV %out_ok, %out_value, %chan_reg`
非阻塞地单方取出最新被挂载在队列就绪位端的数据。如无就绪信息或者未获得到，直接反馈 `%out_ok = 0`。

### `MPSC_FREE %chan_reg`
释放信道内存，将分配好的连续 Ring 队列资源从堆上予以安全归还。
