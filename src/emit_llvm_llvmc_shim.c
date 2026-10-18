#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdio.h>
#include <llvm-c/Core.h>
#include <llvm-c/BitWriter.h>
#include <llvm-c/Analysis.h>
#include <llvm-c/DebugInfo.h>
#ifndef _WIN32
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#else
typedef struct LLVMOpaqueTargetData *LLVMTargetDataRef;
typedef struct LLVMOpaqueTargetMachine *LLVMTargetMachineRef;
typedef struct LLVMTarget *LLVMTargetRef;
typedef enum { LLVMCodeGenLevelNone, LLVMCodeGenLevelLess, LLVMCodeGenLevelDefault, LLVMCodeGenLevelAggressive } LLVMCodeGenOptLevel;
typedef enum { LLVMRelocDefault, LLVMRelocStatic, LLVMRelocPIC, LLVMRelocDynamicNoPic, LLVMRelocROPI, LLVMRelocRWPI, LLVMRelocROPI_RWPI } LLVMRelocMode;
typedef enum { LLVMCodeModelDefault, LLVMCodeModelJITDefault, LLVMCodeModelTiny, LLVMCodeModelSmall, LLVMCodeModelKernel, LLVMCodeModelMedium, LLVMCodeModelLarge } LLVMCodeModel;
typedef enum { LLVMAssemblyFile, LLVMObjectFile } LLVMCodeGenFileType;
LLVMBool LLVMGetTargetFromTriple(const char *triple, LLVMTargetRef *target, char **error_message);
LLVMTargetMachineRef LLVMCreateTargetMachine(LLVMTargetRef target, const char *triple, const char *cpu, const char *features, LLVMCodeGenOptLevel level, LLVMRelocMode reloc, LLVMCodeModel code_model);
void LLVMDisposeTargetMachine(LLVMTargetMachineRef target_machine);
LLVMTargetDataRef LLVMCreateTargetDataLayout(LLVMTargetMachineRef target_machine);
LLVMBool LLVMTargetMachineEmitToFile(LLVMTargetMachineRef target_machine, LLVMModuleRef module, char *filename, LLVMCodeGenFileType codegen, char **error_message);
char *LLVMGetDefaultTargetTriple(void);
char *LLVMGetHostCPUName(void);
char *LLVMGetHostCPUFeatures(void);
char *LLVMCopyStringRepOfTargetData(LLVMTargetDataRef target_data);
void LLVMDisposeTargetData(LLVMTargetDataRef target_data);
#endif
#include <llvm-c/Transforms/IPO.h>
#include <llvm-c/Transforms/PassManagerBuilder.h>
#include <llvm-c/Transforms/Scalar.h>
#include <llvm-c/Transforms/Utils.h>
#include <llvm-c/Transforms/Vectorize.h>

typedef enum { SA_T_VOID=0, SA_T_I1=1, SA_T_I8=2, SA_T_I16=3, SA_T_I32=4, SA_T_I64=5, SA_T_F32=6, SA_T_F64=7, SA_T_PTR=8, SA_T_U8=9, SA_T_U16=10, SA_T_U32=11, SA_T_U64=12 } SaType;
typedef enum { SA_F_NORMAL=0, SA_F_EXTERNAL=1, SA_F_EXPORTED=2, SA_F_TEST=3 } SaFuncKind;
typedef enum { SA_OP_NONE=0, SA_OP_LABEL=1, SA_OP_ALLOC=2, SA_OP_STACK_ALLOC=3, SA_OP_LOAD=4, SA_OP_STORE=5, SA_OP_BINOP=6, SA_OP_PTR_ADD=7, SA_OP_JMP=8, SA_OP_BR=9, SA_OP_CALL=10, SA_OP_RET=11, SA_OP_PANIC=12, SA_OP_PANIC_MSG=13, SA_OP_ATOMIC_LOAD=14, SA_OP_ATOMIC_STORE=15, SA_OP_ATOMIC_RMW=16, SA_OP_CMPXCHG=17, SA_OP_FENCE=18, SA_OP_TRY=19, SA_OP_CALL_INDIRECT=20, SA_OP_ASSIGN=21, SA_OP_RELEASE=22, SA_OP_TAKE=23 } SaOp;
typedef enum { SA_OPER_NONE=0, SA_OPER_REG=1, SA_OPER_IMM_I64=2, SA_OPER_IMM_U64=3, SA_OPER_CONST_PTR=4, SA_OPER_IMM_F64=5 } SaOperandKind;
typedef enum { SA_BIN_ADD=0, SA_BIN_SUB=1, SA_BIN_MUL=2, SA_BIN_SDIV=3, SA_BIN_UDIV=4, SA_BIN_SREM=5, SA_BIN_UREM=6, SA_BIN_AND=7, SA_BIN_OR=8, SA_BIN_XOR=9, SA_BIN_SHL=10, SA_BIN_LSHR=11, SA_BIN_ASHR=12, SA_BIN_EQ=13, SA_BIN_NE=14, SA_BIN_SLT=15, SA_BIN_SLE=16, SA_BIN_SGT=17, SA_BIN_SGE=18, SA_BIN_ULT=19, SA_BIN_ULE=20, SA_BIN_UGT=21, SA_BIN_UGE=22, SA_BIN_FADD=23, SA_BIN_FSUB=24, SA_BIN_FMUL=25, SA_BIN_FDIV=26, SA_BIN_FCMP_EQ=27, SA_BIN_FCMP_NE=28, SA_BIN_FCMP_LT=29, SA_BIN_FCMP_LE=30, SA_BIN_FCMP_GT=31, SA_BIN_FCMP_GE=32 } SaBinaryOp;
typedef enum { SA_ATOMIC_RELAXED=0, SA_ATOMIC_ACQUIRE=1, SA_ATOMIC_RELEASE=2, SA_ATOMIC_ACQ_REL=3, SA_ATOMIC_SEQ_CST=4 } SaAtomicOrdering;
typedef enum { SA_RMW_ADD=0, SA_RMW_SUB=1, SA_RMW_AND=2, SA_RMW_OR=3, SA_RMW_XOR=4, SA_RMW_XCHG=5, SA_RMW_MIN=6, SA_RMW_MAX=7, SA_RMW_UMIN=8, SA_RMW_UMAX=9 } SaAtomicRmwOp;

#ifdef _WIN32
void LLVMInitializeX86TargetInfo(void);
void LLVMInitializeX86Target(void);
void LLVMInitializeX86TargetMC(void);
void LLVMInitializeX86AsmPrinter(void);
#endif

typedef struct { const char *name; const unsigned char *data; size_t len; } SaConst;
typedef struct { const char *name; const char *const *funcs; size_t func_count; } SaVTable;
typedef struct { const char *name; SaType ty; unsigned int slot; } SaParam;
typedef struct { unsigned int line; unsigned int col; } SaDebugLoc;
typedef struct { const char *name; SaType ty; unsigned int slot; unsigned char is_param; unsigned int line; unsigned int col; } SaDebugVar;
typedef struct { SaOperandKind kind; unsigned int reg; long long i64_value; unsigned long long u64_value; double f64_value; SaType ty; const char *name; } SaOperand;
typedef struct {
    SaOp op;
    unsigned int dst;
    SaOperand operand0;
    SaOperand operand1;
    SaOperand operand2;
    SaType ty;
    SaBinaryOp binary_op;
    const char *label;
    const char *false_label;
    const char *callee;
    const SaOperand *args;
    size_t arg_count;
    const SaType *indirect_param_tys;
    size_t indirect_param_count;
    unsigned char has_dst;
    SaAtomicOrdering atomic_ordering;
    SaAtomicOrdering atomic_second_ordering;
    SaAtomicRmwOp atomic_rmw_op;
    unsigned char return_fallible;
    unsigned int indirect_sig_index;
    unsigned char is_malloc;
} SaInstruction;
typedef struct {
    const char *name;
    SaFuncKind kind;
    SaType ret_ty;
    unsigned char return_fallible;
    const SaParam *params;
    size_t param_count;
    const SaInstruction *instructions;
    size_t instruction_count;
    const char *source_file;
    const char *source_dir;
    unsigned int entry_line;
    unsigned int entry_col;
    const SaDebugLoc *debug_locs;
    size_t debug_loc_count;
    const SaDebugVar *debug_vars;
    size_t debug_var_count;
    unsigned char emit_main_wrapper;
} SaFunction;
typedef struct {
    unsigned short size_bits;
    unsigned char wasm_compat;
    unsigned char test_mode;
    unsigned char debug;
    unsigned char is_cgu;
    const char *source_file;
    const char *source_dir;
    const SaConst *consts;
    size_t const_count;
    const SaVTable *vtables;
    size_t vtable_count;
    const SaFunction *functions;
    size_t function_count;
    const char *target_triple;
} SaModule;

typedef struct { const char *name; LLVMBasicBlockRef block; } LabelEntry;
typedef struct { LLVMValueRef slot; LLVMValueRef value; LLVMValueRef fallible_slot; SaType ty; unsigned char fallible; unsigned char initialized; unsigned int indirect_sig_index; unsigned char is_malloc; } RegValue;
typedef struct {
    LLVMContextRef ctx;
    LLVMModuleRef module;
    LLVMBuilderRef builder;
    unsigned short size_bits;
    unsigned char is_cgu;
    unsigned char wasm_compat;
    LLVMTypeRef i8_ty;
    LLVMTypeRef i32_ty;
    LLVMTypeRef i64_ty;
    LLVMTypeRef ptr_ty;
    LLVMValueRef malloc_fn;
    LLVMValueRef free_fn;
    LLVMValueRef write_fn;
    LLVMValueRef exit_fn;
    LLVMValueRef panic_fn;
    LLVMValueRef fopen_fn;
    LLVMValueRef fclose_fn;
    LLVMValueRef fread_fn;
    LLVMValueRef fwrite_fn;
    LLVMValueRef fseek_fn;
    LLVMValueRef ftell_fn;
    LLVMValueRef rewind_fn;
    LLVMValueRef memcpy_fn;
    LLVMValueRef saasm_argc_global;
    LLVMValueRef saasm_argv_global;
    const SaFunction *functions;
    size_t function_count;
    unsigned char debug;
    LLVMDIBuilderRef dib;
    LLVMMetadataRef di_file;
    LLVMMetadataRef di_cu;
    LLVMMetadataRef di_subroutine_type;
    LLVMMetadataRef di_i1_type;
    LLVMMetadataRef di_i8_type;
    LLVMMetadataRef di_i16_type;
    LLVMMetadataRef di_i32_type;
    LLVMMetadataRef di_i64_type;
    LLVMMetadataRef di_f32_type;
    LLVMMetadataRef di_f64_type;
    LLVMMetadataRef di_ptr_type;
    char body_error[256];
    const char *target_triple;
} EmitCtx;

static int set_error(char **out_error, const char *message) {
    if (out_error == NULL) return 0;
    size_t len = strlen(message);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) return 1;
    memcpy(copy, message, len + 1);
    *out_error = copy;
    return 1;
}

void sa_llvmc_free(void *ptr) { free(ptr); }

static void dispose_emit_ctx(EmitCtx *e) {
    if (e == NULL) return;
    if (e->dib != NULL) LLVMDisposeDIBuilder(e->dib);
    if (e->builder != NULL) LLVMDisposeBuilder(e->builder);
    if (e->module != NULL) LLVMDisposeModule(e->module);
    if (e->ctx != NULL) LLVMContextDispose(e->ctx);
}

static int module_bitcode_to_heap(LLVMModuleRef module, unsigned char **out_bytes, size_t *out_len) {
    LLVMMemoryBufferRef buffer = LLVMWriteBitcodeToMemoryBuffer(module);
    if (buffer == NULL) return 1;
    size_t len = LLVMGetBufferSize(buffer);
    unsigned char *bytes = (unsigned char *)malloc(len);
    if (bytes == NULL) { LLVMDisposeMemoryBuffer(buffer); return 1; }
    memcpy(bytes, LLVMGetBufferStart(buffer), len);
    LLVMDisposeMemoryBuffer(buffer);
    *out_bytes = bytes;
    *out_len = len;
    return 0;
}

static unsigned normalize_opt_level(int opt_level) {
    if (opt_level <= 0) return 0;
    if (opt_level == 1) return 1;
    if (opt_level == 2) return 2;
    return 3;
}

static void add_enum_function_attr(EmitCtx *e, LLVMValueRef fn, const char *name) {
    unsigned kind = LLVMGetEnumAttributeKindForName(name, strlen(name));
    if (kind == 0) return;
    LLVMAttributeRef attr = LLVMCreateEnumAttribute(e->ctx, kind, 0);
    LLVMAddAttributeAtIndex(fn, LLVMAttributeFunctionIndex, attr);
}

static void add_inline_hint(EmitCtx *e, LLVMValueRef fn) {
    add_enum_function_attr(e, fn, "inlinehint");
}

static void add_always_inline(EmitCtx *e, LLVMValueRef fn) {
    add_enum_function_attr(e, fn, "alwaysinline");
}

static int verify_emit_module(EmitCtx *e, char **out_error) {
    char *verify_error = NULL;
    if (LLVMVerifyModule(e->module, LLVMReturnStatusAction, &verify_error) != 0) {
        if (verify_error != NULL) {
            int status = set_error(out_error, verify_error);
            LLVMDisposeMessage(verify_error);
            return status;
        }
        return set_error(out_error, "LLVMVerifyModule failed");
    }
    return 0;
}

static void optimize_module_ir(EmitCtx *e, int opt_level) {
    unsigned level = normalize_opt_level(opt_level);
    if (level == 0 || e == NULL || e->module == NULL) return;
    if (e->wasm_compat) return;

    LLVMPassManagerBuilderRef pmb = LLVMPassManagerBuilderCreate();
    if (pmb == NULL) return;
    LLVMPassManagerBuilderSetOptLevel(pmb, level);
    LLVMPassManagerBuilderSetSizeLevel(pmb, 0);
    LLVMPassManagerBuilderUseInlinerWithThreshold(pmb, level >= 3 ? 900 : 225);

    LLVMPassManagerRef fpm = LLVMCreateFunctionPassManagerForModule(e->module);
    if (fpm != NULL) {
        LLVMAddScalarReplAggregatesPassSSA(fpm);
        LLVMAddPromoteMemoryToRegisterPass(fpm);
        LLVMAddInstructionCombiningPass(fpm);
        LLVMAddReassociatePass(fpm);
        LLVMAddGVNPass(fpm);
        LLVMAddCFGSimplificationPass(fpm);
        LLVMPassManagerBuilderPopulateFunctionPassManager(pmb, fpm);
        LLVMInitializeFunctionPassManager(fpm);
        for (LLVMValueRef fn = LLVMGetFirstFunction(e->module); fn != NULL; fn = LLVMGetNextFunction(fn)) {
            if (LLVMCountBasicBlocks(fn) != 0) LLVMRunFunctionPassManager(fpm, fn);
        }
        LLVMFinalizeFunctionPassManager(fpm);
        LLVMDisposePassManager(fpm);
    }

    LLVMPassManagerRef mpm = LLVMCreatePassManager();
    if (mpm != NULL) {
        LLVMAddFunctionAttrsPass(mpm);
        LLVMAddAlwaysInlinerPass(mpm);
        LLVMAddGlobalOptimizerPass(mpm);
        if (level >= 2) LLVMAddIPSCCPPass(mpm);
        LLVMPassManagerBuilderPopulateModulePassManager(pmb, mpm);
        LLVMAddScalarReplAggregatesPassSSA(mpm);
        LLVMAddPromoteMemoryToRegisterPass(mpm);
        LLVMAddInstructionCombiningPass(mpm);
        LLVMAddReassociatePass(mpm);
        LLVMAddGVNPass(mpm);
        LLVMAddSCCPPass(mpm);
        LLVMAddDeadStoreEliminationPass(mpm);
        LLVMAddTailCallEliminationPass(mpm);
        LLVMAddLoopRotatePass(mpm);
        LLVMAddLICMPass(mpm);
        LLVMAddLoopDeletionPass(mpm);
        LLVMAddLoopIdiomPass(mpm);
        LLVMAddIndVarSimplifyPass(mpm);
        LLVMAddMemCpyOptPass(mpm);
        if (level >= 3) {
            LLVMAddLoopUnrollPass(mpm);
            LLVMAddLoopVectorizePass(mpm);
            LLVMAddSLPVectorizePass(mpm);
        }
        LLVMAddCFGSimplificationPass(mpm);
        LLVMAddAggressiveDCEPass(mpm);
        LLVMAddGlobalDCEPass(mpm);
        LLVMAddStripDeadPrototypesPass(mpm);
        LLVMRunPassManager(mpm, e->module);
        LLVMDisposePassManager(mpm);
    }

    LLVMPassManagerBuilderDispose(pmb);
}

static LLVMTypeRef type_of(EmitCtx *e, SaType ty) {
    switch (ty) {
        case SA_T_VOID: return LLVMVoidTypeInContext(e->ctx);
        case SA_T_I1: return LLVMInt1TypeInContext(e->ctx);
        case SA_T_I8: return LLVMInt8TypeInContext(e->ctx);
        case SA_T_U8: return LLVMInt8TypeInContext(e->ctx);
        case SA_T_I16: return LLVMInt16TypeInContext(e->ctx);
        case SA_T_U16: return LLVMInt16TypeInContext(e->ctx);
        case SA_T_I32: return LLVMInt32TypeInContext(e->ctx);
        case SA_T_U32: return LLVMInt32TypeInContext(e->ctx);
        case SA_T_I64: return LLVMInt64TypeInContext(e->ctx);
        case SA_T_U64: return LLVMInt64TypeInContext(e->ctx);
        case SA_T_F32: return LLVMFloatTypeInContext(e->ctx);
        case SA_T_F64: return LLVMDoubleTypeInContext(e->ctx);
        case SA_T_PTR: return LLVMPointerType(LLVMInt8TypeInContext(e->ctx), 0);
    }
    return LLVMInt64TypeInContext(e->ctx);
}

static LLVMTypeRef size_type(EmitCtx *e) {
    return e->size_bits == 32 ? e->i32_ty : e->i64_ty;
}

static LLVMValueRef size_const(EmitCtx *e, unsigned long long value) {
    return LLVMConstInt(size_type(e), value, 0);
}

static LLVMTypeRef vtable_slot_type(EmitCtx *e) {
    if (e->size_bits == 32) {
        LLVMTypeRef fields[2] = { e->ptr_ty, e->i32_ty };
        return LLVMStructTypeInContext(e->ctx, fields, 2, 0);
    }
    return e->ptr_ty;
}

static LLVMValueRef vtable_slot_value(EmitCtx *e, LLVMValueRef fn) {
    LLVMValueRef ptr = LLVMConstPointerCast(fn, e->ptr_ty);
    if (e->size_bits == 32) {
        LLVMValueRef fields[2] = { ptr, LLVMConstInt(e->i32_ty, 0, 0) };
        return LLVMConstNamedStruct(vtable_slot_type(e), fields, 2);
    }
    return ptr;
}

static LLVMValueRef coerce_to_size(EmitCtx *e, LLVMValueRef value, const char *name) {
    LLVMTypeRef from_ty = LLVMTypeOf(value);
    LLVMTypeRef to_ty = size_type(e);
    if (from_ty == to_ty) return value;
    if (LLVMGetTypeKind(from_ty) == LLVMIntegerTypeKind) {
        unsigned from_bits = LLVMGetIntTypeWidth(from_ty);
        unsigned to_bits = LLVMGetIntTypeWidth(to_ty);
        if (from_bits > to_bits) return LLVMBuildTrunc(e->builder, value, to_ty, name);
        if (from_bits < to_bits) return LLVMBuildZExt(e->builder, value, to_ty, name);
    }
    return value;
}

static LLVMValueRef coerce_int_to(EmitCtx *e, LLVMValueRef value, LLVMTypeRef to_ty, const char *name) {
    LLVMTypeRef from_ty = LLVMTypeOf(value);
    if (from_ty == to_ty) return value;
    if (LLVMGetTypeKind(from_ty) == LLVMIntegerTypeKind && LLVMGetTypeKind(to_ty) == LLVMIntegerTypeKind) {
        unsigned from_bits = LLVMGetIntTypeWidth(from_ty);
        unsigned to_bits = LLVMGetIntTypeWidth(to_ty);
        if (from_bits > to_bits) return LLVMBuildTrunc(e->builder, value, to_ty, name);
        if (from_bits < to_bits) return LLVMBuildZExt(e->builder, value, to_ty, name);
    }
    return value;
}

static LLVMTypeRef fallible_type_of(EmitCtx *e, SaType payload_ty) {
    LLVMTypeRef fields[2] = { e->i32_ty, type_of(e, payload_ty) };
    return LLVMStructTypeInContext(e->ctx, fields, 2, 0);
}

static LLVMTypeRef fallible_wire_type_of(EmitCtx *e, SaType payload_ty) {
    return fallible_type_of(e, payload_ty);
}

static int external_fallible_i32_uses_i64_abi(EmitCtx *e, const SaFunction *f) {
    /* The i64 packing relies on SysV returning 8-byte structs in a single
       register. wasm32 uses multi-value {i32, i32} returns instead, so the
       packed declaration mismatches the archive callee (local.set i32 vs
       call i64 at validation). Fall back to the plain struct ABI there. */
    if (e != NULL && e->wasm_compat) return 0;
    return f != NULL && f->kind == SA_F_EXTERNAL && f->return_fallible && (f->ret_ty == SA_T_I32 || f->ret_ty == SA_T_U32 || f->ret_ty == SA_T_I16 || f->ret_ty == SA_T_U16 || f->ret_ty == SA_T_I8 || f->ret_ty == SA_T_U8);
}

/* On Win64 the C ABI returns composite values larger than 8 bytes through a hidden
 * first "sret" pointer (the callee writes the result there and returns void).
 * LLVM does not auto-lower a directly-typed {i32, payload} struct return to sret on
 * the windows-msvc target, so an external declared as `declare { i32, T } @f(...)` is
 * actually called with the SysV 2-register convention while the linked C/Zig export
 * uses sret. The caller then passes path in the sret slot and reads garbage, which is
 * an access violation. The fix is to declare such externals with an explicit sret
 * hidden argument and void return, mirroring how clang lowers Win64 struct returns.
 * FallibleI32 (8-byte {i32, i32}) stays on the i64-register pack path below. */
#ifdef _WIN32
static int external_fallible_uses_sret_win64(const SaFunction *f) {
    if (f == NULL || f->kind != SA_F_EXTERNAL || !f->return_fallible) return 0;
    if (external_fallible_i32_uses_i64_abi(NULL, f)) return 0;
    switch (f->ret_ty) {
        case SA_T_I64:
        case SA_T_U64:
        case SA_T_F64:
        case SA_T_PTR:
            return 1;
        default:
            return 0;
    }
}
#else
static int external_fallible_uses_sret_win64(const SaFunction *f) { (void)f; return 0; }
#endif

static LLVMTypeRef return_type_for(EmitCtx *e, const SaFunction *f) {
    if (external_fallible_i32_uses_i64_abi(e, f)) return e->i64_ty;
    if (external_fallible_uses_sret_win64(f)) return LLVMVoidTypeInContext(e->ctx);
    if (f->return_fallible) return fallible_type_of(e, f->ret_ty);
    return type_of(e, f->ret_ty);
}

static LLVMValueRef unpack_external_fallible_i32(EmitCtx *e, LLVMValueRef packed) {
    LLVMTypeRef result_ty = fallible_type_of(e, SA_T_I32);
    LLVMValueRef agg = LLVMGetUndef(result_ty);
    LLVMValueRef status64 = LLVMBuildAnd(e->builder, packed, LLVMConstInt(e->i64_ty, 0xffffffffULL, 0), "fallible_status_bits");
    LLVMValueRef payload64 = LLVMBuildLShr(e->builder, packed, LLVMConstInt(e->i64_ty, 32, 0), "fallible_payload_bits");
    LLVMValueRef status = LLVMBuildTrunc(e->builder, status64, e->i32_ty, "fallible_status_i32");
    LLVMValueRef payload = LLVMBuildTrunc(e->builder, payload64, e->i32_ty, "fallible_payload_i32");
    agg = LLVMBuildInsertValue(e->builder, agg, status, 0, "fallible_status");
    return LLVMBuildInsertValue(e->builder, agg, payload, 1, "fallible_payload");
}

/* LLVM's triple parser needs an explicit vendor to select the object format:
   "x86_64-windows-gnu" is misparsed and emits ELF, while "x86_64-pc-windows-gnu"
   correctly emits COFF. Normalize <arch>-windows[-<abi>...] to
   <arch>-pc-windows[-<abi>...]. Other triples pass through unchanged. */
static void normalize_triple_for_llvm(const char *triple, char *out, size_t out_len) {
    if (triple == NULL || out_len == 0) { if (out_len > 0) out[0] = '\0'; return; }
    const char *dash1 = strchr(triple, '-');
    if (dash1 == NULL) { snprintf(out, out_len, "%s", triple); return; }
    const char *dash2 = strchr(dash1 + 1, '-');
    size_t second_len = dash2 ? (size_t)(dash2 - dash1 - 1) : strlen(dash1 + 1);
    if (second_len == 7 && strncmp(dash1 + 1, "windows", 7) == 0) {
        size_t arch_len = (size_t)(dash1 - triple);
        snprintf(out, out_len, "%.*s-pc%s", (int)arch_len, triple, dash1);
        return;
    }
    if (second_len == 5 && strncmp(dash1 + 1, "macos", 5) == 0) {
        size_t arch_len = (size_t)(dash1 - triple);
        snprintf(out, out_len, "%.*s-apple-macosx", (int)arch_len, triple);
        return;
    }
    snprintf(out, out_len, "%s", triple);
}

