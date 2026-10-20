//! rsc_driver: real rustc_private driver — `.rs -> MIR -> mir.json`.
//!
//! Official compiler does 100% checking (parse/resolve/hir/typeck/borrowck);
//! we only hijack the resulting MIR in `after_analysis` and dump the stable
//! mir.json subset consumed by `mir2sa lower`. No codegen runs
//! (`Compilation::Stop`). If borrowck/typeck reported errors, no mir.json is
//! written (zero-error backend input, guaranteed).
//!
//! Build (needs nightly + rustc-dev, both present):
//!   ./build.sh
//! Run (direct, mir.json only):
//!   ./target/rsc_driver --edition 2021 /tmp/rsc_demo/src/main.rs \
//!       --rsc-out /tmp/driver.mir.json --crate-type bin
//! Run (cargo workspace capture, real artifacts too):
//!   RUSTC_WORKSPACE_WRAPPER=./target/rsc_driver RSC_OUT_DIR=/tmp/mir \
//!       cargo build            # writes /tmp/mir/<crate>.mir.json per crate

#![feature(rustc_private)]

extern crate rustc_driver;
extern crate rustc_hir;
extern crate rustc_interface;
extern crate rustc_middle;
extern crate rustc_ast;
extern crate rustc_abi;
extern crate rustc_span;

use rustc_driver::{Callbacks, Compilation, compiler_entrypoint};
use rustc_hir::def::DefKind;
use rustc_interface::interface::Compiler;
use rustc_middle::ty::TyCtxt;

use crate::emit::body_json;

struct RscCallbacks {
    out: String,
    /// True when running as a cargo `RUSTC_WORKSPACE_WRAPPER`: after dumping
    /// the MIR we must let rustc finish codegen so cargo still gets its
    /// rlib/bin. Direct invocations stop after the dump (mir.json only).
    continue_compilation: bool,
}

mod emit;
mod place;
mod tyinfo;
mod util;

impl Callbacks for RscCallbacks {
    fn after_analysis<'tcx>(&mut self, _compiler: &Compiler, tcx: TyCtxt<'tcx>) -> Compilation {
        if tcx.dcx().err_count() > 0 {
            eprintln!("rsc_driver: analysis had errors; refusing to emit mir.json");
            if self.continue_compilation {
                return Compilation::Continue;
            }
            std::process::exit(1);
        }
        let mut out = String::from("{\"source\": \"rsc_driver (rustc_private, real MIR)\", \"functions\": [");
        let mut first = true;
        for owner in tcx.hir_body_owners() {
            let did = owner.to_def_id();
            // `optimized_mir` panics on constants ("do not use optimized_mir
            // for constants"): route consts/statics through `mir_for_ctfe`,
            // skip bodies with no MIR at all.
            let body = match tcx.def_kind(did) {
                DefKind::Const | DefKind::AssocConst | DefKind::AnonConst | DefKind::Static { .. } => {
                    tcx.mir_for_ctfe(did)
                }
                DefKind::GlobalAsm => continue,
                _ => tcx.optimized_mir(did),
            };
            let path = tcx.def_path_str(did);
            let short = path.rsplit("::").next().unwrap_or(&path);
            if !first {
                out.push_str(", ");
            }
            first = false;
            body_json(tcx, tcx.param_env(did), short, body, &mut out);
        }
        out.push_str("]}");
        let approx = out.matches("RuntimeChecks-unsupported").count();
        if let Err(e) = std::fs::write(&self.out, &out) {
            eprintln!("rsc_driver: write {}: {}", self.out, e);
            std::process::exit(1);
        }
        eprintln!("rsc_driver: wrote {} APPROX={}", self.out, approx);
        if self.continue_compilation {
            Compilation::Continue
        } else {
            Compilation::Stop
        }
    }
}

/// Value of `--flag <value>` in a rustc argument vector, if present.
fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn main() {
    let raw: Vec<String> = std::env::args().collect();
    // Wrapper mode (cargo `RUSTC_WORKSPACE_WRAPPER`): cargo invokes
    // `<wrapper> <real rustc> <rustc args...>`. RSC_OUT_DIR selects the
    // per-crate mir.json directory, so argv[1] is the real rustc and must
    // become the driver's argv0 (compiler_entrypoint takes a rustc argv).
    let wrapper_mode = std::env::var_os("RSC_OUT_DIR").is_some();
    let mut rustc_args: Vec<String> = Vec::new();
    let mut i = 1;
    if wrapper_mode && raw.len() > 1 {
        rustc_args.push(raw[1].clone());
        i = 2;
    } else {
        rustc_args.push(raw.get(0).cloned().unwrap_or_else(|| "rsc_driver".to_string()));
    }
    let mut out: Option<String> = None;
    while i < raw.len() {
        if raw[i] == "--rsc-out" {
            i += 1;
            if let Some(v) = raw.get(i) {
                out = Some(v.clone());
            }
        } else {
            rustc_args.push(raw[i].clone());
        }
        i += 1;
    }
    let out = match out {
        Some(o) => o,
        None if wrapper_mode => {
            let dir = std::env::var("RSC_OUT_DIR").unwrap_or_else(|_| ".".to_string());
            let crate_name =
                arg_value(&rustc_args, "--crate-name").unwrap_or_else(|| "crate".to_string());
            format!("{}/{}.mir.json", dir.trim_end_matches('/'), crate_name)
        }
        None => "out.mir.json".to_string(),
    };
    let mut cb = RscCallbacks { out, continue_compilation: wrapper_mode };
    compiler_entrypoint(&rustc_args, &mut cb);
}
