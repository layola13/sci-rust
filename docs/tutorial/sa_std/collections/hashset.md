# HashSet (哈希集合)

HashSet 的底层逻辑由 `HashMap` 复用演变而来，用于验证唯一性是否存在。

## 导入
```sa
@import "sa_std/hashset.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何创建哈希集合、添加元素、查询集合中是否存在该元素以及销毁集合的完整示例：

```sa
@import "sa_std/hashset.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化集合
    EXPAND HASHSET_NEW my_set

    // 2. 插入元素
    ele_a = utf8:"element_a"
    EXPAND HASHSET_INSERT my_set, &ele_a

    // 3. 判断元素是否存在 (预期 contains_flag=1)
    EXPAND HASHSET_CONTAINS contains_flag, my_set, &ele_a
    br contains_flag -> L_CONTAINS_OK, L_FAIL

L_CONTAINS_OK:
    // 4. 再次判断一个不存在的元素
    ele_b = utf8:"element_b"
    EXPAND HASHSET_CONTAINS contains_flag_2, my_set, &ele_b
    br contains_flag_2 -> L_FAIL_UNEXPECTED, L_EXPECTED_ABSENT

L_EXPECTED_ABSENT:
    !contains_flag_2
    !contains_flag
    
    // 5. 释放集合
    EXPAND HASHSET_FREE my_set
    return 0

L_FAIL_UNEXPECTED:
    !contains_flag_2
    !contains_flag
    EXPAND HASHSET_FREE my_set
    return 99

L_FAIL:
    !contains_flag
    EXPAND HASHSET_FREE my_set
    return 1
```

## 核心 API 索引说明

### `HASHSET_NEW %out_set`
在堆上创建并初始化集合结构体，初始容量由底层 HashMap 的默认规格确定。

### `HASHSET_INSERT %set_reg, %key_ptr`
向集合中添加元素引用。如果元素已经存在，则不会重复添加。

### `HASHSET_CONTAINS %out_bool, %set_reg, %key_ptr`
判断传入的值是否存在。若存在，`%out_bool` 输出为 `1`；不存在则输出为 `0`。

### `HASHSET_FREE %set_reg`
销毁集合，归还其在堆内存上占有的相关桶空间和对象头部。