static int apply_native_target_layout(EmitCtx *e, char **out_error) {
    if (e == NULL || e->module == NULL || e->wasm_compat) return 0;

    /* Cross-compilation: initialize every LLVM target, not just the host one. */
    LLVMInitializeAllTargetInfos();
    LLVMInitializeAllTargets();
    LLVMInitializeAllTargetMCs();
    LLVMInitializeAllAsmPrinters();

    char triple_buf[128];
    char *triple = NULL;
    int triple_owned = 0;
    if (e->target_triple != NULL && e->target_triple[0] != '\0') {
        normalize_triple_for_llvm(e->target_triple, triple_buf, sizeof(triple_buf));
        triple = triple_buf;
    } else {
        triple = LLVMGetDefaultTargetTriple();
        if (triple == NULL) return set_error(out_error, "LLVMGetDefaultTargetTriple failed");
        triple_owned = 1;
    }

    LLVMTargetRef target;
    char *err_msg = NULL;
    if (LLVMGetTargetFromTriple(triple, &target, &err_msg)) {
        int status = set_error(out_error, err_msg ? err_msg : "target lookup failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        if (triple_owned) LLVMDisposeMessage(triple);
        return status;
    }

    LLVMTargetMachineRef tm = LLVMCreateTargetMachine(
        target, triple, "", "",
        LLVMCodeGenLevelDefault, LLVMRelocDefault, LLVMCodeModelDefault
    );
    if (tm == NULL) {
        if (triple_owned) LLVMDisposeMessage(triple);
        return set_error(out_error, "TargetMachine creation failed");
    }

    LLVMSetTarget(e->module, triple);
    LLVMTargetDataRef dl = LLVMCreateTargetDataLayout(tm);
    char *dl_str = LLVMCopyStringRepOfTargetData(dl);
    LLVMSetDataLayout(e->module, dl_str);
    LLVMDisposeMessage(dl_str);
    LLVMDisposeTargetData(dl);
    LLVMDisposeTargetMachine(tm);
    if (triple_owned) LLVMDisposeMessage(triple);
    return 0;
}

static LLVMValueRef find_function(EmitCtx *e, const char *name) { return LLVMGetNamedFunction(e->module, name); }
static LLVMValueRef find_global(EmitCtx *e, const char *name) { return LLVMGetNamedGlobal(e->module, name); }

static const SaFunction *function_by_name(EmitCtx *e, const char *name) {
    if (e == NULL || name == NULL) return NULL;
    for (size_t i = 0; i < e->function_count; i++) {
        if (strcmp(e->functions[i].name, name) == 0) return &e->functions[i];
    }
    return NULL;
}

static SaType sa_type_from_llvm(LLVMTypeRef ty) {
    switch (LLVMGetTypeKind(ty)) {
        case LLVMVoidTypeKind: return SA_T_VOID;
        case LLVMPointerTypeKind: return SA_T_PTR;
        case LLVMIntegerTypeKind: {
            unsigned bits = LLVMGetIntTypeWidth(ty);
            if (bits <= 1) return SA_T_I1;
            if (bits <= 8) return SA_T_I8;
            if (bits <= 16) return SA_T_I16;
            if (bits <= 32) return SA_T_I32;
            return SA_T_I64;
        }
        case LLVMFloatTypeKind: return SA_T_F32;
        case LLVMDoubleTypeKind: return SA_T_F64;
        default: return SA_T_PTR;
    }
}

static unsigned type_bits(SaType ty) {
    switch (ty) {
        case SA_T_I1:
            return 1;
        case SA_T_I8:
        case SA_T_U8:
            return 8;
        case SA_T_I16:
        case SA_T_U16:
            return 16;
        case SA_T_I32:
        case SA_T_U32:
        case SA_T_F32:
            return 32;
        case SA_T_I64:
        case SA_T_U64:
        case SA_T_F64:
        case SA_T_PTR:
            return 64;
        case SA_T_VOID:
            return 0;
    }
    return 64;
}

static int type_is_signed_int(SaType ty) {
    switch (ty) {
        case SA_T_I8:
        case SA_T_I16:
        case SA_T_I32:
        case SA_T_I64:
            return 1;
        default:
            return 0;
    }
}

static LLVMTypeRef fn_type_for(EmitCtx *e, const SaFunction *f) {
    if (f->param_count > UINT_MAX) return NULL;
    int sret = external_fallible_uses_sret_win64(f);
    size_t extra = sret ? 1 : 0;
    size_t total = f->param_count + extra;
    LLVMTypeRef *params = NULL;
    if (total != 0) {
        params = (LLVMTypeRef *)malloc(sizeof(LLVMTypeRef) * total);
        if (params == NULL) return NULL;
        size_t idx = 0;
        if (sret) params[idx++] = LLVMPointerType(fallible_type_of(e, f->ret_ty), 0);
        for (size_t i = 0; i < f->param_count; i++) params[idx++] = type_of(e, f->params[i].ty);
    }
    LLVMTypeRef ty = LLVMFunctionType(return_type_for(e, f), params, (unsigned)total, 0);
    free(params);
    return ty;
}

static const SaFunction *function_by_index(EmitCtx *e, unsigned int index) {
    if (index == UINT_MAX || index >= e->function_count) return NULL;
    return &e->functions[index];
}

static int sa_type_can_coerce(SaType from, SaType to) {
    if (from == to) return 1;
    if (from == SA_T_PTR || to == SA_T_PTR) return 1;
    return 1;
}

static unsigned int infer_indirect_sig_index(EmitCtx *e, const SaInstruction *in, const SaType *arg_tys) {
    unsigned int chosen = UINT_MAX;

    for (size_t i = 0; i < e->function_count; i++) {
        const SaFunction *candidate = &e->functions[i];
        if (candidate->kind == SA_F_EXTERNAL) continue;
        // A valued indirect call can never target a void function: the old
        // first-match would pick an earlier same-arity void (a ctor, or an
        // imported helper like sa_mem_set inlined ahead of the closures)
        // and mistype the call as void, crashing LLVM codegen downstream.
        // Skipping void here only changes outcomes that previously failed
        // to build, so working programs are unaffected.
        if (in->has_dst && candidate->ret_ty == SA_T_VOID && !candidate->return_fallible) continue;

        size_t param_count = in->indirect_param_count != 0 ? in->indirect_param_count : candidate->param_count;
        if (param_count != in->arg_count) continue;

        int ok = 1;
        for (size_t a = 0; a < in->arg_count; a++) {
            SaType param_ty = in->indirect_param_count != 0 ? in->indirect_param_tys[a] : candidate->params[a].ty;
            if (!sa_type_can_coerce(arg_tys[a], param_ty)) {
                ok = 0;
                break;
            }
        }
        if (!ok) continue;

        if (chosen == UINT_MAX) {
            chosen = (unsigned int)i;
        }
    }

    return chosen;
}

static LLVMTypeRef indirect_fn_type_for(EmitCtx *e, const SaFunction *sig, const SaInstruction *in) {
    size_t param_count = in->indirect_param_count != 0 ? in->indirect_param_count : sig->param_count;
    if (param_count > UINT_MAX) return NULL;
    LLVMTypeRef *params = NULL;
    if (param_count != 0) {
        params = (LLVMTypeRef *)malloc(sizeof(LLVMTypeRef) * param_count);
        if (params == NULL) return NULL;
        for (size_t i = 0; i < param_count; i++) {
            SaType ty = in->indirect_param_count != 0 ? in->indirect_param_tys[i] : sig->params[i].ty;
            params[i] = type_of(e, ty);
        }
    }
    LLVMTypeRef ret_ty = return_type_for(e, sig);
    LLVMTypeRef ty = LLVMFunctionType(ret_ty, params, (unsigned)param_count, 0);
    free(params);
    return ty;
}

static LLVMValueRef coerce(EmitCtx *e, LLVMValueRef v, SaType from, SaType to) {
    if (from == to) return v;
    LLVMTypeRef dst = type_of(e, to);
    if (to == SA_T_PTR) return LLVMBuildIntToPtr(e->builder, v, dst, "cast_ptr");
    if (from == SA_T_PTR) return LLVMBuildPtrToInt(e->builder, v, dst, "cast_int");
    if ((from == SA_T_F32 || from == SA_T_F64) && (to == SA_T_F32 || to == SA_T_F64)) {
        return from == SA_T_F32 ? LLVMBuildFPExt(e->builder, v, dst, "fpext") : LLVMBuildFPTrunc(e->builder, v, dst, "fptrunc");
    }
    if (from == SA_T_F32 || from == SA_T_F64) {
        return LLVMBuildFPToSI(e->builder, v, dst, "fptosi");
    }
    if (to == SA_T_F32 || to == SA_T_F64) {
        return type_is_signed_int(from) ? LLVMBuildSIToFP(e->builder, v, dst, "sitofp") : LLVMBuildUIToFP(e->builder, v, dst, "uitofp");
    }
    unsigned from_bits = type_bits(from);
    unsigned to_bits = type_bits(to);
    if (from_bits < to_bits) return type_is_signed_int(from) ? LLVMBuildSExt(e->builder, v, dst, "sext") : LLVMBuildZExt(e->builder, v, dst, "zext");
    if (from_bits > to_bits) return LLVMBuildTrunc(e->builder, v, dst, "trunc");
    return v;
}

static LLVMValueRef build_fallible_ok(EmitCtx *e, SaType payload_ty, LLVMValueRef payload, SaType payload_from) {
    LLVMTypeRef result_ty = fallible_type_of(e, payload_ty);
    LLVMValueRef agg = LLVMGetUndef(result_ty);
    agg = LLVMBuildInsertValue(e->builder, agg, LLVMConstInt(e->i32_ty, 0, 0), 0, "fallible_status");
    payload = coerce(e, payload, payload_from, payload_ty);
    return LLVMBuildInsertValue(e->builder, agg, payload, 1, "fallible_ok");
}

static LLVMValueRef default_value_of(EmitCtx *e, SaType ty) {
    return LLVMConstNull(type_of(e, ty));
}

static LLVMValueRef build_fallible_err(EmitCtx *e, SaType payload_ty, LLVMValueRef status) {
    LLVMTypeRef result_ty = fallible_type_of(e, payload_ty);
    LLVMValueRef agg = LLVMGetUndef(result_ty);
    agg = LLVMBuildInsertValue(e->builder, agg, status, 0, "fallible_status");
    return LLVMBuildInsertValue(e->builder, agg, default_value_of(e, payload_ty), 1, "fallible_err");
}

static LLVMValueRef const_c_string(EmitCtx *e, const char *name, const char *text) {
    size_t len = strlen(text) + 1;
    LLVMTypeRef arr_ty = LLVMArrayType(e->i8_ty, (unsigned)len);
    LLVMValueRef glob = LLVMAddGlobal(e->module, arr_ty, name);
    LLVMSetGlobalConstant(glob, 1);
    LLVMSetLinkage(glob, LLVMPrivateLinkage);
    LLVMSetInitializer(glob, LLVMConstStringInContext(e->ctx, text, (unsigned)(len - 1), 0));
    LLVMValueRef zero = LLVMConstInt(e->i32_ty, 0, 0);
    LLVMValueRef idxs[2] = { zero, zero };
    return LLVMConstGEP2(arr_ty, glob, idxs, 2);
}

static LLVMAtomicOrdering atomic_ordering(SaAtomicOrdering ordering) {
    switch (ordering) {
        case SA_ATOMIC_RELAXED: return LLVMAtomicOrderingMonotonic;
        case SA_ATOMIC_ACQUIRE: return LLVMAtomicOrderingAcquire;
        case SA_ATOMIC_RELEASE: return LLVMAtomicOrderingRelease;
        case SA_ATOMIC_ACQ_REL: return LLVMAtomicOrderingAcquireRelease;
        case SA_ATOMIC_SEQ_CST: return LLVMAtomicOrderingSequentiallyConsistent;
    }
    return LLVMAtomicOrderingSequentiallyConsistent;
}

static LLVMAtomicRMWBinOp atomic_rmw_op(SaAtomicRmwOp op) {
    switch (op) {
        case SA_RMW_ADD: return LLVMAtomicRMWBinOpAdd;
        case SA_RMW_SUB: return LLVMAtomicRMWBinOpSub;
        case SA_RMW_AND: return LLVMAtomicRMWBinOpAnd;
        case SA_RMW_OR: return LLVMAtomicRMWBinOpOr;
        case SA_RMW_XOR: return LLVMAtomicRMWBinOpXor;
        case SA_RMW_XCHG: return LLVMAtomicRMWBinOpXchg;
        case SA_RMW_MIN: return LLVMAtomicRMWBinOpMin;
        case SA_RMW_MAX: return LLVMAtomicRMWBinOpMax;
        case SA_RMW_UMIN: return LLVMAtomicRMWBinOpUMin;
        case SA_RMW_UMAX: return LLVMAtomicRMWBinOpUMax;
    }
    return LLVMAtomicRMWBinOpAdd;
}

static unsigned align_of(SaType ty) {
    switch (ty) {
        case SA_T_I1:
        case SA_T_I8:
        case SA_T_U8:
            return 1;
        case SA_T_I16:
        case SA_T_U16:
            return 2;
        case SA_T_I32:
        case SA_T_U32:
        case SA_T_F32:
            return 4;
        case SA_T_I64:
        case SA_T_U64:
        case SA_T_F64:
        case SA_T_PTR:
            return 8;
        case SA_T_VOID:
            return 1;
    }
    return 8;
}

static LLVMValueRef reg_encode(EmitCtx *e, LLVMValueRef value, SaType ty) {
    if (ty == SA_T_PTR) return LLVMBuildPtrToInt(e->builder, value, e->i64_ty, "slot_ptr_to_int");
    if (ty == SA_T_F64) return LLVMBuildBitCast(e->builder, value, e->i64_ty, "slot_f64_bits");
    if (ty == SA_T_F32) {
        LLVMValueRef bits32 = LLVMBuildBitCast(e->builder, value, e->i32_ty, "slot_f32_bits");
        return LLVMBuildZExt(e->builder, bits32, e->i64_ty, "slot_f32_ext");
    }
    if (LLVMGetTypeKind(LLVMTypeOf(value)) == LLVMDoubleTypeKind) {
        return LLVMBuildBitCast(e->builder, value, e->i64_ty, "slot_f64_bits");
    }
    if (LLVMGetTypeKind(LLVMTypeOf(value)) == LLVMFloatTypeKind) {
        LLVMValueRef bits32 = LLVMBuildBitCast(e->builder, value, e->i32_ty, "slot_f32_bits");
        return LLVMBuildZExt(e->builder, bits32, e->i64_ty, "slot_f32_ext");
    }
    if (LLVMGetTypeKind(LLVMTypeOf(value)) == LLVMIntegerTypeKind) {
        return coerce_int_to(e, value, e->i64_ty, "slot_int_bits");
    }
    return coerce(e, value, ty, SA_T_I64);
}

static LLVMValueRef reg_decode(EmitCtx *e, LLVMValueRef bits, SaType ty) {
    if (ty == SA_T_PTR) return LLVMBuildIntToPtr(e->builder, bits, e->ptr_ty, "slot_int_to_ptr");
    if (ty == SA_T_F64) return LLVMBuildBitCast(e->builder, bits, LLVMDoubleTypeInContext(e->ctx), "slot_f64");
    if (ty == SA_T_F32) {
        LLVMValueRef bits32 = LLVMBuildTrunc(e->builder, bits, e->i32_ty, "slot_f32_trunc");
        return LLVMBuildBitCast(e->builder, bits32, LLVMFloatTypeInContext(e->ctx), "slot_f32");
    }
    return coerce(e, bits, SA_T_I64, ty);
}

static int reg_store(EmitCtx *e, RegValue *regs, size_t reg_count, unsigned int slot, LLVMValueRef value, SaType ty, unsigned char fallible, unsigned int indirect_sig_index) {
    if (slot >= reg_count) return 1;
    regs[slot].ty = ty;
    regs[slot].fallible = fallible;
    regs[slot].initialized = 1;
    regs[slot].indirect_sig_index = indirect_sig_index;
    regs[slot].fallible_slot = NULL;
    regs[slot].value = value;
    regs[slot].is_malloc = 0;
    if (fallible) {
        return 0;
    }
    if (ty == SA_T_VOID || value == NULL) {
        return 0;
    }
    if (regs[slot].slot != NULL) {
        LLVMValueRef bits = reg_encode(e, value, ty);
        LLVMBuildStore(e->builder, bits, regs[slot].slot);
    }
    return 0;
}

static int fallible_value_ptr(EmitCtx *e, RegValue *reg, LLVMValueRef *out, SaType *out_ty) {
    if (reg == NULL || !reg->fallible || reg->value == NULL) return 1;
    if (reg->fallible_slot == NULL) {
        LLVMTypeRef wire_ty = fallible_wire_type_of(e, reg->ty);
        reg->fallible_slot = LLVMBuildAlloca(e->builder, wire_ty, "fallible_slot");
    }
    LLVMTypeRef wire_ty = fallible_wire_type_of(e, reg->ty);
    LLVMValueRef status = LLVMBuildExtractValue(e->builder, reg->value, 0, "fallible_wire_status");
    LLVMValueRef payload = LLVMBuildExtractValue(e->builder, reg->value, 1, "fallible_wire_payload");
    LLVMValueRef status_slot = LLVMBuildStructGEP2(e->builder, wire_ty, reg->fallible_slot, 0, "fallible_status_slot");
    LLVMValueRef payload_slot = LLVMBuildStructGEP2(e->builder, wire_ty, reg->fallible_slot, 1, "fallible_payload_slot");
    LLVMBuildStore(e->builder, status, status_slot);
    LLVMBuildStore(e->builder, payload, payload_slot);
    *out = LLVMBuildPointerCast(e->builder, reg->fallible_slot, e->ptr_ty, "fallible_ptr");
    *out_ty = SA_T_PTR;
    return 0;
}

static int operand_value(EmitCtx *e, const SaOperand *op, RegValue *regs, size_t reg_count, LLVMValueRef *out, SaType *out_ty) {
    switch (op->kind) {
        case SA_OPER_REG:
            if (op->reg >= reg_count || !regs[op->reg].initialized) return 1;
            *out_ty = regs[op->reg].ty;
            if (regs[op->reg].ty == SA_T_VOID || regs[op->reg].fallible) {
                *out = regs[op->reg].value;
                return 0;
            }
            if (regs[op->reg].slot != NULL) {
                LLVMValueRef bits = LLVMBuildLoad2(e->builder, e->i64_ty, regs[op->reg].slot, "slot_load");
                *out = reg_decode(e, bits, *out_ty);
            } else if (regs[op->reg].value != NULL) {
                *out = regs[op->reg].value;
            } else {
                return 1;
            }
            return 0;
        case SA_OPER_IMM_I64:
            *out = LLVMConstInt(e->i64_ty, (unsigned long long)op->i64_value, 1);
            *out_ty = SA_T_I64;
            return 0;
        case SA_OPER_IMM_U64:
            *out = LLVMConstInt(e->i64_ty, op->u64_value, 0);
            *out_ty = SA_T_I64;
            return 0;
        case SA_OPER_IMM_F64:
            *out_ty = op->ty == SA_T_F32 ? SA_T_F32 : SA_T_F64;
            *out = LLVMConstReal(type_of(e, *out_ty), op->f64_value);
            return 0;
        case SA_OPER_CONST_PTR:
            *out = find_global(e, op->name);
            if (*out == NULL) return 1;
            *out = LLVMBuildPointerCast(e->builder, *out, e->ptr_ty, "const_ptr");
            *out_ty = SA_T_PTR;
            return 0;
        default:
            return 1;
    }
}

static int operand_addressable_value(EmitCtx *e, const SaOperand *op, RegValue *regs, size_t reg_count, LLVMValueRef *out, SaType *out_ty) {
    if (op->kind == SA_OPER_REG) {
        if (op->reg >= reg_count || !regs[op->reg].initialized) return 1;
        if (regs[op->reg].fallible) return fallible_value_ptr(e, &regs[op->reg], out, out_ty);
    }
    return operand_value(e, op, regs, reg_count, out, out_ty);
}

static LLVMBasicBlockRef label_block(LabelEntry *labels, size_t label_count, const char *name) {
    for (size_t i = 0; i < label_count; i++) if (strcmp(labels[i].name, name) == 0) return labels[i].block;
    return NULL;
}

static int current_has_terminator(EmitCtx *e) {
    LLVMBasicBlockRef bb = LLVMGetInsertBlock(e->builder);
    return bb != NULL && LLVMGetBasicBlockTerminator(bb) != NULL;
}

static int function_has_direct_self_call(const SaFunction *f) {
    if (f == NULL || f->name == NULL) return 0;
    for (size_t i = 0; i < f->instruction_count; i++) {
        const SaInstruction *in = &f->instructions[i];
        if (in->op == SA_OP_CALL && in->callee != NULL && strcmp(in->callee, f->name) == 0) return 1;
    }
    return 0;
}

static int self_call_is_immediate_tail_return(const SaFunction *f, size_t index) {
    if (f == NULL || f->return_fallible || index + 1 >= f->instruction_count) return 0;

    const SaInstruction *call = &f->instructions[index];
    const SaInstruction *ret = &f->instructions[index + 1];
    if (call->op != SA_OP_CALL || ret->op != SA_OP_RET) return 0;
    if (call->callee == NULL || strcmp(call->callee, f->name) != 0) return 0;
    if (call->return_fallible) return 0;

    if (f->ret_ty == SA_T_VOID) {
        return !call->has_dst && !ret->has_dst;
    }

    return call->has_dst &&
           ret->has_dst &&
           ret->operand0.kind == SA_OPER_REG &&
           ret->operand0.reg == call->dst;
}

static int fail_body(EmitCtx *e, const SaFunction *f, const SaInstruction *in, size_t index, const char *message) {
    const char *fn_name = f != NULL && f->name != NULL ? f->name : "<unknown>";
    SaOp op = in != NULL ? in->op : SA_OP_NONE;
    snprintf(e->body_error, sizeof(e->body_error), "emit body failed in %s instruction %zu op %d: %s", fn_name, index, (int)op, message);
    return 1;
}

static int fail_body_callee(EmitCtx *e, const SaFunction *f, const SaInstruction *in, size_t index, const char *message) {
    const char *fn_name = f != NULL && f->name != NULL ? f->name : "<unknown>";
    const char *callee = in != NULL && in->callee != NULL ? in->callee : "<null>";
    SaOp op = in != NULL ? in->op : SA_OP_NONE;
    snprintf(e->body_error, sizeof(e->body_error), "emit body failed in %s instruction %zu op %d: %s: %s", fn_name, index, (int)op, message, callee);
    return 1;
}

static LLVMValueRef build_binop(EmitCtx *e, SaBinaryOp op, LLVMValueRef lhs, LLVMValueRef rhs) {
    switch (op) {
        case SA_BIN_ADD: return LLVMBuildAdd(e->builder, lhs, rhs, "op");
        case SA_BIN_SUB: return LLVMBuildSub(e->builder, lhs, rhs, "op");
        case SA_BIN_MUL: return LLVMBuildMul(e->builder, lhs, rhs, "op");
        case SA_BIN_SDIV: return LLVMBuildSDiv(e->builder, lhs, rhs, "op");
        case SA_BIN_UDIV: return LLVMBuildUDiv(e->builder, lhs, rhs, "op");
        case SA_BIN_SREM: return LLVMBuildSRem(e->builder, lhs, rhs, "op");
        case SA_BIN_UREM: return LLVMBuildURem(e->builder, lhs, rhs, "op");
        case SA_BIN_AND: return LLVMBuildAnd(e->builder, lhs, rhs, "op");
        case SA_BIN_OR: return LLVMBuildOr(e->builder, lhs, rhs, "op");
        case SA_BIN_XOR: return LLVMBuildXor(e->builder, lhs, rhs, "op");
        case SA_BIN_SHL: return LLVMBuildShl(e->builder, lhs, rhs, "op");
        case SA_BIN_LSHR: return LLVMBuildLShr(e->builder, lhs, rhs, "op");
        case SA_BIN_ASHR: return LLVMBuildAShr(e->builder, lhs, rhs, "op");
        case SA_BIN_EQ: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_NE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntNE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SLT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSLT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SLE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSLE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SGT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSGT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SGE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSGE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_ULT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntULT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_ULE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntULE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_UGT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_UGE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_FADD: return LLVMBuildFAdd(e->builder, lhs, rhs, "fop");
        case SA_BIN_FSUB: return LLVMBuildFSub(e->builder, lhs, rhs, "fop");
        case SA_BIN_FMUL: return LLVMBuildFMul(e->builder, lhs, rhs, "fop");
        case SA_BIN_FDIV: return LLVMBuildFDiv(e->builder, lhs, rhs, "fop");
        case SA_BIN_FCMP_EQ: return LLVMBuildZExt(e->builder, LLVMBuildFCmp(e->builder, LLVMRealOEQ, lhs, rhs, "fcmp"), e->i64_ty, "bool64");
        case SA_BIN_FCMP_NE: return LLVMBuildZExt(e->builder, LLVMBuildFCmp(e->builder, LLVMRealUNE, lhs, rhs, "fcmp"), e->i64_ty, "bool64");
        case SA_BIN_FCMP_LT: return LLVMBuildZExt(e->builder, LLVMBuildFCmp(e->builder, LLVMRealOLT, lhs, rhs, "fcmp"), e->i64_ty, "bool64");
        case SA_BIN_FCMP_LE: return LLVMBuildZExt(e->builder, LLVMBuildFCmp(e->builder, LLVMRealOLE, lhs, rhs, "fcmp"), e->i64_ty, "bool64");
        case SA_BIN_FCMP_GT: return LLVMBuildZExt(e->builder, LLVMBuildFCmp(e->builder, LLVMRealOGT, lhs, rhs, "fcmp"), e->i64_ty, "bool64");
        case SA_BIN_FCMP_GE: return LLVMBuildZExt(e->builder, LLVMBuildFCmp(e->builder, LLVMRealOGE, lhs, rhs, "fcmp"), e->i64_ty, "bool64");
    }
    return NULL;
}

static int binop_is_float(SaBinaryOp op) {
    return op >= SA_BIN_FADD && op <= SA_BIN_FCMP_GE;
}

static int binop_is_float_cmp(SaBinaryOp op) {
    return op >= SA_BIN_FCMP_EQ && op <= SA_BIN_FCMP_GE;
}

static SaType float_binop_operand_type(SaType lhs, SaType rhs, SaType fallback) {
    if (lhs == SA_T_F64 || rhs == SA_T_F64 || fallback == SA_T_F64) return SA_T_F64;
    if (lhs == SA_T_F32 || rhs == SA_T_F32 || fallback == SA_T_F32) return SA_T_F32;
    return SA_T_F64;
}

static void debug_init(EmitCtx *e, const SaModule *m) {
    if (m == NULL || !m->debug) return;
    const char *source_file = m->source_file != NULL ? m->source_file : "unknown.sars";
    const char *source_dir = m->source_dir != NULL ? m->source_dir : ".";
    e->debug = 1;
    e->dib = LLVMCreateDIBuilder(e->module);
    e->di_file = LLVMDIBuilderCreateFile(e->dib, source_file, strlen(source_file), source_dir, strlen(source_dir));
    e->di_cu = LLVMDIBuilderCreateCompileUnit(
        e->dib,
        LLVMDWARFSourceLanguageC99,
        e->di_file,
        "sa",
        2,
        1,
        "",
        0,
        0,
        "",
        0,
        LLVMDWARFEmissionFull,
        0,
        0,
        0,
        "",
        0,
        "",
        0
    );
    e->di_subroutine_type = LLVMDIBuilderCreateSubroutineType(e->dib, e->di_file, NULL, 0, LLVMDIFlagZero);
    e->di_i1_type = LLVMDIBuilderCreateBasicType(e->dib, "bool", strlen("bool"), 1, 0x02, LLVMDIFlagZero);
    e->di_i8_type = LLVMDIBuilderCreateBasicType(e->dib, "u8", strlen("u8"), 8, 0x08, LLVMDIFlagZero);
    e->di_i16_type = LLVMDIBuilderCreateBasicType(e->dib, "i16", strlen("i16"), 16, 0x05, LLVMDIFlagZero);
    e->di_i32_type = LLVMDIBuilderCreateBasicType(e->dib, "i32", strlen("i32"), 32, 0x05, LLVMDIFlagZero);
    e->di_i64_type = LLVMDIBuilderCreateBasicType(e->dib, "i64", strlen("i64"), 64, 0x05, LLVMDIFlagZero);
    e->di_f32_type = LLVMDIBuilderCreateBasicType(e->dib, "f32", strlen("f32"), 32, 0x04, LLVMDIFlagZero);
    e->di_f64_type = LLVMDIBuilderCreateBasicType(e->dib, "f64", strlen("f64"), 64, 0x04, LLVMDIFlagZero);
    e->di_ptr_type = LLVMDIBuilderCreatePointerType(e->dib, e->di_i8_type, e->size_bits, 0, 0, "ptr", strlen("ptr"));
    LLVMAddModuleFlag(e->module, LLVMModuleFlagBehaviorWarning, "Dwarf Version", strlen("Dwarf Version"), LLVMValueAsMetadata(LLVMConstInt(e->i32_ty, 4, 0)));
    LLVMAddModuleFlag(e->module, LLVMModuleFlagBehaviorWarning, "Debug Info Version", strlen("Debug Info Version"), LLVMValueAsMetadata(LLVMConstInt(e->i32_ty, LLVMDebugMetadataVersion(), 0)));
}

static LLVMMetadataRef debug_type_for(EmitCtx *e, SaType ty) {
    switch (ty) {
        case SA_T_I1: return e->di_i1_type;
        case SA_T_I8: return e->di_i8_type;
        case SA_T_U8: return e->di_i8_type;
        case SA_T_I16: return e->di_i16_type;
        case SA_T_U16: return e->di_i16_type;
        case SA_T_I32: return e->di_i32_type;
        case SA_T_U32: return e->di_i32_type;
        case SA_T_I64: return e->di_i64_type;
        case SA_T_U64: return e->di_i64_type;
        case SA_T_F32: return e->di_f32_type;
        case SA_T_F64: return e->di_f64_type;
        case SA_T_PTR: return e->di_ptr_type;
        case SA_T_VOID: return e->di_i64_type;
    }
    return e->di_i64_type;
}

static LLVMMetadataRef debug_subprogram(EmitCtx *e, LLVMValueRef fn, const SaFunction *f) {
    if (!e->debug || e->dib == NULL || f == NULL) return NULL;
    const char *name = f->name != NULL ? f->name : "<unknown>";
    const char *linkage = f->name != NULL ? f->name : "";
    const char *source_file = f->source_file != NULL ? f->source_file : NULL;
    const char *source_dir = f->source_dir != NULL ? f->source_dir : NULL;
    LLVMMetadataRef file = e->di_file;
    if (source_file != NULL || source_dir != NULL) {
        const char *file_name = source_file != NULL ? source_file : "unknown.sars";
        const char *dir_name = source_dir != NULL ? source_dir : ".";
        file = LLVMDIBuilderCreateFile(e->dib, file_name, strlen(file_name), dir_name, strlen(dir_name));
    }
    unsigned line = f->entry_line == 0 ? 1 : f->entry_line;
    LLVMMetadataRef sp = LLVMDIBuilderCreateFunction(
        e->dib,
        file,
        name,
        strlen(name),
        linkage,
        strlen(linkage),
        file,
        line,
        e->di_subroutine_type,
        f->kind != SA_F_EXPORTED,
        1,
        line,
        LLVMDIFlagZero,
        1
    );
    LLVMSetSubprogram(fn, sp);
    return sp;
}

static void debug_set_location(EmitCtx *e, LLVMMetadataRef scope, const SaFunction *f, size_t inst_index) {
    if (!e->debug || e->dib == NULL || scope == NULL || f == NULL) return;
    if (inst_index >= f->debug_loc_count || f->debug_locs == NULL) {
        LLVMSetCurrentDebugLocation2(e->builder, NULL);
        return;
    }
    unsigned line = f->debug_locs[inst_index].line;
    if (line == 0) {
        LLVMSetCurrentDebugLocation2(e->builder, NULL);
        return;
    }
    unsigned col = f->debug_locs[inst_index].col;
    LLVMMetadataRef loc = LLVMDIBuilderCreateDebugLocation(e->ctx, line, col, scope, NULL);
    LLVMSetCurrentDebugLocation2(e->builder, loc);
}

static void debug_declare_locals(EmitCtx *e, LLVMMetadataRef scope, const SaFunction *f, RegValue *regs, size_t reg_count, LLVMBasicBlockRef block) {
    if (!e->debug || e->dib == NULL || scope == NULL || f == NULL || f->debug_vars == NULL) return;
    LLVMMetadataRef expr = LLVMDIBuilderCreateExpression(e->dib, NULL, 0);
    unsigned line = f->entry_line == 0 ? 1 : f->entry_line;
    unsigned col = f->entry_col == 0 ? 1 : f->entry_col;
    LLVMMetadataRef loc = LLVMDIBuilderCreateDebugLocation(e->ctx, line, col, scope, NULL);
    for (size_t i = 0; i < f->debug_var_count; i++) {
        const SaDebugVar *var = &f->debug_vars[i];
        if (var->slot >= reg_count || regs[var->slot].slot == NULL || var->name == NULL) continue;
        LLVMMetadataRef ty = debug_type_for(e, var->ty);
        LLVMMetadataRef info;
        unsigned var_line = var->line == 0 ? line : var->line;
        if (var->is_param) {
            info = LLVMDIBuilderCreateParameterVariable(e->dib, scope, var->name, strlen(var->name), var->slot + 1, e->di_file, var_line, ty, 1, LLVMDIFlagZero);
        } else {
            info = LLVMDIBuilderCreateAutoVariable(e->dib, scope, var->name, strlen(var->name), e->di_file, var_line, ty, 1, LLVMDIFlagZero, 64);
        }
        LLVMDIBuilderInsertDeclareAtEnd(e->dib, regs[var->slot].slot, info, expr, loc, block);
    }
}

static void note_operand_reg(const SaOperand *op, size_t *max_reg) {
    if (op != NULL && op->kind == SA_OPER_REG && (size_t)op->reg > *max_reg) *max_reg = op->reg;
}

static size_t function_reg_count(const SaFunction *f) {
    size_t max_reg = 0;
    for (size_t i = 0; i < f->param_count; i++) {
        if ((size_t)f->params[i].slot > max_reg) max_reg = f->params[i].slot;
    }
    for (size_t i = 0; i < f->instruction_count; i++) {
        const SaInstruction *in = &f->instructions[i];
        if (in->has_dst && (size_t)in->dst > max_reg) max_reg = in->dst;
        note_operand_reg(&in->operand0, &max_reg);
        note_operand_reg(&in->operand1, &max_reg);
        note_operand_reg(&in->operand2, &max_reg);
        for (size_t a = 0; a < in->arg_count; a++) note_operand_reg(&in->args[a], &max_reg);
    }
    return max_reg + 1;
}

static int emit_function_body(EmitCtx *e, const SaFunction *f) {
    LLVMValueRef fn = find_function(e, f->name);
    if (fn == NULL) return fail_body(e, f, NULL, 0, "function not found");
    LLVMMetadataRef debug_scope = debug_subprogram(e, fn, f);
    size_t reg_count = function_reg_count(f);
    if (reg_count < 1) reg_count = 1;
    RegValue *regs = (RegValue *)calloc(reg_count, sizeof(RegValue));
    LabelEntry *labels = (LabelEntry *)calloc(f->instruction_count + 1, sizeof(LabelEntry));
    if (regs == NULL || labels == NULL) { free(regs); free(labels); return fail_body(e, f, NULL, 0, "alloc frame failed"); }
    size_t label_count = 0;
    for (size_t i = 0; i < reg_count; i++) regs[i].indirect_sig_index = UINT_MAX;

    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    for (size_t i = 0; i < reg_count; i++) {
        regs[i].slot = LLVMBuildAlloca(e->builder, e->i64_ty, "sa_slot");
        LLVMBuildStore(e->builder, LLVMConstInt(e->i64_ty, 0, 0), regs[i].slot);
    }
    debug_declare_locals(e, debug_scope, f, regs, reg_count, entry);
    for (size_t i = 0; i < f->param_count; i++) {
        if (f->params[i].slot < reg_count) {
            reg_store(e, regs, reg_count, f->params[i].slot, LLVMGetParam(fn, (unsigned)i), f->params[i].ty, 0, UINT_MAX);
        }
    }
    for (size_t i = 0; i < f->instruction_count; i++) {
        if (f->instructions[i].op == SA_OP_LABEL && f->instructions[i].label != NULL) {
            labels[label_count].name = f->instructions[i].label;
            labels[label_count].block = LLVMAppendBasicBlockInContext(e->ctx, fn, f->instructions[i].label);
            label_count++;
        }
    }

    for (size_t i = 0; i < f->instruction_count; i++) {
        const SaInstruction *in = &f->instructions[i];
        LLVMValueRef v0, v1, v2;
        SaType t0, t1, t2;
        snprintf(e->body_error, sizeof(e->body_error), "emit body failed in %s instruction %zu op %d", f->name, i, (int)in->op);
        debug_set_location(e, debug_scope, f, i);
        switch (in->op) {
            case SA_OP_LABEL: {
                LLVMBasicBlockRef bb = label_block(labels, label_count, in->label);
                if (bb == NULL) { free(regs); free(labels); return 1; }
                if (!current_has_terminator(e)) LLVMBuildBr(e->builder, bb);
                LLVMPositionBuilderAtEnd(e->builder, bb);
                break;
            }
            case SA_OP_ALLOC:
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64);
                v0 = coerce_to_size(e, v0, "alloc_size");
if (reg_store(e, regs, reg_count, in->dst, LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &v0, 1, "malloced"), SA_T_PTR, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                regs[in->dst].is_malloc = 1;
                break;
            case SA_OP_STACK_ALLOC:
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64);
                v0 = coerce_to_size(e, v0, "stack_size");
                LLVMValueRef stack_mem = LLVMBuildArrayAlloca(e->builder, e->i8_ty, v0, "stack_alloc");
                LLVMSetAlignment(stack_mem, 16);
                if (reg_store(e, regs, reg_count, in->dst, stack_mem, SA_T_PTR, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_TAKE:
            case SA_OP_LOAD:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64);
                LLVMValueRef gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "gep");
                LLVMTypeRef load_ty = type_of(e, in->ty);
                LLVMValueRef load_ptr = LLVMBuildPointerCast(e->builder, gep, LLVMPointerType(load_ty, 0), "load_ptr");
                LLVMValueRef load_inst = LLVMBuildLoad2(e->builder, load_ty, load_ptr, "load");
                LLVMSetAlignment(load_inst, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, load_inst, in->ty, 0, in->indirect_sig_index)) { free(regs); free(labels); return 1; }
                if (in->op == SA_OP_TAKE && in->ty == SA_T_PTR) {
                    regs[in->dst].is_malloc = 1;
                }
                break;
            case SA_OP_STORE:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64); v2 = coerce(e, v2, t2, in->ty);
                LLVMValueRef store_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "gep");
                LLVMTypeRef store_ty = type_of(e, in->ty);
                LLVMValueRef store_ptr = LLVMBuildPointerCast(e->builder, store_gep, LLVMPointerType(store_ty, 0), "store_ptr");
                LLVMValueRef store_inst = LLVMBuildStore(e->builder, v2, store_ptr);
                LLVMSetAlignment(store_inst, align_of(in->ty));
                break;
            case SA_OP_ATOMIC_LOAD:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64);
                LLVMValueRef atomic_load_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "atomic_gep");
                LLVMTypeRef atomic_load_ty = type_of(e, in->ty);
                LLVMValueRef atomic_load_ptr = LLVMBuildPointerCast(e->builder, atomic_load_gep, LLVMPointerType(atomic_load_ty, 0), "atomic_load_ptr");
                LLVMValueRef atomic_loaded = LLVMBuildLoad2(e->builder, atomic_load_ty, atomic_load_ptr, "atomic_load");
                LLVMSetOrdering(atomic_loaded, atomic_ordering(in->atomic_ordering));
                LLVMSetAlignment(atomic_loaded, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, atomic_loaded, in->ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_ATOMIC_STORE:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64); v2 = coerce(e, v2, t2, in->ty);
                LLVMValueRef atomic_store_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "atomic_gep");
                LLVMTypeRef atomic_store_ty = type_of(e, in->ty);
                LLVMValueRef atomic_store_ptr = LLVMBuildPointerCast(e->builder, atomic_store_gep, LLVMPointerType(atomic_store_ty, 0), "atomic_store_ptr");
                LLVMValueRef atomic_store_inst = LLVMBuildStore(e->builder, v2, atomic_store_ptr);
                LLVMSetOrdering(atomic_store_inst, atomic_ordering(in->atomic_ordering));
                LLVMSetAlignment(atomic_store_inst, align_of(in->ty));
                break;
            case SA_OP_ATOMIC_RMW:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64); v2 = coerce(e, v2, t2, in->ty);
                LLVMValueRef atomic_rmw_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "atomic_gep");
                LLVMTypeRef atomic_rmw_ty = type_of(e, in->ty);
                LLVMValueRef atomic_rmw_ptr = LLVMBuildPointerCast(e->builder, atomic_rmw_gep, LLVMPointerType(atomic_rmw_ty, 0), "atomic_rmw_ptr");
                LLVMValueRef atomic_rmw = LLVMBuildAtomicRMW(e->builder, atomic_rmw_op(in->atomic_rmw_op), atomic_rmw_ptr, v2, atomic_ordering(in->atomic_ordering), 0);
                LLVMSetAlignment(atomic_rmw, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, atomic_rmw, in->ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_CMPXCHG: {
                if (in->arg_count < 2) { free(regs); free(labels); return 1; }
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                LLVMValueRef new_value;
                SaType new_ty;
                if (operand_value(e, &in->args[0], regs, reg_count, &new_value, &new_ty)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR);
                v1 = coerce(e, v1, t1, SA_T_I64);
                v2 = coerce(e, v2, t2, in->ty);
                new_value = coerce(e, new_value, new_ty, in->ty);
                LLVMValueRef cmpxchg_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "cmpxchg_gep");
                LLVMTypeRef cmpxchg_ty = type_of(e, in->ty);
                LLVMValueRef cmpxchg_ptr = LLVMBuildPointerCast(e->builder, cmpxchg_gep, LLVMPointerType(cmpxchg_ty, 0), "cmpxchg_ptr");
                LLVMValueRef pair = LLVMBuildAtomicCmpXchg(e->builder, cmpxchg_ptr, v2, new_value, atomic_ordering(in->atomic_ordering), atomic_ordering(in->atomic_second_ordering), 0);
                LLVMSetAlignment(pair, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildExtractValue(e->builder, pair, 0, "cmpxchg_old"), in->ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                unsigned int ok_slot = in->args[1].reg;
                if (ok_slot >= reg_count) { free(regs); free(labels); return 1; }
                if (reg_store(e, regs, reg_count, ok_slot, LLVMBuildExtractValue(e->builder, pair, 1, "cmpxchg_ok"), SA_T_I1, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            }
            case SA_OP_FENCE:
                LLVMBuildFence(e->builder, atomic_ordering(in->atomic_ordering), 0, "");
                break;
            case SA_OP_BINOP:
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                if (binop_is_float(in->binary_op)) {
                    SaType op_ty = float_binop_operand_type(t0, t1, in->ty);
                    v0 = coerce(e, v0, t0, op_ty);
                    v1 = coerce(e, v1, t1, op_ty);
                    SaType result_ty = binop_is_float_cmp(in->binary_op) ? SA_T_I64 : op_ty;
                    if (reg_store(e, regs, reg_count, in->dst, build_binop(e, in->binary_op, v0, v1), result_ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                } else {
                    v0 = coerce(e, v0, t0, SA_T_I64); v1 = coerce(e, v1, t1, SA_T_I64);
                    if (reg_store(e, regs, reg_count, in->dst, build_binop(e, in->binary_op, v0, v1), SA_T_I64, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                }
                break;
            case SA_OP_PTR_ADD:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64);
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "ptradd"), SA_T_PTR, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_ASSIGN: {
                if (in->dst >= reg_count) { free(regs); free(labels); return fail_body(e, f, in, i, "assign destination out of range"); }
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return fail_body(e, f, in, i, "assign operand unavailable"); }
                SaType dst_ty = in->ty == SA_T_VOID ? t0 : in->ty;
                unsigned char dst_fallible = 0;
                unsigned int dst_indirect = in->indirect_sig_index;
                unsigned char src_is_malloc = 0;
                if (in->operand0.kind == SA_OPER_REG && in->operand0.reg < reg_count) {
                    dst_fallible = regs[in->operand0.reg].fallible;
                    dst_indirect = regs[in->operand0.reg].indirect_sig_index;
                    if (in->is_malloc) src_is_malloc = regs[in->operand0.reg].is_malloc;
                }
                if (dst_fallible) {
                    if (reg_store(e, regs, reg_count, in->dst, v0, t0, dst_fallible, dst_indirect)) { free(regs); free(labels); return 1; }
                } else {
                    if (reg_store(e, regs, reg_count, in->dst, coerce(e, v0, t0, dst_ty), dst_ty, dst_fallible, dst_indirect)) { free(regs); free(labels); return 1; }
                }
                regs[in->dst].is_malloc = (t0 == SA_T_PTR) ? src_is_malloc : 0;
                break;
            }
            case SA_OP_JMP: {
                LLVMBasicBlockRef bb = label_block(labels, label_count, in->label);
                if (bb == NULL) { free(regs); free(labels); return 1; }
                LLVMBuildBr(e->builder, bb);
                break;
            }
            case SA_OP_BR: {
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64);
                LLVMValueRef cond = LLVMBuildICmp(e->builder, LLVMIntNE, v0, LLVMConstInt(e->i64_ty, 0, 0), "cond");
                LLVMBasicBlockRef tb = label_block(labels, label_count, in->label);
                LLVMBasicBlockRef fb = label_block(labels, label_count, in->false_label);
                if (tb == NULL || fb == NULL) { free(regs); free(labels); return 1; }
                LLVMBuildCondBr(e->builder, cond, tb, fb);
                break;
            }
            case SA_OP_CALL: {
                LLVMValueRef callee = find_function(e, in->callee);
                if (callee == NULL) { free(regs); free(labels); return fail_body_callee(e, f, in, i, "callee not found"); }
                const SaFunction *callee_sig = function_by_name(e, in->callee);
                int sret = external_fallible_uses_sret_win64(callee_sig);
                LLVMTypeRef fn_ty = LLVMGlobalGetValueType(callee);
                unsigned param_count = LLVMCountParamTypes(fn_ty);
                LLVMTypeRef *param_types = NULL;
                if (param_count != 0) param_types = (LLVMTypeRef *)malloc(sizeof(LLVMTypeRef) * param_count);
                if (param_count != 0 && param_types == NULL) { free(regs); free(labels); return fail_body(e, f, in, i, "alloc param types failed"); }
                if (param_count != 0) LLVMGetParamTypes(fn_ty, param_types);
                size_t total_args = in->arg_count + (sret ? 1 : 0);
                LLVMValueRef *args = NULL;
                if (total_args != 0) args = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * total_args);
                if (total_args != 0 && args == NULL) { free(param_types); free(regs); free(labels); return fail_body(e, f, in, i, "alloc call args failed"); }
                size_t slot_index = 0;
                LLVMValueRef sret_slot = NULL;
                if (sret) {
                    LLVMTypeRef result_struct = fallible_type_of(e, callee_sig->ret_ty);
                    sret_slot = LLVMBuildAlloca(e->builder, result_struct, "sret_slot");
                    LLVMSetAlignment(sret_slot, 8);
                    args[slot_index++] = sret_slot;
                }
                for (size_t a = 0; a < in->arg_count; a++) {
                    SaType aty;
                    if (operand_value(e, &in->args[a], regs, reg_count, &args[slot_index], &aty)) { free(param_types); free(args); free(regs); free(labels); return fail_body(e, f, in, i, "call argument unavailable"); }
                    if ((slot_index) < param_count) args[slot_index] = coerce(e, args[slot_index], aty, sa_type_from_llvm(param_types[slot_index]));
                    slot_index++;
                }
                free(param_types);
                LLVMValueRef callv = LLVMBuildCall2(e->builder, fn_ty, callee, args, (unsigned)total_args, sret ? "" : (in->has_dst ? "call" : ""));
                LLVMValueRef resultv = callv;
                if (external_fallible_i32_uses_i64_abi(e, callee_sig)) resultv = unpack_external_fallible_i32(e, callv);
                if (sret) {
                    LLVMTypeRef result_struct = fallible_type_of(e, callee_sig->ret_ty);
                    LLVMValueRef agg = LLVMGetUndef(result_struct);
                    LLVMValueRef status_ptr = LLVMBuildStructGEP2(e->builder, result_struct, sret_slot, 0, "sret_status_slot");
                    LLVMValueRef payload_ptr = LLVMBuildStructGEP2(e->builder, result_struct, sret_slot, 1, "sret_payload_slot");
                    LLVMValueRef status = LLVMBuildLoad2(e->builder, e->i32_ty, status_ptr, "sret_status");
                    LLVMValueRef payload = LLVMBuildLoad2(e->builder, type_of(e, callee_sig->ret_ty), payload_ptr, "sret_payload");
                    agg = LLVMBuildInsertValue(e->builder, agg, status, 0, "sret_result_status");
                    resultv = LLVMBuildInsertValue(e->builder, agg, payload, 1, "sret_result");
                }
                if (self_call_is_immediate_tail_return(f, i)) {
                    if (!sret) LLVMSetTailCall(callv, 1);
                    if (f->ret_ty == SA_T_VOID) {
                        LLVMBuildRetVoid(e->builder);
                    } else {
                        LLVMBuildRet(e->builder, coerce(e, resultv, in->ty, f->ret_ty));
                    }
                    free(args);
                    i += 1;
                    break;
                }
                if (in->has_dst) {
                    if (reg_store(e, regs, reg_count, in->dst, resultv, in->ty, in->return_fallible, UINT_MAX)) { free(args); free(regs); free(labels); return 1; }
                    regs[in->dst].is_malloc = (in->ty == SA_T_PTR) ? in->is_malloc : 0;
                }
                free(args);
                break;
            }
            case SA_OP_CALL_INDIRECT: {
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return fail_body(e, f, in, i, "indirect callee operand unavailable"); }
                unsigned int sig_index = UINT_MAX;
                if (in->operand0.kind == SA_OPER_REG && in->operand0.reg < reg_count) {
                    sig_index = regs[in->operand0.reg].indirect_sig_index;
                }
                const SaFunction *target_sig = function_by_index(e, sig_index);
                LLVMValueRef *args = NULL;
                SaType *arg_tys = NULL;
                if (in->arg_count != 0) {
                    args = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * in->arg_count);
                    arg_tys = (SaType *)malloc(sizeof(SaType) * in->arg_count);
                }
                if (in->arg_count != 0 && (args == NULL || arg_tys == NULL)) {
                    free(args);
                    free(arg_tys);
                    free(regs);
                    free(labels);
                    return fail_body(e, f, in, i, "alloc indirect args failed");
                }
                for (size_t a = 0; a < in->arg_count; a++) {
                    SaType aty;
                    if (operand_value(e, &in->args[a], regs, reg_count, &args[a], &aty)) { free(arg_tys); free(args); free(regs); free(labels); return fail_body(e, f, in, i, "indirect argument unavailable"); }
                    arg_tys[a] = aty;
                }

                if (target_sig == NULL) {
                    sig_index = infer_indirect_sig_index(e, in, arg_tys);
                    target_sig = function_by_index(e, sig_index);
                }
                if (target_sig == NULL) { free(arg_tys); free(args); free(regs); free(labels); return fail_body(e, f, in, i, "indirect callee missing signature provenance"); }

                LLVMTypeRef fn_ty = indirect_fn_type_for(e, target_sig, in);
                if (fn_ty == NULL) { free(regs); free(labels); return fail_body(e, f, in, i, "indirect function type failed"); }
                for (size_t a = 0; a < in->arg_count; a++) {
                    SaType param_ty = a < target_sig->param_count ? target_sig->params[a].ty : arg_tys[a];
                    if (a < in->indirect_param_count) param_ty = in->indirect_param_tys[a];
                    args[a] = coerce(e, args[a], arg_tys[a], param_ty);
                }
                free(arg_tys);
                LLVMValueRef callee = coerce(e, v0, t0, SA_T_PTR);
                callee = LLVMBuildPointerCast(e->builder, callee, LLVMPointerType(fn_ty, 0), "indirect_fn");
                LLVMValueRef callv = LLVMBuildCall2(e->builder, fn_ty, callee, args, (unsigned)in->arg_count, in->has_dst ? "call_indirect" : "");
                if (in->has_dst) {
                    if (reg_store(e, regs, reg_count, in->dst, callv, target_sig->ret_ty, target_sig->return_fallible, UINT_MAX)) { free(args); free(regs); free(labels); return 1; }
                    regs[in->dst].is_malloc = (in->ty == SA_T_PTR) ? in->is_malloc : 0;
                }
                free(args);
                break;
            }
            case SA_OP_TRY: {
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                if (in->operand0.kind != SA_OPER_REG || !regs[in->operand0.reg].fallible) { free(regs); free(labels); return 1; }
                unsigned int src_reg = in->operand0.reg;
                unsigned char src_is_malloc = regs[src_reg].is_malloc;
                LLVMValueRef status = LLVMBuildExtractValue(e->builder, v0, 0, "try_status");
                LLVMValueRef ok = LLVMBuildICmp(e->builder, LLVMIntEQ, status, LLVMConstInt(e->i32_ty, 0, 0), "try_ok");
                LLVMBasicBlockRef current = LLVMGetInsertBlock(e->builder);
                LLVMValueRef current_fn = LLVMGetBasicBlockParent(current);
                LLVMBasicBlockRef ok_bb = LLVMAppendBasicBlockInContext(e->ctx, current_fn, "try_ok");
                LLVMBasicBlockRef early_bb = LLVMAppendBasicBlockInContext(e->ctx, current_fn, "try_early");
                LLVMBuildCondBr(e->builder, ok, ok_bb, early_bb);
                LLVMPositionBuilderAtEnd(e->builder, early_bb);
                if (f->return_fallible) {
                    LLVMBuildRet(e->builder, build_fallible_err(e, f->ret_ty, status));
                } else if (f->ret_ty == SA_T_VOID) {
                    LLVMBuildRetVoid(e->builder);
                } else {
                    LLVMBuildRet(e->builder, default_value_of(e, f->ret_ty));
                }
                LLVMPositionBuilderAtEnd(e->builder, ok_bb);
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildExtractValue(e->builder, v0, 1, "try_payload"), t0, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                regs[in->dst].is_malloc = (t0 == SA_T_PTR) ? src_is_malloc : 0;
                break;
            }
            case SA_OP_RET:
                if (f->return_fallible) {
                    if (!in->has_dst || f->ret_ty == SA_T_VOID) { free(regs); free(labels); return 1; }
                    if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                    if (in->operand0.kind == SA_OPER_REG && regs[in->operand0.reg].fallible) {
                        LLVMBuildRet(e->builder, v0);
                    } else {
                        LLVMBuildRet(e->builder, build_fallible_ok(e, f->ret_ty, v0, t0));
                    }
                } else if (!in->has_dst || f->ret_ty == SA_T_VOID) {
                    LLVMBuildRetVoid(e->builder);
                } else {
                    if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                    v0 = coerce(e, v0, t0, f->ret_ty);
                    LLVMBuildRet(e->builder, v0);
                }
                break;
            case SA_OP_PANIC: {
                if (in->operand0.kind == SA_OPER_NONE) { free(regs); free(labels); return 1; }
                LLVMValueRef code = NULL;
                SaType code_ty;
                if (operand_value(e, &in->operand0, regs, reg_count, &code, &code_ty)) { free(regs); free(labels); return 1; }
                code = coerce(e, code, code_ty, SA_T_I32);
                LLVMValueRef panic_msg_fn = LLVMGetNamedFunction(e->module, "panic_msg");
                if (panic_msg_fn == NULL) { free(regs); free(labels); return 1; }
                LLVMValueRef args[3] = {
                    code,
                    LLVMConstNull(e->ptr_ty),
                    LLVMConstInt(e->i64_ty, 0, 0)
                };
                LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(panic_msg_fn), panic_msg_fn, args, 3, "");
                LLVMBuildUnreachable(e->builder);
                break;
            }
            case SA_OP_PANIC_MSG: {
                if (in->operand0.kind == SA_OPER_NONE || in->operand1.kind == SA_OPER_NONE || in->operand2.kind == SA_OPER_NONE) { free(regs); free(labels); return 1; }
                LLVMValueRef code = NULL, msg_ptr = NULL, msg_len = NULL;
                SaType code_ty, msg_ptr_ty, msg_len_ty;
                if (operand_value(e, &in->operand0, regs, reg_count, &code, &code_ty) || operand_value(e, &in->operand1, regs, reg_count, &msg_ptr, &msg_ptr_ty) || operand_value(e, &in->operand2, regs, reg_count, &msg_len, &msg_len_ty)) { free(regs); free(labels); return 1; }
                code = coerce(e, code, code_ty, SA_T_I32);
                msg_ptr = coerce(e, msg_ptr, msg_ptr_ty, SA_T_PTR);
                msg_len = coerce(e, msg_len, msg_len_ty, SA_T_I64);
                LLVMValueRef panic_msg_fn = LLVMGetNamedFunction(e->module, "panic_msg");
                if (panic_msg_fn == NULL) { free(regs); free(labels); return 1; }
                LLVMValueRef args[3] = { code, msg_ptr, msg_len };
                LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(panic_msg_fn), panic_msg_fn, args, 3, "");
                break;
            }
            case SA_OP_RELEASE: {
                if (in->operand0.kind == SA_OPER_REG && in->operand0.reg < reg_count && in->ty == SA_T_PTR) {
                    if (regs[in->operand0.reg].is_malloc) {
                        if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                        v0 = coerce(e, v0, t0, SA_T_PTR);
                        LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->free_fn), e->free_fn, &v0, 1, "");
                    }
                }
                break;
            }
            default:
                free(regs); free(labels); return 1;
        }
    }
    LLVMSetCurrentDebugLocation2(e->builder, NULL);
    if (!current_has_terminator(e)) {
        if (f->return_fallible) {
            LLVMValueRef zero = LLVMConstInt(type_of(e, f->ret_ty), 0, 0);
            LLVMBuildRet(e->builder, build_fallible_ok(e, f->ret_ty, zero, f->ret_ty));
        } else if (f->ret_ty == SA_T_VOID) LLVMBuildRetVoid(e->builder);
        else LLVMBuildRet(e->builder, LLVMConstInt(type_of(e, f->ret_ty), 0, 0));
    }
    free(regs);
    free(labels);
    return 0;
}

