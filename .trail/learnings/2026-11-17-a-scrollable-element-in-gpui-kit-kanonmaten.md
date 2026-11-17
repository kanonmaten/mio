---
title: "A scrollable element in gpui-kit hides its test id, so put the id on a wrapper"
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 15, tokens: 55896 }
id: l-4f2d67aa
scope: repo
status: active
src: agent
---

## Decided
- Give a scrolling list its test id on a plain wrapper div, because `overflow_y_scrollbar()` wraps the element in a Scrollable and the id inside is no longer found ("missing ElementId Name(\"verify-output\")" in the UI test).

## Watch out
- The same goes for any element whose builder wraps it (Textarea has no `.id()` at all). When `find` fails, the panic lists every registered path; look for `Scrollable<…>` around where your id should be.

In the code: control/app/src/verify.rs (wrapper "verify-output" around "verify-output-lines").
