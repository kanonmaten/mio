---
title: "In the control panel, JSON key order depends on which crates are built together, so tests compare parsed JSON"
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 137, tokens: 2033252 }
id: l-c7e8b02a
scope: repo
status: active
src: agent
touches:
  - control/core/src/http.rs
  - control/core/src/lib.rs
  - control/core/src/socket_owner.rs
  - control/helper/src/lib.rs
  - control/helper/tests/helper.rs
  - docs/DECISIONS.md
  - CHANGELOG.md
  - CLAUDE.md
  - control/core/src/settings.rs
  - docs/PLAN_KONTROLLPANEL.md
---

## Decided
Tests in control/ compare JSON as parsed values, never as strings.

## Watch out
GPUI turns on serde_json's `preserve_order` feature. Cargo unifies features across a workspace, so the same code in control/core serializes objects in insertion order when the whole workspace is built (the gate runs `cargo test --workspace`), but sorted when only `-p mio-control-core` is built. A string comparison passed alone and failed in the gate. The gateway and the helper parse the JSON, so either order is fine at runtime.

In the code:
- control/core/src/ai_settings.rs, test `a_lesson_on_another_provider_becomes_a_task_profile_and_needs_its_key` (MIO_AI_TASK_PROFILES)
- The gate step `control-tests` runs `cargo test --locked --manifest-path control/Cargo.toml --workspace`
