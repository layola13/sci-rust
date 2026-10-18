# BTreeMap / BTreeSet

提供自动有序的查找树（基于 B 树实现），适合对键值进行范围查询或者需要数据持久维持顺序的场景。与 HashMap 不同，它不会对键进行散列分布，而是根据比较函数（例如字面量升序/降序）进行组织。

在最新版本中，B 树底层节点的拆分（分裂）也已经被置于防溢出安全数学计算（`NUM_U64_CHECKED_*`）体系下保护。

## 导入
```sa
@import "sa_std/btree_map.sars"
@import "sa_std/btree_set.sars"
```

## 核心宏与完整用法示例

下面的完整 SA 程序展示了如何初始化 BTreeMap，插入数据（此时数据会被自动按节点拆分排序），获取特定数据，并释放整棵树。

```sa
@import "sa_std/btree_map.sars"

@main() -> i32:
L_ENTRY:
    // 1. 新建一棵 B 树映射
    EXPAND BTREEMAP_NEW tree_map

    // 2. 准备键值并插入
    // 假定我们要使用某个数值作为指针进行模拟存放
    key_ptr1 = stack_alloc 8
    store key_ptr1+0, 500 as u64
    
    key_ptr2 = stack_alloc 8
    store key_ptr2+0, 100 as u64

    // 此时插入会经历根节点的分裂检查和底层页对齐平衡
    EXPAND BTREEMAP_INSERT tree_map, key_ptr1, 1024
    EXPAND BTREEMAP_INSERT tree_map, key_ptr2, 2048

    // 3. 尝试读取刚刚插入的健 key_ptr1
    EXPAND BTREEMAP_GET ok, val, tree_map, key_ptr1
    br ok -> L_FOUND, L_MISS

L_FOUND:
    // 命中预期，返回的是关联的值 1024
    !val
    !ok
    
    // 4. 从树中删除键
    EXPAND BTREEMAP_REMOVE r_ok, tree_map, key_ptr1
    !r_ok

    // 5. 销毁树 (包含其拥有的所有左右子叶和页结点)
    EXPAND BTREEMAP_FREE tree_map
    return 0

L_MISS:
    !val
    !ok
    EXPAND BTREEMAP_FREE tree_map
    return 1
```

## 核心 API 索引说明

### BTreeMap 宏

#### `BTREEMAP_NEW %out_map`
初始化 B 树结构和页表元数据。

#### `BTREEMAP_INSERT %map_reg, %key_ptr, %value`
根据比较器规则，通过多层深度下沉到对应数据叶节点，插入新数据。若当前节点饱和则进行分页。

#### `BTREEMAP_GET %out_ok, %out_value, %map_reg, %key_ptr`
进行层级查找，若成功命中则 `%out_ok = 1` 并且 `%out_value` 获取对应数据。

#### `BTREEMAP_REMOVE %out_ok, %map_reg, %key_ptr`
删除节点，触发底层再平衡并收缩多余子页空间。

#### `BTREEMAP_FREE %map_reg`
自底向上逐层释放所有叶节点及其所占堆内存。

### BTreeSet 宏
`BTreeSet` 就是包装了忽略 `%value` 参数的特化 B 树。提供了完全相同的插入、包含判定：
- `BTREESET_NEW %out_set`
- `BTREESET_INSERT %set_reg, %key_ptr`
- `BTREESET_CONTAINS %out_bool, %set_reg, %key_ptr`
- `BTREESET_FREE %set_reg`