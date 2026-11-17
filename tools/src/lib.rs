//! Mio's verification tooling: the Linux gate and the portable Swift harnesses it runs.
//!
//! Ported from the Python scripts in `scripts/` on 2026-11-17 (see docs/DECISIONS.md); the
//! messages stay as they were because CI logs and docs/STATUS.md quote them.

pub mod capture;
pub mod cli;
pub mod concurrency;
pub mod gate;
pub mod project;
pub mod session_store;
pub mod swift_core;
pub mod util;