static int declare_runtime(EmitCtx *e) {
    LLVMTypeRef sz_ty = size_type(e);
    LLVMTypeRef malloc_params[1] = { sz_ty };
    e->malloc_fn = LLVMAddFunction(e->module, "malloc", LLVMFunctionType(e->ptr_ty, malloc_params, 1, 0));
    LLVMTypeRef free_params[1] = { e->ptr_ty };
    e->free_fn = LLVMAddFunction(e->module, "free", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), free_params, 1, 0));
    LLVMTypeRef write_params[3] = { e->i32_ty, e->ptr_ty, sz_ty };
    e->write_fn = LLVMAddFunction(e->module, "write", LLVMFunctionType(sz_ty, write_params, 3, 0));
    LLVMTypeRef exit_params[1] = { e->i32_ty };
    e->exit_fn = LLVMAddFunction(e->module, "exit", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), exit_params, 1, 0));
    LLVMTypeRef memcpy_params[3] = { e->ptr_ty, e->ptr_ty, sz_ty };
    e->memcpy_fn = LLVMAddFunction(e->module, "memcpy", LLVMFunctionType(e->ptr_ty, memcpy_params, 3, 0));
    LLVMTypeRef fopen_params[2] = { e->ptr_ty, e->ptr_ty };
    e->fopen_fn = LLVMAddFunction(e->module, "fopen", LLVMFunctionType(e->ptr_ty, fopen_params, 2, 0));
    LLVMTypeRef fclose_params[1] = { e->ptr_ty };
    e->fclose_fn = LLVMAddFunction(e->module, "fclose", LLVMFunctionType(e->i32_ty, fclose_params, 1, 0));
    LLVMTypeRef fread_params[4] = { e->ptr_ty, sz_ty, sz_ty, e->ptr_ty };
    e->fread_fn = LLVMAddFunction(e->module, "fread", LLVMFunctionType(sz_ty, fread_params, 4, 0));
    e->fwrite_fn = LLVMAddFunction(e->module, "fwrite", LLVMFunctionType(sz_ty, fread_params, 4, 0));
    LLVMTypeRef fseek_params[3] = { e->ptr_ty, sz_ty, e->i32_ty };
    e->fseek_fn = LLVMAddFunction(e->module, "fseek", LLVMFunctionType(e->i32_ty, fseek_params, 3, 0));
    LLVMTypeRef ftell_params[1] = { e->ptr_ty };
    e->ftell_fn = LLVMAddFunction(e->module, "ftell", LLVMFunctionType(sz_ty, ftell_params, 1, 0));
    e->rewind_fn = LLVMAddFunction(e->module, "rewind", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), ftell_params, 1, 0));
    unsigned char has_main_wrapper = 0;
    for (size_t i = 0; i < e->function_count; i++) {
        if (e->functions[i].emit_main_wrapper) {
            has_main_wrapper = 1;
            break;
        }
    }
    e->saasm_argc_global = LLVMAddGlobal(e->module, e->i32_ty, "saasm_argc");
    e->saasm_argv_global = LLVMAddGlobal(e->module, e->ptr_ty, "saasm_argv");
    if (e->is_cgu && !has_main_wrapper) {
        LLVMSetLinkage(e->saasm_argc_global, LLVMExternalLinkage);
        LLVMSetLinkage(e->saasm_argv_global, LLVMExternalLinkage);
    } else {
        LLVMSetLinkage(e->saasm_argc_global, LLVMWeakAnyLinkage);
        LLVMSetLinkage(e->saasm_argv_global, LLVMWeakAnyLinkage);
        LLVMSetInitializer(e->saasm_argc_global, LLVMConstInt(e->i32_ty, 0, 0));
        LLVMSetInitializer(e->saasm_argv_global, LLVMConstPointerNull(e->ptr_ty));
    }
    return 0;
}

