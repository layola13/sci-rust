# 架构设计参考 (Technical Design Reference)

- [x] 2026-08-21 `sa_std` facade completion pass：补齐公共类型与子模块入口、环境/时间/FFI/线程命名别名、`BinaryHeap::contains`、`RwLock` 自旋清理，并新增 `FORMAT_*_TO_STRING` / `FORMAT_WRITE_*` / `FORMAT_WRITELN_*` concrete 格式化表面及 focused 行为测试；同步 `docs/std_missing.md`。仍不主张 Rust 泛型/variadic `format!`、panic unwinding/catch_unwind、trait/lifetime 语义；Windows 非 runner 聚合环境大测试仍有独立 LLVM backend blocker。
- [x] 2026-08-21 std validation hardening：拆分 Windows 环境 mega-suite 的超大首测后，18 个环境行为测试全部通过；修复 `LinkedList`、`Barrier`、`Condvar`、`MPSC`、`MPSC list`、定时 `Mutex` 的 borrowed-register cleanup；`sa_std` 全部 122 个 `.sa` 文件通过 `sa check`。
- [x] 2026-08-21 facade layout validation：修正 8 个新增 `.sal` facade 的注释语法，`sa_std` 全部 100 个 `.sal` 文件通过 `sa check`。

- [x] `std::collections::HashMap::values_mut` concrete eager alias 批次已完成：新增 `MAP_VALUES_MUT`，复用 `MAP_VALUES_MUT_PTRS` 按 open-addressed slot scan arbitrary order 物化 raw value-slot pointer bits，支持原地更新且不消费 map；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust lazy `ValuesMut<'a,K,V>` object、scoped mutable references/lifetimes、aliasing guarantees、generic value ABI、hash table iterator layout 或 panic/drop cleanup。
- [x] `std::collections::BTreeMap::values_mut` concrete eager alias 批次已完成：新增 `BTREE_MAP_VALUES_MUT`，复用 `BTREE_MAP_VALUES_MUT_PTRS` 按 sorted key order 物化 raw `u64` value-slot pointer bits，支持原地更新且不消费 map；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust lazy `ValuesMut<'a,K,V>` object、scoped mutable references/lifetimes、aliasing guarantees、generic value ABI、B-tree traversal internals 或 panic/drop cleanup。
- [x] `std::collections::HashMap::retain(pred)` / `extract_if(pred)` concrete mutable-predicate lowering 批次已完成：更新 `MAP_RETAIN` / `MAP_EXTRACT_IF` 让谓词接收 concrete `key_ptr, value_slot_ptr` 原始指针；`MAP_EXTRACT_IF` 在谓词返回后重新读取被提取项的 value，再物化到 removed Vec，确保谓词写回保留。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust `FnMut(&K, &mut V)` borrow ABI、lazy iterator object、partial consumption、aliasing guarantee、generic value ABI 或 panic/drop cleanup。
- [x] `std::collections::BTreeSet::extract_if(range, pred)` concrete half-open ranged eager lowering 批次已完成：新增 `BTREE_SET_EXTRACT_IF_RANGE`，复用 `BTREE_SET_RANGE` 仅对 `[start,end)` sorted key snapshot 调用 `key_slice -> u64` predicate，物化命中 keys 后再从 source set 移除；区间外 keys 不调用 predicate。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust `RangeBounds` excluded/included/unbounded variants、lazy `ExtractIf` object、partial consumption、reference lifetime、generic `Ord`、allocator cloning、drop repair 或 panic/leak cleanup。
- [x] `std::collections::BTreeMap::extract_if(range, pred)` concrete half-open ranged eager lowering 批次已完成：新增 `BTREE_MAP_EXTRACT_IF_RANGE`，复用 `BTREE_MAP_RANGE_MUT_PTRS` 仅对 `[start,end)` sorted entries 调用 `key_slice,value_slot_ptr -> u64` predicate，保留区间内 value 修改，物化命中 entries 后再从 source map 移除；区间外 entries 不调用 predicate。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust `RangeBounds` excluded/included/unbounded variants、lazy `ExtractIf` object、partial consumption、reference lifetime/aliasing、generic `Ord`、allocator cloning、drop repair 或 panic/leak cleanup。
- [x] `std::collections::BTreeMap::extract_if` concrete full-range eager lowering 批次已完成：新增 `BTREE_MAP_EXTRACT_IF`，对 sorted-array entries 调用 concrete `key_slice,value_slot_ptr -> u64` predicate，保留 predicate 对 value 的原地修改，把命中 key/value 物化到新 sorted BTreeMap，并将未命中 entries 稳定压缩回 source map；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust range-bounded lazy `ExtractIf` object、partial iterator consumption、`FnMut(&K,&mut V)` reference/lifetime ABI、generic `RangeBounds`/`Ord`、allocator cloning、drop repair 或 panic/leak cleanup。
- [x] `std::collections::BTreeSet::extract_if` concrete full-range eager lowering 批次已完成：新增 `BTREE_SET_EXTRACT_IF`，对 sorted-array entries 调用 concrete `key_slice -> u64` predicate，把命中 keys 物化到新 sorted BTreeSet，并将未命中 entries 稳定压缩回 source set；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust range-bounded lazy `ExtractIf` object、partial iterator consumption、`FnMut(&T)` reference/lifetime ABI、generic `RangeBounds`/`Ord`、allocator cloning、drop repair 或 panic/leak cleanup。
- [x] `std::collections::BTreeMap::range_mut` concrete eager lowering 批次已完成：新增 `BTREE_MAP_RANGE_MUT_PTRS`，沿用 half-open `[start,end)` concrete slice-key bounds，按 sorted-array entry order 物化 flat `Vec<u64>` triples `key_ptr_bits,key_len,value_slot_ptr_bits`，返回的 raw value-slot pointers 可原地更新 source map；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust `RangeBounds` bound variants、lazy/double-ended `RangeMut` object、scoped mutable reference lifetime、borrow aliasing、generic `Ord`/`Borrow` dispatch、node traversal internals 或 panic/drop cleanup。
- [x] `std::collections::BTreeSet` owned `IntoIterator` concrete eager alias 批次已完成：新增 `BTREE_SET_INTO_ITER`，先按 sorted-array entry order 物化 flat `Vec<u64>` pairs `key_ptr_bits,key_len`，再清空 source set；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust owned `IntoIter` object layout/drop glue、generic item ownership/drop semantics、allocator state、B-tree node traversal internals、lazy consumption 或 panic/drop cleanup。
- [x] `std::collections::HashSet` owned `IntoIterator` concrete eager alias 批次已完成：新增 `SET_INTO_ITER`，复用 `SET_DRAIN` 物化 arbitrary-order key pointer bits 并清空 source set；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust owned `IntoIter` object layout/drop glue、generic item ownership/drop semantics、allocator state、lazy consumption 或 panic/drop cleanup。
- [x] `std::collections::BTreeMap` `IntoIterator` concrete eager alias 批次已完成：新增 `BTREE_MAP_REF_INTO_ITER` / `BTREE_MAP_MUT_REF_INTO_ITER` / `BTREE_MAP_INTO_ITER`，复用现有 sorted key-order eager materialization helper，覆盖 `&BTreeMap`、`&mut BTreeMap` 和 owned consuming iterator 名称层；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust lazy iterator object、owned `IntoIter` layout/drop glue、scoped references/lifetimes、aliasing guarantees、generic item ABI、allocator state、B-tree node traversal internals 或 panic/drop cleanup。
- [x] `std::collections::HashMap` `IntoIterator` concrete eager alias 批次已完成：新增 `MAP_REF_INTO_ITER` / `MAP_MUT_REF_INTO_ITER` / `MAP_INTO_ITER`，分别复用 `MAP_ITER` / `MAP_ITER_MUT_PTRS` / `MAP_DRAIN`，覆盖 `&HashMap`、`&mut HashMap` 和 owned consuming iterator 名称层；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust lazy iterator object、owned `IntoIter` layout/drop glue、scoped references/lifetimes、aliasing guarantees、generic item ABI、allocator state 或 panic/drop cleanup。
- [x] `std::collections::HashSet` bit-operator concrete alias 批次已完成：新增 `SET_BITOR` / `SET_BITAND` / `SET_SUB` / `SET_BITXOR`，复用现有 eager union/intersection/difference/symmetric-difference helper，物化新 pointer-key set 且不消费输入；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust lazy set-algebra adapter、scoped references/lifetimes、generic hash/build-hasher dispatch、allocator cloning、trait object 或 panic/drop cleanup。
- [x] `std::collections::BTreeSet` bit-operator concrete alias 批次已完成：新增 `BTREE_SET_BITOR` / `BTREE_SET_BITAND` / `BTREE_SET_SUB` / `BTREE_SET_BITXOR`，复用现有 eager union/intersection/difference/symmetric-difference helper，物化新 sorted-array set 且不消费输入；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 不主张 Rust lazy set-algebra adapter、scoped references/lifetimes、generic `Ord` / `Clone` dispatch、allocator cloning、trait object 或 panic/drop cleanup。
- [x] `std::collections::BTreeSet::iter` / `IntoIterator for &BTreeSet` concrete eager alias 批次已完成：新增 `BTREE_SET_ITER` / `BTREE_SET_REF_INTO_ITER`，按 sorted-array entry order 物化 flat `Vec<u64>` pairs `key_ptr_bits,key_len`，不消费 set；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 concrete eager lowering，不主张 Rust lazy `Iter` object、scoped references、borrow lifetimes、generic `&T` item ABI、owned `IntoIter`、lazy set algebra adapters、B-tree node traversal internals 或 panic/drop cleanup。
- [x] `std::collections::BTreeMap::iter` / `iter_mut` concrete eager alias 批次已完成：新增 `BTREE_MAP_ITER` / `BTREE_MAP_ITER_MUT_PTRS`，按 sorted-array entry order 物化 flat `Vec<u64>` triples；`BTREE_MAP_ITER` 输出 `key_ptr_bits,key_len,value`，`BTREE_MAP_ITER_MUT_PTRS` 输出 `key_ptr_bits,key_len,value_slot_ptr_bits` 以支持原地更新 stored value。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 concrete eager lowering，不主张 Rust lazy `Iter` / `IterMut` object、scoped references、borrow lifetimes、aliasing guarantees、generic tuple/reference item ABI、B-tree node traversal internals 或 panic/drop cleanup。
- [x] `std::collections::HashSet::iter` / `IntoIterator for &HashSet` concrete eager alias 批次已完成：新增 `SET_ITER` / `SET_REF_INTO_ITER`，复用 `SET_KEYS` 按现有 open-addressed slot scan 物化 arbitrary-order key pointer bits；新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 concrete eager lowering，不主张 Rust lazy `Iter` object、scoped references、borrow lifetimes、generic `&T` item ABI、owned `IntoIter`、lazy set algebra adapters 或 panic/drop cleanup。
- [x] `std::collections::HashMap::iter` / `iter_mut` concrete eager alias 批次已完成：新增 `MAP_ITER` / `MAP_ITER_MUT_PTRS`，按现有 open-addressed slot scan 物化 arbitrary-order interleaved `Vec<u64>`；`MAP_ITER` 输出 key/value pointer bits，`MAP_ITER_MUT_PTRS` 输出 key pointer bits/value-slot pointer bits 以支持原地更新 stored value。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 concrete eager lowering，不主张 Rust lazy `Iter` / `IterMut` object、scoped references、borrow lifetimes、aliasing guarantees、generic tuple/reference item ABI 或 panic/drop cleanup。
- [x] `std::collections::VecDeque::drain(range)` concrete eager lowering 批次已完成：新增 `VEC_DEQUE_TRY_DRAIN_RANGE_U64` / `VEC_DEQUE_DRAIN_RANGE_U64`，先强制 wrapped deque contiguous，再通过临时 `Vec<u64>` 复用 `VEC_DRAIN_U64`，返回 drained range 的 caller-owned Vec，并按剩余值 front-to-back rebuild deque；非法 range 返回 `ok=0`、空 Vec、原 deque 不变。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 concrete eager lowering，不主张 Rust lazy `Drain` object、`RangeBounds` 泛型语法、allocator access、leak/drop repair、scoped references、panic object 或 generic item move/drop 语义。
- [x] `std::collections::VecDeque::splice` concrete eager lowering 批次已完成：新增 `VEC_DEQUE_SPLICE_U64`，先强制 wrapped deque contiguous，再通过临时 `Vec<u64>` 复用 `VEC_SPLICE_U64`，返回 drained range 的 caller-owned Vec，并按 spliced 结果 front-to-back rebuild deque。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 concrete eager lowering，不主张 Rust lazy `Splice` object、generic replacement iterator、allocator access、scoped references、partial-consumption drop behavior、panic object 或 generic item move/drop 语义。
- [x] `std::collections::VecDeque::extract_if` concrete eager lowering 批次已完成：新增 `VEC_DEQUE_EXTRACT_IF_U64`，先强制 wrapped deque contiguous，再按 front-to-back 顺序把 predicate 命中值 materialize 到 caller-owned Vec，并保持未命中值原序 compact 在 deque。新增 focused 单测并同步 `progress/current_plan/std_missing`。该 helper 是 full-range eager lowering，不主张 Rust lazy/range-bounded `ExtractIf` object、`FnMut(&mut T)` reference ABI、partial-consumption drop repair、allocator access、generic item move/drop 或 panic/leak cleanup。
- [x] `std::collections::VecDeque` iter_mut 批次已完成：新增 `VEC_DEQUE_ITER_MUT_U64`、`VEC_DEQUE_MUT_REF_INTO_ITER_U64`、`VEC_DEQUE_ITER_MUT_AS_REF_SLICE_U64`、`VEC_DEQUE_ITER_MUT_AS_MUT_SLICE_U64`、`VEC_DEQUE_ITER_MUT_NEXT_U64`、`VEC_DEQUE_ITER_MUT_NEXT_BACK_U64`、`VEC_DEQUE_ITER_MUT_SIZE_HINT_U64`、`VEC_DEQUE_ITER_MUT_EXACT_SIZE_LEN_U64`、`VEC_DEQUE_ITER_MUT_EXACT_SIZE_IS_EMPTY_U64`。实现先 `MAKE_CONTIGUOUS` 再建立 concrete mutable slice-backed cursor，覆盖 wrapped deque 顺序、remaining slice mutation、double-ended/exact-size 状态与 `&mut VecDeque` into-iterator alias。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust split two-slice `IterMut` object layout、reference lifetimes、borrow aliasing、generic mutable reference item semantics、drop glue 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator view/clone 批次已完成：新增 `VEC_DEQUE_ITER_DEFAULT_U64`、`VEC_DEQUE_ITER_AS_REF_SLICE_U64`、`VEC_DEQUE_ITER_CLONE_U64`、`VEC_DEQUE_INTO_ITER_DEFAULT_U64`、`VEC_DEQUE_INTO_ITER_AS_SLICE_U64`、`VEC_DEQUE_INTO_ITER_AS_MUT_SLICE_U64`、`VEC_DEQUE_INTO_ITER_AS_REF_SLICE_U64`、`VEC_DEQUE_INTO_ITER_CLONE_U64`，复用 snapshot/drained backing cursor 与 concrete Iter/Vec clone/view helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust reference lifetimes、mutable reference aliasing、generic `Clone` trait dispatch、owned iterator allocator cloning、object layout/drop glue 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator callback/chunk 批次已完成：新增 `VEC_DEQUE_ITER_TRY_NEXT_CHUNK_U64`、`VEC_DEQUE_ITER_FOR_EACH_U64`、`VEC_DEQUE_ITER_TRY_FOR_EACH_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator next_chunk / callback helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust const-generic array remainder ABI、generic `Try` residual conversion、closure capture、borrowed reference item semantics、allocator-parametric owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator extended collect 批次已完成：新增 `VEC_DEQUE_ITER_TRY_COLLECT_U64`、`VEC_DEQUE_ITER_COLLECT_INTO_U64`、`VEC_DEQUE_ITER_COPIED_COLLECT_U64`、`VEC_DEQUE_ITER_CLONED_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator collect helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `Try` residual conversion、generic `FromIterator`/`Extend` dispatch、borrowed reference item semantics、generic `Copy`/`Clone` trait dispatch、allocator-parametric owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator array/window collect 批次已完成：新增 `VEC_DEQUE_ITER_ARRAY_CHUNKS_COLLECT_U64`、`VEC_DEQUE_ITER_MAP_WINDOWS_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator array/window helpers，并 eager materialize `Vec<u64>` 输出。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust const-generic array item/reference ABI、lazy `ArrayChunks` / `MapWindows` adapter identity/state、generic closure capture、allocator-parametric owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator adapter-state collect 批次已完成：新增 `VEC_DEQUE_ITER_BY_REF_COLLECT_U64`、`VEC_DEQUE_ITER_FUSE_COLLECT_U64`、`VEC_DEQUE_ITER_PEEKABLE_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator adapter-state helpers，并 eager materialize `Vec<u64>` 输出。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lazy `ByRef` / `Fuse` / `Peekable` adapter identity/state、buffered peekable state、borrow lifetime/reference items、allocator-parametric owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator pair/composition collect 批次已完成：新增 `VEC_DEQUE_ITER_ENUMERATE_COLLECT_U64`、`VEC_DEQUE_ITER_ZIP_COLLECT_U64`、`VEC_DEQUE_ITER_CHAIN_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator pair/composition helpers，并 eager materialize `Vec<u64>` 输出。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust tuple ABI、generic `IntoIterator`/`FromIterator` dispatch、lazy adapter identity/state、allocator-parametric owned iterator layout、reference item/lifetime、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator sequence collect 批次已完成：新增 `VEC_DEQUE_ITER_INTERSPERSE_COLLECT_U64`、`VEC_DEQUE_ITER_INTERSPERSE_WITH_COLLECT_U64`、`VEC_DEQUE_ITER_CYCLE_TAKE_COLLECT_U64`、`VEC_DEQUE_ITER_TAKE_WHILE_COLLECT_U64`、`VEC_DEQUE_ITER_SKIP_WHILE_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator sequence helpers，并 eager materialize `Vec<u64>` 输出。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lazy `Cycle` / `Intersperse` / `TakeWhile` / `SkipWhile` adapter identity、generic `Option`/`FromIterator`、closure capture、allocator-parametric owned iterator layout、reference item/lifetime、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator transform/filter collect 批次已完成：新增 `VEC_DEQUE_ITER_MAP_COLLECT_U64`、`VEC_DEQUE_ITER_INSPECT_COLLECT_U64`、`VEC_DEQUE_ITER_SCAN_COLLECT_U64`、`VEC_DEQUE_ITER_FILTER_COLLECT_U64`、`VEC_DEQUE_ITER_FILTER_MAP_COLLECT_U64`、`VEC_DEQUE_ITER_MAP_WHILE_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator transform/filter helpers，并 eager materialize `Vec<u64>` 输出。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lazy adapter identity/state、generic `Option`/`FromIterator`/`Try` conversion、closure capture、allocator-parametric owned iterator layout、reference item/lifetime、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator eager adapter collect 批次已完成：新增 `VEC_DEQUE_ITER_TAKE_COLLECT_U64`、`VEC_DEQUE_ITER_SKIP_COLLECT_U64`、`VEC_DEQUE_ITER_REV_COLLECT_U64`、`VEC_DEQUE_ITER_TRY_STEP_BY_COLLECT_U64`、`VEC_DEQUE_ITER_STEP_BY_COLLECT_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator adapter helpers，并 eager materialize `Vec<u64>` 输出。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lazy adapter identity/state、generic `IntoIterator`/`FromIterator`、`NonZero<usize>` ABI、allocator-parametric owned iterator layout、reference item/lifetime、closure capture、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator sortedness/partition 批次已完成：新增 `VEC_DEQUE_ITER_IS_SORTED_U64`、`VEC_DEQUE_ITER_IS_SORTED_BY_U64`、`VEC_DEQUE_ITER_IS_SORTED_BY_KEY_U64`、`VEC_DEQUE_ITER_PARTITION_U64`、`VEC_DEQUE_ITER_IS_PARTITIONED_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete sortedness/partition helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `PartialOrd`/`Ord` dispatch、closure capture、lazy adapter/object identity、`Default`/`Extend` generic collection dispatch、reference item/lifetime、owned iterator layout、allocator state、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator comparison/key aggregate 批次已完成：新增 `VEC_DEQUE_ITER_MIN_BY_U64`、`VEC_DEQUE_ITER_MAX_BY_U64`、`VEC_DEQUE_ITER_MIN_BY_KEY_U64`、`VEC_DEQUE_ITER_MAX_BY_KEY_U64`、`VEC_DEQUE_ITER_CMP_U64`、`VEC_DEQUE_ITER_CMP_BY_U64`、`VEC_DEQUE_ITER_PARTIAL_CMP_U64`、`VEC_DEQUE_ITER_PARTIAL_CMP_BY_U64`、`VEC_DEQUE_ITER_EQ_BY_U64`、`VEC_DEQUE_ITER_EQ_U64`、`VEC_DEQUE_ITER_PARTIAL_EQ_U64`、`VEC_DEQUE_ITER_NE_U64`、`VEC_DEQUE_ITER_LT_U64`、`VEC_DEQUE_ITER_LE_U64`、`VEC_DEQUE_ITER_GT_U64`、`VEC_DEQUE_ITER_GE_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete iterator comparison/key helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `Ord`/`PartialOrd` dispatch、closure capture、`Option<Ordering>` ABI、reference item/lifetime、owned iterator layout、allocator state、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator fold/aggregate 批次已完成：新增 `VEC_DEQUE_ITER_FOLD_U64`、`VEC_DEQUE_ITER_TRY_FOLD_U64`、`VEC_DEQUE_ITER_RFOLD_U64`、`VEC_DEQUE_ITER_TRY_RFOLD_U64`、`VEC_DEQUE_ITER_SUM_U64`、`VEC_DEQUE_ITER_PRODUCT_U64`、`VEC_DEQUE_ITER_MIN_U64`、`VEC_DEQUE_ITER_MAX_U64`、`VEC_DEQUE_ITER_REDUCE_U64`、`VEC_DEQUE_ITER_TRY_REDUCE_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete forward/reverse fold helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、`Try` residual、`Sum`/`Product`/`Ord` trait dispatch、`Option` ABI、reference item/lifetime、owned iterator layout 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator search/predicate 批次已完成：新增 `VEC_DEQUE_ITER_FIND_U64`、`VEC_DEQUE_ITER_TRY_FIND_U64`、`VEC_DEQUE_ITER_FIND_MAP_U64`、`VEC_DEQUE_ITER_POSITION_U64`、`VEC_DEQUE_ITER_RPOSITION_U64`、`VEC_DEQUE_ITER_RFIND_U64`、`VEC_DEQUE_ITER_ANY_U64`、`VEC_DEQUE_ITER_ALL_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete forward/reverse iterator helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、`Option`/`Result` ABI、reference item/lifetime、owned iterator layout、allocator state、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator cursor op 批次已完成：新增 `VEC_DEQUE_ITER_NTH_U64`、`VEC_DEQUE_ITER_NTH_BACK_U64`、`VEC_DEQUE_ITER_ADVANCE_BY`、`VEC_DEQUE_ITER_ADVANCE_BACK_BY`、`VEC_DEQUE_ITER_COUNT_U64`、`VEC_DEQUE_ITER_LAST_U64` 以及对应 `VEC_DEQUE_INTO_ITER_*` alias，复用 snapshot/drained backing cursor 与 concrete double-ended iterator helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option`/`NonZero` ABI、reference item/lifetime、owned iterator layout、allocator state、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::VecDeque` borrowed/consuming iterator 基础批次已完成：新增 `VEC_DEQUE_ITER_U64`、`VEC_DEQUE_REF_INTO_ITER_U64`、`VEC_DEQUE_INTO_ITER_U64` 以及 forward/back cursor、size hint、exact-size、collect aliases；borrowed 入口使用 front-to-back snapshot backing，consuming 入口 drain 原 deque 到显式 backing Vec。新增 wrapped deque focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust reference item/lifetime、`Iter`/`IntoIter` object layout、allocator parameter、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` inspect/scan/step_by eager collect 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_INSPECT_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_SCAN_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TRY_STEP_BY_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_STEP_BY_COLLECT_U64`，复用现有 materialized descending cursor 与 concrete iterator transform/step helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 lazy adapter state、`NonZero<usize>`/array remainder ABI、generic `Option` / closure capture、allocator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` zip/chain eager collect 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_ZIP_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_CHAIN_COLLECT_U64`，复用现有 materialized descending cursors 与 concrete iterator pair/composition helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 tuple ABI、generic `IntoIterator` dispatch、lazy adapter state、allocator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` sequence eager collect 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_INTERSPERSE_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_INTERSPERSE_WITH_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_CYCLE_TAKE_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TAKE_WHILE_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_SKIP_WHILE_COLLECT_U64`，复用现有 materialized descending cursor 与 concrete iterator sequence helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 lazy adapter state、无限 `Cycle` object、generic `Option` / closure capture、allocator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` array/window eager collect 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_ARRAY_CHUNKS_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MAP_WINDOWS_COLLECT_U64`，复用现有 materialized descending cursor 与 concrete iterator array/window helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 const-generic array ABI、borrowed window lifetime、lazy adapter state、generic closure/FromIterator、allocator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` enumerate/adapter-state eager collect 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_ENUMERATE_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_BY_REF_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_FUSE_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_PEEKABLE_COLLECT_U64`，复用现有 materialized descending cursor 与 concrete iterator adapter-state helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 lazy adapter object state、Rust borrow lifetime、tuple ABI、generic `IntoIterator` / `FromIterator`、allocator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` transform/filter eager collect 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_MAP_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_FILTER_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_FILTER_MAP_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MAP_WHILE_COLLECT_U64`，复用现有 materialized descending cursor 与 concrete iterator transform/filter helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 lazy adapter object state、generic `Option` / `Try` / closure capture、allocator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` take/skip eager adapter 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_TAKE_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_SKIP_COLLECT_U64`，复用现有 materialized descending cursor 与 concrete iterator adapter collect helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `rev` / `DoubleEndedIterator`、lazy adapter object state、generic `IntoIterator` / `FromIterator` / allocator layout、closure capture、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` partition 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_PARTITION_U64`、`BINARY_HEAP_INTO_ITER_SORTED_IS_PARTITIONED_U64`，复用现有 materialized descending cursor 与 concrete iterator partition helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `Default` / `Extend` / `Try` trait dispatch、closure capture、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` sortedness 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_IS_SORTED_U64`、`BINARY_HEAP_INTO_ITER_SORTED_IS_SORTED_BY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_IS_SORTED_BY_KEY_U64`，复用现有 materialized descending cursor 与 concrete iterator sortedness helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `PartialOrd` dispatch、closure capture、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` comparison/key aggregate 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_MIN_BY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MAX_BY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MIN_BY_KEY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MAX_BY_KEY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_CMP_U64`、`BINARY_HEAP_INTO_ITER_SORTED_CMP_BY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_PARTIAL_CMP_U64`、`BINARY_HEAP_INTO_ITER_SORTED_PARTIAL_CMP_BY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_EQ_BY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_EQ_U64`、`BINARY_HEAP_INTO_ITER_SORTED_PARTIAL_EQ_U64`、`BINARY_HEAP_INTO_ITER_SORTED_NE_U64`、`BINARY_HEAP_INTO_ITER_SORTED_LT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_LE_U64`、`BINARY_HEAP_INTO_ITER_SORTED_GT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_GE_U64`，复用现有 materialized descending cursor 与 concrete iterator comparison/key helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `Ord` / `PartialOrd` dispatch、closure capture、`Option<Ordering>` ABI、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` fold/aggregate 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_FOLD_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TRY_FOLD_U64`、`BINARY_HEAP_INTO_ITER_SORTED_SUM_U64`、`BINARY_HEAP_INTO_ITER_SORTED_PRODUCT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MIN_U64`、`BINARY_HEAP_INTO_ITER_SORTED_MAX_U64`、`BINARY_HEAP_INTO_ITER_SORTED_REDUCE_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TRY_REDUCE_U64`，复用现有 materialized descending cursor 与 concrete iterator fold/aggregate helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `DoubleEndedIterator` / reverse fold、Rust closure capture、generic `Try` residual conversion、`Sum` / `Product` / `Ord` trait dispatch、`Option` ABI、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` any/all/for_each 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_ANY_U64`、`BINARY_HEAP_INTO_ITER_SORTED_ALL_U64`、`BINARY_HEAP_INTO_ITER_SORTED_FOR_EACH_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TRY_FOR_EACH_U64`，复用现有 materialized descending cursor 与 concrete iterator predicate/callback helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `DoubleEndedIterator`、Rust closure capture、generic `Try` residual conversion、`Option` ABI、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` search/predicate 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_FIND_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TRY_FIND_U64`、`BINARY_HEAP_INTO_ITER_SORTED_FIND_MAP_U64`、`BINARY_HEAP_INTO_ITER_SORTED_POSITION_U64`，复用现有 materialized descending cursor 与 concrete iterator search helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `DoubleEndedIterator` / reverse search、Rust closure capture、generic `Try` residual conversion、`Option` ABI、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` advance/chunk 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_TRY_NEXT_CHUNK_U64`、`BINARY_HEAP_INTO_ITER_SORTED_ADVANCE_BY`，复用现有 materialized descending cursor 与 concrete iterator advance/chunk helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `DoubleEndedIterator` / `advance_back_by`、Rust `array::IntoIter` remainder ABI、`NonZero<usize>` layout、const-generic array ABI、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIterSorted` cursor/terminal op 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SORTED_NTH_U64`、`BINARY_HEAP_INTO_ITER_SORTED_COUNT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_LAST_U64`，复用现有 materialized descending cursor 与 concrete iterator terminal helpers，以 Rust `IntoIterSorted` 的 forward `Iterator` 默认方法表面覆盖 greatest-first order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `DoubleEndedIterator`、Rust `Option<T>` ABI、lazy pop-on-next storage、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` for_each/try_for_each 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_FOR_EACH_U64`、`BINARY_HEAP_INTO_ITER_TRY_FOR_EACH_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator callback helpers，以 Rust owned `IntoIter` 的 `for_each` / `try_for_each` 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` any/all 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_ANY_U64`、`BINARY_HEAP_INTO_ITER_ALL_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator search helpers，以 Rust owned `IntoIter` 的 `any` / `all` 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、`Option` ABI、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` search/predicate 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_FIND_U64`、`BINARY_HEAP_INTO_ITER_TRY_FIND_U64`、`BINARY_HEAP_INTO_ITER_FIND_MAP_U64`、`BINARY_HEAP_INTO_ITER_POSITION_U64`、`BINARY_HEAP_INTO_ITER_RPOSITION_U64`、`BINARY_HEAP_INTO_ITER_RFIND_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator search helpers，以 Rust owned `IntoIter` 的 predicate/search 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、`Option` ABI、owned iterator layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` advance/chunk 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_TRY_NEXT_CHUNK_U64`、`BINARY_HEAP_INTO_ITER_ADVANCE_BY`、`BINARY_HEAP_INTO_ITER_ADVANCE_BACK_BY`，复用现有 Vec-backed consuming cursor 与 concrete iterator helper，以 Rust owned `IntoIter` 的 `next_chunk` / `advance_by` / `advance_back_by` 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `array::IntoIter` remainder ABI、`NonZero<usize>` layout、const-generic array item ABI、owned iterator layout 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` cursor/terminal op 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_NTH_U64`、`BINARY_HEAP_INTO_ITER_NTH_BACK_U64`、`BINARY_HEAP_INTO_ITER_COUNT_U64`、`BINARY_HEAP_INTO_ITER_LAST_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator terminal helpers，以 Rust owned `IntoIter` 的 `nth` / `nth_back` / `count` / `last` 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option<T>` ABI、allocator-parametric owned iterator layout、generic item move/drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` aggregate/reduce 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_SUM_U64`、`BINARY_HEAP_INTO_ITER_PRODUCT_U64`、`BINARY_HEAP_INTO_ITER_MIN_U64`、`BINARY_HEAP_INTO_ITER_MAX_U64`、`BINARY_HEAP_INTO_ITER_REDUCE_U64`、`BINARY_HEAP_INTO_ITER_TRY_REDUCE_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator aggregate/reduce helpers，以 Rust owned `IntoIter` 的 terminal aggregate/reduce 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Sum`/`Product`/`Ord` trait dispatch、generic `Try` residual conversion、`Option` ABI、owned iterator object layout 或 generic item 语义。
- [x] `std::collections::BinaryHeap::IntoIter` fold/try_fold/rfold/try_rfold 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_FOLD_U64`、`BINARY_HEAP_INTO_ITER_TRY_FOLD_U64`、`BINARY_HEAP_INTO_ITER_RFOLD_U64`、`BINARY_HEAP_INTO_ITER_TRY_RFOLD_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator fold helpers，以 Rust owned `IntoIter` 的 fold 表面覆盖 heap-array backing order 与 reverse heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、owned iterator object layout、generic item drop 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::IntoIter` comparison/key aggregate 别名批次已完成：新增 `BINARY_HEAP_INTO_ITER_MIN_BY_U64`、`BINARY_HEAP_INTO_ITER_MAX_BY_U64`、`BINARY_HEAP_INTO_ITER_MIN_BY_KEY_U64`、`BINARY_HEAP_INTO_ITER_MAX_BY_KEY_U64`、`BINARY_HEAP_INTO_ITER_CMP_U64`、`BINARY_HEAP_INTO_ITER_CMP_BY_U64`、`BINARY_HEAP_INTO_ITER_PARTIAL_CMP_U64`、`BINARY_HEAP_INTO_ITER_PARTIAL_CMP_BY_U64`、`BINARY_HEAP_INTO_ITER_EQ_BY_U64`、`BINARY_HEAP_INTO_ITER_EQ_U64`、`BINARY_HEAP_INTO_ITER_PARTIAL_EQ_U64`、`BINARY_HEAP_INTO_ITER_NE_U64`、`BINARY_HEAP_INTO_ITER_LT_U64`、`BINARY_HEAP_INTO_ITER_LE_U64`、`BINARY_HEAP_INTO_ITER_GT_U64`、`BINARY_HEAP_INTO_ITER_GE_U64`，复用现有 Vec-backed consuming cursor 与 concrete iterator comparison/min_by helpers，以 Rust `Iterator` comparison/key aggregate 表面覆盖 heap-array backing order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust generic `Ord` / `PartialOrd` dispatch、closure capture、`Option<Ordering>` ABI、owned iterator object layout 或 generic item drop 语义。
- [x] `std::collections::BinaryHeap::Iter` fold/try_fold/rfold/try_rfold 别名批次已完成：新增 `BINARY_HEAP_ITER_FOLD_U64`、`BINARY_HEAP_ITER_TRY_FOLD_U64`、`BINARY_HEAP_ITER_RFOLD_U64`、`BINARY_HEAP_ITER_TRY_RFOLD_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator fold helpers，以 Rust borrowed `Iter` 的 fold 表面覆盖 heap-array order 与 reverse heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、reference item/lifetime 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` aggregate/reduce 别名批次已完成：新增 `BINARY_HEAP_ITER_SUM_U64`、`BINARY_HEAP_ITER_PRODUCT_U64`、`BINARY_HEAP_ITER_MIN_U64`、`BINARY_HEAP_ITER_MAX_U64`、`BINARY_HEAP_ITER_REDUCE_U64`、`BINARY_HEAP_ITER_TRY_REDUCE_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator aggregate helpers，以 Rust borrowed `Iter` 的 terminal aggregate/reduce 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Sum`/`Product`/`Ord` trait dispatch、generic `Try` residual conversion、`Option` ABI、reference item/lifetime 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` for_each/try_for_each 别名批次已完成：新增 `BINARY_HEAP_ITER_FOR_EACH_U64`、`BINARY_HEAP_ITER_TRY_FOR_EACH_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator callback helpers，以 Rust borrowed `Iter` 的 `for_each` / `try_for_each` 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、reference item/lifetime 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` any/all 别名批次已完成：新增 `BINARY_HEAP_ITER_ANY_U64`、`BINARY_HEAP_ITER_ALL_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator search helpers，以 Rust borrowed `Iter` 的 `any` / `all` 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、`Option` ABI、reference item/lifetime 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` search/predicate 别名批次已完成：新增 `BINARY_HEAP_ITER_FIND_U64`、`BINARY_HEAP_ITER_TRY_FIND_U64`、`BINARY_HEAP_ITER_FIND_MAP_U64`、`BINARY_HEAP_ITER_POSITION_U64`、`BINARY_HEAP_ITER_RPOSITION_U64`、`BINARY_HEAP_ITER_RFIND_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator search helpers，以 Rust borrowed `Iter` 的 predicate/search 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust closure capture、generic `Try` residual conversion、`Option` ABI、reference item/lifetime 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` advance/chunk 别名批次已完成：新增 `BINARY_HEAP_ITER_TRY_NEXT_CHUNK_U64`、`BINARY_HEAP_ITER_ADVANCE_BY`、`BINARY_HEAP_ITER_ADVANCE_BACK_BY`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator helper，以 Rust borrowed `Iter` 的 `next_chunk` / `advance_by` / `advance_back_by` 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `array::IntoIter` remainder ABI、`NonZero<usize>` layout、const-generic array item ABI、reference item/lifetime 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` cursor/terminal op 别名批次已完成：新增 `BINARY_HEAP_ITER_NTH_U64`、`BINARY_HEAP_ITER_NTH_BACK_U64`、`BINARY_HEAP_ITER_COUNT_U64`、`BINARY_HEAP_ITER_LAST_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator terminal helpers，以 Rust borrowed `Iter` 的 `nth` / `nth_back` / `count` / `last` 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust reference item/lifetime、generic item semantics、`Option<&T>` ABI 或 panic/drop cleanup。
- [x] `std::collections::BinaryHeap::Iter` collect 别名批次已完成：新增 `BINARY_HEAP_ITER_COLLECT_U64`、`BINARY_HEAP_ITER_TRY_COLLECT_U64`、`BINARY_HEAP_ITER_COLLECT_INTO_U64`，复用现有 slice-backed borrowed iterator cursor 与 concrete iterator collect helpers，以 Rust borrowed `Iter` materializing collection 表面覆盖 heap-array order。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust reference item/lifetime、generic `FromIterator` / `Extend` / `Try` residual conversion、`Result` / `Option` ABI 或泛型元素语义。
- [x] `std::net` / `std::os::unix::net` / `std::os::fd::AsFd` socket 命名别名批次已完成：新增 `NET_TCP_LISTENER_AS_FD`、`NET_TCP_STREAM_AS_FD`、`NET_UDP_AS_FD`、`NET_UNIX_LISTENER_AS_FD`、`NET_UNIX_STREAM_AS_FD`、`NET_UNIX_DATAGRAM_AS_FD`，复用现有 socket raw-fd facade，以 Rust socket `as_fd` 表面返回当前 SA borrowed raw-fd 标量形态。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lifetime、borrow checker、trait dispatch 或 `BorrowedFd<'_>` 对象布局全语义。
- [x] `std::os::{linux,unix}::process` / `std::os::fd::AsFd` 命名别名批次已完成：新增 `PIDFD_AS_FD`、`PROCESS_CHILD_STDOUT_AS_FD`、`PROCESS_CHILD_STDERR_AS_FD`，复用现有 pidfd/child pipe raw-fd facade，以 Rust `PidFd` / `ChildStdout` / `ChildStderr` `as_fd` 表面返回当前 SA borrowed raw-fd 标量形态。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `ChildStdin`、Rust lifetime、borrow checker、trait dispatch 或 `BorrowedFd<'_>` 对象布局全语义。
- [x] `std::io::{Stdin,Stdout,Stderr}` / `std::os::fd::AsFd` 命名别名批次已完成：新增 `IO_STDIN_AS_FD`、`IO_STDOUT_AS_FD`、`IO_STDERR_AS_FD`，复用固定 stdio handle 与现有 fd facade，以 Rust stdio `as_fd` 表面返回 borrowed raw-fd 标量形态。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lock guard、lifetime、borrow checker、trait dispatch 或 `BorrowedFd<'_>` 对象布局全语义。
- [x] `std::fs::File` / `std::os::fd::AsFd` 命名别名批次已完成：新增 `FS_FILE_AS_FD`，复用现有 File handle fd view，以 Rust `File::as_fd` 表面返回当前 SA borrowed raw-fd 标量形态。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lifetime、borrow checker、trait dispatch 或 `BorrowedFd<'_>` 对象布局全语义。
- [x] `std::os::fd::AsFd` 命名别名批次已完成：新增 `FD_OWNED_AS_FD` 与 `FD_BORROWED_AS_FD`，复用现有 owned/borrowed fd facade，以 Rust `OwnedFd/BorrowedFd` 的 `AsFd::as_fd` 表面返回当前 SA borrowed raw-fd 标量形态。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust lifetime、borrow checker、trait dispatch 或 `BorrowedFd<'_>` 对象布局全语义。
- [x] `std::process` Command builder exec wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_EXEC`，把现有 builder 标量状态及显式 uid/gid/groups/chroot 配置转发到真实 `PROCESS_EXEC_COMMAND_EXT` runtime 路径。新增 focused 失败路径单测并同步 `progress/current_plan/std_missing`；成功 `exec` 会替换测试进程，因此本批不运行成功路径单测。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 pre_exec closure 集成。
- [x] `std::process` Command builder stream pidfd wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_SPAWN_STREAM_PIDFD`，把现有 builder 标量状态转发到真实 `PROCESS_SPAWN_STREAM_COMMAND_EXT_PIDFD` runtime 路径，并保留显式 `create_pidfd` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time pidfd 集成。
- [x] `std::process` Command builder stream chroot wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_SPAWN_STREAM_CHROOT`，把现有 builder 标量状态转发到真实 `PROCESS_SPAWN_STREAM_COMMAND_EXT_CHROOT` runtime 路径，并保留显式 chroot pointer/len 与 `has_chroot` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time chroot 集成。
- [x] `std::process` Command builder stream groups wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_SPAWN_STREAM_GROUPS`，把现有 builder 标量状态转发到真实 `PROCESS_SPAWN_STREAM_COMMAND_EXT_GROUPS` runtime 路径，并保留显式 groups pointer/len 与 `has_groups` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time groups 集成。
- [x] `std::process` Command builder stream uid/gid wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_SPAWN_STREAM_UID_GID`，把现有 builder 标量状态转发到真实 `PROCESS_SPAWN_STREAM_COMMAND_EXT_UID_GID` runtime 路径，并保留显式 `uid/gid` 与 `has_uid/has_gid` flags。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time uid/gid 集成。
- [x] `std::process` Command builder chroot wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_STATUS_CHROOT` / `SPAWN_CHROOT`，把现有 builder 标量状态转发到真实 `PROCESS_*_COMMAND_EXT_CHROOT` runtime 路径，并保留显式 chroot pointer/len 与 `has_chroot` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time chroot 集成。
- [x] `std::process` Command builder groups wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_STATUS_GROUPS` / `SPAWN_GROUPS`，把现有 builder 标量状态转发到真实 `PROCESS_*_COMMAND_EXT_GROUPS` runtime 路径，并保留显式 groups pointer/len 与 `has_groups` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time groups 集成。
- [x] `std::process` Command builder uid/gid wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_STATUS_UID_GID` / `SPAWN_UID_GID`，把现有 builder 标量状态转发到真实 `PROCESS_*_COMMAND_EXT_UID_GID` runtime 路径，并保留显式 `uid/gid` 与 `has_uid/has_gid` flags。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time uid/gid 集成。
- [x] `std::process` Command builder pidfd wrapper 批次已完成：新增 `PROCESS_COMMAND_BUILDER_STATUS_PIDFD` / `SPAWN_PIDFD`，把现有 builder 标量状态转发到真实 `PROCESS_*_COMMAND_EXT_PIDFD` runtime 路径，并保留显式 `create_pidfd` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe Stdio redirection wiring、heap Command object 或 capture-time pidfd 集成。
- [x] `std::process::Stdio` value-object 宏表面批次已完成：新增本地 `ProcessStdio` one-byte kind 布局，以及 `PROCESS_STDIO_{PIPED,INHERIT,NULL,KIND,MAKES_PIPE}`；它只覆盖 Rust `Stdio::{piped,inherit,null}` / `makes_pipe` 的可验证值对象子集，不接入当前缺少 stdin/stdout/stderr 配置槽的 process spawn ABI。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 env maps、pipe redirection wiring、ChildStdin/Stdout/Stderr trait integration 或 heap Command object。
- [x] `std::num::SaturatingI64` arithmetic helper 批次已完成：新增 `SATURATING_I64_SET` 与 `SATURATING_I64_{ADD,SUB,MUL}`，load 具体 wrapper inner field 为 signed `i64` 后复用既有 `NUM_I64_SATURATING_*` primitive helper，并把 saturated result 写回 destination wrapper。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Saturating<T>`、assignment operator traits、缺失 wrapper 宽度、`i128` 或 trait-level 集成。
- [x] `std::num::WrappingI64` arithmetic helper 批次已完成：新增 `WRAPPING_I64_SET` 与 `WRAPPING_I64_{ADD,SUB,MUL}`，load 具体 wrapper inner field 为 signed `i64` 后复用既有 `NUM_I64_WRAPPING_*` primitive helper，并把 64-bit wrapping 结果写回 destination wrapper。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Wrapping<T>`、assignment operator traits、缺失 wrapper 宽度、`i128` 或 trait-level 集成。
- [x] `std::num::WrappingU32` arithmetic helper 批次已完成：新增 `WRAPPING_U32_SET` 与 `WRAPPING_U32_{ADD,SUB,MUL}`，load 具体 wrapper inner field 后复用既有 `NUM_U32_WRAPPING_*` primitive helper，并把结果按 32-bit 宽度 mask 后写回 destination wrapper。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Wrapping<T>`、assignment operator traits、缺失 wrapper 宽度、`u128` 或 trait-level 集成。
- [x] `std::num` 64-bit `usize` primitive saturating_div alias 批次已完成：新增 `NUM_USIZE_SATURATING_DIV`，按当前 SA 64-bit target ABI 委托 `NUM_U64_SATURATING_DIV`；成功写 quotient，零除数等 checked failure 写 `NUM_USIZE_MAX`。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 portable target-width switching、Rust panic object/message identity、`u128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive saturating_div 宏表面批次已完成：新增 `NUM_U{8,16,32}_SATURATING_DIV`，复用既有 narrow checked division 路径，成功写 quotient，零除数或 raw quotient 超出声明窄宽度时写对应 unsigned MAX；该批保持当前 SA `U64` saturating-div 表面形状，Rust unsigned `saturating_div` 的零除数 panic control-flow/object identity 仍不建模。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128` 或 trait-level 集成。
- [x] `std::num` narrow signed primitive pow 宏表面批次已完成：新增 `NUM_I{8,16,32}_POW`，base 先按声明 signed 宽度 sign-extend，再复用既有 `I64` direct pow accumulator，并把结果 sign-extend 回窄 signed 宽度；该 direct helper 暴露当前 SA direct pow / release-style wrapping result 语义。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust debug overflow panic object/message identity、`i128` 或 trait-level 集成。
- [x] `std::num` narrow signed primitive ilog 宏表面批次已完成：新增 `NUM_I{8,16,32}_{CHECKED_ILOG,ILOG,CHECKED_ILOG2,ILOG2,CHECKED_ILOG10,ILOG10}`，输入 value/base 先按声明 signed 宽度 sign-extend，再委托既有 `I64` signed log 语义；checked helper 对非正 value 或 base < 2 返回显式 `ok=0/value=0`，direct helper 保持当前 direct failure 写 0 形状。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object/message identity、`i128` 或 trait-level 集成。
- [x] `std::num` narrow signed primitive next_multiple_of 宏表面批次已完成：新增 `NUM_I{8,16,32}_CHECKED_NEXT_MULTIPLE_OF` / `NEXT_MULTIPLE_OF`，输入按声明 signed 宽度 sign-extend，复用既有 `I64` checked next-multiple 路径并对窄 signed 结果做范围检查；保持当前 SA signed next-multiple 子集的负 divisor 绝对值语义和 direct failure 写 0 形状。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object/message identity、`i128` 或 trait-level 集成。
- [x] `std::num` narrow signed primitive div_ceil 宏表面批次已完成：新增 `NUM_I{8,16,32}_CHECKED_DIV_CEIL` / `DIV_CEIL`，复用各宽度既有 checked signed division 以处理零除数和 `MIN / -1`，并按 Rust signed ceil division 语义仅在有余数且操作数同号时把截断商加一；direct helper 保持当前 `I64` direct failure shape。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object/message identity、`i128` 或 trait-level 集成。
- [x] `std::num` narrow signed primitive midpoint 宏表面批次已完成：新增 `NUM_I{8,16,32}_MIDPOINT`，对输入先按声明 signed 宽度 sign-extend，再复用既有 `I64` midpoint 路径并把结果 sign-extend 回窄 signed 宽度，覆盖 Rust sufficiently-wide signed average 且向 0 取整的支持子集。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `i128`、Rust trait dispatch、panic object/message identity 或 generic numeric abstractions。
- [x] `std::num` narrow signed primitive direct Euclidean div/rem 宏表面批次已完成：新增 `NUM_I{8,16,32}_DIV_EUCLID` / `REM_EUCLID`，复用既有 narrow signed checked Euclidean 路径并保持当前 `I64` direct helper 形状；`STRICT_*_EUCLID` 仍是 panic 控制流表面。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object/message identity、`i128` 或 trait-level 集成。
- [x] `std::num` narrow signed primitive bit helper 宏表面批次已完成：新增 `NUM_I{8,16,32}_{COUNT_ONES,COUNT_ZEROS,LEADING_ZEROS,TRAILING_ZEROS,LEADING_ONES,TRAILING_ONES,ISOLATE_HIGHEST_ONE,ISOLATE_LOWEST_ONE,HIGHEST_ONE,LOWEST_ONE}`，按 Rust signed primitive same-width unsigned bit-pattern 语义复用既有 `U8/U16/U32` helper，并对 isolate 返回值 sign-extend 回 signed 宽度；`highest_one` / `lowest_one` 保持显式 `ok/index` 结果形状。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option<u32>` layout、`i128` 或 trait-level 集成。
- [x] `std::num` 64-bit `isize` primitive bit helper alias 批次已完成：新增 `NUM_ISIZE_{COUNT_ONES,COUNT_ZEROS,LEADING_ZEROS,TRAILING_ZEROS,LEADING_ONES,TRAILING_ONES,ISOLATE_HIGHEST_ONE,ISOLATE_LOWEST_ONE,HIGHEST_ONE,LOWEST_ONE}`，按当前 SA 64-bit target ABI 委托既有 `I64` bit-pattern 路径；`highest_one` / `lowest_one` 保持显式 `ok/index` 结果形状。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 portable target-width switching、Rust `Option<u32>` layout、`i128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive unchecked 宏表面批次已完成：新增 `NUM_U{8,16,32}_UNCHECKED_{ADD,SUB,MUL,DIV,REM,SHL,SHR}`，与既有 `U64` / `USIZE` 路径合并后覆盖当前 unsigned primitive 宽度；helper 只主张 caller-precondition 合法输入路径，结果按声明宽度 mask，不做 unsafe UB enforcement。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、Rust UB 检测或 trait-level 集成。
- [x] `std::num` unsigned primitive wrapping/euclidean division 宏表面批次已完成：新增 `NUM_U{8,16,32}_{DIV_EUCLID,REM_EUCLID,WRAPPING_DIV,WRAPPING_REM,WRAPPING_DIV_EUCLID,WRAPPING_REM_EUCLID}`，补齐 `NUM_U{64,SIZE}_WRAPPING_{DIV,REM}_EUCLID` 和 `NUM_USIZE_WRAPPING_{DIV,REM}`，与既有 checked/strict/overflowing div/rem 路径合并后覆盖当前 unsigned primitive 宽度；窄输入按声明宽度 mask，零除数仍走底层除法/取余 trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object、`u128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive `ilog*` 宏表面批次已完成：新增 `NUM_U{8,16,32}_{CHECKED_ILOG,ILOG,CHECKED_ILOG2,ILOG2,CHECKED_ILOG10,ILOG10}`，与既有 `U64` / `USIZE` 路径合并后覆盖当前 unsigned primitive 宽度；窄输入和任意 base 按声明宽度 mask，checked helper 用显式 `ok/out` 表示 zero value 或 base < 2。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object、const/static-known 优化分支、`u128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive multiples/ceil 宏表面批次已完成：新增 `NUM_U{8,16,32}_{IS_MULTIPLE_OF,CHECKED_NEXT_MULTIPLE_OF,NEXT_MULTIPLE_OF,DIV_CEIL}`，与既有 `U64` / `USIZE` 路径合并后覆盖当前 unsigned primitive 宽度；窄输入按声明宽度 mask，checked next-multiple 用显式 `ok/out` 表示零除数或越界。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic object、`u128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive `reverse_bits` 宏表面批次已完成：新增 `NUM_U{8,16,32,SIZE}_REVERSE_BITS`，与既有 `U64` 核心路径合并后覆盖当前 unsigned primitive 宽度；窄输入按声明宽度 mask，再复用 64-bit 反转并移回对应 bit width。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、compiler intrinsic lowering 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive rotate 宏表面批次已完成：新增 `NUM_U{8,16,32,SIZE}_ROTATE_LEFT` / `ROTATE_RIGHT`，与既有 `U64` 核心路径合并后覆盖当前 unsigned primitive 宽度；窄输入按声明宽度 mask，shift amount 按声明 bit width 取模。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、compiler intrinsic lowering 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive bit-position 宏表面批次已完成：新增 `NUM_U{8,16,32,SIZE}_{BIT_WIDTH,ISOLATE_HIGHEST_ONE,ISOLATE_LOWEST_ONE,HIGHEST_ONE,LOWEST_ONE}`，与既有 `U64` 核心路径合并后覆盖当前 unsigned primitive 宽度；窄输入按声明宽度 mask，`highest_one` / `lowest_one` 返回显式 `ok/index` 形状以表示 zero input 的 none 分支。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、Rust `Option` layout、compiler intrinsic lowering 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive bit count/zero-scan 宏表面批次已完成：新增 `NUM_U{8,16,32,SIZE}_{COUNT_ONES,COUNT_ZEROS,LEADING_ZEROS,TRAILING_ZEROS,LEADING_ONES,TRAILING_ONES}`，与既有 `U64` 核心路径合并后覆盖当前 unsigned primitive 宽度；窄输入按声明宽度 mask，zero-scan 按 Rust 声明 bit width 返回。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、compiler intrinsic lowering 或 trait-level 集成。
- [x] `std::num` unsigned primitive checked/direct `next_power_of_two` 宏表面批次已完成：新增 `NUM_U{8,16,32,SIZE}_CHECKED_NEXT_POWER_OF_TWO` 与 `NUM_U{8,16,32,SIZE}_NEXT_POWER_OF_TWO`，和既有 `U64` 路径合并后覆盖当前 unsigned primitive 宽度；checked 版本返回显式 `ok/out`，direct 版本沿用当前 SA direct next-power 失败写 0 的形状。窄 unsigned 输入按声明宽度 mask，`usize` 按当前 64-bit SA ABI alias。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option` layout、debug overflow panic object/message、`u128` 或 trait-level 集成。
- [x] `std::num` unsigned primitive `wrapping_next_power_of_two` 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_WRAPPING_NEXT_POWER_OF_TWO`，按 Rust unstable unsigned primitive 语义返回不小于输入的最小 2 的幂，超过声明宽度时返回 0；窄 unsigned 输入按声明宽度 mask，`usize` 仍按当前 64-bit SA ABI alias。本批同时撤回不在 Rust unsigned-only `NonZero<T>::isqrt` 分支内的 signed NonZero isqrt helper/test/docs。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、Rust feature-gate plumbing、panic/debug overflow 差异或 trait-level 集成。
- [x] `std::num` signed primitive overflowing div/rem/euclid helper 批次已完成：新增 `NUM_I{8,16,32,64,SIZE}_OVERFLOWING_{DIV,DIV_EUCLID,REM,REM_EUCLID}`，按 Rust signed primitive 语义让 `MIN / -1` 的 div 返回 `(MIN, true)`、rem 返回 `(0, true)`，普通 Euclidean div/rem 执行 Rust 风格余数调整，除零通过现有 SA panic code trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust tuple ABI、`i128`、panic message/object identity 或 trait-level 集成。
- [x] `std::num` signed primitive overflowing abs/pow helper 批次已完成：新增 `NUM_I{8,16,32,64,SIZE}_OVERFLOWING_{ABS,POW}`，按 Rust signed primitive 语义让 abs 返回 wrapping abs 与 MIN overflow flag，让 pow 返回 wrapping exponentiation 与 checked pow 派生的 overflow flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed overflowing div/rem、Rust tuple ABI、`i128` 或 trait-level 集成。
- [x] `std::num` signed primitive overflowing neg/shift helper 批次已完成：新增 `NUM_I{8,16,32,64,SIZE}_OVERFLOWING_{NEG,SHL,SHR}`，按 Rust signed primitive 语义让 neg 返回 wrapping neg 与 MIN overflow flag，让 shifts 返回 wrapping shift 与 `shift >= BITS` flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed overflowing div/rem/abs/pow、Rust tuple ABI、`i128` 或 trait-level 集成。
- [x] `std::num` signed wide primitive overflowing helper 批次已完成：补齐 `NUM_I64_OVERFLOWING_{ADD,SUB,MUL}` 与 `NUM_ISIZE_OVERFLOWING_{ADD,SUB,MUL}`，与既有 `I8` / `I16` / `I32` helper 合并后覆盖所有现有 signed 宽度的 add/sub/mul overflowing 表面。实现复用 checked + wrapping 路径，返回 wrapping signed value 和 overflow flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed overflowing div/rem/shift/neg/abs/pow、Rust tuple ABI、`i128` 或 trait-level 集成。
- [x] `std::num` unsigned primitive `overflowing_pow` 批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_OVERFLOWING_POW`，按 Rust unsigned primitive 语义返回 wrapping exponentiation value 和 overflow flag；flag 由既有 checked pow 路径判断，value 由既有 pow/wrapping 路径产生。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust tuple ABI、`u128` / `i128` public primitive support、trait-level dispatch 或 Rust 优化分支建模。
- [x] `std::num` unsigned primitive overflowing div/rem/neg 批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_OVERFLOWING_{DIV,DIV_EUCLID,REM,REM_EUCLID,NEG}`，按 Rust unsigned primitive 语义让非零除法/余数返回结果且 overflow flag 恒为 0，neg 对 0 返回 `(0,0)`，对非零返回 wrapping neg 且 flag 为 1。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张除零 panic 对象/消息建模、overflowing_pow、Rust tuple ABI、`u128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive overflowing helper 批次已完成：补齐 `NUM_U{8,16,32}_OVERFLOWING_{ADD,SUB,MUL,SHL,SHR}`，与既有 `U64` / `USIZE` helper 合并后覆盖所有现有 unsigned 宽度的 add/sub/mul/shift overflowing 表面。算术 helper 返回 wrapping 值和 overflow flag，shift helper 返回 wrapping shift 值并以 `shift >= BITS` 置 flag。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 overflowing div/rem/pow、Rust tuple ABI、`u128` 或 trait-level 集成。
- [x] `std::num` narrow unsigned primitive carry/borrow helper 批次已完成：补齐 `NUM_U{8,16,32}_CARRYING_ADD` / `BORROWING_SUB`，与既有 `U64` / `USIZE` helper 合并后覆盖所有现有 unsigned 宽度。实现按 Rust `unsigned_bigint_helpers` 语义执行 ternary add/sub，返回声明宽度结果和 carry/borrow flag；输入和结果按声明宽度 mask/truncate。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust tuple ABI、`const_unsigned_bigint_helpers` gate plumbing、compiler intrinsic lowering 或 trait-level 集成。
- [x] `std::num` unsigned primitive bigint multiplication helper 批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_CARRYING_MUL` / `CARRYING_MUL_ADD`，按 Rust `unsigned_bigint_helpers` 语义返回 `(low, high)` 两个声明宽度 limb，表示 `lhs * rhs + carry (+ addend)` 的完整 2N-bit 结果。实现不依赖 `u128` 标量，内部用 low/high 累加覆盖 `u64` 最大边界。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust tuple ABI、`const_unsigned_bigint_helpers` gate plumbing、compiler intrinsic lowering、`u128` public helper 或 trait-level 集成。
- [x] `std::num` unsigned primitive `unchecked_disjoint_bitor` 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_UNCHECKED_DISJOINT_BITOR`，按 Rust unstable `disjoint_bitor` 的 caller-precondition 形状对声明宽度内互不重叠的位执行 bitwise OR；合法输入同时满足 OR 与加法结果等价。输入和结果按声明宽度 mask/truncate，`usize` 复用当前 64-bit SA ABI。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust immediate-UB enforcement、overlap validation、feature-gate plumbing、compiler intrinsic selection、`u128` 或 trait-level 集成。
- [x] `std::num` unsigned primitive gather/scatter bits 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_EXTRACT_BITS` / `DEPOSIT_BITS`，按 Rust unstable `uint_gather_scatter_bits` 语义让 extract 依 mask 置位顺序将选中位压紧到低位，让 deposit 将输入低位依次散布到 mask 指定位置。输入、mask 与结果均按声明宽度 mask/truncate，`usize` 复用当前 64-bit SA ABI。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、feature-gate plumbing、hardware/compiler `pext` / `pdep` selection 或 trait-level 集成。
- [x] `std::num` unsigned primitive `carryless_mul` 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_CARRYLESS_MUL`，按 Rust unstable `uint_carryless_mul` 语义以 XOR 代替加法执行 GF(2) 二进制多项式乘法并返回声明宽度的低半部。输入、逐步左移值与最终结果均按声明宽度 mask/truncate，`usize` 复用当前 64-bit SA ABI。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 `u128`、feature-gate plumbing、compiler intrinsic selection 或 trait-level 集成。
- [x] `std::num` unsigned primitive funnel shift 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_FUNNEL_SHL` / `FUNNEL_SHR` 与对应 `UNCHECKED_FUNNEL_SHL` / `UNCHECKED_FUNNEL_SHR`，按 Rust unstable `funnel_shifts` 语义拼接两个同宽 unsigned 值并提取移位后的目标半区。安全版本在 `shift >= BITS` 时复用 SA `panic(2212)` / `panic(2213)`，unchecked helper 依赖调用者保证 shift 在范围内。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 unsafe UB enforcement、`u128`、feature-gate plumbing、intrinsic lowering 或 trait-level 集成。
- [x] `std::num` primitive `div_floor` 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_DIV_FLOOR` 与对应 signed helpers，按 Rust unstable `int_roundings` 语义让 unsigned 直接执行普通除法，signed 在非零余数且操作数异号时将截断商减一。零除数与 signed `MIN / -1` 复用 SA `panic(2208)`。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128`、feature-gate plumbing 或 trait-level 集成。
- [x] `std::num` primitive exact division 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_CHECKED_DIV_EXACT` / `DIV_EXACT` / `UNCHECKED_DIV_EXACT` 与对应 signed helpers，按 Rust unstable `exact_div` 语义区分 checked None、direct Option-like 非整除结果和 direct 零除数/signed overflow panic；direct panic 复用 SA `panic(2208)`。unchecked helper 只执行 declared-width division，依赖调用者保证正除数、整除且无 overflow。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option` object layout、unsafe UB enforcement、`u128` / `i128`、feature-gate plumbing 或 trait-level 集成。
- [x] `std::num` primitive exact shift 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_SHL_EXACT` / `SHR_EXACT` 与对应 signed helpers，以显式 `ok/out` 建模 Rust unstable `shl_exact` / `shr_exact` 的 Option-like 结果；当 shift 越界或反向移位不能无损恢复原值时返回 `ok=0/out=0`。同时新增所有现有 integer width 的 `UNCHECKED_SHL_EXACT` / `UNCHECKED_SHR_EXACT` caller-precondition helpers。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option` object layout、unsafe UB enforcement、`u128` / `i128`、feature-gate plumbing 或 trait-level 集成。
- [x] `std::num` primitive unbounded shift 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_UNBOUNDED_SHL` / `UNBOUNDED_SHR` 与对应 signed helpers，按 Rust primitive `unbounded_shl` / `unbounded_shr` 语义在 shift amount 小于 declared bit width 时执行对应移位；越界左移和 unsigned 右移返回 0，signed 右移按符号填充返回 0 或 -1。新增 focused 单测并同步 `progress/current_plan/std_missing`。该批次不新增运行时 panic code，也不主张 `u128` / `i128`、Rust feature-gate 或 trait-level 集成。
- [x] `std::num` primitive unsigned `checked_signed_diff` 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_CHECKED_SIGNED_DIFF`，按 Rust unsigned primitive `checked_signed_diff` 返回显式 `ok/out`，正向差值要求不超过对应 signed max，负向差值允许到 signed min 幅度。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust `Option` object layout、`u128` / `i128`、feature-gate plumbing 或 trait-level 集成。
- [x] `std::num` primitive mixed-sign checked/strict add/sub 宏表面批次已完成：新增 unsigned `NUM_U{8,16,32,64,SIZE}_CHECKED_ADD_SIGNED` / `STRICT_ADD_SIGNED` / `CHECKED_SUB_SIGNED` / `STRICT_SUB_SIGNED`，并为 signed `NUM_I{8,16,32,64,ISIZE}_CHECKED_ADD_UNSIGNED` / `STRICT_ADD_UNSIGNED` / `CHECKED_SUB_UNSIGNED` / `STRICT_SUB_UNSIGNED` 补齐 Rust mixed-integer checked result 与 strict panic 控制流；strict add-shaped 失败复用 SA `panic(2205)`，strict sub-shaped 失败复用 `panic(2206)`。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128` 或 trait-level 集成。
- [x] `std::num` primitive checked/strict neg/abs 宏表面批次已完成：新增 unsigned `NUM_U{8,16,32,64,SIZE}_CHECKED_NEG` / `STRICT_NEG`，并为 signed `NUM_I{8,16,32,64,ISIZE}_STRICT_NEG` / `STRICT_ABS` 补齐 panic 控制流；strict neg 失败通过 SA `panic(2214)` trap，strict abs 失败通过 `panic(2215)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128`、unchecked neg 或 trait-level 集成。
- [x] `std::num` primitive strict shift 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_STRICT_SHL` / `STRICT_SHR` 与对应 signed helpers，复用现有 checked shift，并在 shift amount 大于等于 declared bit width 时分别通过 SA `panic(2212)` / `panic(2213)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128` 或 trait-level 集成。
- [x] `std::num` primitive checked/strict Euclidean div/rem 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_CHECKED_DIV_EUCLID` / `CHECKED_REM_EUCLID` / `STRICT_DIV_EUCLID` / `STRICT_REM_EUCLID` 与对应 signed helpers，checked 版本按 Rust 返回显式 `ok/out`，strict 版本在失败时通过 SA `panic(2210)` / `panic(2211)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128` 或 trait-level 集成。
- [x] `std::num` primitive strict div/rem 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_STRICT_DIV` / `STRICT_REM` 与对应 `NUM_I{8,16,32,64,SIZE}_*` helpers，复用现有 checked div/rem，并在除法失败或取余失败时分别通过 SA `panic(2208)` / `panic(2209)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128`、`strict_div_euclid` / `strict_rem_euclid` 或 trait-level 集成。
- [x] `std::num` primitive strict add/sub/mul 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_STRICT_ADD` / `STRICT_SUB` / `STRICT_MUL` 与对应 `NUM_I{8,16,32,64,SIZE}_*` helpers，复用现有 checked arithmetic 并在 add/sub/mul 溢出时分别通过 SA `panic(2205)` / `panic(2206)` / `panic(2207)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128` 或 trait-level 集成。
- [x] `std::num` primitive checked/strict pow 宏表面批次已完成：新增 `NUM_U{8,16,32,64,SIZE}_CHECKED_POW` / `STRICT_POW` 与 `NUM_I{8,16,32,64,SIZE}_CHECKED_POW` / `STRICT_POW`，按 Rust primitive `checked_pow` 返回显式 `ok/out`，并让 `strict_pow` 在溢出时通过 SA `panic(2204)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`u128` / `i128`、feature-gate 或 trait-level 集成。
- [x] `std::num` signed `isqrt` panic 宏表面批次已完成：新增 `NUM_I8_ISQRT` / `I16` / `I32` / `I64` / `ISIZE`，复用 signed `checked_isqrt` 的非负 floor root 路径，并在负数输入时通过 SA `panic(2203)` trap，按 Rust signed primitive `isqrt` 的 panic 控制流补齐 direct 方法。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust panic message/object identity、`i128`、feature-gate 或 trait-level 集成。
- [x] `std::num` primitive strict sign cast 宏表面批次已完成：为 `U8` / `U16` / `U32` / `U64` / `USIZE` 新增 `*_STRICT_CAST_SIGNED`，并为 `I8` / `I16` / `I32` / `I64` / `ISIZE` 新增 `*_STRICT_CAST_UNSIGNED`，复用 checked 范围判定并在 unsigned overflow 或 negative signed input 时分别通过 SA `panic(2201)` / `panic(2202)` trap。新增 focused 单测并同步 `progress/current_plan/std_missing`。该批次只主张 Rust strict cast 的 panic 控制流形状，不主张 panic message/object identity、`u128` / `i128` 或 feature-gate/trait-level 集成。
- [x] `std::num` primitive checked/saturating sign cast 宏表面批次已完成：为 `U8` / `U16` / `U32` / `U64` / `USIZE` 新增 `*_CHECKED_CAST_SIGNED` / `*_SATURATING_CAST_SIGNED`，并为 `I8` / `I16` / `I32` / `I64` / `ISIZE` 新增 `*_CHECKED_CAST_UNSIGNED` / `*_SATURATING_CAST_UNSIGNED`，按 Rust nightly `integer_cast_extras` 语义返回显式 Option-like 结果或夹取到同宽目标范围。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 strict panic casts、`u128` / `i128` 或 feature-gate/trait-level 集成。
- [x] `std::num` primitive same-width sign cast 宏表面批次已完成：新增 `NUM_U8_CAST_SIGNED` / `U16` / `U32` / `U64` / `USIZE` 与 `NUM_I8_CAST_UNSIGNED` / `I16` / `I32` / `I64` / `ISIZE`，按 Rust `integer_sign_cast` 的同宽 bit-pattern `as` 语义返回目标 signed/unsigned primitive 形状；窄 unsigned-to-signed sign-extend，窄 signed-to-unsigned mask。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张跨宽度转换、`u128` / `i128` 或 Rust trait/type-level 集成。
- [x] `std::num` signed `checked_isqrt` 宏表面批次已完成：新增 `NUM_I8_CHECKED_ISQRT` / `I16` / `I32` / `I64` / `ISIZE`，按 Rust signed `checked_isqrt` 对非负输入返回 floor integer square root，对负数返回显式 `ok=0/out=0` Option-like 结果；`isize` 按当前 64-bit SA ABI alias。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 panic 型 signed `isqrt`、`i128` 或 Rust `Option`/panic object/trait-level 集成。
- [x] `std::num` unsigned `isqrt` 宏表面批次已完成：新增 `NUM_U8_ISQRT` / `U16` / `U32` / `U64` / `USIZE` primitive helper，并为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 布局新增 `*_ISQRT` concrete helper，按 Rust `isqrt` 返回向下取整整数平方根；`NonZero` 结果保持非零，`usize` 仍按当前 64-bit SA ABI alias。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed `isqrt`、generic `NonZero<T>`、`u128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` same-width sign cast 宏表面批次已完成：为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 新增 `*_CAST_SIGNED`，并为 signed `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 新增 `*_CAST_UNSIGNED`，按 Rust `integer_sign_cast` 的同宽 bit-pattern 语义写入目标 NonZero 布局。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `NonZero<T>`、跨宽度转换、`u128` / `i128`、niche 优化或 Rust trait 层建模。
- [x] `std::num::NonZeroU*::bit_width` 非零返回宏表面批次已完成：为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 布局新增 `*_BIT_WIDTH_NZ_U32` concrete helper，按 Rust `NonZero<unsigned>::bit_width -> NonZero<u32>` 由 `BITS - leading_zeros()` 写入 `NonZeroU32` 输出布局。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed NonZero、generic `NonZero<T>`、`u128` 或 Rust feature-gate/trait 层建模。
- [x] `std::num::Wrapping` unsigned next_power 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` 布局新增 `WRAPPING_*_NEXT_POWER_OF_TWO` concrete helper，按 Rust `Wrapping<unsigned>::next_power_of_two` / primitive `wrapping_next_power_of_two` 语义转发，溢出时写回 0；`WrappingU32` 先按 32-bit 宽度 mask。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Saturating next-power、signed wrapper、泛型 `Wrapping<T>`、缺失宽度、`u128` 或 Rust feature-gate/trait 层建模。
- [x] `std::num::{Wrapping,Saturating}` pow/BITS/power-of-two 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` / `WrappingI64` 和 `SaturatingU64` / `SaturatingI64` 布局新增 `*_BITS` 常量、`*_POW` helper，并为无符号 wrapper 新增 `*_IS_POWER_OF_TWO`；`WrappingU32` 复用 32-bit mask 语义，`SaturatingI64` pow 按 Rust primitive `saturating_pow` 的 signed overflow 方向选择 `MIN` / `MAX`。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic wrapper 类型、缺失宽度、`u128` / `i128`、Rust trait dispatch 或 panic object 建模。
- [x] `std::num::Saturating` operator 宏表面批次已完成：为现有 `SaturatingU64` / `SaturatingI64` 布局新增 `*_DIV` / `REM` / `NOT` / `BITAND` / `BITOR` / `BITXOR` concrete helper，按 Rust operator impl 转发到内层 primitive；`SaturatingI64` division 覆盖 `MIN / -1 -> MAX` 饱和分支。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Saturating<T>`、缺失宽度、assignment operator traits、formatting traits 或 zero-divisor Rust panic object 建模。
- [x] `std::num::{Wrapping,Saturating}` operator 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` / `WrappingI64` 布局新增 `*_DIV` / `REM` / `SHL` / `SHR` / `NOT` / `BITAND` / `BITOR` / `BITXOR` concrete helper，并为 `WrappingI64` 与 `SaturatingI64` 新增 `NEG` / `ABS` / `SIGNUM` / `IS_POSITIVE` / `IS_NEGATIVE` signed helper；`WrappingU32` 按 32-bit 宽度 mask。新增 focused 单测并同步 `progress/current_plan/std_missing`。该批次未覆盖 Saturating div/rem，后续已单独补齐可验证子集。
- [x] `std::num::{Wrapping,Saturating}` comparison 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` / `WrappingI64` 与 `SaturatingU64` / `SaturatingI64` 布局新增 `*_EQ` / `NE` / `CMP` / `PARTIAL_CMP` / `LT` / `LE` / `GT` / `GE` concrete helper，按 Rust derived comparison 转发到内层 primitive；`WrappingU32` 比较前按 32-bit 宽度 mask，signed `i64` wrapper 使用 signed ordering。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Wrapping<T>` / `Saturating<T>`、`u128` / `i128`、缺失宽度、`Option<Ordering>` 对象建模或 Rust trait/type-level 集成。
- [x] `std::num::{Wrapping,Saturating}` bit-transform/endian 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` / `WrappingI64` 与 `SaturatingU64` / `SaturatingI64` 布局新增 `*_ROTATE_LEFT` / `ROTATE_RIGHT` / `REVERSE_BITS` / `SWAP_BYTES` / `TO_BE` / `FROM_BE` / `TO_LE` / `FROM_LE` concrete helper，按 Rust inherent methods 转发到内层 primitive 并写回目标 wrapper；`WrappingU32` 按 32-bit 宽度 rotate/reverse。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Wrapping<T>` / `Saturating<T>`、`u128` / `i128`、缺失宽度或 Rust trait/type-level 集成。
- [x] `std::num::{Wrapping,Saturating}` bit-count 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` / `WrappingI64` 与 `SaturatingU64` / `SaturatingI64` 布局新增 `*_COUNT_ONES` / `COUNT_ZEROS` / `LEADING_ZEROS` / `TRAILING_ZEROS` concrete helper，按 Rust inherent methods 转发到内层 primitive bit-count/zero-scan；`WrappingU32` 按 32-bit 宽度 mask 后计数，并覆盖 zero input 的 32-bit leading/trailing 结果。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Wrapping<T>` / `Saturating<T>`、`u128` / `i128`、缺失宽度或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*::count_ones` 非零返回宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_COUNT_ONES_NZ_U32` concrete helper，复用既有 scalar count helper 后写入 `NonZeroU32` 输出布局，补齐 Rust `NonZero<T>::count_ones -> NonZero<u32>` 的返回形状。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `NonZero<T>`、`u128` / `i128`、Rust niche 优化或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` checked/saturating pow 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_CHECKED_POW` 和 `*_SATURATING_POW` concrete helper，按 Rust `NonZero<T>::checked_pow` / `saturating_pow` 对内层 primitive 做 pow 并重建非零 wrapper；checked 版本返回 `ok/out`，saturating 版本按对应 signed/unsigned 边界饱和。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `NonZero<T>`、`u128` / `i128`、Rust niche 优化或 Rust trait/type-level 集成。
- [x] `std::num::NonZeroU*` div_ceil 宏表面批次已完成：为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 布局新增 `*_DIV_CEIL` concrete helper，按 Rust `NonZero<T>::div_ceil` 对两个非零 unsigned wrapper 做向上取整除法后写回非零 wrapper；positive nonzero ceil division cannot produce zero, so the helper has no `ok` channel。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed NonZero、generic `NonZero<T>`、`u128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZeroU*` midpoint 宏表面批次已完成：为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 布局新增 `*_MIDPOINT` concrete helper，按 Rust `NonZero<T>::midpoint` 转发到内层 primitive unsigned midpoint 后写回非零 wrapper；midpoint of two unsigned nonzero values cannot be zero, so the helper has no `ok` channel。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed NonZero、generic `NonZero<T>`、`u128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZeroU*` ilog 宏表面批次已完成：为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 布局新增 `*_ILOG2` / `*_ILOG10` concrete helper，按 Rust `NonZero<T>::ilog2` / `ilog10` 返回无失败的 floor logarithm；`ilog2` 复用最高 set bit index，`ilog10` 复用 primitive `u64` 十进制日志 helper。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed NonZero、generic `NonZero<T>`、`u128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZeroU*` checked_next_power_of_two 宏表面批次已完成：为现有 unsigned `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 布局新增 `*_CHECKED_NEXT_POWER_OF_TWO` concrete helper，按 Rust `NonZero<T>::checked_next_power_of_two` 返回 `ok/out` 形式的 Option-like 结果；窄 unsigned 宽度在上取结果超过对应 `MAX` 时返回 `ok=0`。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 signed NonZero、panic 型 `next_power_of_two`、generic `NonZero<T>`、`u128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` isolate highest/lowest-one 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_ISOLATE_HIGHEST_ONE` / `*_ISOLATE_LOWEST_ONE` concrete helper，按 Rust `NonZero<T>::isolate_highest_one` / `isolate_lowest_one` 保留内层 primitive bit-pattern 的最高/最低 set bit 后重建非零 wrapper；窄 signed 宽度按对应位宽 sign-extend 回 signed 值。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 nightly feature gate、generic `NonZero<T>`、`u128` / `i128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` rotate 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_ROTATE_LEFT` / `*_ROTATE_RIGHT` concrete helper，按 Rust `NonZero<T>::rotate_left/right` 对内层 primitive bit-pattern 做 declared-width rotate 后重建非零 wrapper；窄 signed 宽度按对应位宽 sign-extend 回 signed 值。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 nightly feature gate、generic `NonZero<T>`、`u128` / `i128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` reverse_bits 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_REVERSE_BITS` concrete helper，按 Rust `NonZero<T>::reverse_bits` 对内层 primitive bit-pattern 反转后重建非零 wrapper；窄 signed 宽度按对应位宽 sign-extend 回 signed 值。新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 nightly feature gate、generic `NonZero<T>`、`u128` / `i128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` bit-position 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_HIGHEST_ONE` / `*_LOWEST_ONE` concrete helper，按 Rust `NonZero<T>::highest_one` / `lowest_one` 分别由 `BITS - 1 - leading_zeros()` 与 `trailing_zeros()` 降低；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `NonZero<T>`、`u128` / `i128` 或 Rust trait/type-level 集成。
- [x] `std::num::NonZero*` min/max 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_MIN` / `*_MAX` concrete helper，按 Rust `NonZero<T>::min` / `max` 转发到 `get().min(...)` / `get().max(...)` 后写回非零 wrapper；新增 focused 单测并同步 `progress/current_plan/std_missing`。暂不新增 `clamp`，因为 Rust `Ord::clamp` 对无效范围会 panic，而当前 concrete `CMP_CLAMP_*` 是非 panic helper。
- [x] `std::num::NonZero*` comparison 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_EQ` / `NE` / `CMP` / `PARTIAL_CMP` / `LT` / `LE` / `GT` / `GE` concrete helper，按 Rust `NonZero<T>` 的 `PartialEq` / `Eq` / `PartialOrd` / `Ord` impl 转发到 `get()` 后的 primitive 比较；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `NonZero<T>`、`u128` / `i128`、niche 优化、Rust `Option<Ordering>` 对象建模或泛型 trait dispatch。
- [x] `std::num::NonZero*` copy/clone 宏表面批次已完成：为现有 `NonZeroU8` / `U16` / `U32` / `U64` / `Usize` 与 `NonZeroI8` / `I16` / `I32` / `I64` / `Isize` 布局新增 `*_COPY` / `*_CLONE` / `*_CLONE_FROM` concrete helper，按 Rust `NonZero<T>` 的 `Copy` / `Clone` impl 复制内层非零 primitive 值；新增 focused 单测并同步 `progress/current_plan/std_missing`。不新增 `Default`，不主张 generic `NonZero<T>`、niche 优化、`u128` / `i128` 或泛型 trait dispatch。
- [x] `std::marker::{PhantomData,PhantomPinned}` extended trait 宏表面批次已完成：新增 `DEFAULT_PHANTOM_DATA` / `DEFAULT_PHANTOM_PINNED`，以及两个 ZST marker 的 `COPY` / `CLONE_FROM` / `NE` / `PARTIAL_CMP` / `LT` / `LE` / `GT` / `GE` concrete helper；按 Rust `PhantomData<T>` 显式 impl 与 `PhantomPinned` 派生 impl 的零大小恒等行为返回 token/ordering/bool；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic marker trait dispatch、drop-check/lifetime、完整 pinning 或 Rust auto-trait solver。
- [x] `std::num::{Wrapping,Saturating}` default/copy/clone 宏表面批次已完成：为现有 `WrappingU64` / `WrappingU32` / `WrappingI64` 与 `SaturatingU64` / `SaturatingI64` 布局新增 `*_DEFAULT` / `COPY` / `CLONE` / `CLONE_FROM` concrete helper，并补齐 `DEFAULT_WRAPPING_U32` / `DEFAULT_WRAPPING_I64` / `DEFAULT_SATURATING_I64`；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic wrapper trait dispatch、缺失宽度或 `Debug` formatting。
- [x] `std::cmp::Reverse` default/clone 宏表面批次已完成：新增 `Reverse<u64>` / `Reverse<i64>` 的 `CMP_REVERSE_*_DEFAULT` / `CLONE` / `CLONE_FROM` concrete helper，按 Rust `Reverse<T>` 的派生 `Default` 与显式 `Clone` impl 转发内层 primitive 值；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Reverse<T>`、泛型 trait dispatch 或 `Debug` formatting。
- [x] `std::mem::ManuallyDrop` default/copy/clone 宏表面批次已完成：新增 `MANUALLY_DROP_U64_DEFAULT` / `COPY` / `CLONE` / `CLONE_FROM` concrete helper，按 Rust `ManuallyDrop<T>` 的派生 `Default` / `Copy` / `Clone` 形状处理现有内层 `u64`；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `ManuallyDrop<T>`、`MaybeUninit<T>` 初始化有效性、drop-suppression 安全语义、泛型 trait dispatch 或 `Debug` formatting。
- [x] `std::mem::ManuallyDrop` comparison 宏表面批次已完成：新增 `MANUALLY_DROP_U64_EQ` / `NE` / `CMP` / `PARTIAL_CMP` / `LT` / `LE` / `GT` / `GE` concrete helper，按 Rust `ManuallyDrop<T>` comparison impl 转发内层 `u64` 值；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `ManuallyDrop<T>`、`MaybeUninit<T>` comparison、drop-suppression 安全语义或泛型 trait dispatch。
- [x] `std::mem::ManuallyDrop` hash/hash_one 宏表面批次已完成：新增 `ManuallyDropU64` 的 `DEFAULT_HASHER_WRITE_MANUALLY_DROP_U64`、`MANUALLY_DROP_U64_HASH`、`BUILD_HASHER_DEFAULT_HASH_ONE_MANUALLY_DROP_U64`、`RANDOM_STATE_HASH_ONE_MANUALLY_DROP_U64` concrete helper，按 Rust `ManuallyDrop<T>` `Hash` impl 转发内层值；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `ManuallyDrop<T>`、`MaybeUninit<T>` hash、drop-suppression 安全语义、随机 `RandomState` 或 SipHash 兼容。
- [x] `std::cmp::Reverse` hash/hash_one 宏表面批次已完成：新增 `Reverse<u64>` / `Reverse<i64>` 的 `DEFAULT_HASHER_WRITE_CMP_REVERSE_*`、`CMP_REVERSE_*_HASH`、`BUILD_HASHER_DEFAULT_HASH_ONE_CMP_REVERSE_*`、`RANDOM_STATE_HASH_ONE_CMP_REVERSE_*` concrete helper，按 Rust `#[repr(transparent)]` 单字段派生 `Hash` 形状转发内层 primitive hash；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Reverse<T>`、泛型 trait dispatch、随机 `RandomState` 或 SipHash 兼容。
- [x] `std::marker::{PhantomData,PhantomPinned}` hash/hash_one 宏表面批次已完成：新增 `DEFAULT_HASHER_WRITE_PHANTOM_DATA` / `PHANTOM_DATA_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_PHANTOM_DATA` / `RANDOM_STATE_HASH_ONE_PHANTOM_DATA` 和 `DEFAULT_HASHER_WRITE_PHANTOM_PINNED` / `PHANTOM_PINNED_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_PHANTOM_PINNED` / `RANDOM_STATE_HASH_ONE_PHANTOM_PINNED`，按 Rust ZST/no-op Hash 形状保持 hasher 状态不变；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic marker trait dispatch、drop-check/lifetime、完整 pinning、随机 `RandomState` 或 SipHash 兼容。
- [x] `std::num::{Wrapping,Saturating}` hash/hash_one 宏表面批次已完成：新增 `WrappingU64` / `WrappingU32` / `WrappingI64` 与 `SaturatingU64` / `SaturatingI64` 的 `DEFAULT_HASHER_WRITE_*`、`*_HASH`、`BUILD_HASHER_DEFAULT_HASH_ONE_*`、`RANDOM_STATE_HASH_ONE_*` concrete helper，按 Rust 透明 tuple struct 派生 `Hash` 的单字段形状转发内层 primitive hash；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 generic `Wrapping<T>` / `Saturating<T>`、缺失宽度、随机 `RandomState` 或 SipHash 兼容。
- [x] `std::ffi::{CStr,CString}` hash/hash_one 宏表面批次已完成：新增 `DEFAULT_HASHER_WRITE_CSTR` / `CSTR_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_CSTR` / `RANDOM_STATE_HASH_ONE_CSTR` 和 `DEFAULT_HASHER_WRITE_CSTRING` / `CSTRING_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_CSTRING` / `RANDOM_STATE_HASH_ONE_CSTRING`，按 Rust backing bytes-with-NUL 形状复用现有 `u8` slice hash；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust 平台 `c_char` signedness 细节、allocator/drop/lifetime、随机 `RandomState` 或 SipHash 兼容。
- [x] `std::time::{Instant,SystemTime}` hash/hash_one 宏表面批次已完成：新增 Unix `Timespec` 形状的 `DEFAULT_HASHER_WRITE_UNIX_TIMESPEC_NS`，以及 `DEFAULT_HASHER_WRITE_INSTANT` / `TIME_INSTANT_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_INSTANT` / `RANDOM_STATE_HASH_ONE_INSTANT` 和 `DEFAULT_HASHER_WRITE_SYSTEM_TIME` / `TIME_SYSTEM_TIME_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_SYSTEM_TIME` / `RANDOM_STATE_HASH_ONE_SYSTEM_TIME`；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust opaque/platform-varying time storage、pre-epoch negative `SystemTime`、monotonic clock 保证、随机 `RandomState` 或 SipHash 兼容。
- [x] `std::time::Duration` hash/hash_one 宏表面批次已完成：新增 `DEFAULT_HASHER_WRITE_DURATION` / `TIME_DURATION_HASH` / `BUILD_HASHER_DEFAULT_HASH_ONE_DURATION` / `RANDOM_STATE_HASH_ONE_DURATION`，按 Rust `core::time::Duration` 派生 `Hash` 的 `secs: u64` + `nanos: u32` 字段顺序从 SA `u64` 纳秒值拆分后写入 hasher；新增 focused 单测并同步 `progress/current_plan/std_missing`。不主张 Rust typed two-field Duration 存储、`Nanoseconds` niche 类型、`u128`/float/signed duration 转换、随机 `RandomState` 或 SipHash 兼容。

## Active test logging diagnostics (2026-07-09)

- [x] Add a dedicated logged full-test dependency runner: `tools/test_steps_timed.sh`.
- [x] Cover the `zig build test` dependency set as explicit named build steps so a timeout identifies the owning step instead of hiding inside the aggregate command.
- [x] Add per-step timeout control (`--timeout` / `SA_TEST_STEP_TIMEOUT`), `--continue`, `--list`, `--jobs`, and `--summary` options.
- [x] Print START/PASS/FAIL/TIMEOUT logs with UTC timestamps, exact command, elapsed time, slowest-step ranking, and final summary.
- [x] Persist every step output to a numbered per-step log file plus `summary.log`, with default logs under ignored `logs/test_steps/<utc timestamp>` and override support through `--log-dir` / `SA_TEST_STEP_LOG_DIR`.
- [x] Avoid duplicate std-smoke work by covering the whitepaper smoke artifact with `whitepaper-lint` rather than the aggregate `smoke` step.
- [x] Verify script syntax, default step listing, and a focused two-step run (`lib-root-smoke`, `pkg-core-test`) without blind full-suite execution.
- [x] Verify persisted-log success and failure paths with focused `pkg-core-test` and an invalid-step failure check.
- [x] Add internal START/END timing to `plugin-host-smoke` so a hang or slowdown identifies the exact Zig test body.
- [x] Add internal demo/phase START/END timing to `wasm-matrix` so a hang or slowdown identifies the exact demo and build/run phase.
- [x] Verify the two newly instrumented heavy steps individually through `tools/test_steps_timed.sh --timeout 420 plugin-host-smoke` and `tools/test_steps_timed.sh --timeout 420 wasm-matrix`.
- [x] At the logging milestone boundary, run the full logged diagnostic pass once instead of `zig build test` directly.
- [x] Record the full logged pass result: `passed=22 failed=0 timeout=0 total=22 elapsed=789.076s`, logs in `logs/test_steps/full-20260709T060333Z`.
- [ ] Optional future precision: add timing inside plugin installer helper paths, temporary Zig plugin builds, and `sa-std-runtime` internals if those remain top blockers.

## Active full-test runtime optimization follow-up (2026-07-09)

- [x] Commit the logging/diagnostics milestone before starting the next optimization: `690d57f Add logged test step diagnostics`.
- [x] Optimize plugin installer failure paths by moving pure preflight checks before temporary plugin dynamic-library builds.
- [x] Keep plugin install unit tests isolated: `plugin-host-smoke` uses `std.testing.tmpDir()` and test-local `SA_PLUGINS_HOME=state`; no real user plugin installation is required for ordinary unit testing.
- [x] Verify the plugin optimization with the logged step runner: `plugin-host-smoke` passed in `170.743s`.
- [x] Record observed improvement: previous logged baseline `209.569s`, optimized run `170.743s`, delta `38.826s` (`18.5%`) for that step; overall optimization follow-up progress estimate `15%`.
- [x] Optimize `sa-std-runtime` by reusing the build-system `sa_std` archive instead of rebuilding the same static runtime library in every C demo test.
- [x] Verify the `sa-std-runtime` optimization with the logged step runner: `14/14 tests passed`, `145.815s -> 33.532s`, delta `112.283s` (`77.0%`); overall optimization follow-up progress estimate `35%`.
- [x] Improve full-test log quality: add per-step heartbeat, failure/timeout log tails, `results.tsv`, `environment.txt`, and `index=current/total` progress fields.
- [x] Verify log-quality changes without a full run: syntax/list checks pass; `pkg-core-test` pass generates structured logs; invalid step preserves exit `1` and prints log tail; `sa-std-runtime` emits a heartbeat at 5s and passes. Overall optimization/logging progress estimate `45%`.
- [x] Improve `unit-framework` internal logs: add per-SA-file START/END/error lines with mode, jobs, elapsed time, stdout/stderr byte counts, and queued worker `index=current/total`.
- [x] Verify `unit-framework` logging with a single build step, not the full suite: `unit-framework` passed, logs contain file-level START/END and no misleading `[unit-framework] FAIL`; overall optimization/logging progress estimate `55%`.
- [x] Normalize remaining `unit-framework` top-level SA logs: `feature_suite.sa`, `assert_diag.sa`, and `mock_io_test.sa` now use START/END/error lines too; single-step verification passed and progress estimate is `60%`.
- [x] Add `wasm-matrix` slowest-demo and slowest-phase summary output; focused single-step verification passed in `146.982s` and showed repeated `build-exe` dominates (`93156ms` of `103970ms` demo time). Overall optimization/logging progress estimate: `65%`.
- [x] Convert default `wasm-matrix` to WASM-fast validation: all 110 demos still run through wasm, native `build-exe` is reduced to 6 sanity demos unless `SA_WASM_MATRIX_NATIVE_ALL=1`, and all matrix builds pass `--project-root` so they share the repo `.sa_cache`.
- [x] Verify the WASM-fast path with focused single-step runs only: cold shared-cache pass `212.385s`; hot shared-cache pass `59.623s`, down from the previous logged `146.982s` (`-87.359s`, `-59.4%`). Overall optimization/logging progress estimate: `75%`.
- [x] Prepare release metadata for this batch: `build.zig.zon` version `0.0.4` and `CHANGELOG.md` covering `0.0.3 -> 0.0.4`.
- [ ] Continue with remaining slow owners after the release merge: `plugin-host-smoke`, `unit-framework`, and `std-smoke`, using focused instrumentation before broad changes.

## Active compiler-performance slice: large SAB focused tests (2026-07-09)

- [x] Commit pre-existing String macro-surface work before starting SCI performance changes: `ee50937 Add extended string macro surfaces`.
- [x] Commit first SCI SAB fast-path checkpoint before continuing: `94d841c Optimize SAB test listing path`.
- [x] Record the issue in `docs/issue14_test_filter_large_sab_performance.md`.
- [x] Measure real downstream SAB baselines: small `parallel_table_erased` focused compile-only about 1.28s, small list about 0.33s; large `world_table_erased` focused list about 8.87s and compile-only about 30.61s.
- [x] Identify root cause in `src/cli.zig`: `executeTest()` calls `compileSource()` before collecting tests or applying filters/list; `.sab` compileSource performs full `loadSabFlat()` + verifier over the whole module.
- [x] Implement `.sab` `sa test --list` fast path that decodes test metadata/function signatures without full verifier.
- [x] Implement selected `.sab --compile-only --filter` reachability pruning, borrowed symbol-pool decode, trusted preverified compile-only path, and skip-link after LLVM bitcode emit succeeds.
- [x] Verify focused ReleaseFast real gates from `docs/issue14_test_filter_large_sab_performance.md`: large list `0.05s`, large compile-only `0.82s`, small compile-only `0.17s`.
- [x] Install with `tools/install.sh --no-shell` and repeat installed focused gates: large list `0.07s`, large compile-only `1.00s`, small compile-only `0.26s`.
- [x] Fix focused full-test blockers from `docs/issue15_full_test_suite_failures_20260709.md`: `splitn aliases` source focused gate passes, and full `plugin-host-smoke` passes `12/12`.
- [x] Isolate and fix the `sa-std-unit` timeout: `sa_net_uring.test.listen accept recv_ticket and outbound commands work end to end` now passes focused, and `zig build sa-std-unit --summary all` passes `63/63`.
- [x] Complete single build-step reruns for the `zig build test` dependency set; all required steps pass with per-object logs.
- [x] Install with `tools/install.sh --no-shell`, then rerun installed focused performance gates: large compile-only `0.75s`, large list `0.04s`, small compile-only `0.13s`.
- [ ] Follow up with lazy/partial SAB instruction decode for selected run-mode and further compile-only headroom.
- [ ] Fix test cache semantics for filtered linked artifacts if selected linked artifacts are cached in the future.

## 2026-07-05 当前工作集

- [x] Linux `sa_std` 补齐：`os/fd` raw/owned fd facade（`AsRawFd` / `IntoRawFd` / `FromRawFd` / `dup` / `is_terminal`）。
- [x] Linux `sa_std` 补齐：`fs::MetadataExt` 关键字段（`mode` / `uid` / `gid` / `ino` / `dev` / `nlink` / `rdev` / `blksize` / `blocks` / `atime/ctime` 毫秒口径）。
- [x] Linux `sa_std` 补齐：`thread` 基础 facade（`current_id` / `yield_now`）。
- [x] Linux `sa_std` 补齐：`process::ExitStatusExt` 核心能力（`wait_raw` / `try_wait_raw` / `from_raw` / `into_raw` / `signal` / `core_dumped` / `stopped_signal` / `continued`）。
- [x] 为上述补齐新增 unit-framework 覆盖。
- [x] 修正 UDS 宏表面回归：`AF_UNIX` 句柄上的 TCP-only keepalive/reuse setter 走成功 no-op，避免打断复用的 `tcp_stream/tcp_listener` 资源模型。
- [x] 修正 DNS 主机名宏表面回归：清除 `std_net_dns_macro_surface.sa` 中泄漏的临时主机寄存器。
- [x] 使用 `tools/install.sh --no-shell` 同步安装态 `/home/vscode/.sa/std`。
- [x] 维持 `progress.md`、`current_plan.md` 与本任务列表一致，验收以 `zig build unit-framework` 和安装态 smoke 为准。

## 下一批锁定（Linux）

- [x] `std::os::unix::fs::FileExt`：`read_at` / `write_at`，以及 `read_exact_at` / `write_all_at` 宏便利层。
- [x] `std::os::unix::fs::OpenOptionsExt`：`mode` / `custom_flags`。
- [x] `std::os::unix::fs::PermissionsExt`：`mode` / `set_mode` / `from_mode`。
- [x] `std::os::unix::fs::FileTypeExt`：`is_block_device` / `is_char_device` / `is_fifo` / `is_socket`。
- [x] `std::os::unix::fs::DirBuilderExt`：`mode`，覆盖单层建目录和递归建目录。

## 下一候选（Linux）

- [x] `std::os::unix::fs::DirEntryExt`：`ino`（已补真实目录项句柄/迭代模型，不再走 JSON 兼容层）。

## 下一步（Linux）

- [x] 跳出 `std::os::unix::fs` 局部，重新审计更广的 Linux `std` 缺口并锁定下一批高价值模块。
- [x] `std::os::linux::fs::MetadataExt`：补 Rust 命名的 `st_*` 字段宏表面（`st_dev` / `st_ino` / `st_mode` / `st_nlink` / `st_uid` / `st_gid` / `st_rdev` / `st_size` / `st_atime` / `st_atime_nsec` / `st_mtime` / `st_mtime_nsec` / `st_ctime` / `st_ctime_nsec` / `st_blksize` / `st_blocks`）。
- [x] `std::os::unix::process::parent_id`：补父进程 ID facade。
- [x] `std::os::unix::process::ChildExt::send_signal`：补按信号发送到 child 的 Linux facade，非法 signal 返回错误而不是 runtime trap。
- [x] 新批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::fs::{chown,lchown,fchown}`：补 Linux ownership helpers，支持 Rust `u32::MAX` unchanged sentinel 和显式 `has_uid/has_gid` 宏表面。
- [x] chown 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net` Unix domain socket 补齐一批：`UnixStream::pair`、`UnixListener::local_addr`、`UnixStream::{local_addr,peer_addr}`，并新增独立 Unix socket address handle（unnamed/pathname/abstract），避免复用 IP `SocketAddr` 语义。
- [x] `std::os::unix::process::CommandExt` 可落地子集：补 `arg0`、`process_group(0/pgid)`、`setsid(true)` 的 Linux spawn 配置入口，并覆盖 capture/inherit/stream 三种现有 process 模式。
- [x] `std::os::linux::process` / Rust pidfd 路径关联的进程组信号子集：补 `PROCESS_SEND_PROCESS_GROUP_SIGNAL`，记录 effective PGID，并用新进程组 `/bin/sleep` raw wait-status 验证 SIGKILL。
- [x] 上述 Linux std parity 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装；批次已提交收口。
- [x] `std::os::linux::process` pidfd 子集：补 create_pidfd 路径、process `pidfd` / `into_pidfd` handle 提取，以及 pidfd `kill` / `send_signal` / `wait` / `wait_raw` / `try_wait` / `try_wait_raw` 宏表面；处理 pidfd wait 消费 child 后 process close 不再触发 runtime trap。
- [x] pidfd 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::CommandExt::{uid,gid}`：补 Linux child-side `setuid` / `setgid` spawn 配置入口，并新增 `PROCESS_USER_ID` / `PROCESS_GROUP_ID` facade 用于非 root 验收当前身份设置。
- [x] uid/gid 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::CommandExt::groups`：补 Linux child-side `setgroups` spawn 配置入口，并覆盖 capture/inherit/stream 三种现有 process 模式；非 root 环境按 child setup 退出码验收权限拒绝路径。
- [x] groups 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::CommandExt::chroot`：补 Linux child-side `chroot` spawn 配置入口，并覆盖 capture/inherit/stream 三种现有 process 模式；非 root 环境按 child setup 退出码验收权限拒绝路径。
- [x] chroot 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::CommandExt::exec`：补 Linux in-place `exec` 入口，支持 cwd/arg0/process_group/setsid/uid/gid/groups/chroot 配置；成功路径替换当前测试子进程，失败路径返回 SA 错误码。
- [x] exec 批次已完成源码、focused 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::linux::net::SocketAddrExt` 抽象 Unix socket 地址子集：补 `from_abstract_name` / `as_abstract_name` 风格地址句柄，以及按 Unix addr handle listen/connect 的 Linux UDS 路径。
- [x] abstract Unix socket 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::net::linux_ext::TcpStreamExt`：补 `TCP_QUICKACK` 与 `TCP_DEFER_ACCEPT` 的 set/get Linux socket option facade。
- [x] TCP Linux extension 批次已完成源码、focused/full net 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::net::linux_ext::UnixSocketExt` UnixStream 子集：补 Linux `SO_PASSCRED` 的 set/get socket option facade。
- [x] UnixSocketExt passcred 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::ChildExt::kill_process_group`：补 Linux process-group `SIGKILL` convenience facade，复用已记录的 effective PGID/process-group signal 路径。
- [x] kill_process_group 批次已完成源码、focused/full process 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::fs::DirEntryExt2::file_name_ref`：补目录项 file-name reference 命名 facade，复用现有 dir-entry 名称指针/长度资源。
- [x] DirEntryExt2 file_name_ref 批次已完成源码、focused dir-entry 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::fs::mkfifo`：补 Rust 命名的 `FS_UNIX_MKFIFO` 宏表面，复用已有 Linux `sa_fs_mkfifo` runtime。
- [x] mkfifo 命名表面批次已完成源码、focused/full Unix fs 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixStream::peer_cred` Linux 子集：补 `SO_PEERCRED` peer pid/uid/gid 标量 facade，不引入 Rust `UCred` 对象模型。
- [x] UnixStream peer_cred 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixStream::peek`：补 `NET_UNIX_STREAM_PEEK` 命名宏表面，复用现有 stream peek runtime，并验证 peek 不消费数据。
- [x] UnixStream peek 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixStream::shutdown`：补 `NET_UNIX_STREAM_SHUTDOWN` 命名宏表面，复用现有 stream shutdown runtime，并验证写半边 shutdown 后 peer 读到 EOF。
- [x] UnixStream shutdown 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::{UnixStream,UnixListener}` option 命名表面：补 stream timeout/nonblocking/take_error 与 listener nonblocking/take_error Unix 宏别名，复用现有 fd-based TCP runtime。
- [x] Unix socket option 命名表面批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::{UnixStream,UnixListener}::try_clone`：补 Linux/Unix fd-dup clone facade，保持 stream/listener 资源类型和独立 close 生命周期。
- [x] Unix socket try_clone 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixListener::accept` 地址返回表面：补 `NET_UNIX_ACCEPT_ADDR`，accept 时同时返回 stream 与 peer Unix addr handle。
- [x] Unix accept_addr 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixListener::incoming`：补 Unix incoming iterator 命名宏表面，复用现有 listener-backed incoming 布局与 accept path。
- [x] Unix incoming 命名表面批次已完成 focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::SocketAddr::{from_pathname,as_pathname}`：补 pathname Unix addr 构造和 Rust 命名 pathname 访问宏表面，复用现有 Unix addr handle 生命周期。
- [x] Unix SocketAddr pathname 批次已完成源码、focused/full Unix socket 测试、完整 `unit-framework`、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::linux::net::SocketAddrExt::as_abstract_name`：补 `NET_UNIX_ADDR_AS_ABSTRACT_NAME_PTR/LEN` Rust 命名访问宏别名，复用现有 abstract ptr/len accessor。
- [x] Unix abstract-name alias 批次已完成 focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::fs::{symlink,chown,lchown,fchown}` Rust 命名表面：补 `FS_UNIX_SYMLINK`、`FS_UNIX_CHOWN`、`FS_UNIX_LCHOWN`、`FS_UNIX_FCHOWN`、`FS_UNIX_FCHOWN_RAW` 宏别名，复用现有 Unix fs runtime。
- [x] Unix fs symlink/chown alias 批次已完成 focused/full Unix fs 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::linux::process::PidFd` raw-fd trait 命名表面：补 `PIDFD_AS_RAW_FD`、`PIDFD_INTO_RAW_FD`、`PIDFD_FROM_RAW_FD`、`PIDFD_CLOSE_RAW_FD` 宏别名，复用现有 `sa_std/os/fd` owned-fd runtime。
- [x] PidFd raw-fd alias 批次已完成 focused/full process 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::linux::process::PidFd` owned-fd trait 命名表面：补 `PIDFD_INTO_OWNED_FD`、`PIDFD_FROM_OWNED_FD` 宏别名，复用 PidFd raw-fd 与 `sa_std/os/fd` owned-fd facade。
- [x] PidFd owned-fd alias 批次已完成 focused/full process 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::{UnixStream,UnixListener}` raw-fd trait 表面：补 stream/listener `as_raw_fd`、`into_raw_fd`、`from_raw_fd` 命名宏；`from_raw_fd` 注册回对应 Unix stream/listener 资源类型。
- [x] Unix socket raw-fd trait 批次已完成 focused/full Unix socket 测试、完整 `unit-framework`、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::{UnixStream,UnixListener}` owned-fd trait 表面：补 stream/listener `into_owned_fd`、`from_owned_fd` 风格宏别名，复用 raw-fd trait 与 `sa_std/os/fd` owned-fd facade。
- [x] Unix socket owned-fd alias 批次已完成 focused/full Unix socket 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::{ChildStdout,ChildStderr}` raw-fd trait 命名表面：补 stdout/stderr `as_raw_fd`、`into_raw_fd`、`from_raw_fd` 宏别名，复用现有 owned-fd facade。
- [x] Child stdout/stderr raw-fd alias 批次已完成 focused/full process 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::process::{ChildStdout,ChildStderr}` owned-fd trait 命名表面：补 stdout/stderr `into_owned_fd`、`from_owned_fd` 风格宏别名，复用 raw-fd trait 与 `sa_std/os/fd` owned-fd facade。
- [x] Child stdout/stderr owned-fd alias 批次已完成 focused/full process 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd` / `std::os::unix::io` TCP stream/listener raw-fd trait 表面：补 `TcpStream` / `TcpListener` 的 `as_raw_fd`、`into_raw_fd`、`from_raw_fd` 命名宏；`from_raw_fd` 验证 INET/INET6 stream socket 并按 `SO_ACCEPTCONN` 恢复 stream/listener 资源类型。
- [x] TCP stream/listener raw-fd trait 批次已完成导出符号检查、focused/full net 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd::OwnedFd` TCP stream/listener 转换表面：补 `NET_TCP_STREAM_INTO_OWNED_FD`、`NET_TCP_STREAM_FROM_OWNED_FD`、`NET_TCP_LISTENER_INTO_OWNED_FD`、`NET_TCP_LISTENER_FROM_OWNED_FD` 宏别名，复用 TCP raw-fd restore 与 `sa_std/os/fd` owned-fd facade。
- [x] TCP stream/listener owned-fd alias 批次已完成 focused/full net 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd` / `std::os::unix::io` UDP socket raw-fd trait 表面：补 `UdpSocket` 的 `as_raw_fd`、`into_raw_fd`、`from_raw_fd` 命名宏；`from_raw_fd` 验证 INET/INET6 datagram socket 并恢复 UDP socket 资源类型。
- [x] UDP socket raw-fd trait 批次已完成导出符号检查、focused/full net 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd::OwnedFd` UDP socket 转换表面：补 `NET_UDP_INTO_OWNED_FD`、`NET_UDP_FROM_OWNED_FD` 宏别名，复用 UDP raw-fd restore 与 `sa_std/os/fd` owned-fd facade。
- [x] UDP socket owned-fd alias 批次已完成 focused/full net 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd` / `std::os::unix::io` stdio borrowed raw-fd trait 表面：补 `IO_STDIN` / `IO_STDOUT` / `IO_STDERR` 句柄宏，以及 `IO_STDIN_AS_RAW_FD` / `IO_STDOUT_AS_RAW_FD` / `IO_STDERR_AS_RAW_FD`，复用固定 stdio handle 与 `sa_std/os/fd` borrowed raw-fd facade。
- [x] stdio raw-fd alias 批次已完成 focused/full io 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd` / `std::os::unix::io` `std::fs::File` raw/owned fd trait 表面：补 `FS_FILE_AS_RAW_FD`、`FS_FILE_INTO_RAW_FD`、`FS_FILE_FROM_RAW_FD`、`FS_FILE_INTO_OWNED_FD`、`FS_FILE_FROM_OWNED_FD`，其中 `from_raw_fd/from_owned_fd` 恢复为 File 资源以支持 File-only `read_at/write_at` 路径。
- [x] File raw/owned fd facade 批次已完成导出符号检查、focused/full fd 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd::OwnedFd` Rust 命名表面：补 `FD_OWNED_AS_RAW_FD`、`FD_OWNED_INTO_RAW_FD`、`FD_OWNED_FROM_RAW_FD`、`FD_OWNED_TRY_CLONE` 宏别名，复用现有 `sa_std/os/fd` raw/dup runtime。
- [x] OwnedFd 命名 facade 批次已完成 focused/full fd 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::fd::{RawFd,BorrowedFd}` Rust 命名表面：补 RawFd reflexive `as_raw_fd/into_raw_fd/from_raw_fd` 宏、BorrowedFd `borrow_raw/as_raw_fd/try_clone_to_owned` 宏，并新增 raw fd dup-to-owned runtime。
- [x] RawFd/BorrowedFd 命名 facade 批次已完成导出符号检查、focused/full fd 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 审计：确认当前 SA facade 尚未覆盖 Rust 全量 API；本批次优先补可验收的 raw-parts 表面。
- [x] `Vec::{into_raw_parts,from_raw_parts}` 与 `StringBuf::{into_raw_parts,from_raw_parts}` facade 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 继续补齐：补 `String` replace-first/replace-last 风格宏表面，以及 `Vec::push_mut` / `Vec::insert_mut` 风格 mut-return 宏表面。
- [x] String/Vec mut-return + replace-first/last 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 继续补齐：补 `Vec::from_fn` 风格生成宏与 `String::remove_matches` 风格 slice-pattern 删除宏表面。
- [x] String remove_matches + Vec from_fn 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 继续补齐：补 `Vec::{as_non_null,into_parts,from_parts}` 风格 NonNull parts 宏表面，复用现有 `NonNull` wrapper facade。
- [x] Vec NonNull parts 批次已完成 focused/full Vec/String 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::extend_from_within` 风格宏表面，包含 bounds 与 UTF-8 char boundary 检查，并避免 self-copy reallocation 悬空。
- [x] String extend_from_within 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::remove(idx)` 风格 byte-index 删除 char 宏表面，并新增 `STR_TRY_CHAR_AT_BYTE` UTF-8 解码 helper。
- [x] String remove-char-at 批次已完成 runtime 导出检查、focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::pop()` 风格 char-aware 尾部弹出宏表面，区别于既有 byte-level pop。
- [x] String pop-char 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::drain(range)` 可支撑形态，返回被移除的 `StringBuf` 并从原 buffer 删除合法 UTF-8 range。
- [x] String drain-range 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 修正：`STRING_BUF_TRY_SPLIT_OFF` / `STRING_BUF_SPLIT_OFF` 对齐 Rust `String::split_off`，要求 split index 是 UTF-8 char boundary。
- [x] String split_off boundary 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::retain` 可支撑形态，按 Unicode codepoint predicate 保留字符并重建 StringBuf。
- [x] String retain 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 修正：`push(char)` / `insert(char)` 支持完整有效 Unicode scalar，并为 `insert_str` 补 Rust char-boundary 检查。
- [x] String Unicode char insert/push 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 继续补齐：补 `Vec::retain_mut` 可支撑 U64 形态，predicate 接收元素指针并可修改后决定是否保留。
- [x] Vec retain_mut 批次已完成 focused/full Vec/String 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 继续补齐：补 `Vec::peek_mut` 可支撑 U64 形态，返回最后一个元素的 mutable pointer，空 Vec 返回 `ok=0`。
- [x] Vec peek_mut 批次已完成 focused/full Vec/String 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 继续补齐：补 `Vec::from_elem` 可支撑形态，按长度重复填充值构造 Vec。
- [x] Vec from_elem 批次已完成 focused/full Vec/String 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 继续补齐：补 `String::leak` / `Vec::leak` 可支撑形态，消费 owning wrapper 并返回可变 slice/str 视图。
- [x] String/Vec leak 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 继续补齐：补 `Vec::spare_capacity_mut` / `Vec::split_at_spare_mut` 可支撑形态，并修正 `VEC_SET_LEN` 为 Rust `set_len` 风格直接设置长度。
- [x] Vec spare capacity 批次已完成 focused/full Vec/String 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf8` 可支撑形态，接受完整有效 UTF-8 字节 slice，拒绝非法 UTF-8。
- [x] String from_utf8 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::into_chars` 可支撑 eager 形态，消费 StringBuf 并返回 U64 codepoint Vec。
- [x] String into_chars 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf16` 可支撑严格 U16 slice 形态，支持 BMP 和 surrogate pair，拒绝非法 surrogate。
- [x] String from_utf16 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf16_lossy` 可支撑 U16 slice 形态，用 U+FFFD 替换非法 surrogate 并继续解码。
- [x] String from_utf16_lossy 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf16le` / `String::from_utf16be` 可支撑严格 endian byte-slice 形态，复用严格 UTF-16 surrogate 解码。
- [x] String UTF-16 endian byte-slice 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf16le_lossy` / `String::from_utf16be_lossy` 可支撑 endian byte-slice 形态，奇数字节和非法 surrogate 用 U+FFFD 替换。
- [x] String UTF-16 endian lossy byte-slice 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf8(Vec<u8>)` owned-Vec 可支撑形态，成功零拷贝转 StringBuf，失败返还原始 Vec。
- [x] String from_utf8 Vec 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf8_lossy` 可支撑 owned-StringBuf 形态，非法 UTF-8 序列替换为 U+FFFD 后继续解码。
- [x] String from_utf8_lossy 批次已完成 runtime 导出检查、focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf8_lossy_owned` 可支撑 owned-Vec 形态，合法 UTF-8 零拷贝移动，非法输入 lossy 重建并释放原 Vec。
- [x] String from_utf8_lossy owned-Vec 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] String from_utf8_lossy 语义修正：按 Rust `utf8_chunks` 风格对连续无效 UTF-8 序列只插入一个 U+FFFD，并用 `F0 90 80 W` 回归覆盖。
- [x] String from_utf8_lossy 语义修正批次已完成 runtime 导出检查、focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 继续补齐：补 `String::from_utf8_unchecked(Vec<u8>)` owned-Vec 零拷贝入口和 `String::as_mut_str` 可变 str 视图命名表面。
- [x] String unchecked owned-Vec + as_mut_str 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 继续补齐：补 `String::from(&str)` / `Clone` / `clone_from` 可支撑形态，以及 `Vec::from(&[T])` / `Clone` / `clone_from` 可支撑形态（含 U64 便捷宏）。
- [x] String/Vec clone + from-slice/from-str 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 继续补齐：补 `Default`、`String` AsRef/AsMut 命名别名、`String + &str` / `AddAssign<&str>`、`String::from(char)`、`Vec<u8>::from(&str)` 与 `Vec::from(String)` 可支撑命名表面。
- [x] String/Vec default + add/from-char/from-str-bytes 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 继续补齐：补 `String::from(&mut str)`、`String::from(&String)`、`TryFrom<Vec<u8>> for String` 命名别名，并为已有 `Vec::from(String)` 表面补完整覆盖。
- [x] String/Vec reference conversion alias 批次已完成 focused/full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `Vec::from(&mut [T])` / `Vec::from(&[T; N])` / `Vec::from(&mut [T; N])` 可支撑命名别名。
- [x] Vec reference/array conversion alias 批次已完成 focused/full String/Vec 源码测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装；`String::as_mut_vec` 不能用简单宏精确表达 Rust metadata-level mutable alias，保持为未覆盖缺口。
- [x] `std::os::unix::xdg` 可支撑环境目录表面：补 `data_home_dir` / `config_home_dir` / `state_home_dir` / `cache_home_dir` / `data_dirs` / `config_dirs` 风格宏表面，按 Rust/XDG 规则处理空 env 与默认值。
- [x] Unix XDG env facade 批次已完成 focused/full env 测试、完整 `unit-framework`、安装态回归、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::fs::chroot`：补当前进程 Linux `chroot(2)` facade，新增 `FS_CHROOT` / `FS_UNIX_CHROOT` 宏表面，并用 `/` 安全验收 root 成功或非 root 权限拒绝路径。
- [x] Unix fs chroot facade 批次已完成源码 focused/full Unix fs 测试、完整 `unit-framework`、安装态回归、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixDatagram` 基础子集：补 unbound/pair、try_clone、raw/owned fd roundtrip、local/peer addr、passcred、timeout/nonblocking/take_error、send/recv/peek、shutdown/close 宏表面。
- [x] UnixDatagram 基础子集批次已完成源码 focused/full Unix socket 测试、完整 `unit-framework`、安装态回归、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::net::UnixDatagram` pathname/abstract 地址路径：补 `bind` / `bind_addr` / `connect` / `connect_addr` / `send_to` / `send_to_addr` / `recv_from` / `peek_from` 宏与 runtime 表面。
- [x] UnixDatagram 地址路径批次已完成源码 focused/full Unix socket 测试、完整 `unit-framework`、安装态回归、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `Vec` AsRef/AsMut/Deref-to-slice 命名别名与 `String` fmt::Write `write_str` / `write_char` 风格宏表面。
- [x] String/Vec naming alias 批次已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::ffi::{OsStrExt,OsStringExt}`：补 Unix 字节语义 `OsStr` / `OsString` facade，覆盖 `from_bytes` / `as_bytes` 与 `from_vec` / `into_vec` 命名表面。
- [x] Unix ffi OsStr/OsString 批次已完成源码 focused 测试、完整 `unit-framework` runner 覆盖、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `std::os::unix::thread::JoinHandleExt`：补真实 raw `pthread_t` facade，覆盖 `as_pthread_t` / `into_pthread_t`，并提供 raw pthread join 清理路径用于 ownership-transfer 验收。
- [x] Unix thread JoinHandleExt pthread 批次已完成 `sa-std-static`、源码 focused thread 测试、完整 `unit-framework`、安装态回归、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装；同时修正 `THREAD_JOIN_STATUS` 输出指针 ABI。
- [x] `std::os::net::linux_ext::UnixSocketExt::set_mark`：补 UnixStream / UnixDatagram 的 Linux `SO_MARK` setter facade，运行时验证 AF_UNIX stream/datagram 句柄并映射权限拒绝/不支持状态。
- [x] Unix socket set_mark 批次已完成 `sa-std-static`、源码 full Unix socket 测试、完整 `unit-framework`、安装态回归、导出符号检查，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 String Extend 风格别名与 Vec Extend 风格别名，复用现有 push/append/slice-copy 路径，不引入虚构 iterator object model；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `PartialEq<String, str, &str>` / `ne` 风格命名别名，复用现有 `STR_EQ` 字节比较路径，不引入虚构 trait object model；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `PartialOrd` / `Ord` 风格 String/str 字典序比较别名，复用 UTF-8 字节字典序比较路径，不引入虚构 trait object model；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补本地 `Hash` 风格委托别名，StringBuf 通过 str view 哈希、Vec U64 通过 slice view 哈希，复用 SA `DefaultHasher` 表面，不声明 Rust 标准哈希算法或泛型 `T: Hash` 全覆盖；已完成源码 hash/String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 eager U64 codepoint slice 的 `FromIterator<char>` / `Extend<char>` 风格别名，整段 Unicode scalar 预验证后再写入，非法 surrogate 路径不修改目标；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 eager pointer-slice `FromIterator<&char>` / `Extend<&char>` 风格别名，整段引用 codepoint 预验证后再写入，非法 surrogate 路径不修改目标；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 eager byte-slice / pointer-slice `FromIterator<core::ascii::Char>` / `Extend<core::ascii::Char>` 风格别名，整段 ASCII byte 预验证后再写入，非法 byte 路径不修改目标；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 eager slice-shaped `FromIterator<T>` / `Extend<T>` 风格别名，复用现有 slice-copy 构造和追加路径，不引入虚构 lazy iterator object model；已完成源码 full Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 U64 slice-delegated equality / inequality 风格别名，覆盖 Vec-vs-slice、slice-vs-Vec、Vec-vs-Vec 比较，不引入虚构泛型 `T: PartialEq` trait object model；已完成源码 full Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 U64 slice-delegated lexicographic comparison / ordering predicate 风格别名，覆盖 Vec-vs-slice、slice-vs-Vec、Vec-vs-Vec 比较，不引入虚构泛型 `T: Ord` trait object model；已完成源码 full Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 eager Slice-of-Slice `FromIterator<&str>` / `Extend<&str>` 风格别名，复用现有 `STRING_BUF_PUSH_STR` 路径，不引入虚构 lazy iterator object model；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 eager Slice-of-StringBuf metadata `FromIterator<String>` / `Extend<String>` 风格别名，逐个追加 owned String 的 str view 并原地 drop moved buffer，不引入虚构 lazy iterator object model；同时修复 LLVM-C 间接调用 vtable slot 签名 provenance；已完成源码 full String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `str::repeat` 与 slice/Vec repeat 风格 eager 别名，按 `count` 次复制源 str/slice 到新的 owned `StringBuf` / Vec，`count=0` 返回空 buffer，不声明 allocator-parametric 或泛型 `T: Clone` 全覆盖；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `ToOwned` / `ToString` / `to_vec` 风格 eager owned-copy 别名，复用现有 StringBuf/Vec clone 与 from-slice 路径，并验证源对象后续 mutation 不影响 owned 结果，不声明 Cow/Box/allocator-parametric/trait-object 全覆盖；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 char/bool/u64/i64 具体 primitive `to_string` 别名，复用现有 StringBuf 构造与 SA formatter 路径，不声明泛型 `Display` / `ToString` trait-object 全覆盖或浮点默认格式 parity；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec `AsMut<Vec<T>>` 风格 metadata pointer 别名 `VEC_AS_MUT_VEC_PTR`，与现有 `AsRef<Vec<T>>` 本地指针表面保持一致，不声明 Rust borrow checker 或 whole-object mutable borrow 全语义；已完成源码 full Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 u8/u16/u32/usize 与 i8/i16/i32/isize 具体 primitive `to_string` 别名，复用现有 u64/i64 formatter-backed StringBuf 路径，不声明 u128/i128、浮点格式或泛型 `Display` 全覆盖；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补具体 String `FromStr` / parse 风格别名 `STRING_BUF_PARSE_FROM_STR` 与 `STR_PARSE_STRING_BUF`，从 `&str` 复制为 owned `StringBuf` 并返回 `ok=1`，不声明泛型 `FromStr` 或错误类型模型；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String::as_bytes_mut` 风格 unsafe mutable byte-slice 别名 `STRING_BUF_AS_MUT_BYTES` 与 `STRING_BUF_AS_MUT_REF_BYTES`，复用现有 Vec mutable-slice metadata facade，不声明 UTF-8 mutation invariant enforcement、`String::as_mut_vec` 或 Rust borrow checker 全语义；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `str` / string slice Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `str::as_bytes_mut` 风格 unsafe mutable byte-slice 别名 `STR_AS_MUT_BYTES` 与 `STRING_AS_MUT_BYTES`，复用现有 Slice metadata view，不声明 UTF-8 mutation invariant enforcement、ownership provenance 或 Rust borrow checker 全语义；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `Vec` / slice Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `as_ptr_range` / `as_mut_ptr_range` 风格 start/end 指针输出别名，覆盖 Slice、str/string、StringBuf 和 Vec/U64 路径，不声明 Rust `Range<*const T>` / `Range<*mut T>` 对象布局或 unsafe `slice::from_ptr_range` 重建 API；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `Vec::pop_if` 可变尾元素谓词形态的 U64 别名 `VEC_TRY_POP_IF_MUT_U64` / `VEC_POP_IF_MUT_U64`，谓词接收尾元素可变指针，keep 路径保留谓词 mutation，take 路径返回 mutation 后的尾值，不声明泛型 `T`、闭包 trait 或 borrow checker 全语义；已完成源码 full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice 的 split-first/split-last U64 命名别名 `VEC_SPLIT_FIRST_U64` / `VEC_SPLIT_FIRST_MUT_U64` / `VEC_SPLIT_LAST_U64` / `VEC_SPLIT_LAST_MUT_U64`，复用现有 try 形态并覆盖 empty miss 与 mut 指针写回，不声明泛型 `T` 或 borrow checker 全语义；已完成源码 focused/full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice 的 first_mut/last_mut U64 指针别名 `VEC_TRY_FIRST_MUT_U64` / `VEC_FIRST_MUT_U64` / `VEC_TRY_LAST_MUT_U64` / `VEC_LAST_MUT_U64`，覆盖 empty null pointer 与非空写回路径，不声明泛型 `T` 或 borrow checker 全语义；已完成源码 focused/full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec unchecked U64 命名别名 `VEC_GET_UNCHECKED_U64` / `VEC_GET_UNCHECKED_MUT_PTR_U64`，只声明调用者保证 in-bounds 的 unsafe alias 表面并覆盖 in-bounds value 读取与 mutable pointer 写回，不声明越界安全、泛型 `T` 或 borrow checker 全语义；已完成源码 focused/full String/Vec 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice 的 chunk 命名别名 `VEC_SPLIT_FIRST_CHUNK_U64` / `VEC_FIRST_CHUNK_U64` / `VEC_FIRST_CHUNK_MUT_U64` / `VEC_SPLIT_FIRST_CHUNK_MUT_U64` / `VEC_SPLIT_LAST_CHUNK_U64` / `VEC_SPLIT_LAST_CHUNK_MUT_U64` / `VEC_LAST_CHUNK_U64` / `VEC_LAST_CHUNK_MUT_U64`，复用现有 try 形态并覆盖 hit/miss/zero 与 mut slice 写回，不声明 const-generic array reference、泛型 `T` 或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice 的 split/range 命名别名 `VEC_SPLIT_AT_U64` / `VEC_TRY_SPLIT_AT_MUT_U64` / `VEC_SPLIT_AT_MUT_U64` / `VEC_SPLIT_AT_CHECKED_U64` / `VEC_SPLIT_AT_MUT_CHECKED_U64` / `VEC_RANGE_U64` / `VEC_GET_RANGE_U64` / `VEC_GET_RANGE_MUT_U64`，复用现有 slice 形态并覆盖 hit/miss 与 mutable slice 写回，不声明 Rust panic 语义、泛型 `T` 或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec unchecked split/range U64 别名 `VEC_SPLIT_AT_UNCHECKED_U64` / `VEC_SPLIT_AT_MUT_UNCHECKED_U64` / `VEC_RANGE_UNCHECKED_U64` / `VEC_GET_RANGE_UNCHECKED_U64` / `VEC_GET_RANGE_MUT_UNCHECKED_U64`，只声明调用者保证 in-bounds 的 unsafe alias 表面并覆盖 in-bounds slice view 与 mutable slice 写回，不声明越界安全、泛型 `T` 或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice mutation U64 别名 `VEC_SWAP_U64` / `VEC_TRY_SWAP_U64` / `VEC_REVERSE_U64` / `VEC_ROTATE_LEFT_U64` / `VEC_ROTATE_RIGHT_U64` / `VEC_SWAP_WITH_SLICE_U64` / `VEC_FILL_U64`，复用现有 mutable slice 形态并覆盖 swap、miss、reverse、rotate、swap_with_slice 与 fill，不声明泛型 `T`、Rust panic 语义或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec chunk/window access U64 命名别名 `VEC_CHUNK_AT_U64` / `VEC_RCHUNK_AT_U64` / `VEC_RCHUNK_MUT_AT_U64` / `VEC_CHUNK_EXACT_AT_U64` / `VEC_CHUNK_EXACT_MUT_AT_U64` / `VEC_RCHUNK_EXACT_AT_U64` / `VEC_RCHUNK_EXACT_MUT_AT_U64` / `VEC_WINDOW_AT_U64`，复用现有 try 形态并覆盖 chunk/window、reverse chunk、exact chunk、miss 与 mut slice 写回，不声明 lazy iterator object、泛型 `T`、Rust panic 语义或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice copy U64 别名 `VEC_COPY_FROM_SLICE_U64` / `VEC_CLONE_FROM_SLICE_U64` / `VEC_COPY_WITHIN_U64`，复用现有 mutable slice 形态并覆盖等长 copy/clone、长度不匹配 miss、重叠 copy_within 与越界 miss，不声明泛型 `T`、Clone drop 语义、Rust panic 语义或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice select_nth_unstable U64 命名别名 `VEC_SELECT_NTH_UNSTABLE_U64` / `VEC_SELECT_NTH_UNSTABLE_BY_U64` / `VEC_SELECT_NTH_UNSTABLE_BY_KEY_U64`，复用现有 try 形态并覆盖普通、compare、key 三条路径，不声明 Rust panic 语义、泛型 `T: Ord`、comparator/key trait object 或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice binary_search U64 命名别名 `VEC_BINARY_SEARCH_U64`，复用现有 `(ok,index)` 搜索结果形态并覆盖 hit 与 miss 插入点，不声明 Rust `Result<usize,usize>` 对象布局、泛型 `T: Ord`、comparator/key 变体或 borrow checker 全语义；已完成源码 focused/full Slice/Vec/String 测试、完整 `unit-framework`、安装态回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 String/str split/strip 命名别名 `STR_STRIP_PREFIX` / `STRING_STRIP_PREFIX` / `STR_STRIP_SUFFIX` / `STRING_STRIP_SUFFIX` / `STR_SPLIT_AT` / `STRING_SPLIT_AT` / `STR_SPLIT_AT_CHECKED` / `STRING_SPLIT_AT_CHECKED` / `STR_SPLIT_ONCE` / `STRING_SPLIT_ONCE` / `STR_RSPLIT_ONCE` / `STRING_RSPLIT_ONCE`，复用现有 `(ok,slice...)` try 形态，不声明 Rust `Option`/tuple 对象布局、泛型 `Pattern` 全覆盖、panic 语义或 borrow checker 全语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 String/str find/rfind 命名别名 `STR_FIND` / `STRING_FIND` / `STR_RFIND` / `STRING_RFIND`，复用现有 `(ok,index)` try 形态，不声明 Rust `Option<usize>` 对象布局、泛型 `Pattern` 全覆盖或 searcher/iterator 对象语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 String/str byte find/rfind 命名别名 `STR_FIND_BYTE` / `STRING_FIND_BYTE` / `STR_RFIND_BYTE` / `STRING_RFIND_BYTE`，复用现有 `(ok,index)` try byte 形态，不声明泛型 `Pattern`、Unicode scalar search、Rust `Option<usize>` 对象布局或 searcher/iterator 对象语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice strip prefix/suffix 命名别名 `VEC_STRIP_PREFIX_U64` / `VEC_STRIP_SUFFIX_U64`，复用现有 `(ok,slice)` checked U64 slice-view 形态，不声明 Rust `Option<&[T]>` 对象布局、泛型 `T: PartialEq`、panic 语义或 borrow checker 全语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 String/str checked range-view 命名别名 `STR_GET_RANGE` / `STRING_GET_RANGE` / `STR_GET_PREFIX` / `STRING_GET_PREFIX` / `STR_GET_SUFFIX` / `STRING_GET_SUFFIX` / `STR_GET_RANGE_TO` / `STRING_GET_RANGE_TO` / `STR_GET_RANGE_FROM` / `STRING_GET_RANGE_FROM` / `STR_GET_RANGE_BETWEEN` / `STRING_GET_RANGE_BETWEEN`，复用现有 `(ok,slice)` UTF-8 boundary checked 形态，不声明 Rust `Option<&str>` 对象布局、range trait object 覆盖、panic 语义或 borrow checker 全语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec split_off 命名别名 `VEC_SPLIT_OFF` / `VEC_SPLIT_OFF_U64`，复用现有 `(ok,Vec)` checked split-off 形态，不声明 Rust panic 语义、allocator-parametric 行为、泛型 `T` 全覆盖或 borrow checker 全语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 checked UTF-8 constructor 命名别名 `STRING_BUF_FROM_UTF8` / `STRING_BUF_FROM_UTF8_VEC` / `STRING_BUF_FROM_VEC_U8` / `STRING_BUF_FROM_BYTES_VEC`，复用现有 `(ok,StringBuf)` 与 `(ok,StringBuf,err_vec)` strict UTF-8 形态，不声明 Rust `Result` / `FromUtf8Error` 对象布局、allocator-parametric 行为或 trait object 全覆盖；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 checked UTF-16 constructor 命名别名 `STRING_BUF_FROM_UTF16_U16` / `STRING_BUF_FROM_UTF16LE` / `STRING_BUF_FROM_UTF16BE`，复用现有 `(ok,StringBuf)` strict UTF-16 形态，不声明 Rust `Result` 对象布局、allocator-parametric 行为或 trait object 全覆盖；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补更贴近 Rust 方法名的 UTF-16 别名 `STRING_BUF_FROM_UTF16` / `STRING_BUF_FROM_UTF16_LOSSY`，复用现有 U16 slice strict/lossy 解码形态，不声明 Rust `Result` 对象布局、allocator-parametric 行为或 trait object 全覆盖；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 checked get_mut U64 指针别名 `VEC_TRY_GET_MUT_PTR_U64` / `VEC_GET_MUT_U64`，复用现有 mutable slice checked pointer helper，命中返回本地 `(ok,ptr)` 且 miss 返回 null pointer，不声明 Rust `Option<&mut T>` 对象布局、泛型 `T` 全覆盖或 borrow checker alias 语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 indexed split/line view 命名别名 `STR_SPLIT_BYTE_AT` / `STRING_SPLIT_BYTE_AT` / `STR_LINE_AT` / `STRING_LINE_AT`，复用现有 `(ok,slice)` checked view 形态，不声明 Rust lazy iterator 对象语义、泛型 `Pattern`、`Option<&str>` 对象布局或 borrow checker 全语义；已完成新增相关源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 unsafe `String::as_mut_vec` 风格本地 metadata pointer 别名 `STRING_BUF_AS_MUT_VEC_PTR`，复用 StringBuf/Vec 三字段布局，不声明 Rust borrow checker alias 规则、UTF-8 mutation invariant enforcement、allocator-parametric 行为或 trait-object 全覆盖；已完成新增相关源码 focused 测试。
- [x] String as_mut_vec pointer alias 批次已完成安装态同步/回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str byte-view 别名 `STRING_BUF_BYTES`，复用现有 `STRING_BUF_AS_BYTES` 本地 Slice 视图，不声明 Rust lazy `str::Bytes` iterator 对象、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str 谓词/搜索别名 `STRING_BUF_CONTAINS` / `STRING_BUF_STARTS_WITH` / `STRING_BUF_ENDS_WITH` / `STRING_BUF_FIND` / `STRING_BUF_RFIND`，复用现有 str slice helper，不声明 Rust generic `Pattern`、`Option<usize>` 对象布局、searcher/iterator 对象语义、borrow checker alias 规则或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str strip 别名 `STRING_BUF_STRIP_PREFIX` / `STRING_BUF_STRIP_SUFFIX`，复用现有 str slice helper，不声明 Rust generic `Pattern`、`Option<&str>` 对象布局、searcher/iterator 对象语义、borrow checker alias 规则或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str split_once/rsplit_once 别名 `STRING_BUF_SPLIT_ONCE` / `STRING_BUF_RSPLIT_ONCE`，复用现有 str slice helper，不声明 Rust generic `Pattern`、`Option<(&str,&str)>` 对象布局、searcher/iterator 对象语义、borrow checker alias 规则或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str split_at 别名 `STRING_BUF_SPLIT_AT` / `STRING_BUF_SPLIT_AT_CHECKED`，通过 UTF-8 char-boundary checked helper 返回本地 `(ok,left,right)`，不声明 Rust panic 行为、`Option` 对象布局、borrow checker alias 规则或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str checked range view 别名 `STRING_BUF_GET_RANGE` / `STRING_BUF_GET_PREFIX` / `STRING_BUF_GET_SUFFIX` / `STRING_BUF_GET_RANGE_TO` / `STRING_BUF_GET_RANGE_FROM` / `STRING_BUF_GET_RANGE_BETWEEN`，通过 UTF-8 char-boundary checked helper 返回本地 `(ok,slice)`，不声明 Rust `Option<&str>` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str checked range `TRY` 命名别名 `STRING_BUF_TRY_GET_RANGE` / `STRING_BUF_TRY_GET_PREFIX` / `STRING_BUF_TRY_GET_SUFFIX` / `STRING_BUF_TRY_GET_RANGE_TO` / `STRING_BUF_TRY_GET_RANGE_FROM` / `STRING_BUF_TRY_GET_RANGE_BETWEEN`，复用现有 UTF-8 char-boundary checked helper 返回本地 `(ok,slice)`，不声明 Rust `Option<&str>` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str ASCII / char-boundary 查询别名 `STRING_BUF_IS_ASCII` / `STRING_BUF_IS_CHAR_BOUNDARY` / `STRING_BUF_FLOOR_CHAR_BOUNDARY` / `STRING_BUF_CEIL_CHAR_BOUNDARY`，复用现有 str slice helper 返回本地 bool/index 标量，不声明 Rust iterator、Pattern、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str UTF-8 byte/char view 别名 `STRING_BUF_BYTE_LEN` / `STRING_BUF_TRY_BYTE_AT` / `STRING_BUF_IS_UTF8` / `STRING_BUF_CHAR_COUNT` / `STRING_BUF_TRY_CHAR_AT` / `STRING_BUF_TRY_CHAR_AT_BYTE` / `STRING_BUF_TRY_CHAR_RANGE_AT`，复用现有 str slice helper 返回本地 bool/count/codepoint/slice 形态，不声明 Rust lazy iterator、`Option`/`Result` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str byte split / line view 别名 `STRING_BUF_COUNT_BYTE` / `STRING_BUF_SPLIT_BYTE_COUNT` / `STRING_BUF_TRY_SPLIT_BYTE_AT` / `STRING_BUF_SPLIT_BYTE_AT` / `STRING_BUF_LINE_COUNT` / `STRING_BUF_TRY_LINE_AT` / `STRING_BUF_LINE_AT`，复用现有 str slice helper 返回本地 count 或 `(ok,slice)` 形态，不声明 Rust lazy iterator、泛型 `Pattern`、`Option<&str>` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `split_ascii_whitespace` count / caller-indexed token view 别名 `STR_SPLIT_ASCII_WHITESPACE_COUNT` / `STRING_SPLIT_ASCII_WHITESPACE_COUNT` / `STRING_BUF_SPLIT_ASCII_WHITESPACE_COUNT` 与 `*_TRY_SPLIT_ASCII_WHITESPACE_AT` / `*_SPLIT_ASCII_WHITESPACE_AT`，复用现有 ASCII whitespace predicate 并返回本地 count 或 `(ok,slice)` borrowed token 形态，不声明 Rust lazy `SplitAsciiWhitespace` iterator、泛型 `Pattern`、borrow checker lifetime 或 trait-object 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str strip/trim 别名 `STRING_BUF_TRY_STRIP_PREFIX` / `STRING_BUF_TRY_STRIP_SUFFIX` / `STRING_BUF_TRIM_PREFIX` / `STRING_BUF_TRIM_SUFFIX` / `STRING_BUF_TRIM_ASCII_START` / `STRING_BUF_TRIM_ASCII_END` / `STRING_BUF_TRIM_ASCII`，复用现有 str slice helper 返回本地 `(ok,slice)` 或 borrowed slice 形态，不声明 Rust Unicode whitespace trim、泛型 `Pattern`、`Option<&str>` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str find 命名别名 `STRING_BUF_TRY_FIND` / `STRING_BUF_TRY_RFIND` / `STRING_BUF_TRY_FIND_BYTE` / `STRING_BUF_FIND_BYTE` / `STRING_BUF_TRY_RFIND_BYTE` / `STRING_BUF_RFIND_BYTE`，复用现有 str slice helper 返回本地 `(ok,index)`，不声明 Rust lazy searcher、泛型 `Pattern`、`Option<usize>` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str ASCII case-insensitive equality 别名 `STRING_BUF_EQ_IGNORE_ASCII_CASE`，复用现有 str slice helper 返回本地 bool，不声明 Rust Unicode case folding、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `StringBuf` / `str` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 `String` deref-to-str `TRY` split 别名 `STRING_BUF_TRY_SPLIT_ONCE` / `STRING_BUF_TRY_RSPLIT_ONCE` / `STRING_BUF_TRY_SPLIT_AT_CHECKED`，复用现有 str slice helper 返回本地 `(ok,left,right)`，不声明 Rust lazy searcher、泛型 `Pattern`、`Option<(&str,&str)>` 对象布局、panic 行为、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `Vec` Rust API parity 复审：确认当前 SA facade 仍不是 Rust 全量 API；本批补 Vec deref-to-slice first/last 显式 U64 命名别名 `VEC_FIRST_U64` / `VEC_LAST_U64`，复用现有 front/back helper 返回本地 `u64` 标量，不声明 Rust `Option<&T>` 对象布局、泛型 `T` 全覆盖或 borrow checker alias 语义；已完成新增源码 focused 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；本批按用户要求不跑全量测试。
- [x] `Vec` Rust API parity 文档复审：同步 `docs/std_missing.md` 中滞后的 Vec implemented 清单，补记当前源码已存在的 default/reference/deref、pointer-range/raw-parts/NonNull/spare-capacity、conversion/cloning、mut-return、retain_mut 以及显式 U64 alias 类别；明确剩余缺口是泛型 `retain`/`retain_mut`、lazy drain/splice iterator 与泛型元素支持，不把当前 U64 子集误标为缺失；本批无运行时代码变更，按用户要求不跑测试套件，仅做 diff/whitespace 审计。
- [x] `StringBuf` / `str` Rust API parity 文档复审：确认当前源码已存在 `String` deref-to-str split-at `TRY` 命名别名 `STRING_BUF_TRY_SPLIT_AT`，通过现有 `STRING_BUF_SPLIT_AT` 走 UTF-8 char-boundary checked helper 并返回本地 `(ok,left,right)`，不声明 Rust panic 行为、`Option` 对象布局、borrow checker alias 规则、allocator-parametric 行为或 trait-object 全覆盖；本批同步 `docs/std_missing.md` 记录并复跑 focused 源码/安装态测试；无运行时代码变更，按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 文档复审：同步 `docs/std_missing.md` 中滞后的 char mutation 范围说明，确认 `STRING_BUF_TRY_PUSH_CHAR` / `STRING_BUF_PUSH_CHAR` 与 `STRING_BUF_TRY_INSERT_CHAR` / `STRING_BUF_INSERT_CHAR` 已按有效 Unicode scalar 编码为 UTF-8，非法 scalar 不应被记录成已支持；本批无运行时代码变更，按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 文档复审：同步 `docs/std_missing.md` 中滞后的 StringBuf implemented surface，补记当前源码已存在的 default/reference/deref、pointer-range/raw-parts/leak、conversion/cloning、UTF strict/lossy constructors、eager char/string extension/extraction、retain/drain/remove/replace-first-last/index-range 等类别；本批无运行时代码变更，按用户要求不跑全量测试。
- [x] `StringBuf` Rust API parity 复审：补 `String::make_ascii_uppercase` / `make_ascii_lowercase` 与 `to_ascii_uppercase` / `to_ascii_lowercase` 风格 owned-buffer 宏表面，复用 ASCII slice case mutation helper；只声明 ASCII-only case conversion，不声明 Unicode case folding；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] `str` / `String` Rust API parity 复审：补 `str::make_ascii_uppercase` / `make_ascii_lowercase` 与 `to_ascii_uppercase` / `to_ascii_lowercase` 风格宏表面，复用 ASCII slice mutation 与 StringBuf owned-copy helper；只声明 ASCII-only case conversion，不声明 Unicode case folding；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] `str` / `String` / `StringBuf` Rust API parity 复审：补 `split_at_mut` / `split_at_mut_checked` 风格命名别名，复用 UTF-8 char-boundary checked split helper 返回本地 `(ok,left,right)` Slice 视图；不声明 Rust panic 行为、`Option` 对象布局或 scoped `&mut str` borrow 语义；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] `str` / `String` / `StringBuf` Rust API parity 复审：补当前 Rust nightly-only `ascii_char` 的 `as_ascii` / `as_ascii_unchecked` 风格命名别名，复用现有 ASCII slice checked/unchecked view helpers；checked 形态返回本地 `(ok,slice)`，unchecked 形态保持原指针/长度，不声明 Rust `Option<&[AsciiChar]>` 对象布局、typed ASCII slice reference、unsafe type-state 或稳定 API 覆盖；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] `str` / `String` Rust API parity 复审：补 `str::as_mut_ptr` 风格命名别名 `STR_AS_MUT_PTR` / `STRING_AS_MUT_PTR`，复用现有 byte pointer view；只返回 raw pointer，不声明 Rust scoped `&mut str` borrow、alias 保证或 UTF-8 mutation invariant enforcement；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] `Vec` Rust API parity 复审：补当前 Rust nightly-only `vec_peek_mut` 的 `VEC_PEEK_MUT` / `VEC_PEEK_MUT_U64` 命名别名，复用现有 `VEC_TRY_PEEK_MUT*` raw-pointer helper；返回本地 `(ok,ptr)`，空 vec 返回 null pointer，不声明 Rust `Option<&mut T>`、peek guard、泛型 `T` 或 borrow checker alias 语义；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] `str` / `String` Rust API parity 复审：补 `str::from_utf8` / `from_utf8_mut` / unchecked 风格 borrowed view 命名别名 `STR_TRY_FROM_UTF8` / `STR_FROM_UTF8` / `STR_TRY_FROM_UTF8_MUT` / `STR_FROM_UTF8_MUT` / `STR_FROM_UTF8_UNCHECKED` / `STR_FROM_UTF8_UNCHECKED_MUT` 及匹配 `STRING_*` 别名；checked 形态返回本地 `(ok,slice)`，非法 UTF-8 返回空 slice，unchecked 形态保持原指针/长度；不声明 Rust `Result<&str, Utf8Error>`、`Result<&mut str, Utf8Error>`、unsafe type-state 或 borrow checker 语义；已完成新增 focused 源码/安装态测试，本批按用户要求不跑全量测试。
- [x] str/String/STRING_BUF slice-needle split/matches 视图批次已补齐 `STR_SPLIT_NEEDLE_COUNT` / `STRING_SPLIT_NEEDLE_COUNT` / `STRING_BUF_SPLIT_NEEDLE_COUNT`、`STR_SPLIT_NEEDLE_TERM_COUNT` / `STRING_SPLIT_NEEDLE_TERM_COUNT` / `STRING_BUF_SPLIT_NEEDLE_TERM_COUNT`、`STR_MATCHES_NEEDLE_COUNT` / `STRING_MATCHES_NEEDLE_COUNT` / `STRING_BUF_MATCHES_NEEDLE_COUNT`，以及 caller-indexed `*_TRY_SPLIT_NEEDLE_AT` / `*_SPLIT_NEEDLE_AT` 与 `*_TRY_MATCHES_NEEDLE_AT` / `*_MATCHES_NEEDLE_AT` `Slice` 视图；复用 `STR_COUNT` 非重叠扫描，返回 `(ok, Slice)` 而非 Rust lazy 迭代器。
- [x] str/String slice-needle split/matches 批次已完成源码、focused/full `std_string_macro_surface.sa` 测试，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF reverse slice-needle split/matches 视图批次已补齐 `STR_RSPLIT_NEEDLE_COUNT` / `STRING_RSPLIT_NEEDLE_COUNT` / `STRING_BUF_RSPLIT_NEEDLE_COUNT`、`STR_RMATCHES_NEEDLE_COUNT` / `STRING_RMATCHES_NEEDLE_COUNT` / `STRING_BUF_RMATCHES_NEEDLE_COUNT`，以及 caller-indexed `*_TRY_RSPLIT_NEEDLE_AT` / `*_RSPLIT_NEEDLE_AT` 与 `*_TRY_RMATCHES_NEEDLE_AT` / `*_RMATCHES_NEEDLE_AT` `Slice` 视图；reverse 视图通过计算 forward caller index (`count - 1 - reverse_index`) 并委托现有 forward `*_TRY_SPLIT_NEEDLE_AT` / `*_TRY_MATCHES_NEEDLE_AT` 实现，返回 `(ok, Slice)` 而非 Rust lazy `RSplit` / `RMatches` 迭代器。
- [x] str/String reverse slice-needle split/matches 批次已完成源码、focused `std_string_macro_surface.sa` 测试，并通过 `tools/install.sh --no-shell` 同步至 `/home/vscode/.sa/std`；未声明 `rsplit_terminator`、`splitn`/`rsplitn` 有限计数变体。
- [x] str/String/STRING_BUF split_terminator slice-needle 视图批次已补齐 `STR_SPLIT_TERMINATOR_NEEDLE_COUNT` / `STRING_SPLIT_TERMINATOR_NEEDLE_COUNT` / `STRING_BUF_SPLIT_TERMINATOR_NEEDLE_COUNT`、`STR_RSPLIT_TERMINATOR_NEEDLE_COUNT` / `STRING_RSPLIT_TERMINATOR_NEEDLE_COUNT` / `STRING_BUF_RSPLIT_TERMINATOR_NEEDLE_COUNT`，以及 forward caller-indexed `*_TRY_SPLIT_TERMINATOR_NEEDLE_AT` / `*_SPLIT_TERMINATOR_NEEDLE_AT` `Slice` 视图；复用现有 terminator count 语义丢弃 trailing terminator empty fields，不声明 Rust lazy `SplitTerminator` / `RSplitTerminator` iterator、泛型 `Pattern` 或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF splitn/rsplitn slice-needle count 批次已补齐 `STR_SPLIT_N_NEEDLE_COUNT` / `STRING_SPLIT_N_NEEDLE_COUNT` / `STRING_BUF_SPLIT_N_NEEDLE_COUNT`、`STR_RSPLIT_N_NEEDLE_COUNT` / `STRING_RSPLIT_N_NEEDLE_COUNT` / `STRING_BUF_RSPLIT_N_NEEDLE_COUNT`，并修正现有 caller-indexed splitn/rsplitn 在 `split_count == 0` 时先减一的问题；empty needle 仍按现有 SA concrete subset 处理为 positive count 下 index 0 返回 whole hay、后续 index miss，不声明 Rust full empty-pattern / lazy iterator / 泛型 `Pattern` 全覆盖；已完成新增源码 focused/full String 测试、既有 splitn focused 回归、安装态 focused 回归、完整 `unit-framework`，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] Vec push_within_capacity alias 批次已补齐 `VEC_TRY_PUSH_WITHIN_CAPACITY` / `VEC_TRY_PUSH_WITHIN_CAPACITY_U64`、`VEC_TRY_PUSH_WITHIN_CAPACITY_MUT` / `VEC_TRY_PUSH_WITHIN_CAPACITY_MUT_U64`，以及 matching non-try mut-return aliases；成功路径不扩容并返回 inserted slot pointer，满容量路径返回 `ok=0` 和 null pointer，不声明 Rust `Result<&mut T,T>` 对象布局、泛型 `T` 或 borrow checker 全语义；已完成新增源码 focused 测试、full Vec macro-surface 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装；完整 `unit-framework` 本次运行静默超过 6 分钟后中断，未作为通过证据。
- [x] str/String/STRING_BUF match_indices/rmatch_indices slice-needle 批次已补齐 `STR_MATCH_INDICES_NEEDLE_COUNT` / `STRING_MATCH_INDICES_NEEDLE_COUNT` / `STRING_BUF_MATCH_INDICES_NEEDLE_COUNT`、`STR_RMATCH_INDICES_NEEDLE_COUNT` / `STRING_RMATCH_INDICES_NEEDLE_COUNT` / `STRING_BUF_RMATCH_INDICES_NEEDLE_COUNT`，以及 caller-indexed `*_TRY_MATCH_INDICES_NEEDLE_AT` / `*_MATCH_INDICES_NEEDLE_AT` 和 `*_TRY_RMATCH_INDICES_NEEDLE_AT` / `*_RMATCH_INDICES_NEEDLE_AT`；返回本地 `(ok, byte_index, Slice)` 形态，reverse 保留原 forward byte offset，不声明 Rust lazy `MatchIndices` / `RMatchIndices` iterator、泛型 `Pattern`、`Option<(usize,&str)>` 对象布局或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF split_inclusive slice-needle 批次已补齐 `STR_SPLIT_INCLUSIVE_NEEDLE_COUNT` / `STRING_SPLIT_INCLUSIVE_NEEDLE_COUNT` / `STRING_BUF_SPLIT_INCLUSIVE_NEEDLE_COUNT`，以及 caller-indexed `*_TRY_SPLIT_INCLUSIVE_NEEDLE_AT` / `*_SPLIT_INCLUSIVE_NEEDLE_AT`；返回本地 `(ok, Slice)` 形态，delimiter-terminated 字段保留 needle，trailing delimiter 不产生最终空字段，empty hay/empty needle 返回 0 项，不声明 Rust lazy `SplitInclusive` iterator、泛型 `Pattern`、`Option<&str>` 对象布局或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF split_inclusive char-pattern 批次已补齐 `STR_SPLIT_INCLUSIVE_CHAR_COUNT` / `STRING_SPLIT_INCLUSIVE_CHAR_COUNT` / `STRING_BUF_SPLIT_INCLUSIVE_CHAR_COUNT`，以及 caller-indexed `*_TRY_SPLIT_INCLUSIVE_CHAR_AT` / `*_SPLIT_INCLUSIVE_CHAR_AT`；通过 `STR_ENCODE_CHAR_SLICE` 将 `u64` Unicode scalar 转为 UTF-8 slice 并委托 split-inclusive needle subset，invalid scalar 返回 0 项或 `ok=0` empty slice，不声明 Rust lazy `SplitInclusive` iterator、泛型 `Pattern`、`Option<&str>` 对象布局或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF split/matches char-pattern 批次已补齐 `STR_SPLIT_CHAR_COUNT` / `STRING_SPLIT_CHAR_COUNT` / `STRING_BUF_SPLIT_CHAR_COUNT`、`STR_RSPLIT_CHAR_COUNT` / `STRING_RSPLIT_CHAR_COUNT` / `STRING_BUF_RSPLIT_CHAR_COUNT`、`STR_MATCHES_CHAR_COUNT` / `STRING_MATCHES_CHAR_COUNT` / `STRING_BUF_MATCHES_CHAR_COUNT`、`STR_RMATCHES_CHAR_COUNT` / `STRING_RMATCHES_CHAR_COUNT` / `STRING_BUF_RMATCHES_CHAR_COUNT`，以及 caller-indexed `*_TRY_SPLIT_CHAR_AT` / `*_SPLIT_CHAR_AT`、`*_TRY_RSPLIT_CHAR_AT` / `*_RSPLIT_CHAR_AT`、`*_TRY_MATCHES_CHAR_AT` / `*_MATCHES_CHAR_AT`、`*_TRY_RMATCHES_CHAR_AT` / `*_RMATCHES_CHAR_AT`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 slice-needle split/matches subset，invalid scalar 返回 0 项或 `ok=0` empty slice，不声明 Rust lazy iterator、泛型 `Pattern`、`Option<&str>` 对象布局或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF match_indices/rmatch_indices char-pattern 批次已补齐 `STR_MATCH_INDICES_CHAR_COUNT` / `STRING_MATCH_INDICES_CHAR_COUNT` / `STRING_BUF_MATCH_INDICES_CHAR_COUNT`、`STR_RMATCH_INDICES_CHAR_COUNT` / `STRING_RMATCH_INDICES_CHAR_COUNT` / `STRING_BUF_RMATCH_INDICES_CHAR_COUNT`，以及 caller-indexed `*_TRY_MATCH_INDICES_CHAR_AT` / `*_MATCH_INDICES_CHAR_AT` 和 `*_TRY_RMATCH_INDICES_CHAR_AT` / `*_RMATCH_INDICES_CHAR_AT`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 match_indices/rmatch_indices needle subset，返回本地 `(ok, byte_index, Slice)` 形态，reverse 保留原 forward byte offset，invalid scalar 返回 `ok=0`、index `0` 和 empty slice，不声明 Rust lazy iterator、泛型 `Pattern`、`Option<(usize,&str)>` 对象布局或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF split_terminator/rsplit_terminator char-pattern 批次已补齐 `STR_SPLIT_TERMINATOR_CHAR_COUNT` / `STRING_SPLIT_TERMINATOR_CHAR_COUNT` / `STRING_BUF_SPLIT_TERMINATOR_CHAR_COUNT`、`STR_RSPLIT_TERMINATOR_CHAR_COUNT` / `STRING_RSPLIT_TERMINATOR_CHAR_COUNT` / `STRING_BUF_RSPLIT_TERMINATOR_CHAR_COUNT`，以及 caller-indexed `*_TRY_SPLIT_TERMINATOR_CHAR_AT` / `*_SPLIT_TERMINATOR_CHAR_AT` 和 `*_TRY_RSPLIT_TERMINATOR_CHAR_AT` / `*_RSPLIT_TERMINATOR_CHAR_AT`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 split_terminator/rsplit_terminator needle subset，复用 trailing terminator empty fields 丢弃语义，invalid scalar 返回 0 项或 `ok=0` empty slice，不声明 Rust lazy iterator、泛型 `Pattern`、`Option<&str>` 对象布局或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF splitn/rsplitn char-pattern 批次已补齐 `STR_SPLIT_N_CHAR_COUNT` / `STRING_SPLIT_N_CHAR_COUNT` / `STRING_BUF_SPLIT_N_CHAR_COUNT`、`STR_RSPLIT_N_CHAR_COUNT` / `STRING_RSPLIT_N_CHAR_COUNT` / `STRING_BUF_RSPLIT_N_CHAR_COUNT`，以及 caller-indexed `*_TRY_SPLIT_N_CHAR_AT` / `*_SPLIT_N_CHAR_AT` 和 `*_TRY_RSPLIT_N_CHAR_AT` / `*_RSPLIT_N_CHAR_AT`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 splitn/rsplitn needle subset，保留 `split_count == 0` miss、positive count 限制字段数、当前 `rsplitn` subset reverse-enumerates local splitn fields 的既有语义，invalid scalar 返回 0 项或 `ok=0` empty slice，不声明 Rust lazy iterator、泛型 `Pattern`、`Option<&str>` 对象布局、完整 right-to-left `rsplitn` pattern 语义或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF split_once/rsplit_once char-pattern 批次已补齐 `STR_TRY_SPLIT_ONCE_CHAR` / `STRING_TRY_SPLIT_ONCE_CHAR` / `STRING_BUF_TRY_SPLIT_ONCE_CHAR`、`STR_SPLIT_ONCE_CHAR` / `STRING_SPLIT_ONCE_CHAR` / `STRING_BUF_SPLIT_ONCE_CHAR`、`STR_TRY_RSPLIT_ONCE_CHAR` / `STRING_TRY_RSPLIT_ONCE_CHAR` / `STRING_BUF_TRY_RSPLIT_ONCE_CHAR`、`STR_RSPLIT_ONCE_CHAR` / `STRING_RSPLIT_ONCE_CHAR` / `STRING_BUF_RSPLIT_ONCE_CHAR`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 split_once/rsplit_once needle subset，返回本地 `(ok,left,right)` Slice 形态，invalid scalar 或 miss 返回 `ok=0` 和 empty left/right，不声明 Rust 泛型 `Pattern`、`Option<(&str,&str)>` 对象布局、searcher internals 或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF prefix/suffix char-pattern 批次已补齐 `STR_STARTS_WITH_CHAR` / `STRING_STARTS_WITH_CHAR` / `STRING_BUF_STARTS_WITH_CHAR`、`STR_ENDS_WITH_CHAR` / `STRING_ENDS_WITH_CHAR` / `STRING_BUF_ENDS_WITH_CHAR`、`STR_TRY_STRIP_PREFIX_CHAR` / `STRING_TRY_STRIP_PREFIX_CHAR` / `STRING_BUF_TRY_STRIP_PREFIX_CHAR`、`STR_STRIP_PREFIX_CHAR` / `STRING_STRIP_PREFIX_CHAR` / `STRING_BUF_STRIP_PREFIX_CHAR`、`STR_TRY_STRIP_SUFFIX_CHAR` / `STRING_TRY_STRIP_SUFFIX_CHAR` / `STRING_BUF_TRY_STRIP_SUFFIX_CHAR`、`STR_STRIP_SUFFIX_CHAR` / `STRING_STRIP_SUFFIX_CHAR` / `STRING_BUF_STRIP_SUFFIX_CHAR`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 starts/ends/strip prefix/suffix needle subset，invalid scalar 返回 false 或 `ok=0` empty slice，不声明 Rust 泛型 `Pattern`、`Option<&str>` 对象布局、searcher internals 或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF trim_start_matches/trim_end_matches/trim_matches char-pattern 批次已补齐 `STR_TRIM_START_MATCHES_CHAR` / `STRING_TRIM_START_MATCHES_CHAR` / `STRING_BUF_TRIM_START_MATCHES_CHAR`、`STR_TRIM_END_MATCHES_CHAR` / `STRING_TRIM_END_MATCHES_CHAR` / `STRING_BUF_TRIM_END_MATCHES_CHAR`、`STR_TRIM_MATCHES_CHAR` / `STRING_TRIM_MATCHES_CHAR` / `STRING_BUF_TRIM_MATCHES_CHAR`；通过 `STR_ENCODE_CHAR_SLICE` 将 valid `u64` Unicode scalar 转为 UTF-8 slice 并委托现有 trim matches needle subset，invalid scalar 作为 no-op 返回原 borrowed Slice，不声明 Rust 泛型 `Pattern`、closure/slice-of-char pattern、searcher internals 或 borrow checker lifetime 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [x] str/String/STRING_BUF char_indices caller-indexed 批次已补齐 `STR_CHAR_INDICES_COUNT` / `STRING_CHAR_INDICES_COUNT` / `STRING_BUF_CHAR_INDICES_COUNT`、`STR_TRY_CHAR_INDICES_AT` / `STRING_TRY_CHAR_INDICES_AT` / `STRING_BUF_TRY_CHAR_INDICES_AT`、`STR_CHAR_INDICES_AT` / `STRING_CHAR_INDICES_AT` / `STRING_BUF_CHAR_INDICES_AT`；复用现有 UTF-8 scalar count/byte decoder，返回本地 `(ok, byte_index, codepoint)` 形态，missing ordinal 或 invalid decode path 返回 `ok=0`、byte index `0`、codepoint `0`，不声明 Rust lazy `CharIndices` iterator、tuple 对象布局、borrow checker lifetime 或 invalid-UTF-8 impossible-type 全覆盖；已完成新增源码 focused/full String 测试、安装态 focused 回归，并通过 `tools/install.sh --no-shell` 一次性安装。
- [ ] 下一轮继续按最高优先级复审 String/Vec 可支撑缺口；若没有可诚实表达的小批次，再回到更大 Linux-only `std` facade 缺口。

> **实施准则**：所有任务实现必须遵循 `docs/design.md` 中的架构规范；`docs/requirements.md` 是需求口径。
> - **工业级性能 (P0)**：[`docs/design.md §1.10`](docs/design.md#110-工业级可伸缩性架构-industrial-scalability-architecture---紧急-p0)
> - **宏驱动高级特性**：[`docs/design.md §1.4`](docs/design.md#14-宏驱动高级特性演进-macro-driven-advanced-features)
> - **格式化打印 (R39)**：[`docs/design.md §3.7`](docs/design.md#37-sys_原语--ffi-气闸舱--错误传播-runtime)
> - **物理极限速度 (R40)**：[`docs/design.md §1.10`](docs/design.md#110-工业级可伸缩性架构-industrial-scalability-architecture---紧急-p0)
>
> **2026-06-04 复评快照**：本文件当前共有 677 个任务行，392 个已勾选、285 个未勾选。评估口径仍是“源码实现 + 测试/运行证据”双证据；外部插件以 `/home/vscode/projects/sa_plugins/` 为权威实现目录。主仓 `timeout 600 zig build test --summary all` 未在 10 分钟窗口内完成，不能作为全绿证据；外部 pkg/db/SAX/HTTP/bc2sa/node/vm/wgpu 当前测试通过，Deno 可构建但无 test step，TS 插件 Debug 测试有 1 个 benchmark 阈值失败。

---

# 实现计划：SA 线性所有权语言与编译器（按版本路线图）

## 紧急 P0 任务：工业级性能重构 (Industrial Performance Refactor)

> **当前状态**：通过 `demos/compare` 基准测试发现，由于寄存器 ID 全局化，在大规模（10k+ 函数）工程下编译会触发 $O(N^2)$ 内存爆炸并 OOM。
> **目标**：将内存占用从 $O(Inst \times GlobalReg)$ 降至 $O(Inst \times LocalReg)$，实现真正的线性扩展。

- [x] **Task P0.1: 寄存器作用域局部化**：修改 Flattener 逻辑，确保每个 `@func` 拥有独立的寄存器 ID 空间。
- [x] **Task P0.2: 稀疏状态注解存储**：重构 `AnnotatedInstruction`，由全量 `[]u16` 快照改为记录状态增量（Delta），解决内存爆炸。
- [x] **Task P0.3: 流式 Emitter 改造**：历史文本 emitter 的流式化阶段已被 P0.5 取代；主线现已删除文本后端，只保留 LLVM-C 纯 `.sa.bc` 流。
- [x] **Task P0.4: 声明级并行发射 (Decl-level Parallel Emission)**：借鉴 Zig `Zcu.PerThread` 模型，将发射任务打散至单函数粒度，充分利用多核并行驱动后端。
- [x] **Task P0.5: 内存直通 Emitter 重构**：借鉴 Zig `codegen/llvm.zig`，引入 `llvm-c` 绑定，放弃文本 `.ll` 中转，直接在内存中构造 LLVM bitcode 模块，消除 I/O 瓶颈。
  - [x] P0.5a 核心闭环：默认已走结构化 LLVM-C builder 直接生成 `.sa.bc`，不再通过文本 IR 解析桥接；已覆盖 hello、loop、while 与 FFI handle 对象生成。
  - [x] P0.5a-default-bc：CLI / SAX 构建默认改为 LLVM-C 纯 `.bc` artifact 流，`build-exe` / `build-obj` / `build-wasm` / `test` 正常路径不再调用文本 emitter，也不再保留文本 LLVM 产物路径；SAX 测试替身也已改为真实 LLVM bitcode，使用 `BC c0 de` 魔数与 `llvm-dis` 回归兜底，避免 dummy 文本 bitcode 占位。
  - [x] P0.5b-atomic：LLVM-C 后端已覆盖 `atomic_load` / `atomic_store` / `atomic_rmw_*` / `cmpxchg` / `fence`，atomic smoke 通过默认纯 `.sa.bc` 流生成 bitcode 并以退出码 11 运行。
  - [x] P0.5b-fallible：LLVM-C 后端已覆盖 fallible ABI `{i32, payload}`、fallible call、`?` payload 提取/早返传播、fallible return 打包与 native main wrapper 状态返回；`19_result_question` / `50_error_chain` / `180_try_trait_v2` 默认 `.sa.bc` native smoke 通过。
  - [x] P0.5b-vtable-indirect：LLVM-C 后端已覆盖 vtable 常量、vtable slot provenance、`call_indirect` typed callee cast 与纯 `.sa.bc` native 运行；`07_trait_vtable` / `110_trait_super_vtable` / `32_trait_object_vector` smoke 通过且不生成 `.ll`。
  - [x] P0.5b-sys-wasm：LLVM-C 后端已内建 `@sys_print` / `@sys_exit` / `@sys_argc` / `@sys_argv` / `@sys_read_file` / `@sys_write_file` 最小 runtime，并按 `size_bits` 修正 wasm32 ABI；`demos/support/sys_runtime_probe.sa` native 运行输出 `ok`，wasm32 通过 Node/WASI 输出 `ok`，且只生成 `.sa.bc` 中间产物。
  - [x] P0.5b-memslot：LLVM-C 后端将 SA 可变寄存器固化为按函数实际 slot 数分配的 entry `i64` mem-slot，消除分支/循环合流处的 SSA dominance 错误；`sort_probe` / `hashmap_probe` / `hashset_probe` / `once_probe` / `mpsc_probe` 已通过纯 `.sa.bc` native smoke 且不生成 `.ll`。
  - [x] P0.5b-debug-min：LLVM-C 后端在纯 `.sa.bc` 流中写入最小 DWARF metadata（compile unit / subprogram / instruction location）；`build-exe -g` 通过，`llvm-bcanalyzer-14` 可见 `llvm.dbg.cu`，且未生成 `.ll`。
  - [x] P0.5b-bitcode-reader：修正 LLVM-C sys argv runtime 的 typed-pointer GEP，`demos/support/sys_runtime_probe.sa` 生成的 `.sa.bc` 可被 `llvm-dis-14` 严格反汇编，native 运行输出 `ok`，且未生成 `.ll`。
  - [x] P0.5b-sab-v3-metadata：SAB v3 保留 LLVM-C 后端需要的 raw instruction text、atomic operand text、native register names、package/upstream metadata 和 verifier-derived function register ids；插件桥接编码前先 verify flattened input，decoded SAB 可作为 `sa test/build-exe` 输入而不丢 SA 语义元数据。
  - [x] P0.5b-debug-vars：LLVM-C 后端在 debug 模式下为函数参数和 SA slot alloca 写入 `llvm.dbg.declare` / `DILocalVariable`；`build-exe -g` 产物可被 `llvm-dis-14` 反汇编并可见变量元数据，native 运行输出 `21`，且未生成 `.ll`。
  - [x] P0.5b-wasm-sys-e2e：`tests/cli_smoke.zig` 已将 `sys_runtime_probe.sa` 扩展为 native + wasm32-WASI 双轨验收，覆盖 argv、文件读写、打印、退出码、`.wasm.sa.bc` 产物和 Node/WASI 运行，且未生成 `.ll`。
  - [x] P0.5b-wasm-demo-matrix：新增独立 `zig build wasm-matrix` rosetta/support native + wasm32-WASI 等价矩阵，覆盖 110 个 demo：基础 print/control-flow/struct/array/slice/string/loop/while/break/nested-loop/factorial/fibonacci、mutability/box/reference/move/borrow/refcount/resource、常量结构体、Option、generic、method、associated fn、enum/match/tuple/destructuring/tagged union、iterator map/filter/fold、module/import/export/config、cache/mem fill/queue、router/parser/serializer、service/pipeline/graph/component、metrics/workflow/kv/sql/blob/sync/scheduler、protocol/text/job/db/query/log/build/release、state/event/channel/actor/async/counter、fallible `?`/Result、vtable/trait object、callback contract、sort/hashmap/hashset/once/mpsc；修正 wasm32 vtable 8 字节槽宽 ABI，补 `sa_time_sleep_ns` fallible weak fallback，并补 LLVM-C `struct_` 常量字节展开；验证通过且主线不保留文本 LLVM 产物路径，同时从巨大的 `cli_smoke` 拆出，避免单项 matrix 重新编译整套 CLI smoke。
  - [x] P0.5b 覆盖扩展：现有 rosetta/support native stdout smoke demos 已全部纳入 wasm/native 等价矩阵；argv / panic-hook 命名 demo 当前源码为纯确定性输出，也已覆盖。

## Rust Core 模式落地任务

- [x] **1. Cell / RefCell 布局与宏**
  - 产出 `Cell` / `RefCell` 的 `.sal` 布局样例和宏模板
  - 明确借用计数器、归零路径、Trap 分支与显式释放顺序
- [x] **2. Rc / Arc / Weak 双计数控制块**
  - 产出 Strong / Weak 双计数控制块布局
  - 验证 `clone` / `drop` / `downgrade` / `upgrade` / `drop` 的级联逻辑
  - 对齐约束必须显式写入布局文件
- [x] **2.1 SA 单测收口**
  - `tests/rust_core_unit.sa` 已覆盖 `cell` / `refcell` / `rc` / `weak` 的 SA 原生 `@test`
  - 使用仓库内 SA 标准库相对导入，直接由 `sa test` 执行
- [x] **3. Waker / Trait Object 调度模式**
  - 产出 vtable / 间接调用示例
  - 确保宏展开末尾清理所有临时寄存器，并避免标签冲突

### 验收口径
- 只接受“宏 + 布局 + Referee 校验”路线，不接受新增 ISA
- 前端降级失配必须通过结构化 Trap 暴露，不接受运行时静默容错


## 当前执行顺序

1. 先完成主线：标准库收口、单元测试框架、零信任包管理、`sa_net_uring`、`bc2sa`。
2. 插件工作只允许在插件边界内推进：每个插件必须独立交付 `.so` 产物、runtime 加载、热重载、ABI 版本化、失败隔离、skills 元数据和生命周期钩子。
3. 不要把插件实现回写到主线程分发逻辑里；主线程只保留发现、加载、卸载、热重载与派发入口，插件命令、skills、生命周期逻辑和测试必须留在各自目录。
4. 构建期错误和运行期失败隔离分开验收：单个插件编译失败只能影响对应 `.so` 产物或插件自身测试，不应把已稳定的宿主运行路径退回静态注册模型。
5. 任务拆分时默认按插件目录并发推进；如果某个插件已有错误，优先修它自己的目录，不要把修复扩散到主线程或别的插件目录。

## 概述

本实现计划按**版本递进**组织，而不是一次性交付全部 23 条需求。核心思路：

1. **v0.1 MVP（Week 1-14）** — "跑通闭环"。SA 源码 → Flattener → Referee → LLVM bitcode → **全程走 `zig cc`** 产出 `.exe` 和 `.wasm`。不自研任何后端。
2. **v0.2（post-MVP，4-6 周）** — "后端自研"。替换 WASM 产线为手写二进制 Emitter，获得更小体积、wasm64、DWARF-in-WASM 精细控制。
3. **v0.3（post-MVP，6-8 周）** — "性能兑现"。SIMD/并行调度/LLM 微调 / AutoBevy 1M ±30%（最低优先级）路线。

## 插件任务验收标准

- 当前插件实现已统一外置到 `/home/vscode/projects/sa_plugins/` 的独立工程；主线只保留薄宿主层、ABI 约定和最小 loader 边界，不再承载插件业务逻辑。
- 插件必须以 runtime `.so` 形式交付，不能把静态注册或宿主内联实现当成完成态。
- 插件必须支持热重载语义，至少能在宿主进程内完成加载、卸载、重新加载的回归验证。
- 插件必须保持目录隔离，agent 只改本插件目录及其入口文件，不改 `src/cli.zig` 的静态分发逻辑。
- 插件编译失败只能影响对应插件产物与该插件测试，不应让其它插件回退到静态耦合路径。
- 插件目录内必须包含 skills 元数据、命令实现和自己的测试，不能依赖宿主补写业务语义。
- 如果插件有公共 ABI 适配层，必须写在插件目录内，且以 `plugin_descriptor` / `saasm_plugin_descriptor_v1` 作为 runtime 导出验收点。
- “完成”必须同时满足：`.so` 可被宿主 runtime 发现，命令入口可执行，skills 可收集，热重载测试通过，且失败插件不会污染其他插件的加载结果。
- 任何插件相关实现都不得把主线程从 runtime loader 回写成静态注册；如果需要改宿主，只能改 loader/隔离/热重载这一层。
- 任何插件任务的验收都必须写清楚：要修改的目录、是否会影响主线程、是否需要 `.so` build、是否需要 hot reload 测试、是否需要失败隔离验证。
- 如果插件最终要开放给 SA 调用，还要额外验收 `sa run` / `@extern` 直调该插件 ABI，并确认解释器不会把插件 handle 当普通堆指针释放。
- 目前 HTTP client/server 已完成 `sa run` 直调桥接，后续新增插件若要给 SA 调用，必须沿用同样的 runtime `.so` + interpreter bridge 模式，不能回到主线程静态分发。

**v0.1 不做的事**（这是刻意的风险削减）：
- ❌ 不手写 WASM 二进制 Emitter（走 `zig cc -target wasm32-wasi -O ReleaseSmall`）
- ❌ 不自研 DWARF-in-WASM（zig cc 自带）
- ❌ AutoBevy 仅作为最低优先级，1M ±30% 不承诺（只跑 1K 冒烟）
- ❌ 不承诺 LLM 零训练 80% 成功率（只跑 pilot 归档 baseline）
- ❌ Referee 不强求 1500 行（2500 行 MVP 基线）
- ❌ 不做 SIMD opcode 降级（ISA 里有占位，但 Emitter 层先 `unreachable`）

工程根目录：

```
sa/
├── build.zig
├── build.zig.zon
├── src/
│   ├── common/              # Instruction / CapabilityMask / Trap / GasReport / UpstreamLoc
│   ├── flattener/           # 预处理 + #loc + 宏
│   ├── referee/             # 状态机 + Phi + 气闸舱 + 早返回 + 原子 ordering
│   ├── emit_llvm_llvmc.zig    # LLVM-C bitcode builder + DWARF
│   ├── emit_wasm/           # [v0.2] 手写 WASM 二进制（v0.1 为空目录）
│   ├── interp/              # sa run 内存解释器
│   ├── driver/              # zig cc 子进程封装
│   ├── cli/                 # sa 四模命令行
│   ├── runtime/             # @sys_* / __sa_panic / snapshot
│   └── libsa_scope/         # 前端降级 helper (C-ABI)
├── tests/{unit,property,integration,golden,pilot}/
├── bench/
└── docs/{whitepaper.md,whitepaper.txt,ebnf.md}
```

---

# Version 0.1 — MVP：跑通闭环（14 周）

目标：一段可编译的 `.sa` 源码能通过 CLI 四模分别产出可运行的 `.exe`、`.wasm`，并在 Referee 上守住所有权正确性。**WASM 产线这一版完全委托 `zig cc`。**

## v0.1 任务

- [x] 1. 初始化 Zig 工程脚手架与工具链
  - 创建 `build.zig` / `build.zig.zon`，目标：单文件静态 CLI
  - 约定 src/tests/bench/docs 目录骨架
  - 集成 Zig PBT 库（无合适选项则以 C-ABI 夹心 Rust proptest）
  - 锁定 Zig 内置 LLVM 版本入 CI 矩阵
  - 配置 `zig fmt --check` / `zig build test` / `tokei` LOC 统计
  - _Requirements: R14.11, R16.6_

- [x] 2. W1-2 协议定型

  - [x] 2.1 定义 `Instruction` / `Operand` / `InstKind` / `OpKind` / `AtomicOrdering` 数据结构
    - 按 design §4.1 实现全部枚举，包含 `Try` / `EarlyReturn` / `AtomicLoad` / `AtomicStore` / `Cmpxchg` / `Fence` / `RawCast` / `AssumeSafe` / `AssumeBorrow` / `LocHint`
    - `operands: [4]Operand` 固定大小
    - _Requirements: R2.1, R2.2, R2.5, R13.1_

  - [x]* 2.2 Instruction 编解码单元测试
    - _Requirements: R2.1, R2.2_

  - [x] 2.3 `CapabilityMask` 8 位真值表常量表
    - 按 design §4.2 定义 `Active` / `Locked_Read` / `Locked_Mut` / `Consumed` / `BorrowView` / `FfiBorrow` / `Untracked` / `Fallible`
    - 编码 TRUTH_TABLE 数组供 Referee 查表
    - _Requirements: R4.1–R4.7, R13.2, R13.3, R18.1_

  - [x]* 2.4 位运算单元测试
    - _Requirements: R4.1, R4.2_

  - [x] 2.5 `TrapReport` JSON schema
    - 按 design §4.4 含 `upstream_loc` / `function` / `is_ffi_wrapper` 字段
    - 29 种 Trap 枚举在 `src/common/trap.zig` 中已列出；其中一部分仅在路线图中保留，尚未全量接入发射路径
    - _Requirements: R9.3, R13.5, R13.7, R17.7, R18.5, R19.2_

  - [x] 2.5a 错误码与诊断规划
    - 以 `docs/errorcode.md` 作为统一查阅入口；`design.md` §4.4 固定 `TrapReport` schema，`docs/faq.md` 解释为什么公共诊断是 JSON-first
    - 统一字段约定：`trap` / `line` / `source_line` / `register` / `registers` / `expected_mask` / `actual_mask` / `expected_mask_name` / `actual_mask_name` / `upstream_loc` / `function` / `is_ffi_wrapper` / `message` / `hint`
    - 明确 `Trap` enum ordinals 不是公开数值代码，后续如需 `trap_code` 必须显式新增
    - 参考 Zig 编译器的 `ErrorMsg` / `ErrorBundle` 组织方式，保留主消息 + note/hint 的结构化诊断能力
    - _Requirements: R9.3, R16.5, R18.5, R19.2_

  - [x] 2.6 `GasReport` / `FunctionSig` / `ParamSpec` / `UpstreamLoc`
    - `FunctionSig` 含 `kind` / `is_ffi_wrapper` / `return_fallible` / `upstream_file`
    - _Requirements: R5.1, R5.3, R11.1, R13.4, R18.1_

  - [x] 2.7 产出 EBNF 文档
    - `docs/ebnf.md` 按 design 附录 C，含 `loc` / `ffi_wrapper_def` / `try_op` / `panic_op` / `atomic_*` / `rawcast` / `assume_*`
    - _Requirements: R1.6, R3.1, R13.1, R13.9_

  - [x] 2.8 产出 LLM 白皮书 v0.1
    - `docs/whitepaper.md` + `.txt`，≤ 2000 行
    - 覆盖 R23.2 全部章节（五符号 + ISA + CFG + 掩码 + 宏 + 气闸舱 + `@sys_*` + 错误传播 + `#loc` + 降级合约摘要 + 5 组对比 + Trap 代号表）
    - _Requirements: R1.1–R1.5, R20.1–R20.2, R23.1, R23.2, R23.5_

  - [x]* 2.9 白皮书 lint 冒烟（≤ 2000 行）
    - _Requirements: R23.1_

- [x] 3. 检查点 — 协议定型
  - 运行 `zig build test`。

- [x] 4. W3-5 Flattener

  - [x] 4.1 行分类器（16 种形态）
    - _Requirements: R3.1_

  - [x] 4.2 `#def` 字典 + 常量折叠（`+/-/*`）
    - _Requirements: R7.1–R7.5_

  - [x]* 4.3 常量折叠 PBT — **P8**
    - _Requirements: R7.1, R7.2, R7.5_

  - [x] 4.4 禁用语法扫描（`{` `}` `if` `else` `while` `for` `a.b.c`）
    - _Requirements: R3.3, R6.6_

  - [x]* 4.5 禁用语法 PBT — **P4**
    - _Requirements: R3.2, R3.3, R6.6_

  - [x] 4.6 `#loc` 伪指令收集器
    - 维护 `LocTable: Map<expanded_line, UpstreamLoc>`
    - 下一条真实指令继承最近一次 `#loc` 值
    - _Requirements: R19.1_

  - [x]* 4.7 `#loc` 单调映射 PBT — **P25**
    - 随机插入 `#loc`，断言 Trap 报告与 LocTable 一致
    - _Requirements: R19.1, R19.2_

  - [x] 4.8 宏模板注册 `[MACRO]...[END_MACRO]`
    - _Requirements: R8.1_

  - [x] 4.9 `EXPAND` 文本展开 + 深度栈（上限 256）
    - _Requirements: R8.2, R8.5, R8.6_

  - [x] 4.10 `[REP N]...[END_REP]` + 游标 `%i`
    - _Requirements: R8.3, R8.5_

  - [x]* 4.11 宏展开 PBT — **P6**
    - _Requirements: R8.1, R8.2, R8.3, R8.5_

  - [x] 4.12 宏/常量错误检测（`DuplicateDef` / `RegisterRedefinition` / `MacroRecursionLimit`）
    - _Requirements: R7.4, R8.4, R8.6_

  - [x]* 4.13 非法宏 PBT — **P7**
    - _Requirements: R7.4, R8.4, R8.6_

  - [x] 4.14 寄存器名规范化为 `u32` ID（保留 SymbolTable）
    - _Requirements: R2.1_

  - [x] 4.15 函数签名解析
    - `src/common/signature.zig` 已覆盖 `@func` / `@ffi_wrapper` / `@extern` / `@export` 四类
    - 已解析 `-> T!` 可失败返回并保留 `return_fallible`
    - _Requirements: R3.1, R5.1, R5.3, R13.4, R13.9, R14.9, R14.10, R18.1_

  - [x]* 4.16 签名解析确定性 PBT — **P11**
    - `src/common/signature.zig` 已加入随机函数头生成与双次解析结构等价断言
    - _Requirements: R2.2, R5.1, R5.3_

  - [x] 4.17 原生类型字面量合法性（11 种 + `v128`）
    - `PrimType` / `parsePrimType` / layout / LLVM type mapping 已接入 `v128`
    - `sa run` 遇 `v128` 明确返回 `UnsupportedInstruction`，不伪造语义
    - _Requirements: R2.4_

  - [x]* 4.18 类型字面量 PBT — **P14**
    - `src/common/signature.zig` 已加入合法字面量随机采样与近似非法字面量拒绝测试
    - _Requirements: R2.4_

  - [x] 4.19 原生逃逸块 `$...$` 识别 + 涉及寄存器名列表
    - `src/flattener/line_classifier.zig` 已识别 `$...$` 为 `native`
    - `src/flattener.zig` 已把块内容保存到 `Instruction.native_text`，并提取裸标识符列表到 `Instruction.native_reg_names`
    - _Requirements: R1.5_

  - [x] 4.20 气闸舱指令解析（`*` / `assume_safe` / `assume_borrow`）
    - Flattener / line classifier 已解析 `RawCast` / `AssumeSafe` / `AssumeBorrow` 三类指令
    - _Requirements: R13.1, R13.2, R13.3_

  - [x] 4.20a `ptr_add` 解析（`dst = ptr_add base, off`）
    - Flattener 已解析并保留 base / off 槽位，支持立即数与寄存器偏移
    - _Requirements: R2.5, R4.9, R4.10_

  - [x] 4.21 原子指令解析（`atomic_load` / `atomic_store` / `cmpxchg` / `fence` + ordering）
    - 已接入 Flattener / Referee / LLVM / Interpreter，并补原子冒烟测试
    - _Requirements: R2.1, R2.6_

  - [x] 4.22 错误传播语法糖 `? reg` 展平
    - 前端层直接展平为 `br_ok + L_early_return` + `EarlyReturn` 指令
    - Referee 无需新增指令类型
    - _Requirements: R18.2, R18.3_

  - [x] 4.23 `panic(code)` 解析为特殊 Call
    - _Requirements: R18.4_

  - [x] 4.24 Flattener 公开 API `flatten(allocator, source) !FlattenResult`
    - _Requirements: R7.1, R8.1, R19.1_

  - [x]* 4.25 Flattener 端到端单测
    - _Requirements: R3.1, R7.1, R8.1, R13.1, R18.2, R19.1_

- [x] 5. 检查点 — Flattener 完成
  - 跑过 P4、P6、P7、P8、P11、P14、P25

- [x] 6. W6-9 Referee（含一周性能调优）

  - [x] 6.1 `CapabilityTable`（masks / origins / lock_refs / flags）
    - _Requirements: R4.1, R9.2_

  - [x] 6.2 统一指令校验函数骨架（把 16+ 种 `InstKind` 收敛为"读 N 源 + 写 M 目标"模式）
    - MVP 基线 ≤ 2500 行 Zig；stretch 目标 1500 行
    - _Requirements: R9.1, R9.2, R9.5_

  - [x] 6.3 四仿射规则（alloc / borrow / move / release）
    - _Requirements: R1.1–R1.4, R4.3–R4.4, R4.6–R4.7_

  - [x]* 6.4 所有权状态机 PBT — **P1**
    - _Requirements: R1.1–R1.4, R4.1–R4.7_

  - [x] 6.5 未声明寄存器检测
    - _Requirements: R2.3_

  - [x]* 6.6 `UnknownRegister` PBT — **P13**
    - _Requirements: R2.3_

  - [x] 6.7 函数出口泄漏检测
    - _Requirements: R4.5_

  - [x] 6.8 基本块结束指令 + 重名 Label
    - _Requirements: R3.4, R3.5_

  - [x]* 6.9 CFG 结构完整性 PBT — **P5**
    - _Requirements: R3.4, R3.5, R10.2_

  - [x] 6.10 Phi 汇聚点按位 AND
    - 合法交集 `{0x01, 0x02, 0x04, 0x08, 0x11, 0x12}`
    - _Requirements: R10.1–R10.4_

  - [x]* 6.11 Phi PBT — **P9**
    - _Requirements: R10.1, R10.3_

  - [x] 6.12 调用点契约前缀校验
    - `src/referee/verifier.zig` 已在直接调用路径校验 call-site capability prefix 与声明签名一致
    - `src/referee/call.zig` 同步提供纯解析/校验 helper
    - _Requirements: R5.2_

  - [x]* 6.13 调用契约 PBT — **P12**
    - `src/referee/call.zig` 已加入随机 capability 合约 PBT
    - `src/referee/verifier.zig` 已加入真实程序路径的前缀失配随机回归
    - _Requirements: R5.2_

  - [x] 6.14 原生逃逸保守消费
    - `src/referee/verifier.zig` 已将 `$...$` 视为 contract boundary：引用的已知寄存器按保守消费处理
    - 借用视图按现有消费语义清借用；`stack_alloc` 穿越原生边界直接 `Trap: StackEscape`
    - _Requirements: R5.4_

  - [x]* 6.15 原生逃逸保守消费 PBT — **P3**
    - 已加入确定性负例与随机化回归：`native` 后再访问被引用寄存器触发 `UseAfterMove`
    - _Requirements: R5.4_

  - [x] 6.16 **气闸舱强制隔离**
    - `RawCast` / `AssumeSafe` / `AssumeBorrow` 仅当 `is_ffi_wrapper == true` 通过
    - 否则 `Trap: IllegalUnsafeContext`
    - _Requirements: R13.1, R13.4, R13.5_

  - [x]* 6.17 气闸舱隔离 PBT — **P21**
    - 已加入随机化测试覆盖 `*` / `assume_safe` / `assume_borrow` 在普通函数中的非法使用
    - _Requirements: R13.1–R13.5_

  - [x] 6.18 **FFI 借用不可销毁**
    - Verifier / CapabilityTable 已对 `FfiBorrow` 位寄存器落地：遇 `^` → `Trap: FfiOwnershipViolation`；遇 `!` 仅清记录不发射 free
    - _Requirements: R13.3, R13.7_

  - [x] 6.18a 母借用 / 子指针追踪
    - Verifier 已对 `ptr_add` 与借用相关 `load`/`take` 建立 parent borrow reg -> interior children 映射
    - 母借用 `!` / 解锁时同步将所有派生 `InteriorPtr` 置为 `Consumed`
    - _Requirements: R4.9, R4.10_

  - [x] 6.18b `InteriorPtrEscape` 逃逸拦截
    - Verifier 已在 `@extern` / `@ffi_wrapper` 调用边界拦截 `InteriorPtr`
    - _Requirements: R13.6, R13.7_

  - [x]* 6.18c 内部指针生命周期 PBT — **P26**
    - 已加入随机化测试：释放母借用后访问派生 `InteriorPtr` 触发 `UseAfterMove`
    - 已加入随机化测试：`InteriorPtr` 作为 `@extern` / `@ffi_wrapper` 实参触发 `InteriorPtrEscape`
    - _Requirements: R4.9, R4.10, R13.6, R13.7_

  - [x]* 6.19 FFI 借用不可销毁 PBT — **P22**
    - 已加入 `assume_borrow` 状态位断言、`^`/`return` 违规断言与 CapabilityTable 对应单测
    - _Requirements: R13.3, R13.7_

  - [x] 6.20 **错误传播早返回泄漏校验**
    - `EarlyReturn` 指令作为特殊 `Return` 处理，检查该路径上 Active/Locked 残留 → `Trap: EarlyReturnLeak`
    - `?` 作用于非 Fallible 寄存器 → `Trap: FallibleContractMismatch`
    - _Requirements: R18.5_

  - [x] 6.20a **stack_alloc 退出规则**
    - `stack_alloc` 允许函数出口自动回收，不计入 `MemoryLeak`
    - `stack_alloc` 作为 `^` / `return` / `move` / `call` 实参时必须 `Trap: StackEscape`
    - _Requirements: R2.1, R2.8, R9.1_

  - [x]* 6.21 早返回泄漏 PBT — **P24**
    - `src/referee/verifier.zig` 已加入随机 live allocation 泄漏用例，断言 `?` 的 fail edge 触发 `Trap: EarlyReturnLeak`
    - _Requirements: R18.5_

  - [x] 6.22 原子 ordering 一致性校验
    - 相同地址 RMW 检查 happens-before（简化实现：仅做 ordering 组合表查表，不跨函数追踪）
    - 违规 → `Trap: AtomicOrderingMismatch`
    - 已补 verifier 查表与负例测试
    - _Requirements: R2.6_

  - [x] 6.23 Gas 静态计数
    - Referee 已输出 `GasReport`，包含 `max_alloc_bytes` / `max_instruction_steps` / `call_depth`
    - 真实代码验证覆盖前向跳转 bounded 与回边 unbounded
    - _Requirements: R11.1–R11.3_

  - [x]* 6.24 Gas PBT — **P19**
    - 随机生成 bounded / unbounded 两类真实程序，验证静态 gas 报告与回边判定一致
    - _Requirements: R11.1–R11.3_

  - [x]* 6.25 Referee 确定性 PBT — **P10**
    - 同一输入重复 `verify()`，比较 `ok` / `trap` 的结构化快照完全一致
    - _Requirements: R9.3, R9.4, R11.2_

  - [x] 6.26 真实代码吞吐基准（W9）
    - 生成"含回边 + 多函数 + 气闸舱 + 早返回"的 1M 行合法流（非直线合成）
    - ReleaseFast 实测：1,000,000 行 / 1.886612s = 530,050.82 行/秒，达到 MVP 基线
    - _Requirements: R9.6_

  - [x] 6.27 Referee LOC lint（`tokei src/referee/ src/verifier.zig` ≤ 6500）
    - 2026-06-09 口径对齐真实验证核心：`src/referee/ + src/verifier.zig` = 5960 code lines（builtin fallback），已安装并实际跑通
    - _Requirements: R9.5_

- [x] 7. 检查点 — Referee 完成
  - 跑过 P1、P3、P5、P9、P10、P12、P13、P19、P21、P22、P24

- [x] 8. W10-11 LLVM bitcode Emitter + CLI + `zig cc` 全权代劳的 exe/wasm

  - [x] 8.1 基础映射 M01–M07（alloc/free/load/store/运算）
    - `src/emit_llvm_llvmc.zig` 主线已直接覆盖：
      - `alloc -> call ptr @malloc(...)`
      - owned `!r -> call void @free(ptr ...)`
      - borrowed `!r -> no-op`
      - typed `load/store -> getelementptr + load/store`
      - 算术/比较按整数/无符号/浮点类型分别发射；`gt` 已修正为整数路径 `icmp sgt`
    - 已补 emitter 级直接测试：`llvm emitter maps M01-M07 with typed integer ops and owned release`、`llvm emitter maps M03 borrow release to no-op`
    - `src/referee/verifier.zig` 已修正 `AnnotatedInstruction.entry_caps/exit_caps` 快照时机，保证 emitter 基于真实 entry state 判断 release 是否物理 free
    - _Requirements: R14.3–R14.6_

  - [x] 8.2 控制流映射 M08–M13（LLVM 原生 `br` + labels）
    - `jmp` / `br` / `br_null` / direct call / `return` 已有 emitter 级直接测试
    - `call_indirect` 已按签名与 provenance 发射 / 分派，`tests/cli_smoke.zig` 的 `vtable loads preserve indirect call provenance end to end` 覆盖了端到端路径
    - _Requirements: R14.8_

  - [x] 8.3 `take` 映射 M14
    - `src/emit_llvm_llvmc.zig` 主线已将 `take src+off` 发射为 `getelementptr i8, ptr %src, i64 off` + `load ptr`
    - 已补 emitter 级直接测试，断言 LLVM 产物包含 `load ptr, ptr`
    - _Requirements: R14.5_

  - [x] 8.4 原生逃逸块 M15 字节级透传
    - 文本 legacy emitter 已删除；主线 LLVM-C bitcode 后端不再支持文本 IR 原生逃逸透传
    - _Requirements: R14.7_

  - [x]* 8.5 原生逃逸字节透传 PBT — **P2**
    - `src/emit_llvm_llvmc.zig` 已覆盖主线；legacy 文本 emitter 与其文本 IR 测试已移除，避免 `.ll` 后门
    - _Requirements: R14.7_

  - [x] 8.6 函数/Label/`@extern`/`@export` 映射 M16-M17, M21-M22
    - `src/emit_llvm_llvmc.zig` 主线已对普通函数/label 产出 `define` / `L_X:`
    - `@extern` 已产出 LLVM `declare`
    - `@export` 已产出无名称修饰的 `define`
    - `tests/cli_smoke.zig` 与 emitter 单测已覆盖 IR 与目标文件符号证据
    - _Requirements: R14.9, R14.10_

  - [x] 8.7 索引访问物理降维（`mul + GEP + load`）
    - `demos/rosetta/44_slice_iteration/main.sa` 已实测走通 `offset = mul idx, 4` -> `ip = ptr_add data, offset` -> `value = load ip+0 as i32`
    - `tests/cli_smoke.zig` 已固定验证该 demo `build-exe` 后真实运行并打印 `10\n`
    - _Requirements: R6.5_

  - [x]* 8.8 索引访问 PBT — **P15**
    - `src/emit_llvm_llvmc.zig` 已覆盖主线；索引访问回归以 `.sa.bc` 端到端 smoke 为准，不再保留文本 `.ll` 断言
    - `tests/cli_smoke.zig` 已有 `44_slice_iteration` 端到端 `build-exe` 回归，固定验证索引访问 demo 可真实运行并打印 `10\n`
    - _Requirements: R6.5_

  - [x] 8.9 气闸舱指令映射 M18-M20（`ptrtoint` / `inttoptr`）
    - `src/emit_llvm_llvmc.zig` 主线已将 `raw = *safe` 发射为 `ptrtoint ptr ... to i64`
    - `assume_safe` / `assume_borrow` 已发射为 `inttoptr i64 ... to ptr`
    - 已补 emitter 级直接测试：`llvm emitter maps M18-M20 airlock casts`
    - _Requirements: R13.1, R13.2, R13.3_

  - [x] 8.10 原子指令映射 M24-M27
    - `src/emit_llvm_llvmc.zig` 主线已发射 `load atomic` / `store atomic` / `atomicrmw` / `cmpxchg` / `fence`
    - `tests/cli_smoke.zig` 已覆盖端到端 exe/wasm/obj 产物与运行结果
    - 已补 emitter 级直接测试：`llvm emitter maps M24-M27 atomic instructions directly`
    - _Requirements: R2.6, R14.4, R14.5_

  - [x] 8.10a `ptr_add` 映射 M35
    - LLVM Emitter 已生成 `%dst = getelementptr i8, ptr %base, i64 %off`
    - _Requirements: R2.5_

  - [x] 8.11 错误传播展平产物 M28（`extractvalue + icmp + br`）
    - Flattener 已展平为 br + EarlyReturn，Emitter 直接翻译
    - _Requirements: R18.3_

  - [x] 8.12 `panic(code)` 映射 M29
    - Native: `call void @__sa_panic(i32) noreturn`
    - **v0.1 WASM 路径**：由 `zig cc -target wasm32-wasi` 自动把 `@__sa_panic` 降为 `unreachable` 或 WASI exit
    - _Requirements: R18.4_

  - [x] 8.13 Fallible ABI 映射 M30（返回 `{i32 status, T value}`）
    - _Requirements: R18.1_

  - [x] 8.14 `#loc` 上游映射 M31（DWARF `!DILocation` 元数据）
    - 顶部生成 `!DICompileUnit` / `!DIFile` / `!DISubprogram`
    - 每条指令附 `!dbg !N`
    - `--no-debug` 关闭
    - _Requirements: R19.3, R19.5_

  - [x]* 8.15 LLVM bitcode 语法合法性 PBT — **P16**
    - `src/emit_llvm_llvmc.zig` 已覆盖主线；文本 `.ll` 语法校验回归已移除，合法性以 LLVM-C bitcode builder 和 `.sa.bc` 读写验收为准
    - _Requirements: R14.1, R14.3–R14.10_

  - [x]* 8.16 Zig 依赖受限 PBT — **P17**（v0.1 版本：断言产物 `@import` 集合为空，因为我们不生成 Zig 源码）
    - `src/emit_llvm_llvmc.zig` 已覆盖主线；不再生成 Zig/LLVM 文本源码，`@import` 文本断言已无主线路径
    - _Requirements: R14.11_

  - [x] 8.17 LLVM-C bitcode Emitter 公开 API `emitLlvmc(allocator, verified, loc_table) ![]const u8`
    - 附 source map `inst_idx → ir_line`
    - _Requirements: R14.1_

  - [x] 8.18 `zig cc` 子进程封装 `driver/zigcc.zig`
    - 把 `.bc` 写临时文件
    - `sa build-exe` → `zig cc <bc> -o <exe> -O ReleaseSmall`（默认 O1 档，`--release-fast` 切 O3）
    - **`sa build-wasm` → `zig cc <bc> -target wasm32-wasi -o <wasm> -O ReleaseSmall`（全程使用 `.sa.bc` artifact，不生成文本 `.ll`）**
    - `sa build-obj` → `zig cc <bc> -c -o <o>`
    - _Requirements: R14.1, R14.11, R15.1, R15.2, R16.2, R16.3, R16.4_

  - [x] 8.19 CLI `sa run` / `build-exe` / `build-wasm` / `build-obj` 四模路由
    - Trap 返回非零退出码 + JSON 到 stderr
    - _Requirements: R16.1, R16.5_

  - [x] 8.20 CLI 二进制分发约束
    - `zig build -Drelease-small` 产物 ≤ 15 MB（MVP），`zig-out/bin/sa` 为静态、剥离后的 ELF，可直接满足分发约束
    - _Requirements: R16.6_

  - [x] 8.21 `-g` / `--no-debug` 调试开关接入
    - `-g` 默认关，`build-exe -g` 启用 DWARF 生成
    - _Requirements: R19.4, R19.5_

  - [ ] 8.22 Agent-First JSON 诊断体系改造 (NEW)
    - 为 `trap.zig` 中的报错赋予稳定的 `SA-XXX` 错误码
    - 实现全局 `--json` 标志，输出含 `repair`、`compile_tokens` 和 `instruction_count` 的结构化诊断
    - 新增 `sa explain` 和 `sa fix --plan` 骨架命令
    - 当前已落地的子集：`trap.zig` 已支持 `repair` 对象，`src/cli.zig` / `src/cli_util.zig` 已接入 `SA-CLI-001..015` 诊断码，`sa explain` / `sa fix --plan` / `sa skills` 已实现并有 `tests/cli_smoke.zig` 覆盖
    - 仍待补齐：trap 侧稳定 `SA-XXX` 命名与后续 trap 词表统一

  - [x] 8.23 可热插拔 CLI 插件系统重构 (NEW，后置)
    - 完成态必须是 runtime hot-reloadable 的动态库 `.so`，不接受静态注册、静态库 `.a`、或主线程硬编码分支作为替代
    - 每个插件必须独立交付自己的 `.so` 产物，并导出稳定 ABI 版本号、descriptor、命令入口、生命周期钩子与 skills 元数据
    - `src/plugins.zig` 只负责 runtime 发现、`dlopen`、`dlsym`、`dlclose`、热重载和失败隔离，不承载插件命令语义
    - 插件边界必须可热插拔：宿主可在运行时替换 `.so`，新版本生效后旧版本可卸载，同名插件以新版本覆盖旧版本
    - `init` / `prebuild` / `postbuild` / `skills` 必须来自已加载插件的运行时导出，宿主不内建插件行为
    - 插件错误必须局部化：单个插件加载失败、ABI 不匹配、符号缺失、descriptor 空值、命令返回异常，都不能拖垮主程序；宿主应跳过坏插件并保留结构化诊断
    - 主线代码的修改面必须最小化：插件实现只改各自目录与必要的宿主加载器，不回写主线程命令分发逻辑
    - 当前验收口径：
      - 至少 1 个插件完成端到端 `.so` 化，且宿主可在运行时发现、调用、卸载并重新加载
      - 至少 1 个同名插件替换回归测试，验证新 `.so` 覆盖旧版本后重新加载并生效
      - 至少 1 个失败隔离测试，验证坏插件不会阻断其他插件和主程序，且同目录内其他插件仍可加载
      - 至少 1 份最小 ABI 文档，写清版本号、导出符号、回调约定、错误码、兼容规则与 reload 语义
      - 每个插件目录都要有自己的最小运行时测试，覆盖 descriptor 导出、skills 元数据和命令入口
      - 插件构建失败只能影响对应 `.so` 产物或插件测试，不应把宿主退回成静态耦合模型
    - 并发拆分建议：
    - `src/sax/` 负责 SAX 外部插件的 runtime `.so` 完整化与热重载回归
      - `src/db/` 负责 DB 外部插件的 runtime `.so` 完整化与失败隔离
      - `src/pkg/` 负责 fetch/pkg 外部插件的 runtime `.so` 完整化与技能元数据
      - `src/bc2sa/` 负责 bc2sa 外部插件的 runtime `.so` 完整化与命令一致性
      - `src/http_server/` 负责 HTTP server 外部插件的 runtime `.so` 完整化与 scaffold 入口
      - 每个 agent 只允许改自己的插件目录和必要的本地测试，不得跨目录改动其他插件或主线程分发逻辑
      - 宿主侧只允许与动态加载和目录发现相关的最小改动；若无必要，不改 `src/cli.zig` 的主命令分发
      - 任何插件交付如果仍然依赖静态注册、静态库 `.a` 或主线程硬编码分支，视为未完成
    - 已验证完成：
      - `src/http_server/`：descriptor / skills / scaffold / serve / runtime `.so`
      - `src/bc2sa/`：descriptor / skills / command consistency / runtime `.so`
      - `src/sax/`：descriptor / skills / runtime `.so`，并通过 compile-time plugin-mode split 避免将 `std.process.Child.run` 拉进 shared-library 图
      - `src/db/`：descriptor / skills / runtime `.so`，nested test graph 通过本地 stub 收口，runtime wrapper 图通过真实 DB 入口
      - `src/pkg/`：descriptor / skills / prebuild / `fetch` / `install` runtime 命令均有插件本地测试；`install` 无参数读取 `sa.mod` 并真实 vendor 依赖，`install <identity>` 复用真实 fetch 路径；`zig build pkg-plugin-test` 已纳入 `zig build test`
      - `/home/vscode/projects/sa_plugins/sa_plugin_http_client` 与 `/home/vscode/projects/sa_plugins/sa_plugin_http_server`：`sa run` 已可直接调用 `sa_http_client_*` / `sa_http_server_*`，SA bridge 已接通
      - `/home/vscode/projects/sa_plugins/sa_plugin_deno`：已外置为独立插件工程，包含 `sap.json` / `deno.sai` / `deno.sal` / `libdeno.so`，并导出 `saasm_plugin_descriptor_v1` 与 `sa_deno_plugin_hostname`

  - [x] 8.24 标准库 JSON FFI 与生态剥离 (NEW，后置)
    - 打通 `sa_std/encoding/json` 的 DOM 与流式双模 FFI 桥接
    - 在文档层明确拒绝 YAML/XML 进入标准库，规划至周边 Package 生态
    - 说明：`sa_std/encoding/json.{sa,sai,sal}` 已提供 DOM / scanner / stream / writer surface，`src/runtime/sa_std.zig` 导出 `sa_json_*` Zig-backed FFI，`tests/std_smoke.zig` 与 `tests/unit_framework/feature_suite.sa` 覆盖 JSON DOM roundtrip / stream tokens；`docs/std_rfc.md` 与 `docs/faq.md` 明确 YAML/XML/TOML 剥离到外围生态。

- [x] 9. W10-11 内存解释器（`sa run`）

  - [x] 9.1 大 switch 分派全部 `InstKind`
    - `call_indirect` 现在优先使用寄存器里携带的 vtable provenance；`demos/rosetta/07_trait_vtable/main.sa` 已可在 `sa run` 下打印 `77`
    - 解释器分派和 `call_indirect` 路径已被 `tests/cli_smoke.zig` 的 `trait vtable demo runs through sa run` 覆盖
    - _Requirements: R16.1_

  - [x] 9.2 `@sys_*` 原语原生实现
    - `@sys_print` / `@sys_read_file` / `@sys_write_file` / `@sys_exit` / `@sys_argv` / `@sys_argc`
    - 兼容 legacy `@sa_print_bytes`，`demos/rosetta/01_hello_world/main.sa` 已可在 `sa run` 下真实打印
    - 新增 `demos/support/sys_runtime_probe.sa`，覆盖 `sa run` 下的 argv、文件读写、打印与退出路径
    - _Requirements: R16.1, R17.1–R17.5_

  - [x] 9.3 气闸舱语义（Interp 模式）
    - `demos/support/airlock_probe.sa` 在 `sa run` 下验证 `assume_safe` / `assume_borrow` 保持指针值不变，并由 `tests/cli_smoke.zig` 覆盖 native `build-exe` 真实运行
    - `assume_*` 只更新 mask，不做实际指针操作
    - _Requirements: R13.2, R13.3_

  - [x] 9.4 插件 ABI bridge
    - `sa run` 已可通过 `@extern` 直接调用 `sa_http_client_*` / `sa_http_server_*`
    - 解释器对插件句柄增加了外部所有权标记，避免把插件返回的 handle 当普通堆指针释放
    - 仓库级 `cli_smoke.zig` 仍有少数非 HTTP 回归待清理
    - _Requirements: R16.1, R13.8_

  - [x] 9.5 `panic(code)` 打印 + 退出 128+code
    - _Requirements: R18.4_

  - [x] 9.6 Interpreter API `run(allocator, annotated, argv) !u8`
    - _Requirements: R16.1_

- [x] 10. W12 `@sys_*` 原语 + FFI 气闸舱 + panic runtime

  - [x] 10.1 Native `@sys_*` 原生 stub（`src/runtime/native_sys.zig`）
    - `src/runtime/native_sys.zig` 已实现 `sys_print` / `sys_exit` / `sys_argc` / `sys_argv` / `sys_read_file` / `sys_write_file`
    - `tests/native_sys_runtime.zig` 已覆盖静态 `.o` 构建、`zig cc` 链接、`sys_read_file` / `sys_write_file` / `sys_exit` 行为
    - _Requirements: R17.1–R17.5_

  - [x] 10.2 **v0.1 WASM 路径**：`@sys_*` 映射到 WASI import
    - `tests/cli_smoke.zig` 已验证 `sa build-wasm` 产物包含 `fd_write` / `proc_exit` / `args_get` / `args_sizes_get`
    - 通过 `zig cc -target wasm32-wasi` 自动链接 Zig 的 WASI stub
    - 不需要手写 WASI 绑定（这部分移到 v0.2）
    - _Requirements: R15.2, R15.5, R17.1–R17.5_

  - [x]* 10.3 `@sys_*` 双轨等价 PBT — **P23**
    - `tests/cli_smoke.zig` 已覆盖 `demos/rosetta/01_hello_world/main.sa` 的 `build-exe` + `build-wasm` 双轨运行，并对比 stdout / 退出码
    - _Requirements: R15.5, R17.1–R17.5_

  - [x] 10.4 `__sa_panic` 运行时符号（Native）
    - ≤ 30 行 Zig，写 stderr + `_exit(128+code)`
    - _Requirements: R18.4_

  - [x] 10.5 句柄模式 FFI 集成样例
    - `tests/integration/ffi_handle.sa`：`@extern` 分配返回 ID → 后续查表借用
    - 已补 `tests/integration/ffi_handle_demo.zig` / `tests/integration/ffi_handle/handle.sa` / `tests/integration/ffi_handle/handle_host.c`，并纳入 `zig build test`
    - _Requirements: R13.8_

  - [x] 10.6 `@export` 对外符号样例
    - 不做名称修饰
    - `tests/cli_smoke.zig` 已覆盖 `@export exported() -> i32` 的 LLVM / nm 证据
    - _Requirements: R13.6, R13.9_

  - [x] 10.7 `UnsupportedSysIntrinsic` 错误路径
    - 目标不支持某 `@sys_*` 时在 Emitter 前报错
    - `src/referee/verifier.zig` 现于 verifier 阶段对未知 `sys_*` 直接返回 `UnsupportedSysIntrinsic`
    - `tests/cli_smoke.zig` 已补未知 sys intrinsic 的 CLI 负例
    - _Requirements: R17.7_

- [x] 11. W12 `libsa_scope` helper 库

  - [x] 11.1 C-ABI 头文件 + 实现
    - 按 design §3.8 导出 `scope_new/drop/enter/exit/bind/move/release/branch_*/emit_releases`
    - 已补 `src/libsa_scope.zig` / `src/libsa_scope.h`，并通过 Zig 单测与 C-ABI demo
    - _Requirements: R20.8_

  - [x] 11.2 Demo 前端样例（`tests/integration/libsa_scope_demo/`）
    - 用 C 写一个微型前端调用 helper，验证作用域末尾自动释放
    - 已接入 `zig build test` 回归
    - _Requirements: R20.8_

- [ ] 12. 检查点 — 发射器 + CLI + sys/FFI
  - 跑过 P2、P15、P16、P21、P22、P23、P24、P25
  - Hello-Compute 端到端：`build-exe` → `.exe` 跑通；`build-wasm` → `.wasm` 在 Wasmtime 跑通
  - v0.1 WASM 体积目标 ≤ 48 KB（由 `zig cc -O ReleaseSmall` 产出，允许较大；v0.2 手写 Emitter 再压到 32 KB）

- [x] 12b. `sa layout` 布局生成工具（R7b）

  - [x] 12b.1 实现 `sa layout --name NAME --fields "field:type, ..."` 子命令
    - 解析字段列表，按对齐规则计算偏移量
    - 输出 `#def` 字典文本到 stdout
    - _Requirements: R7b.1, R7b.2, R7b.3, R7b.4_

  - [x] 12b.2 JSON 输出格式
    - `--format json` 输出结构化 JSON
    - _Requirements: R7b.5_

  - [x] 12b.3 32 位目标支持
    - `--target 32` 时 ptr 对齐为 4
    - _Requirements: R7b.8_

  - [x]* 12b.4 布局工具单元测试
    - 覆盖：纯 i32 结构、混合 i32+f64（需 padding）、全 ptr、空结构
    - _Requirements: R7b.1, R7b.2, R7b.3, R7b.4_

- [ ] 13. W13-14 LLM Pilot + Hello-Compute + AutoBevy（最低优先级）端到端

  - [ ] 13.1 AutoBevy Component Buffer + Entity + System 注册（1K 规模，最低优先级）
    - _Requirements: R21.1, R21.4_

  - [ ] 13.2 System 并行分析器（复用 CapabilityMask AND，最低优先级）
    - _Requirements: R21.2_

  - [ ]* 13.3 System 并行分析 PBT — **P20**（最低优先级）
    - _Requirements: R21.2_

  - [ ] 13.4 AutoBevy 1K 冒烟集成测试（最低优先级）
    - 1K 实体 1 帧跑通 Wasmtime
    - _Requirements: R21.3, R21.4_

  - [ ] 13.5 LLM Pilot 30 题执行脚本
    - 10 种基础用例（alloc/borrow/loop/branch/FFI/错误传播/结构体偏移/数组索引/递归/双缓冲）× 3 变种
    - 3 个 LLM（GPT-4o / Claude Opus / DeepSeek-Coder）
    - 记录首次通过 Referee 比例，归档 baseline，**不预设 KPI**
    - _Requirements: R23.3_

  - [ ] 13.6 Pilot baseline 决策点
    - 若 baseline < 50% → 触发 R23.4 讨论（是否引入伪嵌套前端）
    - 结论写入 post-MVP 路线图
    - _Requirements: R23.4_

  - [x] 13.7 Hello-Compute `.exe` + `.wasm` 端到端测试
    - `tests/cli_smoke.zig` 已覆盖 `demos/rosetta/98_build_pipeline/main.sa` 的 native `build-exe` 与 wasm `build-wasm` 端到端输出/退出码
    - _Requirements: R15.1, R15.3, R16.2, R16.3_

  - [x] 13.8 GDB/LLDB 上游行号断点验证
    - `tests/cli_smoke.zig` 以 `-g` 编译最小 `hello.sa`，并用 `gdb` 在 `hello.rs:10` 下断点实际命中
    - `_debug` 路径保留 `.debug_line`，`build-exe -g` 可在 `gdb` 中回溯到上游源文件
    - _Requirements: R19.5, R19.6_

- [ ] 14. 测试基线与 CI 门禁（v0.1）

  - [x] 14.1 13 类黄金用例集
    - 每类 ≥ 10 例：正常 / `DoubleMutableBorrow` / `UseAfterMove` / 借用期 Move / `MemoryLeak` / Phi 冲突 / 宏合法 / 宏递归 / 禁用语法 / 气闸舱违规 / FFI 借用销毁违规 / 早返回泄漏 / 原子 ordering
    - 第一批已完成 10 个最小可跑 `build-exe` 回归：`02_mutability` / `20_boxed_value` / `26_reference_return` / `27_move_semantics` / `28_borrow_chains` / `51_refcount` / `58_borrow_update` / `61_thread_pool` / `67_resource_pool` / `52_queue_rotate`
    - `tests/cli_smoke.zig` 新增 `assertBuildExeStdout`，固定验证以上 demo 均能编译并打印预期 stdout
    - 第二批已补 11 个最小可跑 `build-exe` 回归：`03_if_else` / `05_struct` / `11_tuples` / `13_array_sum` / `15_string_bytes` / `16_methods` / `18_option_map` / `24_factorial` / `25_fibonacci` / `29_const_data` / `31_trait_static_dispatch`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述核心控制流与数据类 demo 均能真实编译、运行并打印 stdout
    - 第三批已补 11 个已实测可跑 `build-exe` 回归：`12_destructuring` / `34_iterator_filter` / `35_iterator_fold` / `36_tuple_struct` / `40_impl_block_state` / `41_module_imports` / `42_export_visibility` / `45_config_merge` / `46_option_default` / `48_generic_pair` / `63_router_table`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述更多结构、导入、泛型与路由表 demo 均能真实编译、运行并打印 stdout
    - 第四批已补 10 个已实测可跑 `build-exe` 回归：`08_closures` / `10_generics_monomorph` / `17_associated_fn` / `30_manual_guard_branch` / `33_iterator_map` / `37_newtype` / `38_generic_struct_i32` / `39_generic_enum_i32` / `59_method_counter` / `60_enum_branch`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述更多闭包、泛型、关联函数、手动守卫分支、迭代器、newtype 与枚举 demo 均能真实编译、运行并打印 stdout
    - 第五批已补 10 个已实测可跑 `build-exe` 回归：`64_file_manifest` / `68_parser_tokens` / `69_serializer` / `70_integration_service` / `71_pipeline_stage` / `72_graph_walk` / `73_scene_nodes` / `74_component_store` / `77_http_route` / `78_cli_args`
    - 第六批已补 9 个已实测可跑 `build-exe` 回归：`79_metrics` / `80_workflow` / `81_kv_store` / `82_sql_scan` / `83_blob_chunk` / `84_sync_gate` / `85_scheduler_tree` / `87_protocol_frame` / `88_text_index`
    - `86_cache_eviction` 已实测可跑并纳入 `tests/cli_smoke.zig`；后续若再变更语义，以 smoke 为准重新验证
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述更多应用型、路由、序列化与工作流 demo 均能真实编译、运行并打印 stdout
    - 第七批已补 18 个已实测可跑 `build-exe` 回归：`79_metrics` / `80_workflow` / `81_kv_store` / `82_sql_scan` / `83_blob_chunk` / `84_sync_gate` / `85_scheduler_tree` / `87_protocol_frame` / `88_text_index` / `89_job_queue` / `90_app_shell` / `91_db_session` / `92_query_plan` / `93_log_aggregator` / `96_task_orchestrator` / `97_sync_service` / `98_build_pipeline` / `99_release_bundle`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述更多任务队列、应用壳、数据库会话、查询计划、日志聚合、编排、同步、构建与发布 demo 均能真实编译、运行并打印 stdout
    - 第八批已补 3 个已实测可跑 `build-exe` 回归：`94_graphql_router` / `95_repl_shell` / `100_full_app`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述查询路由、REPL 壳与完整应用 demo 均能真实编译、运行并打印 stdout
    - 第九批已补 8 个已实测可跑 `build-exe` 回归：`55_builder_pattern` / `56_state_machine` / `57_event_loop` / `62_channel_pingpong` / `65_job_scheduler` / `66_actor_mailbox` / `75_async_bridge` / `76_lockfree_counter`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述构建器、状态机、事件循环、通道、调度器、actor、异步桥与无锁计数器 demo 均能真实编译、运行并打印 stdout
    - 第十批已补 7 个已实测可跑 `build-exe` 回归：`14_slice_window` / `32_trait_object_vector` / `09_async_await` / `47_tuple_swap` / `94_graphql_router` / `95_repl_shell` / `100_full_app`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述切片窗口、trait 对象向量、异步、tuple 交换、查询路由、REPL 壳与完整应用 demo 均能真实编译、运行并打印 stdout
    - 第十一批已补 1 个已修正并实测可跑的 `build-exe` 回归：`53_cache_hits`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证缓存命中 demo 也能真实编译、运行并打印 stdout
    - 第十二批已补 3 个已修正并实测可跑的 `build-exe` 回归：`43_tagged_union` / `49_pipeline_map` / `86_cache_eviction`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述标签联合、流水线映射与缓存驱逐 demo 也能真实编译、运行并打印 stdout
    - 第十三批已补 1 个已修正并实测可跑的 `build-exe` 回归：`06_enum_and_match`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证枚举与匹配 demo 也能真实编译、运行并打印 stdout
    - 第十四批已补 2 个已修正并实测可跑的 `build-exe` 回归：`19_result_question` / `50_error_chain`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证 fallible / `?` demo 也能真实编译、运行并打印 stdout
    - 第二十批已补 2 个已修正并实测可跑的 `build-exe` 回归：`176_result_flattening` / `178_panic_hook_override`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证结果扁平化与 panic hook override demo 也能真实编译、运行并打印 stdout
    - 第十五批已补 1 个已实测可跑的 `build-exe` 回归：`44_slice_iteration`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证 slice iteration demo 也能真实编译、运行并打印 stdout
    - 第十六批已补 1 个已实测可跑的 `build-exe` 回归：`54_mem_fill`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证内存填充 demo 也能真实编译、运行并打印 stdout
    - 第十七批已补 4 个已实测可跑的 `build-exe` 回归：`01_hello_world` / `04_loop` / `07_trait_vtable` / `21_while_loop`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述基础 hello / loop / trait vtable demo 也能真实编译、运行并打印 stdout
    - 第十九批已补 2 个已实测可跑的 `build-exe` 回归：`22_break_continue` / `23_nested_loops`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述 break / nested loop demo 也能真实编译、运行并打印 stdout
    - 第十八批已补 6 个已实测可跑的 `build-exe` 回归：`29_const_data` / `31_trait_static_dispatch` / `37_newtype` / `38_generic_struct_i32` / `39_generic_enum_i32` / `40_impl_block_state`
    - `tests/cli_smoke.zig` 继续扩充 `assertBuildExeStdout`，固定验证上述基础数据、trait、newtype 与泛型 demo 也能真实编译、运行并打印 stdout
    - 第二批已补 9 个最小反例 `build-exe` 回归：`use_after_move` / `return_after_move` / `borrow_conflict` / `read_write_conflict` / `illegal_unsafe_context` / `stack_escape` / `const_mutation` / `early_return_leak` / `ffi_ownership_violation`
    - `tests/cli_smoke.zig` 新增 `assertBuildExeTrap`，固定验证上述反例均输出结构化 JSON trap
    - 新增 1 个宏合法最小回归：`macro_print`，用 `EXPAND PRINT_MSG RESULT, 9` 验证参数替换与 `@sys_print` 打印
    - 新增 1 个宏递归最小反例：`macro_recursion`，验证 `MacroRecursionLimit` 与 `trap_code:1005`
    - 新增 1 个禁用语法最小反例：`forbidden_syntax`，验证属性链 `a.b.c` 触发 `ForbiddenSyntax`
    - 新增 2 个 `MemoryLeak` 最小反例：`memory_leak_after_borrow` / `memory_leak_partial_release`，分别覆盖借用释放后泄漏与部分释放泄漏
    - 新增 1 个原子 ordering 最小反例：`atomic_ordering_mismatch`，验证同地址 RMW ordering 组合冲突触发 `AtomicOrderingMismatch`
    - 新增 1 个原子前端最小反例：`invalid_atomic_ordering`，验证 `cmpxchg` 失败 ordering 强于成功 ordering 触发 `InvalidAtomicOrdering`
    - `DoubleMutableBorrow` 先在 `src/referee/table.zig` 通过能力表单测覆盖；当前前端没有稳定的最小 `demos/` 文本形态，不为补 demo 放宽语法
    - 新增 1 个 `UnknownRegister` 变体：`unknown_register_return`，验证 `return ghost` 也能输出结构化 trap
    - 新增 5 个 `ForbiddenSyntax` 变体：`forbidden_if` / `forbidden_while` / `forbidden_for` / `forbidden_brace` / `forbidden_property_chain`
    - 新增 1 个 `CapabilityMismatch` 最小反例：`capability_mismatch`，验证调用前缀与被调契约不一致触发结构化 trap
    - 第二十一批已补 2 个已实测可跑的 `build-exe` / 链接回归：`220_pkg_lib_dynamic` / `253_contract_callback_registration`
    - `tests/cli_smoke.zig` 已固定验证 `220_pkg_lib_dynamic` 的 `build-obj` + `ar rcs` + `zig cc` 对象归档链路，以及 `253_contract_callback_registration` 的 `build-exe` 真实运行并打印 stdout
    - 第二十二批已补 5 个已实测可跑的结构化 trap 回归：`205_pkg_cyclic_dependency_reject` / `207_pkg_multiple_versions_conflict` / `226_mod_cyclic_import_detect` / `227_mod_shadowing_prevention` / `243_contract_sig_mismatch_link`
    - `tests/cli_smoke.zig` 已固定验证上述 package / module / contract 约束拒绝路径均输出结构化 JSON trap
    - 新增 `test_all_300.sh`：覆盖 1~300 demo 的 native `build-exe` 回归，并对 wasm32 目标执行 `build-wasm` + Node/WASI 运行；`220_pkg_lib_dynamic` 保留对象归档 native 特例，同时显式验证其 wasm 边界
    - _Requirements: R22.1, R22.2_

  - [ ] 14.2 CI 流水线
    - `zig build test` → Property × 25 × 100+ → 集成 15 个 → 基准回归 ±10% → 白皮书 ≤ 2000 → Referee LOC ≤ 2500 → `.wasm` ≤ 48 KB → DWARF 冒烟 → merge
    - _Requirements: R22.3, R23.1, R9.5, R9.6, R15.3, R16.6_
    - 当前仓库已落地版本化 pre-push hook：根目录 `.githooks/pre-push` 调 `zig build pre-push`，并已通过；它是更窄的前置门禁，不等同于完整 CI

  - [x]* 14.3 Trap 基线回归
    - _Requirements: R22.2, R22.3_

  - [ ] 15. v0.1 最终验收
  - 运行全部测试
  - 硬约束：Referee ≤ 2500 行 / 真实代码 ≥ 500K 行每秒 / 白皮书 ≤ 2000 行 / `.wasm` ≤ 48 KB / `.exe` ≤ 800 KB / CLI ≤ 15 MB / LLM pilot baseline 归档 / AutoBevy 1K 通过（最低优先级）
  - Stretch 全部不强求
  - 任何未通关项向用户确认

---

# Version 0.2 — 自研 WASM 后端（post-MVP，4-6 周）

目标：v0.1 已证明语义闭环，但 `zig cc` 产出的 WASM 偏大（48 KB 级别）且不可控 wasm64。v0.2 替换 WASM 产线为手写二进制 Emitter，获得体积、精度、wasm64 三项收益。Native 路径（LLVM bitcode + zig cc）保持不变。

## v0.2 任务

- [x] 16. WASM 二进制发射器基础设施

  - [x] 16.1 LEB128 变长整数编解码
    - _Requirements: R14.2_

  - [x] 16.2 WASM Section 拼装骨架（Type / Import / Function / Memory / Global / Export / Code / Data）
    - 按 WASM Core 2.0 规范
    - _Requirements: R14.2_

  - [x] 16.3 wasm32 / wasm64 双目标切换
    - CLI `--target wasm32|wasm64`
    - `i32.load/store` ↔ `i64.load/store` 切换
    - `memory` section memory64 标志位
    - 说明：CLI 已支持 `--target wasm32|wasm64`，`wasm64-freestanding -fno-entry` smoke 已覆盖；手写 memory64 section 仍随 21 切换项保留
    - _Requirements: R15.4_

- [ ] 17. WASM opcode 映射层

  - [x] 17.1 基础 opcode 映射（alloc/load/store/运算/控制流）
    - _Requirements: R14.2_

  - [ ] 17.2 原子 opcode 映射（`0xFE` 前缀 atomics proposal）
    - `i32.atomic.load` / `i32.atomic.store` / `i32.atomic.rmw.cmpxchg` / `atomic.fence`
    - _Requirements: R2.6_

  - [ ] 17.3 SIMD 最小集 opcode（`0xFD` 前缀）
    - `v128.load` / `v128.store` / `i32x4.add` / `f32x4.mul` / `i8x16.shuffle`
    - 对应 SA `add.v128` / `mul.v128` / `shuffle.v128` / `extract_lane` / `insert_lane`
    - _Requirements: R2.4, R2.5_

  - [ ] 17.4 `@sys_*` WASI import 段
    - 手写 `wasi_snapshot_preview1` 的 `fd_write` / `fd_read` / `path_open` / `proc_exit` / `args_get` / `args_sizes_get`
    - _Requirements: R15.2, R17.1–R17.5_

  - [x] 17.5 `panic(code)` → `unreachable` opcode
    - _Requirements: R18.4_

- [ ] 18. DWARF-in-WASM

  - [ ] 18.1 `.debug_info` / `.debug_line` / `.debug_abbrev` 自定义段
    - 按 DWARF 5 规范
    - 可被 `wasmtime --debug` / Chrome DevTools / `wasm-objdump` 消费
    - _Requirements: R19.4_

  - [ ] 18.2 `name` 自定义段（函数/局部变量名）
    - _Requirements: R19.4_

- [ ] 19. 体积优化

  - [x] 19.1 死代码消除（函数级）
    - 说明：`src/emit_llvm_llvmc.zig` 在 `emitLlvmcInternal` / `emitLlvmcToArtifacts` 中通过 `collectNormalBuildReachability` 计算可达函数并跳过未引用函数；`build-wasm` 与 native 均走 `emitLlvmcToFile`。`zig build bc2sa-smoke --summary all` 已通过，其中包含 `cli build-exe prunes unused imported functions before llvm emission`。
    - _Requirements: R15.3_

  - [ ] 19.2 Hello-Compute `.wasm` ≤ 32 KB（v0.2 硬约束）
    - _Requirements: R15.3_

- [ ] 20. v0.2 测试

  - [x] 20.1 WASM 产物 wasmparser / wasm-validate 通过
    - **Property 17** 升级为真正的二进制合法性检查
    - _Requirements: R14.2, R15.1–R15.4_

  - [x] 20.2 wasm64 > 4 GB 寻址样例
    - 当前验收为 wasm64 freestanding/no-entry 产物生成与导入表检查；完整 >4GB 运行时寻址仍依赖后续 memory64 手写发射切换
    - _Requirements: R15.4_

  - [ ] 20.3 Wasmtime `--debug` 断点命中上游行号
    - _Requirements: R19.4, R19.5_

- [ ] 21. v0.2 切换
  - CLI `sa build-wasm` 默认改走手写 Emitter
  - 保留 `--via-zigcc` 开关以便对比回归
  - 更新白皮书与 design 文档中的 WASM 章节

- [x] 21b. `#mode compact` 紧凑糖前处理器（R24）— **由外部 SLA 插件替代，主线不再实现**

  > **📌 2026-07-01 更新：`#mode compact` 已被外部 SLA 插件（`sa_plugin_sla`）取代。**
  > SLA 提供了完整的 Rust 风格语言前端（泛型、模式匹配、trait、枚举、闭包、完整表达式解析等），编译到 SA-ASM。
  > SA 核心主线不再实现 `#mode compact`。以下子任务全部标记为已完成（由 SLA 替代实现）。
  > 详见 `~/projects/sa_plugins/sa_plugin_sla`。

  - [x] 21b.1 ~~在 Flattener 前端新增 mode 解析阶段~~ — 由 SLA parser.zig 的完整词法/语法解析替代
  - [x] 21b.2 ~~8 条中缀形态白名单正则匹配器~~ — 由 SLA 的完整 Pratt 解析器替代（支持完整优先级和比较操作符）
  - [x] 21b.3 ~~未启用 `#mode compact` 时的严格拒绝~~ — 由 SLA 编译器自动处理，不接受 SA 中缀糖
  - [x] 21b.4 ~~Trap 报告 `original_text` 字段扩展~~ — SLA 使用自己的诊断框架
  - [x] 21b.5 ~~Property 30：紧凑糖语义等价性~~ — 由 SLA 的 lowerer 等价性保证替代
  - [x] 21b.6 ~~非法糖用例基线~~ — 由 SLA 的错误诊断替代
  - [x] 21b.7 ~~白皮书章节追加~~ — SLA 有自己的独立文档 `~/projects/sa_plugins/sa_plugin_sla/README.md`

---

# Version 0.3 — 性能兑现（post-MVP，6-8 周）

目标：v0.1/v0.2 证明了功能完备性，v0.3 把性能承诺逐一兑现。

## v0.3 任务

- [ ] 22. SIMD 路径全面启用
  - 前端层支持 `v128` 字面量与 lane 操作
  - LLVM bitcode Emitter 完整映射
  - _Requirements: R2.4, R2.5_

- [ ] 23. AutoBevy 1M 性能追 Bevy ±30%（最低优先级）
  - 并行调度器接真实线程池
  - 缓存布局调优
  - SIMD 批量更新
  - 基准对比 Rust/Bevy 同等 Demo
  - _Requirements: R21.5_

- [ ] 24. Referee 性能 stretch 目标
  - 真实代码吞吐 ≥ 1M 行/秒
  - Referee LOC 压缩 ≤ 1500（抽取重复模式 + 表驱动）
  - Flattener + Referee 1M 行 ≤ 100 ms
  - _Requirements: R9.5, R9.6_

- [ ] 25. 产物体积 stretch
  - `.exe` ≤ 500 KB（LTO + 自定义 panic handler + strip）
  - CLI ≤ 10 MB
  - _Requirements: R16.6_

- [ ] 26. LLM 微调路线
  - 根据 v0.1 pilot baseline 结果决策：
    - 若 baseline ≥ 70% → 仅优化白皮书
    - 若 50% ≤ baseline < 70% → prompt engineering + few-shot 样例库
    - 若 baseline < 50% → R23.4 讨论的"伪嵌套前端"方案落地
  - _Requirements: R23.3, R23.4_

- [x] 27. Rust std 防波堤 demo 完善
  - `cargo build --release` 产 `.a`
  - `zig cc main.o libstd_bridge.a -o demo.exe`
  - 样例覆盖：文件 / 网络 / 线程 / JSON 解析
  - _Requirements: R13.9_

- [ ] 28. VTable 签名静态校验（R25）

  - [ ] 28.1 Referee 在 `@const ... = vtable { slot = @func }` 声明时记录每个槽位的完整签名 tuple
    - _Requirements: R25.1_

  - [ ] 28.2 `call_indirect` 编译期参数 tuple 比对
    - 比对调用点参数 `(cap_prefix, ty)[]` 与 VTable 槽位声明的 tuple
    - 不匹配 → `Trap: VTableSignatureMismatch`
    - _Requirements: R25.2, R25.3_

  - [ ]* 28.3 VTable 签名校验 Property 测试 — **P31 (NEW)**
    - 合法生成器：随机 VTable + 匹配调用点，断言通过
    - 注入式生成器：参数数量/类型不匹配，断言必 Trap
    - 最少 100 次
    - _Requirements: R25.2, R25.3_

  - [ ] 28.4 FFI VTable 豁免
    - 外部传入的裸指针 VTable 不做签名校验（Referee 无法获知外部签名）
    - _Requirements: R25.4_

- [x] 29. `libsa_async` 异步状态机宏模板（R26）

  - [x] 29.1 编写 `libsa_async.sa` 宏文件
    - 包含 `ASYNC_CTX_DEF` / `ASYNC_STATE_BEGIN` / `ASYNC_STATE_END` / `ASYNC_POLL_PROLOGUE` / `ASYNC_AWAIT_POINT` / `ASYNC_AWAIT_POINT_FINAL` / `ASYNC_RETURN_PENDING` / `ASYNC_READY` / `ASYNC_INVALID_STATE` 等标准宏
    - 其中前者覆盖状态机骨架与恢复入口，后者覆盖最终收尾与非法状态处理
    - _Requirements: R26.1, R26.3_

  - [x] 29.2 Flattener 文件拼接机制（`@import "libsa_async.sars"`）
    - 在预处理阶段把外部 `.sa` 文件内容原样插入当前源码
    - _Requirements: R26.4_

  - [x] 29.3 用 `libsa_async` 重写案例 23 的 demo
    - 验证展开后与手写等价
    - _Requirements: R26.2, R26.5_

  - [x] 29.4 宏展开等价性 Property 测试 — **P32 (NEW)**
    - 对比手写 120 行 SA 与 `EXPAND ASYNC_AWAIT_POINT ...` / `EXPAND ASYNC_AWAIT_POINT_FINAL ...` 展开后的 `Instruction[]`
    - 断言字段级相等
    - 最少 100 次
    - _Requirements: R26.2_

- [ ] 30. 发射产物诊断级别（R27）

  - [ ] 30.1 `--release` 模式确认零运行时开销
    - 验证产物中不含 gas 计数器、不含 sanitizer 簿记
    - _Requirements: R27.1_

  - [ ] 30.2 `--debug-gas` 模式实现
    - 在每个函数入口/基本块头部插入 gas 计数器自增
    - 超限触发 `Trap: GasExceeded`，命名与层级以 `docs/errorcode.md` 为准
    - _Requirements: R27.2_

  - [ ] 30.3 `--debug-san` 模式实现
    - 在 `alloc` / `!free` 点插入红黑树/哈希表簿记
    - 运行期侦测 UAF / Double-Free
    - 输出结构化 JSON 报告（字段口径见 `docs/errorcode.md`，含 `upstream_loc`）
    - _Requirements: R27.3, R27.4_

  - [x] 30.4 白皮书"构建模式"章节
    - 说明：`docs/whitepaper.md` / `docs/whitepaper.txt` 已新增 Build Modes 小节，明确 `--release` 无 Referee runtime、`-g` / `--no-debug` 调试元数据边界，以及 `--debug-gas` / `--debug-san` 的安全保障和性能代价；`docs/demos/rust-to-sa.md` 另有三种构建模式对比表。
    - 明确三种模式的安全保障边界与性能代价
    - _Requirements: R27.6_

---

# Version 0.4 — 并行开发基建（post-v0.3，4-6 周）

目标：让 SA 从"单人极客工具"进化为"多人/多 LLM 并行协作的工业级基建"。核心能力：接口契约、版本化布局、函数粒度增量编译。

## v0.4 任务

- [x] 31. 接口契约文件 `.sai`（R28）

  - [x] 31.1 定义 `.sai` 文件格式
    - 仅包含 `@extern` 签名声明（含 cap_prefix + ty + 返回类型 + `!` 后缀）
    - 不包含函数体、不包含 `#def`、不包含 `@const`
    - _Requirements: R28.1_

  - [x] 31.2 Flattener 支持 `@import "module.sai"`
    - 将接口文件中的 `@extern` 声明注入当前编译单元
    - 支持相对路径与绝对路径
    - _Requirements: R28.2_

  - [x] 31.3 Referee 基于接口签名做调用点校验
    - 无需实际函数体存在即可校验 `CapabilityMismatch`
    - _Requirements: R28.3_

  - [x] 31.4 链接期签名一致性检查
    - 接口声明与实现的签名不一致时 `zig cc` 报 symbol type mismatch
    - _Requirements: R28.4_

  - [x] 31.5 并行编译验证
    - 多个 `.sa` 文件引用同一 `.sai`，各自独立编译，最后链接
    - 验证结果与串行编译等价
    - _Requirements: R28.5_

  - [x] 31.6 CI 依赖检测
    - 接口文件修改时自动标记依赖方需重新验证（文件哈希比对）
    - _Requirements: R28.6_

- [ ] 32. 版本化布局文件 `.sal`（R29）

  - [x] 32.1 定义 `.sal` 文件格式
    - `#version N` 元数据行 + `#def` 常量声明
    - _Requirements: R29.1, R29.6_

  - [x] 32.2 Flattener 支持 `@import "entity.sal"`
    - 记录引用的 `#version` 值
    - _Requirements: R29.2_

  - [ ] 32.3 版本冲突检测
    - 两个 `.sa` 引用同一布局文件的不同版本 → 链接期 `Trap: LayoutVersionConflict`
    - 通过在 `.o` 文件中嵌入版本元数据实现
    - _Requirements: R29.4_

  - [ ] 32.4 CI 版本递增检查
    - 布局文件内容变更但 `#version` 未递增 → 警告阻断 merge
    - _Requirements: R29.5_

  - [ ] 32.5 版本变更影响扫描
    - `#version` 递增时自动列出所有引用方
    - _Requirements: R29.3_

- [ ] 33. 函数粒度增量编译（R30）

  - [x] 33.1 `--incremental` 模式骨架
    - 按函数粒度产出独立 `.o`（每个函数一个）
    - _Requirements: R30.1_

  - [x] 33.2 函数体哈希比对与缓存复用
    - 未修改的函数跳过 Emitter + zig cc，复用 `.sa-cache/` 中的 `.o`
    - _Requirements: R30.2_

  - [x] 33.3 增量链接
    - 所有函数 `.o` 合并为单一产物
    - 验证与非增量模式产物行为等价
    - _Requirements: R30.3_

  - [x] 33.4 缓存目录结构
    - `.sa_cache/build-obj-incremental/<project_hash>/functions/<function_hash>.o` + `manifest.json`
    - _Requirements: R30.5_

  - [ ] 33.5 增量 + sanitizer 兼容
    - `--incremental --debug-san` 时每个函数 `.o` 独立包含 sanitizer 入口
    - _Requirements: R30.6_

- [ ] 34. 多 LLM 并行生成验证

  - [ ] 34.1 设计"N 个 LLM 实例并行生成 N 个函数"的测试协议
    - 每个 LLM 实例只看到 `.sai` + `.sal`，独立生成一个函数
    - 最后链接，验证 Referee 通过 + 运行正确
    - _Requirements: R28.5, R30.4_

  - [ ] 34.2 冲突检测集成测试
    - 两个 LLM 生成同名函数 → 链接器报 duplicate symbol
    - 签名不匹配 → Referee 报 `CapabilityMismatch`
    - 布局版本不一致 → `LayoutVersionConflict`
    - _Requirements: R28.4, R29.4_

---

# Version 0.5 — 生态基建 + 标准库（post-v0.4，6-8 周）

目标：让 SA 从"能跑通"进化为"LLM 能独立完成完整应用"。核心能力：包管理、标准库、布局标签校验。

## v0.5 任务

- [ ] 35. 零信任包管理 `sa.mod` / `sa.lock` / `sa.sum`（R31, R31a–R31g）

  > 完整设计文档：[`docs/package_management.md`](../../../docs/package_management.md)；架构对接：design.md §3.10 / §4.8。

- [x] 35.1 定义 `sa.mod` 文件格式与解析器（`src/pkg/manifest.zig`）
    - 单行扁平 `require <URL> @<ref> sha256:<hash> [grants [...]]`
    - 解析为 `RequireEntry` 结构体（design §4.8）
    - 缺省 grants = `&.{}`（绝对零权限），禁止 nil / magic
    - _Requirements: R31.1_

  - [ ] 35.2 CLI `sa fetch` 哑下载
    - 默认拉到 `./sa_vendor/<URL>/`
    - `-g` 拉到 `~/.sa/pkg/<URL>@<ref>/` 只读
    - 仅 HTTP/Git 文本下载，**不**执行任何 hooks / build / postinstall
    - _Requirements: R31.2, R31a.1, R31a.2, R31b.1_

  - [x] 35.3 `@import` 解析短路（`src/pkg/resolver.zig`）
    - 顺序：`./sa_vendor/<URL>/` → `~/.sa/pkg/<URL>@<ref>/` → `Trap: PackageNotResolved`
    - 命中全局缓存时通过 `mmap` 只读读取
    - _Requirements: R31a.3, R31a.4_

  - [x] 35.4 依赖接口与布局自动注入
    - 依赖包的 `.sai` 自动 `@import` 到当前编译单元
    - 依赖包的 `.sal` `#def` 自动注入，带 `pkg_url.FIELD_NAME` 命名空间前缀
    - _Requirements: R31.3, R31.4_

  - [ ] 35.5 重复导出 / 版本冲突 / 预编译产物拒绝
    - 两个依赖包同名 `@export` → 链接期 `Trap: DuplicateExportSymbol`
    - 同一包两个版本被间接依赖 → CLI 报错要求显式选择
    - 拉取目录含 `.so/.dll/.dylib/.a/.lib/.whl/.node` → `Trap: PrecompiledArtifactRejected`
    - _Requirements: R31.5, R31.7, R31b.4_

  - [x] 35.6 源码 SHA-256 双轨核验
    - 拉取后立刻字节级哈希
    - 与 `sa.mod` 中 `sha256:` 比对，差一比特 → `Trap: UpstreamShaMismatch`
    - _Requirements: R31.6, R31g.3_

  - [x] 35.7 `sa.sum` 全树拍平
    - 自动生成全部传递依赖的哈希记录
    - 任何子树字节变化 → 顶层哈希失配，整棵树物理熔断
    - _Requirements: R31.8, R31b.5_

- [x] 35a. AST X 光扫描与安全信用评分（R31d）

  - [x] 35a.1 实现 `src/pkg/audit.zig`
    - 单遍线性 token 扫描，搜剿 `@sys_*` 调用
    - 单包 ≤ 50ms（MVP）/ ≤ 20ms（stretch）
    - _Requirements: R31d.1_

  - [x] 35a.2 Trust Score 计算（0–100）
    - 100 = pure compute；80 = mem；50 = io；20 及以下 = net / 跨核心
    - _Requirements: R31d.2_

  - [x] 35a.3 报告输出（stdout 文本 + `--format json`）
    - 含等级、权限列表、`upstream_loc`、修复建议
    - _Requirements: R31d.3, R31d.5_

  - [x] 35a.4 `sa audit <URL>` CLI 命令
    - 重新跑扫描，打印同样格式
    - _Requirements: R31d.4_

  - [x]* 35a.5 Audit Score Property 测试 — **P33 (NEW)**
    - 合成三类包（pure / io / net），断言信用分等级与权限列表精确
    - 最少 100 次
    - _Requirements: R31d.2_

- [ ] 35b. 模块级零权限沙箱与 grants 校验（R31c）

  - [x] 35b.1 实现"包路径反推"
    - 从源码物理路径（`sa_vendor/<URL>/...`）反推所属包
    - 与 `sa.mod` 的 `RequireEntry.grants` 精确匹配
    - _Requirements: R31c.3_

  - [x] 35b.2 `Trap: UnauthorizedPrimitive` 发射
    - 包内 `@sys_*` 不在 `grants` 列表 → 拒绝生成机器码
    - 错误中精确点出越权原语名 + `upstream_loc` + 当前 grants 列表
    - _Requirements: R31c.1, R31c.2, R31c.4_

  - [ ] 35b.3 跨包能力提升拦截
    - 零权限包 A 调用高权限包 B → `Trap: NonTransitivePrimitive`
    - 在控制流分析阶段实施，不依赖 Referee CapabilityMask
    - _Requirements: R31c.5_

  - [x]* 35b.4 grants 静态校验 PBT — **P33（同上，复用）**
    - 说明：外部插件 `/home/vscode/projects/sa_plugins/sa_plugin_pkg/src/pkg/audit.zig` 的 `P33 audit score property covers synthesized pure io and net packages` 以 100 组合成 pure/io/net 包，断言 grants、primitive capability、granted/ungranted 与风险等级；`zig build test --summary all` 已在插件工程通过。
    - _Requirements: R31c.1, R31c.2, R31c.4_

- [ ] 35c. 破窗确权审判台（R31e）

  - [x] 35c.1 `BLOCKED_RISK` 内存态机
    - 编译器扫到信用分 ≤ 20 + 越权原语 → 阻塞管线
    - 状态**仅存进程内存**，进程退出蒸发
    - _Requirements: R31e.1, R31e.6_

  - [x] 35c.2 审判台 banner 输出
    - 醒目标题 + 完整权限列表（带 `upstream_loc`）+ 信用分 + 提示输入完整 URL
    - _Requirements: R31e.2_

  - [x] 35c.3 完整 URL 字符串校验
    - 不接受 `y`/`n`/简写、不接受任何前缀或裁剪
    - _Requirements: R31e.3_

  - [x] 35c.4 TTY 探测与 `MissingTtyForConfirmation`
    - `std.os.isatty(stdin) == false` → 立刻退出
    - 防御 `yes |` 管道绕过
    - _Requirements: R31e.4_

  - [x] 35c.5 拒绝 `--yes` / `--auto-approve` 在 TTY 模式下绕过
    - _Requirements: R31e.7_

  - [ ]* 35c.6 零状态生命周期 PBT — **P35 (NEW)**
    - 验证编译进程退出后状态彻底蒸发
    - 验证审判台**不**修改任何文件（`sa.mod` / `sa.lock` / 全局 / 本地配置）
    - _Requirements: R31e.5, R31e.6_

- [ ] 35d. 指令级哈希钉版与项目级孤岛（R31f）

  - [x] 35d.1 机器码 SHA-256 计算与 `sa.lock` 写入（`src/pkg/lock.zig`）
    - 审判通过后单独编译该依赖，对生成的机器码字节流计算 SHA
    - 写入项目根的 `sa.lock`，结构按 design §4.8 `LockEntry`
    - _Requirements: R31f.1, R31f.2_

  - [ ] 35d.2 增量哈希命中跳过审判
    - 重新生成机器码，与 `sa.lock` 比对一致 → 直接放行（AOT 红利）
    - 不一致 → `Trap: MachineCodeHashMismatch` + 重弹审判台
    - _Requirements: R31f.3_

  - [x] 35d.3 项目级孤岛强制
    - `sa.lock` 必须位于项目根；解析器拒绝其它路径
    - `.sa_cache/` 仅本项目可访问；禁止跨项目复用
    - _Requirements: R31f.4, R31f.5, R31f.6_

  - [x] 35d.4 `sa audit --update-lock` 子命令
    - **唯一**允许写 `sa.lock` 的命令；显式动作
    - _Requirements: R31f.2_

  - [ ] 35d.5 全平台交叉编译 `sa build --all-targets --lock-only`
    - 同时推导 `x86_64-linux-musl` / `x86_64-windows-gnu` / `aarch64-macos` / `wasm32-wasi` 机器码哈希
    - `LockEntry.approved_machine_code_hashes` 多键存储
    - _Requirements: R31f.7_

  - [ ]* 35d.6 项目级孤岛 PBT — **P36 (NEW)**
    - 模拟同机器两个项目共依赖同一高危包，断言审判台各自触发
    - 断言 `~/.sa/pkg/` 不出现 `approved_machine_code_hash`
    - 最少 100 次
    - _Requirements: R31f.4, R31f.6_

  - [ ]* 35d.7 双轨独立性 PBT — **P34 (NEW)**
    - 源码 SHA 一致但机器码变 → 仍熔断
    - 最少 100 次
    - _Requirements: R31.6, R31f.3_

- [ ] 35e. CI/CD 双轨执行与内网/断网模式（R31g）

  - [x] 35e.1 CI 模式自动探测（`src/pkg/ci.zig`）
    - 信号：`CI=true` / `GITHUB_ACTIONS=true` / `isatty=false` / `--ci`
    - _Requirements: R31g.1_

  - [x] 35e.2 双轨核验
    - 第一轨：`@sys_*` 在 `grants` 列表？否 → `UnauthorizedPrimitive`
    - 第二轨：源码 SHA == `sa.mod`？否 → `UpstreamShaMismatch`
    - _Requirements: R31g.3_

  - [x] 35e.3 冷酷熔断 vs 染色放行
    - 默认：发现未审计高危依赖 → 退出码 1
    - `--allow-unaudited-risks`：染色路径，写入 `TAINTED_UNAUDITED_CODE` 元数据 + Job Summary 看板
    - _Requirements: R31g.2_

  - [ ] 35e.4 染色产物运行时警告
    - Referee runtime 探测元数据 → `main()` 入口前 stderr 强行打印三行红字
    - 无法被 `--release` 移除
    - _Requirements: R31g.7_

  - [x] 35e.5 `sa build --offline` 完全断网
    - 关闭网络模块，仅读 `sa_vendor/`
    - 与 `sa.lock` / `sa.sum` 物理比对
    - _Requirements: R31g.4_

  - [x] 35e.6 URL 镜像劫持（`src/pkg/mirror.zig`）
    - 来源 1：`SA_MIRROR_<HOST_UPPER>` 进程级环境变量
    - 来源 2：项目本地 `.sa_env` 或 `sa.mod` 的 `[mirrors]` 块
    - 严禁全局配置文件
    - _Requirements: R31g.5_

  - [x] 35e.7 `Trap: ForbiddenGlobalConfig`
    - 探测 `~/.sa/config.toml` / `~/.sa/mirror.toml` / `/etc/sa/*.toml` 等 → 拒绝启动
    - _Requirements: R31g.6_

  - [ ] 35e.8 全平台 CI 矩阵核验
    - Ubuntu / Windows / macOS Runner 各自算源码 SHA → 与 `sa.mod` 对齐
    - _Requirements: R31g.8_

  - [ ]* 35e.9 CI 模式探测 PBT — **P37 (NEW)**
    - 验证四种信号的非空交集子集均触发 CI 模式
    - 验证 CI 模式下任何 stdin 输入被拒绝
    - 最少 100 次
    - _Requirements: R31g.1, R31g.2, R31e.4_

- [ ] 35f. 包管理集成测试基线（design.md §8.5 第 16–27 条）

  - [x] 35f.1 PkgMgr-Fetch-Smoke：基础下载 + 哈希一致 + 不执行源码
  - [x] 35f.2 PkgMgr-Audit-Score：信用分 100/50/12 三档断言
  - [x] 35f.3 PkgMgr-Confirm-Tty：伪 TTY 输入完整 URL 通过
  - [x] 35f.4 PkgMgr-Confirm-NonTty：管道流必报 `MissingTtyForConfirmation`
  - [ ] 35f.5 PkgMgr-Lock-Idempotency：第二次跳审判 + 改源码重弹
  - [x] 35f.6 PkgMgr-Sum-Transitive：A→B→C 篡改检测
  - [x] 35f.7 PkgMgr-Offline-Build：拷贝 `sa_vendor/` + `sa.mod` + `sa.lock` 到断网容器
  - [x] 35f.8 PkgMgr-CI-DualTrack：模拟 GitHub Actions 双轨触发
  - [ ] 35f.9 PkgMgr-Tainted-Artifact：染色路径产物元数据 + 运行时红字
  - [x] 35f.10 PkgMgr-ForbiddenGlobal：放假全局配置触发 `ForbiddenGlobalConfig`
  - [x] 35f.11 PkgMgr-Mirror-Env：环境变量重定向到内网镜像，进程结束规则消失
  - [x] 35f.12 PkgMgr-PrecompiledRejected：注入 `.so/.dll` 触发 `PrecompiledArtifactRejected`
    - _Requirements: R31, R31a–R31g（全部）_

- [ ] 36. 布局标签校验（R32）

  - [ ] 36.1 `#tag NAME = UNIQUE_ID` 声明
    - Flattener 记录标签为编译期常量
    - _Requirements: R32.1_

  - [ ] 36.2 `alloc N tag NAME` 语法
    - Referee 在寄存器元数据中记录布局标签
    - _Requirements: R32.2_

  - [ ] 36.3 函数签名 `tag NAME` 注解
    - `@func(^d: ptr tag Dog)` 声明期望标签
    - _Requirements: R32.3_

  - [ ] 36.4 调用点标签比对
    - 实参标签与形参标签不匹配 → `Trap: TagMismatch`
    - 无标签寄存器可传给任何函数（向后兼容）
    - _Requirements: R32.4, R32.5_

  - [ ] 36.5 `--no-tag-check` 开关
    - 禁用标签校验（性能敏感场景）
    - _Requirements: R32.7_

  - [ ]* 36.6 标签校验 Property 测试 — **P33 (NEW)**
    - 合法生成器：匹配标签调用，断言通过
    - 注入式：不匹配标签，断言 `TagMismatch`
    - 无标签寄存器传给有标签参数，断言通过
    - 最少 100 次
    - _Requirements: R32.4, R32.5_

- [x] 37. `sa_std` 标准库 v0.1

  - [x] 37.0 SA-facing Zig-backed std facade
    - `sa_std/{io,fs,net,fmt}.sa` 作为只含 `@import` 的模块入口
    - `sa_std/{io,fs,net,fmt}.sai` 声明 Zig-backed `@extern` API
    - `sa_std/{io,fs,net,fmt}.sal` 声明显式布局、错误码和 flag 常量
    - 句柄/缓冲区全部显式传递，并要求调用方显式 `close` / `free` / `flush`
    - 保留 `sa_print_bytes` demo 兼容入口

  - [x] 37.1 `sa_std/string.sa`：字符串操作宏
    - `STR_LEN` / `STR_CONCAT` / `STR_EQ` / `STR_SLICE`
    - 基于胖指针 `[data_ptr | len]` 布局

  - [x] 37.2 `sa_std/vec.sa`：动态数组宏
    - `VEC_NEW` / `VEC_PUSH` / `VEC_GET` / `VEC_LEN` / `VEC_FREE`
    - 基于 `[data_ptr | len | cap]` 布局 + `alloc` 扩容

  - [x] 37.3 `sa_std/hashmap.sa`：哈希表宏
    - 开放寻址法 + FNV-1a 哈希
    - `MAP_NEW` / `MAP_PUT` / `MAP_GET` / `MAP_DEL` / `MAP_FREE`

  - [x] 37.3a `sa_std/hashset.sa`：哈希集合宏
    - 基于现有 `sa_std/hashmap.sa` 封装，值使用非零哨兵
    - `SET_NEW` / `SET_INSERT` / `SET_CONTAINS` / `SET_REMOVE` / `SET_FREE`

  - [x] 37.3b `sa_std/collections/hashset.sa`：集合命名空间入口
    - 仅透出 `../hashset.sa` 作为薄包装

  - [x] 37.4 `sa_std/sort.sa`：排序宏
    - 快速排序（`[MACRO] QSORT %arr, %len, %elem_size, %cmp_fn`）

  - [x] 37.5 `sa_std/io.sa`：IO 便利宏
    - `PRINTLN` / `READ_LINE` / `FORMAT_INT`（基于 `@sys_print` + `@sys_read_file`）

  - [x] 37.6 打包为 `sa_std` 包
    - 创建 `sa_std/sa.pkg` + `sa_std/*.sai`
    - 发布到本地 registry

  - [x] 37.7 `sa_std/time.sa`：时间/日期便利宏
    - `TIME_NOW_NS` / `TIME_NOW_UNIX_S` / `TIME_NOW_UNIX_MS` / `TIME_NOW_UNIX_NS`
    - `TIME_UTC_NOW` / `TIME_SLEEP_MS` / `TIME_SLEEP_NS` / `TIME_DURATION_*`
    - 直连 Zig-backed monotonic / system / UTC calendar ABI

  - [x] 37.8 `sa_std/sync/mutex.sa`：互斥锁宏
    - `MUTEX_NEW` / `MUTEX_LOCK` / `MUTEX_UNLOCK`
    - 基于 `atomic_rmw_xchg` + `sa_time_sleep_ns` 的自旋等待与 release 解锁

  - [x] 37.9 `sa_std/sync/once.sa`：单次初始化宏
    - `ONCE_NEW` / `ONCE_IS_READY` / `ONCE_TRY_CLAIM` / `ONCE_WAIT_READY` / `ONCE_PUBLISH` / `ONCE_GET` / `ONCE_GET_OR_INIT`
    - 基于 `atomic_load` + `cmpxchg` + `sa_time_sleep_ns` 的 OnceCell 懒加载与竞态收敛

  - [x] 37.10 `sa_std/sync/mpsc.sa`：多生产者单消费者通道宏
    - `MPSC_NEW` / `MPSC_FREE` / `MPSC_TRY_SEND` / `MPSC_SEND` / `MPSC_TRY_RECV` / `MPSC_RECV`
    - 基于内联环形缓冲区、原子 head/tail 指针和 slot ready 标志的 bounded MPSC 队列

---

# Version 0.6 — 高可靠性认证（post-v0.5，8-12 周）

目标：让 SA 的 Referee 获得数学可证明的正确性保证，满足 DO-178C Level A / MISRA / 审计要求。

## v0.6 任务

- [ ] 38. Referee 形式化规范（R33）

  - [ ] 38.1 提取 Referee 核心状态机为独立的纯函数规范
    - 从 `src/referee/` 中提取 CapabilityMask 转移逻辑为无副作用的纯函数
    - 产出 `formal/referee_spec.lean` 或 `formal/referee_spec.v`（Coq）
    - _Requirements: R33.1_

  - [ ] 38.2 证明健全性（Soundness）
    - 定理：若 Referee 放行指令流 I，则 I 在任何执行路径上不发生 UAF / Double-Free / Memory Leak
    - _Requirements: R33.2_

  - [ ] 38.3 证明完备性（Completeness）
    - 定理：若指令流 I 在所有路径上内存安全，则 Referee 不误报 Trap
    - _Requirements: R33.2_

  - [ ] 38.4 证明终止性（Termination）
    - 定理：对任意有限长度指令流，Referee 在有限步内产出结果
    - _Requirements: R33.2_

  - [ ] 38.5 CI 集成：形式化规范与 Zig 实现同步
    - Referee 代码修改时 CI 要求重新验证 Lean4/Coq 证明
    - _Requirements: R33.4_

- [ ] 39. Referee 硬件化探索（R33.6）

  - [ ] 39.1 将 Referee 位掩码逻辑翻译为 Verilog/VHDL
    - 目标：FPGA 上的硬件所有权检查器原型
    - _Requirements: R33.6_

  - [ ] 39.2 硬件 Referee 与软件 Referee 等价性验证
    - 对同一指令流，硬件与软件产出相同的 Pass/Trap 判决
    - _Requirements: R33.6_

---

# Version 0.7 — 原生单元测试框架（Native Unit Test Framework）

目标：实现 Safe ASM 的原生单元测试支持，提供类似 `cargo test` 的体验，彻底替代基于 Bash/Zig 的外部集成测试调用。

## v0.7 任务

- [x] 40. 编译器前端与测试收集
  - [x] 40.1 支持 `@test "name"()` 声明，含 `ignored` / `should_panic` 修饰符
  - [x] 40.2 验证测试函数签名无参无返（`TestFuncSignatureMismatch`）
  - [x] 40.3 在 Flattener/Verifier 阶段收集测试元数据至 `TestRegistry`（`test_meta.TestList`）

- [x] 41. CLI 与 Test Runner
  - [x] 41.1 扩展 `src/cli.zig` 支持 `sa test`
  - [x] 41.2 支持 `--filter` / `--skip` / `--exact` / `--ignored` / `--include-ignored` 过滤测试
  - [x] 41.3 动态生成测试 harness，使用 `SA_TEST_NAME` 选择目标测试并由子进程隔离执行
  - [x] 41.4 控制台进度打印、隔离进程运行、退出状态判断（含 `should_panic` / signal / launch failure）
  - [x] 41.5 增强诊断工作流：`sa test --list` 可按现有选择器列出测试名、标记与源码位置；`sa test --compile-only` 完成测试模式编译/链接后退出不运行子进程，便于先定位构建问题
    - 说明：2026-06-05 已在 `src/test_formatter.zig` / `src/cli.zig` 增加列表与只编译路径，并由 `tests/cli_smoke.zig` 覆盖筛选列表、失败用例 compile-only 不执行。
  - [x] 41.6 增强运行期 panic 诊断：失败报告补充测试源码位置、解析出的 panic code，并支持 `--trace-panic` / `--test-debug` 在失败时输出 opt-in 标量调试记录
    - 说明：2026-06-05 `src/test_executor.zig` / `src/test_result.zig` / `src/cli.zig` 已接通该诊断路径，`SA_TEST_TRACE_PANIC=1` 传递给测试子进程。

- [x] 42. 标准库断言与支持
  - [x] 42.1 增强 `ASSERT_EQ` / `ASSERT_TRUE`：新增 `ASSERT_*_MSG` 诊断宏，支持带文件名、行号及具体 diff 的 `panic_msg`
    - 说明：2026-06-05 `src/test_result.zig` 会识别 `expected ... got ...` 与 `expected=... actual=...` panic 文本，在原始 stderr 前输出稳定的 `assertion failed` / `expected` / `actual` 字段，降低复杂 Safe ASM 测试失败定位成本。
    - 说明：2026-06-05 新增 `sa_std/testing/assert.sai`，提供 `sa_assert_eq_i64(actual, expected, code)` 和 `sa_test_debug_i64(name, len, value)`；失败时输出可解析的 actual/expected，并可在 `--trace-panic` 下打印最近记录的标量。
  - [x] 42.2 提供基础的 Mock 机制（如内存 I/O 缓冲）：新增 `sa_std/testing/mock_io.sal` / `.sa`，提供可 rewind 的内存读写缓冲，并由 `sa test` 回归覆盖写入截断、读取游标和 len/pos 查询

- [ ] 43. 测试用例迁移
  - [ ] 43.1 逐步将 `test_all_300.sh` 中的 demo 转化为原生 `@test` 并用 `sa test` 验证（已有 `tests/unit_framework/feature_suite.sa` 代表性基线；已新增二十八批 demo-derived 覆盖：`04_loop` / `21_while_loop` / `24_factorial` / `25_fibonacci` / `35_iterator_fold`，`10_generics_monomorph` / `18_option_map` / `46_option_default` / `177_unwrap_unwrap_err`，`07_trait_vtable` / `11_tuples` / `12_destructuring` / `13_array_sum` / `14_slice_window` / `17_associated_fn` / `59_method_counter`，`08_closures` / `30_manual_guard_branch` / `33_iterator_map` / `34_iterator_filter` / `40_impl_block_state` / `42_export_visibility` / `45_config_merge` / `60_enum_branch`，`37_newtype` / `38_generic_struct_i32` / `39_generic_enum_i32` / `48_generic_pair` / `63_router_table`，以及 `53_cache_hits` / `54_mem_fill` / `56_state_machine` / `68_parser_tokens` / `69_serializer` / `70_integration_service` / `71_pipeline_stage` / `72_graph_walk`，以及 `73_scene_nodes` / `74_component_store` / `79_metrics` / `80_workflow` / `82_sql_scan` / `83_blob_chunk` / `84_sync_gate` / `85_scheduler_tree` / `87_protocol_frame` / `88_text_index`，以及 `89_job_queue` / `90_app_shell` / `91_db_session` / `92_query_plan` / `93_log_aggregator` / `96_task_orchestrator` / `97_sync_service` / `98_build_pipeline` / `99_release_bundle` / `100_full_app`，以及 `101_custom_drop` / `102_raii_guard` / `103_labeled_break` / `104_if_let_chains` / `105_let_else` / `106_cell_interior_mut` / `107_refcell_dynamic_borrow` / `108_atomic_spin_lock` / `109_atomic_fetch_add` / `110_trait_super_vtable`，以及 `111_extern_c_abi` / `112_raw_pointer_arithmetic` / `113_union_ffi_types` / `114_callback_from_c` / `115_opaque_pointers` / `116_va_list_variadic` / `118_global_mutable_state` / `119_simd_intrinsics` / `120_volatile_memory_access`，以及 `121_rwlock_reader_writer` / `122_condvar_wait_notify` / `123_barrier_sync` / `124_thread_local_storage` / `125_once_cell_lazy` / `126_mpmc_channel` / `127_hazard_pointers` / `128_rcu_read_copy_update` / `129_seqlock_optimistic` / `130_park_unpark_thread`，以及 `131_waker_vtable_mechanics` / `132_pinning_and_unpin` / `133_select_macro_race` / `134_join_all_futures` / `135_async_streams` / `136_executor_task_queue` / `137_io_uring_submission` / `138_epoll_kqueue_event` / `139_cancellation_safety` / `140_yield_now_suspend`，以及 `141_dynamically_sized_types` / `142_zero_sized_types` / `143_never_type_diverge` / `144_phantom_data_marker` / `145_opaque_type_alias` / `146_never_type_fallback` / `147_custom_dst_pointers` / `148_transparent_repr` / `149_packed_repr` / `150_c_repr_alignment`，以及 `151_global_alloc_trait` / `152_memory_layout_struct` / `153_box_into_raw` / `154_box_from_raw` / `155_arena_allocator_bump` / `156_slab_allocator_freelist` / `157_aligned_alloc_simd` / `158_custom_dst_alloc` / `159_mem_forget_leak` / `160_manually_drop_union`，以及 `161_generic_associated_types` / `162_auto_traits_send_sync` / `163_object_safety_rules` / `164_trait_upcasting` / `165_blanket_impl_resolution` / `166_specialization_fallback` / `167_const_generics_expansion` / `168_type_alias_impl_trait` / `169_negative_impls` / `170_marker_traits`，以及 `171_anyhow_dynamic_error` / `172_eyre_color_eyre` / `173_catch_unwind_panic` / `174_backtrace_capture` / `175_thiserror_macro_derive` / `176_result_flattening` / `178_panic_hook_override` / `179_assert_macro_expansion` / `180_try_trait_v2`，以及 `181_file_descriptor_raii` / `182_mmap_memory_mapping` / `183_signal_handling_setup` / `184_pthread_spawn_join` / `185_dynamic_lib_dlopen` / `186_sqlite_c_api_binding` / `187_opengl_context_swap` / `188_websocket_frame_parse` / `189_protobuf_varint_decode` / `190_base64_encode_simd`，以及 `191_macro_rules_ast_emit` / `192_proc_macro_derive_ast` / `193_attribute_macro_rewrite` / `194_cfg_conditional_compilation` / `195_build_script_codegen` / `196_lto_link_time_opt` / `197_profile_guided_opt` / `198_control_flow_guard_cfi` / `199_address_sanitizer_asan` / `200_sa_asm_quine`，以及 `201_pkg_manifest_basic` / `202_pkg_dependencies_local` / `203_pkg_dependencies_git` / `204_pkg_dependencies_registry` / `205_pkg_cyclic_dependency_reject` / `206_pkg_version_resolution` / `207_pkg_multiple_versions_conflict` / `208_pkg_dev_dependencies` / `209_pkg_build_dependencies` / `210_pkg_workspace_root`，以及 `211_pkg_workspace_inheritance` / `212_pkg_feature_flags` / `213_pkg_default_features` / `214_pkg_target_specific_deps` / `215_pkg_patch_override` / `216_pkg_profile_release` / `217_pkg_profile_debug` / `218_pkg_metadata_custom` / `219_pkg_bin_multiple` / `220_pkg_lib_dynamic`，以及 `221_mod_relative_import` / `222_mod_absolute_import` / `223_mod_visibility_private` / `224_mod_reexport_pub_use` / `225_mod_namespace_prefix` / `226_mod_cyclic_import_detect` / `227_mod_shadowing_prevention` / `228_mod_iface_separation` / `229_mod_layout_injection` / `230_mod_std_prelude`，以及 `231_mod_directory_module` / `232_mod_conditional_import` / `233_mod_alias_import` / `234_mod_unused_import_lint` / `235_mod_transitive_dependency` / `236_mod_extern_block_grouping` / `237_mod_inline_submodule` / `238_mod_path_resolution_order` / `239_mod_version_suffix_isolation` / `240_mod_entry_point_override`，以及 `241_contract_layout_stability` / `242_contract_opaque_struct` / `243_contract_sig_mismatch_link` / `244_contract_vtable_export` / `245_contract_generic_monomorph_share` / `246_contract_semver_minor_update` / `247_contract_semver_major_break` / `248_contract_ffi_boundary_trust` / `249_contract_macro_export` / `250_contract_const_export`，以及 `251_contract_resource_ownership` / `252_contract_error_code_mapping` / `253_contract_callback_registration` / `254_contract_plugin_system` / `255_contract_memory_allocator_swap` / `256_contract_panic_handler_propagate` / `257_contract_log_facade` / `258_contract_thread_local_isolation` / `259_contract_static_init_order` / `260_contract_deprecated_warning`，以及 `261_build_rs_codegen_saasm` / `262_build_bindgen_c_header` / `263_build_asset_bundling` / `264_build_env_var_injection` / `265_build_custom_linker_script` / `266_build_pre_compile_hook` / `267_build_post_compile_hook` / `268_build_cross_compile_wasm` / `269_build_cross_compile_windows` / `270_build_sysroot_custom`，以及 `271_build_optimization_passes` / `272_build_sanitizer_flags` / `273_build_test_harness` / `274_build_benchmark_runner` / `275_build_doc_generator` / `276_build_incremental_caching` / `277_build_parallel_compilation` / `278_build_reproducible_builds` / `279_build_artifact_caching_remote` / `280_build_ci_cd_integration`，以及 `281_ffi_link_system_libc` / `282_ffi_link_static_c_lib` / `283_ffi_link_dynamic_c_lib` / `284_ffi_pkg_config_integration` / `285_ffi_objective_c_framework` / `286_ffi_rust_staticlib_integration` / `287_ffi_zig_export_integration` / `288_ffi_cxx_name_mangling` / `289_ffi_opaque_handle_passing` / `290_ffi_callback_thunk`，以及 `291_eco_wasm_host_imports` / `292_eco_wasm_memory_export` / `293_eco_embedded_no_os` / `294_eco_os_kernel_module` / `295_eco_bpf_ebpf_bytecode` / `296_eco_gpu_ptx_shader` / `297_eco_game_engine_ecs` / `298_eco_cryptography_simd` / `299_eco_language_server_protocol` / `300_eco_sa_lang_registry_publish`；尚未全量迁移）

---

# Version 0.6 — SA 零信任列式数据库（12 周）

目标：实现 R34 需求，交付一个与包管理同构的列式数据库引擎，支持预编译查询、SHA-256 锁版、权限 X 光扫描、零拷贝沙箱执行、无锁并发、Blob Arena、冷热分层。

## v0.6 任务

### M1：Schema + 列存 + Arena MemTable + Insert（W1–W3）

- [ ] 1. 实现 `.sadb-schema` 编译器（`src/db/schema.zig`）
  - [x] 1.1 扫描 `#def COL_*_STRIDE` 与 `#def TABLE_*_ROW_BYTES`
    - 说明：外部插件 `/home/vscode/projects/sa_plugins/sa_plugin_db/src/schema.zig` 已实现解析，并由 `schema compiler computes row bytes and preserves table alias` 覆盖
  - [ ] 1.2 生成 `.sai` 接口文件（纯文本 `#def` 副本）
  - [x] 1.3 验证容量（`MAX_ROWS * TABLE_ROW_BYTES ≤ 64GB`）
    - 说明：外部插件 schema 编译器已计算列宽总和，并在 `MAX_ROWS * computed_row_bytes > 64GB` 时返回 `CapacityOverflow`
  - _Requirements: R34.1, R2.4_

- [ ] 2. 实现 SoA 列存与 MemTable Arena（`src/db/arena.zig`）
  - [ ] 2.1 Zig `ArenaAllocator` 包装（Append-Only，64MB 阈值）
  - [ ] 2.2 `writev` 系统调用落盘（整块写入磁盘）
  - [x] 2.3 不可变段文件格式（`<table>.col<i>.<seg>.dat` + `<table>.meta`）
    - 说明：外部插件 `/home/vscode/projects/sa_plugins/sa_plugin_db/src/table.zig` 写入列段文件与 `.meta`，并由 `table ingest, verify, snapshot, restore, lock and compact are real` 覆盖
  - [x] 2.4 段内 SoA 列式布局
    - 说明：ingest 按列 buffer 写入 `col<i>` 段文件，表级 verify 校验段文件 SHA 与行数
  - _Requirements: R34.1, R34.2_

- [ ] 3. 实现 Insert 算子（`src/db/exec.zig` 初版）
  - [ ] 3.1 `atomic_rmw_add global_len, 1` 无锁自增游标
  - [ ] 3.2 多列并发写入（`mul + ptr_add + store`）
  - [ ] 3.3 容量检查与 OOM 处理
  - _Requirements: R34.5, R2.7_

- [ ] 4. 单元测试与基准（`tests/db/arena.zig`）
  - [ ] 4.1 Insert 吞吐基线（目标 ≥ 1M rows/sec）
  - [x] 4.2 MemTable → 段落盘的正确性验证
    - 说明：外部插件表层单元测试覆盖 CSV/JSONL ingest、segment_count、verify 和篡改检测

### M2：Blob Arena + Bump 分配（W4）

- [ ] 5. 实现 Blob Arena（`src/db/blob.zig`）
  - [ ] 5.1 Bump Allocator（纯追加，无碎片）
  - [ ] 5.2 `blob_handle = u64 = (seg_id:24 << 40) | offset:40` 位布局
  - [ ] 5.3 墓碑标记删除（1 字节标志位）
  - [ ] 5.4 段压缩触发（死亡比例 ≥ 50%）
  - _Requirements: R34.6_

- [ ] 6. Blob 写入范式（SA-ASM）
  - [ ] 6.1 `@write_blob_text` 完整实现（原子 bump 指针 + 容量检查）
  - [ ] 6.2 与 Insert 的集成（blob_handle 列写入）
  - _Requirements: R34.6_

- [ ] 7. 单元测试（`tests/db/blob.zig`）
  - [ ] 7.1 Blob 分配与释放正确性
  - [ ] 7.2 段压缩的数据完整性

### M3：查询模块编译 + SHA-256 注册 + X 光扫描（W5–W6）

- [ ] 8. 查询模块编译（`src/db/qmod.zig`）
  - [ ] 8.1 `.query.sa` → `<sha256>.qmod` 二进制编译
  - [ ] 8.2 源码 SHA-256 哈希计算与注册
  - [ ] 8.3 查询模块注册表（内存 HashMap）
  - _Requirements: R34.2_

- [ ] 9. Referee X 光扫描扩展（`src/db/referee_db.zig` + hook 进 `src/verifier.zig`）
  - [ ] 9.1 解析 `grants [db_read:tbl, db_write:tbl, db_atomic_cursor:tbl, db_alloc_blob:arena]`
  - [ ] 9.2 遍历查询模块指令流，校验 `load` / `store` / `atomic_rmw_*` 权限
  - [ ] 9.3 违规返回 `Trap: DbCapabilityEscalation`（附 `upstream_loc`）
  - _Requirements: R34.3, R9.3_

- [ ] 10. 单元测试（`tests/db/qmod.zig`）
  - [ ] 10.1 权限白名单校验（正常 + 越权场景）
  - [ ] 10.2 SHA-256 哈希稳定性

### M4：mmap 沙箱 + SIGSEGV handler + Trap 上报（W7）

- [ ] 11. 列基址注入与 mmap 映射（`src/db/exec.zig` 完整版）
  - [ ] 11.1 `@ffi_wrapper db_inject_cols` 实现
  - [ ] 11.2 mmap `MAP_PRIVATE | PROT_READ` 配置
  - [ ] 11.3 列基址作为 `&col: ptr` 借用传入查询模块
  - _Requirements: R34.4, R7_

- [ ] 12. SIGSEGV handler 与越权保护
  - [ ] 12.1 libc SIGSEGV 信号处理
  - [ ] 12.2 越权写入检测与进程终止
  - [ ] 12.3 `Trap: DbMemoryGuardViolation` 上报
  - _Requirements: R34.4_

- [ ] 13. 单元测试（`tests/db/exec.zig`）
  - [ ] 13.1 越权读写的 SIGSEGV 捕获
  - [ ] 13.2 合法读写的正常执行

### M5：CLI 子命令 + ingest + snapshot（W8）

- [ ] 14. CLI 子命令分发（`src/db/cli_db.zig` + hook 进 `src/cli.zig`）
  - [x] 14.1 `sa db init <table>.sadb-schema`
    - 说明：外部插件 `/home/vscode/projects/sa_plugins/sa_plugin_db/src/plugin.zig` 通过 `handle_command` 接入 `db init`，ABI wrapper 单元测试覆盖成功和错误诊断
  - [ ] 14.2 `sa db register <query>.sa`
  - [ ] 14.3 `sa db exec <sha256> --params <file>`
  - [ ] 14.4 `sa db ingest <table> <csv|jsonl>`
  - [ ] 14.5 `sa db snapshot <table>`
  - [ ] 14.6 `sa db restore <table> <epoch>`
  - [ ] 14.7 `sa db inspect <sha256>`
  - [ ] 14.8 `sa db compact <table>`
  - [ ] 14.9 `sa db lock <table>`
  - [ ] 14.10 `sa db verify <table>`
  - _Requirements: R34.11_

- [x] 15. Snapshot 与恢复（`src/db/snapshot.zig`）
  - [x] 15.1 Epoch 快照记录（全局 epoch 号 + 段列表）
    - 说明：外部插件表层实现 `snapshotTable`，将 `.meta`、schema 与段文件复制到 `.sa/db/snapshots/<table>/<epoch>/`
  - [x] 15.2 崩溃恢复（扫描 `.meta` 重建 MemTable 状态）
    - 说明：外部插件表层实现 `restoreTable`，单元测试验证从 epoch 恢复后 row_count 回退且锁状态恢复
  - _Requirements: R34.8_

- [ ] 16. 单元测试（`tests/db/cli.zig`）
  - [ ] 16.1 各子命令的基本功能
  - [x] 16.2 snapshot/restore 的一致性
    - 说明：外部插件 `table ingest, verify, snapshot, restore, lock and compact are real` 覆盖 snapshot/restore 一致性

### M6：冷热分层 + Zstd 压缩 + S3 落冷（W9–W10）

- [ ] 17. 冷热分层策略（`src/db/compact.zig`）
  - [ ] 17.1 后台线程定期扫描段 mtime
  - [ ] 17.2 热数据（7 天）Pin to RAM
  - [ ] 17.3 温数据（1 月）mmap NVMe
  - [ ] 17.4 冷数据（1 年+）Zstd 压缩落 S3
  - _Requirements: R34.7_

- [ ] 18. Zstd 压缩与 S3 集成
  - [ ] 18.1 Zstd 字典压缩（体积目标 10–15%）
  - [ ] 18.2 S3 API 集成（可选本地 mock）
  - [ ] 18.3 按需解压（冷数据访问时）

- [ ] 19. 单元测试（`tests/db/compact.zig`）
  - [ ] 19.1 分层策略的正确性
  - [ ] 19.2 压缩率验证

### M7：测试集 + 双 11 抢购 demo（W11–W12）

- [ ] 20. 完整单元测试套件（`tests/db/`）
  - [ ] 20.1 12 条 Trap 错误码的边界覆盖
  - [ ] 20.2 并发冲突（乐观锁失败）
  - [ ] 20.3 容量溢出（Blob OOM / 行游标溢出）
  - [ ] 20.4 数据完整性（Insert + Query + Snapshot）

- [ ] 21. 双 11 抢购 demo（`demos/flash_sale.sa`）
  - [ ] 21.1 10 万 SKU，初始库存 1000
  - [ ] 21.2 单线程 Insert + Update（扣库存）+ Query（统计）
  - [ ] 21.3 性能目标：1KW TPS 扣减（单线程）
  - [ ] 21.4 查询延迟 ≤ 10ms（p99）

- [ ] 22. 性能基线与文档
  - [ ] 22.1 1 亿行 SoA 列扫描 ≤ 200ms（AVX-512 启用）
  - [ ] 22.2 Insert 吞吐 ≥ 1M rows/sec
  - [x] 22.3 生成 `docs/database.md` 落地文档

### 新增 Trap 错误码（`src/db/trap_db.zig` + 登记到 `docs/errorcode.md`）

- [ ] 23. 12 条新 Trap 错误码
  - [ ] 23.1 `DbCapabilityEscalation` — 查询模块越权 load/store
  - [ ] 23.2 `DbMemoryGuardViolation` — mmap 越界 SIGSEGV
  - [ ] 23.3 `DbBlobArenaOOM` — Bump 分配器写满
  - [ ] 23.4 `DbConcurrencyConflict` — 行版本号 cmpxchg 失败
  - [ ] 23.5 `DbSchemaMismatch` — 数据列类型与 schema 不符
  - [ ] 23.6 `DbCursorOverflow` — `global_len` ≥ MAX_ROWS
  - [ ] 23.7 `DbColumnTypeMismatch` — qmod 用错列类型偏移
  - [ ] 23.8 `DbQueryHashUnknown` — EXEC 一个未注册的 SHA-256
  - [ ] 23.9 `DbBlobHandleInvalid` — blob_handle 段号或偏移越界
  - [ ] 23.10 `DbSnapshotCorrupted` — 段文件 SHA-256 校验失败
  - [ ] 23.11 `DbDuplicateRegister` — 同 SHA-256 重复注册不同 grants
  - [ ] 23.12 `DbForbiddenSqlString` — 任何运行时 SQL 字符串入口
  - _Requirements: R34.12_

---

## v0.8 网络引擎 `sa_netx`（io_uring + per-core sharded SPSC + DMA 扇出）

> 版本号说明：v0.7 已规划为"原生单元测试框架"（见本文件 Version 0.7 章节），故网络引擎排期至 v0.8。
>
> 实施目录：`src/runtime/sa_net_uring.zig`（新增，与 `sa_std.zig` 并列）+ `sa_std/netx.*` 三件套。**零修改 `flattener/` / `referee/` / `verifier.zig` / `common/` / 现有 `sa_std.zig` 的 117 个 `sa_*` export / 现有 `sa_std/net.*` / `sa_std/sync/mpsc.*` / `sa_std/core/mem.*`**。
>
> 详细蓝图：`docs/network_engine_plan.md` v0.9+。

### M0：编译器与契约准备（W0）

- [x] 44. 确认 SA-ASM ISA 足够支撑 Ticket 偏移直读
  - [x] 44.1 复查 `src/common/instruction.zig` 中 `load ... as u32/u64`、`ptr_add`、`atomic_*` 全部就绪
  - [x] 44.2 确认无需新增向量算子（`v_load / v_xor / v_broadcast` 留给 Zig `@Vector` 完成）
  - [x] 44.3 确认无需新增 `bitcast` 指令（用 `ptr_add` + `load as T` 替代）
  - _Requirements: R35.4, R35.6_

- [x] 45. 登记 SA 端契约骨架（仅文件骨架，不接入 build）
  - [x] 45.1 创建 `sa_std/netx.sai`：7 条 `@extern` 声明
  - [x] 45.2 创建 `sa_std/netx.sal`：`Ticket_*` 偏移 + `NetxProto_*` 枚举
  - [x] 45.3 创建 `sa_std/netx.sa`：`@import` 上面两个文件 + `NETX_*` 宏层
    - 说明（2026-07-03）：`netx.sa` 已从裸 `@import` 扩为完整宏层：7 条 extern 薄封装（`NETX_INIT/LISTEN/SHUTDOWN/RECV_TICKET/PUSH_OUTBOUND/BROADCAST/CLOSE_SLOT`）+ Ticket 字段直读（`NETX_TICKET_SLOT_ID/OP_CODE/PROTO/FLAGS/PAYLOAD/PAYLOAD_LEN`）+ 便利宏（`NETX_TICKET_HEADER` / `NETX_TICKET_IS_OP`）。`netx.sal` 补齐 `SA_NETX_*` 状态码、`NETX_OP_*`、`NETX_FLAG_*` 常量（镜像 runtime）。`netx.sai` 返回类型由 `i32!` 修正为 `i32`（实现返回 plain 状态码，非 error-union）。SA 单测 `tests/unit_framework/std_netx_macro_surface.sa` 覆盖 Ticket 字段偏移/宽度直读，`unit-framework` 全套件通过。
    - 关键修复：`sa_netx_*` 7 函数原为 `pub fn`（无 C-ABI 导出）且 `sa_net_uring.zig` 从未被 SA 链接的 runtime 根 `sa_std.zig` 引入 → SA 程序调用会链接失败。已改为 `pub export fn` 并在 `sa_std.zig` comptime 强引用块加入 `sa_net_uring.zig`（与 http2/tls/dtls/quic 同手法）。`nm libsa_std.so` 确认 7 个 `sa_netx_*` 均为 `T`（已定义）。
  - _Requirements: R35.10_

### M1：物理基座（W1–W3）

- [ ] 46. 新增 `src/runtime/sa_net_uring.zig` 骨架
  - [ ] 46.1 `ConnectionSlot align(64) struct`：fd + 9 态枚举 + 4 KB inline buffer + overflow 链 + `inflight_zc` 计数
  - [x] 46.2 `SlotPool`：`mmap(MAP_POPULATE | MAP_HUGETLB)` 一次性预分配 10⁵ – 10⁶ 槽位
  - [x] 46.3 Zig 侧零分配审计:用 `@memset` 清零，禁止调用 `sa_std/core/mem.sa`
  - _Requirements: R35.1, R35.2_

- [ ] 47. `io_uring` reactor 骨架
  - [x] 47.1 `IoUring.init` per-core 实例 + `sched_setaffinity` 绑核
  - [x] 47.2 `IORING_OP_ACCEPT_MULTISHOT` 单 SQE 持续产 CQE
  - [x] 47.3 `IORING_OP_RECV_MULTISHOT` + `IORING_REGISTER_PBUF_RING` provided buffer 环
  - [ ] 47.4 编译期探测 `RECV_MULTISHOT` / `SEND_ZC` 内核能力，运行时 fallback
  - _Requirements: R35.3_

- [x] 48. 槽位生命周期九态状态机
  - [x] 48.1 实现 `Free → Accepting → Handshake → (Http | WebSocket | RawBinary)` 转换
  - [x] 48.2 实现 `Reading / HalfClosed / Closing` 三态保护重入与半关闭
  - [x] 48.3 `IORING_OP_TIMEOUT` 配对 idle / handshake 清扫
    - 说明：`src/runtime/sa_net_uring.zig` 已通过 `Reactor.armTimeout` / `handleTimeoutCqe` / `scanExpiredSlots` 清扫 handshake 与 idle slot；`zig test src/runtime/sa_net_uring.zig -lc` 通过 11/11。
  - _Requirements: R35.9_

- [ ] 49. M1 验收
  - [ ] 49.1 预分配 100W Slot 启动无 OOM（`ulimit -v` 配套）
  - [ ] 49.2 TCP 握手 + echo 跑通
  - [ ] 49.3 `perf` 抓 `__libc_malloc` 调用次数 == 0（稳态运行 60s）
  - _Requirements: R35.2, R35.3_

### M2：HTTP/WS 拆包（W4–W5）

- [x] 50. Zig 侧零分配 DFA HTTP 解析器
  - [x] 50.1 `@Vector(32, u8)` 扫描 `\r\n` 与 `:` 分隔符
  - [x] 50.2 不创建 `HashMap<String, String>`，仅记录 `(offset, len)` 二元组
  - [x] 50.3 输出 `Ticket` 紧凑结构压入入站环
  - _Requirements: R35.4_

- [x] 51. WebSocket 零分配协议升级
  - [x] 51.1 识别 `Upgrade: websocket` → 栈上 `Base64(SHA1(key + magic))`
  - [x] 51.2 `slot.state` 由 `Http` 拨至 `WebSocket`，fd / buffer 不迁移
  - _Requirements: R35.6_

- [ ] 52. SIMD 暴力解掩码（Zig `@Vector`）
  - [x] 52.1 `@Vector(16, u8)` 基线（SSE2/NEON）
  - [x] 52.2 `@Vector(32, u8)` x86_64 AVX2 路径
  - [x] 52.3 标量尾收尾（≤ 15 字节）
  - [ ] 52.4 fuzz 1M 次 random payload + mask 不 panic
  - [ ] 52.5 perf 热路径占比 < 1%
  - _Requirements: R35.4_

- [ ] 53. M2 验收
  - [ ] 53.1 `curl http://localhost:PORT/` 通
  - [ ] 53.2 `wscat -c ws://localhost:PORT/` 握手通
  - [ ] 53.3 端到端 echo（HTTP + WS）跑通
  - _Requirements: R35.4, R35.6_

### M3：三环 + SA 贯通（W6–W7）

- [ ] 54. per-core sharded SPSC 三环
  - [ ] 54.1 Inbound Ring：reactor → SA（SPSC，每 reactor↔SA-core 一对）
  - [ ] 54.2 Execution Ring：SA-ASM 算子消费 Ticket
  - [ ] 54.3 Outbound Ring：SA → reactor（SPSC）
  - [ ] 54.4 与现有 `sa_std/sync/mpsc.sa` 共存：MPSC 仅作跨分片回收慢路径
  - _Requirements: R35.5_

- [x] 55. 7 条 `sa_netx_*` FFI 接入
  - [x] 55.1 `sa_netx_init(slot_capacity, reactor_count)`
  - [x] 55.2 `sa_netx_listen(&host, host_len, port)`
  - [x] 55.3 `sa_netx_recv_ticket(reactor_id, &out_ticket)`
  - [x] 55.4 `sa_netx_push_outbound(reactor_id, slot_id, &msg, len)`
  - [x] 55.5 `sa_netx_broadcast(reactor_id, &slot_ids, n, &msg, len)`
  - [x] 55.6 `sa_netx_close_slot(slot_id)`
  - [x] 55.7 `sa_netx_shutdown()`
  - _Requirements: R35.10_

- [ ] 56. 背压策略实施
  - [ ] 56.1 入站环满 → reactor 停 arm `RECV_MULTISHOT`（TCP 窗口自然收窄）
  - [ ] 56.2 出站环满 → `sa_netx_push_outbound` 返回 `EAGAIN`
  - [ ] 56.3 验证：满载注入 1M req/s，10s 内零 OOM、零内存分配
  - _Requirements: R35.8_

- [ ] 57. Raw Binary RPC 路径
  - [ ] 57.1 Ticket 偏移直读：`load payload+0 as u32` / `load payload+4 as u64`
  - [ ] 57.2 SA-ASM 业务核心吃 Ticket < 80 ns
  - _Requirements: R35.4_

- [ ] 58. M3 验收
  - [ ] 58.1 `examples/netx_echo/echo.sa` 端到端跑通
  - [ ] 58.2 业务核心吃 Ticket 时间 ≤ 80 ns（micro-benchmark）
  - _Requirements: R35.5, R35.10_

### M4：K1 跑分（对标 Bun ping-pong，W8–W9）

- [ ] 59. ping-pong 基准实施
  - [ ] 59.1 `examples/netx_echo/ws_bench.sa`：32 client × 64B 双向
  - [ ] 59.2 **不启用 SEND_ZC**：只用 `SEND` + provided buffer + sharded SPSC + SIMD unmask
  - [ ] 59.3 CPU pinning + busy-poll 调优
  - _Requirements: R35.7, R35.12_

- [ ] 60. M4 验收
  - [ ] 60.1 单机 32 client 64B ping-pong **≥ 2,500,000 msg/s**（持平 Bun v1.2）
  - [ ] 60.2 CPU 占用 ≤ 50%
  - [ ] 60.3 KPI 表标注内核版本与 Bun 版本
  - _Requirements: R35.12 (K1)_

### M5：SEND_ZC + DMA 扇出（W10）

- [ ] 61. 广播切片生命周期
  - [ ] 61.1 `BroadcastArena`：算子 Arena 内生成 `[WS Header | Payload]` 连续切片
  - [ ] 61.2 `gen: u32` 代纪元号 + `refcount: u16`（= fanout_count）
  - [ ] 61.3 SQE `user_data` 编码 `(gen, slot_id)`，notification CQE 触发 refcount--
  - [ ] 61.4 refcount 归零 → 切片归还 Arena
  - _Requirements: R35.7_

- [ ] 62. `IORING_OP_SEND_ZC` 批量轰炸
  - [ ] 62.1 自动选路：单 payload ≥ 1.5 KB **或** `fanout_count ≥ 8` **或** `NETX_FLAG_BROADCAST` → SEND_ZC；否则 SEND
  - [ ] 62.2 SQ 容量 4096–32768，10⁵ 扇出分批 enter
  - [ ] 62.3 共享物理切片：所有 SQE `addr` 指向同一内存
  - [ ] 62.4 内核版本 < 6.0 降级为 `SENDMSG + MSG_ZEROCOPY` 或 `sendmmsg`
  - _Requirements: R35.7_

- [ ] 63. M5 验收（K2 跑分）
  - [ ] 63.1 1 source × 10⁵ receivers × 1 KB payload **≥ 30 GB/s** 总吞吐（≥ 10× Bun 同场景）
  - [ ] 63.2 CPU 占用 ≤ Bun 同场景的 30%
  - [ ] 63.3 ZC notification CQE 必须全部回收，无 leak（valgrind / mtrack 抽检）
  - _Requirements: R35.12 (K2)_

### M6：反向超越 Bun（W11–W12）

- [ ] 64. 极限调优
  - [ ] 64.1 `IORING_SETUP_SQPOLL` 选择性启用（benchmark / 单租户裸金属）
  - [ ] 64.2 reactor busy-poll 节流 + L1 cache 亲和审计
  - [ ] 64.3 零分配审计：perf 抓 `mmap/brk` 调用 == 0
  - _Requirements: R35.2, R35.3, R35.12_

- [ ] 65. M6 验收
  - [ ] 65.1 单机 32 client 64B ping-pong **≥ 3,500,000 msg/s**（≥ 1.4× Bun）
  - [ ] 65.2 KPI 报告锁定内核版本 / Bun 版本 / 硬件型号
  - _Requirements: R35.12 (K1 stretch)_

### v0.8.5 HTTP 插件增强与 OpenAI 转发 (HubProxy)

- [x] 65a. `sa_http_client` 插件实现
  - [x] 集成 Zig `std.http.Client`
  - [x] 暴露 `sa_http_req_send` 及流式 Reader
  - [x] 支持 `POST`、自定义 `--header`、请求 body 透传和本地 loopback 回归
  - [x] 实现 HTTPS/TLS 出站请求
  - 说明：当前已完成 HTTP GET / POST / stream / TLS / runtime descriptor / skills 路径；301 HTTP client SAASM demo 已纳入 `cli-special` 主验收并通过 `zig build test --summary all`
- [x] 65b. `sa_http_server` 高层级封装
  - [x] 基于 `sa_net_uring` 实现 AOT 静态路由
  - [x] 实现 Header 注入与中间件流水线
  - [x] 请求体读取、路由分发和 SSE/chunked 透传
  - 说明：302 HTTP server SAASM demo 已纳入 `cli-special` 主验收并通过 `zig build test --summary all`
- [ ] 65c. HubProxy 端到端实现
  - [x] 实现可运行 `main()` 入口，加载 `upstream.json` 并监听本地端口
    - 说明：`examples/hubproxy/main.zig` 已实现 `main()` / `loadConfig` / `serve`；`zig test examples/hubproxy/main.zig` 通过 2/2，`zig build-exe examples/hubproxy/main.zig -femit-bin=/tmp/hubproxy-smoke` 成功，`timeout 1s /tmp/hubproxy-smoke examples/hubproxy/upstream.json` 输出 `hubproxy listening on http://127.0.0.1:18081`。
  - [x] 实现 `/v1/chat/completions` 与 `/v1/responses` 两条转发路由
    - 说明：`resolveRoute` 覆盖两条 OpenAI-compatible 路由并保留 query suffix，`hubproxy resolves supported routes` 单测通过。
  - [ ] 支持 SSE / chunked 流式响应透传，不允许回退为一次性缓冲假流
  - [x] HubProxy 仅作为示例工程存在，不回写主线程命令分发逻辑
    - 说明：HubProxy 仅位于 `examples/hubproxy/`，`build.zig` 只纳入示例测试和 `hubproxy` 示例可执行产物；`src/cli.zig` / `src/plugins.zig` / `src/main.zig` 未出现 HubProxy 命令分支。
  - [ ] 性能目标：转发延迟损耗 < 1ms

### 文档与生态登记

- [x] 66. `docs/network_engine_plan.md` 维护至 v0.9+（已含 §0–§8）
  - [x] 66.1 §0 边界裁决（TLS 由前置代理终结，HTTP/2/3 本期不做）
  - [x] 66.2 §0.2 项目目录架构（落到现仓库 src/runtime / sa_std / examples / docs）
  - [x] 66.3 §6 性能模型与 K1/K2 双轨 KPI
  - _Requirements: R35.13_

- [x] 67. `docs/std_rfc.md` 登记 `sa_netx_*` 加入标准库的 RFC
  - [x] 67.1 列出 7 条 FFI + Ticket layout
    - 说明：`docs/std_rfc.md` 已新增 `sa_netx` RFC 小节，列出 `sa_netx_init/listen/recv_ticket/push_outbound/broadcast/close_slot/shutdown` 与 `Ticket_*` 布局。
  - [x] 67.2 标注与现有 `sa_std.net` 的并行关系
    - 说明：RFC 已明确 `sa_std/net.*` 是普通 socket facade，`sa_std/netx.*` 是高并发 reactor/Ticket API，不互相替代。
  - _Requirements: R35.13_

### 性能基线与回归

- [ ] 68. 持续 benchmark 基线
  - [ ] 68.1 K1 / K2 双轨每次发版跑分入库
  - [ ] 68.2 KPI 回退 ≥ 5% 触发 CI 红灯
  - [ ] 68.3 内核版本兼容矩阵：6.0 / 6.1 / 6.6 LTS / 6.10
  - _Requirements: R35.12_

---

## v0.9 SAX 前端 UI 方言（safe asm XML，全栈 SA 闭环）

> 实施目录：当前 SAX 主实现已外置到 `/home/vscode/projects/sa_plugins/sa_plugin_sax/src/sax/`（`parser.zig` / `lowerer.zig` / `airlock_gen.zig` / `build.zig` / `cli.zig`）并通过 runtime plugin command 接入；主仓只保留共享 SA 工具链、宿主 loader 和 `src/verifier.zig` 的 SAX hook。**SA-ASM ISA 零扩展**。
>
> 详细蓝图：`docs/sax_whitepaper.md` / `docs/sax_design.md` / `docs/sax_airlock.md` / `docs/sax_syntax.md`。

### Phase 1：MVP 基础渲染闭环（W1–W8）

#### M0：契约与降级蓝图确认（W0）

- [x] 69. 确认 SAX 不需要扩展 SA-ASM ISA
  - [x] 69.1 复查 `src/common/instruction.zig`，所有 SAX 降级目标指令（`alloc / store / load / call / br / jmp / ret / !release`）就绪
  - [x] 69.2 确认浏览器 WASM 目标不需要扩展 SA-ASM ISA
    - 说明：外部 SAX 插件当前走 LLVM-C `.sa.bc` + `zig build-exe -target wasm32-freestanding -fno-entry --import-symbols` 生成浏览器模块，不走旧任务原文中的手写 `src/emit_wasm/wasm32-unknown-unknown` 路线；这属于后端实现路线调整，不影响“ISA 零扩展”结论。
  - [x] 69.3 复查外部插件 `/home/vscode/projects/sa_plugins/sa_plugin_sax/src/sax/` 五件套结构，登记 SAX Parser → SA 文本流的降级契约
  - _Requirements: R36.1, R36.12_

#### M1：SAX Parser 与 Lowerer（W1–W3）

- [x] 70. SAX Parser 完整实现（外部插件 `src/sax/parser.zig`）
  - [x] 70.1 解析 `<Component name="X">` 顶层结构
  - [x] 70.2 解析 `<state>` 块：一行一变量，支持 `i64 / i32 / f64 / i1 / ptr / alloc N` 字面/标注
  - [x] 70.3 解析 DOM 树：标签 + 属性 + `{expr}` 插值 + `onevent={^handler}` 事件
  - [x] 70.4 解析 `@handler:` 函数体（直通 SA-ASM 文本，不变换）
  - [x] 70.5 解析尾部 `!var1 !var2 ...` 释放序列
  - [x] 70.6 **不构造宿主 AST**：解析结果由插件 Lowerer 直接输出 `.sa` 文本流
  - _Requirements: R36.1, R36.2, R36.3_

- [x] 71. SAX Lowerer 完整实现（外部插件 `src/sax/lowerer.zig`）
  - [x] 71.1 状态变量 → `alloc Component_SIZE` + 固定偏移 `store` 初始化
  - [x] 71.2 DOM 树 → `@ffi_wrapper` 内 `sax_dom_create / sax_dom_append_child / sax_dom_set_attr / sax_dom_set_text` 调用序列
  - [x] 71.3 `{expr}` 插值 → typed `load state+offset` + `sax_itoa` / `sax_ftoa_bits` + `sax_dom_set_text(node, &buf, len)`
  - [x] 71.4 `onclick={^handler}` → `sax_dom_bind_event(node, "click", handler_export, ctx)`，handler 走 WASM function export 名称
  - [x] 71.5 自动生成 `sax_X_init` / `sax_X_render` / `sax_X_destroy` 三组 `@export` 函数
  - [x] 71.6 释放序列 `!var` → `destroy` 中释放 state-owned ptr / state / dom / ctx
  - _Requirements: R36.2, R36.3_

- [x] 72. WASM 目标切换
  - [x] 72.1 外部插件 `src/sax/build.zig` 强制浏览器 freestanding WASM 模块路径
    - 说明：`sax browser wasm build targets freestanding browser module` 单测覆盖当前目标路径；实际 target 为 `wasm32-freestanding -fno-entry --import-symbols`。
  - [x] 72.2 不修改主仓手写 `src/emit_wasm/` 后端
    - 说明：SAX 浏览器产物由 LLVM-C bitcode 路径交给 Zig 生成 WASM，避免把 SAX 专用逻辑写回主仓手写 WASM 后端。
  - [x] 72.3 验证：SAX demo 产物 `app.wasm` 体积 < 50 KB（typed demo 2583 bytes；reactive dashboard 4034 bytes）
  - 说明：2026-06-04 复跑 `/home/vscode/projects/sa_plugins/sa_plugin_sax` 的 `zig build test --summary all` 通过 37/37，Build Summary 39/39；Counter/TodoList/dashboard/typed demos 均在 Node runtime E2E 中加载 `app.wasm + airlock.js`。
  - _Requirements: R36.12_

#### M2：Referee 扩展（W4）

- [ ] 73. SAX 7 条专属 Trap 规则（`src/sax/sax_rules.zig`）
  - [x] 73.1 `SaxStateLeak`：销毁函数出口 `<state>` 仍 `Active` → Trap
  - [x] 73.2 `SaxEventEscape`：`^handler` 引用跨 `<Component>` 函数 → Trap
  - [x] 73.3 `SaxRenderOutsideHandler`：`call @render()` 出现在 `@handler` 外 → Trap
  - [x] 73.4 `SaxInvalidInterpolation`：`{expr}` 包含 `^` / `!` → Trap（Parser 阶段）
  - [x] 73.5 `SaxStateWriteFromOutside`：组件外部代码写 `<state>` 内存槽 → Trap
  - [x] 73.6 `SaxUnknownTag`：DOM 标签不在 HTML5 白名单 → Trap（Parser 阶段）
  - [x] 73.7 `SaxUnknownEvent`：事件不在白名单 → Trap（Parser 阶段）
  - [ ] 73.8 每条 Trap 携带 `component / handler / tag / event / upstream_loc` 诊断字段
  - 说明：外部插件 `/home/vscode/projects/sa_plugins/sa_plugin_sax` 已用 `zig build test --summary all` 自动覆盖 7 条 Trap 的 `sa sax check` 负向路径；宿主 `src/verifier.zig` 的 SAX source-map hook 仍按 73.8 / 74 保留。
  - _Requirements: R36.4, R36.5, R36.6, R36.7, R36.8, R36.9_

- [x] 74. Referee hook 接入（`src/verifier.zig` 追加 SAX 规则调用）
  - [x] 74.1 在 `verifyBody` 主循环内添加 SAX 规则分发（仅当输入源标记为 SAX 派生）
  - [x] 74.2 不破坏现有 23 条 Trap 规则
  - _Requirements: R36.9_

#### M3：DOM Airlock 与 HTML Shell（W5–W6）

- [x] 75. Airlock JS 自动生成（外部插件 `src/sax/airlock_gen.zig`）
  - [x] 75.1 ~20 个白名单 API 全部覆盖（查询 / 创建 / 内容 / 属性 / 事件 / 路由 / HTTP / 工具）
  - [x] 75.2 节点句柄走整数 ID（Airlock 内部映射表，WASM 不可伪造）
  - [x] 75.3 `sax_dom_set_text` 强制走 `textContent`（防 XSS）
  - [x] 75.4 `sax_dom_set_attr` 属性白名单：`class / style / value / placeholder / disabled`
  - [x] 75.5 事件绑定走 WASM function export 名称并由 Airlock lookup 调用，不接受任意 inline JS
  - [x] 75.6 验证：`<script>` 注入 / `innerHTML` 注入 / `eval` 注入三类用例触发 Airlock 拒绝
  - _Requirements: R36.10_

- [x] 76. HTML Shell 生成器
  - [x] 76.1 生成最小 `index.html`（加载 `app.wasm` + `airlock.js`）
  - [x] 76.2 注入 CSP（`Content-Security-Policy`）头部，禁用 inline script / eval
  - [x] 76.3 自动注入 entry 调用：`sax_app_init` 在 DOMContentLoaded 后启动
  - _Requirements: R36.10, R36.11_

#### M4：CLI 子命令（W7）

- [x] 77. `sa sax` 子命令族（外部插件 runtime command）
  - [x] 77.1 `sa sax build <file.sax>` → `dist/app.sa + dist/app.wasm + dist/airlock.js + dist/index.html`
  - [x] 77.2 `sa sax check <file.sax>` → 仅 Parser/Validation/Referee 验证，不产出产物
  - [x] 77.3 `sa sax new <name>` → 脚手架最小项目（`app.sax` + `package.json` + `README.md`）
  - [x] 77.4 错误退出码统一：Trap → exit 1，未知命令 → exit 2，IO 错误 → exit 3
  - _Requirements: R36.11_

#### M5：Phase 1 验收（W8）

- [x] 78. E2E 浏览器验证（Phase 1 验收）
  - [x] 78.1 `Counter.sax` 编译通过 + 浏览器点击 +1/-1 正确（Chrome）
  - [x] 78.2 `TodoList.sax` 编译通过 + 增删项 + 输入框 + 列表渲染
  - [x] 78.3 删掉 `!count` → `sa sax check` 报 `SaxStateLeak`
  - [x] 78.4 `^handler` 跨组件引用 → 报 `SaxEventEscape`
  - [x] 78.5 `{count + ^x}` → 报 `SaxInvalidInterpolation`
  - [x] 78.6 `<foo>` 自定义标签 → 报 `SaxUnknownTag`
  - [x] 78.7 `<button onhover={^x}>` → 报 `SaxUnknownEvent`
  - [x] 78.8 包体积对比：TodoList SAX vs React，目标 < 50 KB WASM vs ~130 KB+ React
  - 说明：插件级自动验收已覆盖 `Counter` / `TodoList` / `reactive_dashboard` / `buffer_state` / `allowed_attrs` / `expression_interpolation` / `typed_state_interpolation` 的 `sa sax check`、`sa sax build`、WASM import/export、Airlock/事件名验证；Node 运行时 E2E 会真实加载 `app.wasm + airlock.js`、挂载 `#app`、触发 Counter `+1/-1/reset`、TodoList 增删项与输入框读写、dashboard / typed demo 点击事件，并锁住 root 挂载、Airlock JS 语法与插值文本空格；另已补 `<script>` / `innerHTML` / `onclick=eval(...)` 三类 Airlock 拒绝验证与 CLI exit code 映射测试。Chrome 点击验收已通过，TodoList SAX vs React 体积对比已验证。
  - _Requirements: R36.4, R36.5, R36.6, R36.7, R36.8, R36.9_

### Phase 2：响应式 + 路由 + 生命周期（W9–W14）

- [ ] 79. 编译期细粒度响应式（依赖分析）
  - [x] 79.1 SAX Parser 分析 `{expr}` ↔ `<state>` 依赖关系
  - [x] 79.2 `call @render()` 展开为最小 DOM 更新调用集（仅更新依赖该状态的节点）
  - [ ] 79.3 性能基线：1000 行列表中单行更新 ≤ 1ms（vs 全量 render）
  - _Requirements: R36.2_

- [ ] 80. 生命周期钩子
  - [x] 80.1 `@onMount:` Lowerer 在 init 末尾追加调用
  - [x] 80.2 `@onUnmount:` Lowerer 在 destroy 头部插入调用
  - [ ] 80.3 钩子函数签名一致性校验（无参无返）
  - _Requirements: R36.2_

- [ ] 81. `<Router>` / `<Page>` 基础路由
  - [x] 81.1 `<Router>` 顶层组件，挂载 `popstate` / `hashchange` 事件
  - [x] 81.2 `<Page path="/x" component="X" />` 声明式路由表
  - [ ] 81.3 路由变化触发对应 `<Page>` 组件的 mount/unmount
  - _Requirements: R36.2_

- [ ] 82. `sa sax dev` 开发服务器
  - [x] 82.1 HTTP :8080 + 静态文件托管
  - [ ] 82.2 文件监听（`inotify` / `kqueue`）+ 自动重新编译
  - [ ] 82.3 WASM 模块热替换（保留 SA 状态）
  - _Requirements: R36.11_

- [ ] 83. VS Code 插件
  - [ ] 83.1 TextMate grammar for `.sax`（XML + SA-ASM 混合高亮）
  - [ ] 83.2 `sa sax check` 集成到 LSP 诊断
  - _Requirements: R36.11_

### Phase 3：跨端 + 生态（W15–W22）

- [ ] 84. `--target native` 原生桌面 UI
  - [ ] 84.1 自定义渲染器（GLFW / SDL2 / 自研）
  - [ ] 84.2 Airlock 接口在原生侧的等价实现
  - _Requirements: R36.12_

- [ ] 85. `--target js` 降级模式
  - [ ] 85.1 SAX → JS Bundle（兼容旧浏览器 / 扩大受众）
  - [ ] 85.2 与 WASM 路径并行存在，CLI 标志切换
  - _Requirements: R36.12_

- [ ] 86. WebGPU / Canvas 渲染路径
  - [ ] 86.1 `<canvas>` 标签下沉到 WebGPU 调用
  - [ ] 86.2 高性能 Dashboard / 数据可视化场景
  - _Requirements: R36.6_

- [ ] 87. 包管理集成（复用 v0.5 零信任包管理）
  - [ ] 87.1 `sa.mod` 声明 SAX 组件库依赖
  - [ ] 87.2 `grants [dom_query, dom_event_bind, ...]` 模块级权限
  - _Requirements: R36.14_

- [ ] 88. `<style>` 块支持
  - [ ] 88.1 类 Vue SFC 风格，组件作用域 CSS
  - [ ] 88.2 SA 变量驱动动态样式（编译期展开）
  - _Requirements: R36.6_

### 文档与生态登记

- [x] 89. `docs/sax_*.md` 四件套维护
  - [x] 89.1 `sax_whitepaper.md` 升级到当前外部插件口径（含 Phase 2 已落地/剩余路线）
  - [x] 89.2 `sax_design.md` 跟进外部插件 Lowerer、LLVM-C/WASM 实际实现路径
  - [x] 89.3 `sax_airlock.md` 同步白名单 API 与外部插件路径
  - [x] 89.4 `sax_syntax.md` 维护 DOM 标签 / 属性 / 事件白名单
  - 说明：四件套已同步为 `/home/vscode/projects/sa_plugins/sa_plugin_sax` 外部插件实现口径，并明确当前浏览器 WASM 路径与仍未完成的 dev hot replace/router mount 等 Phase 2 缺口。
  - _Requirements: R36.14_

- [x] 90. `docs/std_rfc.md` 登记 SAX 加入标准库的 RFC
  - [x] 90.1 列出 7 条 SAX Trap + Airlock 白名单 + CLI 命令
  - [x] 90.2 与 `sa_netx`（v0.8）/ `sa-db`（v0.6）的协同关系
  - 说明：`docs/std_rfc.md` 已新增 SAX RFC 小节，登记插件边界、Trap、Airlock、CLI、与 netx/DB/pkg/wgpu/3d 的协作关系。
  - _Requirements: R36.14_

### sa_std String/Vec Rust API Parity Continuation

- [x] str/String/StringBuf slice-needle trim-match aliases
  - `STR_TRIM_START_MATCHES_NEEDLE` / `STRING_TRIM_START_MATCHES_NEEDLE` / `STRING_BUF_TRIM_START_MATCHES_NEEDLE`
  - `STR_TRIM_END_MATCHES_NEEDLE` / `STRING_TRIM_END_MATCHES_NEEDLE` / `STRING_BUF_TRIM_END_MATCHES_NEEDLE`
  - `STR_TRIM_MATCHES_NEEDLE` / `STRING_TRIM_MATCHES_NEEDLE` / `STRING_BUF_TRIM_MATCHES_NEEDLE`
  - Scope: concrete `&str` needle subset; no claim of generic Rust `Pattern` / char / closure / slice-of-char coverage.
- [x] str/String/STRING_BUF escape_default/escape_unicode 批次已补齐 `STR_ESCAPE_DEFAULT` / `STRING_ESCAPE_DEFAULT` / `STRING_BUF_ESCAPE_DEFAULT`、`STR_ESCAPE_UNICODE` / `STRING_ESCAPE_UNICODE` / `STRING_BUF_ESCAPE_UNICODE`；按 UTF-8 scalar 扫描并复用 char 级 escape writer，产出 eager owned `StringBuf`，不声明 Rust lazy escape iterator、泛型 Pattern 或 borrow checker lifetime 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF encode_utf16 批次已补齐 `STR_ENCODE_UTF16_LEN` / `STRING_ENCODE_UTF16_LEN` / `STRING_BUF_ENCODE_UTF16_LEN`、`STR_ENCODE_UTF16` / `STRING_ENCODE_UTF16` / `STRING_BUF_ENCODE_UTF16`；按 UTF-8 scalar 扫描并复用 `CHAR_LEN_UTF16` / `CHAR_TRY_ENCODE_UTF16` 产出 owned `Vec<u16>` unit buffer，覆盖 BMP 与 surrogate pair，不声明 Rust lazy `EncodeUtf16` iterator 或 borrow checker lifetime 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF utf8_chunks 批次已补齐 `STR_UTF8_CHUNKS_COUNT` / `STRING_UTF8_CHUNKS_COUNT` / `STRING_BUF_UTF8_CHUNKS_COUNT`、`STR_TRY_UTF8_CHUNK_AT` / `STRING_TRY_UTF8_CHUNK_AT` / `STRING_BUF_TRY_UTF8_CHUNK_AT`、`STR_UTF8_CHUNK_AT` / `STRING_UTF8_CHUNK_AT` / `STRING_BUF_UTF8_CHUNK_AT`；按 lossy UTF-8 扫描合并 contiguous valid run，并把每个 invalid unit 作为独立 invalid chunk 暴露为 caller-indexed `(ok, valid, Slice)` 视图，不声明 Rust lazy `Utf8Chunks` iterator 或 borrow checker lifetime 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF escape_debug 批次已补齐 `CHAR_ESCAPE_DEBUG_WRITE`、`STR_ESCAPE_DEBUG` / `STRING_ESCAPE_DEBUG` / `STRING_BUF_ESCAPE_DEBUG`；按 UTF-8 scalar 扫描并复用 char 级 debug escape writer，产出 eager owned `StringBuf`，printable ASCII 直通、non-ASCII 写 raw UTF-8、non-printable ASCII 回落 `\u{...}`，不声明 Rust lazy `EscapeDebug` iterator、完整 Unicode graphic 分类或 borrow checker lifetime 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF substr_range 批次已补齐 `STR_TRY_SUBSTR_RANGE` / `STRING_TRY_SUBSTR_RANGE` / `STRING_BUF_TRY_SUBSTR_RANGE`、`STR_SUBSTR_RANGE` / `STRING_SUBSTR_RANGE` / `STRING_BUF_SUBSTR_RANGE`；按指针算术恢复 sub-slice 在 haystack 内的 byte range `(ok, start, end)`，越界/非重叠返回 `ok=0`，不声明 Rust panic/unsafe `substr_range_unchecked`、lifetime proof 或 provenance 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec/StringBuf capacity_remaining 与 StringBuf spare capacity 批次已补齐 `VEC_CAPACITY_REMAINING` / `VEC_REMAINING_CAPACITY`、`STRING_BUF_CAPACITY_REMAINING` / `STRING_BUF_REMAINING_CAPACITY`、`STRING_BUF_SPARE_CAPACITY_MUT` / `STRING_BUF_SPLIT_AT_SPARE_MUT`；返回 `cap-len` 与 byte spare 可变视图，不声明 Rust `MaybeUninit` spare 对象模型或 allocator trait 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF get naming + StringBuf set_len 批次已补齐 `STR_TRY_GET` / `STRING_TRY_GET` / `STRING_BUF_TRY_GET`、`STR_GET` / `STRING_GET` / `STRING_BUF_GET`、`STR_TRY_GET_UNCHECKED` / `STRING_TRY_GET_UNCHECKED` / `STRING_BUF_TRY_GET_UNCHECKED`、`STR_GET_UNCHECKED` / `STRING_GET_UNCHECKED` / `STRING_BUF_GET_UNCHECKED`，以及 `STRING_BUF_TRY_SET_LEN` / `STRING_BUF_SET_LEN`；checked get 委托现有 range-between 边界与 UTF-8 char-boundary 检查，unchecked get 仅做顺序/长度边界检查，set_len 在 cap 内允许 extend、缩小时要求 char boundary，超 cap 与 mid-scalar shrink 返回 `ok=0` 且不修改；不声明 Rust `Option<&str>`、unsafe panic 模型或 allocator/MaybeUninit 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF get_mut naming + StringBuf push_str_within_capacity 批次已补齐 `STR_TRY_GET_MUT` / `STRING_TRY_GET_MUT` / `STRING_BUF_TRY_GET_MUT`、`STR_GET_MUT` / `STRING_GET_MUT` / `STRING_BUF_GET_MUT`、`STR_TRY_GET_UNCHECKED_MUT` / `STRING_TRY_GET_UNCHECKED_MUT` / `STRING_BUF_TRY_GET_UNCHECKED_MUT`、`STR_GET_UNCHECKED_MUT` / `STRING_GET_UNCHECKED_MUT` / `STRING_BUF_GET_UNCHECKED_MUT`，以及 `STRING_BUF_TRY_PUSH_STR_WITHIN_CAPACITY` / `STRING_BUF_PUSH_STR_WITHIN_CAPACITY`；mut get 复用 checked/unchecked get 边界语义并通过 `STRING_BUF_AS_MUT_STR` 写回，push_str_within_capacity 仅在剩余容量足够时追加且不 realloc；不声明 Rust `Option<&mut str>` 或 borrow exclusivity 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf push_byte/char_within_capacity + Vec try_set_len 批次已补齐 `STRING_BUF_TRY_PUSH_BYTE_WITHIN_CAPACITY` / `STRING_BUF_PUSH_BYTE_WITHIN_CAPACITY`、`STRING_BUF_TRY_PUSH_CHAR_WITHIN_CAPACITY` / `STRING_BUF_PUSH_CHAR_WITHIN_CAPACITY`、`VEC_TRY_SET_LEN` / `VEC_TRY_SET_LEN_U64`；push_byte 复用 Vec within-capacity 路径，push_char 先 UTF-8 编码再按剩余容量追加，非法 scalar / 容量不足返回 `ok=0` 且不 realloc；Vec try_set_len 仅在 `new_len <= cap` 时更新长度；不声明 Rust unsafe panic 模型或 allocator 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf try_truncate 批次已补齐 `STRING_BUF_TRY_TRUNCATE`；`new_len > len` 时 no-op 返回 `ok=1`，缩小时要求 UTF-8 char boundary，mid-scalar 返回 `ok=0` 且不修改；不声明 Rust panic-on-boundary 模型；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF get_mut range naming 批次已补齐 `*_TRY_GET_RANGE_MUT` / `*_GET_RANGE_MUT`、`*_TRY_GET_PREFIX_MUT` / `*_GET_PREFIX_MUT`、`*_TRY_GET_SUFFIX_MUT` / `*_GET_SUFFIX_MUT`、`*_TRY_GET_RANGE_BETWEEN_MUT` / `*_GET_RANGE_BETWEEN_MUT`；复用现有 checked get-range 边界语义，`STRING_BUF_*` 经 `AS_MUT_STR` 写回；不声明 Rust `Option<&mut str>` 或 exclusive borrow 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] str/String/STRING_BUF get_mut range_to/from naming 批次已补齐 `*_TRY_GET_RANGE_TO_MUT` / `*_GET_RANGE_TO_MUT`、`*_TRY_GET_RANGE_FROM_MUT` / `*_GET_RANGE_FROM_MUT`；复用现有 checked prefix/suffix 边界语义，`STRING_BUF_*` 经 `AS_MUT_STR` 写回；不声明 Rust `Option<&mut str>` 或 exclusive borrow 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf insert_within_capacity 批次已补齐 `STRING_BUF_TRY_INSERT_STR_WITHIN_CAPACITY` / `STRING_BUF_INSERT_STR_WITHIN_CAPACITY`、`STRING_BUF_TRY_INSERT_BYTE_WITHIN_CAPACITY` / `STRING_BUF_INSERT_BYTE_WITHIN_CAPACITY`、`STRING_BUF_TRY_INSERT_CHAR_WITHIN_CAPACITY` / `STRING_BUF_INSERT_CHAR_WITHIN_CAPACITY`；仅在剩余容量足够且 index 为 char boundary 时原地右移并插入，空插入 no-op，容量不足/mid-scalar/非法 scalar 返回 `ok=0` 且不 realloc；不声明 Rust panic 模型；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec insert_within_capacity 批次已补齐 `VEC_TRY_INSERT_WITHIN_CAPACITY` / `VEC_INSERT_WITHIN_CAPACITY`、`VEC_TRY_INSERT_WITHIN_CAPACITY_U64` / `VEC_INSERT_WITHIN_CAPACITY_U64`；仅在 `index <= len` 且 `len < cap` 时原地右移并插入，容量满/越界返回 `ok=0` 且不 realloc；不声明 Rust panic 模型或 generic T 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec extend_from_slice_within_capacity 批次已补齐 `VEC_TRY_EXTEND_FROM_SLICE_WITHIN_CAPACITY` / `VEC_EXTEND_FROM_SLICE_WITHIN_CAPACITY`、`VEC_TRY_EXTEND_FROM_SLICE_WITHIN_CAPACITY_U64` / `VEC_EXTEND_FROM_SLICE_WITHIN_CAPACITY_U64`；仅在剩余容量足够时整段复制追加，空源 no-op，容量不足返回 `ok=0` 且不 realloc；不声明 Rust panic 或 partial-append 模型；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf/Vec extend and append within capacity 批次已补齐 `STRING_BUF_TRY_EXTEND_STR_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_STR_WITHIN_CAPACITY`、`STRING_BUF_TRY_EXTEND_STRING_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_STRING_WITHIN_CAPACITY`、`STRING_BUF_TRY_EXTEND_FROM_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_FROM_WITHIN_CAPACITY`、`VEC_TRY_APPEND_WITHIN_CAPACITY` / `VEC_APPEND_WITHIN_CAPACITY`、`VEC_TRY_APPEND_WITHIN_CAPACITY_U64` / `VEC_APPEND_WITHIN_CAPACITY_U64`；String 路径复用 within-capacity push 且 extend_string 不消费源，Vec append 成功后将源 len 清零；容量不足/非法 range 返回 `ok=0` 且不 realloc；不声明 Rust panic 或 partial-append 模型；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec extend_from_within + StringBuf extend char/byte within capacity 批次已补齐 `VEC_TRY_EXTEND_FROM_WITHIN_CAPACITY_U64` / `VEC_EXTEND_FROM_WITHIN_CAPACITY_U64`、`STRING_BUF_TRY_EXTEND_CHAR_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_CHAR_WITHIN_CAPACITY`、`STRING_BUF_TRY_EXTEND_BYTE_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_BYTE_WITHIN_CAPACITY`；Vec 路径先校验 range/剩余容量，经临时缓冲复制后再 within-capacity 追加；String char/byte 为现有 within-capacity push 的命名别名；容量不足/越界/非法 scalar 返回 `ok=0` 且不 realloc；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf replace_range within capacity 批次已补齐 `STRING_BUF_TRY_REPLACE_RANGE_WITHIN_CAPACITY` / `STRING_BUF_REPLACE_RANGE_WITHIN_CAPACITY`；仅在 char boundary 合法且新长度不超过 cap 时原地替换，replacement 先拷入临时缓冲再右移/左移后缀；容量不足/越界/mid-scalar 返回 `ok=0` 且不 realloc；不声明 Rust panic 模型；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf replace_first/last + Vec resize within capacity 批次已补齐 `STRING_BUF_TRY_REPLACE_FIRST_WITHIN_CAPACITY` / `STRING_BUF_REPLACE_FIRST_WITHIN_CAPACITY`、`STRING_BUF_TRY_REPLACE_LAST_WITHIN_CAPACITY` / `STRING_BUF_REPLACE_LAST_WITHIN_CAPACITY`、`VEC_TRY_RESIZE_WITHIN_CAPACITY` / `VEC_RESIZE_WITHIN_CAPACITY`、`VEC_TRY_RESIZE_WITHIN_CAPACITY_U64` / `VEC_RESIZE_WITHIN_CAPACITY_U64`；String 路径复用 within-capacity replace_range，Vec 缩小时直接截断、增长仅在 `new_len <= cap` 时填充分配槽；容量不足/未命中 needle 返回 `ok=0` 且不 realloc；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf replace_first/last char within capacity 批次已补齐 `STRING_BUF_TRY_REPLACE_FIRST_CHAR_WITHIN_CAPACITY` / `STRING_BUF_REPLACE_FIRST_CHAR_WITHIN_CAPACITY`、`STRING_BUF_TRY_REPLACE_LAST_CHAR_WITHIN_CAPACITY` / `STRING_BUF_REPLACE_LAST_CHAR_WITHIN_CAPACITY`；将 scalar 编码为 UTF-8 needle 后复用 within-capacity first/last replace；非法 scalar/未命中/容量不足返回 `ok=0` 且不 realloc；不声明 Rust Pattern 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf extend chars/ascii within capacity 批次已补齐 `STRING_BUF_TRY_EXTEND_CHARS_WITHIN_CAPACITY_U64` / `STRING_BUF_EXTEND_CHARS_WITHIN_CAPACITY_U64`、`STRING_BUF_TRY_EXTEND_ASCII_CHARS_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_ASCII_CHARS_WITHIN_CAPACITY`；先校验全部 scalar/ASCII 并累计所需字节，仅在剩余容量足够时整段追加；非法值/容量不足返回 `ok=0` 且不 realloc；不声明 Pattern/iterator 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf extend char/ascii refs within capacity 批次已补齐 `STRING_BUF_TRY_EXTEND_CHAR_REFS_WITHIN_CAPACITY_U64` / `STRING_BUF_EXTEND_CHAR_REFS_WITHIN_CAPACITY_U64`、`STRING_BUF_TRY_EXTEND_ASCII_CHAR_REFS_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_ASCII_CHAR_REFS_WITHIN_CAPACITY`；从 ref slice 间接读取 scalar/ASCII 后做 all-or-nothing 容量校验与追加；非法值/容量不足返回 `ok=0` 且不 realloc；不声明 Pattern/iterator 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf replace_range char within capacity 批次已补齐 `STRING_BUF_TRY_REPLACE_RANGE_CHAR_WITHIN_CAPACITY` / `STRING_BUF_REPLACE_RANGE_CHAR_WITHIN_CAPACITY`；将 scalar 编码为 UTF-8 后复用 within-capacity replace_range；非法 scalar/越界/mid-scalar/容量不足返回 `ok=0` 且不 realloc；不声明 Rust Pattern 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf replace char first/last/range 批次已补齐 `STRING_BUF_TRY_REPLACE_FIRST_CHAR` / `STRING_BUF_REPLACE_FIRST_CHAR`、`STRING_BUF_TRY_REPLACE_LAST_CHAR` / `STRING_BUF_REPLACE_LAST_CHAR`、`STRING_BUF_TRY_REPLACE_RANGE_CHAR` / `STRING_BUF_REPLACE_RANGE_CHAR`；将 scalar 编码为 UTF-8 后复用现有 first/last/range replace；非法 scalar/未命中/越界返回 `ok=0`，可经非 WC 路径 realloc；不声明 Rust Pattern 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf remove_matches within capacity 批次已补齐 `STRING_BUF_TRY_REMOVE_MATCHES_WITHIN_CAPACITY` / `STRING_BUF_REMOVE_MATCHES_WITHIN_CAPACITY`、`STRING_BUF_TRY_REMOVE_MATCHES_CHAR_WITHIN_CAPACITY` / `STRING_BUF_REMOVE_MATCHES_CHAR_WITHIN_CAPACITY`；needle 先拷临时缓冲后原地压缩非匹配字节，空 needle 为成功 no-op；char 路径先编码 scalar，非法 scalar 返回 `ok=0` 且不 mutation；仅收缩不 realloc；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec splice + StringBuf retain within capacity 批次已补齐 `VEC_TRY_SPLICE_WITHIN_CAPACITY_U64` / `VEC_SPLICE_WITHIN_CAPACITY_U64`、`STRING_BUF_TRY_RETAIN_WITHIN_CAPACITY` / `STRING_BUF_RETAIN_WITHIN_CAPACITY`；Vec splice 在 cap 足够时原地 drain+右移+写入 replacement，容量不足/越界返回 `ok=0` 且不 mutation；String retain 原地压缩 retained UTF-8 scalars，解码失败返回 `ok=0`；不声明 lazy iterator 或 generic T 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec resize_with within capacity 批次已补齐 `VEC_TRY_RESIZE_WITH_WITHIN_CAPACITY_U64` / `VEC_RESIZE_WITH_WITHIN_CAPACITY_U64`；缩小时直接截断，增长仅在 `new_len <= cap` 时通过 generator 填充；容量不足返回 `ok=0` 且 len 不变；不声明 generic T/allocator 全覆盖；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf drain within capacity 批次已补齐 `STRING_BUF_TRY_DRAIN_WITHIN_CAPACITY` / `STRING_BUF_DRAIN_WITHIN_CAPACITY`；将合法 range 拷到新 StringBuf 后用 empty replace_range within capacity 从 owner 删除；非法 range 返回 `ok=0` 且不 mutation；仅收缩不 realloc；不声明 lazy drain iterator；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf splice within capacity 批次已补齐 `STRING_BUF_TRY_SPLICE_WITHIN_CAPACITY` / `STRING_BUF_SPLICE_WITHIN_CAPACITY`；先校验 char boundary 与新长度 cap，再拷出 drained range 并 within-capacity replace；容量不足/非法 range 返回 `ok=0` 且不 mutation；不声明 lazy splice iterator；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf pop_if 批次已补齐 `STRING_BUF_TRY_POP_BYTE_IF` / `STRING_BUF_POP_BYTE_IF`、`STRING_BUF_TRY_POP_CHAR_IF` / `STRING_BUF_POP_CHAR_IF`；对尾 byte/scalar 调用 predicate，仅命中时 pop；空串/解码失败/未命中返回 `ok=0` 且不 mutation；仅收缩；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf push_str_n within capacity 批次已补齐 `STRING_BUF_TRY_PUSH_STR_N_WITHIN_CAPACITY` / `STRING_BUF_PUSH_STR_N_WITHIN_CAPACITY`；先计算重复总字节并仅在剩余 cap 足够时整段追加 count 次；count=0 为成功 no-op，容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec extend_from_slice_n within capacity 批次已补齐 `VEC_TRY_EXTEND_FROM_SLICE_N_WITHIN_CAPACITY_U64` / `VEC_EXTEND_FROM_SLICE_N_WITHIN_CAPACITY_U64`；先计算重复总长度并仅在剩余 cap 足够时整段追加 count 次；count=0 为成功 no-op，容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec push_n within capacity 批次已补齐 `VEC_TRY_PUSH_N_WITHIN_CAPACITY` / `VEC_PUSH_N_WITHIN_CAPACITY`、`VEC_TRY_PUSH_N_WITHIN_CAPACITY_U64` / `VEC_PUSH_N_WITHIN_CAPACITY_U64`；先计算 `len+count` 并仅在 cap 足够时重复 push 同一值 count 次；count=0 为成功 no-op，容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf push_byte_n / push_char_n within capacity 批次已补齐 `STRING_BUF_TRY_PUSH_BYTE_N_WITHIN_CAPACITY` / `STRING_BUF_PUSH_BYTE_N_WITHIN_CAPACITY`、`STRING_BUF_TRY_PUSH_CHAR_N_WITHIN_CAPACITY` / `STRING_BUF_PUSH_CHAR_N_WITHIN_CAPACITY`；byte 复用 Vec push_n WC，char 先编码并校验 total width*count；count=0 为成功 no-op，非法 scalar/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec extend_from_within_n within capacity 批次已补齐 `VEC_TRY_EXTEND_FROM_WITHIN_N_WITHIN_CAPACITY_U64` / `VEC_EXTEND_FROM_WITHIN_N_WITHIN_CAPACITY_U64`；先校验 range 并计算 length*count，仅在 cap 足够时重复 extend_from_within count 次；count=0 为成功 no-op，非法 range/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf extend_from_within_n within capacity 批次已补齐 `STRING_BUF_TRY_EXTEND_FROM_WITHIN_N_WITHIN_CAPACITY` / `STRING_BUF_EXTEND_FROM_WITHIN_N_WITHIN_CAPACITY`；先校验 range 并计算 length*count，仅在 cap 足够时重复 extend_from_within count 次；count=0 为成功 no-op，非法 range/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec insert_n within capacity 批次已补齐 `VEC_TRY_INSERT_N_WITHIN_CAPACITY` / `VEC_INSERT_N_WITHIN_CAPACITY`、`VEC_TRY_INSERT_N_WITHIN_CAPACITY_U64` / `VEC_INSERT_N_WITHIN_CAPACITY_U64`；先校验 index 与 `len+count<=cap`，再在 index 起重复 insert 同一值 count 次；count=0 为成功 no-op，越界/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] StringBuf insert_n within capacity 批次已补齐 `STRING_BUF_TRY_INSERT_STR_N_WITHIN_CAPACITY` / `STRING_BUF_INSERT_STR_N_WITHIN_CAPACITY`、`STRING_BUF_TRY_INSERT_BYTE_N_WITHIN_CAPACITY` / `STRING_BUF_INSERT_BYTE_N_WITHIN_CAPACITY`、`STRING_BUF_TRY_INSERT_CHAR_N_WITHIN_CAPACITY` / `STRING_BUF_INSERT_CHAR_N_WITHIN_CAPACITY`；先校验 char boundary 与 insert_len*count 容量，再在 index 起重复 insert count 次；count=0 为成功 no-op，mid-scalar/非法 scalar/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec insert_from_slice within capacity 批次已补齐 `VEC_TRY_INSERT_FROM_SLICE_WITHIN_CAPACITY` / `VEC_INSERT_FROM_SLICE_WITHIN_CAPACITY`、`VEC_TRY_INSERT_FROM_SLICE_WITHIN_CAPACITY_U64` / `VEC_INSERT_FROM_SLICE_WITHIN_CAPACITY_U64`；先校验 index 与整段 slice 容量，再右移 tail 并原地拷贝；空 slice 为成功 no-op，越界/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] Vec insert_from_slice_n within capacity 批次已补齐 `VEC_TRY_INSERT_FROM_SLICE_N_WITHIN_CAPACITY` / `VEC_INSERT_FROM_SLICE_N_WITHIN_CAPACITY`、`VEC_TRY_INSERT_FROM_SLICE_N_WITHIN_CAPACITY_U64` / `VEC_INSERT_FROM_SLICE_N_WITHIN_CAPACITY_U64`；先校验 index 与 src_len*count 容量，再在 index 起重复 insert 整段 slice count 次；空 slice/count=0 为成功 no-op，越界/容量不足返回 `ok=0` 且不 mutation；已完成新增源码 focused 测试、安装态 focused 回归。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque::{get,front,back,try_front,try_back}` 显式 `u64`-named 视图别名 `VEC_DEQUE_GET_U64` / `VEC_DEQUE_FRONT_U64` / `VEC_DEQUE_TRY_FRONT_U64` / `VEC_DEQUE_BACK_U64` / `VEC_DEQUE_TRY_BACK_U64`，以及 Rust 1.87 `VecDeque::extra_capacity` 形态 `VEC_DEQUE_EXTRA_CAPACITY`（`capacity - len`，纯减法不申请内存）。
- [x] VecDeque u64 view aliases + extra_capacity 批次已完成新增源码 focused 测试、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 generic element support / scoped Rust references / splice-ranged iterator 语义。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque::resize` / `resize_with` 可支撑 eager 降阶 `VEC_DEQUE_RESIZE` / `VEC_DEQUE_RESIZE_U64` / `VEC_DEQUE_RESIZE_WITH` / `VEC_DEQUE_RESIZE_WITH_U64`；`new_len <= len` 走既有 `truncate` ABI，`new_len > len` 走既有 `push_back` 循环（后者接受 value 或 `() -> u64` generator）。
- [x] VecDeque resize / resize_with 批次已完成新增源码 focused 测试、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 generic element support / scoped Rust references / lazy splice-ranged iterator 语义 / allocator-aware `try_resize*` 变体。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 非重分配 resize-within-capacity 降阶 `VEC_DEQUE_TRY_RESIZE_WITHIN_CAPACITY` / `VEC_DEQUE_TRY_RESIZE_WITHIN_CAPACITY_U64` / `VEC_DEQUE_RESIZE_WITHIN_CAPACITY` / `VEC_DEQUE_RESIZE_WITHIN_CAPACITY_U64`，以及 generator 版 `VEC_DEQUE_TRY_RESIZE_WITH_WITHIN_CAPACITY` / `_U64` / `VEC_DEQUE_RESIZE_WITH_WITHIN_CAPACITY` / `_U64`；shrink 走 truncate，grow 先校验 `new_len <= cap`，不足则 `ok=0` 无 mutation。
- [x] VecDeque try_resize within capacity 批次已完成新增源码 focused 测试、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展、generic element support / scoped Rust references / lazy splice-ranged iterator 语义。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque::extend` 可支撑 within-capacity 降阶 `VEC_DEQUE_TRY_EXTEND_FROM_SLICE_U64` / `VEC_DEQUE_EXTEND_FROM_SLICE_U64` / `VEC_DEQUE_EXTEND_FROM_SLICE`；先校验 `len + src_len <= cap`，不足则 `ok=0` 无 mutation，足则通过既有 `sa_vec_deque_push_back` 循环 append（grow 路径不会触碰 runtime auto-grow 分支）。
- [x] VecDeque try_extend_from_slice within capacity 批次已完成新增源码 focused 测试（含 out-of-capacity 失败路径）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / lazy `extend` iterator / generic element support / scoped Rust references 语义。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 重复 extend within-capacity 降阶 `VEC_DEQUE_TRY_EXTEND_FROM_SLICE_N_WITHIN_CAPACITY_U64` / `VEC_DEQUE_EXTEND_FROM_SLICE_N_WITHIN_CAPACITY_U64`；先校验 `src_len * count + len <= cap`，不足则 `ok=0` 无 mutation，足则循环 `count` 次 `VEC_DEQUE_TRY_EXTEND_FROM_SLICE_U64`；`count=0` / `src_len=0` 为成功 no-op。
- [x] VecDeque try_extend_from_slice_n within capacity 批次已完成新增源码 focused 测试（含 `count=0` no-op 与 out-of-capacity 失败路径）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / lazy `extend` iterator / generic element support / scoped Rust references 语义。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 重复 push within-capacity 降阶 `VEC_DEQUE_TRY_PUSH_BACK_N_WITHIN_CAPACITY_U64` / `VEC_DEQUE_PUSH_BACK_N_WITHIN_CAPACITY_U64` / `VEC_DEQUE_TRY_PUSH_FRONT_N_WITHIN_CAPACITY_U64` / `VEC_DEQUE_PUSH_FRONT_N_WITHIN_CAPACITY_U64`；先校验 `len + count <= cap`，不足则 `ok=0` 无 mutation，足则循环 `count` 次 `sa_vec_deque_push_back/front`；`count=0` 为成功 no-op。
- [x] VecDeque push_n within capacity 批次已完成新增源码 focused 测试（含 back-grow、front-grow 环绕顺序校验、out-of-capacity 失败路径、`count=0` no-op）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / generic element support / scoped Rust references / lazy iterator allocator-aware 变体。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 非重分配单元素 insert within-capacity 降阶 `VEC_DEQUE_TRY_INSERT_WITHIN_CAPACITY` / `VEC_DEQUE_TRY_INSERT_WITHIN_CAPACITY_U64` / `VEC_DEQUE_INSERT_WITHIN_CAPACITY` / `VEC_DEQUE_INSERT_WITHIN_CAPACITY_U64`；先校验 `index <= len` 与 `len+1 <= cap`，不足或越界则 `ok=0` 无 mutation，足则通过既有 `sa_vec_deque_try_insert`（其内部 `reserve(1)` 因已预留容量变成整数 no-op）。
- [x] VecDeque insert within capacity 批次已完成新增源码 focused 测试（含 mid-insert、末端 insert 满容、out-of-capacity 失败、out-of-bounds index 失败）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / generic element support / slice-insert 变体 / scoped Rust references / allocator-aware `try_insert*` strict-failure 变体。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 非重分配重复值 insert within-capacity 降阶 `VEC_DEQUE_TRY_INSERT_N_WITHIN_CAPACITY` / `VEC_DEQUE_TRY_INSERT_N_WITHIN_CAPACITY_U64` / `VEC_DEQUE_INSERT_N_WITHIN_CAPACITY` / `VEC_DEQUE_INSERT_N_WITHIN_CAPACITY_U64`；先校验 `index <= len` 与 `len + count <= cap`，不足或越界则 `ok=0` 无 mutation，足则循环 `count` 次按 `index + i` 调用单元素 `VEC_DEQUE_TRY_INSERT_WITHIN_CAPACITY`；`count=0` 为成功 no-op。
- [x] VecDeque insert_n within capacity 批次已完成新增源码 focused 测试（含 3 元素重复 insert 满容、`count=0` no-op、out-of-capacity 失败、out-of-bounds index 失败）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / generic element support / slice-insert 变体 / scoped Rust references / allocator-aware `try_insert*` strict-failure 变体。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 非重分配整段 slice insert within-capacity 降阶 `VEC_DEQUE_TRY_INSERT_FROM_SLICE_WITHIN_CAPACITY` / `VEC_DEQUE_TRY_INSERT_FROM_SLICE_WITHIN_CAPACITY_U64` / `VEC_DEQUE_INSERT_FROM_SLICE_WITHIN_CAPACITY` / `VEC_DEQUE_INSERT_FROM_SLICE_WITHIN_CAPACITY_U64`；先校验 `index <= len` 与 `len + src_len <= cap`，不足或越界则 `ok=0` 无 mutation，足则循环 `src_len` 次按 `index + i` 从 src slice 取元素并调用单元素 `VEC_DEQUE_TRY_INSERT_WITHIN_CAPACITY`；空 slice 为成功 no-op。
- [x] VecDeque insert_from_slice within capacity 批次已完成新增源码 focused 测试（含 3 元素 slice 中段 insert 满容、空 slice no-op、out-of-capacity 失败、out-of-bounds index 失败）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / generic element support / repeated-slice-insert 变体 / scoped Rust references / allocator-aware `try_insert*` strict-failure 变体。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 非重分配重复整段 slice insert within-capacity 降阶 `VEC_DEQUE_TRY_INSERT_FROM_SLICE_N_WITHIN_CAPACITY` / `VEC_DEQUE_TRY_INSERT_FROM_SLICE_N_WITHIN_CAPACITY_U64` / `VEC_DEQUE_INSERT_FROM_SLICE_N_WITHIN_CAPACITY` / `VEC_DEQUE_INSERT_FROM_SLICE_N_WITHIN_CAPACITY_U64`；先校验 `index <= len` 与 `len + src_len*count <= cap`，不足或越界则 `ok=0` 无 mutation，足则循环 `count` 次按 `index + i*src_len` 调用整段 `VEC_DEQUE_TRY_INSERT_FROM_SLICE_WITHIN_CAPACITY`；`count=0` 与 `src_len=0` 均为成功 no-op。
- [x] VecDeque insert_from_slice_n within capacity 批次已完成新增源码 focused 测试（含 2 元素 slice 连插 2 次填满 8-cap、`count=0` no-op、空 slice no-op、out-of-capacity 失败、out-of-bounds index 失败）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust allocator 自动扩展 / generic element support / scoped Rust references / allocator-aware `try_insert*` strict-failure 变体。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 `VecDeque` 非重分配 `extend_chars` 别名 `VEC_DEQUE_TRY_EXTEND_CHARS_U64` / `VEC_DEQUE_EXTEND_CHARS_U64`，把 `Slice<u64>` 元素当作 Unicode scalar-value codepoint 复用现有 `VEC_DEQUE_TRY_EXTEND_FROM_SLICE_U64`（先校验 `len + src_len <= cap`，不足则 `ok=0` 无 mutation，足则循环 `src_len` 次 `sa_vec_deque_push_back` 各 codepoint）。
- [x] VecDeque extend_chars u64 别名批次已完成新增源码 focused 测试（含 6-cap 先 extend `[65,66,67]` 再 `[68,69]` 填至 len 5、再尝试 extend 因容量不足返回 `ok=0` 无 mutation）、安装态 focused 回归，四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust `char` 合法性校验（U+10FFFF/代理对原样透传）、不主张 Rust allocator 自动扩展 / lazy iterator / generic element / scoped Rust references / allocator-aware `try_extend*` strict-failure 变体。
- [x] `std::fs` Rust API parity 审计继续补齐：补 `std::fs::DirBuilder` builder 模式降阶 `FS_DIR_BUILDER_NEW` / `FS_DIR_BUILDER_WITH_RECURSIVE` / `FS_DIR_BUILDER_WITH_MODE` / `FS_DIR_BUILDER_CREATE`；builder 状态为两个传播式 SSA `u64`（`recursive` bool、POSIX `mode`），`NEW` 初始化 `recursive=false / mode=0o755`（Rust 默认），`WITH_RECURSIVE` 把任意非零 flag 归一为 `1` 并保留 `mode`，`WITH_MODE` 保留 `recursive` 并设新 `mode`，`CREATE` 按 `recursive` flag 分派现有 `FS_CREATE_DIR_MODE` / `FS_CREATE_DIR_ALL_MODE`，不新增 FFI/socketable 系统调用表。
- [x] fs DirBuilder 宏表面批次已完成新增源码 focused 测试（`std_fs_macro_surface.sa --filter 'DirBuilder'`：1 通过 8 跳过；全文件 9 passed 0 failed）、安装态 focused 回归（`SA_STD_DIR=/home/vscode/.sa/std` 下同 filter 通过），四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust owned `DirBuilder` move/build value 语义、返回目录句柄变体、Windows ACL 权限层、`Permissions`/`metadata`-style builder 方法。
- [x] `std::fs::OpenOptions` builder 模式降阶：补 `FS_OPEN_OPTIONS_BUILDER_NEW` / `FS_OPEN_OPTIONS_BUILDER_WITH_READ` / `_WITH_WRITE` / `_WITH_APPEND` / `_WITH_CREATE` / `_WITH_TRUNCATE` / `_WITH_MODE` / `_WITH_CUSTOM_FLAGS` / `_WITH_OPEN`；builder 状态为三个传播式 SSA `u64`（`flags`、POSIX `create_mode`、`custom_flags`），`NEW` 初始化 `OpenOptions::new()` 默认（全部 false），每个 `WITH_<flag>` 把任意非零 flag 归一为 set-bit OR、为零则 bit 不动（匹配 Rust `.x(true)` 习惯；`x(false)` clear-the-bit 暂不降阶），`WITH_OPEN` 委托现有 `FS_OPEN_OPTIONS` FFI 不新增 syscall 表面。
- [x] fs OpenOptions builder 宏表面批次已完成新增源码 focused 测试（`std_fs_macro_surface.sa --filter 'OpenOptions'`：1 通过 9 跳过；全文件 10 passed 0 failed；含 builder 位运算逐步断言 + write/create end-to-end 读写回校验）、安装态 focused 回归（`SA_STD_DIR=/home/vscode/.sa/std` 下同 filter 通过），四份文档（progress/tasks/current_plan/std_missing）同步更新；不主张 Rust `create_new` (`O_CREAT|O_EXCL`)（`SA_FS_CUSTOM_*` 未暴露 `O_EXCL`）、.`x(false)` clear-bit 降阶、跨平台 read-only truncate/append 边界、`set_permissions`-equivalent builder 方法、Windows ACL、owned builder move/build value 语义。
- [ ] Continue String/Vec audit for supportable gaps that map to explicit SA macro/runtime surfaces and focused macro-surface tests.

---

## 说明

- 带 `*` 的任务为可选 PBT；核心实现任务必做。
- 每条 PBT 显式标注 Property 编号（P1–P32）与验证的需求号。
- **版本分期的核心原则**：v0.1 只证明"能跑通"，v0.2 只证明"WASM 后端可自研"，v0.3 才谈"性能兑现"，v0.4 才谈"多人/多 LLM 并行协作"，v0.5 才谈"生态自给自足"，v0.6 才谈"/航空级形式化认证 + 数据库生态"。**不要把这七件事压在 14 周 MVP 里**。
- **v0.1 特别说明**：WASM 产线默认仍委托 `zig cc -target wasm32-wasi`，这意味着：
  - v0.1 的 `.wasm` 体积会比 v0.2 大（48 KB vs 32 KB），这是可接受的权衡
  - `wasm64` 先开放为 freestanding / no-entry 的纯计算路径，不承诺 WASI / I/O 支持；完整 memory64 产线仍归 v0.2
  - v0.1 的 WASI 映射由 Zig 自动完成，不手写（v0.2 手写后可精简）
  - 这一刀砍下去节省约 3-4 周时间
- **v0.6 特别说明**：sa-db 是 v0.5 包管理的自然延伸，复用所有既有基础设施（Referee、`#def`、`grants`、SHA-256、零权限默认）。12 周时间表假设 v0.5 已交付。
- **v0.7 特别说明**：原生单元测试框架（见本文件 Version 0.7 章节），与 v0.6 数据库无强依赖。
- **v0.8 特别说明**：sa_netx 是 v0.6 数据库的同构延伸（mmap 预分配 / SA-ASM 算子内核 / 零拷贝沙箱）。**SA-ASM ISA 零扩展**，**flattener / referee / verifier / common / 现有 sa_std 全部零修改**。所有新增能力落到 `src/runtime/sa_net_uring.zig`（新增）+ `sa_std/netx.*` 三件套（新增）。TLS 由前置 Nginx/Envoy 终结，本期不做 HTTP/2/3。12 周时间表假设 v0.5 + v0.6 已交付（v0.7 可并行）。
- **v0.9 特别说明**：SAX 是 SA 的**前端方言层**而非新语言。**SA-ASM ISA 零扩展**；当前实现已外置到 `/home/vscode/projects/sa_plugins/sa_plugin_sax`，主仓只保留共享工具链、宿主 loader 和 verifier hook。SAX Parser 直接输出**合法 `.sa` 文本**，不构造 AST。浏览器 WASM 当前通过 LLVM-C `.sa.bc` + Zig `wasm32-freestanding -fno-entry --import-symbols` 生成，DOM 通过气闸舱 `airlock.js` 唯一通道访问。Phase 1 已由 Counter / TodoList / dashboard / typed demos 闭环验证；Phase 2 已落地部分路由、生命周期和细粒度更新，仍缺 route mount/unmount、inotify/kqueue、热替换保留状态等验收；Phase 3 跨端继续未完成。
- 实现阶段打开 tasks.md 点击 "Start task" 按钮开始执行。

### Phase X: sa_std Macro Ergonomics & Standardization
- [x] Design and implement `sa_std/core/derive.sa` containing foundational macros for structural operations (e.g., shallow copy, field-wise equality).
- [x] Document the "Naming Contract" pattern for structures (e.g., standardizing `_CLONE`, `_FREE` suffixes for macros).
- [x] Refine and document the `[MACRO] DISPATCH` pattern as the preferred method for simulated dynamic dispatch (defunctionalization) to maintain O(1) ownership tracking by the Referee.
- [x] Prioritize the next macro wave for data-structure portability, in this order:
  1. container construction and field access (`STRUCT_NEW`, `FIELD_GET`, `FIELD_SET`, `STRUCT_FREE`, `PTR_FIELD`)
  2. `Option` / `Result` convenience helpers (`OPTION_MATCH_SOME_NONE`, `OPTION_UNWRAP_OR_RETURN`, `RESULT_MATCH_OK_ERR`, `RESULT_RETURN_ERR`, `RESULT_MAP_OK`, `RESULT_IS_OK` / `RESULT_IS_ERR`)
  3. loop / index sugar (`FOR_RANGE`, `WHILE`, `WHILE_COND`, `INDEX_LOOP`, `ARRAY_FOR_EACH`, `ARRAY_SCAN_MIN/MAX`, `SLICE_GET_U64`)
  4. bit / mask operations (`BIT_SET`, `BIT_GET`, `BIT_CLEAR`, `BIT_TEST`, `BIT_MASK`, `BIT_INDEX_BYTE`, `BIT_INDEX_BIT`)
  5. hash / probe helpers (`HASH_PTR`, `HASH_MIX`, `HASH_MOD`, `PROBE_START`, `PROBE_NEXT`, `MAP_LOOKUP`, `MAP_INSERT_OR_UPDATE`)
  6. resource cleanup sugar (`DEFER`, `CLEANUP_ON_ERROR`, `WITH_TEMP`, `RETURN_CLEAN`, `FREE_AND_RETURN`)
  7. structured control-flow sugar (`IF`, `ELSE`, `ELIF`, `MATCH_BOOL`, `MATCH_OPTION`, `MATCH_RESULT`, `WHILE_LET`, `BREAK_IF`, `CONTINUE_IF`)
  - Goal: keep future `trie` / `bloom_filter` / `segment_tree` / `graph` ports closer to Rust while still lowering to explicit labels, stores, and branches.

- [x] Implement `Arc<T>` macros in `sa_std/core/arc.sa` using atomic `add`/`sub` operations.
- [x] Refactor `RefCell` to support multiple simultaneous readers.
- [x] Implement `RwLock` in `sa_std/sync/rwlock.sa`.
- [x] Add `BOX_NEW`/`BOX_FREE` ergonomics to `sa_std/core/mem.sa`.
- [x] Wire `line!` / `file!` / `column!` / `module_path!` through the flattener macro path, and add SA unit coverage for source-location expansion.
- [x] Add `include!` SA coverage through `tests/include_macro_expand_unit.sa` and CLI smoke execution.

### sa_std Macro Priority Backlog: Data-Structure Portability Wave 2
- [x] Container construction and field access macros
  - `STRUCT_NEW`
  - `FIELD_GET`
  - `FIELD_SET`
  - `STRUCT_FREE`
  - `PTR_FIELD`
  - Priority: highest; target `stack` / `queue` / `heap` / `linked_list` / `union_find` / `hash_table` / `fenwick_tree` ports first.
- [x] `Option` / `Result` convenience macros
  - `OPTION_MATCH_SOME_NONE`
  - `OPTION_UNWRAP_OR_RETURN`
  - `RESULT_MATCH_OK_ERR`
  - `RESULT_RETURN_ERR`
  - `RESULT_MAP_OK`
  - `RESULT_IS_OK` / `RESULT_IS_ERR`
  - Priority: high; target `trie` / `bloom_filter` / `segment_tree` / `graph` next.
- [x] Loop and index macros
  - `FOR_RANGE`
  - `WHILE`
  - `WHILE_COND`
  - `INDEX_LOOP`
  - `ARRAY_FOR_EACH`
  - `ARRAY_SCAN_MIN/MAX`
  - `SLICE_GET_U64`
  - Priority: high; use to cut `jmp` / `branch` / `idx_slot` boilerplate and reduce `PhiStateConflict` risk.
- [x] Bit and mask macros
  - `BIT_SET`
  - `BIT_GET`
  - `BIT_CLEAR`
  - `BIT_TEST`
  - `BIT_MASK`
  - `BIT_INDEX_BYTE`
  - `BIT_INDEX_BIT`
  - Priority: medium-high; target `bloom_filter` / `bitset` / `bitmap` / compressed segment-tree layouts.
- [x] Hash and probe macros
  - `HASH_PTR`
  - `HASH_MIX`
  - `HASH_MOD`
  - `PROBE_START`
  - `PROBE_NEXT`
  - `MAP_LOOKUP`
  - `MAP_INSERT_OR_UPDATE`
  - Priority: medium-high; target `hashmap` / `hashset` / `bloom_filter` / `count_min_sketch`.
- [x] Resource cleanup macros
  - `DEFER`
  - `CLEANUP_ON_ERROR`
  - `WITH_TEMP`
  - `RETURN_CLEAN`
  - `FREE_AND_RETURN`
  - Priority: medium; make temp alloc cleanup and error-path teardown explicit and repeatable.
- [x] Structured control-flow sugar
  - `IF`
  - `ELSE`
  - `ELIF`
  - `MATCH_BOOL`
  - `MATCH_OPTION`
  - `MATCH_RESULT`
  - `WHILE_LET`
  - `BREAK_IF`
  - `CONTINUE_IF`
  - Priority: lower than the data-structure helpers; keep the expansion thin and label-based.
  - 说明：`src/flattener/line_classifier.zig` 已识别 `[IF]` / `[ELSE]` / `[END_IF]`，`src/flattener.zig` 的 `macro-time conditionals select then else and nested branches` 单测覆盖 then/else/nested/reject 路径；`sa_std/core/control.sa`、`sa_std/core/option.sa`、`sa_std/core/result.sa` 已提供其余宏，`tests/rust_core_unit.sa` 与 `tests/std_smoke_core.zig` 有对应用例/存在性覆盖。验证命令：`zig test src/flattener.zig` 通过 61/61；`zig build std-smoke --summary all` 仍因已知 Deno/HTTP 链接符号 `sa_http_client_resp_body_slice` 失败，非本项失败。
- [x] Add SA unit tests for every new macro family as soon as it lands
  - Smoke coverage for expansion presence
  - Behavior coverage for success / failure / cleanup paths
  - Keep the tests in `tests/rust_core_unit.sa` or adjacent macro-specific SA tests
- [x] `VecDeque` Rust API parity 审计继续补齐：补 Rust-named `VecDeque::push_back_mut` / `push_front_mut` 降阶别名 `VEC_DEQUE_PUSH_BACK_MUT` / `VEC_DEQUE_PUSH_FRONT_MUT`，转发到既有 raw-pointer slot helper，保持当前具体 `u64` 槽位指针语义。
- [x] VecDeque push_mut alias 批次已新增 focused 测试 `std_vec_deque_push_mut_alias_macro_surface.sa`（panic ID 10699）并同步 progress/current_plan/std_missing；不主张 scoped Rust mutable references / generic `VecDeque<T>` / borrow lifetime 语义。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 Rust-named `VecDeque::get_mut` / `insert_mut` 降阶别名 `VEC_DEQUE_GET_MUT_PTR` / `VEC_DEQUE_GET_MUT` / `VEC_DEQUE_INSERT_MUT`，复用既有 checked raw-pointer helper，保持当前具体 `u64` 槽位 `(ok, ptr)` 语义。
- [x] VecDeque mut-slot alias 批次已新增 focused 测试 `std_vec_deque_mut_alias_macro_surface.sa`（panic ID 10700）并同步 progress/current_plan/std_missing；不主张 Rust `Option<&mut T>` / panic object / scoped lifetime / generic `VecDeque<T>` 语义。
- [x] `VecDeque` Rust API parity 审计继续补齐：补 Rust-named `VecDeque::front_mut` / `back_mut` 降阶别名 `VEC_DEQUE_FRONT_MUT` / `VEC_DEQUE_BACK_MUT`，复用既有 checked raw-pointer front/back helper，保持当前具体 `u64` 槽位 `(ok, ptr)` 语义。
- [x] VecDeque front/back mut alias 批次已新增 focused 测试 `std_vec_deque_front_back_mut_alias_macro_surface.sa`（panic ID 10824）并同步 progress/current_plan/std_missing；不主张 Rust `Option<&mut T>` / scoped lifetime / aliasing guarantees / generic `VecDeque<T>` 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 unstable `BinaryHeap::pop_if` 降阶宏 `BINARY_HEAP_TRY_POP_IF_U64` / `BINARY_HEAP_POP_IF_U64`，复用既有 try-peek/try-pop，保持当前具体 `u64` max-heap 的 `(ok, value)` 语义。
- [x] BinaryHeap pop_if 批次新增 focused 测试 `std_binary_heap_pop_if_macro_surface.sa`（panic ID 10701）并同步 progress/current_plan/std_missing；不主张 Rust `Option<T>` 布局 / generic `BinaryHeap<T>` / borrow lifetime / predicate unwind/drop 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 `BinaryHeap::iter` 具体降阶宏 `BINARY_HEAP_ITER_U64`，复用既有 heap `as_slice` 和 slice-backed `Iter`，按内部 heap-array order 读取且不消费 heap。
- [x] BinaryHeap iter 批次新增 focused 测试 `std_binary_heap_iter_macro_surface.sa`（panic ID 10702）并同步 progress/current_plan/std_missing；不主张 Rust generic `Iter<'_, T>` / borrow lifetime / owned `IntoIterator` / lazy drain 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 `IntoIterator for &BinaryHeap` 和 `Default for binary_heap::Iter` 具体降阶宏 `BINARY_HEAP_REF_INTO_ITER_U64` / `BINARY_HEAP_ITER_DEFAULT_U64`，都复用现有 slice-backed `Iter`。
- [x] BinaryHeap iterator alias 批次新增 focused 测试 `std_binary_heap_iter_alias_macro_surface.sa`（panic ID 10703）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / reference lifetime / iterator trait object / owned `IntoIterator` 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 `binary_heap::Iter` concrete `Clone` / `Iterator` / `DoubleEndedIterator` / `ExactSizeIterator` 降阶别名 `BINARY_HEAP_ITER_CLONE_U64`、`BINARY_HEAP_ITER_NEXT_U64`、`BINARY_HEAP_ITER_NEXT_BACK_U64`、`BINARY_HEAP_ITER_SIZE_HINT_U64`、`BINARY_HEAP_ITER_EXACT_SIZE_LEN_U64`、`BINARY_HEAP_ITER_EXACT_SIZE_IS_EMPTY_U64`。
- [x] BinaryHeap Iter trait/clone 批次新增 focused 测试 `std_binary_heap_iter_trait_clone_macro_surface.sa`（panic ID 10733）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / borrowed reference item ABI / lifetime enforcement / iterator object layout 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 consuming `IntoIterator for BinaryHeap` 具体降阶宏 `BINARY_HEAP_INTO_ITER_U64`，消费 heap 到显式 backing `Vec<u64>` 并在该 Vec 上建立 slice-backed `Iter`。
- [x] BinaryHeap into_iter 批次新增 focused 测试 `std_binary_heap_into_iter_macro_surface.sa`（panic ID 10704）并同步 progress/current_plan/std_missing；不主张 Rust owned `IntoIter<T,A>` object layout / generic `T` / allocator parameter / 隐式 drop glue 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 unstable `BinaryHeap::into_iter_sorted` 具体降阶宏 `BINARY_HEAP_INTO_ITER_SORTED_U64`，消费 heap 并生成降序 backing `Vec<u64>`，使 forward iterator 最大值优先。
- [x] BinaryHeap into_iter_sorted 批次新增 focused 测试 `std_binary_heap_into_iter_sorted_macro_surface.sa`（panic ID 10705）并同步 progress/current_plan/std_missing；不主张 Rust `IntoIterSorted<T,A>` object layout / lazy pop-on-next / generic `T` / allocator parameter 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `Vec::iter` / `Vec::iter_mut` / `IntoIterator for &Vec` / `IntoIterator for &mut Vec` 具体 U64 降阶宏 `VEC_ITER_U64` / `VEC_ITER_MUT_U64` / `VEC_REF_INTO_ITER_U64` / `VEC_MUT_REF_INTO_ITER_U64`，并补 `VEC_ITER_DEFAULT_U64` 空 cursor。
- [x] Vec iterator alias 批次新增 focused 测试 `std_vec_iter_macro_surface.sa`（panic ID 10706）并同步 progress/current_plan/std_missing；不主张 Rust reference item type / borrow lifetime / owned `IntoIter<T,A>` object layout / generic `T` / allocator parameter 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `slice::Iter` / `Vec::iter` concrete `AsRef<[T]>` / `Clone` / `Iterator` / `DoubleEndedIterator` / `ExactSizeIterator` 降阶别名 `VEC_ITER_AS_REF_SLICE_U64`、`VEC_ITER_CLONE_U64`、`VEC_ITER_NEXT_U64`、`VEC_ITER_NEXT_BACK_U64`、`VEC_ITER_SIZE_HINT_U64`、`VEC_ITER_EXACT_SIZE_LEN_U64`、`VEC_ITER_EXACT_SIZE_IS_EMPTY_U64`。
- [x] Vec Iter trait/clone 批次新增 focused 测试 `std_vec_iter_trait_clone_macro_surface.sa`（panic ID 10734）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / borrowed reference item ABI / lifetime enforcement / mutable iterator clone 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `slice::IterMut` / `Vec::iter_mut` concrete `AsRef<[T]>` / unstable `as_mut_slice` / `Iterator` / `DoubleEndedIterator` / `ExactSizeIterator` 降阶别名 `VEC_ITER_MUT_AS_REF_SLICE_U64`、`VEC_ITER_MUT_AS_MUT_SLICE_U64`、`VEC_ITER_MUT_NEXT_U64`、`VEC_ITER_MUT_NEXT_BACK_U64`、`VEC_ITER_MUT_SIZE_HINT_U64`、`VEC_ITER_MUT_EXACT_SIZE_LEN_U64`、`VEC_ITER_MUT_EXACT_SIZE_IS_EMPTY_U64`。
- [x] Vec IterMut trait 批次新增 focused 测试 `std_vec_iter_mut_trait_macro_surface.sa`（panic ID 10735）并同步 progress/current_plan/std_missing；不主张 Rust `&mut T` item ABI / lifetime enforcement / aliasing rules / `IterMut` Clone 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `IntoIterator for &[T; N]` / `IntoIterator for &mut [T; N]` 背后的 concrete borrowed `slice::Iter<u64>` / `slice::IterMut<u64>` trait 降阶别名 `ARRAY_ITER_AS_REF_SLICE_U64`、`ARRAY_ITER_CLONE_U64`、`ARRAY_ITER_NEXT_U64`、`ARRAY_ITER_NEXT_BACK_U64`、`ARRAY_ITER_SIZE_HINT_U64`、`ARRAY_ITER_EXACT_SIZE_LEN_U64`、`ARRAY_ITER_EXACT_SIZE_IS_EMPTY_U64`、`ARRAY_ITER_MUT_AS_REF_SLICE_U64`、`ARRAY_ITER_MUT_AS_MUT_SLICE_U64`、`ARRAY_ITER_MUT_NEXT_U64`、`ARRAY_ITER_MUT_NEXT_BACK_U64`、`ARRAY_ITER_MUT_SIZE_HINT_U64`、`ARRAY_ITER_MUT_EXACT_SIZE_LEN_U64`、`ARRAY_ITER_MUT_EXACT_SIZE_IS_EMPTY_U64`。
- [x] Array Iter trait 批次新增 focused 测试 `std_array_iter_trait_macro_surface.sa`（panic ID 10736）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / borrowed reference item ABI / lifetime enforcement / aliasing rules / `IterMut` Clone 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 owned `IntoIterator for [T; N]` / `array::IntoIter` concrete U64 降阶宏 `ARRAY_INTO_ITER_U64`、`ARRAY_INTO_ITER_NEW_U64`、`ARRAY_INTO_ITER_EMPTY_U64`、`ARRAY_INTO_ITER_DEFAULT_U64`、`ARRAY_INTO_ITER_AS_SLICE_U64`、`ARRAY_INTO_ITER_AS_MUT_SLICE_U64`、`ARRAY_INTO_ITER_AS_REF_SLICE_U64`、`ARRAY_INTO_ITER_CLONE_U64`、`ARRAY_INTO_ITER_NEXT_U64`、`ARRAY_INTO_ITER_NEXT_BACK_U64`、`ARRAY_INTO_ITER_SIZE_HINT_U64`、`ARRAY_INTO_ITER_EXACT_SIZE_LEN_U64`、`ARRAY_INTO_ITER_EXACT_SIZE_IS_EMPTY_U64`。
- [x] Array IntoIter 批次新增 focused 测试 `std_array_into_iter_macro_surface.sa`（panic ID 10737）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / MaybeUninit alive-range ABI / drop glue / const-generic type identity 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete cursor op 降阶别名 `ARRAY_INTO_ITER_NTH_U64`、`ARRAY_INTO_ITER_NTH_BACK_U64`、`ARRAY_INTO_ITER_TRY_NEXT_CHUNK_U64`、`ARRAY_INTO_ITER_COUNT_U64`、`ARRAY_INTO_ITER_LAST_U64`、`ARRAY_INTO_ITER_ADVANCE_BY`、`ARRAY_INTO_ITER_ADVANCE_BACK_BY`。
- [x] Array IntoIter cursor ops 批次新增 focused 测试 `std_array_into_iter_cursor_ops_macro_surface.sa`（panic ID 10738）并同步 progress/current_plan/std_missing；不主张 Rust `Result<(), NonZero<usize>>` ABI / const-generic chunk remainder ABI / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete fold 降阶别名 `ARRAY_INTO_ITER_FOLD_U64`、`ARRAY_INTO_ITER_TRY_FOLD_U64`、`ARRAY_INTO_ITER_RFOLD_U64`、`ARRAY_INTO_ITER_TRY_RFOLD_U64`。
- [x] Array IntoIter fold 批次新增 focused 测试 `std_array_into_iter_fold_macro_surface.sa`（panic ID 10739）并同步 progress/current_plan/std_missing；不主张 Rust closure capture / generic `Try` residual / panic-drop cleanup / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete aggregate/reduce 降阶别名 `ARRAY_INTO_ITER_SUM_U64`、`ARRAY_INTO_ITER_PRODUCT_U64`、`ARRAY_INTO_ITER_MIN_U64`、`ARRAY_INTO_ITER_MAX_U64`、`ARRAY_INTO_ITER_REDUCE_U64`、`ARRAY_INTO_ITER_TRY_REDUCE_U64`。
- [x] Array IntoIter aggregate/reduce 批次新增 focused 测试 `std_array_into_iter_aggregate_macro_surface.sa`（panic ID 10740）并同步 progress/current_plan/std_missing；不主张 Rust `Sum` / `Product` / `Ord` trait dispatch / `Option<T>` ABI / generic `Try` residual / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete comparator/key aggregate 降阶别名 `ARRAY_INTO_ITER_MIN_BY_U64`、`ARRAY_INTO_ITER_MAX_BY_U64`、`ARRAY_INTO_ITER_MIN_BY_KEY_U64`、`ARRAY_INTO_ITER_MAX_BY_KEY_U64`。
- [x] Array IntoIter comparator/key aggregate 批次新增 focused 测试 `std_array_into_iter_min_max_by_macro_surface.sa`（panic ID 10741）并同步 progress/current_plan/std_missing；不主张 Rust `Option<T>` ABI / generic `Ord` trait dispatch / closure capture / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete search/predicate 降阶别名 `ARRAY_INTO_ITER_FIND_U64`、`ARRAY_INTO_ITER_TRY_FIND_U64`、`ARRAY_INTO_ITER_FIND_MAP_U64`、`ARRAY_INTO_ITER_POSITION_U64`、`ARRAY_INTO_ITER_RPOSITION_U64`、`ARRAY_INTO_ITER_RFIND_U64`、`ARRAY_INTO_ITER_ANY_U64`、`ARRAY_INTO_ITER_ALL_U64`。
- [x] Array IntoIter search/predicate 批次新增 focused 测试 `std_array_into_iter_search_macro_surface.sa`（panic ID 10742）并同步 progress/current_plan/std_missing；不主张 Rust `Option<T>` / `Option<usize>` ABI / generic `Try` residual / closure capture / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete for_each 降阶别名 `ARRAY_INTO_ITER_FOR_EACH_U64`、`ARRAY_INTO_ITER_TRY_FOR_EACH_U64`。
- [x] Array IntoIter for_each 批次新增 focused 测试 `std_array_into_iter_for_each_macro_surface.sa`（panic ID 10743）并同步 progress/current_plan/std_missing；不主张 Rust closure capture / generic `Try` residual / panic-drop cleanup / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete sortedness 降阶别名 `ARRAY_INTO_ITER_IS_SORTED_U64`、`ARRAY_INTO_ITER_IS_SORTED_BY_U64`、`ARRAY_INTO_ITER_IS_SORTED_BY_KEY_U64`。
- [x] Array IntoIter sortedness 批次新增 focused 测试 `std_array_into_iter_sorted_macro_surface.sa`（panic ID 10744）并同步 progress/current_plan/std_missing；不主张 Rust generic `Ord` / closure capture / borrowed reference item / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete lexicographic comparison 降阶别名 `ARRAY_INTO_ITER_CMP_U64`、`ARRAY_INTO_ITER_CMP_BY_U64`、`ARRAY_INTO_ITER_PARTIAL_CMP_U64`、`ARRAY_INTO_ITER_PARTIAL_CMP_BY_U64`、`ARRAY_INTO_ITER_EQ_BY_U64`、`ARRAY_INTO_ITER_EQ_U64`、`ARRAY_INTO_ITER_PARTIAL_EQ_U64`、`ARRAY_INTO_ITER_NE_U64`、`ARRAY_INTO_ITER_LT_U64`、`ARRAY_INTO_ITER_LE_U64`、`ARRAY_INTO_ITER_GT_U64`、`ARRAY_INTO_ITER_GE_U64`。
- [x] Array IntoIter comparison 批次新增 focused 测试 `std_array_into_iter_comparison_macro_surface.sa`（panic ID 10745）并同步 progress/current_plan/std_missing；不主张 Rust `Option<Ordering>` ABI / generic `Ord` / `PartialOrd` / closure capture / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete materializing collect 降阶别名 `ARRAY_INTO_ITER_COLLECT_U64`、`ARRAY_INTO_ITER_TRY_COLLECT_U64`、`ARRAY_INTO_ITER_COLLECT_INTO_U64`。
- [x] Array IntoIter collect 批次新增 focused 测试 `std_array_into_iter_collect_macro_surface.sa`（panic ID 10746）并同步 progress/current_plan/std_missing；不主张 Rust generic `FromIterator` / `Try` residual / `Result` ABI / allocator-parametric collect 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete eager adapter collect 降阶别名 `ARRAY_INTO_ITER_TAKE_COLLECT_U64`、`ARRAY_INTO_ITER_SKIP_COLLECT_U64`、`ARRAY_INTO_ITER_REV_COLLECT_U64`、`ARRAY_INTO_ITER_TRY_STEP_BY_COLLECT_U64`、`ARRAY_INTO_ITER_STEP_BY_COLLECT_U64`。
- [x] Array IntoIter adapter collect 批次新增 focused 测试 `std_array_into_iter_adapter_collect_macro_surface.sa`（panic ID 10747）并同步 progress/current_plan/std_missing；不主张 Rust lazy adapter identity / generic `Iterator<Item=T>` / panic object / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete transform/filter eager collect 降阶别名 `ARRAY_INTO_ITER_MAP_COLLECT_U64`、`ARRAY_INTO_ITER_INSPECT_COLLECT_U64`、`ARRAY_INTO_ITER_SCAN_COLLECT_U64`、`ARRAY_INTO_ITER_FILTER_COLLECT_U64`、`ARRAY_INTO_ITER_FILTER_MAP_COLLECT_U64`、`ARRAY_INTO_ITER_MAP_WHILE_COLLECT_U64`。
- [x] Array IntoIter transform collect 批次新增 focused 测试 `std_array_into_iter_transform_collect_macro_surface.sa`（panic ID 10748）并同步 progress/current_plan/std_missing；不主张 Rust lazy adapter identity / closure capture / generic `Option` / generic `Iterator<Item=T>` / generic item move/drop 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 consuming `IntoIterator for Vec` 具体 U64 降阶宏 `VEC_INTO_ITER_U64`，消费 Vec 到显式 backing `Vec<u64>` 并在该 Vec 上建立 slice-backed `Iter`。
- [x] Vec into_iter 批次新增 focused 测试 `std_vec_into_iter_macro_surface.sa`（panic ID 10707）并同步 progress/current_plan/std_missing；不主张 Rust owned `IntoIter<T,A>` object layout / generic `T` / allocator parameter / 隐式 drop glue 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `Default for vec::IntoIter` 具体 U64 降阶宏 `VEC_INTO_ITER_DEFAULT_U64`，创建空 backing `Vec<u64>` 和空 slice-backed cursor。
- [x] Vec IntoIter default 批次新增 focused 测试 `std_vec_into_iter_default_macro_surface.sa`（panic ID 10708）并同步 progress/current_plan/std_missing；不主张 Rust owned `IntoIter<T,A>` object layout / generic `T` / allocator parameter / 隐式 drop glue 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter::as_slice` / `as_mut_slice` 具体 U64 降阶宏 `VEC_INTO_ITER_AS_SLICE_U64` / `VEC_INTO_ITER_AS_MUT_SLICE_U64`，暴露当前 remaining cursor range 的 Slice view。
- [x] Vec IntoIter slice-view 批次新增 focused 测试 `std_vec_into_iter_slice_macro_surface.sa`（panic ID 10709）并同步 progress/current_plan/std_missing；不主张 Rust borrow lifetime / reference item type / owned `IntoIter<T,A>` object layout / allocator parameter 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `Clone for vec::IntoIter` 具体 U64 降阶宏 `VEC_INTO_ITER_CLONE_U64`，从当前剩余 cursor slice 克隆到新的显式 backing `Vec<u64>` 并建立新 cursor。
- [x] Vec IntoIter clone 批次新增 focused 测试 `std_vec_into_iter_clone_macro_surface.sa`（panic ID 10710）并同步 progress/current_plan/std_missing；不主张 Rust generic `T: Clone` / allocator cloning / owned `IntoIter<T,A>` object layout / borrow lifetime / drop glue 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 `AsRef<[T]>` / `Iterator::size_hint` / `ExactSizeIterator` 具体 U64 降阶别名 `VEC_INTO_ITER_AS_REF_SLICE_U64` / `VEC_INTO_ITER_SIZE_HINT_U64` / `VEC_INTO_ITER_EXACT_SIZE_LEN_U64` / `VEC_INTO_ITER_EXACT_SIZE_IS_EMPTY_U64`。
- [x] Vec IntoIter trait alias 批次新增 focused 测试 `std_vec_into_iter_trait_alias_macro_surface.sa`（panic ID 10711）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / `Option<usize>` ABI / marker trait wiring / owned `IntoIter<T,A>` object layout / borrow lifetime / drop glue 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete cursor op 降阶别名 `VEC_INTO_ITER_NEXT_U64` / `VEC_INTO_ITER_NEXT_BACK_U64` / `VEC_INTO_ITER_NTH_U64` / `VEC_INTO_ITER_NTH_BACK_U64` / `VEC_INTO_ITER_COUNT_U64` / `VEC_INTO_ITER_LAST_U64` / `VEC_INTO_ITER_ADVANCE_BY` / `VEC_INTO_ITER_ADVANCE_BACK_BY`。
- [x] Vec IntoIter cursor ops 批次新增 focused 测试 `std_vec_into_iter_cursor_ops_macro_surface.sa`（panic ID 10712）并同步 progress/current_plan/std_missing；不主张 Rust `Option<T>` / `Result<(), NonZero<usize>>` ABI / generic `T` / owned `IntoIter<T,A>` object layout / drop glue 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete fold op 降阶别名 `VEC_INTO_ITER_FOLD_U64` / `VEC_INTO_ITER_TRY_FOLD_U64` / `VEC_INTO_ITER_RFOLD_U64` / `VEC_INTO_ITER_TRY_RFOLD_U64`。
- [x] Vec IntoIter fold ops 批次新增 focused 测试 `std_vec_into_iter_fold_macro_surface.sa`（panic ID 10713）并同步 progress/current_plan/std_missing；不主张 Rust closure capture / generic `Try` residual / panic-drop cleanup / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete aggregate/reduce 降阶别名 `VEC_INTO_ITER_SUM_U64` / `VEC_INTO_ITER_PRODUCT_U64` / `VEC_INTO_ITER_MIN_U64` / `VEC_INTO_ITER_MAX_U64` / `VEC_INTO_ITER_REDUCE_U64` / `VEC_INTO_ITER_TRY_REDUCE_U64`。
- [x] Vec IntoIter aggregate ops 批次新增 focused 测试 `std_vec_into_iter_aggregate_macro_surface.sa`（panic ID 10714）并同步 progress/current_plan/std_missing；不主张 Rust `Sum` / `Product` / `Ord` trait dispatch / `Option<T>` ABI / generic `Try` residual / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete search/predicate 降阶别名 `VEC_INTO_ITER_FIND_U64` / `VEC_INTO_ITER_TRY_FIND_U64` / `VEC_INTO_ITER_FIND_MAP_U64` / `VEC_INTO_ITER_POSITION_U64` / `VEC_INTO_ITER_RPOSITION_U64` / `VEC_INTO_ITER_RFIND_U64` / `VEC_INTO_ITER_ANY_U64` / `VEC_INTO_ITER_ALL_U64`。
- [x] Vec IntoIter search/predicate ops 批次新增 focused 测试 `std_vec_into_iter_search_macro_surface.sa`（panic ID 10715）并同步 progress/current_plan/std_missing；不主张 Rust closure capture / generic `Try` residual / `Option<T>` / `Option<usize>` ABI / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete for_each 降阶别名 `VEC_INTO_ITER_FOR_EACH_U64` / `VEC_INTO_ITER_TRY_FOR_EACH_U64`。
- [x] Vec IntoIter for_each ops 批次新增 focused 测试 `std_vec_into_iter_for_each_macro_surface.sa`（panic ID 10716）并同步 progress/current_plan/std_missing；不主张 Rust closure capture / generic `Try` residual / panic-drop cleanup / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete comparator/key 降阶别名 `VEC_INTO_ITER_MIN_BY_U64` / `VEC_INTO_ITER_MAX_BY_U64` / `VEC_INTO_ITER_MIN_BY_KEY_U64` / `VEC_INTO_ITER_MAX_BY_KEY_U64`。
- [x] Vec IntoIter min/max-by ops 批次新增 focused 测试 `std_vec_into_iter_min_max_by_macro_surface.sa`（panic ID 10717）并同步 progress/current_plan/std_missing；不主张 Rust `Option<T>` ABI / generic `Ord` / closure capture / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete sortedness 降阶别名 `VEC_INTO_ITER_IS_SORTED_U64` / `VEC_INTO_ITER_IS_SORTED_BY_U64` / `VEC_INTO_ITER_IS_SORTED_BY_KEY_U64`。
- [x] Vec IntoIter sortedness ops 批次新增 focused 测试 `std_vec_into_iter_sorted_macro_surface.sa`（panic ID 10718）并同步 progress/current_plan/std_missing；不主张 Rust generic `Ord` / closure capture / borrowed reference item / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete lexicographic comparison 降阶别名 `VEC_INTO_ITER_CMP_U64` / `VEC_INTO_ITER_CMP_BY_U64` / `VEC_INTO_ITER_PARTIAL_CMP_U64` / `VEC_INTO_ITER_PARTIAL_CMP_BY_U64` / `VEC_INTO_ITER_EQ_BY_U64` / `VEC_INTO_ITER_EQ_U64` / `VEC_INTO_ITER_PARTIAL_EQ_U64` / `VEC_INTO_ITER_NE_U64` / `VEC_INTO_ITER_LT_U64` / `VEC_INTO_ITER_LE_U64` / `VEC_INTO_ITER_GT_U64` / `VEC_INTO_ITER_GE_U64`。
- [x] Vec IntoIter comparison ops 批次新增 focused 测试 `std_vec_into_iter_comparison_macro_surface.sa`（panic ID 10719）并同步 progress/current_plan/std_missing；不主张 Rust `Option<Ordering>` ABI / generic `Ord` / `PartialOrd` / closure capture / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete materializing collect 降阶别名 `VEC_INTO_ITER_COLLECT_U64` / `VEC_INTO_ITER_TRY_COLLECT_U64` / `VEC_INTO_ITER_COLLECT_INTO_U64`。
- [x] Vec IntoIter collect ops 批次新增 focused 测试 `std_vec_into_iter_collect_macro_surface.sa`（panic ID 10720）并同步 progress/current_plan/std_missing；不主张 Rust generic `FromIterator` / `Try` residual / `Result` ABI / allocator-parametric collect 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete eager adapter collect 降阶别名 `VEC_INTO_ITER_TAKE_COLLECT_U64` / `VEC_INTO_ITER_SKIP_COLLECT_U64` / `VEC_INTO_ITER_REV_COLLECT_U64` / `VEC_INTO_ITER_TRY_STEP_BY_COLLECT_U64` / `VEC_INTO_ITER_STEP_BY_COLLECT_U64`。
- [x] Vec IntoIter adapter collect ops 批次新增 focused 测试 `std_vec_into_iter_adapter_collect_macro_surface.sa`（panic ID 10721）并同步 progress/current_plan/std_missing；不主张 Rust lazy adapter identity / generic `Iterator<Item=T>` / panic object / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete transform/filter eager collect 降阶别名 `VEC_INTO_ITER_MAP_COLLECT_U64` / `VEC_INTO_ITER_INSPECT_COLLECT_U64` / `VEC_INTO_ITER_SCAN_COLLECT_U64` / `VEC_INTO_ITER_FILTER_COLLECT_U64` / `VEC_INTO_ITER_FILTER_MAP_COLLECT_U64` / `VEC_INTO_ITER_MAP_WHILE_COLLECT_U64`。
- [x] Vec IntoIter transform collect ops 批次新增 focused 测试 `std_vec_into_iter_transform_collect_macro_surface.sa`（panic ID 10722）并同步 progress/current_plan/std_missing；不主张 Rust lazy adapter identity / closure capture / generic `Option` / generic `Iterator<Item=T>` / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete sequence eager collect 降阶别名 `VEC_INTO_ITER_INTERSPERSE_COLLECT_U64` / `VEC_INTO_ITER_INTERSPERSE_WITH_COLLECT_U64` / `VEC_INTO_ITER_CYCLE_TAKE_COLLECT_U64` / `VEC_INTO_ITER_TAKE_WHILE_COLLECT_U64` / `VEC_INTO_ITER_SKIP_WHILE_COLLECT_U64`。
- [x] Vec IntoIter sequence collect ops 批次新增 focused 测试 `std_vec_into_iter_sequence_collect_macro_surface.sa`（panic ID 10723）并同步 progress/current_plan/std_missing；不主张 Rust lazy `Cycle` / `Intersperse` / `TakeWhile` / `SkipWhile` adapter identity、generic closure capture、owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete pair/composition eager collect 降阶别名 `VEC_INTO_ITER_ENUMERATE_COLLECT_U64` / `VEC_INTO_ITER_ZIP_COLLECT_U64` / `VEC_INTO_ITER_CHAIN_COLLECT_U64`。
- [x] Vec IntoIter pair collect ops 批次新增 focused 测试 `std_vec_into_iter_pair_collect_macro_surface.sa`（panic ID 10724）并同步 progress/current_plan/std_missing；不主张 Rust tuple ABI / generic `IntoIterator` conversion / lazy `Enumerate` / `Zip` / `Chain` adapter identity / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete adapter-state eager collect 降阶别名 `VEC_INTO_ITER_BY_REF_COLLECT_U64` / `VEC_INTO_ITER_FUSE_COLLECT_U64` / `VEC_INTO_ITER_PEEKABLE_COLLECT_U64`。
- [x] Vec IntoIter adapter state collect ops 批次新增 focused 测试 `std_vec_into_iter_adapter_state_collect_macro_surface.sa`（panic ID 10725）并同步 progress/current_plan/std_missing；不主张 Rust lazy `ByRef` / `Fuse` / `Peekable` adapter identity、borrow lifetime/reference semantics、generic `Iterator<Item=T>` / owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete partition 降阶别名 `VEC_INTO_ITER_PARTITION_U64` / `VEC_INTO_ITER_IS_PARTITIONED_U64`。
- [x] Vec IntoIter partition ops 批次新增 focused 测试 `std_vec_into_iter_partition_macro_surface.sa`（panic ID 10726）并同步 progress/current_plan/std_missing；不主张 Rust generic `Default + Extend` collection、tuple ABI、nightly adapter object/trait wiring、closure capture、owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 concrete nightly array/window eager collect 降阶别名 `VEC_INTO_ITER_ARRAY_CHUNKS_COLLECT_U64` / `VEC_INTO_ITER_MAP_WINDOWS_COLLECT_U64`。
- [x] Vec IntoIter array/window collect 批次新增 focused 测试 `std_vec_into_iter_array_window_collect_macro_surface.sa`（panic ID 10727）并同步 progress/current_plan/std_missing；不主张 Rust const-generic array item/reference ABI、lazy `ArrayChunks` / `MapWindows` adapter identity、generic closure capture、owned `IntoIter<T,A>` object layout 语义。
- [x] `Vec` Rust API parity 审计继续补齐：补 `vec::IntoIter` 的 nightly `Iterator::next_chunk` concrete 降阶别名 `VEC_INTO_ITER_TRY_NEXT_CHUNK_U64`。
- [x] Vec IntoIter next_chunk 批次新增 focused 测试 `std_vec_into_iter_next_chunk_macro_surface.sa`（panic ID 10728）并同步 progress/current_plan/std_missing；不主张 Rust const-generic array / `Result<[T; N], array::IntoIter<T, N>>` ABI、generic `T`、owned `IntoIter<T,A>` object layout 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 `binary_heap::IntoIter` 的 concrete `Default` / `Iterator` / `DoubleEndedIterator` / `ExactSizeIterator` 降阶别名 `BINARY_HEAP_INTO_ITER_DEFAULT_U64`、`BINARY_HEAP_INTO_ITER_NEXT_U64`、`BINARY_HEAP_INTO_ITER_NEXT_BACK_U64`、`BINARY_HEAP_INTO_ITER_SIZE_HINT_U64`、`BINARY_HEAP_INTO_ITER_EXACT_SIZE_LEN_U64`、`BINARY_HEAP_INTO_ITER_EXACT_SIZE_IS_EMPTY_U64`。
- [x] BinaryHeap IntoIter trait ops 批次新增 focused 测试 `std_binary_heap_into_iter_trait_macro_surface.sa`（panic ID 10729）并同步 progress/current_plan/std_missing；不主张 Rust generic `T` / allocator parameter / marker trait wiring / owned `IntoIter<T,A>` object layout/drop glue 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 `Clone for binary_heap::IntoIter` concrete U64 降阶宏 `BINARY_HEAP_INTO_ITER_CLONE_U64`，从当前 remainder 克隆到新的显式 backing Vec 和 cursor。
- [x] BinaryHeap IntoIter clone 批次新增 focused 测试 `std_binary_heap_into_iter_clone_macro_surface.sa`（panic ID 10730）并同步 progress/current_plan/std_missing；不主张 Rust generic `T: Clone` / allocator cloning / owned `IntoIter<T,A>` object layout/drop glue 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 unstable `binary_heap::IntoIterSorted` 的 concrete `Iterator` / `ExactSizeIterator` 降阶别名 `BINARY_HEAP_INTO_ITER_SORTED_NEXT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_SIZE_HINT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_EXACT_SIZE_LEN_U64`、`BINARY_HEAP_INTO_ITER_SORTED_EXACT_SIZE_IS_EMPTY_U64`。
- [x] BinaryHeap IntoIterSorted trait ops 批次新增 focused 测试 `std_binary_heap_into_iter_sorted_trait_macro_surface.sa`（panic ID 10731）并同步 progress/current_plan/std_missing；不主张 Rust generic `T: Ord` / allocator parameter / lazy pop-on-next object state / owned `IntoIterSorted<T,A>` object layout/drop glue 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 unstable `Clone for binary_heap::IntoIterSorted` concrete U64 降阶宏 `BINARY_HEAP_INTO_ITER_SORTED_CLONE_U64`，从当前 materialized descending remainder 克隆到新的显式 backing Vec 和 cursor。
- [x] BinaryHeap IntoIterSorted clone 批次新增 focused 测试 `std_binary_heap_into_iter_sorted_clone_macro_surface.sa`（panic ID 10732）并同步 progress/current_plan/std_missing；不主张 Rust generic `T: Clone` / allocator cloning/access / lazy pop-on-next object state / owned `IntoIterSorted<T,A>` object layout/drop glue 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete sequence eager collect 降阶别名 `ARRAY_INTO_ITER_INTERSPERSE_COLLECT_U64`、`ARRAY_INTO_ITER_INTERSPERSE_WITH_COLLECT_U64`、`ARRAY_INTO_ITER_CYCLE_TAKE_COLLECT_U64`、`ARRAY_INTO_ITER_TAKE_WHILE_COLLECT_U64`、`ARRAY_INTO_ITER_SKIP_WHILE_COLLECT_U64`。
- [x] Array IntoIter sequence collect 批次新增 focused 测试 `std_array_into_iter_sequence_collect_macro_surface.sa`（panic ID 10749）并同步 progress/current_plan/std_missing；不主张 Rust lazy `Cycle` / `Intersperse` / `TakeWhile` / `SkipWhile` adapter identity、generic closure capture、generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete pair/composition eager collect 降阶别名 `ARRAY_INTO_ITER_ENUMERATE_COLLECT_U64`、`ARRAY_INTO_ITER_ZIP_COLLECT_U64`、`ARRAY_INTO_ITER_CHAIN_COLLECT_U64`。
- [x] Array IntoIter pair collect 批次新增 focused 测试 `std_array_into_iter_pair_collect_macro_surface.sa`（panic ID 10750）并同步 progress/current_plan/std_missing；不主张 Rust tuple ABI / generic `IntoIterator` conversion / lazy `Enumerate` / `Zip` / `Chain` adapter identity / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete adapter-state eager collect 降阶别名 `ARRAY_INTO_ITER_BY_REF_COLLECT_U64`、`ARRAY_INTO_ITER_FUSE_COLLECT_U64`、`ARRAY_INTO_ITER_PEEKABLE_COLLECT_U64`。
- [x] Array IntoIter adapter-state collect 批次新增 focused 测试 `std_array_into_iter_adapter_state_collect_macro_surface.sa`（panic ID 10751）并同步 progress/current_plan/std_missing；不主张 Rust lazy `ByRef` / `Fuse` / `Peekable` adapter identity、borrow lifetime/reference semantics、generic `Iterator<Item=T>` / generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete partition 降阶别名 `ARRAY_INTO_ITER_PARTITION_U64`、`ARRAY_INTO_ITER_IS_PARTITIONED_U64`。
- [x] Array IntoIter partition 批次新增 focused 测试 `std_array_into_iter_partition_macro_surface.sa`（panic ID 10752）并同步 progress/current_plan/std_missing；不主张 Rust generic `Default + Extend` collection、tuple ABI、nightly adapter object/trait wiring、closure capture、generic item move/drop 语义。
- [x] `Array` Rust API parity 审计继续补齐：补 `array::IntoIter` concrete nightly array/window eager collect 降阶别名 `ARRAY_INTO_ITER_ARRAY_CHUNKS_COLLECT_U64`、`ARRAY_INTO_ITER_MAP_WINDOWS_COLLECT_U64`。
- [x] Array IntoIter array/window collect 批次新增 focused 测试 `std_array_into_iter_array_window_collect_macro_surface.sa`（panic ID 10753）并同步 progress/current_plan/std_missing；不主张 Rust const-generic array item/reference ABI、lazy `ArrayChunks` / `MapWindows` adapter identity、generic closure capture、generic item move/drop 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 `binary_heap::IntoIter` concrete materializing collect 降阶别名 `BINARY_HEAP_INTO_ITER_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_TRY_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_COLLECT_INTO_U64`。
- [x] BinaryHeap IntoIter collect 批次新增 focused 测试 `std_binary_heap_into_iter_collect_macro_surface.sa`（panic ID 10754）并同步 progress/current_plan/std_missing；不主张 Rust generic `FromIterator` / `Extend` / `Try` residual、tuple/Result ABI、owned `IntoIter<T,A>` object layout 语义。
- [x] `BinaryHeap` Rust API parity 审计继续补齐：补 unstable `binary_heap::IntoIterSorted` concrete materializing collect 降阶别名 `BINARY_HEAP_INTO_ITER_SORTED_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_TRY_COLLECT_U64`、`BINARY_HEAP_INTO_ITER_SORTED_COLLECT_INTO_U64`。
- [x] BinaryHeap IntoIterSorted collect 批次新增 focused 测试 `std_binary_heap_into_iter_sorted_collect_macro_surface.sa`（panic ID 10755）并同步 progress/current_plan/std_missing；不主张 Rust generic `FromIterator` / `Extend` / `Try` residual、tuple/Result ABI、owned `IntoIterSorted<T,A>` object layout 语义。
