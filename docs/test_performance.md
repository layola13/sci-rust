# Test Performance Notes

Date: 2026-06-08

This note records the first timed pre-push pass after replacing the fixed `zig build pre-push -j1` hook with `tools/pre_push_timed.sh`.

## What Changed

- `.githooks/pre-push` now runs `tools/pre_push_timed.sh` instead of hard-coding `zig build pre-push -j1`.
- `.git/hooks/pre-push` was updated in the working tree to use the same timed script.
- The timed script defaults to the host CPU count through `nproc`, with overrides:
  - `SA_ZIG_JOBS=<n>` or `ZIG_BUILD_JOBS=<n>` controls Zig worker count.
  - `SA_TEST_JOBS=<n|auto>` controls SA unit-test worker count inside the native unit framework runner.
  - `SA_ZIG_SUMMARY=<mode>` controls Zig summary output, defaulting to `all`.
- The script runs named Zig build stages one by one and prints `[pre-push] START/PASS/FAIL ... elapsed=...` for each stage.
- The script accepts optional stage names, for example `tools/pre_push_timed.sh unit-framework wasm-matrix`.
- The script supports stage profiles through `SA_PRE_PUSH_PROFILE`:
  - `full` is the default de-duplicated gate.
  - `fast` runs the std/runtime/unit-framework/skills/lint subset intended for ordinary compiler-std work.
  - `legacy` preserves the older stage list for timing comparisons.
- `pre-push-aggregate` is available as an explicit stage, but it is not part of the default timed run because it repeats all previous CI dependencies.

## 2026-07-09 Logged Full-Test Dependency Runner

`tools/test_steps_timed.sh` is now the preferred diagnostic command when the goal is to validate the `zig build test` dependency set without losing timeout ownership inside Zig's aggregate build output.

Example commands:

```sh
tools/test_steps_timed.sh --list
tools/test_steps_timed.sh --timeout 420
tools/test_steps_timed.sh --continue --timeout 420
tools/test_steps_timed.sh --timeout 420 --log-dir /tmp/sci-test-steps
tools/test_steps_timed.sh --timeout 180 lib-root-smoke pkg-core-test
```

The runner prints:

- per-step `START` lines with UTC timestamp, timeout, and exact `zig build <step>` command.
- per-step `PASS`, `FAIL`, or `TIMEOUT` lines with elapsed time and status.
- a slowest-step ranking.
- a final `SUMMARY passed=... failed=... timeout=... total=... elapsed=...` line.
- a persisted log directory, defaulting to `logs/test_steps/<utc timestamp>`, containing one numbered log per step plus `summary.log`. Use `--log-dir` or `SA_TEST_STEP_LOG_DIR` to override this path.

The default step list mirrors the `build.zig` `test` dependency set through named build steps. It uses `std-smoke` for the std smoke artifacts and `whitepaper-lint` for the whitepaper smoke artifact, instead of using the aggregate `smoke` step, because `smoke` also repeats the std smoke artifacts.

Focused verification after adding the runner:

```sh
bash -n tools/test_steps_timed.sh
tools/test_steps_timed.sh --list
tools/test_steps_timed.sh --timeout 180 lib-root-smoke pkg-core-test
tools/test_steps_timed.sh --timeout 180 --log-dir /tmp/sci-test-steps-logs pkg-core-test
```

Result: the focused two-step run passed. `lib-root-smoke` took `50.989s`, `pkg-core-test` took `1.419s`, and the runner printed the slowest-step summary. The explicit log-dir check generated `summary.log` and `01-pkg-core-test.log`; an invalid-step failure-path check preserved exit status `1` while writing the Zig error output to the step log. A full logged run was intentionally not executed during this follow-up; use this runner at the next milestone boundary instead of invoking `zig build test` directly.

Milestone full logged pass:

```sh
tools/test_steps_timed.sh --continue --timeout 420 --log-dir logs/test_steps/full-20260709T060333Z
```

Result: `passed=22 failed=0 timeout=0 total=22 elapsed=789.076s`. Full logs were written under `logs/test_steps/full-20260709T060333Z`.

Slowest steps from that pass:

