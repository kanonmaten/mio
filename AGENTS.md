# Mio – project guidance for Codex

This file is the durable starting point for every Codex task in this repository.

## Read first

Before changing code or documentation, read:

1. `README.md`
2. `docs/PRODUKTVISION.md`
3. `docs/ROADMAP.md`
4. `docs/DECISIONS.md`
5. the relevant test or installation document for the task

For phase 2 work, also read `docs/DATAMODELL_FAS_2.md`, `docs/KRAVMATRIS_FAS_2.md` and `docs/TESTPLAN_FAS_2.md`.

## Product and current phase

- Mio is a private personal iPhone app for one user; App Store distribution is not planned.
- The long-term product is a discreet daily companion for local transcription, notes, plans, explicit memories and summaries. It is not intended to be a general ChatGPT-style tutor.
- The wake word is the standalone word `Mio`.
- Phase 1 is a feasibility test on an iPhone 13 running iOS 26. Its short smoke test passed, but long background, battery, interruption and quality tests remain; phase 1 is not closed.
- Phase 2 is implemented in the working copy as a local, manual MVP. This does not waive any remaining phase 1 device test.
- The phase 2 working copy has not yet been compiled with Xcode, built in GitHub Actions or verified on the iPhone. Keep implementation, build and device status separate in every report.
- Phase 2 intentionally contains no OpenAI calls, account system, EventKit integration, system alarm integration or saved raw audio.
- `SpeechAnalyzer` is the shared analysis engine. Mio feeds it timed audio buffers and configures one transcription module at a time: `SpeechTranscriber` when its Swedish asset is installed, otherwise `DictationTranscriber` as fallback. `AssetInventory` manages module assets; it is not a separate analyzer model.
- The real device selected `DictationTranscriber` with `sv_SE`. The newer Swedish `SpeechTranscriber` asset could not be installed in the first test.
- Phase 2 improves `SpeechTranscriber` asset handling with `AssetInventory` status, explicit Swedish reservation, a separate install action and final installed-state verification. Session start does not initiate that download: if the asset is not already installed, use `DictationTranscriber` immediately. Treat this as unverified until a new device test.
- Active project, source, test, target, scheme and product names use `MioPhaseTwo`. The main bundle identifier intentionally remains `se.eyvin.MioPhaseOne` for in-place upgrades.
- Phase 2 stores content in versioned `MioPhaseTwo/content-v1.json` and sessions in `MioPhaseTwo/sessions.json`. If the new sessions file is absent, a legacy `MioPhaseOne/sessions.json` is migrated on first read. Session corrections are overlays: original transcript text, audio timing and evidence fields must remain intact.
- See `docs/TESTRESULTAT_FAS_1.md` for the historical phone result and `docs/TESTRESULTAT_FAS_2.md` for current phase 2 verification status.

## Non-negotiable privacy rules

- Never commit exported sessions, transcripts, recordings, pairing files, certificates, provisioning profiles, Apple credentials or API keys.
- Raw microphone audio may be processed transiently in memory but must not be written to an audio file unless the user explicitly changes this product decision.
- Future OpenAI requests may contain only an explicitly approved question and the minimum necessary context. Never place an OpenAI API key in the iOS app.
- Treat school, workplace and bystander audio as sensitive. Documentation must require consent and compliance with local rules.

## Engineering rules

- Preserve the user's unrelated changes and inspect `git status` before editing.
- Prefer small, reviewable changes. Do not reorganize Swift files merely for appearance.
- Keep straightforward code self-explanatory. Add comments only for lifecycle, timing, concurrency, privacy or other non-obvious invariants.
- User-facing copy and project documentation are Swedish. Swift identifiers and technical code comments are English.
- Do not commit or push unless the user explicitly asks for it.
- Do not mark a device requirement as verified without evidence from an exported session or a clearly reported manual test.

## Build and verification

- The local Windows environment cannot compile this iOS 26 project.
- `.github/workflows/build-unsigned-ipa.yml` keeps Xcode 26.6 as the authoritative stable build, test and IPA environment. Its separate `xcode-27` public-preview job is non-blocking, creates no IPA and is only an early compatibility signal.
- GitHub Actions produces an unsigned IPA. SideStore signs and installs it with the user's Apple Account.
- Run all safe static checks available on Windows. State clearly which checks still require GitHub Actions or the physical iPhone.
- Do not describe a new revision as compiled, Actions-built, installed or phone-verified without evidence for that exact revision.
- When phase 2 behavior or status changes, update `docs/BYGGSTATUS.md`, `docs/ROADMAP.md`, `docs/KRAVMATRIS_FAS_2.md` and `docs/TESTRESULTAT_FAS_2.md` as applicable.
- Update `docs/KRAVMATRIS_FAS_1.md` or `docs/TESTRESULTAT_FAS_1.md` only when phase 1 behavior changes or a real new phase 1 test result exists. Preserve the 2026-08-20 observations as historical evidence.

## Working agreement

Each Codex task should have one concrete outcome. At the start, restate the scope and exclusions. At the end, report changed files, verification performed and the next physical-device check, if any.
