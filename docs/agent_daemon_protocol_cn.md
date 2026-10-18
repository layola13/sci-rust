# `sa daemon` 协议规范（Phase A 可执行设计）

> **实现备注（2026-07-11）**：已落地 Unix socket daemon、完整 argv（含 `sa`/二进制路径归一化）、
> `agent_id`/`generation` 取消、`per-agent-limit`、`ping`/`shutdown`/`cancel`、响应 `metrics.wall_ms` 与
> verdict/affected 计数。客户端通过 `SA_DAEMON_SOCKET`（可选 `SA_AGENT_ID`/`SA_AGENT_GENERATION`）接入。
>

> 本文是 [`agent_native_compiler_gap_and_plan_cn.md`](agent_native_compiler_gap_and_plan_cn.md)
> Phase A 的落地规范。目标 KPI：**把 N-Agent 的冷启动成本从 O(N) 降到 O(1)，
> 缓存跨请求命中**。核实日期：2026-07-11，接口以当前 `src/cli.zig` /
> `src/flattener.zig` 实现为准。

---

## 0. 为什么 daemon 是最高杠杆

当前每次 `sa build/check/test` 都是**冷启动进程**：

- 三块进程内 static 缓存在进程退出时全部丢弃：
  - `src/cli.zig`：`source_tree_hash_cache`（源树哈希，mtime+size 校验）
  - `src/flattener.zig`：`import_source_cache`（导入源文本）
  - `src/flattener.zig`：`expanded_import_cache`（展开后导入）
- N 个 Agent 各自冷启，缓存零复用 → 重复 parse / 展开 / 布局 / 验证。

这三块缓存**已经是 `mutex + tick-LRU` 结构**（见 `import_source_cache_mutex`
/ `import_source_cache_tick`），天生适合迁移到常驻进程内跨请求共享。daemon
不需要重写缓存，只需要**延长它们的生命周期**并加请求路由。

---

## 1. 进程模型

```
Agent A ─┐
Agent B ─┤   Unix domain socket        ┌─ 共享缓存（进程内，跨请求存活）
Agent C ─┼──►  $XDG_RUNTIME_DIR/  ────► │   source_tree_hash_cache
Agent D ─┘     sa-daemon-<projhash>.sock│   import_source_cache
              （JSON 行协议）           │   expanded_import_cache
                                        │   （Phase B 追加）per-fn SAB / Referee summary
                                        └─ 调度器（Phase D 追加）
```

- **一个 daemon 绑定一个 project root**（socket 名含 project root 哈希），
  避免跨项目缓存串味，也让不同工程的 Agent 群互不干扰。
- **瘦客户端**：现有 CLI 子命令加 `--daemon` 标志；能连上就走 daemon，
  连不上（或 `--no-daemon`）回落到当前进程内执行 —— 保证零破坏、可灰度。
- **传输**：Unix domain socket（本机，低延迟，天然权限隔离）。不引入 TCP，
  避免暴露网络面（与 `content_safety` 的最小暴露原则一致）。

---

## 2. 线协议（JSON 行协议）

每个请求 / 响应是一行 UTF-8 JSON，以 `\n` 结尾（NDJSON）。复用现有
`--json` 诊断模型（`trap.writeJson` 输出的 `{"status","diagnostics"}`），
Agent 侧解析逻辑与现在完全一致。

### 2.1 请求

```json
{
  "id": "req-7f3a",
  "agent_id": "agent-03",
  "generation": 12,
  "op": "build" | "check" | "test" | "explain" | "cancel" | "ping" | "shutdown",
  "file": "src/main.sars",
  "args": ["--json", "--jobs", "4"],
  "cwd": "/abs/project/root"
}
```

- `agent_id` + `generation`：用于 Phase D 的过期任务取消（同 agent 新
  generation 到达即取消旧 generation 在途任务）。Phase A 可先只透传、不调度。
- `op: cancel`：请求体携带要取消的 `agent_id`（Phase D 生效；Phase A 可返回
  `unsupported` 占位）。
- `op: ping` / `shutdown`：健康检查与优雅退出。

### 2.2 响应

复用现有诊断模型，追加 daemon 元数据：

```json
{
  "id": "req-7f3a",
  "status": "ok" | "error",
  "exit_code": 0,
  "metrics": {
    "compile_tokens": 12050,
    "instruction_count": 842,
    "wall_ms": 41,
    "cache": { "source_tree": "hit", "import": "hit", "expanded": "miss" }
  },
  "diagnostics": [ /* 与现有 --json 完全一致的 diagnostic 数组 */ ],
  "stdout": "…",
  "stderr": "…"
}
```

- `metrics.cache.*`：命中率是 daemon 的核心可观测指标，直接证明"跨 Agent 复用"。
- `stdout`/`stderr`：daemon 内把执行输出捕获进字符串返回，客户端原样透传，
  保证 `--daemon` 与非 daemon 模式对 Agent 输出等价。

---

## 3. 服务端执行路径（复用现有分发）

daemon 收到请求后，**不重写编译逻辑**，直接复用现有可注入 writer 的入口：

```
src/cli.zig:7180  executeWithWritersAndOptions(allocator, argv, stdout, stderr, options)
```

