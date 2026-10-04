# Mio: reliability, coherent workflows, and provider independence

## Summary and agreed direction

Strengthen the existing Mio product: private capture, lessons, notes, planning, suggestions, and explicit approvals. Configure text-AI providers and models through server task profiles. Keep original Pianissimo on the private GPU/Tailscale service.

The audit covered the application source and XCTest files, both backend runtimes, transcription server, persistence, system integrations, configuration, dependencies, and build/deployment infrastructure. No tracked files were changed.

Fresh verification:

- **47 Node tests passed**, with simulated providers.
- **25 transcription API tests passed**, with a fake backend.
- **199 structural checks passed**.
- Worker dry-run and local workerd/Miniflare tests passed without external model requests.
- Current revision `3f99f40` was **not iOS-built or phone-verified**. The latest successful [Xcode run](https://github.com/kanonmaten/mio/actions/runs/36694542101) covers earlier revision `7901644`.
- Cloudflare’s active code/configuration mismatch was verified through read-only administration calls.

The current system is:

```text
Microphone → bounded RAM audio → private transcription API
           → original transcript/session → local storage
           → local commands or consented text analysis → suggestions
           → user approval → local content → optional system actions

Completed lesson → consented text parts → detailed notes
                 → persisted parts → local compilation/copying

Approved question/context → text gateway → provider
                          → validated temporary answer
```

There is no existing threaded AI conversation history, streaming generation, model tool execution, TTS, audio playback, embeddings, or server-side conversation database.

## Cross-cutting architecture findings

| Finding | Consequence | Implementation priority |
|---|---|---|
| Cloudflare runs older OpenAI-only code with Groq configuration | The deployed gateway cannot initialize correctly; newer routes are absent | Immediate deployment preparation |
| Audio expiry is disabled during graceful stop | Nearly expired audio can remain held beyond the 60-second rule | Critical regression fix |
| Starting a lesson loses the suspended everyday session from the in-memory register | Returning to everyday capture fails despite the session remaining on disk | Critical workflow fix |
| Session edits replace whole snapshots captured before suspension points | Concurrent edits can overwrite each other; late writes can compete with deletion | Critical persistence fix |
| Product operations are coordinated partly by views, callbacks, global errors, and busy flags | Successful storage can still fail to finalize a lesson; automatic work can be silently skipped | Shared workflow boundary |
| Provider/model/protocol/task responsibilities share one gateway module | Adding capabilities or routing rules becomes increasingly brittle | Targeted backend separation |
| Discovery validation hardcodes providers and known capabilities | A new server provider or advertised capability can require an otherwise unnecessary IPA update | Compatibility fix |
| Source identity does not include correction freshness | Existing lesson notes can look complete after their source text changes | Explicit freshness tracking |
| Deadlines, errors, and recovery differ across boundaries | D1 timeouts can leave unanswered requests; useful failure distinctions disappear | Unified execution policy |

Representative evidence: [audio stop](/home/kanonmaten/Documents/ChatGPT/Mio/Mio/Services/LiveTranscriptionPipeline.swift:105), [lesson transition](/home/kanonmaten/Documents/ChatGPT/Mio/Mio/MioViewModel.swift:197), [snapshot replacement](/home/kanonmaten/Documents/ChatGPT/Mio/Mio/Services/SessionRepository.swift:36), [discovery restrictions](/home/kanonmaten/Documents/ChatGPT/Mio/Mio/Models/MioDiagnosticsModels.swift:191), and [budget wait](/home/kanonmaten/Documents/ChatGPT/Mio/server/src/server.mjs:230).

These are source-level findings. The gateway deadline, schema, date, and response-size discrepancies also have synthetic reproductions. Actual microphone and device behavior still require physical testing.

## Highest-leverage improvements and order

Implement independently reviewable stages:

1. **Regression fixes:** audio expiry/timing, everyday–lesson transitions, session write races, gateway deadline/schema/date validation, and extensible discovery.
2. **Workflow ownership:** move acceptance, lesson finalization, deletion, and capture-event coordination into a small testable application service.
3. **Provider architecture:** separate task definitions, model profiles, adapters, and request execution; introduce server task routing.
4. **Workflow improvements:** connection diagnostics, freshness/conflict notices, notification navigation, and explicit answer saving.
5. **Release validation:** authorized gateway deployment, exact-revision Xcode build, synthetic provider checks, then physical-device acceptance.

The necessary Cloudflare repair can be released separately from later product improvements. Do not delay restoring compatible gateway code for speculative capabilities.

Each stage should introduce failing regression tests for its defects, implement the smallest adequate changes, and pass its relevant checks before dependent stages begin.

## Core architecture

**Current weakness:** SwiftUI participates in business coordination, while observable presentation state also controls whether automatic operations run.

**Change:**

- Introduce a small application workflow coordinator owned by `MioApp`.
- Give it responsibility for capture-event routing, lesson finalization, suggestion acceptance/rejection, coordinated deletion, and consistent export snapshots.
- Keep `MioAnalysisCoordinator` responsible for consented analysis scheduling.
- Keep view models responsible for presentation and user input. Views invoke commands and display outcomes.
- Inject narrow capture-factory, clock, and system-action boundaries so lifecycle and failure tests do not require a microphone or AlarmKit.
- Replace success decisions based on shared `errorMessage` with explicit operation results.

Automatic finalization must queue or return a visible failure; it must never disappear because an unrelated button operation is busy.

**Affected:** app composition, `ContentView`, view models, analysis coordination, and native-service boundaries.

**Tradeoff:** a small coordination layer adds structure, but avoids a wholesale SwiftUI rewrite. Only workflows with demonstrated cross-component problems move.

**Validation:** deterministic tests for transition order, simultaneous commands, storage failures, cancellation, and late callbacks.

## Backend / services

**Current weaknesses:** the D1 reservation can outlive the deadline without producing a response; lesson schema and validator disagree; invalid calendar dates normalize silently.

**Change:**

- Bound the entire post-body operation by the existing **40-second deadline**, including quota reservation, upstream request, body reading, parsing, and validation. Retain the separate **5-second request-body limit**.
- Distinguish deadline expiry from client cancellation. A live client receives a bounded error response; expired work never starts a later provider call.
- Release concurrency slots and listeners on every exit path.
- Treat an uncancellable, late D1 reservation conservatively: it may consume quota, but must not trigger inference or attempt an unsafe refund.
- Restrict lesson candidates to `plan/task` in both the provider schema and domain validator.
- Validate actual calendar components and offsets, rather than accepting `Date.parse` normalization.
- Keep domain validation independent of provider parsing.
- Preserve the shared Node/Worker implementation and current bridge. Add explicit runtime tests and cancellation bindings rather than assuming Node socket settings apply to Workers.

Cloudflare documents differences between its Node HTTP implementation and ordinary Node servers; those differences need runtime coverage. [Cloudflare HTTP documentation](https://developers.cloudflare.com/workers/runtime-apis/nodejs/http/)

**Affected:** gateway execution, analysis validation, status, budget service, Node transport, and Worker wrapper.

**Tradeoff:** retain the working deployment structure; do not introduce distributed queues or global concurrency infrastructure for this private application.

**Validation:** delayed/hung D1, disconnects during each stage, slow/chunked bodies, oversized upstream bodies, invalid dates, schema-valid-but-domain-invalid responses, and resource cleanup.

## AI-provider abstraction and interoperability

### Provider-independence findings

Important existing coupling points are:

- `provider.mjs` imports Mio prompts/schemas and chooses business task, token budget, provider protocol, model policy, and response interpretation.
- Model eligibility uses family patterns and a small `plain` classification. It accepts invented snapshot names such as `gpt-4.1-2099-99-99`.
- Provider branches own different endpoint, authentication, API-version, reasoning, token-limit, structured-output, and response-envelope conventions.
- Gemini currently uses its OpenAI compatibility surface.
- OpenRouter and Vercel presets deliberately constrain routing to reviewed OpenAI choices; they are not general model interoperability.
- Custom endpoints require the explicit `chat-none-strict` contract. This safeguard should remain.
- Provider errors lose distinctions between credentials, model availability, parameters, refusal, quota, and infrastructure failures.
- Reported metadata describes the configured model; returned model identity, usage, and upstream request identifiers are discarded.
- Swift discovery hardcodes provider names and rejects unknown advertised capabilities.
- Transcription is intentionally coupled to private networking, PCM input, and word timestamps at its API boundary; NeMo/Pianissimo assumptions belong inside its server adapter.

No provider SDK types currently leak into Swift. Preserve that advantage.

### Target architecture

Separate four responsibilities:

| Boundary | Responsibility |
|---|---|
| Mio task definition | Prompt, schema, source rules, output budget, prompt version, domain validator |
| Reviewed model profile | Exact model/alias, supported capabilities, parameter semantics, schema dialect, verification status |
| Provider adapter | Native request/authentication format, response interpretation, safe errors, usage, provenance, validated extensions |
| Execution service | Routing, deadlines, cancellation, quotas, transport limits, diagnostics |

Use a provider-neutral generation request containing messages/input, structured-output requirements, output limit, and explicit generation policy. Return normalized output, finish/refusal state, requested/returned model identifiers, and optional usage/provenance.

Adapters must not receive Mio-specific task names to select prompts themselves.

### Routing and public interfaces

- Preserve the existing question, analysis, and lesson request/result bodies.
- Add optional `MIO_AI_TASK_PROFILES` server configuration keyed by `ask`, `everyday`, and `lesson`.
- Each task profile selects `provider`, `model`, and validated adapter options.
- Missing task overrides inherit the current global configuration. This preserves existing installations.
- An invalid task profile disables that task with a specific configuration result; it does not silently route elsewhere.
- Continue resolving credentials through designated server-side provider secrets.
- Preserve legacy OpenAI configuration reading only for backward-compatible configuration, never request-time fallback.

Add a protected **`GET /v2/status`** for task-profile availability, configuration revision, capabilities, and quota information. Preserve `/v1/status` for older clients.

New clients send the observed configuration revision with AI requests. A changed revision produces **409 before provider traffic**, requiring re-preview or reactivation. Discovery accepts bounded unknown provider identifiers and capability names, while checking capabilities required by the selected task. Generated domain results remain strictly validated.

### Capabilities without a lowest common denominator

- Keep **reasoning disabled, temperature 0, and strict structured output** mandatory for all current Mio tasks.
- Describe support per model, not merely per provider or API family.
- Localize native retention, routing, caching, and other useful controls as validated adapter options.
- Reject unsupported required options before quota/inference. Never discard parameters silently.
- Normalize usage and safe errors while retaining optional provider-specific metadata.
- Define extension boundaries for streaming, tools, multimodal input, STT, TTS, embeddings, and async APIs. Do not implement unused dispatchers or empty feature frameworks.
- A future capability receives its own typed contract and adapter extension when a real product feature needs it.

Replace permissive snapshot patterns with explicitly reviewed IDs and documented aliases. Record contract review separately from actual model testing. DeepSeek strict-output compatibility needs explicit verification before it is described as established.

Provider controls differ materially; for example, Groq documents strict schema and reasoning disablement, while Anthropic has a different structured-output contract. [Groq structured outputs](https://console.groq.com/docs/structured-outputs), [Groq reasoning](https://console.groq.com/docs/reasoning), [Anthropic structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)

**Tradeoff:** retain existing adapters and fetch-based transport. Do not adopt a universal SDK simply to replace functioning request builders.

**Validation:** fixture tests for every reviewed adapter, unsupported capabilities/options, profile switching, routing, refusals, usage, errors, schema dialects, and no fallback.

## Transcription / audio / voice

**Current weaknesses:** graceful-stop expiry, uncertain timestamps presented as evidence, and dropped buffers below 250 ms being silently compressed out of the timeline.

**Change:**

- Keep audio expiry active during drain. Schedule against the earliest retained sample deadline, including assembler, pending, and inflight audio.
- Drain for at most the existing 15 seconds **and never beyond audio expiry**.
- Cancel expired transport and release application-owned audio references before awaiting diagnostic/UI callbacks.
- Carry timestamp validity and capture continuity through conversion and chunk assembly.
- Use valid host/sample-time anchors where possible. Estimated callback time must not prove background capture or post-consent eligibility.
- Observe dropped-buffer results and sample continuity. Distinguish actual missing frames from clock jitter; mark real losses and reset the relevant epoch.
- Preserve 20-second owned regions, one-second overlap, PCM16/16 kHz, final results, and stable retry IDs initially.
- Bound serialized server responses to the client’s 262,144-byte limit; reject oversized backend output before caching.
- Add text-free STT diagnostics for retries, formats, dropped buffers, timing validity, duration, and safe error categories.
- Make the Python backend seam explicit: load/readiness, transcription, normalized word timings, and model metadata. Only Pianissimo is configured in this pass.

Apple permits audio timestamps without host time, so validity cannot be assumed. [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime)

**Dependencies:** capture-event types and clock injection precede deterministic lifecycle tests.

**Tradeoff:** keep the existing HTTP strategy until real Swedish accuracy, latency, and battery measurements justify changing overlap or transport.

**Validation:** expiry during stop/retry, one/two dropped taps, repeated loss, format changes, resampling/frame conservation, short tails, interruptions, reset, cancellation, and known Swedish speech across chunk boundaries. Audio conversion follows Apple’s documented conversion boundary. [TN3136](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)

No cloud STT, Apple/CPU fallback, TTS, playback, or WebSocket transcription is added.

## Frontend / UX

- Present microphone state, transcription connectivity, and AI state separately. Recording may remain active while transcription is offline.
- Show clear waiting/loss/recovery messages without presenting the 15–30-second design target as a measured guarantee.
- Add a model-free **Test text-AI connection** action showing authentication, protocol/task availability, release, and selected profiles.
- Distinguish configuration validity from verified provider access and model quality.
- Correct timed-pause wording to describe manual continuation.
- Refresh day views on foreground, day changes, and time-zone changes.
- Improve task-button hit areas and VoiceOver labels, including the task name.
- Preserve native navigation, semantic reading surfaces, Dynamic Type, and accessibility settings.

**Tradeoff:** keep the existing five-tab structure and visual language. Focus on comprehensible behavior and recovery.

**Validation:** UI smoke tests plus physical VoiceOver, large text, dark mode, reduced motion/transparency, and iPhone 13 layout checks.

## Improvements to existing functionality

- Maintain one session register containing active, suspended, and ended sessions. Everyday–lesson–everyday transitions must preserve the original session through success, cancellation, and failed startup.
- Finalize stored lessons based on the actual save result, independently of prior microphone/UI errors.
- Serialize automatic lesson registration rather than dropping it through a UI busy flag.
- Version suggestion drafts. Approval must detect that the reviewed suggestion changed, preserve user edits, and require explicit re-review.
- Reset date confirmation after relevant edits. Missing AI dates require an explicit user date choice; they must not become an unnoticed “now”.
- Preserve the current dated-task model in this pass.
- Add source-freshness metadata to new lesson records. Corrected source text must mark affected existing notes as older/unknown, rather than reporting them as current.
- Preserve existing notes, original text, and evidence. Do not automatically resend corrected material.
- Keep completed lesson parts and manual continuation after interruption.

**Migration:** new revision/freshness fields are optional. Existing records remain readable; missing freshness metadata is shown as unknown rather than fabricated.

**Validation:** failed lesson startup, old-error finalization, simultaneous approval/analysis, missing dates, corrections after analysis, and restart with partially completed notes.

## Worthwhile new features

Limit additions to three cohesive features:

1. **Connection and capacity view:** task-profile status, safe diagnostics, remaining shared quota when available, and expected remaining lesson work. This makes failures and long processing understandable without extra model calls.
2. **Notification navigation:** generic lock-screen text with opaque local IDs that open the relevant post or morning/evening view. Missing/deleted targets fall back safely.
3. **Save AI answer as a note:** an explicit local review/save action using the existing content store. No automatic answer history or extra AI request.

These depend on the workflow, discovery, and persistence improvements.

## Reliability and error recovery

- Use explicit success/failure/cancelled/conflict outcomes.
- Separate gateway authentication, provider authentication/account, model/parameter incompatibility, refusal/truncation, provider quota, local minute/day/concurrency limits, budget-store failure, timeout, and transport failure.
- Normalize numeric and HTTP-date `Retry-After`.
- Keep text-AI retries manual: uncertain requests may already have consumed quota or incurred cost.
- Retain bounded STT retries with the same chunk identity and original expiry.
- Centralize supervised task ownership and cancellation. Disablement, configuration changes, and deletion invalidate late results.
- Add an ID-only, protected operation journal for cross-store deletion. Record intent before removal; complete steps idempotently and reconcile after restart.
- Full-deletion recovery must not restart capture, model work, or permission prompts automatically. A blocked system cleanup gets an actionable retry state.
- Never report complete deletion while app-owned exports, credentials, or system actions remain.

**Tradeoff:** use a small recovery journal for demonstrated multi-store operations, not a general job platform.

## Performance

- Preserve existing batching, lesson pacing, quotas, and bounded context.
- Cache successful discovery briefly by connection/configuration revision; invalidate on settings/auth/revision changes. Never cache user generation responses as an optimization.
- Avoid rebuilding and comparing full historical session arrays for routine UI updates.
- Use targeted state revisions/events to invalidate affected views and export snapshots.
- Cache the assistant document inside its owning actor once external-file fixture tests and invalidation behavior are covered.
- Measure session-store encoding/write time and memory with representative long histories before considering a database migration.
- Measure converter cost, queue age, inference latency, request count, and device battery independently.

**Non-assumption:** 100 shared AI requests/day does not support continuous all-day minute-by-minute analysis. Keep the cap and make that limitation visible; do not silently increase cost exposure.

## Persistence / state management

- Replace metadata/correction whole-session upserts with actor-owned patch commands that read the latest state.
- Capture checkpoints update capture fields without overwriting presentation corrections or reopening finalized sessions.
- Use per-session deletion tombstones and operation generations against late writes.
- Reconcile accepted suggestion IDs against existing content without rewriting later user edits.
- Validate duplicate identities and malformed relationships before constructing dictionaries that can trap.
- Create consistent content/session/assistant export snapshots through the workflow boundary.
- Give exports unique filenames; do not overwrite a file currently being shared.
- Surface export-removal and privacy-attribute failures.
- Share protected atomic-write handling while preserving separate repositories and existing filenames.

Apply protection during file creation, rather than only through best-effort attributes afterward. Apple documents this creation-time option. [Apple file protection](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)

**Migration:** retain current storage paths, legacy session arrays, export compatibility, and unknown-schema protections. Add optional fields and the small operation journal; do not rewrite historical evidence or migrate to SwiftData/SQLite.

## Security and configuration

- Keep provider keys server-owned and gateway/Access/transcription credentials distinct.
- Preserve HTTPS, redirect rejection, private transcription networking, RAM-only audio, and explicit AI consent.
- Keep current task requirements immutable through adapter options.
- Validate profile configuration before provider traffic; unknown/incompatible models fail explicitly.
- Keep source text, answers, audio, credentials, full URLs, and arbitrary error bodies out of operational logs.
- Extend diagnostics only with bounded, sanitized metadata and optional usage.
- Preserve Access protection for all traffic and disable public preview bypasses.
- Never equate a successful status check with valid provider credentials or model access.

Configuration-revision checking depends on task profiles and discovery. Credential rotation remains separately authenticated and does not require exporting secret fingerprints.

## Testing and validation

| Workflow | Required acceptance |
|---|---|
| Questions | Exact approved payload; valid answer; cancellation; explicit note saving; no implicit actions/history |
| Provider/model changes | Correct task routing; unknown provider metadata accepted safely; incompatible capabilities rejected; no fallback; configuration change requires re-review |
| Structured generation | Adapter wire fixtures; strict output; refusal/truncation; source validation; invalid dates; schema/validator agreement |
| Streaming | Existing chunked HTTP body limits/cancellation tested; generated streaming remains unsupported and is never advertised as implemented |
| Tools | AI output cannot execute system actions; suggestions still require approval; model tool execution remains unavailable |
| Capture | Permission denial, start/stop/pause/resume, lesson transitions, interruption, route change, media reset, no unintended restart |
| Transcription | Exact expiry, drop gaps, timing validity, retry identity/cache conflicts, invalid/oversized responses, final tails |
| Backend failures | Slow/hung D1, auth/account failure, quota distinctions, deadlines, disconnects, malformed bodies, cleanup |
| Persistence | Concurrent patches, deletion races, unknown schemas, malformed identities, partial deletion/restart, export snapshots |
| Lessons | Partial completion/restart, finalization failure, stale source, correct copy warnings, no duplicate saved parts |
| System features | Calendar save/cancel, alarm/reminder cancellation, notification routing, time-zone/day changes |

Run existing suites plus targeted regressions. Add a small UI smoke/accessibility suite, not exhaustive snapshots of every view.

Real-provider tests use separately approved synthetic material. Verify request-side reasoning disablement and reported reasoning usage when available; absence of usage alone does not prove internal behavior.

Physical acceptance on iPhone 16 Pro, then iPhone 13:

- Actual iOS 26/27 behavior where supported.
- Locked-screen capture, network changes, PC restart, interruptions, and media reset.
- Swedish accuracy across chunk boundaries with a known reference.
- Battery, heat, latency, and recovery.
- Native Keychain, URLSession, file protection, AlarmKit, notifications, and accessibility.

Report source checks, Xcode/XCTest, IPA validation, installation, and phone results separately.

## Developer experience

- Add Linux CI for structural checks, Node tests, transcription API tests, and Worker runtime checks.
- Keep Xcode/IPA distribution explicit; run the exact release revision on a verified available runner.
- Add strict-concurrency checking as a dedicated diagnostic gate, fixing relevant warnings before escalating enforcement.
- Provide one documented verification entry point with explicit platform limitations.
- Recreate development Python environments from the lockfile rather than relying on the current broken temporary-interpreter symlink.
- Test the minimum supported Node version or narrow the declared support range.
- Record gateway release/bundle/revision and app build provenance.
- Maintain a reviewed provider capability matrix and synthetic contract-test procedure.

## Cleanup / technical debt

- Update stale current-use documentation that still describes OpenAI-only support, Apple transcription, discarded stop batches, or only three stores.
- Preserve dated historical results; correct current guidance without rewriting old evidence.
- Remove duplicate workflow wiring only after replacement tests pass.
- Consolidate repeated safe networking, error normalization, and protected-write code where behavior is genuinely shared.
- Update Swedish user/project documentation, changelog, architecture decisions, and roadmap. Update status only from performed checks.

Do not reorganize Swift files solely for visual neatness.

## Cloudflare gateway work

The existing authenticated Wrangler session and account read access are available. Codex can attempt the later deployment after an explicit request. No deployment was authorized or performed here.

Required release procedure:

1. From `/home/kanonmaten/Documents/ChatGPT/Mio/server`, verify the intended revision, tests, bundle, task configuration, and current production settings.
2. Preserve `mio-private-gateway`, existing D1 binding/database/counters, secrets, and Access policy. Do not recreate D1 or routinely reimport its schema.
3. Compare Wrangler’s explicit variables with Dashboard settings: `keep_vars` does not make explicit conflicting variables harmless.
4. Deploy the intended **code bundle**, not just variable changes.
5. Record and read-verify the active version/release and authenticated status.
6. Verify negative Access/gateway-auth paths and protected alternate addresses.
7. After sending approval, test synthetic question, everyday analysis, and detailed lesson requests with the selected real provider.
8. Build/install the matching app revision and run connection/provider/lesson/device acceptance.
9. Roll back only to a compatible **code/configuration pair**. The older OpenAI code with Groq variables is not a working rollback.

If deployment requires refreshed OAuth scopes, the user must complete the browser authorization. If CLI deployment is unavailable, the same verified bundle/configuration must be deployed through the account’s supported flow, followed by the same read-back and authenticated checks. Secrets must never be pasted into chat or committed.

Cloudflare versions and configuration are separate operational concerns. [Versions/deployments](https://developers.cloudflare.com/workers/versions-and-deployments/), [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)

## Explicit non-goals and defaults

- No threaded chatbot, streaming generation UI, model tools, autonomous actions, TTS, playback, image generation/input, embeddings, or async provider jobs.
- No cloud transcription, Apple/CPU fallback, raw-audio files, silent retries/failover, or automatic microphone restart.
- No client model selector; server task profiles are the chosen control point.
- No automatic corrected-source reanalysis or comprehensive lesson-generation revision system in this pass. Show freshness honestly and preserve existing work.
- No calendar synchronization, broad calendar reading, hidden memories, or automatic homework acceptance.
- No database replacement, distributed job queue, HA/autoscaling, provider marketplace, or universal AI SDK migration.
- No quota increases or claimed battery/accuracy gains without evidence.
- No commit, push, tag, publication, paid model traffic, or deployment without the applicable explicit authorization.

Preserve `Mio` project/module identities, `app.mio.assistant`, current data paths, iOS 26 minimum, immutable original evidence, and all existing consent rules.

Audit tooling: Graft reported **at least ~287k estimated tokens saved across 14 calls**; net savings were not measured because exhaustive source reading followed.
