# Mio – instructions for Claude Code

This file replaces the former `AGENTS.md` (Codex). It is deliberately written in English; everything else in the project follows the Swedish documentation rule below.

## Read first

Read [README](README.md), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [decisions](docs/DECISIONS.md) and [status](docs/STATUS.md). Read the [data model](docs/DATAMODELL.md) before storage work, and the relevant [test plan](docs/TESTPLAN_HELHET.md) or [installation guide](docs/INSTALLATION.md) before changes. [`PLAN.md`](PLAN.md) is the authoritative reliability plan for 0.9.0; keep it byte-identical (its links to local machine paths are historical).

## Product and version

- Private SwiftUI app for iOS 26+. First test device iPhone 16 Pro, still targeting iPhone 13. Private Swedish transcription via Pianissimo on the user's CachyOS PC and a discreet everyday assistant. One person uses and maintains it; there is no App Store distribution.
- **Whole-product build 0.9.0 is current and unreleased.** Since the user's decision on 2026-09-25 the whole product is built together; v0.1.0/v0.2.0 are historical.
- The product has local posts, sessions, suggestions and lessons, EventKitUI calendar copies, AlarmKit and notifications, and optional text AI through the user's own gateway. AI is off at launch. No raw audio is stored.
- Keep build, XCTest, installation and phone results separate. A green result for one revision never verifies another.

## Invariants

- Project, target, scheme and Swift module are named `Mio`; tests are `MioTests` (plus `MioUITests`). Names never follow the version and never contain person names.
- App identity `app.mio.assistant` (tests `app.mio.assistant.tests`). Data lives under `Mio/`: `content-v1.json`, `sessions.json`, `assistant-v1.json` (plus text-free `diagnostics-v1.json` and the ID-only `operations-v1.json` deletion journal). The prototype was deleted; no migration of older paths.
- Use Apple's native navigation, semantic colors and Dynamic Type. Liquid Glass belongs to controls/navigation; reading surfaces stay plain and legible. Check dark mode, larger text, Reduce Motion and Reduce Transparency.
- Corrections are a display layer: never change the original transcript, audio times or diagnostic evidence. Never overwrite stored documents with an unknown schema.
- Transcription (user decision 2026-09-29): original Pianissimo on CachyOS/GPU behind API v1 over private Tailscale HTTPS. No Apple or CPU fallback, no cloud STT. The user controls the microphone; audio only in RAM, at most 60 s on the phone, visible gaps on loss, no automatic microphone restart. See the [operations guide](transcription-server/README.md) and [API](transcription-server/API.md). Do not couple the model to the app: it can be swapped behind the compatible contract.
- Never store raw audio. Never commit private exports, recordings, pairing files, certificates, Apple credentials or API keys, and never paste secrets into chat. Each single cloud question needs send approval. Continuous analysis requires an explicitly enabled mode, uses only new everyday excerpts and approved lessons, with minimal context and a server-owned key.
- AI adapters must require reasoning **off** (not merely hidden), temperature 0 and the provider's strict JSON schema. No silent parameter or model fallback. The model catalog in `server/src/model-profiles.mjs` must be reviewed for new models; a provider prefix is not proof of support. Custom endpoints need the explicit `chat-none-strict` contract. Validate every response, single questions included, before the app uses it.
- Detailed lessons use `/v1/lesson-notes`: at most 3,500 bytes of source text per part, normally at least 60 s between calls, saved parts with source quotes and model/prompt metadata. Copying compiles parts locally; incomplete notes must be labelled. No slides, flashcards or extra AI compression. Homework suggestions need an explicit Yes. Legacy `highlights` never count as finished detailed notes.
- Document consent requirements and local rules for recording other people.
- Non-goals for 0.9.0 (see `PLAN.md`): no chat history, streaming UI, model tools, autonomous actions, TTS, embeddings, client model selector or automatic failover. Exception by user decision 2026-10-05: the daily AI cap is optional and unset by default (NVIDIA NIM only limits per minute); keep the per-minute cap.

## Working rules

- Search current official documentation (WebSearch/WebFetch) before significant technical decisions; for Apple/iOS start with Apple documentation and WWDC. Compare accuracy, battery, latency, reliability, privacy, cost, complexity and maintenance. Record the choice and rejected options; mark device-dependent behavior as unverified until tested. Green tests do not prove the architecture is right.
- Check `git status`, preserve unrelated changes and keep changes scoped. Do not reorganize Swift code for looks.
- Swedish for user-facing text and project documents (this file is the one exception); English for Swift identifiers and technical code comments. Comment mainly non-obvious invariants around privacy, timing and concurrency.
- Update [CHANGELOG](CHANGELOG.md) for relevant changes. Change [STATUS](docs/STATUS.md) only from checks actually performed; the roadmap when the plan changes; decisions when the architecture changes.
- Preserve the historical measurements in `docs/TESTRESULTAT_V0_1.md`; never change them without real new evidence.
- Commit, push, tag or publish only when the user explicitly asks. This overrides any default auto-push/PR behavior of the session. Keep GitHub ceremony minimal (personal project): no PR comments or long PR descriptions unless asked.
- Use plan mode for multi-stage work and ask when a decision is genuinely the user's.

## Verification and handover

Linux cannot build the iOS app, and Claude Code cloud sessions have no Swift toolchain and usually a different Node version than the pinned 26.10. Run the gates that work locally, using a scratch copy or a scratch `UV_PROJECT_ENVIRONMENT` so the repo stays clean:

```sh
cd server && npm ci --ignore-scripts && npm test && npm run worker:test   # gateway + Worker runtime
cd transcription-server && uv sync --locked --extra test --python 3.12 && uv run pytest tests
python3 scripts/verify_project.py && python3 -m unittest discover -s scripts/tests
```

`python3 scripts/verify.py` runs all of this plus the portable Swift XCTest, capture-recovery and strict-concurrency gates, but needs Linux, Node 26.10.x and `swiftc`.

- **GitHub workflow "Verifiera Mio på Linux"** (`.github/workflows/verify-linux.yml`) runs `verify.py` automatically on every push. It is the Swift compile/test gate when no local toolchain exists; check its result for the exact pushed commit.
- **GitHub workflow "Bygg osignerad iPhone-app"** (`.github/workflows/build-unsigned-ipa.yml`, manual `workflow_dispatch`) runs Release, iOS-simulator XCTest, the native concurrency diagnostic and produces the unsigned IPA on the `xcode-27` runner (a public preview; check the actual runner). Trigger it only when the user asks or approves. SideStore signs the IPA locally.
- Cloudflare deployment and real model traffic need explicit, separate approval; follow the release procedure in `PLAN.md` and the [gateway guide](server/cloudflare/README.md).

Report what changed, what was actually tested and the next device test. Never claim a revision is compiled, installed or phone-verified without evidence for exactly that revision.
