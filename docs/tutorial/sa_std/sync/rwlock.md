# RwLock (读写锁)

当数据存在“绝大部分是多方同时读取，偶发单方写入”的场景下，使用读写锁 (Read-Write Lock) 将比全局互斥锁 (`Mutex`) 拥有极高的并发效率。

SA 的 `RwLock` 经过架构重构：修复了读者计数可能会引发的下溢漏洞（释放错误），且引入了基于硬件级 `atomic_rmw_add` 与获取释放序列 (acq_rel) 内存一致性模型的原子宏。使得读写锁的同步状态即使面对极其严苛的多核高并发也不会产生撕裂和竞争。

## 导入
```sa
@import "sa_std/sync/rwlock.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序演示了在一个读写锁实例上发生写独占、读共享验证、多重只读借用等的综合机制：

```sa
@import "sa_std/sync/rwlock.sars"

@main() -> i32:
L_ENTRY:
    EXPAND RWLOCK_NEW my_rw_lock

    // 1. 获取独占写入锁（第一次通常必定成功）
    EXPAND RWLOCK_TRY_WRITE w_ok, write_guard, my_rw_lock, L_WRITE_FAIL
    
    // 2. 模拟：由于已经处于写独占状态，此时其他人尝试获取只读锁将会被无情拒绝
    EXPAND RWLOCK_TRY_READ r_ok_1, read_guard_1, my_rw_lock, L_EXPECTED_READ_FAIL

L_EXPECTED_READ_FAIL:
    // ...被写者排斥
    !r_ok_1
    !read_guard_1

    // 3. 写者完成临界工作，释放独占写锁
    EXPAND RWLOCK_RELEASE_WRITE my_rw_lock
    !write_guard
    !w_ok
    
    // 4. 写者退场，现在多个读者可以成功并行进场
    EXPAND RWLOCK_TRY_READ r_ok_2, read_guard_2, my_rw_lock, L_READ_FAIL_UNEXPECTED
    EXPAND RWLOCK_TRY_READ r_ok_3, read_guard_3, my_rw_lock, L_READ_FAIL_UNEXPECTED
    
    // 5. 模拟：此时在有读者的情况下来了一个写入者，获取写锁必定失败！
    EXPAND RWLOCK_TRY_WRITE w_ok_2, write_guard_2, my_rw_lock, L_EXPECTED_WRITE_FAIL

L_EXPECTED_WRITE_FAIL:
    !w_ok_2
    !write_guard_2
    
    // 6. 所有读者完成阅读，纷纷退场交出钥匙
    EXPAND RWLOCK_RELEASE_READ my_rw_lock
    !read_guard_2
    !r_ok_2
    
    EXPAND RWLOCK_RELEASE_READ my_rw_lock
    !read_guard_3
    !r_ok_3

    !my_rw_lock
    return 0

L_READ_FAIL_UNEXPECTED:
    return 98

L_WRITE_FAIL:
    return 99
```

## 核心 API 索引说明

### `RWLOCK_NEW %out_lock`
在底层初始化用于存放 `RwLock_readers` 和 `RwLock_writing` 信号标志的内存。

### `RWLOCK_TRY_READ %out_ok, %out_guard, %lock_reg, %err_label`
带有回滚与失败跳转的安全读者获取。若内部判定 `RwLock_writing` 为激活状态，直接跳入 `%err_label`；若允许阅读，利用原子自增成功注册阅读者份额。

### `RWLOCK_TRY_WRITE %out_ok, %out_guard, %lock_reg, %err_label`
仅当目前没有任何人拥有写入权并且拥有读取权（读/写状态机皆为 `0`）时，通过 `cmpxchg` 并发原语夺取写入资格。冲突则跳入 `%err_label` 拒绝。

### `RWLOCK_RELEASE_READ %lock_reg`
取消自己的阅读份额。底层函数保护保证了在执行时会侦测计数状态并防范 `panic(1601)` 读取者错误下溢漏洞（读者人数少于 1 继续引发减法）。

### `RWLOCK_RELEASE_WRITE %lock_reg`
退出写排他状态，重新让其他人公平竞争资源。
