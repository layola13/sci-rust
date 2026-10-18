# HashMap (哈希映射表)

哈希表支持任意指针与 u64 作为字典的结构数据。底层基于容量倍增方案扩展，具备完整防溢出的重新散列机制保护。

## 导入
```sa
@import "sa_std/hashmap.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何创建 HashMap、插入自定义键值对、检索命中状态、安全移除，以及最终释放字典对象的内存：

```sa
@import "sa_std/hashmap.sars"

@main() -> i32:
L_ENTRY:
    // 1. 初始化哈希表
    EXPAND HASHMAP_NEW my_map

    // 2. 准备键值对 (以 GREETING 为 key，存入 1024 为 value)
    key_str = utf8:"my_key"
    
    // 插入操作，底层会使用哈希散列函数和冲突检测
    EXPAND HASHMAP_INSERT my_map, &key_str, 1024

    // 3. 安全读取哈希键
    EXPAND HASHMAP_GET ok, val, my_map, &key_str
    br ok -> L_GET_OK, L_GET_FAIL

L_GET_OK:
    // 此时 val 必定为 1024
    !ok
    !val

    // 4. 尝试移除一个哈希键，预期 remove_ok=1
    EXPAND HASHMAP_REMOVE remove_ok, my_map, &key_str
    
    // 5. 校验移除是否成功 (再次读取，预期应该 miss)
    EXPAND HASHMAP_GET check_ok, check_val, my_map, &key_str
    br check_ok -> L_UNEXPECTED_HIT, L_EXPECTED_MISS

L_EXPECTED_MISS:
    !check_ok
    !check_val
    !remove_ok
    
    // 6. 销毁并释放整个 HashMap 的哈希桶及对象
    EXPAND HASHMAP_FREE my_map
    return 0

L_UNEXPECTED_HIT:
    !check_ok
    !check_val
    !remove_ok
    EXPAND HASHMAP_FREE my_map
    return 99

L_GET_FAIL:
    !ok
    !val
    EXPAND HASHMAP_FREE my_map
    return 1
```

## 核心 API 索引说明与微型示例

### `HASHMAP_NEW %out_map`
分配哈希表的控制结构，建立预设大小的动态插槽数组并初始化状态。

### `HASHMAP_INSERT %map_reg, %key_ptr, %value`
将 `%key_ptr` 与数据进行关联。若哈希表负载因子过高，会自动触发 `map_rehash` 动作，该动作自带安全算术乘法溢出保护。

### `HASHMAP_GET %out_ok, %out_value, %map_reg, %key_ptr`
对传入指针进行哈希定位，在探针数组中查询是否命中。若键不存在，则 `%out_ok` 设为 `0`。

### `HASHMAP_REMOVE %out_ok, %map_reg, %key_ptr`
逻辑删除该位置的键，如果确实移除了已有节点，`%out_ok` 返回 `1`，否则返回 `0`。

### `HASHMAP_FREE %map_reg`
释放所有已插入键值以及底层持有的桶数组和控制块头部指针。