| Step | Elapsed |
| --- | ---: |
| `plugin-host-smoke` | 209.569s |
| `sa-std-runtime` | 145.815s |
| `wasm-matrix` | 121.868s |
| `unit-framework` | 57.407s |
| `std-smoke` | 57.155s |
| `bc2sa-smoke` | 47.792s |
| `workspace-smoke` | 43.340s |
| `trap-baseline` | 41.566s |
| `sa-std-unit` | 27.227s |
| `sa-term-runtime` | 24.427s |

## 2026-07-09 Heavy Step Internal Timing

Two historically expensive steps now emit internal timing, so the step runner can identify both the owning build step and the slow or stuck object inside that step.

`plugin-host-smoke` now prints one START/END pair per Zig test body:

```text
[plugin-host-smoke] START test="plugin installer rejects duplicate extern symbols across installed plugins"
[plugin-host-smoke] END   test="plugin installer rejects duplicate extern symbols across installed plugins" elapsed=30534ms
```

Focused validation:

```sh
tools/test_steps_timed.sh --timeout 420 plugin-host-smoke
```

Result: pass, `230.858s` total. Zig test binary build took about `47s`; the test run took about `3m`. The slowest visible plugin tests were duplicate extern checks and optional dependency skills checks at about `30s` each.

`wasm-matrix` now prints demo and phase timing for `build-exe`, `native-run`, `build-wasm`, and `wasm-run`:

```text
[wasm-matrix] START demo=demos/rosetta/01_hello_world/main.sa phase=build-exe
[wasm-matrix] END   demo=demos/rosetta/01_hello_world/main.sa phase=build-exe elapsed=822ms
```

Focused validation:

```sh
tools/test_steps_timed.sh --timeout 420 wasm-matrix
```

Result: pass, `149.039s` total. Zig test binary build took about `41s`; the matrix run took about `1m`. The visible per-demo output shows most time is in repeated `build-exe` SA compilation, while `native-run`, `build-wasm`, and `wasm-run` are comparatively small for most demos.

## 2026-07-09 Plugin Install Preflight Optimization

The first optimization after the logged-runner milestone targets `plugin-host-smoke`, the slowest owner from the full logged pass.

Change: `src/plugins.zig` now runs pure plugin-install preflight checks before `buildPluginProject()`:

- declared interface file verification.
- declared asset file verification.
- installed extern-symbol conflict checks.

Artifact-dependent checks remain after build/copy:

- dynamic symbol smoke.
- artifact static policy.

This does not remove plugin install coverage. The `plugin-host-smoke` unit tests intentionally exercise install flows, but they set `SA_PLUGINS_HOME` to a `std.testing.tmpDir()`-backed `state` directory, so ordinary unit tests do not install plugins into the real user plugin home.

Focused verification:

```sh
tools/test_steps_timed.sh --timeout 420 --log-dir logs/test_steps/plugin-opt-20260709T070747Z plugin-host-smoke
```

Result: pass, `12/12 tests passed`, `elapsed=170.743s`.

Observed improvement against the prior logged full-pass baseline:

| Step / test body | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `plugin-host-smoke` step | 209.569s | 170.743s | -38.826s / -18.5% |
| duplicate extern symbols across installed plugins | ~33.936s | ~13.809s | ~-20.127s |
| duplicate extern symbols inside installed plugin | ~18.447s | ~0.007s | ~-18.440s |

The optimized run rebuilt the Zig test binary because `src/plugins.zig` changed, so the steady-state runtime saving is likely better represented by the individual test-body deltas than by the total step delta alone.

## 2026-07-09 `sa-std-runtime` Archive Reuse

The next slowest owner from the full logged pass was `sa-std-runtime` at `145.815s`. The test body was repeatedly compiling the same static runtime library for each C demo:

```text
zig build-lib src/runtime/sa_std.zig src/runtime/sa_pthread_host.c -O Debug -lc -femit-bin=libsa_std.a
```

Change:

- `build.zig` makes `sa-std-runtime` depend on the build-system refresh of `artifacts/sa_std/libsa_std.a`.
- `tests/sa_std_runtime.zig` copies that archive into each temp test directory before linking each C demo.
- Each C demo still compiles, links, runs, and validates its output independently. The removed work is only the repeated static runtime library rebuild inside each test case.

Focused verification:

```sh
tools/test_steps_timed.sh --timeout 420 --log-dir logs/test_steps/sa-std-runtime-opt-20260709T073000Z sa-std-runtime
```

