# 项目：构建高性能 Echo 服务器

作为本教程的第一个实战项目，我们将结合 `netx` 引擎和 `sa_std` 构建一个支持并发处理的 Echo 服务器。

## 1. 项目需求
- 监听 `8080` 端口。
- 接收客户端发送的任何消息，并在其前面加上 `ECHO: ` 后返回。
- 能够处理多个并发连接而不阻塞。

## 2. 核心架构
我们将使用 **Reactor 模式**：
1.  **Main Loop**：轮询 `sa_netx_recv_ticket`。
2.  **Dispatcher**：根据 Ticket 的 `op_code` 分发任务。
3.  **Handler**：处理具体的业务逻辑。

## 3. 源码实现 (`echo.sa`)

```sa
@import "sa_std/netx.sal"
@import "sa_std/netx.sai"
@import "sa_std/io.sars"

@const PREFIX = utf8:"ECHO: "
@const MSG = utf8:"Echo Server listening on 8080..."

@main() -> i32:
L_ENTRY:
    res = call @sa_netx_init(1024, 1)
    host = utf8:"0.0.0.0"
    res = call @sa_netx_listen(&host, 7, 8080)
    EXPAND PRINTLN MSG, 32

L_LOOP:
    ticket = alloc Ticket_SIZE
    res = call @sa_netx_recv_ticket(0, ticket)

    op = load ticket+Ticket_op_code as u16
    is_data = eq op, 5
    br is_data -> L_HANDLE_DATA, L_SKIP

L_HANDLE_DATA:
    slot_id = load ticket+Ticket_slot_id as u32
    data_ptr = load ticket+Ticket_payload as ptr
    data_len = load ticket+Ticket_payload_len as u32

    call @sa_netx_push_outbound(0, slot_id, &PREFIX, 6)
    call @sa_netx_push_outbound(0, slot_id, data_ptr, data_len)

    !data_ptr
    !slot_id
    !data_len
    jmp L_CLEANUP

L_SKIP:
    !op
    jmp L_CLEANUP

L_CLEANUP:
    !ticket
    !is_data
    jmp L_LOOP
```

## 4. 运行与测试
1.  编译并运行：`sa run echo.sa`
2.  在另一个终端使用 `telnet` 或 `nc` 连接：
    ```bash
    nc localhost 8080
    > hello
    ECHO: hello
    ```

## 5. 进阶挑战
- **多线程化**：修改 `sa_netx_init` 参数，开启 4 个 Reactor 线程。
- **内存安全**：在 `L_HANDLE_DATA` 中，确保所有的 Ticket 资源都已正确释放。
- **协议升级**：尝试识别输入中的 `quit` 字符串，并调用 `sa_netx_close_slot` 主动关闭连接。

恭喜你！你已经写出了一个基于 `io_uring` 的工业级高性能 Echo 服务器原型。
