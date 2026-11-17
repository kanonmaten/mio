---
title: "AI batch failures caused by the batch's content are skipped or split, never a reason to stop AI"
author: Kanonmaten
date: 2026-11-17
branch: main
cost: { minutes: 55, tokens: 459475 }
id: l-ec7af0db
scope: repo
status: active
src: agent
touches:
  - CHANGELOG.md
  - Mio/MioAnalysisCoordinator.swift
  - Mio/Models/MioPairing.swift
  - MioTests/MioCoordinatorContextTests.swift
  - docs/DECISIONS.md
  - docs/STATUS.md
  - Mio/Services/MioSystemServices.swift
  - Mio/Services/TranscriptionService.swift
  - MioTests/TranscriptionTests.swift
  - Mio/ContentView.swift
---

## Decided
- A failure that depends on what is in the batch (provider refusal, too-large request or answer, cut-off answer, invalid answer, a 400 the gateway gives for the request body, the phone's own size check) shrinks, splits or skips that work. It never calls fail()/disable(), and the identical request is never resent. Only errors that need the user (auth, changed configuration, missing model) stop AI; quota, rate and network errors pause.
- A refusal is never retried unchanged, even for lesson parts: at temperature 0 the same text is refused again, so the part is split at once.
- Skipped everyday text is remembered across app restarts, because catch-up re-queues unsent text from the last 12 h. Only fragment IDs and times are stored, never text.
- The batch shrink relaxes one step per 4 successful everyday calls; a one-excerpt batch that is still too large is skipped and does not raise the shrink.

## Tried and ruled out
- Keeping skipped IDs only in memory: every relaunch within 12 h sent the refused text again.
- Marking skipped text as analysed in the assistant store: that mixes "AI answered" with "AI never could" in the AI reviews.

## Watch out
- The verifier's swift-core step can hit its timeout in AudioReliabilityTests (time-dependent audio tests) without any assertion failing. Rerun before suspecting a change.
- Up to 8 sources a request may carry only 10,000 bytes, whatever the batch limit; backlog batches must respect that.

In the code:
- Mio/MioAnalysisCoordinator.swift (catch block in startWorker, handleRejectedEverydayWork, relaxEverydayShrink)
- Mio/Models/MioAnalysisSchedule.swift: MioWorkSplit.needsSmallerRequest, MioLessonRetry.isRefusal / isRefusedRequest
- Mio/Models/MioPairing.swift: MioSkippedFragmentLog, key mio.ai.skippedFragments.v1
- Mio/Models/MioEverydayContext.swift: batches() 10,000-byte rule, hints capped at MioAnalysisRequest.maximumHintSources = 8