Result: pass, `14/14 tests passed`, `elapsed=33.532s`.

Observed improvement:

| Step | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `sa-std-runtime` | 145.815s | 33.532s | -112.283s / -77.0% |

The logged build summary shows the new shape: one `zig build-lib sa_std` archive refresh at about `12s`, one `zig test` build at about `6s`, and the test run at about `7s`, instead of rebuilding the runtime archive per C demo.

## 2026-07-09 Full-Test Log Quality Follow-up

The logged step runner now emits better progress and failure diagnostics for long full-test runs:

- `--heartbeat SEC` / `SA_TEST_STEP_HEARTBEAT`, default `30`, prints `RUNNING` lines while a step is active.
- Heartbeat lines include `index=current/total`, elapsed time, current step log size in bytes, timestamp, and log path.
- `--fail-tail-lines N` / `SA_TEST_STEP_FAIL_TAIL_LINES`, default `80`, prints the tail of failed or timed-out step logs into both the console and `summary.log`.
- Every run writes `results.tsv` with one row per completed step and `environment.txt` with repo/git/settings metadata.
- START/PASS/FAIL/TIMEOUT lines now include `index=current/total`.

Focused verification only:

```sh
bash -n tools/test_steps_timed.sh
tools/test_steps_timed.sh --list
tools/test_steps_timed.sh --heartbeat 1 --timeout 180 --log-dir logs/test_steps/log-quality-pkg-20260709T080000Z pkg-core-test
tools/test_steps_timed.sh --heartbeat 1 --fail-tail-lines 20 --timeout 30 --log-dir logs/test_steps/log-quality-fail-20260709T080000Z definitely-not-a-step
tools/test_steps_timed.sh --heartbeat 5 --timeout 180 --log-dir logs/test_steps/log-quality-heartbeat-20260709T080000Z sa-std-runtime
```

Results: syntax/list checks passed; `pkg-core-test` passed and generated structured logs; the intentional invalid step preserved exit status `1` and printed its failing log tail; `sa-std-runtime` passed and emitted a `RUNNING` heartbeat at 5s. A full suite was intentionally not run for this log-quality slice.

## 2026-07-09 `unit-framework` File-Level Logs

The `unit-framework` step now prints one line before and after each SA unit file it runs:

```text
[unit-framework] START file=tests/unit_framework/std_string_macro_surface.sa mode=in-process jobs=auto
[unit-framework] END   file=tests/unit_framework/std_string_macro_surface.sa mode=in-process elapsed=2095ms jobs=auto stdout_bytes=2686 stderr_bytes=0
```

Queued process-mode files include progress inside the queue:

```text
[unit-framework] START index=1/2 file=.../queued_pass.sa mode=process jobs=1
[unit-framework] END   index=1/2 file=.../queued_pass.sa mode=process elapsed=137ms jobs=1 stdout_bytes=71 stderr_bytes=0
```

Unexpected per-file errors use `END status=error` rather than a bare `[unit-framework] FAIL`. This keeps the intentional queued-worker failure propagation test from making a passing `unit-framework` step look failed in simple log searches.

Focused verification:

```sh
tools/test_steps_timed.sh --heartbeat 10 --timeout 240 --log-dir logs/test_steps/unit-framework-log2-20260709T082000Z unit-framework
rg -n "\\[unit-framework\\] (START|END|FAIL)|status=error|stdout_bytes|stderr_bytes" logs/test_steps/unit-framework-log2-20260709T082000Z/01-unit-framework.log
rg -n "\\[unit-framework\\] FAIL" logs/test_steps/unit-framework-log2-20260709T082000Z/01-unit-framework.log
```

Result: `unit-framework` passed (`5/5 tests passed`). The log contains file-level START/END lines and `stdout_bytes` / `stderr_bytes`; the final grep returned no `[unit-framework] FAIL` matches. A full suite was not run for this logging slice.

Follow-up consistency pass:

- `feature_suite.sa` now logs `START/END file=tests/unit_framework/feature_suite.sa mode=all-modes`.
- `assert_diag.sa` now logs `START/END file=assert_diag.sa mode=negative-diagnostic`.
- `mock_io_test.sa` now logs `START/END file=mock_io_test.sa mode=in-process`.

Focused verification:

```sh
tools/test_steps_timed.sh --heartbeat 10 --timeout 240 --log-dir logs/test_steps/unit-framework-log3-20260709T083000Z unit-framework
rg -n "feature_suite\\.sa all modes elapsed|assert_diag\\.sa elapsed|mock_io_test\\.sa elapsed|\\[unit-framework\\] FAIL" logs/test_steps/unit-framework-log3-20260709T083000Z/01-unit-framework.log
rg -n "START file=tests/unit_framework/feature_suite\\.sa|END   file=tests/unit_framework/feature_suite\\.sa|START file=assert_diag\\.sa|END   file=assert_diag\\.sa|START file=mock_io_test\\.sa|END   file=mock_io_test\\.sars" logs/test_steps/unit-framework-log3-20260709T083000Z/01-unit-framework.log
```

Result: `unit-framework` passed (`5/5 tests passed`). The first grep returned no matches for the old elapsed-only formats or misleading `[unit-framework] FAIL`; the second grep found the new START/END lines.

## 2026-07-09 `wasm-matrix` Slowest Summary

The `wasm-matrix` step now prints an end-of-step summary with aggregate phase totals and top-10 rankings for slow demos and slow phases. This keeps the existing per-demo START/END lines, but avoids manually scanning more than 100 demo records when a run is slow.

Focused verification:

```sh
tools/test_steps_timed.sh --heartbeat 15 --timeout 420 --log-dir logs/test_steps/wasm-matrix-summary2-20260709T084000Z wasm-matrix
rg -n "\\[wasm-matrix\\] SUMMARY|demo_rank=|phase_rank=" logs/test_steps/wasm-matrix-summary2-20260709T084000Z/01-wasm-matrix.log
```

Result: pass, `1/1 tests passed`, `elapsed=146.982s` including Zig test rebuild.

Summary from the successful run:

```text
[wasm-matrix] SUMMARY demos=110 total_demo_ms=103970 build_exe_ms=93156 native_run_ms=502 build_wasm_ms=1711 wasm_run_ms=8188
```

Slowest demos:

| Rank | Demo | Elapsed | build-exe |
| ---: | --- | ---: | ---: |
| 1 | `demos/rosetta/81_kv_store/main.sa` | 2252ms | 2106ms |
| 2 | `demos/rosetta/35_iterator_fold/main.sa` | 2236ms | 2154ms |
| 3 | `demos/rosetta/176_result_flattening/main.sa` | 1780ms | 1680ms |
| 4 | `demos/rosetta/32_trait_object_vector/main.sa` | 1631ms | 1543ms |
| 5 | `demos/rosetta/83_blob_chunk/main.sa` | 1589ms | 1497ms |

The top-10 slowest individual phases were all `build-exe`. Current evidence points at repeated SA native build cost as the next optimization target; wasm execution itself was only `8188ms` across all 110 demos.

## 2026-07-09 `wasm-matrix` WASM-Fast Default

The matrix now matches the WASM-fast product claim more directly:

- all 110 demos still build and run through `build-wasm` plus Node/WASI.
- native `build-exe` is reduced to 6 representative sanity checks by default.
- full native equivalence remains available with `SA_WASM_MATRIX_NATIVE_ALL=1`.
- `build-exe` and `build-wasm` now pass `--project-root <repo-root>`, so matrix builds share the repo `.sa_cache` instead of scattering cache roots across demo directories.

Focused verification only:

```sh
tools/test_steps_timed.sh --heartbeat 15 --timeout 420 --log-dir logs/test_steps/wasm-fast-default-20260709T091500Z wasm-matrix
tools/test_steps_timed.sh --heartbeat 10 --timeout 300 --log-dir logs/test_steps/wasm-fast-hot-20260709T092000Z wasm-matrix
```

Results:

| Run | Step elapsed | native_checked | build-exe | build-wasm | wasm-run |
| --- | ---: | ---: | ---: | ---: | ---: |
| Previous default | 146.982s | 110 | 93.156s | 1.711s | 8.188s |
| Cold shared cache | 212.385s | 6 | 18.404s | 138.154s | 8.577s |
| Hot shared cache | 59.623s | 6 | 6.255s | 43.033s | 7.754s |