- 把请求的 `args` 拼成 `argv`，`stdout`/`stderr` 用内存 buffer writer 接住，
  执行完把 buffer 内容塞回响应的 `stdout`/`stderr` 字段。
- 返回的 `!u8` 即 `exit_code`。
- **关键改动**：把 `src/cli.zig` 和 `src/flattener.zig` 里的 static 缓存变量
  从"进程 static"改为"daemon 会话持有"——最小做法是保持 static 但**不在
  请求结束时清空**（现在也不清，进程退出才没），daemon 常驻即天然跨请求存活。
  唯一要加的是 LRU 上限的运行时可配（已有 `*_max_entries` 测试钩子，提升为
  正式 env / 请求参数）。

### 3.1 并发模型（Phase A 最小版）

- daemon 主线程 accept；每个连接一个 worker 线程（或线程池）。
- 缓存已是 `mutex` 保护 → 多 worker 并发安全，无需额外改造。
- Phase A **不做调度/取消/配额**（那是 Phase D）；先证明"缓存跨请求复用 +
  免冷启动"的收益。但请求结构里预留 `agent_id`/`generation`，避免 Phase D 破协议。

---

## 4. 客户端改造（瘦客户端）

- 新增 `Command.daemon`（`sa daemon [--socket <path>] [--idle-timeout <s>]`）：
  启动/前台运行常驻服务。
- 现有子命令加 `--daemon` / `--no-daemon`：
  - `--daemon`：尝试连接（socket 不存在则可选自动 spawn），走线协议。
  - 默认（无标志）：保持当前行为（进程内），**零破坏**。
- 连接失败回落进程内执行，并在 `stderr` 给一条降级提示（Agent 可读）。

---

## 5. 生命周期与安全

- **socket 权限** `0600`，仅属主可连（本机多租户隔离）。
- **idle 超时**：空闲 N 秒自动退出，避免僵尸 daemon 占内存
  （直接回应本机 3.5 GB / 无 swap 的实测约束）。
- **版本校验**：请求携带客户端编译器版本；与 daemon 版本不符则响应
  `status:error, code: SA-DAEMON-001 version mismatch`，客户端回落冷启动。
  （缓存 key 已含 `cacheCompilerVersion()`，daemon 版本漂移不会污染缓存。）
- **崩溃隔离**：单个请求 panic 不应带崩 daemon —— worker 线程捕获，回一条
  `status:error` 诊断；必要时该请求回落客户端进程内重试。

---

## 6. 验收标准（对齐 Phase A KPI）

1. **正确性等价**：`--daemon` 与冷启动模式对同一输入产出**逐字节相同**的
   diagnostics + exit_code（用现有 fixture 语料做 A/B）。
2. **缓存复用可观测**：第二个 Agent 的同项目请求 `metrics.cache.import = "hit"`。
3. **吞吐量**：10-Agent benchmark（见 gap 文档 §3）daemon 模式 P50 反馈延迟
   相对冷启动 **下降 ≥5×**。
4. **稳定性**：单请求 panic 不带崩 daemon；idle 超时正确回收。
5. **零破坏**：不带 `--daemon` 时行为与当前完全一致。

---

## 7. 稳定错误码补充（写入 `trap.zig` 字典）

| Code | 含义 |
|------|------|
| `SA-DAEMON-001` | 客户端/daemon 版本不匹配，客户端应回落冷启动 |
| `SA-DAEMON-002` | socket 连接失败（daemon 未启动 / 权限） |
| `SA-DAEMON-003` | 请求格式非法（JSON 解析失败 / 缺字段） |
| `SA-DAEMON-004` | 请求被取消（Phase D：新 generation 抢占） |
| `SA-DAEMON-005` | 超配额，请求排队超时（Phase D） |

---

## 8. 实施顺序（Phase A 内部拆分）

1. **A1**：`Command.daemon` + Unix socket accept + NDJSON 编解码 +
   `op: ping/shutdown`。（可跑空壳 daemon）
2. **A2**：`op: build/check` 路由到 `executeWithWritersAndOptions`，
   buffer 捕获 stdout/stderr，返回 exit_code + diagnostics。
3. **A3**：static 缓存生命周期确认跨请求存活 + `metrics.cache.*` 命中率上报。
4. **A4**：客户端 `--daemon` 标志 + 连接/回落逻辑。
5. **A5**：idle 超时、socket 权限、版本校验、panic 隔离。
6. **A6**：10-Agent benchmark 脚本 + P50 延迟对比报告。

每步都可独立 `zig build` + 现有语料 A/B 验证，不需要等整个 Phase A 完成。

---

## 附：与既有文档的关系

- 本文 = `agent_native_compiler_gap_and_plan_cn.md` Phase A 的展开。
- `agent_first_toolchain.md`：应新增 "§5 Daemon 模式" 指回本文。
- Phase B（函数级 content hash + 增量 Referee）的 per-function SAB / Referee
  summary 缓存，未来挂在同一个 daemon 缓存层上（本文 §1 已预留位置）。
- Phase D（调度 / 取消 / 配额）复用本文请求里的 `agent_id` / `generation` 字段，
  不破协议。