static void declare_sa_print_bytes(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_print_bytes");
    if (fn == NULL) {
        fn = LLVMAddFunction(e->module, "sa_print_bytes", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 2, 0));
    }
    LLVMSetLinkage(fn, LLVMExternalLinkage);
}

static void emit_sa_print_bytes(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_print_bytes");
    if (fn == NULL) {
        fn = LLVMAddFunction(e->module, "sa_print_bytes", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 2, 0));
    }
    if (LLVMCountBasicBlocks(fn) != 0) return;
    // weak: wasm32-wasi archive (same ABI) wins when linked; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef len = coerce_to_size(e, LLVMGetParam(fn, 1), "len_size");
    LLVMValueRef args[3] = { LLVMConstInt(e->i32_ty, 1, 0), LLVMGetParam(fn, 0), len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, args, 3, "");
    LLVMBuildRetVoid(e->builder);
}

/* sa_hexdec_simd for wasm: in-module vector hex decoder. Native links
   libsa (which owns the Zig @Vector implementation), so this only fills
   the body when a wasm_compat module left an external declaration behind.
   Contract mirrors sa_hexdec_simd in sa_std.zig: clean even-length input
   of n chars yields n/2 bytes; stops at the first invalid char or odd
   trailing nibble, returning bytes written. Vector path handles 16 input
   chars per iteration (single-source shuffles only); scalar tail covers
   the rest. Correct with or without SIMD128 (falls back to scalarized
   vectors); +simd128 at link time uses real v128 ops. */
static LLVMValueRef wasm_const_splat_u8(EmitCtx *e, LLVMTypeRef vty, unsigned lanes, uint8_t v) {
    LLVMValueRef *vals = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * lanes);
    if (vals == NULL) return NULL;
    for (unsigned k = 0; k < lanes; k++) vals[k] = LLVMConstInt(e->i8_ty, v, 0);
    LLVMValueRef out = LLVMConstVector(vals, lanes);
    free(vals);
    return out;
}

static LLVMValueRef wasm_const_shuf_mask(EmitCtx *e, const unsigned *idx, unsigned lanes) {
    LLVMValueRef *vals = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * lanes);
    if (vals == NULL) return NULL;
    for (unsigned k = 0; k < lanes; k++) vals[k] = LLVMConstInt(e->i32_ty, idx[k], 0);
    LLVMValueRef out = LLVMConstVector(vals, lanes);
    free(vals);
    return out;
}

/* Byte-lane constant for full-width merge masks (0xFF at kept lanes). */
static LLVMValueRef wasm_const_bytes16(EmitCtx *e, LLVMTypeRef vty, const uint8_t *vals) {
    LLVMValueRef elems[16];
    for (unsigned k = 0; k < 16; k++) elems[k] = LLVMConstInt(e->i8_ty, vals[k], 0);
    return LLVMConstVector(elems, 16);
}

/* Looks up a 1-type-param vector intrinsic (e.g. "llvm.wasm.swizzle",
   "llvm.wasm.avgr.unsigned", "llvm.uadd.sat"); NULL when the toolchain
   predates it (caller must bail before emitting blocks). */
static LLVMValueRef wasm_intrinsic1(EmitCtx *e, const char *name, LLVMTypeRef vty) {
    unsigned id = LLVMLookupIntrinsicID(name, strlen(name));
    if (id == 0) return NULL;
    return LLVMGetIntrinsicDeclaration(e->module, id, &vty, 1);
}

/* Calls a (vty, vty) -> vty vector intrinsic. */
static LLVMValueRef wasm_call2(EmitCtx *e, LLVMValueRef fn, LLVMTypeRef vty, LLVMValueRef a, LLVMValueRef bv) {
    LLVMTypeRef pty[2] = { vty, vty };
    LLVMTypeRef fty = LLVMFunctionType(vty, pty, 2, 0);
    LLVMValueRef args[2] = { a, bv };
    return LLVMBuildCall2(e->builder, fty, fn, args, 2, "");
}

/* Calls a (vty, vty, vty) -> vty vector intrinsic (v128.bitselect). */
static LLVMValueRef wasm_call3(EmitCtx *e, LLVMValueRef fn, LLVMTypeRef vty, LLVMValueRef a, LLVMValueRef bv, LLVMValueRef c) {
    LLVMTypeRef pty[3] = { vty, vty, vty };
    LLVMTypeRef fty = LLVMFunctionType(vty, pty, 3, 0);
    LLVMValueRef args[3] = { a, bv, c };
    return LLVMBuildCall2(e->builder, fty, fn, args, 3, "");
}

/* Calls a (v8i16, v8i16) -> v4i32 vector intrinsic (i32x4.dot_i16x8_s). */
static LLVMValueRef wasm_call_dot(EmitCtx *e, LLVMValueRef fn, LLVMTypeRef v8i16, LLVMTypeRef v4i32, LLVMValueRef a, LLVMValueRef bv) {
    LLVMTypeRef pty[2] = { v8i16, v8i16 };
    LLVMTypeRef fty = LLVMFunctionType(v4i32, pty, 2, 0);
    LLVMValueRef args[2] = { a, bv };
    return LLVMBuildCall2(e->builder, fty, fn, args, 2, "");
}

/* Fixed-signature intrinsic (e.g. "llvm.wasm.swizzle" takes no type
   suffix, unlike overloaded ones): declare via GetIntrinsicDeclaration
   with an EMPTY type list, which yields the bare name as a TRUE
   intrinsic. Both alternatives silently misbehave: appending types
   creates "llvm.wasm.swizzle.v16i8" (undefined symbol at link time),
   while LLVMAddFunction makes a plain non-intrinsic function that links
   but is never lowered to the swizzle instruction (wrong output). */
static LLVMValueRef wasm_fixed_intrinsic(EmitCtx *e, const char *name, LLVMTypeRef vty) {
    (void)vty;
    unsigned id = LLVMLookupIntrinsicID(name, strlen(name));
    if (id == 0) return NULL;
    return LLVMGetIntrinsicDeclaration(e->module, id, NULL, 0);
}

static void emit_sa_hexdec_simd_wasm(EmitCtx *e) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_hexdec_simd");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMTypeRef i64 = e->i64_ty;
    LLVMTypeRef v16 = LLVMVectorType(e->i8_ty, 16);
    LLVMTypeRef v8 = LLVMVectorType(e->i8_ty, 8);
    LLVMValueRef in_ptr = LLVMGetParam(fn, 0);
    LLVMValueRef in_len = LLVMGetParam(fn, 1);
    LLVMValueRef out_ptr = LLVMGetParam(fn, 2);
    LLVMValueRef z0 = LLVMConstInt(i64, 0, 0);

    /* Case-fold classify: t = c | 0x20 folds A-F onto a-f, so one digit
       test (t-'0' <= 9) plus one alpha test (t-'a' <= 5) covers all. */
    LLVMValueRef s20 = wasm_const_splat_u8(e, v16, 16, 32);
    LLVMValueRef s48 = wasm_const_splat_u8(e, v16, 16, 48);
    LLVMValueRef s97 = wasm_const_splat_u8(e, v16, 16, 97);
    LLVMValueRef s9v = wasm_const_splat_u8(e, v16, 16, 9);
    LLVMValueRef s5v = wasm_const_splat_u8(e, v16, 16, 5);
    LLVMValueRef s10 = wasm_const_splat_u8(e, v16, 16, 10);
    LLVMValueRef s4v8 = wasm_const_splat_u8(e, v8, 8, 4);
    LLVMValueRef vundef16 = LLVMGetUndef(v16);
    LLVMValueRef vundef8 = LLVMGetUndef(v8);
    static const unsigned even_idx[8] = { 0, 2, 4, 6, 8, 10, 12, 14 };
    static const unsigned odd_idx[8] = { 1, 3, 5, 7, 9, 11, 13, 15 };
    LLVMValueRef even_mask = wasm_const_shuf_mask(e, even_idx, 8);
    LLVMValueRef odd_mask = wasm_const_shuf_mask(e, odd_idx, 8);
    if (!s20 || !s48 || !s97 || !s9v || !s5v || !s10 || !s4v8 || !even_mask || !odd_mask) return;

    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef vecloop = LLVMAppendBasicBlockInContext(e->ctx, fn, "vecloop");
    LLVMBasicBlockRef vecbody = LLVMAppendBasicBlockInContext(e->ctx, fn, "vecbody");
    LLVMBasicBlockRef scalarloop = LLVMAppendBasicBlockInContext(e->ctx, fn, "scalarloop");
    LLVMBasicBlockRef scalarbody = LLVMAppendBasicBlockInContext(e->ctx, fn, "scalarbody");
    LLVMBasicBlockRef ret = LLVMAppendBasicBlockInContext(e->ctx, fn, "ret");

    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef null_ok = LLVMBuildICmp(e->builder, LLVMIntEQ, LLVMBuildPtrToInt(e->builder, in_ptr, i64, ""), z0, "");
    LLVMValueRef null_ok2 = LLVMBuildICmp(e->builder, LLVMIntEQ, LLVMBuildPtrToInt(e->builder, out_ptr, i64, ""), z0, "");
    LLVMValueRef bail = LLVMBuildOr(e->builder, null_ok, null_ok2, "");
    bail = LLVMBuildOr(e->builder, bail, LLVMBuildICmp(e->builder, LLVMIntEQ, in_len, z0, ""), "");
    LLVMBuildCondBr(e->builder, bail, ret, vecloop);

    LLVMPositionBuilderAtEnd(e->builder, vecloop);
    LLVMValueRef phi_i = LLVMBuildPhi(e->builder, i64, "i");
    LLVMValueRef phi_w = LLVMBuildPhi(e->builder, i64, "w");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntULE,
            LLVMBuildAdd(e->builder, phi_i, LLVMConstInt(i64, 16, 0), ""),
            in_len, ""),
        vecbody, scalarloop);

    LLVMPositionBuilderAtEnd(e->builder, vecbody);
    LLVMValueRef in_gep = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &phi_i, 1, "");
    LLVMValueRef in_vgep = LLVMBuildBitCast(e->builder, in_gep, LLVMPointerType(v16, 0), "");
    LLVMValueRef vload = LLVMBuildLoad2(e->builder, v16, in_vgep, "");
    LLVMSetAlignment(vload, 1);
    LLVMValueRef fold = LLVMBuildOr(e->builder, vload, s20, "");
    LLVMValueRef dval = LLVMBuildSub(e->builder, fold, s48, "");
    LLVMValueRef aval = LLVMBuildSub(e->builder, fold, s97, "");
    LLVMValueRef isdig = LLVMBuildICmp(e->builder, LLVMIntULE, dval, s9v, "");
    LLVMValueRef isalp = LLVMBuildICmp(e->builder, LLVMIntULE, aval, s5v, "");
    LLVMValueRef okv = LLVMBuildOr(e->builder, isdig, isalp, "");
    LLVMValueRef okflat = LLVMBuildBitCast(e->builder, okv, LLVMInt16TypeInContext(e->ctx), "");
    LLVMValueRef allok = LLVMBuildICmp(e->builder, LLVMIntEQ, okflat, LLVMConstInt(LLVMInt16TypeInContext(e->ctx), 0xFFFF, 0), "");
    LLVMValueRef nib = LLVMBuildSelect(e->builder, isdig, dval,
        LLVMBuildAdd(e->builder, aval, s10, ""), "");
    LLVMValueRef evens = LLVMBuildShuffleVector(e->builder, nib, vundef16, even_mask, "");
    LLVMValueRef odds = LLVMBuildShuffleVector(e->builder, nib, vundef16, odd_mask, "");
    LLVMValueRef packed = LLVMBuildOr(e->builder,
        LLVMBuildShl(e->builder, evens, s4v8, ""),
        odds, "");
    LLVMValueRef out_gep = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &phi_w, 1, "");
    LLVMValueRef out_vgep = LLVMBuildBitCast(e->builder, out_gep, LLVMPointerType(v8, 0), "");
    LLVMValueRef vstore = LLVMBuildStore(e->builder, packed, out_vgep);
    LLVMSetAlignment(vstore, 1);
    LLVMValueRef ni = LLVMBuildAdd(e->builder, phi_i, LLVMConstInt(i64, 16, 0), "");
    LLVMValueRef nw = LLVMBuildAdd(e->builder, phi_w, LLVMConstInt(i64, 8, 0), "");
    LLVMBuildCondBr(e->builder, allok, vecloop, scalarloop);

    LLVMPositionBuilderAtEnd(e->builder, scalarloop);
    LLVMValueRef phi_i2 = LLVMBuildPhi(e->builder, i64, "i2");
    LLVMValueRef phi_w2 = LLVMBuildPhi(e->builder, i64, "w2");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntULE,
            LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 2, 0), ""),
            in_len, ""),
        scalarbody, ret);

    LLVMPositionBuilderAtEnd(e->builder, scalarbody);
    LLVMValueRef c1p = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &phi_i2, 1, "");
    LLVMValueRef c1 = LLVMBuildLoad2(e->builder, e->i8_ty, c1p, "");
    LLVMValueRef i2p1 = LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 1, 0), "");
    LLVMValueRef c2p = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &i2p1, 1, "");
    LLVMValueRef c2 = LLVMBuildLoad2(e->builder, e->i8_ty, c2p, "");
    LLVMValueRef t1 = LLVMBuildOr(e->builder, c1, LLVMConstInt(e->i8_ty, 32, 0), "");
    LLVMValueRef d1 = LLVMBuildSub(e->builder, t1, LLVMConstInt(e->i8_ty, 48, 0), "");
    LLVMValueRef a1 = LLVMBuildSub(e->builder, t1, LLVMConstInt(e->i8_ty, 97, 0), "");
    LLVMValueRef isdig1 = LLVMBuildICmp(e->builder, LLVMIntULE, d1, LLVMConstInt(e->i8_ty, 9, 0), "");
    LLVMValueRef isalp1 = LLVMBuildICmp(e->builder, LLVMIntULE, a1, LLVMConstInt(e->i8_ty, 5, 0), "");
    LLVMValueRef ok1 = LLVMBuildOr(e->builder, isdig1, isalp1, "");
    LLVMValueRef t2 = LLVMBuildOr(e->builder, c2, LLVMConstInt(e->i8_ty, 32, 0), "");
    LLVMValueRef d2 = LLVMBuildSub(e->builder, t2, LLVMConstInt(e->i8_ty, 48, 0), "");
    LLVMValueRef a2 = LLVMBuildSub(e->builder, t2, LLVMConstInt(e->i8_ty, 97, 0), "");
    LLVMValueRef isdig2 = LLVMBuildICmp(e->builder, LLVMIntULE, d2, LLVMConstInt(e->i8_ty, 9, 0), "");
    LLVMValueRef isalp2 = LLVMBuildICmp(e->builder, LLVMIntULE, a2, LLVMConstInt(e->i8_ty, 5, 0), "");
    LLVMValueRef ok2 = LLVMBuildOr(e->builder, isdig2, isalp2, "");
    LLVMValueRef bothok = LLVMBuildAnd(e->builder, ok1, ok2, "");
    LLVMValueRef hi = LLVMBuildSelect(e->builder, isdig1, d1,
        LLVMBuildAdd(e->builder, a1, LLVMConstInt(e->i8_ty, 10, 0), ""), "");
    LLVMValueRef lo = LLVMBuildSelect(e->builder, isdig2, d2,
        LLVMBuildAdd(e->builder, a2, LLVMConstInt(e->i8_ty, 10, 0), ""), "");
    LLVMValueRef bytev = LLVMBuildOr(e->builder,
        LLVMBuildShl(e->builder, hi, LLVMConstInt(e->i8_ty, 4, 0), ""), lo, "");
    LLVMValueRef ob = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &phi_w2, 1, "");
    LLVMBuildStore(e->builder, bytev, ob);
    LLVMValueRef si2 = LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 2, 0), "");
    LLVMValueRef sw2 = LLVMBuildAdd(e->builder, phi_w2, LLVMConstInt(i64, 1, 0), "");
    LLVMBuildCondBr(e->builder, bothok, scalarloop, ret);

    /* vecloop preds: entry, vecbody. scalarloop preds: vecloop, vecbody,
       scalarbody. ret preds: entry, scalarloop, scalarbody.
       NOTE: the vecbody edge rewinds to (phi_i, phi_w) so a vector block
       that fails validation is re-decoded by the scalar loop (stopping
       exactly like native) instead of being skipped with garbage kept
       (same fix as sa_b64dec_simd; locked by peer_hexmid). */
    {
        LLVMValueRef ivals[2] = { z0, ni };
        LLVMBasicBlockRef iblocks[2] = { entry, vecbody };
        LLVMAddIncoming(phi_i, ivals, iblocks, 2);
        LLVMValueRef wvals[2] = { z0, nw };
        LLVMBasicBlockRef wblocks[2] = { entry, vecbody };
        LLVMAddIncoming(phi_w, wvals, wblocks, 2);
        LLVMValueRef i2vals[3] = { phi_i, phi_i, si2 };
        LLVMBasicBlockRef i2blocks[3] = { vecloop, vecbody, scalarbody };
        LLVMAddIncoming(phi_i2, i2vals, i2blocks, 3);
        LLVMValueRef w2vals[3] = { phi_w, phi_w, sw2 };
        LLVMBasicBlockRef w2blocks[3] = { vecloop, vecbody, scalarbody };
        LLVMAddIncoming(phi_w2, w2vals, w2blocks, 3);
    }
    LLVMPositionBuilderAtEnd(e->builder, ret);
    LLVMValueRef phi_ret = LLVMBuildPhi(e->builder, i64, "wret");
    {
        LLVMValueRef rvals[3] = { z0, phi_w2, phi_w2 };
        LLVMBasicBlockRef rblocks[3] = { entry, scalarloop, scalarbody };
        LLVMAddIncoming(phi_ret, rvals, rblocks, 3);
    }
    LLVMBuildRet(e->builder, phi_ret);
}

