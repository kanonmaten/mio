---
title: "Lesson models that always reason are sent without temperature, since no provider documents a value"
author: Kanonmaten
date: 2026-11-23
branch: mio-43-lesson-temperature
cost: { minutes: 57, tokens: 247656 }
id: l-b4f693d4
scope: repo
status: active
src: agent
touches:
  - CHANGELOG.md
  - control/README.md
  - control/app/src/ai.rs
  - control/app/src/setup.rs
  - control/app/src/shell.rs
  - control/app/tests/app/ai.rs
  - control/app/tests/app/setup_computer.rs
  - control/core/src/setup.rs
  - control/core/src/status.rs
  - control/core/src/updates.rs
---

## Decided
The user decided (2026-11-22, MIO-43) that lessons get the provider's recommended temperature instead of 0; temperature stays without a setting. Reading the docs on 2026-11-23 found that no provider recommends a value for its reasoning models: Mistral's Large 4 model and reasoning pages, OpenAI's gpt-6.2-sol page and reasoning guide are silent, and Google's text-generation page says Gemini 4 and 3.6+ ignore temperature/top_p/top_k and asks for them to be removed. OpenRouter forwards no temperature when it is absent. So "recommended" means the provider's own default: the parameter is left out for every model that always reasons, and /v2/status says "provider-default" for lesson. Ask, everyday, and lessons on a non-reasoning model keep temperature 0.

## Tried and ruled out
- A fixed value such as 0.7 for reasoning models: no source supports it.
- Temperature 0 for Gemini 3.8 Flash: Google says it is ignored and should be removed.

## Watch out
`Reviewed.temperature` now means "the provider takes a temperature at all" (false for Anthropic). What is sent is `Reviewed::sends_zero_temperature()`, which also turns it off for `Reasoning::Effort`. Use that, not the field, when listing or building a profile.

In the code: server/src/model_profiles.rs (`sends_zero_temperature`, `profile_for`), server/src/tools.rs (`reviewed_models`), test `a_model_that_reasons_gets_its_providers_temperature_and_a_plain_one_gets_zero` in server/tests/reasoning_usage.rs.
