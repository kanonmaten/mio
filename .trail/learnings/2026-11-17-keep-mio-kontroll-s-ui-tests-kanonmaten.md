---
title: "Keep Mio Kontroll's UI tests in one test binary so the gate fits its ten minutes"
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 1, tokens: 2394 }
id: l-8334c4d9
scope: repo
status: active
src: agent
touches:
  - control/app/tests/app/main.rs
  - tools/src/gate.rs
---

## Decided
- All UI integration tests for the app are modules of one test binary, because every test binary links all of GPUI. With five of them, the control-tests step timed out at 600 s on the laptop after a change to the core ("Verifier process failed: TimeoutExpired", no test failed).

## Watch out
- rust-analyzer builds in the same `control/target`, so cargo waits on its build lock; a gate step that uses little CPU but a lot of time is waiting, not compiling. Start the gate when the editor is idle.
- Add a new page's tests as a module in the existing app test binary, not as a new file directly under `tests/`, because each new file is another GPUI link.

In the code: control/app/tests/app/main.rs (mod per page); tools/src/gate.rs STEP_TIMEOUT = 600 s.
