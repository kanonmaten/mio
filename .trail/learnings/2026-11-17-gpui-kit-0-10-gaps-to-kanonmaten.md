---
title: gpui-kit 0.10 gaps to know before writing a Mio Kontroll page
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 1, tokens: 1588 }
id: l-041368a6
scope: repo
status: active
src: agent
touches:
  - control/app/tests/ai.rs
---

## Decided
- Test ids for a text area go on a wrapping div, because gpui-kit's Textarea has no `.id()` (the build fails with "no method named `id` found for struct Textarea"). Give the wrapper `.id(..).test_support()`, and click it in a test before typing.
- Use only icons from gpui-kit's default component set (`IconName`), because it is a small subset of Lucide and a missing name does not compile: there is no Smartphone, QrCode or Key. The list is in the `__component_icon_names!` macro in the generated `icon_name.rs` under `target/debug/build/gpui-kit-assets-*/out/`.

## Watch out
- A Select confirm is deferred, so a UI test that asserts right after choosing sees the old state ("1 ändringar" instead of 2). Call `cx.run_until_parked()` first.
- Test focus loss with `VisualTestContext::from_window(handle, cx).deactivate_window()`. A page that hides something on blur uses `cx.observe_window_activation(window, ..)`, so its `new` needs the window.
- Don't edit the next phase while the full gate is running, because the gate compiles the working tree as it is at that moment and half-written code fails it. Keep drafts outside the repo until the commit is done.

In the code: control/app/src/words.rs (wrapper id "words-editor"), control/app/tests/ai.rs (run_until_parked after the select).
