---
title: "Groq 413 is a size refusal, not a quota wait"
author: Kanonmaten
date: 2026-11-15
branch: main
cost: { minutes: 1, tokens: 1537 }
id: l-69ad6c9a
scope: repo
status: active
src: agent
touches:
  - server/src/adapters.mjs
  - server/src/generation-execution.mjs
  - "Mio/MioAnalysisCoordinator.swift#handleRejectedEverydayWork"
  - "Mio/Models/MioAnalysisSchedule.swift#MioWorkSplit"
---

Symptom the user reported on 2026-11-15: the app kept showing 'quota reached, retrying in 60 s' and nothing ever happened. Cause: on Groq's free tier a request is admitted only if prompt tokens plus max_tokens fit the model's 8,000 tokens per minute, and the max_tokens reservation counts whether or not the answer uses it. A request over that gets HTTP 413 with error code rate_limit_exceeded, and no wait fixes it. normalizeProviderError in server/src/adapters.mjs matched on the code first, so 413 became provider_quota (429, Retry-After 60), and MioAnalysisCoordinator put the same batch back at the head of the queue after each pause. Fix: adapters.mjs checks status 413 before the code and returns provider_request_too_large; fitToMinuteBudget in generation-execution.mjs sizes max_tokens against MIO_TOKENS_PER_MINUTE (estimate: 3 UTF-8 bytes per token) before the call; the app shrinks or skips a refused everyday batch (handleRejectedEverydayWork) instead of resending it. Ruled out: a real tokenizer in the gateway (the gateway has no dependencies, and Qwen's Swedish tokenization was not verified), and only remapping 413 without sizing (the app would split blindly). Not verified against real Groq traffic: the 413 behaviour comes from Groq's rate-limit docs and user reports, the tests use a synthetic transport. Rule that follows: a refused or failed batch must never be resent unchanged; when adding a new provider error, decide whether waiting can help before mapping it to a 429.
