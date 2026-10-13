# Mio: instructions for Claude Code

Private SwiftUI app for iOS 26+ (tested on iPhone 16 Pro, still targeting iPhone 13), used and maintained by one person, installed with SideStore. Version 0.9.1 is current and unreleased. This file is in English; everything else in the repo is Swedish.

Before changing something, read the docs that cover it: [README](README.md), [decisions](docs/DECISIONS.md), [status](docs/STATUS.md), the [data model](docs/DATAMODELL.md) for storage, the [gateway](server/README.md) or [Pianissimo](transcription-server/README.md) guide for server work. [`PLAN.md`](PLAN.md) is the 0.9.0 reliability plan; never edit it.

## Rules that must hold

- Names: project, target, scheme and module are `Mio`, tests `MioTests`/`MioUITests`. App ID `app.mio.assistant` (widgets `.widgets`). Names never contain versions or person names.
- Storage: SwiftData `Mio/store/Mio.store`; schema changes go through `VersionedSchema` and the migration plan. Never overwrite a stored document whose schema is unknown. Export stays versioned JSON.
- Privacy: never store raw audio (RAM only, at most 60 s). Corrections and speaker names are a display layer; the original transcript and timings never change. Never commit exports, recordings, pairing data, certificates or keys, and never paste secrets into chat.
- Transcription: Pianissimo on the user's CachyOS GPU, reached over Tailscale HTTPS. No Apple, CPU or cloud fallback. The microphone restarts itself after interruptions but never after the user's pause or stop.
- AI: a Node gateway on the same PC (`server/`), Groq `qwen/qwen3.8-27b` only, keep the provider seam. Every call has reasoning off, temperature 0 and strict JSON schema, with no silent model or parameter fallback; validate every response. AI is on once paired. Suggestions need an explicit Yes. Everyday text is batched at most every 5 minutes, and unsent text from the last 12 h is caught up on start. A locked Keychain must never turn AI off.
- UI: native navigation, semantic colors, Dynamic Type. Liquid Glass only on controls; reading surfaces stay plain.
- Not in 0.9.0: chat history, streaming, model tools, autonomous actions, TTS, embeddings, model picker, automatic failover.

## Working rules

- Check official docs (Apple first for iOS) before a significant technical decision, and record the choice and the rejected options in `docs/DECISIONS.md`. Mark anything that depends on the phone as unverified until tested.
- Keep changes scoped and leave unrelated changes alone. Don't reorganize Swift code for looks.
- Swedish for UI text and docs, English for identifiers and code comments. Comment the non-obvious privacy, timing and concurrency rules.
- Update `CHANGELOG.md` for user-visible changes. Edit `docs/STATUS.md` only with checks you actually ran. Never touch the measurements in `docs/TESTRESULTAT_V0_1.md`.
- Git: commit finished, verified work and push to `main` without asking. No branches or pull requests, even if the session assigns one; never force-push. Tags, running the IPA workflow, real model traffic and anything on Cloudflare (the old Worker, D1 and Access are still deployed) need the user's approval.
- Ask when a decision is the user's to make.

## Verifying

Linux can't build the iOS app. On the user's PC (Node 26, `swiftc`, `uv`) run the full gate; in a cloud session run what the toolchain allows:

```sh
python3 scripts/verify.py                  # everything below plus Swift XCTest and concurrency
python3 scripts/verify_swift_core.py       # portable Swift XCTest only
cd server && npm ci --ignore-scripts && npm test
cd transcription-server && uv sync --locked --extra test --python 3.12 && uv run pytest tests
python3 scripts/verify_project.py && python3 -m unittest discover -s scripts/tests
```

GitHub runs "Verifiera Mio på Linux" on every push; check it for the exact commit. "Bygg Mio IPA" (manual) builds the iOS app, runs simulator tests and makes the unsigned IPA; it is the only check of iOS-only code such as Keychain, UIKit and SwiftUI views.

When you hand over, say what changed, what was tested on which commit, and what to test on the phone. Never call a revision built, installed or phone-tested without proof for that exact revision.
