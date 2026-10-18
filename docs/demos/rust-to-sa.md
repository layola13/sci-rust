# Rust → SA 降级对照全集（v0.2 规范严格版）

> 本文档严格按照 `.kiro/specs/sa-asm-language/` 下的 **requirements.md（R1–R24）** 与 **design.md** 规范。
>
> **关键约束**（R5.2 / R5.8 / R5.9）：
> - SA 语法层**只有 `&`**（借用），**没有 `&mut`**
> - 共享读 vs 独占写由 Referee 的 `Locked_Read` / `Locked_Mut` 位掩码在**调用方上下文**内动态决定
> - 凡 `&` / `^` 前缀参数，`ty` **必须是 `ptr`**
> - 按值传递（无前缀）才能用原生数值类型 `i32` / `f32` / `u64` 等
> - 用户自定义类型名（如 `Vec3` / `Slice`）**只活在 `#def` 注释里**，不出现在函数签名中
> - `@const` **无类型标注**，字节长度由字面量推断
>
> 每个 SA 示例伪装为前端已完成词法作用域跟踪与隐式 Drop 插入后的产物（R20 合约）。

---

## 1. 变量与算术 ✅

### Rust
```rust
fn sum(a: i32, b: i32) -> i32 {
    let c = a + b;
    let d = c * 2;
    d
}
```

### SA
```
@sum(a: i32, b: i32) -> i32:
L_ENTRY:
    c = add a, b
    d = mul c, 2
    return d
```

---

## 2. 条件与循环 ✅

### Rust
```rust
fn abs_sum(arr: &[i32]) -> i32 { /* while + if/else */ }
```

### SA
```
// Slice 布局: [data_ptr(8) | len(8)] = 16 bytes
#def Slice_data = +0
#def Slice_len  = +8
#def I32_SIZE   = 4

@abs_sum(arr: &ptr) -> i32:          // &ptr: 借用一个指向 Slice 布局的内存块
L_ENTRY:
    sum = 0
    i = 0
    len = load arr+Slice_len as u64
    jmp L_COND

L_COND:
    cond = ult i, len
    br cond -> L_BODY, L_END

L_BODY:
    data_base = load arr+Slice_data as ptr
    offset    = mul i, I32_SIZE
    data_ip   = ptr_add data_base, offset    // InteriorPtr
    v         = load data_ip+0 as i32

    neg = slt v, 0
    br neg -> L_NEG, L_POS

L_POS:
    sum = add sum, v
    jmp L_NEXT

L_NEG:
    sum = sub sum, v
    jmp L_NEXT

L_NEXT:
    i = add i, 1
    jmp L_COND

L_END:
    return sum
```

---

## 3. 所有权 Move ✅

### Rust
```rust
struct Data { v: i32 }
fn consume(d: Data) {}
fn main() { let x = Data { v: 10 }; consume(x); }
```

### SA
```
#def Data_SIZE = 4
#def Data_v    = +0

@consume(^d: ptr):                    // ^ptr: Move 进来
L_ENTRY:
    !d
    return

@main:
L_ENTRY:
    x = alloc Data_SIZE
    store x+Data_v, 10 as i32
    call @consume(^x)
    return
```

---

## 4. 共享借用 `&` ✅

### Rust
```rust
fn read_only(r: &i32) -> i32 { *r + 100 }
```

### SA
```
@read_only(r: &ptr) -> i32:          // &ptr: 借用指向 i32 的内存
L_ENTRY:
    v = load r+0 as i32
    res = add v, 100
    return res

@main:
L_ENTRY:
    x = stack_alloc 4
    store x+0, 42 as i32

    r1 = &x
    y = call @read_only(&r1)
    !r1

    r2 = &x
    z = call @read_only(&r2)
    !r2

    return
```

---

## 5. 独占借用 `&mut` ✅

### Rust
```rust
fn increment(r: &mut i32) { *r += 1; }
```

### SA
```
// SA 没有 &mut 语法。独占借用由调用方上下文决定：
// 当源寄存器只有一个借用且该借用会写入时，Referee 自动标记 Locked_Mut。
@increment(r: &ptr):                  // &ptr: 借用（Referee 内部标 Locked_Mut）
L_ENTRY:
    v  = load r+0 as i32
    v2 = add v, 1
    store r+0, v2 as i32
    return

@main:
L_ENTRY:
    x = stack_alloc 4
    store x+0, 10 as i32

    r = &x                            // Referee: x → Locked_Mut（因为 r 会 store）
    call @increment(&r)
    !r                                // 解锁 x

    y = load x+0 as i32
    return
```

**关键**：SA 语法层只有 `&`。Rust 的 `&mut` 在 SA 里通过 Referee 的 `Locked_Mut` 位掩码实现——当借用视图对源内存执行 `store` 时，Referee 自动将源寄存器从 `Locked_Read` 升级为 `Locked_Mut`（若已有其它读借用则 Trap `ReadWriteConflict`）。前端不需要在签名上区分。

---

## 6. 结构体（字段偏移） ✅

### Rust
```rust
struct Vec3 { x: f32, y: f32, z: f32 }
fn length_sq(v: &Vec3) -> f32 { v.x*v.x + v.y*v.y + v.z*v.z }
```

### SA
```
#def Vec3_SIZE = 12
#def Vec3_x    = +0
#def Vec3_y    = +4
#def Vec3_z    = +8

@length_sq(v: &ptr) -> f32:          // &ptr: 借用指向 Vec3 布局的 12 字节块
L_ENTRY:
    x  = load v+Vec3_x as f32
    y  = load v+Vec3_y as f32
    z  = load v+Vec3_z as f32
    xx = fmul x, x
    yy = fmul y, y
    zz = fmul z, z
    t  = fadd xx, yy
    res = fadd t, zz
    return res
```

---

## 7. 数组索引（InteriorPtr） ✅

### Rust
```rust
fn get_or_zero(arr: &[i32], i: usize) -> i32 {
    if i < arr.len() { arr[i] } else { 0 }
}
```

### SA
```
#def Slice_data = +0
#def Slice_len  = +8
#def I32_SIZE   = 4

@get_or_zero(arr: &ptr, i: u64) -> i32:
L_ENTRY:
    len = load arr+Slice_len as u64
    ok = ult i, len
    br ok -> L_READ, L_ZERO

L_READ:
    data_base = load arr+Slice_data as ptr
    offset    = mul i, I32_SIZE
    data_ip   = ptr_add data_base, offset
    v         = load data_ip+0 as i32
    return v

L_ZERO:
    return 0
```

---

## 8. 字符串（胖指针 UTF-8） ⚠️

### Rust
```rust
fn count_a(s: &str) -> u64 { s.bytes().filter(|&b| b == b'a').count() as u64 }
```

### SA
```
#def Str_data = +0
#def Str_len  = +8
#def CHAR_a   = 97

@count_a(s: &ptr) -> u64:            // &ptr: 借用指向 Str 布局 [data(8)|len(8)]
L_ENTRY:
    data = load s+Str_data as ptr
    len  = load s+Str_len  as u64
    count = 0
    i = 0
    jmp L_COND

L_COND:
    cond = ult i, len
    br cond -> L_BODY, L_END

L_BODY:
    cur  = ptr_add data, i
    b    = load cur+0 as u8
    is_a = eq b, CHAR_a
    br is_a -> L_HIT, L_NEXT

L_HIT:
    count = add count, 1
    jmp L_NEXT

L_NEXT:
    i = add i, 1
    jmp L_COND

L_END:
    return count
```

---

## 9. Vec<T>（胖指针容器） ⚠️

### SA
```
#def Vec_data  = +0
#def Vec_len   = +8
#def I32_SIZE  = 4

@sum_vec(v: &ptr) -> i32:            // &ptr: 借用指向 Vec 布局 [data(8)|len(8)|cap(8)]
L_ENTRY:
    data = load v+Vec_data as ptr
    len  = load v+Vec_len  as u64
    s = 0
    i = 0
    jmp L_COND

L_COND:
    cond = ult i, len
    br cond -> L_BODY, L_END

L_BODY:
    off  = mul i, I32_SIZE
    slot = ptr_add data, off
    x    = load slot+0 as i32
    s    = add s, x
    i    = add i, 1
    jmp L_COND

L_END:
    return s
```

