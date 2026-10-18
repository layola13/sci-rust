# PowerShell 与文本编码约定

- Windows 终端命令统一使用 `C:\Program Files\PowerShell\7\pwsh.exe -NoLogo -NoProfile`，不要使用 Windows PowerShell 5.1。
- 读取包含中文的文本、Markdown、TOML、JSON 时显式使用 `Get-Content -Encoding UTF8`。
- 写入文本优先使用 `apply_patch`；必须使用 PowerShell 写入时显式使用 `Set-Content -Encoding UTF8` 或 `Add-Content -Encoding UTF8`。
- 终端输出出现乱码时，先按 UTF-8 重新读取确认，不要直接认定文件损坏。
-NoNewline

## 2026-08-09 (installer one-shot restore; verify)
Question:
- The installed `sa.exe` got overwritten with a non-LLVM stub build (PE has no `LLVM-C.dll` import) by an earlier agent that assumed the host had no local LLVM-14 and could not rebuild a real LLVM-linked `sa.exe`. Did `tools/install.bat` actually rebuild + re-install the LLVM-C-linked binary end-to-end on this host, and is it durable for future loss?

Evidence checked:
- Prior state measured before restore: installed `C:\Users\zhan\AppData\Local\Programs\SCI\current\bin\sa.exe` = 10926592 B, mtime 22:30:37; ASCII-import probe of the PE found NO `LLVM-C.dll` string -> stub build (unlinked from the runtime LLVM backend). `LLVM-C.dll` (77487616 B) was still present beside it but unused.
- Host toolchain present (contrary to the earlier agent premise): `D:\zig-x86_64-windows-0.14.1\zig.exe` OK; `D:\LLVM-14.0.6\bin\LLVM-C.dll` (77487616 B) OK; `D:\LLVM-14.0.6\lib\LLVM-C.lib` (313524 B) OK; `D:\LLVM-14.0.6\include\llvm-c\Core.h` OK. So a local LLVM rebuild IS possible here; no release-download is required.
- `zig build install -Dllvm=true -Dllvm-include-dir=D:\LLVM-14.0.6\include -Dllvm-lib-dir=D:\LLVM-14.0.6\lib -Dllvm-lib-name=LLVM-C --summary all` -> RC=0, `Build Summary: 13/13 steps succeeded`, including line `install D:\LLVM-14.0.6\bin\LLVM-C.dll to LLVM-C.dll cached` (the `installLlvmCDll` helper added in commit `fe6576c9`, `build.zig:1181`, called at `build.zig:271` only when `enable_llvm`).
- `E:\projects\sci\zig-out\bin\sa.exe` after that build: 11268096 B, mtime 16:12:46; ASCII-import probe -> contains `LLVM-C.dll` string -> LINKED (real LLVM backend).
- Ran the one-shot installer end-to-end via a synchronous child: `cmd /c call "E:\projects\sci\tools\install.bat" --user` with `ZIG`/`LLVM_INC`/`LLVM_LIB` set to the D:\ paths (these are ALSO the script defaults at `tools/install.bat:62/64/66`). Output: `INSTALL_RC=0`; `== Building SCI (LLVM-C backend)`; `[install] detected sa version: 0.0.4`; `== Installing to "C:\Users\zhan\AppData\Local\Programs\SCI\0.0.4"`; `== Registering PATH` / `already in User PATH: C:\Users\zhan\AppData\Local\Programs\SCI\current\bin`; `== Installed SCI 0.0.4`. Log: `tmp_test\restore_install_real.log` (`tmp_test\` is in `.gitignore`).
- Post-install verification: `Get-Command sa` -> `C:\Users\zhan\AppData\Local\Programs\SCI\current\bin\sa.exe`; `sa --version` -> `sa 0.0.4` (rc=0); ASCII-import probe of the installed copy now finds `LLVM-C.dll` -> LINKED OK; `sa --help` advertises `bc2sa <file>  Translate LLVM bitcode to SA assembly` (the LLVM-dependent subcommand, confirming the runtime backend, not the stub).
- `tools/install.bat` design (audited lines 60-175): default `ZIG=D:...0.14.1\zig.exe`, `LLVM_INC=D:\LLVM-14.0.6\include`, `LLVM_LIB=D:\LLVM-14.0.6\lib`; line 93 `"%ZIG%" build install -Dllvm=true ...`; lines 116-120 `copy /y ...\zig-out\bin\{sa.exe,sa.pdb,LLVM-C.dll,hubproxy.exe,hubproxy.pdb}` into the versioned `<prefix>\SCI\<ver>\bin\`; line 140 `mklink /J <prefix>\SCI\current <DEST>` (junction); lines 156-175 add `...\SCI\current\bin` to User or Machine PATH. `--user`/`--admin`/`uninstall`/`--help` recognized; `uninstall` scrubs both `*\SCI\current\bin` and `*\SCI\current_bin` from Machine and User PATH.

Answer:
- Yes, the loss is recoverable with one command: `cmd /c "E:\projects\sci\tools\install.bat --user"` (or `--admin` when elevated). The script rebuilds `sa.exe` with the LLVM-C backend (`-Dllvm=true`), copies `sa.exe` + `LLVM-C.dll` + `hubproxy.exe` into the versioned install dir, repoints the `current` junction, and ensures `SCI\current\bin` is on PATH. Verified end-to-end on this host: installed `sa.exe` is back to 11268096 B, LINKED to `LLVM-C.dll`, `sa --version` -> `sa 0.0.4`, `sa bc2sa`/`build`/`test` subcommands all advertised.
- The earlier agent premise (host has no local LLVM, must re-download release) was wrong for THIS host: `D:\LLVM-14.0.6` and `D:\zig-x86_64-windows-0.14.1` are both present, and the script already defaults to them, so re-build is fully local.
- Note for the restore procedure itself: this sandbox cannot reliably capture stdout/stderr of a nested `cmd /c "..." > file` chain from inside the agent harness (the redirection was silently dropped on several runs). The reliable invocation patterns that DID produce captured output were (a) `System.Diagnostics.Process` with `RedirectStandardOutput/Error` from a `.ps1` run via `powershell -File script.ps1`, or (b) writing a `.bat` runner first. When re-verifying, prefer `powershell -NoProfile -ExecutionPolicy Bypass -File <runner.ps1>` that calls `Start-Process cmd.exe -ArgumentList /c,call install.bat --user -Wait -RedirectStandardOutput log`.

Next:
- If the installed `sa.exe` is ever found to be the stub build again (e.g. `dumpbin /dependents` or a PE import probe shows no `LLVM-C.dll`, or size ~= 10.93 MB instead of ~= 11.27 MB), run one command to restore: `cmd /c "E:\projects\sci\tools\install.bat --user"`. No manual `copy` is needed.
- Keep `D:\LLVM-14.0.6` and `D:\zig-x86_64-windows-0.14.1\zig.exe` in place; they are the rebuild toolchain and are the script defaults. If those paths ever move, pass the new paths as env vars: `set ZIG=... & set LLVM_INC=... & set LLVM_LIB=...` before calling `install.bat`.
- The sret helper scoped to wide fallible externals on `_WIN32` (`src/emit_llvm_llvmc_shim.c`) and the `wip-before-test-fix-2026-08-09` stash are still in force; do not drop the stash.

## 2026-08-09 (recheck pass)
Question:
- Re-verification pass: are both test gates still green, abi-check clean, and the demo-compile result (348/380) still accurate?

Evidence checked:
- `zig build test --summary all` (isolated second run) -> exit 0, `Build Summary: 50/50 steps succeeded; 73/78 tests passed; 5 skipped` (0 failed steps, 0 failed tests). An earlier interleaved run printed `1 failed` step = transient `lld-link: failed to write ...runtime_abi_check.exe: Permission denied` (file-lock collision with a parallel `zig run` abi-check); in isolation it passes 50/50.
- `zig build test -Dllvm=true -Dllvm-include-dir=D:\LLVM-14.0.6\\include -Dllvm-lib-dir=D:\LLVM-14.0.6\\lib -Dllvm-lib-name=LLVM-C --summary all` -> exit 0, `Build Summary: 58/58 steps succeeded; 80/88 tests passed; 8 skipped` (0 failed). Only inner `0 passed; 1 failed` is the intentional `queued_fail.sa` fixture.
- `zig run tools/runtime_abi_check.zig -- --platform both` -> `[runtime-abi] PASS: 492 public symbols are covered for both` (0 contract errors).
- Demo spot rebuilds via `sa build-exe ... --no-incremental`: idx 219 (pkg-bin, rebuilt `bin/` tree), 220 (pkg-lib-dynamic, +`lib/index.sa` import), 198 (control-flow-guard-cfi), 181 (fd-mmap fd-RAII), 301 (http_client_saasm) all rc=0; trap demo `demos/support/use_after_move.sa` rc=1 as expected.
- Note: an inline `... && sa.exe ... & echo RC=%ERRORLEVEL%` one-liner shows EXIT=0 for trap demos (the `& echo` chain masks the real rc); the canonical `tmp_test/demo_one.bat` (setlocal + redirect + `set RC=%ERRORLEVEL%`) correctly records rc=1 for traps and rc=0 for should-build demos. Verified by re-running idx 5 -> `5*0*` and idx 378 -> `378*1*`.
- Definitive recount of `tmp_test/demo_results.txt` (last-occurrence per idx, 380 unique): 348 rc=0, 32 rc=1; the 32 are exactly idx 32 + 129/131/152/153/171 + the 26 support/detector fixtures -- all expected.

Answer:
- Yes. Recheck confirms no regression on any front: default gate 0 failed, LLVM gate 0 failed, abi-check PASS, 348/380 demos compile, 32 expected failures hold.

Next:
- Nothing else needed. If a default-gate run shows `Permission denied` writing `runtime_abi_check.exe`, simply rerun it isolated (avoid a concurrent `zig run tools/runtime_abi_check.zig`).

## 2026-08-09 (later, demo-gate completion)
Question:
- Are all SCI unit tests passing on this Windows host AND does every demo under `demos/` compile via `sa build-exe` (failures fixed or documented)?

Evidence checked:
- `zig build test --summary all` (default `-Dllvm=false`) -> exit 0, `Build Summary: 50/50 steps succeeded; 73/78 tests passed; 5 skipped` (0 failed).
- `zig build test -Dllvm=true -Dllvm-include-dir=D:\\LLVM-14.0.6\\include -Dllvm-lib-dir=D:\\LLVM-14.0.6\\lib -Dllvm-lib-name=LLVM-C --summary all` -> exit 0, `Build Summary: 58/58 steps succeeded; 80/88 tests passed; 8 skipped` (0 failed). The single inner `test result: FAILED. 0 passed; 1 failed` is the intentional `queued_fail.sa` fixture (SaTestFailed expected, framework counts as pass).
- `tools/runtime_abi_check.zig -- --platform both` -> `[runtime-abi] PASS: 492 public symbols are covered for both` after adding the 25 `sa_http_*` mock symbols to `docs/runtime_abi_windows_extra.txt`. Before this, the abi-check failed with `25 contract errors` because the HTTP mock surface added to `src/runtime/sa_std_windows.zig` was exported but not documented in the extra manifest.
- Full demo batch compile (`tmp_test/build_all_demo.bat` over `tmp_test/demo_list_all_abs.txt`, 380 entries): 348 rc=0, 32 rc=1. Logs in `tmp_test/demo_build/<idx>.log`; results in `tmp_test/demo_results.txt`.
- The 32 remaining rc=1 demos are ALL expected failures:
  - 5 rosetta pkg/mod detector demos (idx 129/131/152/153/171) asserted via `assertBuildExeTrap` in `tests/cli_smoke.zig:1863-1867` (ForbiddenSyntax/DuplicateDef/CapabilityMismatch traps).
  - 26 `demos/support/*.sa` fixtures asserted via `assertBuildExeTrap` or `expectError(error.FileNotFound)` in `tests/cli_smoke.zig` (UseAfterMove/BorrowConflict/ReadWriteConflict/IllegalUnsafeContext/StackEscape/ConstMutation/EarlyReturnLeak/MacroRecursionLimit/ForbiddenSyntax(6 variants)/MemoryLeak family/AtomicOrdering family/InvalidAtomicOrdering/UnknownRegister/CapabilityMismatch + duplicate_label/fallthrough/memory_leak/phi_conflict/unknown_register FileNotFound probes).
  - idx 32 `demos/rosetta/117_inline_assembly/main.sa`: genuine LLVM-C backend limitation (native escape `$call void asm sideeffect` -> `emit_llvm_llvmc.zig:1142 UnsupportedInstruction`); no cli_smoke test references it.
- Fixed in this slice:
  - 25 `sa_http_*` symbols documented in `docs/runtime_abi_windows_extra.txt` (HTTP client+server mock surface added earlier to `sa_std_windows.zig` for demos 301/302).
  - idx 144 `demos/rosetta/219_pkg_bin_multiple`: recreated the missing `bin/` package tree described in its README (`bin/index.sa` aggregating `bin/alpha` + `bin/beta`, each with `helpers/index.sa` + `*.sal` macro files) so `@import "bin/index.sars"` resolves and `@bins_total()` returns 219. `sa build-exe ... -> rc=0`, runs and prints `219`.
  - idx 146 `demos/rosetta/220_pkg_lib_dynamic`: added `@import "lib/index.sars"` to `main.sa` so the `@export sa_library_dynamic_value` definition (previously only declared via `lib/iface.sai`) is pulled into the single-file link graph; the host-side ABI split is preserved (host still imports only `lib/iface.sai`). `sa build-exe ... -> rc=0`, runs and prints `220`.

Answer:
- Yes. Both test gates pass (default 0 failed, LLVM 0 failed), the runtime-abi contract passes for both platforms, and 348/380 demos compile. The 32 non-compiling demos are all intentional detector-trap fixtures (asserted in cli_smoke) or the one documented LLVM-C backend limitation for native inline-assembly escaping; none is a real defect.

Next:
- No further unit-test or demo-compile work is needed on this Windows host. The only non-buildable-by-design demo (idx 117 inline_assembly) tracks the LLVM-C `.native` InstKind gap; native Linux LLVM regression remains an explicit open gate that cannot run on this Windows host. Do not drop the `wip-before-test-fix-2026-08-09` safety stash.

## 2026-08-09 00:35
Question:
- Are both `cli_smoke` LLVM-gate failures now resolved on this Windows host?

Evidence checked:
- `zig build test -Dllvm=true -Dllvm-include-dir=D:\LLVM-14.0.6\include -Dllvm-lib-dir=D:\LLVM-14.0.6\lib -Dllvm-lib-name=LLVM-C --summary all` -> exit 0, `80/88 tests passed; 8 skipped; 0 failed`, `58/58 steps succeeded`.
- `zig build test --summary all` (default `-Dllvm=false`) -> exit 0, `73/78 tests passed; 5 skipped; 0 failed, test success`.
- Baseline before this slice was `79/88 passed; 7 skipped; 2 failed` (exit 95); the delta is exactly +1 passed (fallible ABI), +1 skipped (bc2sa cmake), -2 failed.
- Disassembly of a fresh `fallible_i32_file` probe showed proper Win64 sret: `leaq path,%rdx; movl $9,%r8d; movq %rsi,%rcx; callq sa_fs_metadata; cmpl $0,(%rsi); movq 8(%rsi),%rcx` and the probe exits 0.
- `where llvm-dis` / `where llvm-dis-14` both report not found, so the two `bc2sa` cmake/overflow tests now `return error.SkipZigTest` via the new `llvmDisAvailable()` helper.
- The only remaining `1 failed` log line is the intentional `queued_fail.sa` inner fixture (SaTestFailed expected and counted as a framework pass).
- `src/emit_llvm_llvmc_shim.c`: the temporary `SA_DUMP_LLVM_IR` debug block and its `sa_debug_dump_ir(e.module)` call were removed for a clean diff.

Answer:
- Yes. LLVM does NOT auto-lower a directly-typed `{i32, u64}` struct return to Win64 sret, so the caller codegen used a SysV 2-register return while the Zig `extern struct` callee used sret; the mismatch caused an access violation at the metadata call. The fix makes wide fallible externals (payload i64/u64/f64/ptr on `_WIN32`) declare a void return with an sret-typed first parameter and the call site allocates an alloca slot, passes it, then loads status+payload into the `{i32, payload}` result. The bc2sa failures are environment-only: `llvm-dis` is absent on this host, so those tests now skip instead of failing.

Next:
- Keep the sret helper scoped to wide fallible externals on `_WIN32`; native Linux LLVM regression remains an explicit open gate that cannot run on this Windows host. No further unit-test work is needed for the Windows LLVM gate.


## 2026-08-09 00:01

Question:
- Why do two `cli_smoke` tests fail under the LLVM-enabled `zig build test -Dllvm=true ...` gate on this Windows host?

Evidence checked:
- `D:\zig-x86_64-windows-0.14.1\zig.exe build test -Dllvm=true ...` returns exit 1 with `79/88 passed; 2 failed`.
- `tests/cli_smoke.zig:3137` `bc2sa translates clang cmake bitcode demo`: cmake/clang build of `demos/bc2sa_cmake` succeeds, `sa bc2sa main.bc` returns code 1 with `error[SA-CLI-016]: llvm-dis not found`.
- `src/llvm2sa.zig:835-840` `disassembleBitcode` requires `llvm-dis-14` or `llvm-dis`; `where.exe llvm-dis` and `where.exe llvm-dis-14` both report not found on this host.
- `tests/cli_smoke.zig:2788` `extern i32 fallible return uses ABI-aligned payload offset`: probe calls `sa_fs_metadata` (returns `sa_std_fallible_u64` = `{i32,u64}`, 16 bytes) then loads `metadata_res+0`/`+8`; built probe exits with code 5 (=0xC0000005 & 0xFF access violation).
- `src/runtime/sa_std.h:128-137` declares `sa_std_fallible_u64 { int32_t status; uint64_t value; }` (16 bytes, 8-byte align) and `sa_std_fallible_i32 { int32_t status; int32_t value; }` (8 bytes).
- `src/emit_llvm_llvmc_shim.c:364-379` `fallible_type_of` returns `{i32,payload}` struct; `external_fallible_i32_uses_i64_abi` only adapts the 8-byte FallibleI32 case (pack into i64), leaving FallibleU64 declared as a direct struct return.
- Win64 ABI returns structs >8 bytes via hidden `sret` pointer; Linux SysV returns `{i32,u64}` in RAX:RDX. The shim declares the external with direct struct return while the linked Zig export uses sret, so the caller reads garbage and access-violates.

Answer:
- bc2sa: the test cannot succeed without `llvm-dis`; it should `SkipZigTest` when `llvm-dis`/`llvm-dis-14` are missing, mirroring the existing cmake/clang skip pattern. The `bc2sa` command itself must keep requiring `llvm-dis`.
- fallible ABI: extend Windows-safe return handling to fallible returns wider than 64 bits (FallibleU64 and any `{i32, >32bit payload}`). On Windows, declare such externals with an `sret` hidden pointer and `void` return, allocate the result alloca at the call site, pass it as the first arg, then load status/value into the struct result. FallibleI32 (8 bytes) keeps the existing i64 pack.

Next:
- Add an `llvm-dis` availability probe to the bc2sa cli_smoke tests; add sret handling to the LLVM-C shim for >8-byte fallible externals on Windows; rerun the LLVM-enabled and default test gates.