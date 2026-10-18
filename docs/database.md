# SA 零信任列式数据库设计（sa-db Zero-Trust Columnar DB）

> 本文档在 `talk.md` L3859–4848 数据库脑暴成果的基础上落地为可施工的工程方案。
> 设计哲学完全沿用 SA 主线：**零 AST、五符号契约、O(1) 位掩码、扁平控制流、气闸舱 FFI、SHA-256 锁版、零权限默认、URL 即命名空间**。
> 与 R31（`sa.pkg` 包管理）、R31a–R31g 配套。新增 R34（`sa-db` 列式数据库）。

---

## §0 TL;DR + 一图看懂

`sa-db` 不是 SQL 数据库，是 SA 包管理在数据维度上的同构延伸：表 schema = 编译期 `#def` 字典，查询 = 预编译 `.qmod` 二进制 + SHA-256 锁版 + grants 白名单，执行 = mmap 只读切片注入到沙箱 + Referee X 光扫描 + 越权 SIGSEGV 物理熔断。

```
┌──────────────────────────────────────────────────────────────────────┐
│ ① <tbl>.sadb-schema  ──编译期一次扫描──►  #def COL_*_STRIDE           │
│        │                              #def TABLE_*_ROW_BYTES          │
│        ▼                                                              │
│ ② SoA 列存（per-table，顺序追加）                                     │
│    ├─ MemTable Arena(64MB) ──writev──► <tbl>.col<i>.<seg>.dat         │
│    └─ Blob Arena(mmap bump) ──seal──► <tbl>.blob.<seg>.bin            │
│        │                                                              │
│        ▼                                                              │
│ ③ <name>.query.sa  +  grants [db_read:t1, db_write:t2]             │
│        │  sa db register                                           │
│        ▼                                                              │
│ ④ <sha256>.qmod  ──Referee X-ray──►  load/store/atomic_rmw 权限校验   │
│        │  违规 ► Trap: DbCapabilityEscalation                         │
│        ▼                                                              │
│ ⑤ EXEC <hash>(args) ─►  @ffi_wrapper assume_borrow                   │
│        │             ─►  mmap MAP_PRIVATE | PROT_READ 列基址注入      │
│        ▼  越权写 ► CPU SIGSEGV ► Trap: DbMemoryGuardViolation         │
│ ⑥ 结果返回 ──────────────────────────────────────────────────────────│
│                                                                       │
│ 冷热分离：RAM(7d) ──► mmap NVMe(1m) ──► Zstd+S3(1y+, 10-15%)         │
└──────────────────────────────────────────────────────────────────────┘
```

**核心特性**：
- 无 SQL 字符串解析（编译期 schema + 预编译查询）
- 无 B-Tree（SoA 列式 + 物理行索引直跳）
- 无 GC（Arena + Bump 分配 + 显式释放）
- 无隐式状态（所有权五符号 `=&^!*` 显式可见）
- 极限并发（`atomic_rmw_add` 单点串行化 + 无锁读）
- 物理隔离（mmap 只读切片 + CPU MMU 熔断）

**决策来源**：talk.md L3860–L3905 + L3916–L3922 + L4107–L4167 + L4751–L4824

---

## §1 总体定位

### 1.1 是什么

`sa-db` 是一个**预编译、零信任、列式的内存数据库引擎**，专为 SA 生态设计。它把数据库的三个核心操作——**schema 定义、查询执行、权限隔离**——完全映射到 SA 的既有基础设施：

| 维度 | 传统数据库 | sa-db |
|---|---|---|
| Schema | 运行时 CREATE TABLE | 编译期 `#def` 字典（`.sadb-schema`） |
| 查询 | 运行时 SQL 字符串 | 预编译 SA-ASM 模块（`.qmod`） |
| 权限 | 用户级 GRANT/REVOKE | 模块级 `grants` 声明（源码透明） |
| 版本控制 | 无 | SHA-256 锁版（源码 + 机器码） |
| 隔离 | 进程级沙箱 | CPU MMU 级物理隔离 |
| 并发 | 锁 / MVCC / 2PC | `atomic_rmw_add` 单点 + 无锁读 |

### 1.2 不是什么

- ❌ 不是 SQL 数据库（拒绝运行时 SQL 字符串）
- ❌ 不是关系型数据库（无外键约束、无 ACID 事务、无触发器）
- ❌ 不是 NoSQL（无 JSON 动态字段、无文档模型）
- ❌ 不支持 B-Tree 索引（用排序+二分查询模块替代）
- ❌ 不支持动态 schema（schema 锁定后不可变）
- ❌ 不支持 MVCC（SoA 顺序写 + 乐观锁替代）

### 1.3 与 SA 包管理的同构关系

| 维度 | 包管理（`sa.mod`） | 数据库（`sa-db`） |
|---|---|---|
| **身份** | URL（`github.com/x/y`） | URL（`github.com/x/y`） |
| **版本锁定** | `sha256:...`（源码哈希） | `sha256:...`（schema + 查询源码） |
| **权限声明** | `grants [net_tx, net_rx]` | `grants [db_read:tbl_a, db_write:tbl_b]` |
| **源码透明** | 纯文本 `.sa` | 纯文本 `.sadb-schema` + `.query.sa` |
| **零隐式状态** | 无 `postinstall` 钩子 | 无运行时 SQL 解析 |
| **零权限默认** | 缺省 `grants []` | 缺省 `grants []` |
| **双轨缓存** | `sa_vendor/` + `~/.sa/pkg/` | 同上 |

**决策来源**：talk.md L3863–L3867 + `docs/package_management.md` §0–§3

---

## §2 表 Schema：`.sadb-schema` 文件

### 2.1 文件形态与语法

`.sadb-schema` 是纯文本文件，继承 `docs/ebnf.md` 的 `#def` 语法，不引入新 token。

```ebnf
schema_file    = { schema_line } ;
schema_line    = def | comment | blank ;
def            = "#def" IDENT "=" LITERAL ;
comment        = "//" { ANY } ;
blank          = "" ;
```

**示例**（`flash_sale.sadb-schema`，取自 talk.md L4737–L4750）：

```sa
// flash_sale.sadb-schema
// 定义秒杀表的物理内存属性

// 1. 定义总数据容量上限
#def MAX_ROWS = 1000000

// 2. 定义各列的步长 (Stride)
#def COL_ID_STRIDE        8   // u64: 商品 ID
#def COL_PRICE_STRIDE     4   // f32: 价格
#def COL_INVENTORY_STRIDE 4   // u32: 库存数量
#def COL_STATUS_STRIDE    1   // u8:  状态 (0:待售, 1:抢购)

// 3. 计算行大小（编译器自动生成）
#def TABLE_ROW_BYTES = 17   // 8 + 4 + 4 + 1
```