The hot-cache default path saves `87.359s` versus the previous logged default (`59.4%`). The cold shared-cache run is intentionally slower because it fills the new shared repo-level `build-wasm` cache for all 110 demos.

## Sample Timings

Command: `tools/pre_push_timed.sh`

Environment: default `jobs=4`, `summary=all`. Most Zig test binaries were already cached, so the heavy timings below are primarily test runtime, SA compilation, import expansion, plugin loading, or demo matrix work rather than Zig compilation.

| Stage | Elapsed |
| --- | ---: |
| `unit-framework` | 284.459s |
| `wasm-matrix` | 179.975s |
| `plugin-host-smoke` | 143.466s |
| `sa-std-runtime` | 82.090s |
| `std-smoke` | 56.934s |
| `smoke` | 48.589s |
| `sa-term-runtime` | 15.920s |
| `sa-net-uring-test` | 7.884s |
| `sa-std-unit` | 7.387s |
| `referee-loc-lint` | 3.097s |
| `native-sys-runtime` | 2.842s |
| `scope-demo` | 2.509s |
| `pkg-core-test` | 0.879s |
| `trap-baseline` | 0.661s |
| `ffi-handle-demo` | 0.369s |
| `hubproxy-test` | 0.137s |

The timed pass was intentionally stopped before the old aggregate rerun completed, because the aggregate stage duplicated the already measured stages. The default script has been corrected so this duplicate work no longer happens.

## Main Bottlenecks

1. `unit-framework` is the largest single gate at about 4m44s.
   - It runs the SA native unit framework suites through a Zig test harness.
   - The output shows repeated `sa_std` and support imports across many SA test files.
   - This is the best candidate for SA test-level caching, per-file timing inside `tests/unit_framework/runner.zig`, and selective/focused unit-framework stages.

2. `wasm-matrix` is about 3m.
   - Zig compilation was cached, but the run step still compiled/verified many demo programs.
   - The output repeatedly resolved `sa_std/io/print.sai`, `core/slice`, `option`, `result`, and several collection imports.
   - This is a strong candidate for persistent SA build artifacts per demo and for matrix sharding.

3. `plugin-host-smoke` is about 2m23s.
   - Zig compilation was cached; the cost is in runtime plugin host behavior.
   - Likely expensive subareas are building temporary plugin shared objects, dynamic loading, command dispatch, hot reload, and failure isolation checks.
   - This should get internal per-test timing before changing behavior.

4. `sa-std-runtime`, `std-smoke`, and `smoke` are all substantial.
   - `std-smoke` and `smoke` both include std smoke run artifacts, so running both as separate timed stages repeats some work.
   - `smoke` depends on `run_std_smoke_core` and `run_std_smoke_containers` in addition to whitepaper lint, so it should not be used as a cheap smoke name in pre-push timing.

## 2026-06-08 Pre-push Profile Follow-up

`build.zig` now exposes a `whitepaper-lint` step that runs only `tests/smoke/whitepaper_lint.zig`. The timed pre-push script uses that step in the default `full` profile instead of `smoke`, because `smoke` also depends on both std smoke run artifacts. This removes a known duplicate `std-smoke` rerun from the default hook while preserving the whitepaper lint check.

Current timed profiles:

| Profile | Purpose | Stages |
| --- | --- | --- |
| `full` | Default pre-push gate without known duplicate std smoke reruns. | Runtime/std/system/plugin/wasm/unit-framework/skills/lint stages. |
| `fast` | Faster local gate for ordinary `sa_std` and CLI skills work. | `trap-baseline`, `std-smoke`, `sa-std-unit`, `sa-std-runtime`, `unit-framework`, `cli-skills-smoke`, `referee-loc-lint`. |
| `legacy` | Old stage list for regression timing comparisons. | Includes both `std-smoke` and `smoke`, so it intentionally repeats std smoke work. |

Example commands:

```sh
tools/pre_push_timed.sh --list
SA_PRE_PUSH_PROFILE=fast tools/pre_push_timed.sh --list
tools/pre_push_timed.sh
SA_PRE_PUSH_PROFILE=fast tools/pre_push_timed.sh
SA_PRE_PUSH_PROFILE=legacy tools/pre_push_timed.sh
tools/pre_push_timed.sh unit-framework cli-skills-smoke
```