---

## 10. Box<T> / stack_alloc ✅

### SA
```
@boxed_double(x: i32) -> ^ptr:       // ^ptr: Move 出堆分配的 4 字节块
L_ENTRY:
    b = alloc 4
    v = mul x, 2
    store b+0, v as i32
    return ^b

@stacked_double(x: i32) -> i32:
L_ENTRY:
    tmp = stack_alloc 4
    v = mul x, 2
    store tmp+0, v as i32
    r = load tmp+0 as i32
    return r
```

---

## 11. Enum + match ✅

### SA
```
#def Shape_tag  = +0
#def Circle_r   = +4
#def Rect_w     = +4
#def Rect_h     = +8
#def TAG_CIRCLE = 0
#def TAG_RECT   = 1

@area(s: &ptr) -> f32:               // &ptr: 借用指向 Shape 布局
L_ENTRY:
    tag = load s+Shape_tag as u32
    is_c = eq tag, TAG_CIRCLE
    br is_c -> L_CIRCLE, L_CHECK_RECT

L_CIRCLE:
    r = load s+Circle_r as f32
    rr = fmul r, r
    res = fmul 3.14159, rr
    return res

L_CHECK_RECT:
    is_r = eq tag, TAG_RECT
    br is_r -> L_RECT, L_MISS

L_RECT:
    w = load s+Rect_w as f32
    h = load s+Rect_h as f32
    res2 = fmul w, h
    return res2

L_MISS:
    panic(106)
```

---

## 12. Option<T> / Result<T, E> ✅

### SA
```
#def Opt_tag = +0
#def Opt_val = +4
#def NONE = 0
#def SOME = 1

@safe_div(a: i32, b: i32) -> ^ptr:   // ^ptr: Move 出 Option 布局
L_ENTRY:
    is_zero = eq b, 0
    br is_zero -> L_NONE, L_SOME

L_NONE:
    r = alloc 8
    store r+Opt_tag, NONE as u32
    return ^r

L_SOME:
    q = sdiv a, b
    r = alloc 8
    store r+Opt_tag, SOME as u32
    store r+Opt_val, q as i32
    return ^r
```

---

## 13. `?` 错误传播 ✅

### SA
```
@extern read_file(path: &ptr) -> ptr!
@extern parse_int(s: &ptr) -> i32!

@const CONFIG_BYTES = utf8:"config.txt"

@load_config() -> i32!:
L_ENTRY:
    // 构造 Str 胖指针（指向 @const 字节 + 长度）
    path = stack_alloc 16
    store path+0, &CONFIG_BYTES as ptr
    store path+8, 10 as u64           // "config.txt" = 10 bytes

    r_path = &path
    res1 = call @read_file(&r_path)
    !r_path
    raw = ? res1

    r_raw = &raw
    res2 = call @parse_int(&r_raw)
    !r_raw
    parsed = ? res2

    !raw

    doubled = mul parsed, 2
    // 构造 Ok(doubled) 作为 sa_result {status=0, value=doubled}
    ok_buf = stack_alloc 8
    store ok_buf+0, 0 as u32
    store ok_buf+4, doubled as i32
    r = load ok_buf+0 as u64
    return r
```

---

## 14. 函数参数三种模式 ✅

### SA
```
@by_value(x: i32):                   // 无前缀 = 按值
    return

@by_borrow(r: &ptr):                 // &ptr = 借用
    return

@take_ownership(^d: ptr):            // ^ptr = Move
    !d
    return
```

---

## 15. 递归函数（链表） ✅

### SA
```
#def Node_val  = +0
#def Node_next = +8

@sum_list(node: ptr) -> i32:          // 按值传 ptr（nullable）
L_ENTRY:
    br_null node -> L_NULL, L_BODY

L_NULL:
    return 0

L_BODY:
    v    = load node+Node_val as i32
    next = load node+Node_next as ptr
    rest = call @sum_list(next)
    total = add v, rest
    return total
```

**注意**：`node` 是按值传递的 `ptr`（nullable），不是借用。调用方不转移所有权（只是传了一个地址值）。这对应 Rust 的 `Option<&Node>` 降级为裸地址。

---

## 16. 生命周期 `'a` ❌（刻意缺失）

### SA
```
@longest(x: &ptr, y: &ptr) -> &ptr:  // 返回借用：SA 不追踪来源
L_ENTRY:
    xlen = load x+Str_len as u64
    ylen = load y+Str_len as u64
    ge   = uge xlen, ylen
    br ge -> L_X, L_Y

L_X: return x
L_Y: return y
```

**❌ 刻意缺失**：SA 无跨函数借用追踪。前端（R20）负责保证调用方在使用返回值期间源内存未释放。

---

## 17. 泛型 + 单态化 ✅

### SA
```
@max_i32(a: i32, b: i32) -> i32:
L_ENTRY:
    ge = sge a, b
    br ge -> L_A, L_B
L_A: return a
L_B: return b

@max_f32(a: f32, b: f32) -> f32:
L_ENTRY:
    ge = fcmp_ge a, b
    br ge -> L_A, L_B
L_A: return a
L_B: return b
```

---

## 18. Trait 静态分发 ✅

### SA
```
#def Circle_r = +0

@Circle_area(self: &ptr) -> f32:     // &ptr: 借用指向 Circle 布局
L_ENTRY:
    r = load self+Circle_r as f32
    rr = fmul r, r
    res = fmul 3.14, rr
    return res

@print_area_Circle(s: &ptr):
L_ENTRY:
    a = call @Circle_area(&s)
    call @print_f32(a)
    return
```

---

## 19. `dyn Trait` 动态分发（`@const` VTable） ✅

### SA
```
#def Dyn_data    = +0
#def Dyn_vtable  = +8
#def Dyn_SIZE    = 16
#def VT_draw     = +0

@Circle_draw(self: &ptr): return
@Square_draw(self: &ptr): return

@const CIRCLE_VT = vtable { draw = @Circle_draw }
@const SQUARE_VT = vtable { draw = @Square_draw }

@render(shapes: &ptr):               // &ptr: 借用指向 Slice of Dyn 布局
L_ENTRY:
    data_base = load shapes+0 as ptr
    len       = load shapes+8 as u64
    i = 0
    jmp L_COND

L_COND:
    c = ult i, len
    br c -> L_BODY, L_END

L_BODY:
    off        = mul i, Dyn_SIZE
    elem       = ptr_add data_base, off
    obj_data   = load elem+Dyn_data as ptr
    obj_vtable = load elem+Dyn_vtable as ptr
    draw_fn    = load obj_vtable+VT_draw as ptr
    call_indirect draw_fn(obj_data)
    i = add i, 1
    jmp L_COND

L_END:
    return
```

---

## 20. 闭包（Lambda Lifting） ✅

### SA
```
#def Env_multiplier = +0

@triple_impl(env: &ptr, x: i32) -> i32:
L_ENTRY:
    m = load env+Env_multiplier as i32
    r = mul x, m
    return r

@main:
L_ENTRY:
    env = stack_alloc 4
    store env+Env_multiplier, 3 as i32
    r_env  = &env
    result = call @triple_impl(&r_env, 10)
    !r_env
    return
```

---

## 21. Iterator + for 循环 ⚠️

### SA
```
@sum_squares(v: &ptr) -> i32:
L_ENTRY:
    data = load v+0 as ptr
    len  = load v+8 as u64
    s = 0
    i = 0
    jmp L_COND

L_COND:
    c = ult i, len
    br c -> L_BODY, L_END

L_BODY:
    off  = mul i, 4
    slot = ptr_add data, off
    x    = load slot+0 as i32
    sq   = mul x, x
    s    = add s, sq
    i    = add i, 1
    jmp L_COND

L_END:
    return s
```

---

## 22. 原子操作 ✅

### SA
```
@increment(c: &ptr):                  // &ptr: 借用指向 AtomicI32
L_ENTRY:
    old = atomic_rmw_add c+0, 1 seq_cst
    return

@try_swap(c: &ptr, expected: i32, new_val: i32) -> i32:
L_ENTRY:
    old, ok = cmpxchg c+0, expected, new_val acq_rel acquire
    ret = zext ok
    return ret
```