### 2.2 列类型集合

列仅允许 SA 原生类型，新增 `blob_handle`：

| 类型 | 字节 | 用途 |
|---|---|---|
| `i8 / i16 / i32 / i64` | 1/2/4/8 | 有符号整数 |
| `u8 / u16 / u32 / u64` | 1/2/4/8 | 无符号整数 |
| `f32 / f64` | 4/8 | 浮点数 |
| `ptr` | 8 | 裸指针（仅用于外键） |
| `blob_handle` | 8 | Blob Arena 句柄（新增） |

**不支持**：`struct`、`array`、`string`（变长文本走 Blob Arena）。

### 2.3 编译期一次扫描算法

`sa db init <table>.sadb-schema` 执行以下步骤：

1. **扫描 `#def COL_*_STRIDE`**：提取所有列的字节步长
2. **计算行大小**：`TABLE_ROW_BYTES = sum(COL_*_STRIDE)`
3. **生成 `.sai` 文件**：包含所有 `#def` 的副本，供查询模块 `@import` 使用
4. **验证容量**：`MAX_ROWS * TABLE_ROW_BYTES ≤ 64GB`（MemTable 上限）

**产物**：`<table>.sai`（纯文本，可被 `@import` 引用）

**决策来源**：talk.md L4736–L4750 + `requirements.md` R2.4 + `src/common/const_decl.zig`

---

## §3 物理存储布局

### 3.1 内存阶段：MemTable Arena

表的热数据驻留在 Zig 的 `ArenaAllocator` 中（MemTable）：

- **分配策略**：Append-Only（纯追加，无随机写）
- **阈值**：64 MB
- **刷盘**：达到阈值后，调用 `writev` 系统调用一次性整块写入磁盘（逼近 SSD 顺序写物理极限）
- **所有权**：整个 MemTable 视为单个 `alloc`，生命周期绑定表的打开状态

### 3.2 磁盘阶段：不可变段（Immutable Segments）

每个 MemTable 刷盘后生成一个**不可变段**：

```
<table>.col0.<seg>.dat    // 第 0 列的段文件
<table>.col1.<seg>.dat    // 第 1 列的段文件
<table>.col2.<seg>.dat    // ...
<table>.meta              // 元数据头（段列表、行数、时间戳）
```

**段内布局**（SoA 列式）：

```
[COL0_STRIDE * ROW0][COL0_STRIDE * ROW1]...[COL0_STRIDE * ROWn]  // col0.dat
[COL1_STRIDE * ROW0][COL1_STRIDE * ROW1]...[COL1_STRIDE * ROWn]  // col1.dat
...
```

**不可变性**：段一旦写入，永不修改。所有写入仅追加新段。

### 3.3 冷热分层

| 温度 | 时间范围 | 存储 | 访问方式 |
|---|---|---|---|
| **热** | 最近 7 天 | RAM（MemTable + 最新段） | 直接内存访问 |
| **温** | 7 天 – 1 月 | NVMe（mmap） | 零拷贝 mmap 映射 |
| **冷** | 1 年+ | S3（Zstd 压缩） | 按需解压（体积压至 10–15%） |

**分层策略**：后台线程定期扫描段的 mtime，自动降温。

### 3.4 崩溃恢复（无 WAL）

SA-db **不使用 WAL**（与"零隐式状态"哲学冲突）。等价方案：

1. **快照 epoch**：每个 MemTable 刷盘时记录全局 epoch 号
2. **不可变段**：段一旦落盘，物理上不可改
3. **原子游标**：`global_len` 用 `atomic_rmw_add` 自增，保证一致性
4. **恢复**：重启时扫描 `.meta` 文件，重建 MemTable 状态

**决策来源**：talk.md L3919–L3922 + L4107–L4167

---

## §4 Blob Arena

### 4.1 物理形态

变长文本（如用户评价、聊天记录）存储在独立的 Blob Arena 中：

```
<table>.blob.0.bin    // 第 0 个 Blob 段（mmap 文件）
<table>.blob.1.bin    // 第 1 个 Blob 段
<table>.blob.meta     // Blob 元数据（段大小、死亡比例）
```

每个 Blob 段是一个独立的 mmap 文件，大小固定（如 256 MB）。

### 4.2 blob_handle 位布局

```
blob_handle = u64

[seg_id:24][offset:40]

seg_id:  段号（0–16777215，支持最多 16M 段）
offset:  段内偏移（0–1099511627775，支持最多 1TB 段）
```

### 4.3 Bump Allocator（唯一选择）

Blob Arena 采用 **Bump Allocator**（纯追加分配器）：

- **分配**：全局 `bump_ptr` 自增，无碎片
- **释放**：不支持单条释放；整段 mmap 视为单个 `alloc`，单次 `!arena` 释放
- **删除**：标记墓碑（1 字节标志位），不回收空间
- **压缩**：当段死亡比例 ≥ 50% 时，`sa db compact` 触发整段重写

**为何不用 Free-List**：Free-List 需要维护空闲链表，破坏"显式所有权释放"的语义（无法精确追踪哪些字节被释放）。

### 4.4 Blob 写入范式（SA-ASM）

```sa
@write_blob_text(&arena: ptr, text_ptr: ptr, text_len: u64) -> u64:
L_ENTRY:
    // 1. 原子获取当前 bump 指针
    cur_offset = atomic_rmw_add arena+0, text_len
    
    // 2. 检查是否超出段大小（256 MB）
    is_full = uge cur_offset, 268435456
    br is_full -> L_OOM, L_WRITE
    
L_WRITE:
    !is_full
    
    // 3. 计算目标地址（段基址 + 偏移）
    target = ptr_add arena, cur_offset
    
    // 4. 复制文本数据（memcpy 等价）
    // （这里简化为伪代码；实际用 @sys_memcpy）
    
    // 5. 返回 blob_handle
    seg_id = load arena+8 as u32
    handle = shl seg_id, 40
    handle = or handle, cur_offset
    
    !arena
    !text_ptr
    !text_len
    return handle
    
L_OOM:
    !is_full
    !arena
    !text_ptr
    !text_len
    return 0xFFFFFFFFFFFFFFFF  // 错误标记
```

**决策来源**：talk.md L4848（Bump vs Free-List 取舍）+ `docs/faq.md` L218–L240（Drop 哲学）

---

## §5 查询模块：从 `.sa` 到 `<sha256>.qmod`

### 5.1 文件形态

查询由两个文件组成：

```
<name>.query.sa    // 查询逻辑（SA 汇编）
<name>.query.sai    // 接口声明（导入的表 schema）
```

