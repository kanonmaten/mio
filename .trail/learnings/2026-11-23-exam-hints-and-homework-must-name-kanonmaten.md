---
title: "Exam hints and homework must name only facts their quote holds, checked by rules and only in lesson notes v2"
author: Kanonmaten
date: 2026-11-23
branch: mio-46-quote-facts
cost: { minutes: 19, tokens: 186770 }
id: l-ecd796c9
scope: repo
status: active
src: agent
touches:
  - CHANGELOG.md
  - control/README.md
  - control/app/src/ai.rs
  - control/core/src/ai_settings.rs
  - control/core/src/settings.rs
  - docs/DECISIONS.md
  - server/README.md
  - server/src/config.rs
  - server/src/generation.rs
  - server/src/status.rs
---

## Decided
The user chose (2026-11-23, MIO-46) rule-based checks first: every number, weekday, month and name in a v2 exam hint, or in a lesson homework title, must also be in its proved quote, or that item is dropped silently like any unprovable item. Spoken numbers in the quote count (tjugo, tjugofem, tredje); in the text, "en", "ett" and ordinals are ignored because they double as ordinary words. A name is a capitalised word inside a sentence, compared on its stem without genitive s.

## Tried and ruled out
- A second, cheap model call judging text against quote: catches inverted meaning too, but is a new task with real model traffic and can itself be wrong. Revisit only if the MIO-47 PC test shows errors the rules miss.
- Applying the rule to lesson sections: a section that fails rejects the whole lesson part, too harsh.

## Watch out
`check_lesson` is shared by v1 and v2; the fact rule runs only when `check_facts` is true (v2), because /v1/lesson-notes is documented as unchanged byte for byte. Test fixtures with numbered hints ("Tips 0") now get dropped unless the quote holds the number.

In the code: server/src/facts.rs (`follow_quote`), server/src/analysis.rs (`clean_exam_hint`, `check_lesson`), test `a_hint_or_homework_that_names_a_fact_its_quote_lacks_is_dropped` in server/tests/lesson_v2.rs.