---

## 23. async/await ⚠️

### Rust
```rust
async fn fetch_and_parse(url: &str) -> Result<i32, u32> {
    let data = fetch(url).await?;       // Suspension point 1
    let parsed = parse(&data).await?;   // Suspension point 2
    Ok(parsed)
}
```

### SA（前端 CPS 转换后，完整展开）

**降级策略**：每个 `async fn` 拆为"状态机上下文结构体 + poll 函数"。每个 `.await` 点 = 一个 state ID。跨 `.await` 存活的局部变量必须存入 ctx（栈帧会被调度器切走）。

```
// 状态机上下文结构体布局
#def Ctx_SIZE      = 40
#def Ctx_state     = +0       // u32: 0=init, 1=waiting_fetch, 2=waiting_parse
#def Ctx_url_ptr   = +8       // ptr: url 数据指针（跨 await 存活）
#def Ctx_url_len   = +16      // u64: url 长度
#def Ctx_data_ptr  = +24      // ptr: fetch 结果（跨 await 存活）
#def Ctx_data_len  = +32      // u64: fetch 结果长度

// 外部 reactor 接口
@extern reactor_start_fetch(*url_ptr: ptr, url_len: u64, *ctx_ptr: ptr) -> void
@extern reactor_poll_fetch(*ctx_ptr: ptr) -> i32    // 0=pending, 1=ready, 2=error
@extern reactor_take_fetch(*ctx_ptr: ptr, *out_ptr: ptr, *out_len: ptr) -> void
@extern reactor_start_parse(*data_ptr: ptr, data_len: u64, *ctx_ptr: ptr) -> void
@extern reactor_poll_parse(*ctx_ptr: ptr) -> i32
@extern reactor_take_parse(*ctx_ptr: ptr) -> i32

// Poll 函数：每次被事件循环唤醒时调用
// 返回 sa_result: status=0 Ready, status=1 Pending, status>1 Error
@ffi_wrapper fetch_and_parse_poll(ctx: &ptr) -> i32!:
L_ENTRY:
    state = load ctx+Ctx_state as u32
    s0 = eq state, 0
    br s0 -> L_STATE_0, L_CHECK_1

// State 0: 初始，发起 fetch
L_STATE_0:
    url_ptr = load ctx+Ctx_url_ptr as ptr
    url_len = load ctx+Ctx_url_len as u64
    raw_ctx = *ctx
    call @reactor_start_fetch(url_ptr, url_len, raw_ctx)
    store ctx+Ctx_state, 1 as u32
    jmp L_RETURN_PENDING

L_CHECK_1:
    s1 = eq state, 1
    br s1 -> L_STATE_1, L_CHECK_2

// State 1: 轮询 fetch 是否完成
L_STATE_1:
    raw_ctx1 = *ctx
    fs = call @reactor_poll_fetch(raw_ctx1)
    is_p = eq fs, 0
    br is_p -> L_RETURN_PENDING, L_FETCH_CHECK_ERR

L_FETCH_CHECK_ERR:
    is_err = eq fs, 2
    br is_err -> L_ERR_FETCH, L_FETCH_DONE

L_ERR_FETCH:
    err = stack_alloc 8
    store err+0, 2 as u32
    store err+4, 0 as i32
    r = load err+0 as u64
    return r

L_FETCH_DONE:
    // 取出结果，存入 ctx（跨 await 存活）
    out_ptr_buf = stack_alloc 8
    out_len_buf = stack_alloc 8
    raw_ctx2 = *ctx
    call @reactor_take_fetch(raw_ctx2, out_ptr_buf, out_len_buf)
    dp = load out_ptr_buf+0 as ptr
    dl = load out_len_buf+0 as u64
    store ctx+Ctx_data_ptr, dp as ptr
    store ctx+Ctx_data_len, dl as u64
    raw_ctx3 = *ctx
    call @reactor_start_parse(dp, dl, raw_ctx3)
    store ctx+Ctx_state, 2 as u32
    jmp L_RETURN_PENDING

L_CHECK_2:
    s2 = eq state, 2
    br s2 -> L_STATE_2, L_INVALID

// State 2: 轮询 parse 是否完成
L_STATE_2:
    raw_ctx4 = *ctx
    ps = call @reactor_poll_parse(raw_ctx4)
    is_p2 = eq ps, 0
    br is_p2 -> L_RETURN_PENDING, L_PARSE_CHECK_ERR

L_PARSE_CHECK_ERR:
    is_err2 = eq ps, 2
    br is_err2 -> L_ERR_PARSE, L_PARSE_DONE

L_ERR_PARSE:
    err2 = stack_alloc 8
    store err2+0, 3 as u32
    store err2+4, 0 as i32
    r2 = load err2+0 as u64
    return r2

L_PARSE_DONE:
    raw_ctx5 = *ctx
    parsed = call @reactor_take_parse(raw_ctx5)
    store ctx+Ctx_state, 3 as u32
    ok = stack_alloc 8
    store ok+0, 0 as u32
    store ok+4, parsed as i32
    rok = load ok+0 as u64
    return rok

// 公共 Pending 返回
L_RETURN_PENDING:
    p = stack_alloc 8
    store p+0, 1 as u32
    store p+4, 0 as i32
    rp = load p+0 as u64
    return rp

L_INVALID:
    panic(102)
```

### 调用方：事件循环驱动
```
@run_task(^ctx: ptr):
L_ENTRY:
    jmp L_POLL
L_POLL:
    r_ctx = &ctx
    result = call @fetch_and_parse_poll(&r_ctx)
    !r_ctx
    status = load result+0 as u32
    is_pending = eq status, 1
    br is_pending -> L_YIELD, L_DONE
L_YIELD:
    call @reactor_yield()
    jmp L_POLL
L_DONE:
    is_ok = eq status, 0
    br is_ok -> L_SUCCESS, L_FAILURE
L_SUCCESS:
    value = load result+4 as i32
    !ctx
    return
L_FAILURE:
    !ctx
    return
```

**⚠️ 前端重担分析**：

| 工作项 | 行数估算 | 说明 |
|---|---|---|
| 状态机结构体布局 | ~20 行 `#def` | 扫描跨 await 存活变量，计算偏移 |
| state 分发跳转表 | ~20 行/await 点 | `eq state, N` + `br` 链 |
| 局部变量存入/取出 ctx | ~10 行/变量/await 点 | `store ctx+off` / `load ctx+off` |
| 错误传播 `?` 在每个 resume 点 | ~15 行/await 点 | 检查 status + 早返回 |
| reactor 接口调用 | ~5 行/await 点 | `@extern` 调用 |
| **本例（2 个 await 点）** | **~120 行 SA** | 对应 Rust 3 行源码（40x 膨胀） |

**为什么 SA 不内置 coroutine**：内置 coroutine 需要"可暂停栈帧"，破坏"所有状态显式可见"的核心哲学；Referee 的 O(1) 线性扫描无法处理"暂停后恢复"的非线性控制流。

**缓解建议**：v0.3 提供 `libsa_async` helper 库，封装状态机结构体生成 + state 分发模板 + 局部变量自动存取，前端只需声明 await 点和跨 await 变量。

---

## 24. Rc/Arc 引用计数 ✅

### SA
```
#def Rc_strong    = +0
#def Rc_value_i32 = +16
#def Rc_TOTAL     = 20

@rc_new_i32(v: i32) -> ^ptr:
L_ENTRY:
    r = alloc Rc_TOTAL
    store r+Rc_strong, 1 as u64
    store r+Rc_value_i32, v as i32
    return ^r

@rc_clone(r: &ptr) -> ^ptr:          // &ptr: 借用 Rc 块
L_ENTRY:
    r_addr = load r+0 as ptr
    old = atomic_rmw_add r_addr+Rc_strong, 1 acq_rel
    return ^r_addr

@rc_drop(^r: ptr):
L_ENTRY:
    old = atomic_rmw_sub r+Rc_strong, 1 acq_rel
    is_last = eq old, 1
    br is_last -> L_FREE, L_DONE
L_FREE:
    !r
    return
L_DONE:
    return
```

---

## 25. unsafe / 气闸舱 ✅

