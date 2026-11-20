---
title: "On GitHub's macOS runners the iOS 27 simulator boot, not the build, decides how long the test job takes"
author: Kanonmaten
date: 2026-11-20
branch: main
cost: { minutes: 143, tokens: 377550 }
id: l-4a4cddeb
scope: repo
status: active
src: agent
touches:
  - ".github/workflows/build-unsigned-ipa.yml"
  - CLAUDE.md
  - ".github/workflows/verify-linux.yml"
  - docs/INSTALLATION.md
  - tools/src/gate.rs
  - tools/tests/verification_tools.rs
  - tools/src/project.rs
  - README.md
---

## Decided
The test job in "Bygg Mio IPA" boots the simulator as its very first step and waits with `simctl bootstatus -b` only (no extra `simctl boot`). No build cache in the test job. UI tests and strict concurrency diagnostics run nightly, on v* tags and on manual runs, not on pushes.

## Tried and ruled out
- Booting the simulator after the compile (run #52): the compile dropped to 1 min 40 s, but the same 6+ minute stall moved into the unit test step; the test job went from 9 to 14 min.
- Xcode's compilation cache (COMPILATION_CACHE_ENABLE_CACHING, runs #54–#57) and DerivedData with mtime restore (irgaly/xcode-cache, #58–#59): no steady gain, warm compiles ranged 1 min 53 s to 8 min 42 s.
- A custom GHCR container image for the Linux job: pulling it (56 s) cost more than the apt and rustup steps it saved (~15 s).

## Watch out
- A freshly booted iOS 27 simulator saturates the 3-core runner for 6–15 minutes: checkout took up to 7 min, xcodebuild sat silent up to 6 min 42 s before compiling, and once the runner's own log stalled. Measure step timings from the GitHub log timestamps, and expect large run-to-run variance; one run proves nothing.
- With the simulator settled, the unit test step takes ~1.5 min; the tests themselves ~30 s.
- Swatinem/rust-cache hashes every installed toolchain into its key; ubuntu runner images differ in which stable they ship, so the control job uninstalls all but Rust 1.100.0 or the cache never hits.

In the code: .github/workflows/build-unsigned-ipa.yml (test job), .github/workflows/verify-linux.yml (control job). Measurements in docs/STATUS.md "Snabbare CI, 2026-11-20".
