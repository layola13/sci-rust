#!/usr/bin/env bash
# Cargo workspace -> .sars end-to-end (full-Cargo slice of the sci-rust goal).
#
# Pipeline: real rustc drives the workspace; rsc_driver runs as
# RUSTC_WORKSPACE_WRAPPER, dumps one mir.json per workspace crate, and still
# lets rustc finish codegen so cargo gets its artifacts. mir2sars then lowers
# the crates in dependency order, turning cross-crate callees into
# `@import`, and `sars check`/`sars run` execute the app with no broker.
#
# Needs: nightly rustup toolchain with the rustc-dev component, plus a built
# zig-out/bin/sars and rust/target/debug/mir2sars.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="$ROOT/rust/cargo_demo"
OUT="$DEMO/sars_out"

export PATH="$HOME/.cargo/bin:$PATH"
# The driver is built against the nightly that ships rustc-dev; make cargo use
# the same toolchain so the wrapper's rustc_private ABI matches.
export RUSTUP_TOOLCHAIN=nightly

echo "[1/5] building rsc_driver"
( cd "$ROOT/rust/rsc_driver" && ./build.sh >/dev/null )
DRIVER="$ROOT/rust/rsc_driver/target/rsc_driver"

echo "[2/5] building mir2sars"
cargo build --manifest-path "$ROOT/rust/Cargo.toml" --quiet
MIR2SARS="$ROOT/rust/target/debug/mir2sars"
SARS="$ROOT/zig-out/bin/sars"

echo "[3/5] cargo build with MIR capture"
mkdir -p "$OUT"
rm -f "$OUT"/*.mir.json "$OUT"/*.sars
# Force a rebuild so the wrapper is actually invoked for every crate.
find "$DEMO" -name '*.rs' -exec touch {} +
(
  cd "$DEMO"
  RUSTC_WORKSPACE_WRAPPER="$DRIVER" RSC_OUT_DIR="$OUT" cargo build --quiet
)

echo "[4/5] mir2sars lower (dependency order)"
"$MIR2SARS" lower "$OUT/macros_lib.mir.json" --out "$OUT/macros_lib.sars"
"$MIR2SARS" lower "$OUT/macros_app.mir.json" --out "$OUT/macros_app.sars" \
  --dep "$OUT/macros_lib.mir.json=macros_lib.sars"

echo "[5/5] sars check + run"
"$SARS" check --edition rust --project-root "$ROOT" "$OUT/macros_app.sars"
"$SARS" run --edition rust --project-root "$ROOT" "$OUT/macros_app.sars"

echo "cargo workspace -> sars: OK"