### SA
```
@extern c_sum(*raw: ptr, len: u64) -> i32

@ffi_wrapper call_c_sum(arr: &ptr) -> i32:
L_ENTRY:
    data = load arr+0 as ptr
    len  = load arr+8 as u64
    raw  = *data                      // 裸指针降级：仅气闸舱内允许
    res  = call @c_sum(raw, len)
    return res
```

---

## 26. FFI extern "C" ✅

### SA
```
@export sa_multiply(a: i32, b: i32) -> i32:
L_ENTRY:
    r = mul a, b
    return r
```

---

## 27. panic! / panic_msg ✅

### SA
```
#def PANIC_DIV_ZERO = 100

@const MSG_DIV_ZERO = utf8:"div by zero"

@divide(a: i32, b: i32) -> i32:
L_ENTRY:
    z = eq b, 0
    br z -> L_PANIC, L_OK

L_PANIC:
    r_msg = &MSG_DIV_ZERO
    data  = load r_msg+0 as ptr       // @const 的地址
    len   = 11                        // "div by zero" = 11 bytes
    panic_msg(PANIC_DIV_ZERO, data, len)

L_OK:
    q = sdiv a, b
    return q
```

---

## 28. `#mode compact` 紧凑糖 ✅ — 已由外部 SLA 插件替代

> **📌 重要更新 (2026-07-01): `#mode compact` 已被外部 SLA 插件（`sa_plugin_sla`）取代。**
> SLA 提供了完整的 Rust 风格语言前端（泛型、模式匹配、trait、枚举、闭包等），拥有完整的表达式解析器。请使用 SLA 而非 `#mode compact`。
> 详见 `~/projects/sa_plugins/sa_plugin_sla`。

### SA（关键字形态）
```
@dot(a: &ptr, b: &ptr) -> f32:
L_ENTRY:
    ax = load a+0 as f32
    bx = load b+0 as f32
    m1 = fmul ax, bx
    ay = load a+4 as f32
    by = load b+4 as f32
    m2 = fmul ay, by
    s  = fadd m1, m2
    az = load a+8 as f32
    bz = load b+8 as f32
    m3 = fmul az, bz
    res = fadd s, m3
    return res
```

### SA（`#mode compact` 形态，等价）
```
#mode compact

@dot(a: &ptr, b: &ptr) -> f32:
L_ENTRY:
    ax = load a+0 as f32
    bx = load b+0 as f32
    m1 = ax * bx
    ay = load a+4 as f32
    by = load b+4 as f32
    m2 = ay * by
    s  = m1 + m2
    az = load a+8 as f32
    bz = load b+8 as f32
    m3 = az * bz
    res = s + m3
    return res
```

**约束**：单行只能一个中缀操作符。`s = ax * bx + ay * by` 非法。

---

# 总结

## 签名规则速查

| Rust 形态 | SA 签名 | 说明 |
|---|---|---|
| `fn f(x: i32)` | `@f(x: i32)` | 按值，原生数值 |
| `fn f(r: &T)` / `fn f(r: &mut T)` | `@f(r: &ptr)` | 借用（共享/独占由 Referee 掩码决定，语法层不区分） |
| `fn f(d: T)` (Move) | `@f(^d: ptr)` | Move 进来 |
| `fn f() -> T` (值) | `@f() -> i32` | 按值返回 |
| `fn f() -> Box<T>` | `@f() -> ^ptr` | Move 出堆块 |
| `fn f() -> &T` | `@f() -> &ptr` | 返回借用（前端负责安全） |
| `fn f() -> Result<T,E>` | `@f() -> i32!` | Fallible ABI |
| `extern fn f(p: *T)` | `@extern f(*p: ptr)` | FFI 裸指针 |

## 设计评分（28 案例）

| 维度 | 评分 |
|---|---|
| 基础控制流 | ✅ |
| 所有权/借用 | ✅ |
| 错误传播 | ✅ |
| 结构体/Enum | ✅ |
| 原子操作 | ✅ |
| 泛型/Trait | ✅ |
| dyn Trait/VTable | ✅ |
| 生命周期 | ❌ 刻意缺失 |
| 切片/字符串索引 | ✅（InteriorPtr） |
| async/await | ⚠️ 前端重担 |
| FFI/unsafe | ✅ |
| Rc/Arc | ✅ |
| panic | ✅ |
| Token 密度 | ✅（已由外部 SLA 插件替代） |

**零自定义类型名泄漏到签名。零 `@const` 类型标注。所有借用/Move 参数恒为 `ptr`。语法层不存在 `&mut`。**

**未解决**：`call_indirect` 仍无法校验参数 ABI 一致性，这是 Rust 也有的痛点。


@triple_impl(env: &ptr, x: i32) -> i32:   // &ptr: 借用指向闭包环境 [multiplier(4)]
L_ENTRY:
    m = load env+Env_triple_multiplier as i32
    r = mul x, m
    return r

@main:
L_ENTRY:
    env = stack_alloc 4            // v0.2：闭包环境栈分配
    store env+Env_triple_multiplier, 3 as i32

    r_env  = &env
    result = call @triple_impl(&r_env, 10)
    !r_env

    return                          // stack_alloc 自动回收
```

---

## 21. Iterator + for 循环 ⚠️

### Rust
```rust
fn sum_squares(v: &Vec<i32>) -> i32 {
    v.iter().map(|x| x * x).sum()
}
```

### SA（前端展开迭代器链）
```
@sum_squares(v: &ptr) -> i32:             // &ptr: 借用指向 Vec 布局
L_ENTRY:
    data = load v+Vec_data as ptr
    len  = load v+Vec_len  as u64
    s = 0
    i = 0
    jmp L_COND

L_COND:
    c = ult i, len
    br c -> L_BODY, L_END

L_BODY:
    off  = mul i, 4
    slot = ptr_add data, off
    x    = load slot+0 as i32
    sq   = mul x, x
    s    = add s, sq
    i    = add i, 1
    jmp L_COND

L_END:
    return s
```

**⚠️ 前端重担**：迭代器链的融合优化是 smrustc 的职责。SA 本身只看到展开后的单循环。

---

## 22. 原子操作（`atomic_rmw_*` + `cmpxchg` 双返回） ✅

### Rust
```rust
use std::sync::atomic::{AtomicI32, Ordering};

fn increment(c: &AtomicI32) {
    c.fetch_add(1, Ordering::SeqCst);
}

fn try_swap(c: &AtomicI32, expected: i32, new: i32) -> bool {
    c.compare_exchange(expected, new, Ordering::AcqRel, Ordering::Acquire).is_ok()
}
```

### SA（v0.2）
```
@increment(c: &ptr):                      // &ptr: 借用指向 AtomicI32
L_ENTRY:
    // ✅ 已修复（R2.1 atomic_rmw 族）：单条指令原子 fetch_add
    old = atomic_rmw_add c+0, 1 seq_cst
    return

@try_swap(c: &ptr, expected: i32, new: i32) -> i32:
L_ENTRY:
    // ✅ 已修复（R2.1/R2.7 + P29）：cmpxchg 双返回值 (old, ok)
    old, ok = cmpxchg c+0, expected, new acq_rel acquire
    // ok 是 i1 布尔；转成 i32 返回
    ret = zext ok
    return ret
```

**✅ 已修复**（v0.2）：
- `atomic_rmw_{add,sub,and,or,xor,xchg,smin,smax,umin,umax}` 指令族 1 条完成原子 RMW（R2.1）
- `cmpxchg` 返回 `(old_value, ok: i1)` 双值（R2.7、P29）
- ordering 支持 `seq_cst` / `acq_rel` / 双 ordering（success / failure）

---

## 23. async/await（状态机展平） ⚠️

### Rust
```rust
async fn fetch_and_parse(url: &str) -> Result<i32, u32> {
    let data = fetch(url).await?;
    let parsed = parse(&data).await?;
    Ok(parsed)
}
```

### SA（前端 CPS 转换后，完整展开）

**降级策略**：每个 `async fn` 拆为"状态机上下文结构体 + poll 函数"。每个 `.await` 点 = 一个 state ID。跨 `.await` 存活的局部变量必须存入 ctx（栈帧会被调度器切走）。

```
// ============================================================
// 状态机上下文结构体布局
// ============================================================
#def Ctx_SIZE      = 40
#def Ctx_state     = +0       // u32: 0=init, 1=waiting_fetch, 2=waiting_parse
#def Ctx_url_ptr   = +8       // ptr: url 字符串数据指针（跨 await 存活）
#def Ctx_url_len   = +16      // u64: url 长度
#def Ctx_data_ptr  = +24      // ptr: fetch 结果数据指针（跨 await 存活）
#def Ctx_data_len  = +32      // u64: fetch 结果长度