Expected immediate saving in `full`: about the old `smoke` duplicate std-smoke cost minus the cheap whitepaper lint-only run. On the initial timing sample this removes roughly one `std_smoke_core` + `std_smoke_containers` rerun from the hook path.

## Immediate Recommendations

- Keep the pre-push hook parallel by default; the previous `-j1` setting made it unnecessarily serial.
- Do not include `pre-push-aggregate` in the timed script default, because it repeats every stage after individual timing.
- Add per-SA-file timings inside `tests/unit_framework/runner.zig` to identify the slowest SA unit files, especially `feature_suite.sa` and the std macro surface suites.
- Add per-demo timings inside `tests/wasm_matrix_smoke.zig` so slow demo builds are visible without parsing import noise.
- Add per-test timing in `tests/plugin_host_smoke.zig` around plugin build/load/reload sections.
- Use `SA_PRE_PUSH_PROFILE=fast` for ordinary std macro changes during local iteration, and keep the default `full` profile for commit/release boundaries.

## 2026-06-08 Unit Framework Follow-up

`tests/unit_framework/runner.zig` no longer hard-codes `sa test --jobs 1` for every SA suite. It now reads `SA_TEST_JOBS`, then `SA_ZIG_JOBS`, then `ZIG_BUILD_JOBS`, and otherwise passes `--jobs auto` to `sa test`. The timed pre-push script exports `SA_TEST_JOBS` from the detected worker count unless the caller overrides it.

Focused verification command:

```sh
SA_TEST_JOBS=auto zig build unit-framework --summary all
```

Result: `4/4 tests passed`, elapsed about `3m` for the run step. This is better than the earlier `unit-framework` sample of about `284s`, but it is still one of the dominant gates.

Visible per-file timings from that pass:

| SA unit group | Elapsed |
| --- | ---: |
| `feature_suite.sa` all modes | 54.683s |
| `std_string_vec_macro_surface.sa` | 31.493s |
| `std_path_macro_surface.sa` | 17.065s |
| `std_net_addr_macro_surface.sa` | 12.757s |
| `std_btree_macro_surface.sa` | 5.119s |
| `std_hashmap_macro_surface.sa` | 4.808s |
| `std_fs_macro_surface.sa` | 4.281s |
| `std_iter_macro_surface.sa` | 4.077s |
| `std_vec_deque_macro_surface.sa` | 3.846s |
| `std_hashset_macro_surface.sa` | 3.726s |

Historical finding: `std_fs_macro_surface.sa` previously could not safely run its internal `@test` cases in parallel. With `--jobs auto`, shared file paths raced across filesystem tests and failed with statuses such as `perm_status=3`, `open_status=3`, and `len_status=3`.

Current status: the filesystem macro tests now use isolated per-test paths and `tests/unit_framework/runner.zig` no longer forces this suite to `--jobs 1`. The 2026-06-09 `zig build unit-framework --summary all` pass ran `std_fs_macro_surface.sa` with `jobs=auto` and completed in about `3.771s`.

The current remaining cost is not Zig compilation. It is mostly repeated SA import expansion, repeated SA test binary compile/link work per file, the very large feature suite being run in three modes, and a few large std macro surface suites. The next meaningful improvements are SA test artifact reuse, splitting giant surface suites into independent build units that Zig can schedule separately, and making filesystem tests use isolated temp paths so they can become parallel-safe.

## Current Policy Suggestion

- For narrow `sa_std` macro changes: run the focused SA test file, `sa-std-static`, `cli-skills-smoke` when skills surface changes, then `SA_PRE_PUSH_PROFILE=fast tools/pre_push_timed.sh`.
- For runtime ABI changes: add `sa-std-runtime` and `sa-std-unit`.
- For CLI/plugin changes: add `plugin-host-smoke` and `cli-skills-smoke`.
- For release or install-before-commit boundaries: run the full timed script once.

## 2026-06-08 Pre-push Timing Follow-up

`tools/pre_push_timed.sh` now defaults to `SA_PRE_PUSH_PROFILE=auto` and prints a slowest-stage ranking at the end of successful or failed runs. The explicit profiles are still available through `SA_PRE_PUSH_PROFILE=full|fast|legacy`.

`auto` inspects changed files against the upstream branch plus the current working tree:

