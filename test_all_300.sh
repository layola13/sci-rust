#!/bin/bash

set -u
set -o pipefail

SAASM_BIN=${SAASM_BIN:-./zig-out/bin/sa}
NODE_BIN=${NODE_BIN:-node}

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    echo "error: node is required to validate wasm targets" >&2
    exit 1
fi

if ! command -v realpath >/dev/null 2>&1; then
    echo "error: realpath is required to resolve demo sources" >&2
    exit 1
fi

repo_root=$(dirname "$(realpath "$0")")
cd "$repo_root"

append_failure() {
    fail=$((fail + 1))
    fail_list+=$'\n'"$1"
}

check_trap_output() {
    local log_file=$1
    local expected_trap=$2
    local expected_code=$3
    local expected_message=$4

    grep -q "\"trap\":\"${expected_trap}\"" "$log_file" &&
        grep -q "\"trap_code\":${expected_code}" "$log_file" &&
        grep -q "$expected_message" "$log_file"
}

check_linker_output() {
    local log_file=$1
    local expected_message=$2

    grep -q "$expected_message" "$log_file"
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

wasm_runner="$tmp_root/run_wasm.js"
cat >"$wasm_runner" <<'EOF'
const fs = require('node:fs');
const { WASI } = require('node:wasi');

const wasmPath = process.argv[2];
const wasi = new WASI({
  version: 'preview1',
  args: process.argv.slice(3),
  env: {},
  preopens: { '/': '.' },
});

const wasm = fs.readFileSync(wasmPath);
WebAssembly.instantiate(wasm, wasi.getImportObject()).then(({ instance }) => {
  process.exitCode = wasi.start(instance);
}).catch((err) => {
  console.error(err);
  process.exit(1);
});
EOF

wasm64_validator="$tmp_root/validate_wasm64.cjs"
cat >"$wasm64_validator" <<'EOF'
const fs = require('node:fs');

const wasmPath = process.argv[2];
const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(mod);
const export_descs = WebAssembly.Module.exports(mod);

if (imports.length !== 0) {
  console.error(`expected no imports, got ${imports.length}`);
  process.exit(1);
}

if (export_descs.length !== 1 || export_descs[0].name !== 'memory' || export_descs[0].kind !== 'memory') {
  console.error(`expected only a memory export, got ${export_descs.map((item) => `${item.name}:${item.kind}`).join(', ')}`);
  process.exit(1);
}
EOF

pass=0
fail=0
skip=0
fail_list=""

for dir in demos/rosetta/*; do
    [ -f "$dir/main.sars" ] || continue

    base=$(basename "$dir")
    # Skip HTTP demos that need special runtime
    case "$base" in
        301_http_client_saasm|302_http_server_saasm)
            ((skip++))
            continue
            ;;
    esac
    num_raw=${base%%_*}
    case "$num_raw" in
        ''|*[!0-9]*) continue ;;
    esac
    num=$((10#$num_raw))
    if [ "$num" -lt 1 ] || [ "$num" -gt 333 ]; then
        continue
    fi

    source_path=$(realpath "$dir/main.sars")
    native_stdout="$tmp_root/$base.native.stdout"
    native_stderr="$tmp_root/$base.native.stderr"
    wasm_stdout="$tmp_root/$base.wasm.stdout"
    wasm_stderr="$tmp_root/$base.wasm.stderr"
    build_log="$tmp_root/$base.build.log"
    demo_bin_path="$dir/bin"
    if [ -e "$demo_bin_path" ] && [ ! -d "$demo_bin_path" ]; then
        native_out="$dir/bin.out"
        wasm_out="$dir/bin.wasm"
    else
        mkdir -p "$demo_bin_path"
        native_out="$demo_bin_path/$base.out"
        wasm_out="$demo_bin_path/$base.wasm"
    fi
    native_bc_out="${native_out}.sa.bc"
    wasm_bc_out="${wasm_out}.sa.bc"
    rm -f "$native_out" "$native_bc_out" "$wasm_out" "$wasm_bc_out"
    wasm_target="wasm32"
    wasm_compile_only=0
    wasm_native_only=0

    case "$base" in
        110_trait_super_vtable|164_trait_upcasting)
            wasm_target="wasm64"
            wasm_compile_only=1
            ;;
        181_file_descriptor_raii|182_mmap_memory_mapping|183_signal_handling_setup|184_pthread_spawn_join|185_dynamic_lib_dlopen|186_sqlite_c_api_binding)
            wasm_native_only=1
            ;;
    esac

    case "$base" in
        205_pkg_cyclic_dependency_reject|207_pkg_multiple_versions_conflict|226_mod_cyclic_import_detect|227_mod_shadowing_prevention|243_contract_sig_mismatch_link)
            expected_trap=""
            expected_code=0
            expected_message=""
            case "$base" in
                205_pkg_cyclic_dependency_reject)
                    expected_trap="ForbiddenSyntax"
                    expected_code=1001
                    expected_message="import cycle detected during flattening"
                    ;;
                207_pkg_multiple_versions_conflict)
                    expected_trap="DuplicateDef"
                    expected_code=1002
                    expected_message="duplicate definition detected during flattening"
                    ;;
                226_mod_cyclic_import_detect)
                    expected_trap="ForbiddenSyntax"
                    expected_code=1001
                    expected_message="import cycle detected during flattening"
                    ;;
                227_mod_shadowing_prevention)
                    expected_trap="DuplicateDef"
                    expected_code=1002
                    expected_message="duplicate definition detected during flattening"
                    ;;
                243_contract_sig_mismatch_link)
                    expected_trap="CapabilityMismatch"
                    expected_code=1013
                    expected_message="call-site capability prefix does not match the callee contract"
                    ;;
            esac

            if "$SAASM_BIN" build-exe "$source_path" -o "$native_out" >"$build_log" 2>&1; then
                append_failure "$base (native build unexpectedly succeeded)"
                rm -f "$native_out" "$native_bc_out" "$wasm_out" "$wasm_bc_out"
                continue
            fi
            if ! check_trap_output "$build_log" "$expected_trap" "$expected_code" "$expected_message"; then
                append_failure "$base (native trap output mismatch)"
                rm -f "$native_out" "$native_bc_out" "$wasm_out" "$wasm_bc_out"
                continue
            fi

            if "$SAASM_BIN" build-wasm "$source_path" -o "$wasm_out" --target wasm32 >"$build_log" 2>&1; then
                append_failure "$base (wasm build unexpectedly succeeded)"
                rm -f "$native_out" "$native_bc_out" "$wasm_out" "$wasm_bc_out"
                continue
            fi
            if ! check_trap_output "$build_log" "$expected_trap" "$expected_code" "$expected_message"; then
                append_failure "$base (wasm trap output mismatch)"
                rm -f "$native_out" "$native_bc_out" "$wasm_out" "$wasm_bc_out"
                continue
            fi

            ((pass++))
            rm -f "$native_bc_out" "$wasm_bc_out"
            continue
            ;;
    esac

    if [ "$base" = "220_pkg_lib_dynamic" ]; then
        main_source=$(realpath "$dir/main.sars")
        lib_source=$(realpath "$dir/lib/index.sars")
        sa_std_archive_path="artifacts/sa_std/libsa_std.a"
        main_obj="$tmp_root/$base.main.o"
        lib_obj="$tmp_root/$base.lib.o"
        lib_archive="$tmp_root/$base.lib.a"

        if ! "$SAASM_BIN" build-obj "$main_source" -o "$main_obj" >"$build_log" 2>&1; then
            append_failure "$base (main object build failed)"
            continue
        fi
        if ! "$SAASM_BIN" build-obj "$lib_source" -o "$lib_obj" >"$build_log" 2>&1; then
            append_failure "$base (lib object build failed)"
            continue
        fi
        if ! ar rcs "$lib_archive" "$lib_obj" >"$build_log" 2>&1; then
            append_failure "$base (archive creation failed)"
            continue
        fi
        if ! zig cc "$main_obj" "$lib_archive" "$sa_std_archive_path" -o "$native_out" >"$build_log" 2>&1; then
            append_failure "$base (native zig cc link failed)"
            continue
        fi
        if "$native_out" >"$native_stdout" 2>"$native_stderr"; then
            native_code=0
        else
            native_code=$?
        fi
        if [ "$native_code" -ne 0 ]; then
            append_failure "$base (native object/archive run mismatch)"
            continue
        fi

        ((pass++))
        continue
    fi

    if ! "$SAASM_BIN" build-exe "$source_path" -o "$native_out" >"$build_log" 2>&1; then
        append_failure "$base (native build failed)"
        rm -f "$native_out" "$native_bc_out"
        continue
    fi
    if "$native_out" >"$native_stdout" 2>"$native_stderr"; then
        native_code=0
    else
        native_code=$?
    fi
    if [ "$native_code" -ne 0 ]; then
        append_failure "$base (native run mismatch)"
        rm -f "$native_out" "$native_bc_out"
        continue
    fi

    rm -f "$native_bc_out"

    if [ "$wasm_native_only" -eq 1 ]; then
        ((pass++))
        continue
    fi

    if [ "$wasm_compile_only" -eq 1 ]; then
        if ! "$SAASM_BIN" build-wasm "$source_path" -o "$wasm_out" --target "$wasm_target" >"$build_log" 2>&1; then
            append_failure "$base (wasm64 build failed)"
            rm -f "$wasm_out" "$wasm_bc_out"
            continue
        fi
        if ! "$NODE_BIN" --no-warnings "$wasm64_validator" "$wasm_out" >"$wasm_stdout" 2>"$wasm_stderr"; then
            append_failure "$base (wasm64 validation failed)"
            rm -f "$wasm_out" "$wasm_bc_out"
            continue
        fi
        rm -f "$wasm_bc_out"
    else
        if ! "$SAASM_BIN" build-wasm "$source_path" -o "$wasm_out" --target "$wasm_target" >"$build_log" 2>&1; then
            append_failure "$base (wasm build failed)"
            rm -f "$wasm_out" "$wasm_bc_out"
            continue
        fi
        if "$NODE_BIN" --no-warnings "$wasm_runner" "$wasm_out" saasm "$base.wasm" >"$wasm_stdout" 2>"$wasm_stderr"; then
            wasm_code=0
        else
            wasm_code=$?
        fi
        if [ "$wasm_code" -ne 0 ] || ! cmp -s "$wasm_stdout" "$native_stdout" || ! cmp -s "$wasm_stderr" "$native_stderr"; then
            append_failure "$base (wasm run mismatch)"
            rm -f "$wasm_out" "$wasm_bc_out"
            continue
        fi
        rm -f "$wasm_bc_out"
    fi

    ((pass++))
done

echo "Total Passed: $pass, Failed: $fail, Skipped: $skip"
if [ "$fail" -gt 0 ]; then
    echo -e "Failures:$fail_list" | head -n 40
fi