// ============================================================
// 外部 reactor 接口（由宿主提供）
// ============================================================
@extern reactor_start_fetch(*url_ptr: ptr, url_len: u64, *ctx_ptr: ptr) -> void
@extern reactor_poll_fetch(*ctx_ptr: ptr) -> i32    // 0=pending, 1=ready, 2=error
@extern reactor_take_fetch(*ctx_ptr: ptr, *out_ptr: ptr, *out_len: ptr) -> void

@extern reactor_start_parse(*data_ptr: ptr, data_len: u64, *ctx_ptr: ptr) -> void
@extern reactor_poll_parse(*ctx_ptr: ptr) -> i32
@extern reactor_take_parse(*ctx_ptr: ptr) -> i32    // 返回 parsed i32

// ============================================================
// Poll 函数：每次被事件循环唤醒时调用
// 返回 sa_result: status=0 Ready, status=1 Pending, status>1 Error
// ============================================================

@ffi_wrapper fetch_and_parse_poll(ctx: &ptr) -> i32!:
L_ENTRY:
    state = load ctx+Ctx_state as u32
    s0 = eq state, 0
    br s0 -> L_STATE_0, L_CHECK_1

// ------ State 0: 初始，发起 fetch ------
L_STATE_0:
    url_ptr = load ctx+Ctx_url_ptr as ptr
    url_len = load ctx+Ctx_url_len as u64
    raw_ctx = *ctx
    call @reactor_start_fetch(url_ptr, url_len, raw_ctx)
    store ctx+Ctx_state, 1 as u32
    jmp L_RETURN_PENDING

// ------ 检查 state 1 ------
L_CHECK_1:
    s1 = eq state, 1
    br s1 -> L_STATE_1, L_CHECK_2

// ------ State 1: 轮询 fetch 是否完成 ------
L_STATE_1:
    raw_ctx1 = *ctx
    fs = call @reactor_poll_fetch(raw_ctx1)
    is_p = eq fs, 0
    br is_p -> L_RETURN_PENDING, L_FETCH_CHECK_ERR

L_FETCH_CHECK_ERR:
    is_err = eq fs, 2
    br is_err -> L_RETURN_ERR_FETCH, L_FETCH_DONE

L_RETURN_ERR_FETCH:
    err = stack_alloc 8
    store err+0, 2 as u32
    store err+4, 0 as i32
    r = load err+0 as u64
    return r

L_FETCH_DONE:
    // 取出结果，存入 ctx（跨 await 存活）
    out_ptr_buf = stack_alloc 8
    out_len_buf = stack_alloc 8
    raw_ctx2 = *ctx
    call @reactor_take_fetch(raw_ctx2, out_ptr_buf, out_len_buf)
    dp = load out_ptr_buf+0 as ptr
    dl = load out_len_buf+0 as u64
    store ctx+Ctx_data_ptr, dp as ptr
    store ctx+Ctx_data_len, dl as u64
    // 发起 parse
    raw_ctx3 = *ctx
    call @reactor_start_parse(dp, dl, raw_ctx3)
    store ctx+Ctx_state, 2 as u32
    jmp L_RETURN_PENDING

// ------ 检查 state 2 ------
L_CHECK_2:
    s2 = eq state, 2
    br s2 -> L_STATE_2, L_INVALID

// ------ State 2: 轮询 parse 是否完成 ------
L_STATE_2:
    raw_ctx4 = *ctx
    ps = call @reactor_poll_parse(raw_ctx4)
    is_p2 = eq ps, 0
    br is_p2 -> L_RETURN_PENDING, L_PARSE_CHECK_ERR

L_PARSE_CHECK_ERR:
    is_err2 = eq ps, 2
    br is_err2 -> L_RETURN_ERR_PARSE, L_PARSE_DONE

L_RETURN_ERR_PARSE:
    err2 = stack_alloc 8
    store err2+0, 3 as u32
    store err2+4, 0 as i32
    r2 = load err2+0 as u64
    return r2

L_PARSE_DONE:
    raw_ctx5 = *ctx
    parsed = call @reactor_take_parse(raw_ctx5)
    store ctx+Ctx_state, 3 as u32
    // 返回 Ok(parsed)
    ok = stack_alloc 8
    store ok+0, 0 as u32
    store ok+4, parsed as i32
    rok = load ok+0 as u64
    return rok

// ------ 公共 Pending 返回 ------
L_RETURN_PENDING:
    p = stack_alloc 8
    store p+0, 1 as u32
    store p+4, 0 as i32
    rp = load p+0 as u64
    return rp

// ------ 非法状态 ------
L_INVALID:
    panic(102)
```

### 调用方：事件循环驱动
```
@run_task(^ctx: ptr):
L_ENTRY:
    jmp L_POLL

L_POLL:
    r_ctx = &ctx
    result = call @fetch_and_parse_poll(&r_ctx)
    !r_ctx
    status = load result+0 as u32
    is_pending = eq status, 1
    br is_pending -> L_YIELD, L_DONE

L_YIELD:
    call @reactor_yield()
    jmp L_POLL

L_DONE:
    is_ok = eq status, 0
    br is_ok -> L_SUCCESS, L_FAILURE

L_SUCCESS:
    value = load result+4 as i32
    !ctx
    return

L_FAILURE:
    !ctx
    return
```

**⚠️ 前端重担分析**：

| 工作项 | 行数估算 | 说明 |
|---|---|---|
| 状态机结构体布局 | ~20 行 `#def` | 扫描跨 await 存活变量，计算偏移 |
| state 分发跳转表 | ~20 行/await 点 | `eq state, N` + `br` 链 |
| 局部变量存入/取出 ctx | ~10 行/变量/await 点 | `store ctx+off` / `load ctx+off` |
| 错误传播 `?` 在每个 resume 点 | ~15 行/await 点 | 检查 status + 早返回 |
| reactor 接口调用 | ~5 行/await 点 | `@extern` 调用 |
| **本例（2 个 await 点）** | **~120 行 SA** | 对应 Rust 3 行源码（40x 膨胀） |

**为什么 SA 不内置 coroutine**：
- 内置 coroutine 需要"可暂停栈帧"，破坏"所有状态显式可见"的核心哲学
- Referee 的 O(1) 线性扫描无法处理"暂停后恢复"的非线性控制流
- 把 CPS 转换留给前端，SA 本身保持绝对扁平

**缓解建议**：v0.3 提供 `libsa_async` helper 库，封装"状态机结构体生成 + state 分发模板 + 局部变量自动存取"，前端只需声明 await 点和跨 await 变量。

---

## 24. Rc/Arc 引用计数（`atomic_rmw_sub`） ✅

### Rust
```rust
use std::sync::Arc;

fn main() {
    let a = Arc::new(42i32);
    let b = a.clone();    // strong_count = 2
    let c = a.clone();    // strong_count = 3
    // 离开作用域：原子递减到 0 时 free
}
```

### SA（v0.2）
```
#def Rc_strong    = +0
#def Rc_weak      = +8
#def Rc_value_i32 = +16
#def Rc_TOTAL_i32 = 20

@rc_new_i32(v: i32) -> ^ptr:
L_ENTRY:
    r = alloc Rc_TOTAL_i32
    store r+Rc_strong, 1 as u64
    store r+Rc_weak, 1 as u64
    store r+Rc_value_i32, v as i32
    return ^r

// Clone: 原子递增 strong
@rc_clone(r: &ptr) -> ^ptr:
L_ENTRY:
    r_addr = load r+0 as ptr
    // ✅ 已修复：单条原子 RMW
    old = atomic_rmw_add r_addr+Rc_strong, 1 acq_rel
    // 直接把同一指针作为新的所有权副本返回
    // （前端保证调用方处理好 Move 语义）
    return ^r_addr

// Drop: 原子递减，到 1→0 时 free
@rc_drop(^r: ptr):
L_ENTRY:
    // ✅ 原子 fetch_sub 返回旧值；若旧值 == 1 则此次是最后一个引用
    old = atomic_rmw_sub r+Rc_strong, 1 acq_rel
    is_last = eq old, 1
    br is_last -> L_FREE, L_DONE

L_FREE:
    !r                              // 物理 free
    return

L_DONE:
    return
```