- If the changes are limited to `sa_std/`, `tests/unit_framework/`, docs/progress files, generated skill files, or the pre-push script itself, it resolves to `fast`.
- If the changes include compiler/runtime/build/plugin/wasm/source files, it resolves to `full`.
- If no changed files can be detected, it resolves to `full`.

This keeps ordinary standard-library macro work out of unrelated wasm/plugin/system smoke stages while preserving the full gate for broad compiler or runtime changes. The slowest-stage summary avoids digging through long Zig output after a failed hook run.

The unit framework had one stale expected summary after the owned `CString` test was added: `std_ffi_cstr_macro_surface.sa` now reports 2 tests, and `tests/unit_framework/runner.zig` was updated accordingly. Without that fix, pre-push timing runs failed before reaching the later slow std surface suites.

Focused verification after this change:

```sh
SA_TEST_JOBS=auto zig build unit-framework --summary all
```

Result: `4/4 tests passed`, run step about `3m`. The slowest visible SA files were still `feature_suite.sa` at about `53.7s`, `std_string_vec_macro_surface.sa` at about `30.8s`, `std_path_macro_surface.sa` at about `18.1s`, and `std_net_addr_macro_surface.sa` at about `12.7s`.

Conclusion: hook-level filtering and ranking reduce avoidable local pre-push work and improve diagnostics, but the remaining large win must come from unit-framework sharding or SA test artifact/import reuse. Shell-level changes alone cannot remove the repeated SA compile/import cost inside those large suites.

## 2026-06-09 Unit Framework Duplicate Feature Suite Follow-up

`tests/unit_framework/runner.zig` now keeps the full `feature_suite.sa` matrix in the default mode only and checks `--ignored` / `--include-ignored` with a tiny generated two-test fixture. This preserves coverage for ignored-test CLI behavior without compiling and running the 271-test feature matrix two additional times.

Focused verification command:

```sh
zig build unit-framework --summary all
```

Result: `4/4 tests passed`. The visible runner timing showed `feature_suite.sa all modes` at about `23.204s`, down from the previous roughly `53-65s` samples where the large suite was exercised in three modes.

Current slowest visible SA unit groups from that pass:

| SA unit group | Elapsed |
| --- | ---: |
| `std_string_vec_macro_surface.sa` | 48.007s |
| `std_path_macro_surface.sa` | 24.850s |
| `feature_suite.sa` default matrix plus tiny ignored fixture | 23.204s |
| `std_net_addr_macro_surface.sa` | 14.801s |
| `std_iter_macro_surface.sa` | 11.435s |
| `std_vec_deque_macro_surface.sa` | 8.001s |
| `std_hashset_macro_surface.sa` | 7.220s |

The remaining high-cost work is now concentrated in large std macro surface suites and repeated SA import/test artifact work, not in ignored-mode feature-suite duplication.

## 2026-06-09 String/Vec Surface Split Follow-up

`tests/unit_framework/std_string_vec_macro_surface.sa` has been split into three independent files so file-level unit-framework parallelism can schedule the former single slow group across workers:

- `std_string_macro_surface.sa` covers the 13 string and owned-buffer tests.
- `std_slice_vec_macro_surface.sa` covers the 17 slice and mixed slice/Vec tests.
- `std_vec_macro_surface.sa` covers the 8 Vec-only tests.

Focused verification:

```sh
zig build unit-framework --summary all
```

Result: `4/4 tests passed`. The visible runner timing for the split group was:

| SA unit group | Elapsed |
| --- | ---: |
| `std_string_macro_surface.sa` | 17.973s |
| `std_slice_vec_macro_surface.sa` | 18.279s |
| `std_vec_macro_surface.sa` | 9.780s |

The old `std_string_vec_macro_surface.sa` single scheduling unit was removed from the runner. Total coverage remains 38 tests, but the longest former single unit is now split into smaller file jobs.

## 2026-06-09 Project Cache Follow-up

The project cache now has an explicit cleanup command:

```sh
sa cache clean
sa cache clean --dry-run
sa cache clean --max-age-days 7
```

`sa cache clean` is intentionally project-local. It scans only the current directory's `.sa_cache` and does not touch package mirrors, global package caches, or plugin installation caches. The default policy removes malformed cache keys, incomplete entries, empty artifact/output files, and complete entries older than 30 days. `--max-age-days 0` disables age-based expiry and only removes invalid entries.