/* sa_b64dec_simd for wasm: in-module vector base64 decoder (Mula-style).
   Native links libsa instead; this only fills the body when a wasm_compat
   module left an external declaration behind. Contract mirrors
   sa_b64dec_simd in sa_std.zig: clean A-Za-z0-9+/ input with n % 4 == 0
   yields n/4*3 bytes; stops at the first non-alphabet char (including
   '='), returning bytes written. Vector path handles 16 input chars per
   iteration in v16 (single v128 ops; v32 would pay a legalizer split tax
   under Cranelift); scalar tail covers whole trailing quanta. A vector
   block that fails validation rewinds into the scalar loop (same block
   re-decoded, stopping exactly like native) instead of skipping it. */
static void emit_sa_b64dec_simd_wasm(EmitCtx *e) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_b64dec_simd");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMTypeRef i64 = e->i64_ty;
    LLVMTypeRef v16 = LLVMVectorType(e->i8_ty, 16);
    LLVMTypeRef v12 = LLVMVectorType(e->i8_ty, 12);
    LLVMTypeRef v8 = LLVMVectorType(e->i8_ty, 8);
    LLVMTypeRef v4 = LLVMVectorType(e->i8_ty, 4);
    LLVMTypeRef v4i32 = LLVMVectorType(e->i32_ty, 4);
    LLVMValueRef in_ptr = LLVMGetParam(fn, 0);
    LLVMValueRef in_len = LLVMGetParam(fn, 1);
    LLVMValueRef out_ptr = LLVMGetParam(fn, 2);
    LLVMValueRef z0 = LLVMConstInt(i64, 0, 0);

    LLVMValueRef zero = wasm_const_splat_u8(e, v16, 16, 0);
    LLVMValueRef m15 = wasm_const_splat_u8(e, v16, 16, 15);
    LLVMTypeRef v8i16 = LLVMVectorType(LLVMInt16TypeInContext(e->ctx), 8);
    LLVMValueRef vundef16 = LLVMGetUndef(v16);
    LLVMValueRef splat_i32_3 = LLVMConstVector(
        (LLVMValueRef[]){ LLVMConstInt(e->i32_ty, 3, 0), LLVMConstInt(e->i32_ty, 3, 0),
                          LLVMConstInt(e->i32_ty, 3, 0), LLVMConstInt(e->i32_ty, 3, 0) }, 4);
    /* aqrit hash-translation tables (strict-standard halves, adapted from
       simdutf src/haswell/avx2_base64.cpp, Apache-2.0, credit aqrit). */
    static const uint8_t dasso_lanes[16] = { 0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x0F,0x00,0x0F };
    static const uint8_t dvals_lanes[16] = { 0x00,0x00,0x00,0x13,0x04,0xBF,0xBF,0xB9,0xB9,0x00,0x10,0xC3,0xBF,0xBF,0xB9,0xB9 };
    static const uint8_t casso_lanes[16] = { 0x0D,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x03,0x07,0x0B,0x0B,0x0B,0x0F };
    static const uint8_t cvals_lanes[16] = { 0x80,0x80,0x80,0x80,0xCF,0xBF,0xD5,0xA6,0xB5,0x86,0xD1,0x80,0xB1,0x80,0x91,0x80 };
    LLVMValueRef dAssoV = wasm_const_bytes16(e, v16, dasso_lanes);
    LLVMValueRef dValsV = wasm_const_bytes16(e, v16, dvals_lanes);
    LLVMValueRef cAssoV = wasm_const_bytes16(e, v16, casso_lanes);
    LLVMValueRef cValsV = wasm_const_bytes16(e, v16, cvals_lanes);
    LLVMValueRef swizzle_fn = wasm_fixed_intrinsic(e, "llvm.wasm.swizzle", v16);
    LLVMValueRef avgr_fn = wasm_intrinsic1(e, "llvm.wasm.avgr.unsigned", v16);
    /* SIGNED saturation (i8x16.add_sat_s): simdutf's tables are designed
       around adds_epi8 clamping at +127. Unsigned saturation lets sums in
       128..255 through and silently breaks both sextets and validity
       (every block rewinds: correct but scalar-slow). Verified the
       lowering with llc before using. */
    LLVMValueRef uaddsat_fn = wasm_intrinsic1(e, "llvm.sadd.sat", v16);
    /* Pack (expert Q1 5-op recipe, see packsel_lanes below). The final
       12-byte compress shuffle mask: */
    static const unsigned finB_idx[12] = { 2,1,0,6,5,4,10,9,8,14,13,12 };
    static const uint8_t w4096_lanes[16] = { 0x00,0x10,0x01,0x00,0x00,0x10,0x01,0x00,0x00,0x10,0x01,0x00,0x00,0x10,0x01,0x00 };
    /* 5-op pack (expert Q1, 2026-10): per-word mask selecting bit 6..11
       from (x<<6) and the rest from (x>>8), so each i16 lane becomes
       exactly 64a+b; one [4096,1] dot then yields the full 24-bit
       quartet. Replaces zero-interleave(2)+L1dot(2)+pick(2)+blend(1)+
       L2dot(1) = 9 ops with shl+shr+bitselect+dot = 4 ops (+1 final
       shuffle, unchanged). Q<=4095 so signed dot stays exact. */
    static const uint8_t packsel_lanes[16] = { 0xC0,0x0F,0xC0,0x0F,0xC0,0x0F,0xC0,0x0F,0xC0,0x0F,0xC0,0x0F,0xC0,0x0F,0xC0,0x0F };
    LLVMValueRef finBM = wasm_const_shuf_mask(e, finB_idx, 12);
    LLVMValueRef w4096v = wasm_const_bytes16(e, v16, w4096_lanes);
    LLVMValueRef packselv = wasm_const_bytes16(e, v16, packsel_lanes);
    LLVMValueRef dot_fn = wasm_fixed_intrinsic(e, "llvm.wasm.dot", v16);
    /* NB: llvm.wasm.bitselect is OVERLOADED in LLVM 14 (takes one type
       param -> llvm.wasm.bitselect.v16i8), unlike swizzle/dot which are
       fixed. Declaring it via the fixed helper segfaults inside
       GetIntrinsicDeclaration; wasm_intrinsic1 yields the true
       intrinsic, lowered to v128.bitselect. */
    LLVMValueRef bitselect_fn = wasm_intrinsic1(e, "llvm.wasm.bitselect", v16);
    LLVMValueRef splat6_16 = NULL, splat8_16 = NULL;
    {
        LLVMValueRef e6[8], e8[8];
        for (unsigned k = 0; k < 8; k++) {
            e6[k] = LLVMConstInt(LLVMInt16TypeInContext(e->ctx), 6, 0);
            e8[k] = LLVMConstInt(LLVMInt16TypeInContext(e->ctx), 8, 0);
        }
        splat6_16 = LLVMConstVector(e6, 8);
        splat8_16 = LLVMConstVector(e8, 8);
    }
    if (!zero || !m15 ||
        !splat_i32_3 ||
        !dAssoV || !dValsV || !cAssoV || !cValsV ||
        !swizzle_fn || !avgr_fn || !uaddsat_fn || !dot_fn ||
        !finBM || !w4096v ||
        !packselv || !splat6_16 || !splat8_16) return;

    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef vecloop = LLVMAppendBasicBlockInContext(e->ctx, fn, "vecloop");
    LLVMBasicBlockRef vecbody = LLVMAppendBasicBlockInContext(e->ctx, fn, "vecbody");
    LLVMBasicBlockRef scalarloop = LLVMAppendBasicBlockInContext(e->ctx, fn, "scalarloop");
    LLVMBasicBlockRef scalarbody = LLVMAppendBasicBlockInContext(e->ctx, fn, "scalarbody");
    LLVMBasicBlockRef ret = LLVMAppendBasicBlockInContext(e->ctx, fn, "ret");

    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef bail = LLVMBuildOr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntEQ, LLVMBuildPtrToInt(e->builder, in_ptr, i64, ""), z0, ""),
        LLVMBuildICmp(e->builder, LLVMIntEQ, LLVMBuildPtrToInt(e->builder, out_ptr, i64, ""), z0, ""), "");
    bail = LLVMBuildOr(e->builder, bail, LLVMBuildICmp(e->builder, LLVMIntEQ, in_len, z0, ""), "");
    LLVMBuildCondBr(e->builder, bail, ret, vecloop);

    LLVMPositionBuilderAtEnd(e->builder, vecloop);
    LLVMValueRef phi_i = LLVMBuildPhi(e->builder, i64, "i");
    LLVMValueRef phi_w = LLVMBuildPhi(e->builder, i64, "w");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntULE,
            LLVMBuildAdd(e->builder, phi_i, LLVMConstInt(i64, 32, 0), ""),
            in_len, ""),
        vecbody, scalarloop);

    LLVMPositionBuilderAtEnd(e->builder, vecbody);
    LLVMValueRef in_gep = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &phi_i, 1, "");
    LLVMValueRef in_vgep = LLVMBuildBitCast(e->builder, in_gep, LLVMPointerType(v16, 0), "");
    LLVMValueRef chunk = LLVMBuildLoad2(e->builder, v16, in_vgep, "");
    LLVMSetAlignment(chunk, 1);
    /* aqrit hash translation (tables adapted from simdutf, Apache-2.0):
       shifted mixes 32-bit groups; delta/check hashes diffuse through
       rounding average; saturating adds fold table deltas into sextets
       (sext) and validity flags (chk, nonzero lane = invalid). Replaces
       5 compares + flattened selects at ~half the v128 cost. */
    LLVMValueRef as_i32 = LLVMBuildBitCast(e->builder, chunk, v4i32, "");
    LLVMValueRef shr32 = LLVMBuildLShr(e->builder, as_i32, splat_i32_3, "");
    LLVMValueRef shifted = LLVMBuildBitCast(e->builder, shr32, v16, "");
    /* WASM swizzle zeroes out-of-range lanes (unlike pshufb's low-4-bit
       select), so every table index is pre-masked with 15. Soundness of
       the masked check chain is verified by exhaustive sweep (all 64
       chars exact, all 192 non-alphabet bytes flagged). */
    LLVMValueRef idxA = LLVMBuildAnd(e->builder, chunk, m15, "");
    LLVMValueRef dHash = wasm_call2(e, avgr_fn, v16,
        wasm_call2(e, swizzle_fn, v16, dAssoV, idxA), shifted);
    LLVMValueRef cHash = wasm_call2(e, avgr_fn, v16,
        wasm_call2(e, swizzle_fn, v16, cAssoV, idxA), shifted);
    LLVMValueRef sext = wasm_call2(e, uaddsat_fn, v16,
        wasm_call2(e, swizzle_fn, v16, dValsV,
            LLVMBuildAnd(e->builder, dHash, m15, "")), chunk);
    LLVMValueRef chk = wasm_call2(e, uaddsat_fn, v16,
        wasm_call2(e, swizzle_fn, v16, cValsV,
            LLVMBuildAnd(e->builder, cHash, m15, "")), chunk);
    /* Validity is the SIGN bit (movemask semantics): valid lanes yield
       small positive chk (e.g. 'B' -> 1), invalid lanes 0x80+. A !=0
       test misfires on every clean block (all rewind: correct but
       scalar-slow); SLT 0 is the exact movemask criterion. */
    LLVMValueRef badv = LLVMBuildICmp(e->builder, LLVMIntSLT, chk, zero, "");
    /* Full-width merge: quartet k sits at lanes 3k..3k+2 of B/C.
       tA picks byte0 slots {0,3,6,9}, tB byte1 {1,4,7,10}, tC byte2
       {2,5,8,11}; lanes 12..15 are masked out. All shuffles are
       single-source full-width (one swizzle each under Cranelift). */
    /* 5-op pack, first half: x=a|(b<<8) per word; L=x<<6, R=x>>8;
       Q=bitselect(L,R,0x0FC0)=64a+b; P=dot(Q,[4096,1])=full word. */
    LLVMValueRef x16 = LLVMBuildBitCast(e->builder, sext, v8i16, "");
    LLVMValueRef shl6 = LLVMBuildShl(e->builder, x16, splat6_16, "");
    LLVMValueRef shr8 = LLVMBuildLShr(e->builder, x16, splat8_16, "");
    LLVMValueRef shl6b = LLVMBuildBitCast(e->builder, shl6, v16, "");
    LLVMValueRef shr8b = LLVMBuildBitCast(e->builder, shr8, v16, "");
    LLVMValueRef qpack;
    if (bitselect_fn) {
        qpack = wasm_call3(e, bitselect_fn, v16, shl6b, shr8b, packselv);
    } else {
        /* Fallback: (L&m)|(R&~m); ~m via xor with splat-FF. */
        LLVMValueRef ff = wasm_const_splat_u8(e, v16, 16, 0xFF);
        LLVMValueRef notm = LLVMBuildXor(e->builder, packselv, ff, "");
        qpack = LLVMBuildOr(e->builder,
            LLVMBuildAnd(e->builder, shl6b, packselv, ""),
            LLVMBuildAnd(e->builder, shr8b, notm, ""), "");
    }
    LLVMValueRef q16 = LLVMBuildBitCast(e->builder, qpack, v8i16, "");
    LLVMValueRef w4096_16 = LLVMBuildBitCast(e->builder, w4096v, v8i16, "");
    LLVMValueRef vv = wasm_call_dot(e, dot_fn, v8i16, v4i32, q16, w4096_16);
    LLVMValueRef vvB = LLVMBuildBitCast(e->builder, vv, v16, "");
    LLVMValueRef out12 = LLVMBuildShuffleVector(e->builder, vvB, vundef16, finBM, "");
    LLVMValueRef out_gep = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &phi_w, 1, "");
    LLVMValueRef out_vgep = LLVMBuildBitCast(e->builder, out_gep, LLVMPointerType(v12, 0), "");
    LLVMValueRef vstore = LLVMBuildStore(e->builder, out12, out_vgep);
    LLVMSetAlignment(vstore, 1);
    /* Unrolled second half: next 16 chars -> 12 bytes at w+12.
       Shares one validity check with the first half below. */
    LLVMValueRef i16b = LLVMBuildAdd(e->builder, phi_i, LLVMConstInt(i64, 16, 0), "");
    LLVMValueRef w12b = LLVMBuildAdd(e->builder, phi_w, LLVMConstInt(i64, 12, 0), "");
    LLVMValueRef in_gep2 = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &i16b, 1, "");
    LLVMValueRef in_vgep2 = LLVMBuildBitCast(e->builder, in_gep2, LLVMPointerType(v16, 0), "");
    LLVMValueRef chunk2 = LLVMBuildLoad2(e->builder, v16, in_vgep2, "");
    LLVMSetAlignment(chunk2, 1);
    LLVMValueRef as2_i32 = LLVMBuildBitCast(e->builder, chunk2, v4i32, "");
    LLVMValueRef shr2_32 = LLVMBuildLShr(e->builder, as2_i32, splat_i32_3, "");
    LLVMValueRef shifted2 = LLVMBuildBitCast(e->builder, shr2_32, v16, "");
    LLVMValueRef idxB = LLVMBuildAnd(e->builder, chunk2, m15, "");
    LLVMValueRef dHash2 = wasm_call2(e, avgr_fn, v16,
        wasm_call2(e, swizzle_fn, v16, dAssoV, idxB), shifted2);
    LLVMValueRef cHash2 = wasm_call2(e, avgr_fn, v16,
        wasm_call2(e, swizzle_fn, v16, cAssoV, idxB), shifted2);
    LLVMValueRef sext2 = wasm_call2(e, uaddsat_fn, v16,
        wasm_call2(e, swizzle_fn, v16, dValsV,
            LLVMBuildAnd(e->builder, dHash2, m15, "")), chunk2);
    LLVMValueRef chk2 = wasm_call2(e, uaddsat_fn, v16,
        wasm_call2(e, swizzle_fn, v16, cValsV,
            LLVMBuildAnd(e->builder, cHash2, m15, "")), chunk2);
    LLVMValueRef badv2 = LLVMBuildICmp(e->builder, LLVMIntSLT, chk2, zero, "");
    LLVMValueRef x16_2 = LLVMBuildBitCast(e->builder, sext2, v8i16, "");
    LLVMValueRef shl6_2 = LLVMBuildShl(e->builder, x16_2, splat6_16, "");
    LLVMValueRef shr8_2 = LLVMBuildLShr(e->builder, x16_2, splat8_16, "");
    LLVMValueRef shl6b_2 = LLVMBuildBitCast(e->builder, shl6_2, v16, "");
    LLVMValueRef shr8b_2 = LLVMBuildBitCast(e->builder, shr8_2, v16, "");
    LLVMValueRef qpack2;
    if (bitselect_fn) {
        qpack2 = wasm_call3(e, bitselect_fn, v16, shl6b_2, shr8b_2, packselv);
    } else {
        LLVMValueRef ff2 = wasm_const_splat_u8(e, v16, 16, 0xFF);
        LLVMValueRef notm2 = LLVMBuildXor(e->builder, packselv, ff2, "");
        qpack2 = LLVMBuildOr(e->builder,
            LLVMBuildAnd(e->builder, shl6b_2, packselv, ""),
            LLVMBuildAnd(e->builder, shr8b_2, notm2, ""), "");
    }
    LLVMValueRef q16_2 = LLVMBuildBitCast(e->builder, qpack2, v8i16, "");
    LLVMValueRef w4096_2 = LLVMBuildBitCast(e->builder, w4096v, v8i16, "");
    LLVMValueRef vv2 = wasm_call_dot(e, dot_fn, v8i16, v4i32, q16_2, w4096_2);
    LLVMValueRef vv2B = LLVMBuildBitCast(e->builder, vv2, v16, "");
    LLVMValueRef out12_2 = LLVMBuildShuffleVector(e->builder, vv2B, vundef16, finBM, "");
    LLVMValueRef out_gep2 = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &w12b, 1, "");
    LLVMValueRef out_vgep2 = LLVMBuildBitCast(e->builder, out_gep2, LLVMPointerType(v12, 0), "");
    LLVMValueRef vstore2 = LLVMBuildStore(e->builder, out12_2, out_vgep2);
    LLVMSetAlignment(vstore2, 1);
    LLVMValueRef ni = LLVMBuildAdd(e->builder, phi_i, LLVMConstInt(i64, 32, 0), "");
    LLVMValueRef nw = LLVMBuildAdd(e->builder, phi_w, LLVMConstInt(i64, 24, 0), "");
    /* Validity is per-block reduction AND-ed: chk carries the sign bit
       exactly at invalid lanes (movemask semantics; valid lanes are
       small positives, so !=0 misfires). OR-ing masks across halves
       caused a real bug here before (good lane covering bad lane),
       hence reductions. */
    LLVMValueRef okflatA = LLVMBuildBitCast(e->builder, badv, LLVMInt16TypeInContext(e->ctx), "");
    LLVMValueRef okA = LLVMBuildICmp(e->builder, LLVMIntEQ, okflatA, LLVMConstInt(LLVMInt16TypeInContext(e->ctx), 0, 0), "");
    LLVMValueRef okflatB = LLVMBuildBitCast(e->builder, badv2, LLVMInt16TypeInContext(e->ctx), "");
    LLVMValueRef okB = LLVMBuildICmp(e->builder, LLVMIntEQ, okflatB, LLVMConstInt(LLVMInt16TypeInContext(e->ctx), 0, 0), "");
    LLVMValueRef allok = LLVMBuildAnd(e->builder, okA, okB, "");
    LLVMBuildCondBr(e->builder, allok, vecloop, scalarloop);

    LLVMPositionBuilderAtEnd(e->builder, scalarloop);
    LLVMValueRef phi_i2 = LLVMBuildPhi(e->builder, i64, "i2");
    LLVMValueRef phi_w2 = LLVMBuildPhi(e->builder, i64, "w2");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntULE,
            LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 4, 0), ""),
            in_len, ""),
        scalarbody, ret);

    LLVMPositionBuilderAtEnd(e->builder, scalarbody);
    LLVMValueRef q0p = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &phi_i2, 1, "");
    LLVMValueRef qa = LLVMBuildLoad2(e->builder, e->i8_ty, q0p, "");
    LLVMValueRef q1i = LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 1, 0), "");
    LLVMValueRef q1p = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &q1i, 1, "");
    LLVMValueRef qb = LLVMBuildLoad2(e->builder, e->i8_ty, q1p, "");
    LLVMValueRef q2i = LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 2, 0), "");
    LLVMValueRef q2p = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &q2i, 1, "");
    LLVMValueRef qc = LLVMBuildLoad2(e->builder, e->i8_ty, q2p, "");
    LLVMValueRef q3i = LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 3, 0), "");
    LLVMValueRef q3p = LLVMBuildGEP2(e->builder, e->i8_ty, in_ptr, &q3i, 1, "");
    LLVMValueRef qd = LLVMBuildLoad2(e->builder, e->i8_ty, q3p, "");
    LLVMValueRef c8_0 = LLVMConstInt(e->i8_ty, '0', 0);
    LLVMValueRef c8_9 = LLVMConstInt(e->i8_ty, '9', 0);
    LLVMValueRef c8_A = LLVMConstInt(e->i8_ty, 'A', 0);
    LLVMValueRef c8_Z = LLVMConstInt(e->i8_ty, 'Z', 0);
    LLVMValueRef c8_a = LLVMConstInt(e->i8_ty, 'a', 0);
    LLVMValueRef c8_z = LLVMConstInt(e->i8_ty, 'z', 0);
    /* Base64 sextet biases (Sub wraps mod 256): digit c-(-4)=c+4, upper c-65, lower c-71.
       Names keep the legacy c8_* shape; values are what matter. */
    LLVMValueRef c8_48 = LLVMConstInt(e->i8_ty, (uint64_t)(int64_t)-4, 0);
    LLVMValueRef c8_55 = LLVMConstInt(e->i8_ty, 65, 0);
    LLVMValueRef c8_87 = LLVMConstInt(e->i8_ty, 71, 0);
    LLVMValueRef c8_4 = LLVMConstInt(e->i8_ty, 4, 0);
    LLVMValueRef c8_15 = LLVMConstInt(e->i8_ty, 15, 0);
    LLVMValueRef c8_2 = LLVMConstInt(e->i8_ty, 2, 0);
    LLVMValueRef c8_3 = LLVMConstInt(e->i8_ty, 3, 0);
    LLVMValueRef c8_6 = LLVMConstInt(e->i8_ty, 6, 0);
    LLVMValueRef va = LLVMBuildSelect(e->builder,
        LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qa, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qa, c8_9, ""), ""),
        LLVMBuildSub(e->builder, qa, c8_48, ""),
        LLVMBuildSelect(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qa, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qa, c8_Z, ""), ""),
            LLVMBuildSub(e->builder, qa, c8_55, ""),
            LLVMBuildSelect(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qa, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qa, c8_z, ""), ""),
                LLVMBuildSub(e->builder, qa, c8_87, ""),
                LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qa, LLVMConstInt(e->i8_ty, '+', 0), ""), LLVMConstInt(e->i8_ty, 62, 0),
                    LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qa, LLVMConstInt(e->i8_ty, '/', 0), ""), LLVMConstInt(e->i8_ty, 63, 0), LLVMConstInt(e->i8_ty, 0, 0), ""), ""), ""), ""), "");
    LLVMValueRef oka = LLVMBuildOr(e->builder,
        LLVMBuildOr(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qa, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qa, c8_9, ""), ""),
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qa, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qa, c8_Z, ""), ""), ""),
        LLVMBuildOr(e->builder,
            LLVMBuildOr(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qa, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qa, c8_z, ""), ""),
                LLVMBuildICmp(e->builder, LLVMIntEQ, qa, LLVMConstInt(e->i8_ty, '+', 0), ""), ""),
            LLVMBuildICmp(e->builder, LLVMIntEQ, qa, LLVMConstInt(e->i8_ty, '/', 0), ""), ""), "");
    LLVMValueRef vb = LLVMBuildSelect(e->builder,
        LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qb, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qb, c8_9, ""), ""),
        LLVMBuildSub(e->builder, qb, c8_48, ""),
        LLVMBuildSelect(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qb, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qb, c8_Z, ""), ""),
            LLVMBuildSub(e->builder, qb, c8_55, ""),
            LLVMBuildSelect(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qb, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qb, c8_z, ""), ""),
                LLVMBuildSub(e->builder, qb, c8_87, ""),
                LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qb, LLVMConstInt(e->i8_ty, '+', 0), ""), LLVMConstInt(e->i8_ty, 62, 0),
                    LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qb, LLVMConstInt(e->i8_ty, '/', 0), ""), LLVMConstInt(e->i8_ty, 63, 0), LLVMConstInt(e->i8_ty, 0, 0), ""), ""), ""), ""), "");
    LLVMValueRef okb = LLVMBuildOr(e->builder,
        LLVMBuildOr(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qb, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qb, c8_9, ""), ""),
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qb, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qb, c8_Z, ""), ""), ""),
        LLVMBuildOr(e->builder,
            LLVMBuildOr(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qb, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qb, c8_z, ""), ""),
                LLVMBuildICmp(e->builder, LLVMIntEQ, qb, LLVMConstInt(e->i8_ty, '+', 0), ""), ""),
            LLVMBuildICmp(e->builder, LLVMIntEQ, qb, LLVMConstInt(e->i8_ty, '/', 0), ""), ""), "");
    LLVMValueRef vc = LLVMBuildSelect(e->builder,
        LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qc, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qc, c8_9, ""), ""),
        LLVMBuildSub(e->builder, qc, c8_48, ""),
        LLVMBuildSelect(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qc, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qc, c8_Z, ""), ""),
            LLVMBuildSub(e->builder, qc, c8_55, ""),
            LLVMBuildSelect(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qc, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qc, c8_z, ""), ""),
                LLVMBuildSub(e->builder, qc, c8_87, ""),
                LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qc, LLVMConstInt(e->i8_ty, '+', 0), ""), LLVMConstInt(e->i8_ty, 62, 0),
                    LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qc, LLVMConstInt(e->i8_ty, '/', 0), ""), LLVMConstInt(e->i8_ty, 63, 0), LLVMConstInt(e->i8_ty, 0, 0), ""), ""), ""), ""), "");
    LLVMValueRef okc = LLVMBuildOr(e->builder,
        LLVMBuildOr(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qc, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qc, c8_9, ""), ""),
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qc, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qc, c8_Z, ""), ""), ""),
        LLVMBuildOr(e->builder,
            LLVMBuildOr(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qc, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qc, c8_z, ""), ""),
                LLVMBuildICmp(e->builder, LLVMIntEQ, qc, LLVMConstInt(e->i8_ty, '+', 0), ""), ""),
            LLVMBuildICmp(e->builder, LLVMIntEQ, qc, LLVMConstInt(e->i8_ty, '/', 0), ""), ""), "");
    LLVMValueRef vd = LLVMBuildSelect(e->builder,
        LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qd, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qd, c8_9, ""), ""),
        LLVMBuildSub(e->builder, qd, c8_48, ""),
        LLVMBuildSelect(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qd, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qd, c8_Z, ""), ""),
            LLVMBuildSub(e->builder, qd, c8_55, ""),
            LLVMBuildSelect(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qd, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qd, c8_z, ""), ""),
                LLVMBuildSub(e->builder, qd, c8_87, ""),
                LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qd, LLVMConstInt(e->i8_ty, '+', 0), ""), LLVMConstInt(e->i8_ty, 62, 0),
                    LLVMBuildSelect(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, qd, LLVMConstInt(e->i8_ty, '/', 0), ""), LLVMConstInt(e->i8_ty, 63, 0), LLVMConstInt(e->i8_ty, 0, 0), ""), ""), ""), ""), "");
    LLVMValueRef okd = LLVMBuildOr(e->builder,
        LLVMBuildOr(e->builder,
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qd, c8_0, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qd, c8_9, ""), ""),
            LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qd, c8_A, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qd, c8_Z, ""), ""), ""),
        LLVMBuildOr(e->builder,
            LLVMBuildOr(e->builder,
                LLVMBuildAnd(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, qd, c8_a, ""), LLVMBuildICmp(e->builder, LLVMIntULE, qd, c8_z, ""), ""),
                LLVMBuildICmp(e->builder, LLVMIntEQ, qd, LLVMConstInt(e->i8_ty, '+', 0), ""), ""),
            LLVMBuildICmp(e->builder, LLVMIntEQ, qd, LLVMConstInt(e->i8_ty, '/', 0), ""), ""), "");
    LLVMValueRef qok = LLVMBuildAnd(e->builder, LLVMBuildAnd(e->builder, oka, okb, ""), LLVMBuildAnd(e->builder, okc, okd, ""), "");
    LLVMValueRef ob0 = LLVMBuildOr(e->builder,
        LLVMBuildShl(e->builder, va, c8_2, ""),
        LLVMBuildLShr(e->builder, vb, c8_4, ""), "");
    LLVMValueRef ob1 = LLVMBuildOr(e->builder,
        LLVMBuildShl(e->builder, LLVMBuildAnd(e->builder, vb, c8_15, ""), c8_4, ""),
        LLVMBuildLShr(e->builder, vc, c8_2, ""), "");
    LLVMValueRef ob2 = LLVMBuildOr(e->builder,
        LLVMBuildShl(e->builder, LLVMBuildAnd(e->builder, vc, c8_3, ""), c8_6, ""),
        vd, "");
    LLVMValueRef obp = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &phi_w2, 1, "");
    LLVMBuildStore(e->builder, ob0, obp);
    LLVMValueRef ob1i = LLVMBuildAdd(e->builder, phi_w2, LLVMConstInt(i64, 1, 0), "");
    LLVMValueRef ob1p = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &ob1i, 1, "");
    LLVMBuildStore(e->builder, ob1, ob1p);
    LLVMValueRef ob2i = LLVMBuildAdd(e->builder, phi_w2, LLVMConstInt(i64, 2, 0), "");
    LLVMValueRef ob2p = LLVMBuildGEP2(e->builder, e->i8_ty, out_ptr, &ob2i, 1, "");
    LLVMBuildStore(e->builder, ob2, ob2p);
    LLVMValueRef si2 = LLVMBuildAdd(e->builder, phi_i2, LLVMConstInt(i64, 4, 0), "");
    LLVMValueRef sw2 = LLVMBuildAdd(e->builder, phi_w2, LLVMConstInt(i64, 3, 0), "");
    LLVMBuildCondBr(e->builder, qok, scalarloop, ret);

    /* vecloop preds: entry, vecbody. scalarloop preds: vecloop, vecbody,
       scalarbody. ret preds: entry, scalarloop, scalarbody.
       NOTE: the vecbody edge rewinds to (phi_i, phi_w) so a vector block
       that fails validation is re-decoded by the scalar loop (stopping
       exactly like native) instead of being skipped with garbage kept. */
    {
        LLVMValueRef ivals[2] = { z0, ni };
        LLVMBasicBlockRef iblocks[2] = { entry, vecbody };
        LLVMAddIncoming(phi_i, ivals, iblocks, 2);
        LLVMValueRef wvals[2] = { z0, nw };
        LLVMBasicBlockRef wblocks[2] = { entry, vecbody };
        LLVMAddIncoming(phi_w, wvals, wblocks, 2);
        LLVMValueRef i2vals[3] = { phi_i, phi_i, si2 };
        LLVMBasicBlockRef i2blocks[3] = { vecloop, vecbody, scalarbody };
        LLVMAddIncoming(phi_i2, i2vals, i2blocks, 3);
        LLVMValueRef w2vals[3] = { phi_w, phi_w, sw2 };
        LLVMBasicBlockRef w2blocks[3] = { vecloop, vecbody, scalarbody };
        LLVMAddIncoming(phi_w2, w2vals, w2blocks, 3);
    }
    LLVMPositionBuilderAtEnd(e->builder, ret);
    LLVMValueRef phi_ret = LLVMBuildPhi(e->builder, i64, "wret");
    {
        LLVMValueRef rvals[3] = { z0, phi_w2, phi_w2 };
        LLVMBasicBlockRef rblocks[3] = { entry, scalarloop, scalarbody };
        LLVMAddIncoming(phi_ret, rvals, rblocks, 3);
    }
    LLVMBuildRet(e->builder, phi_ret);
}