**✅ 已修复**（v0.2）：用 `atomic_rmw_add` / `atomic_rmw_sub` 一条指令完成，无需 `cmpxchg` retry loop，真正满足原子语义。

---

## 25. unsafe 块与裸指针（气闸舱） ✅

### Rust
```rust
extern "C" {
    fn c_sum(ptr: *const i32, len: usize) -> i32;
}

fn call_c_sum(arr: &[i32]) -> i32 {
    unsafe { c_sum(arr.as_ptr(), arr.len()) }
}
```

### SA
```
@extern c_sum(ptr: *i32, len: u64) -> i32

@ffi_wrapper call_c_sum(arr: &Slice) -> i32:
L_ENTRY:
    data_base = load arr+Slice_data as ptr
    len       = load arr+Slice_len  as u64

    // 裸指针降级：只在气闸舱内允许
    raw_ptr   = *data_base
    res       = call @c_sum(raw_ptr, len)
    return res
```

**说明**：
- **普通函数**出现 `*` / `assume_*` → `Trap: IllegalUnsafeContext`（R13.5）
- FFI 调用链顶必须 `@ffi_wrapper`
- 比 Rust 的 `unsafe { }` 块更严格（函数级而非块级）

**注意 `InteriorPtr` 与裸指针的区别**：
- `ptr_add` 派生的 `InteriorPtr` 只能在本函数内 `load`/`store`
- 若要把它传给 `@extern`，必须先在 `@ffi_wrapper` 内用 `*` 再降级（否则 `Trap: InteriorPtrEscape`，R13.7）

---

## 26. FFI extern "C" ✅

### Rust
```rust
#[no_mangle]
pub extern "C" fn sa_multiply(a: i32, b: i32) -> i32 {
    a * b
}
```

### SA
```
@export sa_multiply(a: i32, b: i32) -> i32:
L_ENTRY:
    r = mul a, b
    return r
```

---

## 27. panic! / panic_msg ✅

### Rust
```rust
fn divide(a: i32, b: i32) -> i32 {
    if b == 0 { panic!("div by zero"); }
    a / b
}

fn slice_check(arr: &[i32], i: usize) -> i32 {
    if i >= arr.len() {
        panic!("index {} out of {} bounds", i, arr.len());
    }
    arr[i]
}
```

### SA（v0.2）
```
// 标准 panic code 字典（R18.6）
#def PANIC_DIV_BY_ZERO   = 100
#def PANIC_OUT_OF_BOUNDS = 101

// 字符串消息放 rodata
@const MSG_DIV_BY_ZERO = utf8:"div by zero"

@divide(a: i32, b: i32) -> i32:
L_ENTRY:
    z = eq b, 0
    br z -> L_PANIC, L_OK

L_PANIC:
    // ✅ 已修复（R18.5）：panic_msg 携带消息
    r_msg = &MSG_DIV_BY_ZERO
    data  = load r_msg+Str_data as ptr
    len   = load r_msg+Str_len  as u64
    panic_msg(PANIC_DIV_BY_ZERO, data, len)

L_OK:
    q = sdiv a, b
    return q
```

**✅ 已修复**（v0.2 R18.5）：`panic_msg(code, *str_ptr, str_len)` 携带消息字符串。Native 写 stderr 再 `_exit`；WASM `fd_write(2,...)` 再 `unreachable`。标准 panic code 字典见 R18.6。

---

## 28. `#mode compact` 紧凑中缀糖（v0.2 可选） ✅ — 已由外部 SLA 插件替代

### Rust
```rust
fn dot(a: &[f32; 3], b: &[f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
```

### SA（默认关键字形态）
```
@dot(a: &ptr, b: &ptr) -> f32:       // &ptr: 借用指向 Vec3 布局 [x(4)|y(4)|z(4)]
L_ENTRY:
    ax = load a+0 as f32
    ay = load a+4 as f32
    az = load a+8 as f32
    bx = load b+0 as f32
    by = load b+4 as f32
    bz = load b+8 as f32
    m1 = fmul ax, bx
    m2 = fmul ay, by
    m3 = fmul az, bz
    s1 = fadd m1, m2
    s2 = fadd s1, m3
    return s2
```

### SA（`#mode compact` 形态）
```
#mode compact

@dot(a: &ptr, b: &ptr) -> f32:       // &ptr: 借用指向 Vec3 布局
L_ENTRY:
    ax = load a+0 as f32
    ay = load a+4 as f32
    az = load a+8 as f32
    bx = load b+0 as f32
    by = load b+4 as f32
    bz = load b+8 as f32
    m1 = ax * bx
    m2 = ay * by
    m3 = az * bz
    s1 = m1 + m2
    s2 = s1 + m3
    return s2
```

**重要约束**（R24.3）：
- ❌ 不能写 `s = ax * bx + ay * by + az * bz`（禁止多操作符组合）
- ❌ 不能写 `s = a < b`（禁止中缀比较）
- ❌ 不能写 `s = a && b`（无短路）
- ✅ 只能单行一个中缀操作符

**P30 保证**：启用前后的源码，Flattener 产出的 `Instruction[]` 必须字段级相等。

---

# 压力测试总结（v0.2 规范对齐）

## 设计评分

| 维度 | v0.1 评分 | v0.1 具体问题 | v0.2 评分 | v0.2 解决方案 | 证据 |
|---|---|---|---|---|---|
| 基础控制流降级 | ✅ | — | ✅ | — | 案例 1-5 |
| 所有权与借用 | ✅ | — | ✅ | — | 案例 3-5 |
| 错误传播 | ✅ | — | ✅ | — | 案例 12-13 |
| 结构体与 Enum | ✅ | — | ✅ | — | 案例 6, 11 |
| 原子操作 | ⚠️ | v0.1 只有 `cmpxchg`，实现 `fetch_add` 需要手写 retry loop（非真正原子，有 ABA 风险），代码膨胀 5-8 行 | ✅ | `atomic_rmw_{add,sub,and,or,xor,xchg,smin,smax,umin,umax}` 单条指令完成（R2.1） | 案例 22, 24 |
| 泛型与 Trait | ✅ | — | ✅ | — | 案例 17-18 |
| 动态分发 / VTable | ⚠️ | v0.1 无 `@const` 全局只读数据段，VTable 函数指针数组无处安放；只能在运行时 `alloc` + `store` 手动构造，浪费堆内存且每次启动重复初始化 | ✅ | `@const NAME = vtable { slot = @func }` 声明 `.rodata` 段永续数据（R6.5/R6.8） | 案例 19 |
| 生命周期类型系统 | ❌ | SA 刻意不做跨函数借用图追踪；前端（R20）完全负责保证返回借用的源内存未释放；错误时产生悬空引用直到段错误 | ❌ | 未变（设计取舍，非缺陷） | 案例 16 |
| 切片/字符串索引 | ⚠️ | v0.1 从胖指针 `load` 出的 `data_ptr` 是裸指针，严格执行 R13 气闸舱规则会把**所有** `arr[i]` 操作推进 `@ffi_wrapper`，导致 80%+ 的普通业务代码被迫标为 FFI 边界 | ✅ | `ptr_add` 派生 `InteriorPtr` 状态位（R4.9），生命周期绑定母借用，普通函数内合法 `load`/`store`，不触发气闸舱（R13.6） | 案例 2, 7, 8, 9 |
| async/await | ⚠️ | 前端必须做完整 CPS 转换：每个 `await` 点 = 新 state ID + 检查 Label + 局部变量存入 ctx 结构体；约 3000 行前端代码量 | ⚠️ | 未变（SA 不提供 coroutine 原语，CPS 仍由前端完成；建议 v0.3 提供 `libsa_async` helper 封装） | 案例 23 |
| FFI / unsafe | ✅ | — | ✅ | — | 案例 25-26 |
| Box / Rc / Arc | ⚠️ | v0.1 缺 `stack_alloc`（小对象如 `Option<i32>` 每次强制堆分配，性能倒退）；缺 `atomic_rmw`（Rc/Arc 的 clone/drop 需要 cmpxchg retry loop，非真正原子） | ✅ | `stack_alloc N` 栈分配（R2.1/P27）+ `atomic_rmw_sub` 单条原子递减（R2.1） | 案例 10, 24 |
| panic 语义 | ⚠️ | v0.1 只有 `panic(code)` 整数错误码，无法携带消息字符串；调试时只能看到数字，无法定位具体错误原因 | ✅ | `panic_msg(code, *str_ptr, str_len)` 携带 rodata 消息 + 标准 panic code 字典 100-107（R18.5/R18.6） | 案例 27 |
| **Token 密度（可选）** | — | v0.1 所有算术必须写关键字形态（`d = add a, b`），手写时心智负担较高 | ✅ | `#mode compact` 可选中缀糖 ~~（`d = a + b`），8 条白名单，禁优先级（R24）~~ 已由外部 SLA 插件（`sa_plugin_sla`）的完整 Rust 风格语法替代 | 案例 28 |

