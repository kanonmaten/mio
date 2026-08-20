# Mio – project guidance for Codex

This file is the durable starting point for every Codex task in this repository.

## Read first

Before changing code or documentation, read:

1. `README.md`
2. `docs/PRODUKTVISION.md`
3. `docs/ROADMAP.md`
4. `docs/DECISIONS.md`
5. the relevant test or installation document for the task

## Product and current phase

- Mio is a private personal iPhone app for one user; App Store distribution is not planned.
- The long-term product is a discreet daily companion for local transcription, notes, plans, explicit memories and summaries. It is not intended to be a general ChatGPT-style tutor.
- The wake word is the standalone word `Mio`.
- Phase 1 is a feasibility test on an iPhone 13 running iOS 26.
- Phase 1 intentionally contains no OpenAI calls, account system, calendar integration or saved raw audio.
- The real device selected `DictationTranscriber` with `sv_SE`. The advanced Swedish `SpeechTranscriber` asset could not be installed in the first test.
- A short smoke test passed on 2026-08-20. Long background, battery and interruption tests remain. See `docs/TESTRESULTAT_FAS_1.md`.

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
- `.github/workflows/build-unsigned-ipa.yml` is the authoritative cloud build and uses Xcode 26.
- GitHub Actions produces an unsigned IPA. SideStore signs and installs it with the user's Apple Account.
- Run all safe static checks available on Windows. State clearly which checks still require GitHub Actions or the physical iPhone.
- When behavior or test status changes, update `docs/BYGGSTATUS.md`, `docs/ROADMAP.md`, `docs/KRAVMATRIS_FAS_1.md` and/or `docs/TESTRESULTAT_FAS_1.md` as applicable.

## Working agreement

Each Codex task should have one concrete outcome. At the start, restate the scope and exclusions. At the end, report changed files, verification performed and the next physical-device check, if any.
