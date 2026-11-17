---
title: "Free AI providers checked as Groq alternatives: Mistral is the only realistic one, Gemini free and Cerebras are not"
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 4, tokens: 62089 }
id: l-2a96c54a
scope: repo
status: active
src: agent
touches:
  - docs/STATUS.md
  - CLAUDE.md
  - docs/DECISIONS.md
  - server/src/model_profiles.rs
  - server/src/adapters.rs
---

## Decided
Nothing switched yet. Groq `qwen/qwen3.8-27b` stays the only provider until the user decides. Research done 2026-11-17 for a user in Sweden (EEA). Most figures come from third-party trackers, not provider docs, so recheck before acting.

## Tried and ruled out
- Gemini free tier: in the EEA, Google's terms apply the paid-service data rules to the free tier too, so training isn't the problem. Free Flash was about 20 requests/day in Oct 2026, below Mio's roughly 190 five-minute everyday batches a day. Flash-Lite (about 500/day) fits but is weaker. The terms also say "only Paid Services" may be used when making an API client available to users in the EEA; whether that covers a one-person app is unclear.
- Cerebras: the open free tier ended 2026-07-21; it's now a one-time $5 credit.
- NVIDIA NIM: already used 2026-10-05 and replaced by Groq on 2026-10-11; it would also break the Qwen-only rule.

## Watch out
- Mistral's free Experiment plan fits the volume (about 1 request/s, 1B tokens/month). It may train on requests by default; the user said they trust Mistral more and accept that. Its chat models have no reasoning to turn off. `response_format` json_schema is documented, but a `strict` flag is unconfirmed, and Swedish quality hasn't been tested. An earlier gateway revision blocked Mistral until exact contracts were established; a real test call settles that, and real model traffic needs the user's OK.
- Switching changes the "Groq only" rule in CLAUDE.md, so it's the user's decision, recorded in docs/DECISIONS.md.

In the code:
- server/src/model_profiles.rs PROVIDERS lists only groq; a new provider goes there plus an adapter in server/src/adapters.rs.
- MIO_TOKENS_PER_MINUTE sizes max_tokens for Groq's 8,000 TPM free limit; 0 turns it off for a paid plan.