## v0.1 到 v0.2 的缺口修复总览

| 缺口 | v0.2 修复 | Requirements |
|---|---|---|
| 切片索引被迫进气闸舱 | `ptr_add` + `InteriorPtr` 状态位 | R2.5, R4.9, R4.10, R13.6 |
| VTable 无处安放 | `@const NAME = vtable {...}` | R6.5, R6.8 |
| 原子 RMW 要 cmpxchg 循环 | `atomic_rmw_{add,sub,...}` 指令族 | R2.1 |
| `cmpxchg` 无成功位返回 | 双返回值 `(old, ok)` | R2.7, P29 |
| 浮点比较缺 `ge/le/ne` | ISA 补齐 | R2.5 |
| Option 小值每次堆分配 | `stack_alloc N` | R2.1, P27 |
| panic 无消息 | `panic_msg(code, *s, len)` | R18.5 |
| panic code 五花八门 | 标准字典 100-107 | R18.6 |
| 算术写法冗余（可选） | `#mode compact` 中缀糖 ~~→ 已由 SLA 插件替代~~ | R24 |

## smrustc 前端工作量更新

基于修复后的 SA，前端代码量估算：

| 阶段 | v0.1 估算 | v0.2 估算 | 变化原因 |
|---|---|---|---|
| 案例 1-10 基础 | 500-1000 行 | 400-800 行 | `InteriorPtr` 消除气闸舱包装 |
| 案例 11-18 中级 | +1500 行 | +1300 行 | `@const` 简化字面量处理 |
| 案例 19-22 高级 | +2000 行 | +1500 行 | VTable/`atomic_rmw` 简化 |
| 案例 23 async | +3000 行 | +3000 行 | 未变（CPS 转换本质复杂） |
| 案例 24-27 其它 | +500 行 | +400 行 | panic_msg / stack_alloc 简化 |
| **总计** | **~7500-8000 行** | **~6600-7000 行** | 净减 ~1000 行 |

## 结论：SA v0.2 能不能用来重写 Rust 项目？

**能，且比 v0.1 显著更顺滑。**

关键缺口都已对齐：
- `InteriorPtr` 让日常 `arr[i]` 不再逃进 unsafe
- `@const` 让 VTable/字符串字面量有正式家
- `atomic_rmw` / `cmpxchg` 双返回值让并发原语语义完整
- `stack_alloc` 让小对象不再强制堆分配
- `panic_msg` + 标准字典让错误可诊断
- `#mode compact`（可选）~~让手写 SA 不必被关键字淹没~~（由外部 SLA 插件 `sa_plugin_sla` 的完整 Rust 风格语法替代）

**仍然保留的刻意缺失**：
- 生命周期类型系统（R20 前端合约承担）
- async/await 原生支持（CPS 由前端做）
- 操作符优先级（紧凑糖仍禁止组合）

SA 的核心哲学——"把证明外包给 Referee 的 O(1) 位掩码"——在 v0.2 后站得更稳。**前端责任制是真实成本**，但比官方 rustc 的借用检查器数十万行代码轻量一个数量级。

L_ENTRY:
    old, ok = cmpxchg c+0, expected, new_val acq_rel acquire
    ret = zext ok
    return ret
```

---

# v0.3 新特性案例（R25/R26/R27）

---

## 29. VTable 签名静态校验（R25） ✅

### 问题场景（v0.2 未解决）
```rust
trait Animal {
    fn speak(&self) -> i32;
    fn legs(&self) -> i32;
}

// 如果前端错误地把 speak(self, extra_arg) 的签名塞进了 VTable，
// v0.2 的 call_indirect 不会报错，运行时段错误。
```

### SA（v0.3：编译期 Trap）
```
// 正确的 VTable 声明：speak 签名为 (&ptr) -> i32
@Dog_speak(self: &ptr) -> i32:
L_ENTRY:
    return 1

@Dog_legs(self: &ptr) -> i32:
L_ENTRY:
    return 4

#def VT_speak = +0
#def VT_legs  = +8

@const DOG_VT = vtable { speak = @Dog_speak, legs = @Dog_legs }

// 正确调用：参数 tuple 匹配
@call_speak(obj: &ptr, vt: &ptr) -> i32:
L_ENTRY:
    speak_fn = load vt+VT_speak as ptr
    result = call_indirect speak_fn(&obj)    // ✅ Referee 校验：(&ptr)->i32 匹配
    return result

// 错误调用：参数 tuple 不匹配
@call_speak_wrong(obj: &ptr, vt: &ptr, extra: i32) -> i32:
L_ENTRY:
    speak_fn = load vt+VT_speak as ptr
    result = call_indirect speak_fn(&obj, extra)  // ❌ Trap: VTableSignatureMismatch
    //                                               期望 (&ptr)->i32，实际传了 (&ptr, i32)->i32
    return result
```

**v0.3 保证（R25.2/R25.3）**：
- Referee 在编译期记录 `DOG_VT.speak` 的签名 tuple = `[(&ptr)] -> i32`
- `call_indirect speak_fn(&obj)` 的调用点参数 tuple = `[(&ptr)]` → 匹配 → 通过
- `call_indirect speak_fn(&obj, extra)` 的调用点参数 tuple = `[(&ptr), (i32)]` → 不匹配 → `Trap: VTableSignatureMismatch`
- **零运行时开销**：纯编译期静态分析

**FFI 豁免（R25.4）**：若 VTable 来自外部 `@ffi_wrapper` 传入的裸指针，Referee 无法获知签名，不做校验。

---

## 30. `libsa_async` 宏模板（R26） ✅

### 问题场景（v0.2 的 40x 膨胀）
案例 23 展示了 Rust 3 行 async 代码降级为 ~120 行 SA。v0.3 用 `[MACRO]` 宏模板缓解。

### SA（v0.3：使用 libsa_async 宏）
```
// 引入标准异步宏库
@import "libsa_async.sars"

// 状态机上下文布局（仍需手写，因为跨 await 变量是业务特定的）
#def Ctx_SIZE      = 40
#def Ctx_state     = +0
#def Ctx_url_ptr   = +8
#def Ctx_url_len   = +16
#def Ctx_data_ptr  = +24
#def Ctx_data_len  = +32

// 外部 reactor 接口
@extern reactor_start_fetch(*url_ptr: ptr, url_len: u64, *ctx_ptr: ptr) -> void
@extern reactor_poll_fetch(*ctx_ptr: ptr) -> i32
@extern reactor_take_fetch(*ctx_ptr: ptr, *out_ptr: ptr, *out_len: ptr) -> void
@extern reactor_start_parse(*data_ptr: ptr, data_len: u64, *ctx_ptr: ptr) -> void
@extern reactor_poll_parse(*ctx_ptr: ptr) -> i32
@extern reactor_take_parse(*ctx_ptr: ptr) -> i32

// Poll 函数：用宏模板生成骨架
@ffi_wrapper fetch_and_parse_poll(ctx: &ptr) -> i32!:

