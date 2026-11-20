---
title: "After the grilling, new features get their own routes and files instead of changing existing contracts"
author: Kanonmaten
date: 2026-11-20
branch: main
cost: { minutes: 5, tokens: 136172 }
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
---

## Decided
- Lesson notes with exam hints, speaker roles and a subject suggestion get a new route (`/v2/lesson-notes`, capability `lesson-notes-v2`). `/v1/lesson-notes` stays byte-identical, because the Node parity tests cover it and the app's decoder rejects unknown fields, so changing v1 would break an older app against a newer gateway.
- Words she adds from the phone go to a separate file in Pianissimo's own state directory, merged after the /etc list (max 500 lines together). The /etc file is root-owned and the service is hardened, so the service cannot write it.
- The nightly backup goes to the gateway, not Pianissimo: the app already reaches it with its own token, and Mio Kontroll already reads `/v2/status` through its helper, so the latest backup can be shown from there.
- The usage counter for the credit meter lives in its own state file, separate from the per-minute/day quota counters.

## Watch out
- The backup encryption key sits on the same LUKS disk as the backups. It protects copies moved off the directory, not against root on the PC.
- A field missing from `/v2/status` or `/health` means "old counterpart"; clients must keep working without it.

In the code:
- Contracts: docs/DATAMODELL.md, section "Kontrakt efter grillningen".
- Files: /var/lib/mio-gateway/usage.json, /var/lib/mio-gateway/backups/, /var/lib/mio-transcription/vocabulary-phone.txt.