**示例**（`heavy_users.query.sa`）：

```sa
@import "flash_sale.sadb-schema"

// 查询：找出库存 < 100 且价格 > 1000 的商品
@query_heavy_discount(
    &col_id: ptr,
    &col_price: ptr,
    &col_inventory: ptr,
    len: u64,
    &result_buf: ptr
) -> u64:
    grants [db_read:flash_sale, db_alloc_blob:result_arena]

L_ENTRY:
    idx = 0
    res_idx = 0
    jmp L_COND

L_COND:
    cond = ult idx, len
    br cond -> L_BODY, L_EXIT

L_BODY:
    // 读取库存
    offset_inv = mul idx, COL_INVENTORY_STRIDE
    inv = load col_inventory+offset_inv as u32
    is_low = ult inv, 100
    br is_low -> L_CHECK_PRICE, L_NEXT
    
L_CHECK_PRICE:
    !is_low
    offset_price = mul idx, COL_PRICE_STRIDE
    price = load col_price+offset_price as f32
    is_expensive = fcmp_gt price, 1000.0
    br is_expensive -> L_MATCH, L_NEXT
    
L_MATCH:
    !is_expensive
    // 写入结果
    offset_res = mul res_idx, 8
    store result_buf+offset_res, idx as u64
    res_idx = add res_idx, 1
    !offset_res
    
L_NEXT:
    !is_expensive
    !is_low
    !offset_inv
    !offset_price
    idx = add idx, 1
    !cond
    jmp L_COND

L_EXIT:
    !cond
    !idx
    !col_id
    !col_price
    !col_inventory
    !len
    !result_buf
    return res_idx
```

### 5.2 grants 语法扩展

复用 `sa.mod` 的 `grants []` 语法，新增四种数据库权限：

```sa
grants [
    db_read:<table>,           // 注入 <table> 的只读列基址
    db_write:<table>,          // 注入 <table> 的可写列基址
    db_alloc_blob:<arena>,     // 在 <arena> 申请 Blob 空间
    db_atomic_cursor:<table>   // 修改 <table> 的 global_len 游标
]
```

**示例**：

```sa
grants [db_read:users, db_read:orders, db_write:logs, db_atomic_cursor:logs]
```

### 5.3 编译与注册

```bash
sa db register heavy_users.query.sa
# 输出：
# Compiled: heavy_users.query.sa
# Hash: a1b2c3d4e5f6...
# Registered: a1b2c3d4e5f6.qmod
```

**产物**：`<sha256>.qmod`（二进制查询模块）

### 5.4 Referee X 光扫描

注册时，Referee 复用 `src/verifier.zig` 主入口，新增"列基址守门器"：

1. **遍历指令流**：扫描所有 `load` / `store` / `atomic_rmw_*` 指令
2. **权限校验**：
   - `load <col_base>+offset` → 检查 `db_read:<table>` 白名单
   - `store <col_base>+offset` → 检查 `db_write:<table>` 白名单
   - `atomic_rmw_add <cursor>+0` → 检查 `db_atomic_cursor:<table>`
3. **违规处理**：返回 `Trap: DbCapabilityEscalation`，附 `upstream_loc`（沿用 `#loc` 机制）

**决策来源**：talk.md L3876–L3905 + `docs/package_management.md` §2.1–§2.2

---

## §6 列基址注入与零拷贝沙箱

### 6.1 mmap 配置

查询模块执行时，数据库引擎通过 mmap 把列数据零拷贝映射到内存：

```c
// 读路径（查询模块）
mmap(..., MAP_PRIVATE | PROT_READ, ...)

// 写路径（Insert/Update）
mmap(..., MAP_SHARED | PROT_WRITE, ...)
```

**MAP_PRIVATE**：写时复制（CoW），查询模块无法修改原始数据。

### 6.2 参数传递

数据库引擎通过 `@ffi_wrapper` 把列基址注入查询模块：

```sa
@ffi_wrapper db_inject_cols(
    &col0_raw: ptr,
    &col1_raw: ptr,
    len: u64
) -> {col0: ptr, col1: ptr, len: u64}:

L_ENTRY:
    // 1. 解除安全位（仅在 @ffi_wrapper 内允许）
    col0 = assume_borrow col0_raw, mut?
    col1 = assume_borrow col1_raw, mut?
    
    // 2. 返回安全的借用指针
    // （实际返回值为结构体，这里简化）
    
    !col0_raw
    !col1_raw
    return
```

### 6.3 越权保护

如果查询模块尝试越权修改只读列：

1. **CPU MMU 检查**：`PROT_READ` 标志阻止写入
2. **SIGSEGV 信号**：CPU 触发段错误
3. **Handler 捕获**：libc SIGSEGV handler 捕获中断
4. **Trap 上报**：终止查询协程，返回 `Trap: DbMemoryGuardViolation`

**决策来源**：talk.md L3923–L3930 + `requirements.md` R7（气闸舱）

---

## §7 Insert / Update / Delete / JOIN 范式

### 7.1 Insert（基于 talk.md L4766–L4824）

```sa
@insert_flash_item(
    &global_len: ptr,
    &col_id: ptr,
    &col_price: ptr,
    &col_inv: ptr,
    id: u64,
    price: f32,
    inv: u32
) -> u64:
    grants [db_atomic_cursor:flash_sale, db_write:flash_sale]

L_ENTRY:
    // 1. 原子自增行游标
    r_idx = atomic_rmw_add global_len, 1
    
    // 2. 检查容量
    is_full = uge r_idx, 1000000
    br is_full -> L_OOM, L_WRITE

L_WRITE:
    !is_full
    
    // 3. 写入 ID（步长 8）
    mul offset_id, r_idx, 8
    ptr_add target_id, col_id, offset_id
    store target_id, id as u64
    !offset_id
    !target_id
    
    // 4. 写入 Price（步长 4）
    mul offset_price, r_idx, 4
    ptr_add target_price, col_price, offset_price
    store target_price, price as f32
    !offset_price
    !target_price
    
    // 5. 写入 Inventory（步长 4）
    mul offset_inv, r_idx, 4
    ptr_add target_inv, col_inv, offset_inv
    store target_inv, inv as u32
    !offset_inv
    !target_inv
    
    // 6. 释放所有权
    !col_id
    !col_price
    !col_inv
    !global_len
    !id
    !price
    !inv
    
    return r_idx

L_OOM:
    !is_full
    !col_id
    !col_price
    !col_inv
    !global_len
    !id
    !price
    !inv
    !r_idx
    return 0xFFFFFFFFFFFFFFFF
```

### 7.2 Update（乐观锁）