/* sa_mfind_u8 for wasm: thin wrapper over libc memmem (wasi-libc
   provides it; same class as the native Zig std.mem.indexOf bridge).
   Only fills the body when a wasm_compat module left an external
   declaration behind. Contract mirrors sa_mfind_u8 in sa_std.zig:
   byte offset of first hit, or hay_len on miss; empty needle matches
   at 0; needle longer than haystack misses. */
static void emit_sa_mfind_u8_wasm(EmitCtx *e) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_mfind_u8");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMTypeRef i64 = e->i64_ty;
    LLVMTypeRef size = size_type(e);
    LLVMValueRef hay = LLVMGetParam(fn, 0);
    LLVMValueRef hay_len = LLVMGetParam(fn, 1);
    LLVMValueRef ndl = LLVMGetParam(fn, 2);
    LLVMValueRef ndl_len = LLVMGetParam(fn, 3);
    LLVMValueRef z0 = LLVMConstInt(i64, 0, 0);
    LLVMTypeRef mparams[4] = { e->ptr_ty, size, e->ptr_ty, size };
    LLVMValueRef memmem = LLVMGetNamedFunction(e->module, "memmem");
    if (memmem == NULL) {
        memmem = LLVMAddFunction(e->module, "memmem",
            LLVMFunctionType(e->ptr_ty, mparams, 4, 0));
    }
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef check = LLVMAppendBasicBlockInContext(e->ctx, fn, "check");
    LLVMBasicBlockRef callblk = LLVMAppendBasicBlockInContext(e->ctx, fn, "callblk");
    LLVMBasicBlockRef diffblk = LLVMAppendBasicBlockInContext(e->ctx, fn, "diffblk");
    LLVMBasicBlockRef ret = LLVMAppendBasicBlockInContext(e->ctx, fn, "ret");

    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntEQ, ndl_len, z0, ""), ret, check);

    LLVMPositionBuilderAtEnd(e->builder, check);
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntUGT, ndl_len, hay_len, ""), ret, callblk);

    LLVMPositionBuilderAtEnd(e->builder, callblk);
    LLVMValueRef hlen_t = LLVMBuildTrunc(e->builder, hay_len, size, "");
    LLVMValueRef nlen_t = LLVMBuildTrunc(e->builder, ndl_len, size, "");
    LLVMValueRef margs[4] = { hay, hlen_t, ndl, nlen_t };
    LLVMValueRef p = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(memmem), memmem, margs, 4, "");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntEQ,
            LLVMBuildPtrToInt(e->builder, p, size, ""),
            LLVMConstInt(size, 0, 0), ""),
        ret, diffblk);

    LLVMPositionBuilderAtEnd(e->builder, diffblk);
    LLVMValueRef d = LLVMBuildSub(e->builder,
        LLVMBuildPtrToInt(e->builder, p, size, ""),
        LLVMBuildPtrToInt(e->builder, hay, size, ""), "");
    LLVMValueRef dw = LLVMBuildZExt(e->builder, d, i64, "");
    LLVMBuildBr(e->builder, ret);

    LLVMPositionBuilderAtEnd(e->builder, ret);
    LLVMValueRef phi_ret = LLVMBuildPhi(e->builder, i64, "rret");
    {
        LLVMValueRef rvals[4] = { z0, hay_len, hay_len, dw };
        LLVMBasicBlockRef rblocks[4] = { entry, check, callblk, diffblk };
        LLVMAddIncoming(phi_ret, rvals, rblocks, 4);
    }
    LLVMBuildRet(e->builder, phi_ret);
}

/* ------------------------------------------------------------------ */
/* wasm32-wasi fmt runtime.                                            */
/* `sa build-wasm` links only the emitted bitcode, so the sa_fmt_*     */
/* externs injected by the flattener would stay undefined (native      */
/* build-exe links artifacts/sa_std/libsa_std.a instead). Define them */
/* here with the same ABI as src/runtime/sa_std.zig: owned-buffer     */
/* handles are 1-based slot indices, 0 means failure/invalid. Slot    */
/* payloads are backed by wasi libc malloc/free, already declared for */
/* every module by declare_runtime.                                   */
/* ------------------------------------------------------------------ */
#define SA_FMT_WASM_SLOTS 32
#define SA_FMT_WASM_SCRATCH 128
#define SA_FMT_WASM_F64_SCRATCH 512

typedef struct {
    LLVMValueRef used;
    LLVMValueRef ptrs;
    LLVMValueRef lens;
    LLVMValueRef digits_lo;
    LLVMValueRef digits_hi;
    LLVMValueRef f64fmt;
    LLVMTypeRef used_ty;
    LLVMTypeRef ptrs_ty;
    LLVMTypeRef lens_ty;
    LLVMTypeRef digits_ty;
    LLVMTypeRef f64fmt_ty;
} FmtWasmState;

static LLVMValueRef fmt_wasm_global(EmitCtx *e, const char *name, LLVMTypeRef ty, LLVMValueRef init) {
    LLVMValueRef g = LLVMGetNamedGlobal(e->module, name);
    if (g == NULL) {
        g = LLVMAddGlobal(e->module, ty, name);
        LLVMSetLinkage(g, LLVMInternalLinkage);
        LLVMSetInitializer(g, init);
    }
    return g;
}

static LLVMValueRef fmt_wasm_elem(EmitCtx *e, LLVMTypeRef el_ty, LLVMValueRef base, LLVMValueRef idx) {
    LLVMValueRef sub[2] = { LLVMConstInt(e->i32_ty, 0, 0), idx };
    return LLVMBuildGEP2(e->builder, el_ty, base, sub, 2, "");
}

static void fmt_wasm_ensure_state(EmitCtx *e, FmtWasmState *s) {
    s->used_ty = LLVMArrayType(e->i8_ty, SA_FMT_WASM_SLOTS);
    s->ptrs_ty = LLVMArrayType(e->ptr_ty, SA_FMT_WASM_SLOTS);
    s->lens_ty = LLVMArrayType(e->i64_ty, SA_FMT_WASM_SLOTS);
    s->digits_ty = LLVMArrayType(e->i8_ty, 16);
    s->f64fmt_ty = LLVMArrayType(e->i8_ty, 5);
    s->used = fmt_wasm_global(e, "sa_fmt_wasm_used", s->used_ty, LLVMConstNull(s->used_ty));
    s->ptrs = fmt_wasm_global(e, "sa_fmt_wasm_ptrs", s->ptrs_ty, LLVMConstNull(s->ptrs_ty));
    s->lens = fmt_wasm_global(e, "sa_fmt_wasm_lens", s->lens_ty, LLVMConstNull(s->lens_ty));
    s->digits_lo = fmt_wasm_global(e, "sa_fmt_wasm_digits_lo", s->digits_ty,
        LLVMConstStringInContext(e->ctx, "0123456789abcdef", 16, 1));
    s->digits_hi = fmt_wasm_global(e, "sa_fmt_wasm_digits_hi", s->digits_ty,
        LLVMConstStringInContext(e->ctx, "0123456789ABCDEF", 16, 1));
    s->f64fmt = fmt_wasm_global(e, "sa_fmt_wasm_f64fmt", s->f64fmt_ty,
        LLVMConstStringInContext(e->ctx, "%.*f", 4, 0));
}

static LLVMValueRef fmt_wasm_snprintf_fn(EmitCtx *e) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "snprintf");
    if (fn == NULL) {
        LLVMTypeRef params[3] = { e->ptr_ty, size_type(e), e->ptr_ty };
        fn = LLVMAddFunction(e->module, "snprintf", LLVMFunctionType(e->i32_ty, params, 3, 1));
    }
    return fn;
}

static LLVMValueRef fmt_wasm_call_malloc(EmitCtx *e, LLVMValueRef len_i64) {
    LLVMValueRef sz = LLVMBuildTrunc(e->builder, len_i64, size_type(e), "");
    return LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &sz, 1, "");
}

static LLVMValueRef fmt_wasm_call_memcpy(EmitCtx *e, LLVMValueRef dst, LLVMValueRef src, LLVMValueRef len_i64) {
    LLVMValueRef args[3] = { dst, src, LLVMBuildTrunc(e->builder, len_i64, size_type(e), "") };
    return LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->memcpy_fn), e->memcpy_fn, args, 3, "");
}

/* sa_fmt_wasm_alloc(len: i64) -> i64 handle (0 on failure). */
static LLVMValueRef fmt_wasm_ensure_alloc(EmitCtx *e, const FmtWasmState *s) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_wasm_alloc");
    if (fn != NULL) return fn;
    LLVMTypeRef i64 = e->i64_ty;
    LLVMTypeRef params[1] = { i64 };
    fn = LLVMAddFunction(e->module, "sa_fmt_wasm_alloc", LLVMFunctionType(i64, params, 1, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMValueRef len = LLVMGetParam(fn, 0);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef loop = LLVMAppendBasicBlockInContext(e->ctx, fn, "loop");
    LLVMBasicBlockRef body = LLVMAppendBasicBlockInContext(e->ctx, fn, "body");
    LLVMBasicBlockRef next = LLVMAppendBasicBlockInContext(e->ctx, fn, "next");
    LLVMBasicBlockRef take = LLVMAppendBasicBlockInContext(e->ctx, fn, "take");
    LLVMBasicBlockRef fill = LLVMAppendBasicBlockInContext(e->ctx, fn, "fill");
    LLVMBasicBlockRef fail = LLVMAppendBasicBlockInContext(e->ctx, fn, "fail");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMBuildBr(e->builder, loop);
    LLVMPositionBuilderAtEnd(e->builder, loop);
    LLVMValueRef phi = LLVMBuildPhi(e->builder, i64, "i");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntULT, phi, LLVMConstInt(i64, SA_FMT_WASM_SLOTS, 0), ""), body, fail);
    LLVMPositionBuilderAtEnd(e->builder, body);
    LLVMValueRef ucell = fmt_wasm_elem(e, s->used_ty, s->used, phi);
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntEQ,
            LLVMBuildLoad2(e->builder, e->i8_ty, ucell, ""), LLVMConstInt(e->i8_ty, 0, 0), ""),
        take, next);
    LLVMPositionBuilderAtEnd(e->builder, next);
    LLVMValueRef inc = LLVMBuildAdd(e->builder, phi, LLVMConstInt(i64, 1, 0), "");
    LLVMBuildBr(e->builder, loop);
    {
        LLVMValueRef vals[2] = { LLVMConstInt(i64, 0, 0), inc };
        LLVMBasicBlockRef blocks[2] = { entry, next };
        LLVMAddIncoming(phi, vals, blocks, 2);
    }
    LLVMPositionBuilderAtEnd(e->builder, take);
    LLVMValueRef mem = fmt_wasm_call_malloc(e, len);
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntEQ, mem, LLVMConstPointerNull(e->ptr_ty), ""), fail, fill);
    LLVMPositionBuilderAtEnd(e->builder, fill);
    LLVMBuildStore(e->builder, mem, fmt_wasm_elem(e, s->ptrs_ty, s->ptrs, phi));
    LLVMBuildStore(e->builder, len, fmt_wasm_elem(e, s->lens_ty, s->lens, phi));
    LLVMBuildStore(e->builder, LLVMConstInt(e->i8_ty, 1, 0), ucell);
    LLVMBuildRet(e->builder, LLVMBuildAdd(e->builder, phi, LLVMConstInt(i64, 1, 0), ""));
    LLVMPositionBuilderAtEnd(e->builder, fail);
    LLVMBuildRet(e->builder, LLVMConstInt(i64, 0, 0));
    return fn;
}

/* sa_fmt_wasm_slot(handle: i64) -> i64 slot index, or -1 if invalid. */
static LLVMValueRef fmt_wasm_ensure_slot(EmitCtx *e, const FmtWasmState *s) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_wasm_slot");
    if (fn != NULL) return fn;
    LLVMTypeRef i64 = e->i64_ty;
    LLVMTypeRef params[1] = { i64 };
    fn = LLVMAddFunction(e->module, "sa_fmt_wasm_slot", LLVMFunctionType(i64, params, 1, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMValueRef handle = LLVMGetParam(fn, 0);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef check_hi = LLVMAppendBasicBlockInContext(e->ctx, fn, "check_hi");
    LLVMBasicBlockRef check_used = LLVMAppendBasicBlockInContext(e->ctx, fn, "check_used");
    LLVMBasicBlockRef ok = LLVMAppendBasicBlockInContext(e->ctx, fn, "ok");
    LLVMBasicBlockRef fail = LLVMAppendBasicBlockInContext(e->ctx, fn, "fail");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntSLT, handle, LLVMConstInt(i64, 1, 0), ""), fail, check_hi);
    LLVMPositionBuilderAtEnd(e->builder, check_hi);
    LLVMValueRef idx = LLVMBuildSub(e->builder, handle, LLVMConstInt(i64, 1, 0), "");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntUGE, idx, LLVMConstInt(i64, SA_FMT_WASM_SLOTS, 0), ""), fail, check_used);
    LLVMPositionBuilderAtEnd(e->builder, check_used);
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntEQ,
            LLVMBuildLoad2(e->builder, e->i8_ty, fmt_wasm_elem(e, s->used_ty, s->used, idx), ""),
            LLVMConstInt(e->i8_ty, 0, 0), ""),
        fail, ok);
    LLVMPositionBuilderAtEnd(e->builder, ok);
    LLVMBuildRet(e->builder, idx);
    LLVMPositionBuilderAtEnd(e->builder, fail);
    LLVMBuildRet(e->builder, LLVMBuildSub(e->builder, LLVMConstInt(i64, 0, 0), LLVMConstInt(i64, 1, 0), ""));
    return fn;
}

