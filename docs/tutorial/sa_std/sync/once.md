# Once (一次性初始化)

用于那些在全局只需要精确发生（被执行）一次的过程（如：初始化系统环境、单例池挂载）。无论多少个线程并发尝试激活，它都保证内部的操作代码块有且只会被触发一次。

## 导入
```sa
@import "sa_std/sync/once.sars"
```

## 核心宏与用法

### `ONCE_NEW %out_once`
### `ONCE_IS_COMPLETED %out_bool, %once_reg`
### `ONCE_CALL %once_reg, %func_ptr`

```sa
EXPAND ONCE_NEW my_once

// @my_init_func 是你定义的且只会执行一次的函数
EXPAND ONCE_CALL my_once, @my_init_func
```