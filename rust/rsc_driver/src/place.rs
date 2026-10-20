//! rsc_driver::place.
use crate::util::{local_name, trunc};
use rustc_middle::mir::{Body, Place, ProjectionElem};
use rustc_middle::ty::{PseudoCanonicalInput, Ty, TyCtxt, TyKind, TypingEnv};

pub fn place_name(p: &Place<'_>) -> (String, String) {
    let full = trunc(format!("{:?}", p), 80);
    match p.as_local() {
        Some(l) => (local_name(l), full),
        None => {
            // Base-local collapse (documented approximation): every MIR
            // projection reads through its root local. This replaced the old
            // Debug-scraping heuristics (leading `_N`, pure-deref) which
            // missed shapes like double-parenthesized `((_1.0: …))` and fell
            // back to the `_proj` placeholder — an undefined register that
            // can never assemble. Full text stays in `place_via`/comments.
            (local_name(p.local), full)
        }
    }
}

/// Original place text when place_name had to approximate (deref chains,

pub fn place_via(p: &Place<'_>) -> Option<String> {
    match p.as_local() {
        Some(_) => None,
        None => Some(trunc(format!("{:?}", p), 80)),
    }
}

/// Constant byte offset + SA value type for an aggregate field projection
/// (`_1.0`, `(*_2).b`, `_3.0.1`, ...), else `None`.
///
/// `place_name` collapses every projected place to its root local so the
/// backend always names a real register; that loses *which* field is read
/// (`_1.0` and `_1.1` both become `_1`). This resolves the projection against
/// rustc's own layout: `Deref` re-bases onto the pointee (the register already
/// holds the address), `Field` accumulates the field's byte offset. Returns
/// `None` for plain locals, pure-deref places (the pointer value itself, which
/// the collapse already renders correctly) and any layout we cannot resolve —
/// unsupported shapes keep the old collapse and go loud downstream.
pub fn place_proj<'tcx>(
    tcx: TyCtxt<'tcx>,
    body: &Body<'tcx>,
    p: &Place<'tcx>,
) -> Option<(u64, String, String)> {
    if p.projection.is_empty() {
        return None;
    }
    let env = TypingEnv::fully_monomorphized();
    let mut cur: Ty<'tcx> = body.local_decls[p.local].ty;
    let mut off: u64 = 0;
    let mut has_field = false;
    let mut leaf: Ty<'tcx> = cur;
    for elem in p.projection.iter() {
        match elem {
            ProjectionElem::Deref => {
                cur = match cur.kind() {
                    TyKind::Ref(_, t, _) => *t,
                    TyKind::RawPtr(t, _) => *t,
                    _ => return None,
                };
                leaf = cur;
            }
            ProjectionElem::Field(idx, fty) => {
                has_field = true;
                let layout = tcx
                    .layout_of(PseudoCanonicalInput { typing_env: env, value: cur })
                    .ok()?;
                off = off.checked_add(layout.fields.offset(idx.as_usize()).bytes())?;
                cur = fty;
                leaf = fty;
            }
            // Downcast/Index/ConstantIndex/Subslice/OpaqueCast carry no
            // constant byte offset here; leave them to the collapse path.
            _ => return None,
        }
    }
    if !has_field {
        return None;
    }
    let ty = crate::tyinfo::ty_sa_sig_opt(leaf)?;
    if ty == "void" {
        return None;
    }
    Some((off, ty, trunc(format!("{:?}", p), 80)))
}
