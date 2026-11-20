---
title: "After the grilling, new features get their own routes and files instead of changing existing contracts"
author: Kanonmaten
date: 2026-11-20
branch: main
cost: { minutes: 11, tokens: 166809 }
id: l-86152479
scope: repo
status: active
src: agent
touches:
  - CLAUDE.md
  - docs/DATAMODELL.md
  - docs/DECISIONS.md
  - docs/PLAN_GRILLNING.md
  - docs/PRODUKTVISION.md
  - control/README.md
  - control/app/src/ai.rs
  - control/app/src/computer.rs
  - control/app/src/model.rs
  - control/app/src/overview.rs
---

## Decided
- Lesson notes with exam hints, speaker roles and a subject suggestion get a new route (`/v2/lesson-notes`, capability `lesson-notes-v2`). `/v1/lesson-notes` stays byte-identical, because the Node parity tests cover it and the app's decoder rejects unknown fields, so changing v1 would break an older app against a newer gateway.
- Words she adds from the phone go to a separate file in Pianissimo's own state directory, merged after the /etc list (max 500 lines together). The /etc file is root-owned and the service is hardened, so the service cannot write it.
- The nightly backup goes to the gateway, not Pianissimo: the app already reaches it with its own token, and Mio Kontroll already reads `/v2/status` through its helper, so the latest backup can be shown from there.
- The usage counter for the credit meter lives in its own state file, separate from the per-minute/day quota counters.
- The recorded Node parity file is never regenerated. New `/v2/status` fields (`reasoning`, `schemaDialect`, `usage`) are removed before comparing, and get their own tests. Everything Node published is still compared byte for byte.
- Lessons on a reasoning model (Mistral Large 4, effort medium, ID `mistral-large-4-0`, the only version-pinned one of three listed IDs) get 12,000 output tokens: 3,000 for the notes plus room for thinking, which Mistral bills as output. Other tasks keep their limits.
- The whole-call deadline for a reasoning lesson is 180 s in the gateway, and the app waits 200 s, so the gateway's error arrives first.

## Watch out
- The backup encryption key sits on the same LUKS disk as the backups. It protects copies moved off the directory, not against root on the PC.
- A field missing from `/v2/status` or `/health` means "old counterpart"; clients must keep working without it.

In the code:
- Contracts: docs/DATAMODELL.md, section "Kontrakt efter grillningen".
- Files: /var/lib/mio-gateway/usage.json, /var/lib/mio-gateway/backups/, /var/lib/mio-transcription/vocabulary-phone.txt.
- Mistral's docs don't say whether `completion_tokens` includes reasoning. The adapter adds reasoning to output only when `total_tokens` shows it was left out.
- The `reasoning-off` capability is still published for `lesson` because older apps require it; the real value is the `reasoning` field.
- Unverified until Prova: strict `response_format` and `temperature: 0` together with reasoning at Mistral.

- server/tests/parity.rs `without_additions`; server/src/config.rs `LESSON_REASONING_MAX_OUTPUT_TOKENS`; server/src/usage.rs; docs/DATAMODELL.md "Kontrakt efter grillningen".

## Tried and ruled out
- Rewriting the golden file with serde: it changes escape sequences in unrelated cases (for example `\u0085`), so the diff would no longer prove parity.