Build and test cache hits also validate the cached bitcode/output pair before reuse. If either file is missing or empty, the key directory is deleted and the command recompiles normally. This prevents stale partial writes from surviving indefinitely after interrupted builds or manual cache edits.

Cache entries now include a `manifest.json` beside `artifact.sa.bc` and `output.bin`. The manifest records the cache kind, key, artifact byte size, artifact SHA-256, output byte size, and output SHA-256. Cache hits validate the manifest before copying artifacts back to the requested output path; mismatched or malformed entries are deleted and rebuilt. `sa cache clean` applies the same manifest requirement, so old-format entries, tampered files, and hash/size mismatches are removed during explicit cleanup instead of being kept just because both files are non-empty.

`sa test` now stores no-plugin test compile/link artifacts under `.sa_cache/test`. This does not bypass frontend compilation, because test discovery and filtering still require current metadata, but it skips repeated LLVM emit/link work for repeated compile-only or repeated runs of the same source. Native plugin-linked tests are deliberately excluded from this cache so plugin install/uninstall state remains outside compiler-core cache assumptions.

The process-local flattener import cache also avoids cloning cached std source text on hits. The first resolved std import keeps a page-allocator cache copy; later hits borrow that cached source with `owned_source == null` and only duplicate the small path/identity metadata needed by the caller. Invalidated entries remove stale metadata but keep old source buffers alive for the process lifetime, avoiding dangling borrowed text during concurrent or nested import expansion while reducing allocator churn in repeated std imports.

Routine flattener import tracing is now quiet by default. The previous unconditional `[IMPORT] resolved ...` stderr print can still be enabled with `SAASM_TRACE_IMPORTS=1`, but normal smoke/unit runs no longer pay for or display every resolved import.

Single-worker LLVM emission now backs per-job arenas with the caller allocator instead of always using `std.heap.page_allocator`. Parallel emission deliberately keeps `std.heap.page_allocator`, because the compiler entrypoint allocator is not guaranteed to be thread-safe when several emitter workers allocate concurrently. This trims page allocator churn for common focused builds and tests without changing the safer backing allocator choice for multi-worker emission.

## 2026-06-09 Unit Framework File-Level Parallelism

The macro surface portion of `tests/unit_framework/runner.zig` can now run independent SA files in parallel when `SA_UNIT_FILE_JOBS` is greater than 1. Parallel mode launches the freshly built `sa` binary as a child process for each file instead of calling the in-process CLI from several threads, so compiler globals and process-local import caches are not shared across concurrent SA test files.

The pre-push script now exports `SA_UNIT_FILE_JOBS` from the detected host job count. It no longer forces `SA_TEST_JOBS` by default; when file-level parallelism is active and `SA_TEST_JOBS` is unset, each child `sa test` uses `--jobs 1` to avoid oversubscribing CPUs. Callers can still explicitly set `SA_TEST_JOBS=auto` or a fixed value when they want nested per-file test parallelism.

Focused verification:

```sh
zig build unit-framework --summary all
SA_UNIT_FILE_JOBS=4 zig build unit-framework --summary all
```

The default serial-compatible path still passed with `4/4 tests passed` and about `3m` for the run step. With `SA_UNIT_FILE_JOBS=4`, the same gate passed with `4/4 tests passed`; the macro surface files completed in `54.960s`, and the overall run step completed in about `1m`. The remaining fixed cost is now the large `feature_suite.sa` test plus the Zig test binary itself.

Focused verification:

```sh
zig test -ODebug ... --test-filter "cli cache clean removes invalid project cache entries" --test-filter "sa test compile-only reuses and repairs project test cache"
zig build bc2sa-smoke --summary all
```

Result: both focused cache tests passed, and `bc2sa-smoke` completed with `3/3 tests passed`. The cache smoke now also covers manifest-backed cleanup and test-cache manifest repair. A broader cache-adjacent pass also completed successfully:

```sh
zig build std-smoke unit-framework --summary all
./zig-out/bin/sa cache clean --max-age-days 0
```

`std-smoke` and `unit-framework` passed (`18/18` tests in the combined build summary). The explicit invalid-only cleanup scanned the newly generated project test cache and reported `scanned=41 removed=0 kept=41`, confirming no incomplete or malformed test cache entries remained after the run.