/* sa_fmt_wasm_uint(uval: i64 bits, base: i32, neg: i1) -> i64 handle. */
static LLVMValueRef fmt_wasm_ensure_uint(EmitCtx *e, const FmtWasmState *s, LLVMValueRef alloc_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_wasm_uint");
    if (fn != NULL) return fn;
    LLVMTypeRef i64 = e->i64_ty;
    LLVMTypeRef i32 = e->i32_ty;
    LLVMTypeRef i1 = LLVMInt1TypeInContext(e->ctx);
    LLVMTypeRef params[3] = { i64, i32, i1 };
    fn = LLVMAddFunction(e->module, "sa_fmt_wasm_uint", LLVMFunctionType(i64, params, 3, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMValueRef uval = LLVMGetParam(fn, 0);
    LLVMValueRef base = LLVMGetParam(fn, 1);
    LLVMValueRef neg = LLVMGetParam(fn, 2);
    LLVMTypeRef buf_ty = LLVMArrayType(e->i8_ty, SA_FMT_WASM_SCRATCH);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef loop = LLVMAppendBasicBlockInContext(e->ctx, fn, "loop");
    LLVMBasicBlockRef exit = LLVMAppendBasicBlockInContext(e->ctx, fn, "exit");
    LLVMBasicBlockRef sign = LLVMAppendBasicBlockInContext(e->ctx, fn, "sign");
    LLVMBasicBlockRef nosign = LLVMAppendBasicBlockInContext(e->ctx, fn, "nosign");
    LLVMBasicBlockRef collect = LLVMAppendBasicBlockInContext(e->ctx, fn, "collect");
    LLVMBasicBlockRef linked = LLVMAppendBasicBlockInContext(e->ctx, fn, "linked");
    LLVMBasicBlockRef ret0 = LLVMAppendBasicBlockInContext(e->ctx, fn, "ret0");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef is2 = LLVMBuildICmp(e->builder, LLVMIntEQ, base, LLVMConstInt(i32, 2, 0), "");
    LLVMValueRef is8 = LLVMBuildICmp(e->builder, LLVMIntEQ, base, LLVMConstInt(i32, 8, 0), "");
    LLVMValueRef is10 = LLVMBuildICmp(e->builder, LLVMIntEQ, base, LLVMConstInt(i32, 10, 0), "");
    LLVMValueRef is16 = LLVMBuildICmp(e->builder, LLVMIntEQ, base, LLVMConstInt(i32, 16, 0), "");
    LLVMValueRef is17 = LLVMBuildICmp(e->builder, LLVMIntEQ, base, LLVMConstInt(i32, 17, 0), "");
    LLVMValueRef valid = LLVMBuildOr(e->builder,
        LLVMBuildOr(e->builder, is2, is8, ""),
        LLVMBuildOr(e->builder, LLVMBuildOr(e->builder, is10, is16, ""), is17, ""), "");
    LLVMValueRef b32 = LLVMBuildSelect(e->builder, valid, base, LLVMConstInt(i32, 10, 0), "");
    LLVMValueRef b64 = LLVMBuildZExt(e->builder, b32, i64, "");
    LLVMValueRef lut = LLVMBuildSelect(e->builder, is17, s->digits_hi, s->digits_lo, "");
    LLVMValueRef buf = LLVMBuildAlloca(e->builder, buf_ty, "buf");
    LLVMValueRef pos = LLVMBuildAlloca(e->builder, i64, "pos");
    LLVMValueRef vslot = LLVMBuildAlloca(e->builder, i64, "v");
    LLVMBuildStore(e->builder, LLVMConstInt(i64, SA_FMT_WASM_SCRATCH, 0), pos);
    LLVMBuildStore(e->builder, uval, vslot);
    LLVMBuildBr(e->builder, loop);
    LLVMPositionBuilderAtEnd(e->builder, loop);
    LLVMValueRef vv = LLVMBuildLoad2(e->builder, i64, vslot, "");
    LLVMValueRef pp = LLVMBuildLoad2(e->builder, i64, pos, "");
    LLVMValueRef digit = LLVMBuildURem(e->builder, vv, b64, "");
    LLVMBuildStore(e->builder, LLVMBuildUDiv(e->builder, vv, b64, ""), vslot);
    LLVMValueRef pp2 = LLVMBuildSub(e->builder, pp, LLVMConstInt(i64, 1, 0), "");
    LLVMBuildStore(e->builder, pp2, pos);
    LLVMValueRef ch = LLVMBuildLoad2(e->builder, e->i8_ty, fmt_wasm_elem(e, s->digits_ty, lut, digit), "");
    LLVMBuildStore(e->builder, ch, fmt_wasm_elem(e, buf_ty, buf, pp2));
    LLVMValueRef rest = LLVMBuildLoad2(e->builder, i64, vslot, "");
    LLVMBuildCondBr(e->builder, LLVMBuildICmp(e->builder, LLVMIntNE, rest, LLVMConstInt(i64, 0, 0), ""), loop, exit);
    LLVMPositionBuilderAtEnd(e->builder, exit);
    LLVMBuildCondBr(e->builder, neg, sign, nosign);
    LLVMPositionBuilderAtEnd(e->builder, sign);
    LLVMValueRef sp = LLVMBuildLoad2(e->builder, i64, pos, "");
    LLVMValueRef sp2 = LLVMBuildSub(e->builder, sp, LLVMConstInt(i64, 1, 0), "");
    LLVMBuildStore(e->builder, sp2, pos);
    LLVMBuildStore(e->builder, LLVMConstInt(e->i8_ty, 45, 0), fmt_wasm_elem(e, buf_ty, buf, sp2));
    LLVMBuildBr(e->builder, collect);
    LLVMPositionBuilderAtEnd(e->builder, nosign);
    LLVMBuildBr(e->builder, collect);
    LLVMPositionBuilderAtEnd(e->builder, collect);
    LLVMValueRef posf = LLVMBuildLoad2(e->builder, i64, pos, "");
    LLVMValueRef data = fmt_wasm_elem(e, buf_ty, buf, posf);
    LLVMValueRef len = LLVMBuildSub(e->builder, LLVMConstInt(i64, SA_FMT_WASM_SCRATCH, 0), posf, "");
    LLVMValueRef h = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(alloc_fn), alloc_fn, &len, 1, "");
    LLVMBuildCondBr(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, h, LLVMConstInt(i64, 0, 0), ""), ret0, linked);
    LLVMPositionBuilderAtEnd(e->builder, linked);
    LLVMValueRef idx = LLVMBuildSub(e->builder, h, LLVMConstInt(i64, 1, 0), "");
    LLVMValueRef dst = LLVMBuildLoad2(e->builder, e->ptr_ty, fmt_wasm_elem(e, s->ptrs_ty, s->ptrs, idx), "");
    fmt_wasm_call_memcpy(e, dst, data, len);
    LLVMBuildRet(e->builder, h);
    LLVMPositionBuilderAtEnd(e->builder, ret0);
    LLVMBuildRet(e->builder, LLVMConstInt(i64, 0, 0));
    return fn;
}

static void fmt_wasm_define_u64(EmitCtx *e, LLVMValueRef uint_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_u64");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef args[3] = {
        LLVMGetParam(fn, 0), LLVMGetParam(fn, 1), LLVMConstInt(LLVMInt1TypeInContext(e->ctx), 0, 0)
    };
    LLVMBuildRet(e->builder, LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(uint_fn), uint_fn, args, 3, ""));
}

static void fmt_wasm_define_i64(EmitCtx *e, LLVMValueRef uint_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_i64");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMValueRef val = LLVMGetParam(fn, 0);
    LLVMValueRef base = LLVMGetParam(fn, 1);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef is10 = LLVMBuildICmp(e->builder, LLVMIntEQ, base, LLVMConstInt(e->i32_ty, 10, 0), "");
    LLVMValueRef isneg0 = LLVMBuildICmp(e->builder, LLVMIntSLT, val, LLVMConstInt(e->i64_ty, 0, 0), "");
    LLVMValueRef neg = LLVMBuildAnd(e->builder, is10, isneg0, "");
    LLVMValueRef mag = LLVMBuildSelect(e->builder, neg,
        LLVMBuildSub(e->builder, LLVMConstInt(e->i64_ty, 0, 0), val, ""), val, "");
    LLVMValueRef args[3] = { mag, base, neg };
    LLVMBuildRet(e->builder, LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(uint_fn), uint_fn, args, 3, ""));
}

static void fmt_wasm_define_f64(EmitCtx *e, const FmtWasmState *s, LLVMValueRef alloc_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_f64");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMValueRef val = LLVMGetParam(fn, 0);
    LLVMValueRef prec = LLVMGetParam(fn, 1);
    LLVMTypeRef buf_ty = LLVMArrayType(e->i8_ty, SA_FMT_WASM_F64_SCRATCH);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef sized = LLVMAppendBasicBlockInContext(e->ctx, fn, "sized");
    LLVMBasicBlockRef copy = LLVMAppendBasicBlockInContext(e->ctx, fn, "copy");
    LLVMBasicBlockRef ret0 = LLVMAppendBasicBlockInContext(e->ctx, fn, "ret0");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef buf = LLVMBuildAlloca(e->builder, buf_ty, "buf");
    LLVMValueRef data = fmt_wasm_elem(e, buf_ty, buf, LLVMConstInt(e->i32_ty, 0, 0));
    LLVMValueRef fmtp = fmt_wasm_elem(e, s->f64fmt_ty, s->f64fmt, LLVMConstInt(e->i32_ty, 0, 0));
    LLVMValueRef snprintf = fmt_wasm_snprintf_fn(e);
    LLVMValueRef snargs[5] = {
        data, LLVMConstInt(size_type(e), SA_FMT_WASM_F64_SCRATCH, 0), fmtp, prec, val
    };
    LLVMValueRef n = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(snprintf), snprintf, snargs, 5, "");
    LLVMBuildCondBr(e->builder, LLVMBuildICmp(e->builder, LLVMIntSLT, n, LLVMConstInt(e->i32_ty, 0, 0), ""), ret0, sized);
    LLVMPositionBuilderAtEnd(e->builder, sized);
    LLVMValueRef len64 = LLVMBuildSExt(e->builder, n, e->i64_ty, "");
    LLVMValueRef over = LLVMBuildICmp(e->builder, LLVMIntSGT, len64,
        LLVMConstInt(e->i64_ty, SA_FMT_WASM_F64_SCRATCH - 1, 0), "");
    LLVMValueRef len = LLVMBuildSelect(e->builder, over,
        LLVMConstInt(e->i64_ty, SA_FMT_WASM_F64_SCRATCH - 1, 0), len64, "");
    LLVMValueRef h = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(alloc_fn), alloc_fn, &len, 1, "");
    LLVMBuildCondBr(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, h, LLVMConstInt(e->i64_ty, 0, 0), ""), ret0, copy);
    LLVMPositionBuilderAtEnd(e->builder, copy);
    LLVMValueRef idx = LLVMBuildSub(e->builder, h, LLVMConstInt(e->i64_ty, 1, 0), "");
    LLVMValueRef dst = LLVMBuildLoad2(e->builder, e->ptr_ty, fmt_wasm_elem(e, s->ptrs_ty, s->ptrs, idx), "");
    fmt_wasm_call_memcpy(e, dst, data, len);
    LLVMBuildRet(e->builder, h);
    LLVMPositionBuilderAtEnd(e->builder, ret0);
    LLVMBuildRet(e->builder, LLVMConstInt(e->i64_ty, 0, 0));
}

static void fmt_wasm_define_bytes(EmitCtx *e, LLVMValueRef alloc_fn, const FmtWasmState *s) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_bytes");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMValueRef src = LLVMGetParam(fn, 0);
    LLVMValueRef len = LLVMGetParam(fn, 1);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef copy = LLVMAppendBasicBlockInContext(e->ctx, fn, "copy");
    LLVMBasicBlockRef ret0 = LLVMAppendBasicBlockInContext(e->ctx, fn, "ret0");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef is_empty = LLVMBuildICmp(e->builder, LLVMIntEQ, len, LLVMConstInt(e->i64_ty, 0, 0), "");
    LLVMValueRef eff = LLVMBuildSelect(e->builder, is_empty, LLVMConstInt(e->i64_ty, 1, 0), len, "");
    LLVMValueRef h = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(alloc_fn), alloc_fn, &eff, 1, "");
    LLVMBuildCondBr(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, h, LLVMConstInt(e->i64_ty, 0, 0), ""), ret0, copy);
    LLVMPositionBuilderAtEnd(e->builder, copy);
    LLVMValueRef idx = LLVMBuildSub(e->builder, h, LLVMConstInt(e->i64_ty, 1, 0), "");
    LLVMValueRef dst = LLVMBuildLoad2(e->builder, e->ptr_ty, fmt_wasm_elem(e, s->ptrs_ty, s->ptrs, idx), "");
    fmt_wasm_call_memcpy(e, dst, src, len);
    LLVMBuildStore(e->builder, len, fmt_wasm_elem(e, s->lens_ty, s->lens, idx));
    LLVMBuildRet(e->builder, h);
    LLVMPositionBuilderAtEnd(e->builder, ret0);
    LLVMBuildRet(e->builder, LLVMConstInt(e->i64_ty, 0, 0));
}

static void fmt_wasm_define_buffer_data(EmitCtx *e, const FmtWasmState *s, LLVMValueRef slot_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_buffer_data");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef found = LLVMAppendBasicBlockInContext(e->ctx, fn, "found");
    LLVMBasicBlockRef miss = LLVMAppendBasicBlockInContext(e->ctx, fn, "miss");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef handle = LLVMGetParam(fn, 0);
    LLVMValueRef idx = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(slot_fn), slot_fn, &handle, 1, "");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntSLT, idx, LLVMConstInt(e->i64_ty, 0, 0), ""), miss, found);
    LLVMPositionBuilderAtEnd(e->builder, found);
    LLVMBuildRet(e->builder, LLVMBuildLoad2(e->builder, e->ptr_ty, fmt_wasm_elem(e, s->ptrs_ty, s->ptrs, idx), ""));
    LLVMPositionBuilderAtEnd(e->builder, miss);
    LLVMBuildRet(e->builder, LLVMConstPointerNull(e->ptr_ty));
}

static void fmt_wasm_define_buffer_len(EmitCtx *e, const FmtWasmState *s, LLVMValueRef slot_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_buffer_len");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef found = LLVMAppendBasicBlockInContext(e->ctx, fn, "found");
    LLVMBasicBlockRef miss = LLVMAppendBasicBlockInContext(e->ctx, fn, "miss");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef handle = LLVMGetParam(fn, 0);
    LLVMValueRef idx = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(slot_fn), slot_fn, &handle, 1, "");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntSLT, idx, LLVMConstInt(e->i64_ty, 0, 0), ""), miss, found);
    LLVMPositionBuilderAtEnd(e->builder, found);
    LLVMBuildRet(e->builder, LLVMBuildLoad2(e->builder, e->i64_ty, fmt_wasm_elem(e, s->lens_ty, s->lens, idx), ""));
    LLVMPositionBuilderAtEnd(e->builder, miss);
    LLVMBuildRet(e->builder, LLVMConstInt(e->i64_ty, 0, 0));
}

static void fmt_wasm_define_buffer_free(EmitCtx *e, const FmtWasmState *s, LLVMValueRef slot_fn) {
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_fmt_buffer_free");
    if (fn == NULL || LLVMCountBasicBlocks(fn) != 0) return;
    // wasm may also link the wasm32-wasi sa_std archive (same ABI): weak so the archive wins; shim is the no-archive fallback.
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef found = LLVMAppendBasicBlockInContext(e->ctx, fn, "found");
    LLVMBasicBlockRef miss = LLVMAppendBasicBlockInContext(e->ctx, fn, "miss");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef handle = LLVMGetParam(fn, 0);
    LLVMValueRef idx = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(slot_fn), slot_fn, &handle, 1, "");
    LLVMBuildCondBr(e->builder,
        LLVMBuildICmp(e->builder, LLVMIntSLT, idx, LLVMConstInt(e->i64_ty, 0, 0), ""), miss, found);
    LLVMPositionBuilderAtEnd(e->builder, found);
    LLVMValueRef cell = fmt_wasm_elem(e, s->ptrs_ty, s->ptrs, idx);
    LLVMValueRef free_arg = LLVMBuildLoad2(e->builder, e->ptr_ty, cell, "");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->free_fn), e->free_fn, &free_arg, 1, "");
    LLVMBuildStore(e->builder, LLVMConstInt(e->i8_ty, 0, 0), fmt_wasm_elem(e, s->used_ty, s->used, idx));
    LLVMBuildStore(e->builder, LLVMConstPointerNull(e->ptr_ty), cell);
    LLVMBuildStore(e->builder, LLVMConstInt(e->i64_ty, 0, 0), fmt_wasm_elem(e, s->lens_ty, s->lens, idx));
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));
    LLVMPositionBuilderAtEnd(e->builder, miss);
    LLVMValueRef neg = LLVMBuildSub(e->builder, LLVMConstInt(e->i32_ty, 0, 0), LLVMConstInt(e->i32_ty, 1, 0), "");
    LLVMBuildRet(e->builder, neg);
}

static void emit_sa_fmt_wasm_runtime(EmitCtx *e) {
    static const char *names[] = {
        "sa_fmt_u64", "sa_fmt_i64", "sa_fmt_f64", "sa_fmt_bytes",
        "sa_fmt_buffer_data", "sa_fmt_buffer_len", "sa_fmt_buffer_free"
    };
    int need = 0;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        LLVMValueRef fn = LLVMGetNamedFunction(e->module, names[i]);
        if (fn != NULL && LLVMCountBasicBlocks(fn) == 0) { need = 1; break; }
    }
    if (!need) return;
    FmtWasmState s;
    fmt_wasm_ensure_state(e, &s);
    LLVMValueRef alloc_fn = fmt_wasm_ensure_alloc(e, &s);
    LLVMValueRef slot_fn = fmt_wasm_ensure_slot(e, &s);
    LLVMValueRef uint_fn = fmt_wasm_ensure_uint(e, &s, alloc_fn);
    fmt_wasm_define_u64(e, uint_fn);
    fmt_wasm_define_i64(e, uint_fn);
    fmt_wasm_define_f64(e, &s, alloc_fn);
    fmt_wasm_define_bytes(e, alloc_fn, &s);
    fmt_wasm_define_buffer_data(e, &s, slot_fn);
    fmt_wasm_define_buffer_len(e, &s, slot_fn);
    fmt_wasm_define_buffer_free(e, &s, slot_fn);
}

static void emit_sys_print(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_print", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 2, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef len = coerce_to_size(e, LLVMGetParam(fn, 1), "len_size");
    LLVMValueRef args[3] = { LLVMConstInt(e->i32_ty, 1, 0), LLVMGetParam(fn, 0), len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, args, 3, "");
    LLVMBuildRetVoid(e->builder);
}

static void emit_sys_exit(EmitCtx *e) {
    LLVMTypeRef params[1] = { e->i32_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_exit", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 1, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef code = LLVMGetParam(fn, 0);
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->exit_fn), e->exit_fn, &code, 1, "");
    LLVMBuildUnreachable(e->builder);
}

static void emit_panic_msg(EmitCtx *e) {
    LLVMTypeRef params[3] = { e->i32_ty, e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "panic_msg", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 3, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    e->panic_fn = fn;
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef code = LLVMGetParam(fn, 0);
    LLVMValueRef msg_ptr = LLVMBuildPointerCast(e->builder, LLVMGetParam(fn, 1), LLVMPointerType(e->i8_ty, 0), "panic_msg_ptr");
    LLVMValueRef msg_len = coerce_to_size(e, LLVMGetParam(fn, 2), "panic_msg_len");
    LLVMTypeRef sz_ty = size_type(e);

    // Dynamic decimal formatting of 'code' on the stack. i32 needs at most 10 unsigned digits.
    const unsigned max_panic_code_digits = 10;
    LLVMValueRef zero32 = LLVMConstInt(e->i32_ty, 0, 0);
    LLVMValueRef one32 = LLVMConstInt(e->i32_ty, 1, 0);
    LLVMValueRef ten32 = LLVMConstInt(e->i32_ty, 10, 0);

    LLVMValueRef buf = LLVMBuildAlloca(e->builder, LLVMArrayType(e->i8_ty, max_panic_code_digits), "buf");
    LLVMValueRef buf_ptr = LLVMBuildPointerCast(e->builder, buf, e->ptr_ty, "buf_ptr");

    LLVMValueRef tmp_slot = LLVMBuildAlloca(e->builder, e->i32_ty, "panic_code_tmp");
    LLVMValueRef idx_slot = LLVMBuildAlloca(e->builder, e->i32_ty, "panic_code_idx");
    LLVMBuildStore(e->builder, code, tmp_slot);
    LLVMBuildStore(e->builder, LLVMConstInt(e->i32_ty, max_panic_code_digits, 0), idx_slot);

    LLVMBasicBlockRef digits_loop_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "digits_loop");
    LLVMBasicBlockRef digits_done_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "digits_done");
    LLVMBuildBr(e->builder, digits_loop_bb);

    LLVMPositionBuilderAtEnd(e->builder, digits_loop_bb);
    LLVMValueRef tmp_value = LLVMBuildLoad2(e->builder, e->i32_ty, tmp_slot, "tmp");
    LLVMValueRef digit = LLVMBuildURem(e->builder, tmp_value, ten32, "digit");
    LLVMValueRef next_tmp = LLVMBuildUDiv(e->builder, tmp_value, ten32, "next_tmp");
    LLVMValueRef idx_value = LLVMBuildLoad2(e->builder, e->i32_ty, idx_slot, "idx");
    LLVMValueRef next_idx = LLVMBuildSub(e->builder, idx_value, one32, "next_idx");
    LLVMBuildStore(e->builder, next_idx, idx_slot);
    LLVMValueRef digit_char = LLVMBuildAdd(e->builder, digit, LLVMConstInt(e->i32_ty, '0', 0), "digit_char");
    LLVMValueRef digit_ptr = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &next_idx, 1, "digit_ptr");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, digit_char, e->i8_ty, ""), digit_ptr);
    LLVMBuildStore(e->builder, next_tmp, tmp_slot);
    LLVMValueRef more_digits = LLVMBuildICmp(e->builder, LLVMIntNE, next_tmp, zero32, "more_digits");
    LLVMBuildCondBr(e->builder, more_digits, digits_loop_bb, digits_done_bb);

    LLVMPositionBuilderAtEnd(e->builder, digits_done_bb);
    LLVMValueRef start_idx32 = LLVMBuildLoad2(e->builder, e->i32_ty, idx_slot, "start_idx");
    LLVMValueRef start_idx = coerce_to_size(e, start_idx32, "start_idx_size");
    LLVMValueRef formatted_ptr = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &start_idx, 1, "formatted_ptr");
    LLVMValueRef formatted_len = LLVMBuildSub(e->builder, LLVMConstInt(sz_ty, max_panic_code_digits, 0), start_idx, "formatted_len");

    // Branch on msg_len == 0 to determine layout
    LLVMValueRef is_zero_len = LLVMBuildICmp(e->builder, LLVMIntEQ, msg_len, LLVMConstInt(sz_ty, 0, 0), "is_zero_len");
    LLVMBasicBlockRef simple_panic_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "simple_panic");
    LLVMBasicBlockRef msg_panic_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "msg_panic");
    LLVMBasicBlockRef exit_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "exit_block");
    LLVMBuildCondBr(e->builder, is_zero_len, simple_panic_bb, msg_panic_bb);

    // Block: simple_panic
    LLVMPositionBuilderAtEnd(e->builder, simple_panic_bb);
    LLVMValueRef simple_prefix = const_c_string(e, ".panic_simple_prefix", "PANIC: code=");
    LLVMValueRef write_args_simple1[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        simple_prefix,
        LLVMConstInt(sz_ty, 12, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_simple1, 3, "");

    LLVMValueRef write_args_simple2[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        formatted_ptr,
        formatted_len
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_simple2, 3, "");

    LLVMBuildBr(e->builder, exit_bb);

    // Block: msg_panic
    LLVMPositionBuilderAtEnd(e->builder, msg_panic_bb);
    LLVMValueRef msg_prefix = const_c_string(e, ".panic_msg_prefix", "PANIC[");
    LLVMValueRef write_args_msg1[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        msg_prefix,
        LLVMConstInt(sz_ty, 6, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg1, 3, "");

    LLVMValueRef write_args_msg2[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        formatted_ptr,
        formatted_len
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg2, 3, "");

    LLVMValueRef msg_suffix = const_c_string(e, ".panic_msg_suffix", "]: ");
    LLVMValueRef write_args_msg3[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        msg_suffix,
        LLVMConstInt(sz_ty, 3, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg3, 3, "");

    LLVMValueRef write_args_msg4[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        msg_ptr,
        msg_len
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg4, 3, "");

    LLVMBuildBr(e->builder, exit_bb);

    // Block: exit_block
    LLVMPositionBuilderAtEnd(e->builder, exit_bb);
    LLVMValueRef newline = const_c_string(e, ".panic_newline", "\n");
    LLVMValueRef write_args_exit1[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        newline,
        LLVMConstInt(sz_ty, 1, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_exit1, 3, "");

    LLVMValueRef exit_code = LLVMBuildAdd(e->builder, code, LLVMConstInt(e->i32_ty, 128, 0), "exit_code");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->exit_fn), e->exit_fn, &exit_code, 1, "");
    LLVMBuildUnreachable(e->builder);
}

static void emit_sys_argc(EmitCtx *e) {
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_argc", LLVMFunctionType(e->i32_ty, NULL, 0, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMBuildRet(e->builder, LLVMBuildLoad2(e->builder, e->i32_ty, e->saasm_argc_global, "argc"));
}

static void emit_sys_argv(EmitCtx *e) {
    LLVMTypeRef params[1] = { e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_argv", LLVMFunctionType(e->ptr_ty, params, 1, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef argv = LLVMBuildLoad2(e->builder, e->ptr_ty, e->saasm_argv_global, "argv");
    LLVMValueRef index = coerce_to_size(e, LLVMGetParam(fn, 0), "index_size");
    LLVMTypeRef argv_array_ty = LLVMPointerType(e->ptr_ty, 0);
    LLVMValueRef argv_array = LLVMBuildPointerCast(e->builder, argv, argv_array_ty, "argv_array");
    LLVMValueRef slot = LLVMBuildGEP2(e->builder, e->ptr_ty, argv_array, &index, 1, "argv_slot");
    LLVMBuildRet(e->builder, LLVMBuildLoad2(e->builder, e->ptr_ty, slot, "arg"));
}

static void emit_sa_strdupz(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sa_strdupz", LLVMFunctionType(e->ptr_ty, params, 2, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef len = coerce_to_size(e, LLVMGetParam(fn, 1), "len_size");
    LLVMValueRef one = size_const(e, 1);
    LLVMValueRef size = LLVMBuildAdd(e->builder, len, one, "size");
    LLVMValueRef buf = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &size, 1, "buf");
    LLVMValueRef memcpy_args[3] = { buf, LLVMGetParam(fn, 0), len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->memcpy_fn), e->memcpy_fn, memcpy_args, 3, "");
    LLVMValueRef end_index = len;
    LLVMValueRef end = LLVMBuildGEP2(e->builder, e->i8_ty, buf, &end_index, 1, "end");
    LLVMBuildStore(e->builder, LLVMConstInt(e->i8_ty, 0, 0), end);
    LLVMBuildRet(e->builder, buf);
}

static void emit_sys_read_file(EmitCtx *e) {
    LLVMTypeRef params[3] = { e->ptr_ty, e->i64_ty, e->ptr_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_read_file", LLVMFunctionType(e->ptr_ty, params, 3, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef fail = LLVMAppendBasicBlockInContext(e->ctx, fn, "fail");
    LLVMBasicBlockRef ok = LLVMAppendBasicBlockInContext(e->ctx, fn, "ok");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef dup_args[2] = { LLVMGetParam(fn, 0), LLVMGetParam(fn, 1) };
    LLVMValueRef path = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(LLVMGetNamedFunction(e->module, "sa_strdupz")), LLVMGetNamedFunction(e->module, "sa_strdupz"), dup_args, 2, "path");
    LLVMValueRef mode = const_c_string(e, ".mode_rb", "rb");
    LLVMValueRef fopen_args[2] = { path, mode };
    LLVMValueRef file = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fopen_fn), e->fopen_fn, fopen_args, 2, "file");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->free_fn), e->free_fn, &path, 1, "");
    LLVMValueRef is_null = LLVMBuildICmp(e->builder, LLVMIntEQ, file, LLVMConstPointerNull(e->ptr_ty), "is_null");
    LLVMBuildCondBr(e->builder, is_null, fail, ok);
    LLVMPositionBuilderAtEnd(e->builder, fail);
    LLVMValueRef out_len_ptr_fail = LLVMBuildPointerCast(e->builder, LLVMGetParam(fn, 2), LLVMPointerType(e->i64_ty, 0), "out_len_ptr");
    LLVMBuildStore(e->builder, LLVMConstInt(e->i64_ty, 0, 0), out_len_ptr_fail);
    LLVMBuildRet(e->builder, LLVMConstPointerNull(e->ptr_ty));
    LLVMPositionBuilderAtEnd(e->builder, ok);
    LLVMValueRef seek_args[3] = { file, size_const(e, 0), LLVMConstInt(e->i32_ty, 2, 0) };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fseek_fn), e->fseek_fn, seek_args, 3, "");
    LLVMValueRef size = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->ftell_fn), e->ftell_fn, &file, 1, "size");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->rewind_fn), e->rewind_fn, &file, 1, "");
    LLVMValueRef size_arg = coerce_to_size(e, size, "size_arg");
    LLVMValueRef buf = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &size_arg, 1, "buf");
    LLVMValueRef fread_args[4] = { buf, size_const(e, 1), size_arg, file };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fread_fn), e->fread_fn, fread_args, 4, "");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fclose_fn), e->fclose_fn, &file, 1, "");
    LLVMValueRef out_len_ptr_ok = LLVMBuildPointerCast(e->builder, LLVMGetParam(fn, 2), LLVMPointerType(e->i64_ty, 0), "out_len_ptr");
    LLVMBuildStore(e->builder, coerce_int_to(e, size, e->i64_ty, "size64"), out_len_ptr_ok);
    LLVMBuildRet(e->builder, buf);
}