// 宏展开：state 分发入口
EXPAND ASYNC_POLL_PROLOGUE ctx, Ctx_state

// State 0: 发起 fetch
EXPAND ASYNC_STATE_BEGIN 0
    url_ptr = load ctx+Ctx_url_ptr as ptr
    url_len = load ctx+Ctx_url_len as u64
    raw_ctx = *ctx
    call @reactor_start_fetch(url_ptr, url_len, raw_ctx)
EXPAND ASYNC_STATE_END ctx, Ctx_state, 1

// State 1: 轮询 fetch
EXPAND ASYNC_AWAIT_POINT ctx, Ctx_state, 1, @reactor_poll_fetch, @reactor_take_fetch, Ctx_data_ptr, Ctx_data_len

// State 1 完成后：发起 parse
EXPAND ASYNC_STATE_BEGIN 1_DONE
    dp = load ctx+Ctx_data_ptr as ptr
    dl = load ctx+Ctx_data_len as u64
    raw_ctx3 = *ctx
    call @reactor_start_parse(dp, dl, raw_ctx3)
EXPAND ASYNC_STATE_END ctx, Ctx_state, 2

// State 2: 轮询 parse
EXPAND ASYNC_AWAIT_POINT_FINAL ctx, Ctx_state, 2, @reactor_poll_parse, @reactor_take_parse

// 宏展开：公共 Pending 返回
EXPAND ASYNC_RETURN_PENDING

// 宏展开：非法状态 panic
EXPAND ASYNC_INVALID_STATE
```

**对比 v0.2 手写**：
- v0.2 手写：~120 行 SA
- v0.3 用宏：~40 行 SA（业务逻辑 + `EXPAND` 调用）
- **膨胀比从 40x 降到 ~13x**

**关键约束（R26.3/R26.6）**：
- 宏展开后的指令流与手写**完全等价**（P32 保证）
- SA 语法层**不引入** `@async` / `await_state` 等新关键字
- 宏只是文本模板，不引入隐式展开或跨 await 变量自动存取
- 前端仍需手写 `#def Ctx_*` 布局（因为跨 await 变量是业务特定的）

---

## 31. 发射产物诊断级别（R27） ✅

### 三种构建模式对比

```
// 同一段 SA 代码
@process(data: &ptr) -> i32:
L_ENTRY:
    buf = alloc 64
    r = &buf
    v = load r+0 as i32
    !r
    !buf
    return v
```

#### `sa build-exe process.sa -o out`（默认 `--release`）
```
// 产物中零 Referee 运行时代码
// 所有所有权校验已在编译期完成
// 性能 = LLVM O1 原生速度
```

#### `sa build-exe process.sa -o out --debug-gas`
```
// 产物在每个函数入口插入 gas 计数器
// 伪代码等价：
//   __sa_gas_counter += 1;
//   if (__sa_gas_counter > __sa_gas_limit) trap("GasExceeded");
// 用于防御失控的 LLM 产物（无限循环等）
```

#### `sa build-exe process.sa -o out --debug-san`
```
// 产物在 alloc/free 点插入簿记
// 伪代码等价：
//   alloc: __sa_san_register(ptr, size);
//   free:  __sa_san_check_and_unregister(ptr);  // UAF/Double-Free 检测
// 性能损耗 2-5x，仅用于调试前端降级错误
// 检测到 UAF 时输出：
// {"trap":"UseAfterFree","address":"0x...","alloc_site":{"file":"main.rs","line":42},"free_site":{"file":"main.rs","line":50}}
```

### 使用场景

| 模式 | 何时用 | 性能代价 | 安全保障 |
|---|---|---|---|
| `--release`（默认） | 生产部署 | 零 | 编译期 Referee 已通过 = 内存安全（前端合约正确的前提下） |
| `--debug-gas` | LLM 沙盒 / 不信任的代码 | ~5% | 防无限循环/递归 |
| `--debug-san` | 调试前端降级错误 | 2-5x | 运行期侦测 UAF / Double-Free / 悬空引用 |

**关键（R27.5）**：`--release` 模式下发生段错误 = **前端降级合约（R20）被违反**，或 FFI 气闸舱外的宿主代码有 bug。这不是 SA 的责任。

---

# v0.3 设计评分追加

| 维度 | v0.2 评分 | v0.3 评分 | 证据 |
|---|---|---|---|
| VTable ABI 安全 | ⚠️ `call_indirect` 无校验 | ✅ 编译期签名 tuple 比对 | 案例 29（R25） |
| async/await 膨胀 | ⚠️ 40x 膨胀 | ✅ ~13x（宏模板缓解） | 案例 30（R26） |
| 运行期安全诊断 | ❌ 无 | ✅ `--debug-san` UAF 检测 | 案例 31（R27） |
| Gas 防御 | ⚠️ 仅编译期报告 | ✅ `--debug-gas` 运行期熔断 | 案例 31（R27） |

---

## 32. `sa layout` 布局生成工具（R7b） ✅

### 问题场景：LLM 手算偏移量出错

```
// LLM 容易犯的错误：i32 后跟 f64，忘了对齐 padding
#def Entity_id    = +0     // u32, 4 bytes
#def Entity_pos_x = +4     // ❌ 错！f64 需要 8 字节对齐，应该是 +8
```

### 解法：`sa layout` 工具自动生成正确的 `#def` 字典

```bash
$ sa layout --name Entity --fields "id:u32, pos_x:f64, pos_y:f64, hp:i32"

#def Entity_SIZE  = 32
#def Entity_id    = +0     // u32, 4 bytes
                           // 4 bytes padding (align f64 to 8)
#def Entity_pos_x = +8    // f64, 8 bytes
#def Entity_pos_y = +16   // f64, 8 bytes
#def Entity_hp    = +24   // i32, 4 bytes
                           // 4 bytes tail padding (align struct to 8)
```

### SA 中使用生成的字典

```
// 直接粘贴 sa layout 的输出
#def Entity_SIZE  = 32
#def Entity_id    = +0
#def Entity_pos_x = +8
#def Entity_pos_y = +16
#def Entity_hp    = +24

@update_entity(e: &ptr, dx: f64, dy: f64):
L_ENTRY:
    // 用常量名访问字段，永远不需要手算偏移量
    px = load e+Entity_pos_x as f64
    py = load e+Entity_pos_y as f64
    new_px = fadd px, dx
    new_py = fadd py, dy
    store e+Entity_pos_x, new_px as f64
    store e+Entity_pos_y, new_py as f64
    return
```

### JSON 输出格式（供 LLM 程序化消费）

```bash
$ sa layout --name Entity --fields "id:u32, pos_x:f64, pos_y:f64, hp:i32" --format json
```

```json
{
  "name": "Entity",
  "size": 32,
  "max_align": 8,
  "fields": [
    {"name": "id", "offset": 0, "size": 4, "align": 4, "ty": "u32"},
    {"name": "pos_x", "offset": 8, "size": 8, "align": 8, "ty": "f64"},
    {"name": "pos_y", "offset": 16, "size": 8, "align": 8, "ty": "f64"},
    {"name": "hp", "offset": 24, "size": 4, "align": 4, "ty": "i32"}
  ]
}
```

### 对齐规则

| 类型 | 大小 | 对齐 |
|---|---|---|
| `i8` / `u8` | 1 | 1 |
| `i16` / `u16` | 2 | 2 |
| `i32` / `u32` / `f32` | 4 | 4 |
| `i64` / `u64` / `f64` / `ptr` | 8 | 8（`--target 32` 时 ptr 对齐为 4） |

### LLM 工作流

```
1. LLM 决定需要一个结构体
2. LLM 调用: sa layout --name X --fields "a:i32, b:f64, c:ptr"
3. 工具输出正确的 #def 字典
4. LLM 把字典粘贴到 .sa 文件顶部
5. LLM 用常量名写代码: load ptr+X_b as f64
6. 永远不需要手算偏移量
7. 永远不会因为对齐错误导致内存踩踏
```

**为什么这个工具是 v0.1 必需的**：LLM 生成 SA 代码时的**头号错误来源**就是偏移量算错。这个 ~100 行 Zig 的小工具，对 LLM 生成正确代码的成功率提升是**决定性的**。
