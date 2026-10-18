# Atomic (原子操作)

提供系统对内存位置进行并发无竞争改变的方法，例如内存栅栏和底层的 RMW (Read-Modify-Write) 并发状态。

## 导入
```sa
@import "sa_std/sync/atomic.sars"
```

这部分直接映射到底层的汇编原语如 `atomic_load`, `atomic_store`, `cmpxchg`, `atomic_rmw_add` 等。它们是上面高阶容器（Arc, RwLock 等）保持健壮性的基石。在无必要的情形下，建议直接使用高级别的封装。