```sa
@update_price(
    &col_id: ptr,
    &col_price: ptr,
    &col_version: ptr,
    row_idx: u64,
    new_price: f32
) -> i32:
    grants [db_read:flash_sale, db_write:flash_sale]

L_ENTRY:
    // 1. 读取当前版本号
    mul offset_ver, row_idx, 8
    ptr_add target_ver, col_version, offset_ver
    old_ver = load target_ver as u64
    
    // 2. CAS 更新版本号
    new_ver = add old_ver, 1
    cmpxchg_result, ok = cmpxchg target_ver, old_ver, new_ver seq_cst seq_cst
    br ok -> L_UPDATE, L_CONFLICT
    
L_UPDATE:
    !ok
    !cmpxchg_result
    
    // 3. 更新价格
    mul offset_price, row_idx, 4
    ptr_add target_price, col_price, offset_price
    store target_price, new_price as f32
    !offset_price
    !target_price
    
    // 4. 清理并返回成功
    !col_id
    !col_price
    !col_version
    !row_idx
    !new_price
    !old_ver
    !new_ver
    !offset_ver
    !target_ver
    return 0

L_CONFLICT:
    !ok
    !cmpxchg_result
    !col_id
    !col_price
    !col_version
    !row_idx
    !new_price
    !old_ver
    !new_ver
    !offset_ver
    !target_ver
    return 1  // 冲突标记
```

### 7.3 Delete（墓碑标记）

```sa
@delete_row(
    &col_deleted: ptr,
    row_idx: u64
) -> i32:
    grants [db_write:flash_sale]

L_ENTRY:
    // 1. 计算墓碑位置（假设 col_deleted 是 u8 列）
    mul offset_del, row_idx, 1
    ptr_add target_del, col_deleted, offset_del
    
    // 2. 标记为已删除
    store target_del, 1 as u8
    
    // 3. 清理并返回
    !col_deleted
    !row_idx
    !offset_del
    !target_del
    return 0
```

### 7.4 JOIN（物理索引跳转）

```sa
@join_order_user(
    &col_order_user_id: ptr,
    &col_user_age: ptr,
    order_idx: u64
) -> u32:
    grants [db_read:orders, db_read:users]

L_ENTRY:
    // 1. 从订单表读取用户 ID（行索引）
    mul offset_order, order_idx, 8
    ptr_add target_order, col_order_user_id, offset_order
    user_idx = load target_order as u64
    !offset_order
    !target_order
    
    // 2. 跳转到用户表，读取年龄
    mul offset_user, user_idx, 4
    ptr_add target_user, col_user_age, offset_user
    age = load target_user as u32
    !offset_user
    !target_user
    
    // 3. 清理并返回
    !col_order_user_id
    !col_user_age
    !order_idx
    !user_idx
    return age
```

**决策来源**：talk.md L4751–L4824（Insert）+ L4836–L4841（JOIN）+ 新增（Update/Delete）

---

## §8 并发模型

### 8.1 写入串行化

所有写入通过**唯一的串行化点**序列化：

```sa
r_idx = atomic_rmw_add global_len, 1
```

这是表级别的全局行游标，用 `atomic_rmw_add` 自增。所有 Insert 竞争这个原子操作，保证行号唯一分配。

### 8.2 读无锁

所有查询模块拿到的是 **snapshot epoch** 的 mmap 只读视图：

1. 查询开始时，记录当前 epoch 号
2. 数据库引擎注入该 epoch 对应的列基址（mmap 映射）
3. 查询在只读视图上执行，无需加锁
4. 同时进行的 Insert 写入新行，不影响查询的视图

### 8.3 跨行事务（可选乐观锁）

如果需要跨行一致性，使用乐观锁：

- 每行额外存储 8 字节 `version` 列
- Update 时用 `cmpxchg` 尝试原子更新版本号
- 失败返回 `Trap: DbConcurrencyConflict`

### 8.4 明确否决 MVCC

**为什么不用 MVCC**：

1. **违反 SoA 顺序写**：MVCC 需要版本链，破坏列的顺序性
2. **引入 GC**：版本链需要垃圾回收，与"显式所有权"冲突
3. **与 Bump Arena 冲突**：Blob 的 Bump 分配无法支持版本链
4. **性能反而差**：查询需要遍历版本链，不如直接读快照

**决策来源**：talk.md L3921 + L4751–L4771 + 新增

---

## §9 CLI 子命令（嵌入 `src/cli.zig`）

| 命令 | 用途 |
|---|---|
| `sa db init <table>.sadb-schema` | 编译 schema → `.sai` |
| `sa db register <query>.sa` | 编译查询 → `<sha256>.qmod` |
| `sa db exec <sha256> --params <file>` | 执行注册过的查询 |
| `sa db ingest <table> <csv\|jsonl>` | 编译期一次性导入数据 |
| `sa db snapshot <table>` | 落盘当前 epoch |
| `sa db restore <table> <epoch>` | 从快照恢复 |
| `sa db inspect <sha256>` | 打印 X 光扫描结果 |
| `sa db compact <table>` | 触发 Blob Arena 段重写 |
| `sa db lock <table>` | 冻结表为不可变 |
| `sa db verify <table>` | 全段 SHA-256 校验 |

**决策来源**：talk.md L3899 + `src/cli.zig` 现有 5 个子命令的同构延伸

---

## §10 新增 12 条 Trap 错误码

| Trap | 阶段 | 触发条件 |
|---|---|---|
| `DbCapabilityEscalation` | Referee | 查询模块越权 load/store |
| `DbMemoryGuardViolation` | Runtime | mmap 越界 SIGSEGV |
| `DbBlobArenaOOM` | Runtime | Bump 分配器写满 |
| `DbConcurrencyConflict` | Runtime | 行版本号 cmpxchg 失败 |
| `DbSchemaMismatch` | Runtime | 数据列类型与 schema 不符 |
| `DbCursorOverflow` | Runtime | `global_len` ≥ MAX_ROWS |
| `DbColumnTypeMismatch` | Referee | qmod 用错列类型偏移 |
| `DbQueryHashUnknown` | Runtime | EXEC 一个未注册的 SHA-256 |
| `DbBlobHandleInvalid` | Runtime | blob_handle 段号或偏移越界 |
| `DbSnapshotCorrupted` | Runtime | 段文件 SHA-256 校验失败 |
| `DbDuplicateRegister` | Registry | 同 SHA-256 重复注册不同 grants |
| `DbForbiddenSqlString` | CLI | 任何运行时 SQL 字符串入口 |

