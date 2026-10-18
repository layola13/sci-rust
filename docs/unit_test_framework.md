# Safe ASM 原生单元测试框架 (Native Unit Test Framework)

Safe ASM 拥有内置的、零运行时开销的单元测试框架。它允许你在汇编级别直接编写断言和隔离测试，无需借助外部 bash 脚本或繁重的宿主环境。

## 1. 如何编写与运行测试

### 1.1 编写 `@test` 用例
在 `.sa` 源码中，你可以使用 `@test` 关键字直接声明一个无参无返回值的测试块。

```sa
// math_test.sa

@const ADD_FAIL_MSG = utf8:"math_test.sa:7: expected 5, got -5"
#def ADD_FAIL_MSG_LEN = 34

@test "addition handles negative numbers"():
L_ADD:
    // 1. 执行被测逻辑
    a = add -10, 5
    
    // 2. 调用带诊断消息的断言宏
    EXPAND ASSERT_EQ_MSG assert_cond, a, 5, ADD_FAIL_MSG, ADD_FAIL_MSG_LEN
    !a
    !assert_cond
    return

@test "memory correctly freed prevents leaks"():
L_MEMORY:
    p = alloc 16
    ! p
    
    // 如果忘记写 ! p，测试框架会自动探测到 MemoryLeak 并标记测试失败
    return
```

### 1.2 运行测试 (`sa test`)
使用 `sa test` 命令行可以直接发现并执行目录下所有的 `@test`：

```bash
# 运行当前目录下的所有测试
sa test ./

# 模糊匹配测试名 (只运行带有 "addition" 的测试)
sa test ./ --filter "addition"

# 列出会被选择的测试，只做前端检查和元数据收集，不发射或链接测试二进制
sa test ./ --list

# 只完成编译和链接，确认测试可构建但不运行
sa test ./ --compile-only

# 失败时额外输出 panic 诊断和最近记录的调试标量
sa test ./ --trace-panic
```

**测试报告输出示例：**
```text
[PASS] memory correctly freed prevents leaks
[FAIL] addition handles negative numbers
----
test result: FAILED. 1 passed; 1 failed; 0 skipped
```

失败详情输出到 stderr。测试框架会识别 `panic_msg` 中的 `expected ... got ...` 或 `expected=... actual=...` 断言文本，并在原始 panic 前补充稳定字段：

```text
error: test addition handles negative numbers exited with code 231
  test location: math_test.sa:3:1
  code path: math_test.sa::_saasm_test_1
  panic: code=103
  panic location: math_test.sa:6:5
assertion failed:
  expected: 5
  actual: -5
PANIC[103]: math_test.sa:6:5: expected 5, got -5
```

`--trace-panic`（或别名 `--test-debug`）只影响失败详情。配合测试 helper 记录标量后，失败 stderr 会包含最近记录值：

```text
  trace-panic: enabled
recent scalars:
  raw_status=0
  strict_status=1
  raw_mask=7
```

`--list` 输出受 `--filter` / `--skip` / `--exact` / `--ignored` / `--include-ignored` 影响，并包含测试标记与源码位置。它只需要前端编译/验证通过，不会生成 LLVM bitcode、链接测试可执行文件或运行子进程；需要验证后端发射和链接时使用 `--compile-only`。

```text
tests:
- addition handles negative numbers (math_test.sa:3:1)
- ignored crash path [ignored] [should_panic] (math_test.sa:12:1)
test count: 2
```

## 2. 断言宏的底层原理 (ASSERT_*)

在 `sa_std/core/sa_core.sa` 中，断言是通过宏展开来实现的，它们在底层会被展开为极其高效的分支语句。

```sa
[MACRO] ASSERT_EQ %cond, %actual, %expected, %ok_label, %fail_label
    %cond = eq %actual, %expected
    br %cond -> %ok_label, %fail_label
[END_MACRO]
```
当你需要框架级失败详情时，优先使用带消息的 `ASSERT_*_MSG` 变体，让失败路径通过 `panic_msg(103, ...)` 输出可解析的诊断文本。

当前标准库还提供 `ASSERT_TRUE_MSG` / `ASSERT_EQ_MSG` / `ASSERT_NE_MSG`。调用方传入静态消息常量，推荐把文件、行号、期望值和实际值写进消息，便于 `sa test` 提取：

```sa
@const ASSERT_FAIL_MSG = utf8:"math_test.sa:6: expected 5, got -5"
#def ASSERT_FAIL_MSG_LEN = 34

@test "addition handles negative numbers"():
L_ENTRY:
    value = add -10, 5
    EXPAND ASSERT_EQ_MSG assert_cond, value, 5, ASSERT_FAIL_MSG, ASSERT_FAIL_MSG_LEN
    !value
    !assert_cond
    return
```

如果测试需要动态 actual/expected 值，可以使用轻量测试 helper：

```sa
@import "sa_std/testing/assert.sai"

@const RAW_STATUS_NAME = utf8:"raw_status"
@const THIS_FILE = utf8:"status_test.sars"

@test "status matches strict parser"():
L_ENTRY:
    raw_status = add 0, 0
    call @sa_test_debug_i64(*RAW_STATUS_NAME, 10, raw_status)
    call @sa_assert_eq_i64_at(raw_status, 1, 103, *THIS_FILE, 14, 8, 5)
    !raw_status
    return
```

`sa_assert_eq_i64(actual, expected, code)` 失败时输出 `PANIC[code]: expected=<expected> actual=<actual>`，`sa test` 会自动提取为稳定的 `assertion failed` 字段。`sa_test_debug_i64(name, len, value)` 只记录最近标量；只有启用 `--trace-panic` / `--test-debug` 时才会在失败 panic 后打印这些值。
如果需要具体错误行列，使用 `sa_assert_eq_i64_at(actual, expected, code, file, file_len, line, col)`；runner 会把它解析为 `panic location`。

## 3. 测试隔离架构 (Process Isolation)

由于 SA 的设计哲学是 **Fail-Fast (Panic 即终止)**，如果一个测试断言失败或触发了非法内存访问，整个解释器通常应该崩溃。

为了让测试“失败而不中断执行列表”，`sa test` 实现了一种多进程隔离机制：
1. 主进程（Test Runner）解析出所有的 `@test` 符号，形成测试元数据列表 (`test_meta.TestList`)。
2. 针对每一个测试，主进程通过 `fork` / `spawn` 拉起一个孤立的子进程。
3. 主进程监听子进程的 Exit Code：
   - 如果 Exit Code == `0`，标记为 **PASS**。
   - 如果 Exit Code == `103` (AssertionFailed)，标记为 **FAIL** 并提取 stderr 日志。
   - 如果触发了 `UseAfterMove` / `MemoryLeak` 等 Trap，记录为 **ERROR**。

这种隔离机制确保了即便某个测试严重违规导致内存段错误，其余的测试依旧会正常排队执行，为你提供最完整的安全体检报告。
