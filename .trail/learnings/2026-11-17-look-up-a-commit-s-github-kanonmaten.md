---
title: "Look up a commit's GitHub run by its full hash, not the short one"
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 14, tokens: 35268 }
id: l-cb8714b5
scope: repo
status: active
src: agent
touches:
  - CHANGELOG.md
  - control/app/src/ai.rs
  - control/app/src/lib.rs
  - control/app/src/parts.rs
  - control/app/src/shell.rs
  - control/app/src/transcription.rs
  - control/app/src/words.rs
  - control/app/tests/ai.rs
  - control/app/tests/transcription.rs
  - control/core/src/lib.rs
---

## Watch out
- `gh run list --commit <sha>` returns an empty list for a short hash, because it matches the full head SHA only. A CI watcher built on it then waits on nothing and reports a failure for a run that actually passed (af86fd3 looked red; run 44149620116 was green).
- Use the full hash (`git rev-parse HEAD`), or list recent runs and compare `headSha`.

In the code: `gh run list --commit "$(git rev-parse HEAD)" --workflow "Verifiera Mio på Linux" --json databaseId,conclusion`