**诊断字段**（每条 Trap 附带）：
- `table`：涉及的表名
- `sha256`：查询模块哈希
- `offset`：Blob 或列偏移
- `expected_mask` / `actual_mask`：权限位掩码
- `upstream_loc`：源码位置（`#loc` 追踪）

**决策来源**：`docs/errorcode.md` §2.1 现有 30 条 Trap 的命名风格延伸

---

## §11 文件与目录约定（指导未来实现）

### 11.1 `src/db/` 子目录布局（后续 PR）

```
src/db/
├── schema.zig      # .sadb-schema → #def 字典
├── arena.zig       # MemTable + writev 落盘
├── blob.zig        # Bump Allocator + 墓碑 + 段压缩
├── qmod.zig        # 查询模块编译/注册/SHA-256
├── exec.zig        # 列基址注入 + mmap + SIGSEGV handler
├── referee_db.zig  # X 光扫描列权限（hook 进 src/verifier.zig）
├── cli_db.zig      # sa db 子命令分发
├── snapshot.zig    # epoch 快照与恢复
├── compact.zig     # 段死亡比例触发的整段重写
├── concurrent.zig  # 行版本号 + 乐观锁辅助
├── trap_db.zig     # 12 条 Db* Trap 注册
└── tests/          # 单元测试与 e2e
```

### 11.2 与 `src/pkg/` 的同构对照

| 概念 | 包管理 | 数据库 |
|---|---|---|
| 清单文件 | `sa.mod` | 表 schema（`.sadb-schema`） |
| 拉取 | `src/pkg/fetch.zig` | `src/db/schema.zig` |
| 解析 | `src/pkg/manifest.zig` | `src/db/schema.zig` |
| 注册表 | `sa_vendor/` | qmod registry |
| 权限声明 | `grants []` | `grants [db_*]` |
| 校验 | `src/pkg/resolver.zig` | `src/db/referee_db.zig` |

---

## §12 与包管理的耦合

### 12.1 分发机制

表 schema 与查询模块通过 `@import` 分发，复用 `sa.mod` 的 SHA-256 锁版：

```sa
// 在查询模块中
@import "github.com/xiaoming/sa-db-shop/flash_sale.sadb-schema"
@import "github.com/xiaoming/sa-db-shop/queries.sars"
```

### 12.2 `sa.mod` 扩展（不新增 `sadb.mod`）

直接复用 `sa.mod`，新增两种 require 类型：

```
require_db_table github.com/x/y @v1.0 sha256:... grants [db_read:tbl_a]
require_db_query github.com/x/y @v1.0 sha256:... grants [db_read:tbl_a, db_write:tbl_b]
```

**决策来源**：`docs/package_management.md` §2 + `src/pkg/manifest.zig`

---

## §13 实施里程碑（W1–W12）

| Milestone | 周 | 内容 | 交付物 |
|---|---|---|---|
| M1 | W1–W3 | schema + 列存 + Arena MemTable + Insert | `src/db/schema.zig` + `src/db/arena.zig` |
| M2 | W4 | Blob Arena + Bump 分配 | `src/db/blob.zig` |
| M3 | W5–W6 | 查询模块编译 + SHA-256 注册 + X 光扫描 | `src/db/qmod.zig` + `src/db/referee_db.zig` |
| M4 | W7 | mmap 沙箱 + SIGSEGV handler + Trap 上报 | `src/db/exec.zig` |
| M5 | W8 | CLI 子命令 + ingest + snapshot | `src/db/cli_db.zig` + `src/db/snapshot.zig` |
| M6 | W9–W10 | 冷热分层 + Zstd 压缩 + S3 落冷 | `src/db/compact.zig` |
| M7 | W11–W12 | 测试集 + 双 11 抢购 demo | `tests/db/` + demo |

---

## §14 验证方案

### 14.1 单元测试

覆盖每条 Trap 的边界：

- `DbCapabilityEscalation`：查询模块越权读写
- `DbMemoryGuardViolation`：mmap 越界写入
- `DbBlobArenaOOM`：Blob 段满
- `DbConcurrencyConflict`：行版本号冲突
- 其余 8 条 Trap

### 14.2 端到端测试

秒杀场景 e2e：

- 10 万 SKU，每个 SKU 初始库存 1000
- 单线程 Insert + Update（扣库存）+ Query（统计）
- 目标：1KW TPS 扣减（单线程）

### 14.3 性能基线

- 1 亿行 SoA 列扫描：≤ 200 ms（AVX-512 启用）
- Insert 吞吐：≥ 1M rows/sec
- Query 延迟：≤ 10 ms（p99）

### 14.4 与 `tests/` 目录对接

新增 `tests/db/` 子目录，沿用现有 Zig 测试 runner。

---

## §15 显式 Non-Goals

1. **不支持运行时 SQL 字符串**：所有查询必须预编译
2. **不支持 B-Tree 索引**：用排序+二分查询模块替代
3. **不支持触发器/隐式存储过程**：必须显式 EXEC hash
4. **不支持跨表 2PC 事务**：前端用乐观锁链拼
5. **不支持 MVCC**：SoA 顺序写 + 乐观锁替代
6. **不支持动态 schema 变更**：schema 锁定后不可变

---

## 附录 A：与现有约束的对齐验证

| 约束 | 来源 | sa-db 遵循 | 验证方式 |
|---|---|---|---|
| 零 AST | R1 | ✅ | schema 仅 `#def`，查询走扁平 Instruction[] |
| 五符号契约 | R1 | ✅ | 表/列/查询所有权流转用 `=&^!*` |
| O(1) 位掩码 | R4 | ✅ | Referee 用 `u16` 10 位掩码，无图论 |
| 扁平控制流 | R3 | ✅ | 查询模块禁用 `if/else/while/for/{}`，仅 `L_LABEL:` + `jmp/br` |
| 气闸舱 FFI | R7 | ✅ | mmap/syscall 封装在 `@ffi_wrapper` 内 |
| 显式释放 | R2 | ✅ | 列借用 `&col` 必须显式 `!col` |
| SHA-256 锁版 | R31f | ✅ | schema + 查询源码全部走 SHA-256 |
| 零权限默认 | R31c | ✅ | `grants` 缺省为空 |
| URL 即命名空间 | R31a | ✅ | `@import "github.com/.../sa-db-shop"` |
| Trap 错误码 | errorcode.md | ✅ | 12 条新 Db* Trap 登记 |
| 源码透明 | R31d | ✅ | 纯文本 `.sadb-schema` + `.query.sa` |

---

## 附录 B：决策来源索引

