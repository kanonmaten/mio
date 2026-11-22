---
title: "OpenAI, OpenRouter and Gemini became candidate providers, and reasoning-off decides which model serves which task"
author: Kanonmaten
date: 2026-11-22
branch: mio-40-more-providers
cost: { minutes: 16, tokens: 148497 }
id: l-ff78bdd6
scope: repo
status: active
replaces: l-2a96c54a
src: agent
touches:
  - CHANGELOG.md
  - CLAUDE.md
  - control/core/src/ai_settings.rs
  - control/core/src/command.rs
  - control/core/src/settings.rs
  - docs/DECISIONS.md
  - server/README.md
  - server/src/adapters.rs
  - server/src/model_profiles.rs
  - server/tests/new_providers.rs
---

## Decided
The user chose (2026-11-22) to add OpenAI, OpenRouter and Google Gemini next to Mistral, Groq, Anthropic and NVIDIA, each with several candidate models that only become selectable after a passed trial. Reasoning-off rule decides which models fit which task: OpenAI gpt-6-luna and gpt-6.1-terra take effort none; gpt-6.2-sol rejects none (lesson only). Gemini 3 and 4 cannot turn reasoning off, so only gemini-2.5-flash-lite serves ask/everyday and 3.8 Flash is lesson only. OpenRouter calls are pinned per request to endpoints that support every sent parameter, collect no data and retain nothing; without such an endpoint the call fails.

## Tried and ruled out
- Relying on OpenRouter account settings alone or the models list's zdr filter: the filter only narrows the catalog, it does not steer routing.
- Guessing prices: OpenRouter's price depends on the upstream endpoint, and Gemini's cached-input price was not read, so neither has a Price entry.

## Watch out
- OpenAI docs do not say whether GPT-6 models accept temperature 0 or max_tokens; the adapter sends max_completion_tokens and the trial settles temperature (if refused, mark temperature false like Anthropic).
- OpenRouter's public /api/v1/models returns no supported_parameters or pricing despite the docs; per-endpoint records have them.
- Gemini's free tier allows about 20 Flash requests a day, far below everyday's ~190 batches, and in the EEA only paid services may back an API client.
- The parity recording used openai as an unknown provider; exactly one configuration case differs and is allowed in the parity test.

In the code: server/src/model_profiles.rs (PROVIDERS, CANDIDATE_MODELS, PRICES), server/src/adapters.rs chat_request, server/tests/new_providers.rs, control/core PROVIDER_IDS and PROVIDER_SECRET_KEYS (same order).
