# Rc (Reference Counting)

`Rc` 提供了单线程的共享所有权。与 `Arc` 类似，但底层计数并不保证原子性，开销最低，但**绝对不能跨线程传递**。

## 导入
```sa
@import "sa_std/core/rc.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序演示了单线程环境下 `Rc` 的引用克隆和资源回收生命周期：

```sa
@import "sa_std/core/rc.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化一个新的单线程引用计数实例
    EXPAND RC_NEW my_rc, 555
    
    // 2. 复制引用
    EXPAND RC_CLONE my_rc
    
    // 3. 读取值并校验
    EXPAND RC_GET value, my_rc
    
    // 4. 依次剥离递减引用计数
    EXPAND RC_DECREMENT_STRONG_COUNT my_rc
    EXPAND RC_DECREMENT_STRONG_COUNT my_rc
    
    !value
    return 0
```

## 核心 API 索引说明

### `RC_NEW %out_rc, %value`
分配堆包裹，创建强计数和弱计数为 1 的局部 Rc 对象。

### `RC_CLONE %rc_reg`
递增该局部实例的强引用计数。

### `RC_GET %out_value, %rc_reg`
只读获取 Rc 的内部数值。

### `RC_DECREMENT_STRONG_COUNT %rc_reg`
递减强引用。降至 0 时释放 Rc 包装所占用的堆空间。

### `RC_TRY_UNWRAP %out_ok, %out_value, %rc_reg`
尝试剥离 Rc 外壳。如果引用唯一则输出内部数据并将 `%out_ok` 设为 `1`；否则 `%out_ok` 设为 `0`。