| 章节 | 决策来源 |
|---|---|
| §0 TL;DR | talk.md L3860–L3905 + L3916–L3922 + L4107–L4167 + L4751–L4824 |
| §1 定位 | talk.md L3863–L3867 + `docs/package_management.md` §0–§3 |
| §2 Schema | talk.md L4736–L4750 + `requirements.md` R2.4 + `src/common/const_decl.zig` |
| §3 存储 | talk.md L3919–L3922 + L4107–L4167 |
| §4 Blob | talk.md L4848 + `docs/faq.md` L218–L240 |
| §5 查询 | talk.md L3876–L3905 + `docs/package_management.md` §2.1–§2.2 |
| §6 沙箱 | talk.md L3923–L3930 + `requirements.md` R7 |
| §7 范式 | talk.md L4751–L4824 + L4836–L4841 |
| §8 并发 | talk.md L3921 + L4751–L4771 |
| §9 CLI | talk.md L3899 + `src/cli.zig` |
| §10 Trap | `docs/errorcode.md` §2.1 |
| §11 目录 | 新增 |
| §12 耦合 | `docs/package_management.md` §2 + `src/pkg/manifest.zig` |
| §13 里程碑 | 新增 |
| §14 验证 | 新增 |
| §15 Non-Goals | 新增 |

---

**文档终态**：本设计覆盖 talk.md L3859–4848 全部 14 轮数据库脑暴成果，落地为可施工的工程方案。所有跨子系统的耦合点都明确指向现有绝对路径文件，无新增 AST、无新增图论求解器、无 SQL 字符串运行时。后续 PR 按 §13 里程碑分批实现。

