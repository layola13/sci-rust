# Mutex (互斥锁)

用于多线程保护的底层互斥锁原语。它能够有效避免 Data Race（数据竞争）。

SA 标准库近期对 `Mutex` 做了针对性的算法优化，由原来的激进“纯轮询占用 CPU”方案，更新成了基于 **指数退避自旋 (Exponential Backoff)** 加系统休眠的混合算法。在保证低延迟竞争锁获取的前提下，极大降低了长期无法获取锁时的无效 CPU 使用。

## 导入
```sa
@import "sa_std/sync/mutex.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了单线程下获取互斥锁并在进入临界区执行后再解除占用的全过程。在实际项目中，可以将其包裹在 `Arc` 中传给多线程系统：

```sa
@import "sa_std/sync/mutex.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化分配一把锁
    EXPAND MUTEX_NEW my_mtx
    
    // 2. 尝试无阻塞地获取锁 (应该立刻成功获得)
    EXPAND MUTEX_TRY_LOCK ok1, my_mtx
    br ok1 -> L_LOCK_1_OK, L_FAIL

L_LOCK_1_OK:
    // 3. 在此时再次尝试获取锁，将会立即失败，因为锁已经被独占
    EXPAND MUTEX_TRY_LOCK ok2, my_mtx
    br ok2 -> L_FAIL_UNEXPECTED, L_EXPECTED_BUSY

L_EXPECTED_BUSY:
    !ok2
    
    // 4. 进行安全的解除独占
    EXPAND MUTEX_UNLOCK my_mtx
    
    // 5. 再次使用会发生指令退避与休眠的稳定锁定调用进行阻塞等待
    EXPAND MUTEX_LOCK my_mtx
    
    // 临界区域的业务操作...
    
    // 操作完毕，解锁
    EXPAND MUTEX_UNLOCK my_mtx

    !ok1
    !my_mtx
    return 0

L_FAIL_UNEXPECTED:
    !ok2
    !ok1
    !my_mtx
    return 99

L_FAIL:
    !ok1
    !my_mtx
    return 1
```

## 核心 API 索引说明

### `MUTEX_NEW %out_mutex`
分配并在堆上建立一个被保护的锁定块状态机对象，默认处于未锁定空闲状态。

### `MUTEX_LOCK %lock_ptr`
尝试获取锁的所有权。如果已有其他线程获取，当前线程将会进入 `L_MUTEX_LOCK_WAIT` 的“自旋 -> 增长间隙退避 -> 系统休眠”的智能等待期。

### `MUTEX_TRY_LOCK %out_ok, %lock_ptr`
进行极速非阻塞的探测获取。如果立刻获取锁成功 `%out_ok` 为 `1`，锁标志位置位；如果锁已被占用则立刻返回 `%out_ok` 为 `0`。

### `MUTEX_UNLOCK %lock_ptr`
将锁标志恢复空闲状态，在所有操作执行结束并保证跳出共享安全边界之外，务必解锁释放给他人使用。
