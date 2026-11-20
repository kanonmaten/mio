# Mio: instructions for Claude Code

Private SwiftUI app for iOS 27+ (tested on iPhone 16 Pro, still targeting iPhone 13), used and maintained by one person, installed with SideStore. Version 0.9.1 is current and unreleased. This file is in English; everything else in the repo is Swedish.

Before changing something, read the docs that cover it: [README](README.md), [decisions](docs/DECISIONS.md), [status](docs/STATUS.md), the [data model](docs/DATAMODELL.md) for storage, the [gateway](server/README.md) or [Pianissimo](transcription-server/README.md) guide for server work. [`PLAN.md`](PLAN.md) is the 0.9.0 reliability plan; never edit it. The next work is [`docs/PLAN_GRILLNING.md`](docs/PLAN_GRILLNING.md) (the user's decisions from 2026-11-19, not started): take it before other new work, phase by phase, and tick its checkboxes as you go. Exception (user's decision 2026-11-20): the faster-CI plan (`PLAN_SNABBARE_CI_v2.md`, kept outside the repo) may run before it when the user starts it.

## Rules that must hold

- Names: project, target, scheme and module are `Mio`, tests `MioTests`/`MioUITests`. App ID `app.mio.assistant` (widgets `.widgets`). Names never contain versions or person names.
- Storage: SwiftData `Mio/store/Mio.store`; schema changes go through `VersionedSchema` and the migration plan. Never overwrite a stored document whose schema is unknown. Export stays versioned JSON.
- Privacy: never store raw audio (RAM only, at most 60 s). Corrections and speaker names are a display layer; the original transcript and timings never change. Never commit exports, recordings, pairing data, certificates or keys, and never paste secrets into chat.
- Transcription: Pianissimo on the user's CachyOS GPU, reached over Tailscale HTTPS. No Apple, CPU or cloud fallback. The user's own words (phrase boosting) live in a file on the PC and never leave it; a failing word list must never block transcription. The microphone restarts itself after interruptions but never after the user's pause or stop.
- AI: a Rust gateway on the same PC (`server/`, one binary, moved from Node 2026-11-16 with recorded parity tests), only provider and model pairs reviewed in `server/src/model_profiles.rs` run, one active pair per task (`ask`, `everyday`, `lesson`), chosen on the PC in Mio Kontroll (`control/`); Groq `qwen/qwen3.8-27b` is what `server/install.sh` sets up (rule changed with the user's approval 2026-11-17). Every call has reasoning off and strict JSON schema, and temperature 0 unless the reviewed model is marked as refusing the parameter (then it is left out and `/v2/status` says so), with no silent model or parameter fallback; validate every response. A candidate pair is never selectable until the user approves a synthetic test call. The gateway sizes `max_tokens` to the provider's per-minute token budget and may retry the identical request once; an invalid item in an answer is dropped or repaired from the source, never passed on. A refused or failed batch is never resent unchanged in a loop: the app shrinks it, skips it or backs off. AI is on once paired. Suggestions need an explicit Yes. Everyday text is batched at most every 5 minutes, and unsent text from the last 12 h is caught up on start. A locked Keychain must never turn AI off.
- UI: native navigation, semantic colors, Dynamic Type. Graphite ground, one blue tint, never violet. Liquid Glass on controls and on summary/status cards; text read at length (transcripts, notes, list rows) stays on plain surfaces. All settings live in the one settings sheet; other screens show at most a status chip that opens it, plus the one-tap AI pause on Fånga (user's choice 2026-11-16). See DESIGN.md.
- Not in 0.9.0: chat history, streaming, model tools, autonomous actions, TTS, embeddings, a model picker in the iPhone app (it lives only in Mio Kontroll on the PC), automatic failover.

## Working rules

- Check official docs (Apple first for iOS) before a significant technical decision, and record the choice and the rejected options in `docs/DECISIONS.md`. Mark anything that depends on the phone as unverified until tested.
- Keep changes scoped and leave unrelated changes alone. Don't reorganize Swift code for looks.
- Swedish for UI text and docs, English for identifiers and code comments. Comment the non-obvious privacy, timing and concurrency rules.
- Update `CHANGELOG.md` for user-visible changes. Edit `docs/STATUS.md` only with checks you actually ran. Never touch the measurements in `docs/TESTRESULTAT_V0_1.md`.
- Git: commit finished, verified work and push to `main` without asking. No branches or pull requests, even if the session assigns one; never force-push. Run "Bygg Mio IPA" whenever it helps, without asking (user's decision 2026-11-20). Tags, real model traffic and anything on Cloudflare (the old Worker, D1 and Access are still deployed) need the user's approval.
- Ask when a decision is the user's to make.
- Reminder (user's request 2026-11-16, updated 2026-11-17): the GPUI control app for the PC, Mio Kontroll in `control/`, is built but not tested on the PC. At the start of work on Mio, remind the user in one line of the PC test list in `control/README.md#prov-på-datorn`. Keep doing so until the user reports it done or drops it.
- Reminder (user's request 2026-11-19): at the start of work on Mio, also remind the user in one line that the next step is [`docs/PLAN_GRILLNING.md`](docs/PLAN_GRILLNING.md) and which phase is next (the first with unticked boxes). Keep doing so until every phase is ticked or the user drops it.

## Verifying

Linux can't build the iOS app. On the user's PC (Rust 1.92+ since the gate builds `control/`, `swiftc`, `uv`) run the full gate; in a cloud session run what the toolchain allows:

```sh
cargo run --locked --manifest-path tools/Cargo.toml -- verify       # everything below plus Swift XCTest and concurrency
cargo run --locked --manifest-path tools/Cargo.toml -- swift-core   # portable Swift XCTest only
cargo run --locked --manifest-path tools/Cargo.toml -- project      # structure checks only
cd tools && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings
cd server && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings
cd transcription-server && uv sync --locked --extra test --python 3.12 && uv run pytest tests
```

While working, run only the checks for what the change touches; run the full `verify` before pushing:

| Changed | Run |
|---|---|
| Swift logic (`Mio/` portable code) | `cargo run --locked --manifest-path tools/Cargo.toml -- swift-core` |
| Project structure, plists, file layout | `cargo run --locked --manifest-path tools/Cargo.toml -- project` |
| `tools/` | `cd tools && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings` |
| `server/` | `cd server && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings` |
| `control/` | `cargo clippy --locked --manifest-path control/Cargo.toml --workspace --all-targets -- -D warnings` and `cargo test --locked --manifest-path control/Cargo.toml --workspace` |
| `transcription-server/` | `cd transcription-server && uv sync --locked --extra test --python 3.12 && uv run pytest tests` |

The verifier (`tools/`, binary `mio-verify`) is Rust since 2026-11-17. Pianissimo and its tests stay Python (NeMo). Keep the verifier's Swedish messages unchanged: CI logs and `docs/STATUS.md` quote them. Its Swift rewrites must stay byte-identical to what they replace; the substituted Swift lives in `tools/swift/`.

GitHub runs "Verifiera Mio på Linux" on every push; check it for the exact commit. "Bygg Mio IPA" (manual) builds the iOS app, runs simulator tests and makes the unsigned IPA; it is the only check of iOS-only code such as Keychain, UIKit and SwiftUI views.

When you hand over, say what changed, what was tested on which commit, and what to test on the phone. Never call a revision built, installed or phone-tested without proof for that exact revision.