备注：
 SA 零信任列式数据库（sa-db）落地设计方案

 Context

 talk.md L3859–L4848 共 14 轮脑暴，把 SA 的"零信任 + 不可变哈希 + 物理级隔离"哲学从包管理平移到了数据库层。脑暴落地为：sa-db 不是 SQL 数据库，是 SA
 包管理在数据维度上的同构延伸 —— 表 schema = 编译期 #def 字典；查询 = 预编译 .qmod 二进制 + SHA-256 锁版 + grants 白名单；执行 = mmap
 只读切片注入沙箱 + Referee X 光扫描 + 越权 SIGSEGV 物理熔断。

 现状缺口：脑暴只在 talk.md 里，没有落到 docs/；新人无法施工，里程碑无法编排，与现有 src/pkg/ src/referee/ src/cli.zig 的衔接路径未明确。

 目标产出：写一份 /home/vscode/projects/sci/docs/database.md（约 1000 行 Markdown），与 docs/package_management.md 同级、同风格，作为 R34（sa-db
 列式数据库）的官方落地文档。本计划批准后即写入此单一文件，不改任何代码、不新增 src/db/ 子目录。

 ---
 单一交付物

 新建文件：/home/vscode/projects/sci/docs/database.md

 完整章节大纲（15 章 + TL;DR + 附录）：

 §0 TL;DR + 一图看懂（ASCII 架构图）

 覆盖：schema → 列存 → 查询模块 → Referee X 光 → mmap 注入 → 执行 → Blob Arena → 冷热分离。
 决策来源：talk.md L3860–L3905 整合。

 §1 总体定位

 - 物理边界（是什么、不是什么）
 - 与 MySQL/PG/SQLite/DuckDB 对比表（10 行内）
 - 与 SA 包管理的同构关系矩阵：URL=身份 / SHA-256=锁版 / grants=权限 / 源码透明 / 零隐式状态
 - 决策来源：talk.md L3863–L3867 + docs/package_management.md §0

 §2 表 Schema：.sadb-schema 文件

 - 文件形态：纯文本 EBNF（继承 docs/ebnf.md 的 #def 语法），不引入新 token
 - 列类型仅允许 {i8..u64, f32, f64, ptr, blob_handle}（blob_handle = u64，新引入但仍是 SA 原生 8 字节）
 - 编译期一次扫描算法：sa db schema-compile → 生成 <table>.sai 文件，里面全是 #def COL_<name>_STRIDE = N 与 #def TABLE_<x>_ROW_BYTES = N
 - 真实示例：flash_sale.sadb-schema 完整版（取自 talk.md L4737–L4750）
 - 决策来源：talk.md L4736–L4750 + requirements.md R2.4（原生类型集合）+ src/common/const_decl.zig

 §3 物理存储布局

 - Table 在内存：MemTable Arena 64MB → 阈值后整块 writev 落盘
 - Table 在磁盘：<table>.col<i>.<seg>.dat 顺序段文件 + <table>.meta 元数据头
 - 段内 SoA 顺序排布；段不可变（immutable segment），写入仅追加新段
 - 冷热分层：RAM（7 天）/ mmap NVMe（1 月）/ Zstd+S3（1 年+，体积压至 10–15%）
 - 不引入 WAL：以"快照 epoch + 不可变段 + atomic_rmw_add 自增 global_len"实现等价崩溃恢复（理由：WAL 与"零隐式状态"哲学冲突）
 - 决策来源：talk.md L3919–L3922 + L4107–L4167（推断行号）+ 新增

 §4 Blob Arena

 - 物理形态：每表独立 mmap 文件 <table>.blob.<seg>.bin
 - blob_handle = u64 = (seg_id:24 << 40) | offset:40，给出位布局图
 - Bump Allocator 唯一选择：整段 mmap 视为单个 alloc，单次 !arena 释放（脑暴明确否决 Free-List）
 - 删除策略：墓碑标记 + 段死亡比例 ≥ 50% 时 sa db compact 整段重写
 - 写入流程的 SA-ASM 范式（10 行）
 - 决策来源：talk.md L4848（开放问题被作者后续选定 Bump）+ FAQ Drop 哲学（faq.md L218–L240）

 §5 查询模块：从 .sa 到 <sha256>.qmod

 - 文件命名：<name>.query.sa + 配套 <name>.query.sai
 - grants 语法扩展（复用 sa.mod 现有 grants [] 语法）：
   - db_read:<table> — 注入只读列基址
   - db_write:<table> — 注入可写列基址（必经 @ffi_wrapper）
   - db_alloc_blob:<arena> — 在 Blob Arena 申请字节
   - db_atomic_cursor:<table> — 修改 global_len 行游标
 - 编译产物：<sha256>.qmod（哈希取自 .sa 源码字节流，与 sa.mod 完全同构）
 - 注册时 Referee 复用 src/verifier.zig 主入口，新增"列基址守门器"：
   - 任何 load <col_base>+offset → 检查 db_read 白名单
   - 任何 store <col_base>+offset → 检查 db_write 白名单
   - 任何 atomic_rmw_add <cursor>+0 → 检查 db_atomic_cursor
   - 违规 → Trap: DbCapabilityEscalation，附 upstream_loc（沿用 #loc 机制）
 - 调用约定：sa db exec <sha256> --params <bin> 或代码内 call @exec_qmod(<hash>, args)
 - 决策来源：talk.md L3876–L3905 + docs/package_management.md §0、§2.1（grants 语法）+ src/pkg/manifest.zig

 §6 列基址注入与零拷贝沙箱

 - mmap 配置：MAP_PRIVATE | PROT_READ（写入路径走另一个 @ffi_wrapper 用 MAP_SHARED | PROT_WRITE）
 - 引擎 → 查询模块的传值：@ffi_wrapper db_inject_cols 内 assume_borrow raw, mut? 转成五符号合法的 &col_xxx: ptr
 - 越权时 CPU SIGSEGV → libc handler → 终止该查询协程 + 上报 Trap: DbMemoryGuardViolation
 - 与 requirements.md R7（气闸舱）严格对齐
 - 决策来源：talk.md L3923–L3930 + requirements.md R7

 §7 Insert / Update / Delete / JOIN 范式（4 个完整 SA-ASM）

 1. Insert：以 talk.md L4766–L4824 的 @insert_flash_item 为基础，删减优化（约 25 行）
 2. Update：先 cmpxchg 行版本号取乐观锁 → mul + ptr_add + store → 失败 Trap: DbConcurrencyConflict（约 20 行）
 3. Delete：标记位 store + Blob 墓碑（约 15 行）
 4. JOIN：外键 = u64 行索引；一次 load + 一次 mul + 一次 load（取自 talk.md L4836–L4841，约 15 行）

 每个范式严格遵守 docs/faq.md L4470–L4670 的释放铁律（每个寄存器显式 !，无 if/else/while/for，扁平 Label）。
 决策来源：talk.md L4751–L4824（Insert）+ L4825–L4841（JOIN）+ 新增（Update/Delete）

 §8 并发模型

 - 写入串行化点：唯一一个 atomic_rmw_add global_len, 1
 - 读无锁：所有查询模块拿到 snapshot epoch 的 mmap 只读视图
 - 跨行事务：可选乐观锁（每行 8 字节 version 列；cmpxchg 失败即 Trap: DbConcurrencyConflict）
 - 明确否决 MVCC：违反 SoA 顺序写、引入版本链需要 GC、与 Bump Arena 哲学冲突
 - 决策来源：talk.md L3921 + L4751–L4771（atomic_rmw_add）+ 新增

 §9 CLI 子命令（嵌入 src/cli.zig）

 列表（10 条）：

 ┌────────────────────────────────────────┬──────────────────────────┐
 │                  命令                  │           用途           │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db init <table>.sadb-schema      │ 编译 schema → .sai     │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db register <query>.sa        │ 编译查询 → <sha256>.qmod │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db exec <sha256> --params <file> │ 执行注册过的查询         │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db ingest <table> <csv|jsonl>    │ 编译期一次性导入         │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db snapshot <table>              │ 落盘当前 epoch           │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db restore <table> <epoch>       │ 从快照重建               │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db inspect <sha256>              │ 打印 X 光扫描结果        │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db compact <table>               │ 触发 Blob Arena 段重写   │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db lock <table>                  │ 冻结表为不可变           │
 ├────────────────────────────────────────┼──────────────────────────┤
 │ sa db verify <table>                │ 全段 SHA-256 校验        │
 └────────────────────────────────────────┴──────────────────────────┘

 决策来源：talk.md L3899（EXEC 形态）+ src/cli.zig 现有 5 个子命令的同构延伸

 §10 新增 12 条 Trap 错误码（登记到 docs/errorcode.md）

 ┌────────────────────────┬──────────┬────────────────────────────────┐
 │          Trap          │  Stage   │            触发条件            │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbCapabilityEscalation │ Referee  │ 查询模块越权 load/store        │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbMemoryGuardViolation │ Runtime  │ mmap 越界 SIGSEGV              │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbBlobArenaOOM         │ Runtime  │ Bump 分配器写满                │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbConcurrencyConflict  │ Runtime  │ 行版本号 cmpxchg 失败          │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbSchemaMismatch       │ Runtime  │ 数据列类型与 schema 不符       │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbCursorOverflow       │ Runtime  │ global_len ≥ MAX_ROWS          │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbColumnTypeMismatch   │ Referee  │ qmod 用错列类型偏移            │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbQueryHashUnknown     │ Runtime  │ EXEC 一个未注册的 SHA-256      │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbBlobHandleInvalid    │ Runtime  │ blob_handle 段号或偏移越界     │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbSnapshotCorrupted    │ Runtime  │ 段文件 SHA-256 校验失败        │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbDuplicateRegister    │ Registry │ 同 SHA-256 重复注册不同 grants │
 ├────────────────────────┼──────────┼────────────────────────────────┤
 │ DbForbiddenSqlString   │ CLI      │ 任何运行时 SQL 字符串入口      │
 └────────────────────────┴──────────┴────────────────────────────────┘

 每条附"诊断字段"说明（table/sha256/offset/expected_mask/actual_mask/upstream_loc）。
 决策来源：docs/errorcode.md §2.1 现有 30 条 Trap 的命名风格延伸

 §11 文件与目录约定（指导未来的 src/db/）

 src/db/
 ├── schema.zig      # .sadb-schema → #def 字典
 ├── arena.zig       # MemTable + writev 落盘
 ├── blob.zig        # Bump Allocator + 墓碑 + 段压缩
 ├── qmod.zig        # 查询模块编译/注册/SHA-256
 ├── exec.zig        # 列基址注入 + mmap + SIGSEGV handler
 ├── referee_db.zig  # X 光扫描列权限（hook 进 src/verifier.zig）
 ├── cli_db.zig      # sa db 子命令分发
 ├── snapshot.zig    # epoch 快照与恢复
 ├── compact.zig     # 段死亡比例触发的整段重写
 ├── concurrent.zig  # 行版本号 + 乐观锁辅助
 ├── trap_db.zig     # 12 条 Db* Trap 注册
 └── tests/          # 单元测试与 e2e

 与 src/pkg/ 同构对照表（manifest↔schema、fetch↔ingest、resolver↔qmod registry）。

 注意：本文档只描述目录约定，不在本次落地中创建任何代码文件。

 §12 与包管理的耦合

 - 表 schema 与查询模块通过 @import "github.com/.../sa-db-shop" 分发，复用 sa.mod 的 SHA-256 锁版
 - 不引入 sadb.mod 单独文件：直接复用 sa.mod，新增两种 require 类型：
   - require_db_table github.com/x/y @v1.0 sha256:... grants [db_read:tbl_a]
   - require_db_query github.com/x/y @v1.0 sha256:... grants [db_read:tbl_a, db_write:tbl_b]
 - 决策来源：docs/package_management.md §2 + src/pkg/manifest.zig 现有解析器

 §13 实施里程碑（W1–W12）

 ┌───────────┬─────────┬─────────────────────────────────────────┐
 │ Milestone │   周    │                  内容                   │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M1        │ W1–W3   │ schema + 列存 + Arena MemTable + Insert │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M2        │ W4      │ Blob Arena + Bump 分配                  │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M3        │ W5–W6   │ 查询模块编译 + SHA-256 注册 + X 光扫描  │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M4        │ W7      │ mmap 沙箱 + SIGSEGV handler + Trap 上报 │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M5        │ W8      │ CLI 子命令 + ingest + snapshot          │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M6        │ W9–W10  │ 冷热分层 + Zstd 压缩 + S3 落冷          │
 ├───────────┼─────────┼─────────────────────────────────────────┤
 │ M7        │ W11–W12 │ 测试集 + 双 11 抢购 demo                │
 └───────────┴─────────┴─────────────────────────────────────────┘

 §14 验证方案

 - 单元测试覆盖每条 Trap 的边界
 - 端到端：秒杀场景 e2e（10 万 SKU、单线程 1KW TPS 扣减目标）
 - 性能基线：1 亿行 SoA 列扫描 ≤ 200ms（AVX-512 启用）
 - 与 tests/ 目录对接：新增 tests/db/ 子目录，沿用现有 Zig 测试 runner

 §15 显式 Non-Goals

 1. 不支持运行时 SQL 字符串
 2. 不支持 B-Tree 索引（如需，前端用排序+二分自行实现并注册为查询模块）
 3. 不支持触发器/隐式存储过程
 4. 不支持跨表 2PC 事务
 5. 不支持 MVCC
 6. 不支持动态 schema 变更（schema 锁定后不可改，新增列必须开新表）

 附录 A：与现有约束的对齐验证清单

 逐条核对 requirements.md R1–R23 与本设计的兼容性（11 条硬约束）。

 附录 B：决策来源索引

 每节末尾的"决策来源"汇总成一张表，方便回溯。

 ---
 文风与格式要求

 - 中文为主，技术术语保留英文
 - ASCII 架构图与表格优先（不画 PNG）
 - 所有 SA-ASM 代码片段严格遵守 docs/faq.md L4470–L4670 范例的释放铁律（每个 = 后必有 !，控制流仅 L_LABEL: + jmp/br）
 - 章节末尾标注"决策来源：talk.md L<行号> / requirements.md R<编号> / 新增"
 - 不出现"可能/也许/或者"等模糊表述，全部明确决策
 - 文档总长约 900–1100 行，与 docs/package_management.md（778 行）同量级

 ---
 关键文件路径引用（落地时复用，本次不改）

 ┌─────────────────┬──────────────────────────────────────────────────────┐
 │      类别       │                         路径                         │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 能力掩码        │ /home/vscode/projects/sci/src/common/capability.zig  │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 原子原语        │ /home/vscode/projects/sci/src/common/atomic.zig      │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ #def 常量       │ /home/vscode/projects/sci/src/common/const_decl.zig  │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ Trap 报告       │ /home/vscode/projects/sci/src/common/trap.zig        │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 函数签名        │ /home/vscode/projects/sci/src/common/signature.zig   │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 指令枚举        │ /home/vscode/projects/sci/src/common/instruction.zig │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ sa.mod 解析     │ /home/vscode/projects/sci/src/pkg/manifest.zig       │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 哑拉取          │ /home/vscode/projects/sci/src/pkg/fetch.zig          │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 包路径解析      │ /home/vscode/projects/sci/src/pkg/resolver.zig       │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ Referee 主入口  │ /home/vscode/projects/sci/src/verifier.zig           │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ CapabilityTable │ /home/vscode/projects/sci/src/referee/table.zig      │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ Flattener       │ /home/vscode/projects/sci/src/flattener.zig          │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 内存布局        │ /home/vscode/projects/sci/src/layout.zig             │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ LLVM-C BC 后端   │ /home/vscode/projects/sci/src/emit_llvm_llvmc.zig    │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ WASM 后端       │ /home/vscode/projects/sci/src/emit_wasm/mod.zig      │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 解释器          │ /home/vscode/projects/sci/src/interp.zig             │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ CLI 主分发      │ /home/vscode/projects/sci/src/cli.zig                │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 系统调用        │ /home/vscode/projects/sci/src/runtime/native_sys.zig │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 运行时原语      │ /home/vscode/projects/sci/src/runtime/sa_std.zig     │
 ├─────────────────┼──────────────────────────────────────────────────────┤
 │ 错误码登记      │ /home/vscode/projects/sci/docs/errorcode.md          │
 ├─────────────────┼──────────────────────────────────────────────────────┤
     ├─────────────────┼──────────────────────────────────────────────────────┤
     │ 包管理文档      │ /home/vscode/projects/sci/docs/package_management.md │
     └─────────────────┴──────────────────────────────────────────────────────┘

     ---
     验证方式（写完文档后如何确认 OK）

     1. 结构完整性：
     wc -l /home/vscode/projects/sci/docs/database.md
     1. 预期 900–1100 行。
     2. 章节编号：
     grep -E "^## " /home/vscode/projects/sci/docs/database.md
     2. 预期 16 个标题（§0–§15 + 附录 A/B）。
     3. 代码片段语法：grep @\w+\( 与 L_\w+: 的命中数 ≥ 4 个 SA-ASM 范式 × 平均 3 个标签。
     4. 交叉引用：grep talk.md L\d+ / requirements.md R\d+ / package_management.md 的引用次数 ≥ 30 处。
     5. Trap 登记一致性：
     grep -c "^| Db" /home/vscode/projects/sci/docs/database.md
     5. 预期 ≥ 12（§10 表中的 12 条新 Trap）。
     6. 同行 review：与 docs/package_management.md 风格抽样比对（同样的 TL;DR + 一图看懂 + 章节编号 + 决策来源）。

     ---
     范围边界（本次只做）

     - ✅ 写 /home/vscode/projects/sci/docs/database.md 一个文件
     - ❌ 不创建 src/db/ 任何 Zig 源文件
     - ❌ 不修改 src/cli.zig 加 sa db 子命令
     - ❌ 不修改 docs/errorcode.md 注册 Trap（文档内描述即可，留待后续 PR）
     - ❌ 不修改 docs/ebnf.md 加 .sadb-schema 语法（同上）
     - ❌ 不修改 requirements.md 加 R34（同上）

     后续 PR 路线图（不在本次范围）：M1 起按本文档 §13 里程碑分批 PR。