static void emit_sys_write_file(EmitCtx *e) {
    LLVMTypeRef params[4] = { e->ptr_ty, e->i64_ty, e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_write_file", LLVMFunctionType(e->i32_ty, params, 4, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef fail = LLVMAppendBasicBlockInContext(e->ctx, fn, "fail");
    LLVMBasicBlockRef ok = LLVMAppendBasicBlockInContext(e->ctx, fn, "ok");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef dup_args[2] = { LLVMGetParam(fn, 0), LLVMGetParam(fn, 1) };
    LLVMValueRef path = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(LLVMGetNamedFunction(e->module, "sa_strdupz")), LLVMGetNamedFunction(e->module, "sa_strdupz"), dup_args, 2, "path");
    LLVMValueRef mode = const_c_string(e, ".mode_wb", "wb");
    LLVMValueRef fopen_args[2] = { path, mode };
    LLVMValueRef file = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fopen_fn), e->fopen_fn, fopen_args, 2, "file");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->free_fn), e->free_fn, &path, 1, "");
    LLVMValueRef is_null = LLVMBuildICmp(e->builder, LLVMIntEQ, file, LLVMConstPointerNull(e->ptr_ty), "is_null");
    LLVMBuildCondBr(e->builder, is_null, fail, ok);
    LLVMPositionBuilderAtEnd(e->builder, fail);
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, (unsigned long long)-1, 1));
    LLVMPositionBuilderAtEnd(e->builder, ok);
    LLVMValueRef data_len = coerce_to_size(e, LLVMGetParam(fn, 3), "data_len_size");
    LLVMValueRef fwrite_args[4] = { LLVMGetParam(fn, 2), size_const(e, 1), data_len, file };
    LLVMValueRef written = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fwrite_fn), e->fwrite_fn, fwrite_args, 4, "written");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fclose_fn), e->fclose_fn, &file, 1, "");
    LLVMBuildRet(e->builder, coerce_int_to(e, written, e->i32_ty, "status"));
}

static void emit_sa_time_sleep_ns(EmitCtx *e) {
    // Runtime `sa_time_sleep_ns` returns plain i32 status (not Fallible {i32,i32}).
    // If SAI already declared the symbol, reuse its type; only emit a weak stub when missing.
    LLVMTypeRef params[1] = { e->i64_ty };
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_time_sleep_ns");
    if (fn == NULL) {
        fn = LLVMAddFunction(e->module, "sa_time_sleep_ns", LLVMFunctionType(e->i32_ty, params, 1, 0));
    }
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    if (LLVMCountBasicBlocks(fn) != 0) return;
    LLVMTypeRef declared_ret = LLVMGetReturnType(LLVMGlobalGetValueType(fn));
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    // Match declared return shape so we never ret {i32,i32} from an i32 function (or vice versa).
    if (LLVMGetTypeKind(declared_ret) == LLVMStructTypeKind) {
        LLVMBuildRet(e->builder, build_fallible_ok(e, SA_T_I32, LLVMConstInt(e->i32_ty, 0, 0), SA_T_I32));
    } else {
        LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));
    }
}

static void emit_sys_runtime(EmitCtx *e) {
    emit_sa_strdupz(e);
    emit_sys_print(e);
    emit_sys_exit(e);
    emit_panic_msg(e);
    emit_sys_argc(e);
    emit_sys_argv(e);
    emit_sys_read_file(e);
    emit_sys_write_file(e);
    emit_sa_time_sleep_ns(e);
}

int sa_llvmc_make_minimal_module_bitcode(unsigned char **out_bytes, size_t *out_len, char **out_error) {
    if (out_bytes == NULL || out_len == NULL) return set_error(out_error, "invalid output pointers");
    *out_bytes = NULL; *out_len = 0;
    LLVMContextRef context = LLVMContextCreate();
    if (context == NULL) return set_error(out_error, "LLVMContextCreate failed");
    LLVMModuleRef module = LLVMModuleCreateWithNameInContext("sa_llvmc_test", context);
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    if (module == NULL || builder == NULL) {
        if (builder != NULL) LLVMDisposeBuilder(builder);
        if (module != NULL) LLVMDisposeModule(module);
        LLVMContextDispose(context);
        return set_error(out_error, "LLVM module or builder creation failed");
    }
    LLVMTypeRef i32_ty = LLVMInt32TypeInContext(context);
    LLVMTypeRef fn_ty = LLVMFunctionType(i32_ty, NULL, 0, 0);
    LLVMValueRef fn_value = LLVMAddFunction(module, "main", fn_ty);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(context, fn_value, "entry");
    LLVMPositionBuilderAtEnd(builder, entry);
    LLVMBuildRet(builder, LLVMConstInt(i32_ty, 0, 0));
    int status = module_bitcode_to_heap(module, out_bytes, out_len);
    LLVMDisposeBuilder(builder); LLVMDisposeModule(module); LLVMContextDispose(context);
    if (status != 0) return set_error(out_error, "writing bitcode failed");
    return 0;
}

static void emit_test_harness_main(EmitCtx *e, const SaModule *m) {
    LLVMValueRef getenv_fn = LLVMGetNamedFunction(e->module, "getenv");
    if (getenv_fn == NULL) {
        LLVMTypeRef getenv_param = e->ptr_ty;
        getenv_fn = LLVMAddFunction(e->module, "getenv", LLVMFunctionType(e->ptr_ty, &getenv_param, 1, 0));
    }

    LLVMValueRef strcmp_fn = LLVMGetNamedFunction(e->module, "strcmp");
    if (strcmp_fn == NULL) {
        LLVMTypeRef strcmp_params[2] = { e->ptr_ty, e->ptr_ty };
        strcmp_fn = LLVMAddFunction(e->module, "strcmp", LLVMFunctionType(e->i32_ty, strcmp_params, 2, 0));
    }

    size_t test_count = 0;
    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind == SA_F_TEST) test_count++;
    }

    LLVMTypeRef main_params[2] = { e->i32_ty, e->ptr_ty };
    LLVMValueRef main_fn = LLVMAddFunction(e->module, "main", LLVMFunctionType(e->i32_ty, main_params, 2, 0));

    if (test_count == 0) {
        LLVMBasicBlockRef entry_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "entry");
        LLVMPositionBuilderAtEnd(e->builder, entry_bb);
        LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));
        return;
    }

    LLVMBasicBlockRef entry_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "entry");
    LLVMBasicBlockRef run_all_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "run_all");
    LLVMBasicBlockRef select_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "select");

    LLVMPositionBuilderAtEnd(e->builder, entry_bb);
    LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 0), e->saasm_argc_global);
    LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 1), e->saasm_argv_global);
    LLVMValueRef env_ptr = const_c_string(e, ".sa_test_name_env", "SA_TEST_NAME");
    LLVMValueRef filter = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(getenv_fn), getenv_fn, &env_ptr, 1, "filter");
    LLVMValueRef has_filter = LLVMBuildICmp(e->builder, LLVMIntNE, filter, LLVMConstPointerNull(e->ptr_ty), "has_filter");
    LLVMBuildCondBr(e->builder, has_filter, select_bb, run_all_bb);

    LLVMPositionBuilderAtEnd(e->builder, run_all_bb);
    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind != SA_F_TEST) continue;
        LLVMValueRef test_fn = find_function(e, m->functions[i].name);
        LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(test_fn), test_fn, NULL, 0, "");
    }
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));

    LLVMPositionBuilderAtEnd(e->builder, select_bb);

    LLVMBasicBlockRef current_select = select_bb;
    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind != SA_F_TEST) continue;
        char glob_name[64];
        if (snprintf(glob_name, sizeof(glob_name), ".sa_test_name_%zu", i) >= (int)sizeof(glob_name)) return;
        LLVMValueRef test_name_ptr = const_c_string(e, glob_name, m->functions[i].name);
        LLVMValueRef strcmp_args[2] = { filter, test_name_ptr };
        LLVMValueRef cmp = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(strcmp_fn), strcmp_fn, strcmp_args, 2, "cmp");
        LLVMValueRef eq = LLVMBuildICmp(e->builder, LLVMIntEQ, cmp, LLVMConstInt(e->i32_ty, 0, 0), "eq");
    

        LLVMBasicBlockRef match_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "match");
        LLVMBasicBlockRef next_select = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "select_next");
        LLVMBuildCondBr(e->builder, eq, match_bb, next_select);

        LLVMPositionBuilderAtEnd(e->builder, match_bb);
        LLVMValueRef test_fn = find_function(e, m->functions[i].name);
        LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(test_fn), test_fn, NULL, 0, "");
        LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));

        current_select = next_select;
        LLVMPositionBuilderAtEnd(e->builder, current_select);
    }

    LLVMValueRef missing_ptr = const_c_string(e, ".sa_test_missing_msg", "error: no matching test\n");
    LLVMTypeRef sz_ty = size_type(e);
    LLVMValueRef missing_len = LLVMConstInt(sz_ty, 24, 0);
    LLVMValueRef write_args[3] = { LLVMConstInt(e->i32_ty, 2, 0), missing_ptr, missing_len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args, 3, "written");
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 1, 0));
}

/* Build an LLVM module from a SA module description.
 * On success returns 0 and *e is fully initialised – caller must dispose_emit_ctx(e).
 * On failure returns non-zero and disposes the partial context itself. */
static int build_sa_llvm_module(const SaModule *m, EmitCtx *e, char **out_error) {
    memset(e, 0, sizeof(*e));
    e->ctx = LLVMContextCreate();
    if (e->ctx == NULL) return set_error(out_error, "LLVMContextCreate failed");
    e->module = LLVMModuleCreateWithNameInContext("sa_module", e->ctx);
    e->builder = LLVMCreateBuilderInContext(e->ctx);
    if (e->module == NULL || e->builder == NULL) {
        dispose_emit_ctx(e);
        return set_error(out_error, "LLVM module or builder creation failed");
    }
    e->size_bits = m->size_bits;
    e->is_cgu = m->is_cgu;
    e->wasm_compat = m->wasm_compat;
    e->target_triple = m->target_triple;
    if (m->function_count > UINT_MAX) {
        dispose_emit_ctx(e);
        return set_error(out_error, "function table too large");
    }
    e->i8_ty  = LLVMInt8TypeInContext(e->ctx);
    e->i32_ty = LLVMInt32TypeInContext(e->ctx);
    e->i64_ty = LLVMInt64TypeInContext(e->ctx);
    e->ptr_ty = LLVMPointerType(e->i8_ty, 0);
    e->functions     = m->functions;
    e->function_count = m->function_count;
    if (apply_native_target_layout(e, out_error) != 0) {
        dispose_emit_ctx(e);
        return 1;
    }

    debug_init(e, m);
    declare_runtime(e);

    for (size_t i = 0; i < m->const_count; i++) {
        if (m->consts[i].len > UINT_MAX) { dispose_emit_ctx(e); return set_error(out_error, "const too large"); }
        const unsigned const_len = (unsigned)m->consts[i].len;
        LLVMTypeRef arr_ty = LLVMArrayType(e->i8_ty, const_len);
        LLVMValueRef glob = LLVMAddGlobal(e->module, arr_ty, m->consts[i].name);
        LLVMSetGlobalConstant(glob, 1);
        LLVMSetLinkage(glob, LLVMPrivateLinkage);
        LLVMValueRef *vals = NULL;
        if (m->consts[i].len != 0) vals = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * m->consts[i].len);
        if (m->consts[i].len != 0 && vals == NULL) { dispose_emit_ctx(e); return set_error(out_error, "alloc const failed"); }
        for (size_t j = 0; j < m->consts[i].len; j++) vals[j] = LLVMConstInt(e->i8_ty, m->consts[i].data[j], 0);
        LLVMSetInitializer(glob, LLVMConstArray(e->i8_ty, vals, const_len));
        free(vals);
    }

    for (size_t i = 0; i < m->function_count; i++) {
        if (strcmp(m->functions[i].name, "sa_print_bytes") == 0 && m->functions[i].kind == SA_F_EXTERNAL) {
            declare_sa_print_bytes(e);
            continue;
        }
        LLVMTypeRef fty = fn_type_for(e, &m->functions[i]);
        if (fty == NULL) { dispose_emit_ctx(e); return set_error(out_error, "function type failed"); }
        LLVMValueRef fn = LLVMAddFunction(e->module, m->functions[i].name, fty);
        if (external_fallible_uses_sret_win64(&m->functions[i])) {
            unsigned sret_kind = LLVMGetEnumAttributeKindForName("sret", 4);
            LLVMTypeRef sret_struct = fallible_type_of(e, m->functions[i].ret_ty);
            LLVMAttributeRef sret_attr = LLVMCreateTypeAttribute(e->ctx, sret_kind, sret_struct);
            LLVMAddAttributeAtIndex(fn, 1, sret_attr);
        }
        if (m->functions[i].kind != SA_F_EXPORTED && strcmp(m->functions[i].name, "saasm_main") != 0)
            LLVMSetLinkage(fn, (m->functions[i].kind == SA_F_EXTERNAL || m->is_cgu) ? LLVMExternalLinkage : LLVMInternalLinkage);
        int direct_self_call = function_has_direct_self_call(&m->functions[i]);
        if (m->functions[i].kind == SA_F_NORMAL &&
            !m->is_cgu &&
            !m->functions[i].emit_main_wrapper &&
            !direct_self_call &&
            m->functions[i].instruction_count <= 24) {
            add_always_inline(e, fn);
        } else if (m->functions[i].kind == SA_F_NORMAL &&
            !m->is_cgu &&
            !m->functions[i].emit_main_wrapper &&
            m->functions[i].instruction_count <= 100) {
            add_inline_hint(e, fn);
        }
    }
    if (m->wasm_compat) {
        emit_sa_print_bytes(e);
        emit_sa_fmt_wasm_runtime(e);
        emit_sa_hexdec_simd_wasm(e);
        emit_sa_b64dec_simd_wasm(e);
        emit_sa_mfind_u8_wasm(e);
    }
    emit_sys_runtime(e);

    for (size_t i = 0; i < m->vtable_count; i++) {
        LLVMTypeRef slot_ty = vtable_slot_type(e);
        if (m->vtables[i].func_count > UINT_MAX) { dispose_emit_ctx(e); return set_error(out_error, "vtable too large"); }
        const unsigned vtable_len = (unsigned)m->vtables[i].func_count;
        LLVMTypeRef arr_ty  = LLVMArrayType(slot_ty, vtable_len);
        LLVMValueRef glob   = LLVMAddGlobal(e->module, arr_ty, m->vtables[i].name);
        LLVMSetGlobalConstant(glob, 1);
        LLVMSetLinkage(glob, LLVMPrivateLinkage);
        LLVMValueRef *vals = NULL;
        if (m->vtables[i].func_count != 0) vals = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * m->vtables[i].func_count);
        if (m->vtables[i].func_count != 0 && vals == NULL) { dispose_emit_ctx(e); return set_error(out_error, "alloc vtable failed"); }
        for (size_t j = 0; j < m->vtables[i].func_count; j++) {
            LLVMValueRef fn = find_function(e, m->vtables[i].funcs[j]);
            if (fn == NULL) { free(vals); dispose_emit_ctx(e); return set_error(out_error, "vtable function not found"); }
            vals[j] = vtable_slot_value(e, fn);
        }
        LLVMSetInitializer(glob, LLVMConstArray(slot_ty, vals, vtable_len));
        free(vals);
    }

    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind == SA_F_EXTERNAL) continue;
        if (emit_function_body(e, &m->functions[i]) != 0) {
            int err_status = set_error(out_error, e->body_error[0] != 0 ? e->body_error : "emit function body failed");
            dispose_emit_ctx(e);
            return err_status;
        }
    }

    if (m->test_mode) {
        emit_test_harness_main(e, m);
    } else {
        for (size_t i = 0; i < m->function_count; i++) {
            if (!m->functions[i].emit_main_wrapper) continue;
            LLVMTypeRef params[2] = { e->i32_ty, e->ptr_ty };
            /* WASI command model (wasi-libc __main_void.c contract): the
               compiler must expose the argc/argv entry as `__main_argc_argv`.
               A plain `main` is left unreferenced and links to an
               `unreachable` weak stub (LLVM 14's libc provided a weak default
               `__main_argc_argv` that called `main`; LLVM 17+ toolchains do
               not, so the rename is required for wasm_compat). Native keeps
               the traditional `main` entry. */
            const char *entry_name = m->wasm_compat ? "__main_argc_argv" : "main";
            LLVMValueRef main_fn = LLVMAddFunction(e->module, entry_name, LLVMFunctionType(e->i32_ty, params, 2, 0));
            LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "entry");
            LLVMPositionBuilderAtEnd(e->builder, bb);
            LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 0), e->saasm_argc_global);
            LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 1), e->saasm_argv_global);
            LLVMValueRef target = find_function(e, m->functions[i].name);
            LLVMValueRef res = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(target), target, NULL, 0,
                m->functions[i].ret_ty == SA_T_VOID && !m->functions[i].return_fallible ? "" : "res");
            if (m->functions[i].return_fallible) {
                LLVMValueRef status = LLVMBuildExtractValue(e->builder, res, 0, "status");
                LLVMBuildRet(e->builder, status);
            } else if (m->functions[i].ret_ty == SA_T_VOID) {
                LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));
            } else {
                LLVMBuildRet(e->builder, coerce(e, res, m->functions[i].ret_ty, SA_T_I32));
            }
            break;
        }
    }

    if (e->dib != NULL) LLVMDIBuilderFinalize(e->dib);

    if (verify_emit_module(e, out_error) != 0) {
        dispose_emit_ctx(e);
        return 1;
    }
    return 0;
}

/* Emit LLVM bitcode bytes to heap (original interface). */
int sa_llvmc_emit_module_bitcode(const SaModule *m, int opt_level, unsigned char **out_bytes, size_t *out_len, char **out_error) {
    if (m == NULL || out_bytes == NULL || out_len == NULL) return set_error(out_error, "invalid module pointers");
    *out_bytes = NULL; *out_len = 0;
    EmitCtx e;
    if (build_sa_llvm_module(m, &e, out_error) != 0) return 1;
    optimize_module_ir(&e, opt_level);
    if (verify_emit_module(&e, out_error) != 0) {
        dispose_emit_ctx(&e);
        return 1;
    }
    int status = module_bitcode_to_heap(e.module, out_bytes, out_len);
    dispose_emit_ctx(&e);
    if (status != 0) return set_error(out_error, "writing bitcode failed");
    return 0;
}

/* In-process native object emission: build IR and emit .o without spawning any subprocess.
 * opt_level: 0=none, 1=O1 (fast, matches -O1), 2=O2, 3=O3 */
int sa_llvmc_emit_module_object(const SaModule *m, const char *out_path, int opt_level, char **out_error) {
    if (m == NULL || out_path == NULL) return set_error(out_error, "invalid pointers");
    EmitCtx e;
    if (build_sa_llvm_module(m, &e, out_error) != 0) return 1;

    char triple_buf[128];
    char *triple = NULL;
    int triple_owned = 0;
    if (m->target_triple != NULL && m->target_triple[0] != '\0') {
        normalize_triple_for_llvm(m->target_triple, triple_buf, sizeof(triple_buf));
        triple = triple_buf;
    } else {
        triple = LLVMGetDefaultTargetTriple();
        triple_owned = 1;
    }
    const int is_cross = (m->target_triple != NULL && m->target_triple[0] != '\0');
    LLVMTargetRef target;
    char *err_msg = NULL;
    if (LLVMGetTargetFromTriple(triple, &target, &err_msg)) {
        int s = set_error(out_error, err_msg ? err_msg : "target lookup failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        if (triple_owned) LLVMDisposeMessage(triple);
        dispose_emit_ctx(&e);
        return s;
    }

    LLVMCodeGenOptLevel cg_opt;
    switch (opt_level) {
        case 0:  cg_opt = LLVMCodeGenLevelNone;        break;
        case 1:  cg_opt = LLVMCodeGenLevelLess;        break;
        case 2:  cg_opt = LLVMCodeGenLevelDefault;     break;
        default: cg_opt = LLVMCodeGenLevelAggressive;  break;
    }

    /* Use the host CPU so we get tuned codegen (equivalent to -mcpu=native);
       for cross targets use the generic CPU instead. */
    char *cpu;
    char *features;
    if (is_cross) { cpu = (char *)""; features = (char *)""; }
    else { cpu = LLVMGetHostCPUName(); features = LLVMGetHostCPUFeatures(); }
    LLVMTargetMachineRef tm = LLVMCreateTargetMachine(
        target, triple, cpu, features,
        cg_opt, LLVMRelocDefault, LLVMCodeModelDefault
    );
    if (!is_cross) {
        LLVMDisposeMessage(cpu);
        LLVMDisposeMessage(features);
    }
    if (triple_owned) LLVMDisposeMessage(triple);

    if (tm == NULL) {
        dispose_emit_ctx(&e);
        return set_error(out_error, "TargetMachine creation failed");
    }

    optimize_module_ir(&e, opt_level);
    if (verify_emit_module(&e, out_error) != 0) {
        LLVMDisposeTargetMachine(tm);
        dispose_emit_ctx(&e);
        return 1;
    }

    if (LLVMTargetMachineEmitToFile(tm, e.module, (char *)out_path, LLVMObjectFile, &err_msg)) {
        int s = set_error(out_error, err_msg ? err_msg : "emit object failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        LLVMDisposeTargetMachine(tm);
        dispose_emit_ctx(&e);
        return s;
    }

    LLVMDisposeTargetMachine(tm);
    dispose_emit_ctx(&e);
    return 0;
}

int sa_llvmc_emit_module_artifacts(const SaModule *m, const char *out_bitcode_path, const char *out_object_path, int opt_level, char **out_error) {
    if (m == NULL || out_bitcode_path == NULL || out_object_path == NULL) return set_error(out_error, "invalid pointers");
    EmitCtx e;
    if (build_sa_llvm_module(m, &e, out_error) != 0) return 1;

    char triple_buf[128];
    char *triple = NULL;
    int triple_owned = 0;
    if (m->target_triple != NULL && m->target_triple[0] != '\0') {
        normalize_triple_for_llvm(m->target_triple, triple_buf, sizeof(triple_buf));
        triple = triple_buf;
    } else {
        triple = LLVMGetDefaultTargetTriple();
        triple_owned = 1;
    }
    const int is_cross = (m->target_triple != NULL && m->target_triple[0] != '\0');
    LLVMTargetRef target;
    char *err_msg = NULL;
    if (LLVMGetTargetFromTriple(triple, &target, &err_msg)) {
        int s = set_error(out_error, err_msg ? err_msg : "target lookup failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        if (triple_owned) LLVMDisposeMessage(triple);
        dispose_emit_ctx(&e);
        return s;
    }

    LLVMCodeGenOptLevel cg_opt;
    switch (opt_level) {
        case 0:  cg_opt = LLVMCodeGenLevelNone;        break;
        case 1:  cg_opt = LLVMCodeGenLevelLess;        break;
        case 2:  cg_opt = LLVMCodeGenLevelDefault;     break;
        default: cg_opt = LLVMCodeGenLevelAggressive;  break;
    }

    char *cpu;
    char *features;
    if (is_cross) { cpu = (char *)""; features = (char *)""; }
    else { cpu = LLVMGetHostCPUName(); features = LLVMGetHostCPUFeatures(); }
    LLVMTargetMachineRef tm = LLVMCreateTargetMachine(
        target, triple, cpu, features,
        cg_opt, LLVMRelocDefault, LLVMCodeModelDefault
    );
    if (!is_cross) {
        LLVMDisposeMessage(cpu);
        LLVMDisposeMessage(features);
    }
    if (triple_owned) LLVMDisposeMessage(triple);

    if (tm == NULL) {
        dispose_emit_ctx(&e);
        return set_error(out_error, "TargetMachine creation failed");
    }

    optimize_module_ir(&e, opt_level);
    if (verify_emit_module(&e, out_error) != 0) {
        LLVMDisposeTargetMachine(tm);
        dispose_emit_ctx(&e);
        return 1;
    }

    if (LLVMWriteBitcodeToFile(e.module, out_bitcode_path) != 0) {
        LLVMDisposeTargetMachine(tm);
        dispose_emit_ctx(&e);
        return set_error(out_error, "writing bitcode failed");
    }

    if (LLVMTargetMachineEmitToFile(tm, e.module, (char *)out_object_path, LLVMObjectFile, &err_msg)) {
        int s = set_error(out_error, err_msg ? err_msg : "emit object failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        LLVMDisposeTargetMachine(tm);
        dispose_emit_ctx(&e);
        return s;
    }

    LLVMDisposeTargetMachine(tm);
    dispose_emit_ctx(&e);
    return 0;
}
