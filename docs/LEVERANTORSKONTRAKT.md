# Granskade text-AI-kontrakt

Aktuell kodkatalog finns i [model-profiles.mjs](../server/src/model-profiles.mjs). Kontrakten dokumentgranskades 2026-10-02; denna sammanställning uppdaterades 2026-10-03. **Inga verkliga leverantörsprofiler är modellverifierade för den nya revisionen.** Lokal fixture-/runtime-verifiering, autentiserad gatewaystatus, verklig kontoåtkomst och svensk modellkvalitet är olika bevis.

Alla nuvarande Mio-uppgifter kräver reasoning helt avstängt, temperatur 0, strikt strukturerat utdata och oberoende domänvalidering. Dold reasoning uppfyller inte kravet. Det finns ingen tyst parameter-, modell-, leverantörs- eller vanligt-JSON-fallback. Fråga/analys/lektion behåller sina appkontrakt; serverprofiler väljer modell, inte telefonen.

## Förmågematris

| Provider | Granskad adapter/policy | Lokal verifiering | Verkligt modellprov |
|---|---|---|---|
| `openai` | Responses; `reasoning.effort:none` för granskade reasoningmodeller, 4.x är icke-reasoning; `temperature:0`, `text.format` med strikt schema, `store:false` | Request-/response-fixtures och avvisning av okända ID:n | Återstår |
| `groq` | Chat Completions; Qwen `reasoning_effort:none`, temperatur 0 och `response_format.json_schema.strict:true` | Fixtures, profilrouting, syntetiskt Worker-runtimeprov | Återstår |
| `gemini` | Native GenerateContent; `thinkingBudget:0`, temperatur 0, `responseMimeType:application/json` och `responseJsonSchema` | Native fixtures och schema-/thinkingkontroller | Återstår |
| `anthropic` | Messages; `thinking.type:disabled`, temperatur 0, `output_config.format` med native JSON-schema | Native fixtures, schema-subset och finishkontroller | Återstår |
| `vercel` | Responses med enbart OpenAI-routning; samma obligatoriska policy för granskade modeller | Fixtures, endast granskade gateway-ID:n och validerade nativealternativ | Återstår |
| `openrouter` | Chat, endast granskade icke-reasoning OpenAI-ID:n; `only:[openai]`, `allow_fallbacks:false`, `require_parameters:true`, strikt schema och temperatur 0 | Fixtures och avvisning av annan routing | Återstår |
| `mistral` | Adaptergräns bevarad, samtliga profiler spärrade: fullständig reasoning OFF är inte etablerad | Lokal avvisning före kvot/modelltrafik | Inte tillåtet genom Mio-katalogen |
| `deepseek` | Adaptergräns bevarad, samtliga profiler spärrade: strikt sluttexts-schema är inte etablerat tillräckligt | Lokal avvisning före kvot/modelltrafik | Inte tillåtet genom Mio-katalogen |
| `custom` | Chat med explicit operatörsförsäkran `chat-none-strict`; HTTPS och exakt modell-ID | Syntetisk fixture och kontrakts-/URL-avvisning | Återstår för operatörens faktiska endpoint |

Lokal verifiering använder syntetiska transportgränser, inte leverantörernas servrar. Fixturerna finns i [adapter-contracts.test.mjs](../server/test/adapter-contracts.test.mjs), [providers.test.mjs](../server/test/providers.test.mjs) och [task-routing.test.mjs](../server/test/task-routing.test.mjs). Resultat för hela aktuella revisionen redovisas i [status](STATUS.md).

## Exakta tillåtna ID:n

Ett familjeprefix är inte stödbevis. Tabellen är en explicit lista; inga andra datumändelser är tillåtna.

| Direkt OpenAI-alias | Tillåtna snapshots utöver alias |
|---|---|
| `gpt-6-luna`, `gpt-6-sol` | Inga |
| `gpt-5.1` | `gpt-5.1-2025-11-13` |
| `gpt-5.2` | `gpt-5.2-2025-12-11` |
| `gpt-5.4` | `gpt-5.4-2026-03-05` |
| `gpt-4.1` | `gpt-4.1-2025-04-14` |
| `gpt-4.1-mini` | `gpt-4.1-mini-2025-04-14` |
| `gpt-4.1-nano` | `gpt-4.1-nano-2025-04-14` |
| `gpt-4o` | `gpt-4o-2024-08-06`, `gpt-4o-2024-11-20` |
| `gpt-4o-mini` | `gpt-4o-mini-2024-07-18` |

OpenAI dokumenterar `none` och strukturerat utdata för [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna); [Sol](https://developers.openai.com/api/docs/models/gpt-6-sol), [5.1](https://developers.openai.com/api/docs/models/gpt-5.1), [5.2](https://developers.openai.com/api/docs/models/gpt-5.2), [5.4](https://developers.openai.com/api/docs/models/gpt-5.4) och [modellguiden](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.4) styr deras parametergranskning. Snapshotlistorna för 4.x kommer från [4.1](https://developers.openai.com/api/docs/models/gpt-4.1), [mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini), [nano](https://developers.openai.com/api/docs/models/gpt-4.1-nano), [4o](https://developers.openai.com/api/docs/models/gpt-4o) och [4o-mini](https://developers.openai.com/api/docs/models/gpt-4o-mini). GPT-6.1 Sol/Astra och äldre 4o-snapshots ingår inte.

| Övrig provider | Exakta tillåtna ID:n |
|---|---|
| Groq | `qwen/qwen3.8-27b` |
| Gemini | `gemini-2.5-flash`, `gemini-2.5-flash-lite` |
| Anthropic | `claude-sonnet-4-5`, `claude-sonnet-4-5-20250929`, `claude-haiku-4-5`, `claude-haiku-4-5-20251001`, `claude-opus-4-5`, `claude-opus-4-5-20251101` |
| Vercel | `openai/gpt-6-luna`, `openai/gpt-6-sol`, `openai/gpt-5.2`, `openai/gpt-5.4`, `openai/gpt-4.1`, `openai/gpt-4.1-mini`, `openai/gpt-4.1-nano`, `openai/gpt-4o`, `openai/gpt-4o-mini` |
| OpenRouter | `openai/gpt-4.1`, `openai/gpt-4.1-mini`, `openai/gpt-4.1-nano`, `openai/gpt-4o`, `openai/gpt-4o-mini`, `openai/gpt-4o-2024-08-06`, `openai/gpt-4o-2024-11-20`, `openai/gpt-4o-mini-2024-07-18` |
| Mistral, DeepSeek | Inga; befintliga namn är spärrade |

Groqs [strikta utdata](https://console.groq.com/docs/structured-outputs) och [reasoningkontroll](https://console.groq.com/docs/reasoning) etablerar Qwen-kontraktet. Gemini använder [native strukturerat utdata](https://ai.google.dev/gemini-api/docs/generate-content/structured-output) och [thinkingBudget](https://ai.google.dev/gemini-api/docs/thinking); Pro/3 och tidigare previews är inte granskade profiler här. Anthropic använder [strukturerade svar](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [Messages](https://platform.claude.com/docs/en/api/messages/create) och [exakta modellversioner](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions).

Vercel måste dessutom ha modellen i sin [egen katalog](https://ai-gateway.vercel.sh/v1/models) och följa [Responses-formatet](https://vercel.com/docs/ai-gateway/sdks-and-apis/responses). OpenRouter kräver [strikt schema](https://openrouter.ai/docs/guides/features/structured-outputs) och [låst routning med parameterkrav](https://openrouter.ai/docs/guides/routing/provider-selection); upstreams modellstöd räcker inte för gatewayens stöd. GPT-5/6 tillåts därför inte genom den nu granskade OpenRouter-katalogen.

Mistrals [reasoningguide](https://docs.mistral.ai/studio/conversations/reasoning) beskriver `none` på aktuella Small/Medium som minimalt, dolt tänkande; det uppfyller inte full OFF. Large saknar tillräckligt etablerad OFF-kontroll i granskningen. DeepSeeks [Responses](https://api-docs.deepseek.com/api/create-response/) och [kompatibilitetsguide](https://api-docs.deepseek.com/guides/responses_api/) etablerar inte ett tillräckligt preciserat strikt sluttextskontrakt och kan ignorera parametrar. Verktygens strict-mode ersätter inte verktygsfri strukturerad sluttext. Dessa gränser får inte kringgås med annan modell eller vanligt JSON-läge.

## Validerade adapteralternativ

| Provider | Tillåtna `adapterOptions` |
|---|---|
| OpenRouter | `dataCollection: "allow"` eller `"deny"`; `zeroDataRetention: boolean` |
| Vercel | `zeroDataRetention: boolean`; `disallowPromptTraining: boolean` |
| Anthropic | `serviceTier: "auto"` eller `"standard_only"` |
| Övriga | Tomt objekt; inga andra alternativ |

Alternativen kan inte ändra reasoning, temperatur, schema, verktyg, credentials, godtyckliga headers eller fallback. Schemaegenskaper som en nativeadapter inte stöder avvisas före kvotreservation; de tas inte tyst bort. Retentionskontroller är anropskrav, inte ett löfte om alla leverantörens datavillkor.

Egen endpoint kräver operatörens explicita `chat-none-strict`-försäkran för exakt modell. Base URL måste vara HTTPS utan credentials/query/fragment/egen port eller lokal/IP-värd. Ingen redirect följs. Ett korrekt svar bevisar inte att endpointen upprätthåller obligatoriska parametrar internt.

## Separat godkänt syntetiskt modellprov

Kör först [den lokala verifieringen](../server/README.md#verifiera-utan-modelltrafik). Publicera och read-verifiera endast efter uttrycklig publiceringsbegäran. En lyckad modellfri status är inte sändningsgodkännande: godkänn därefter den exakta profilen, nedanstående syntetiska payloads och högst tre modellförsök separat. De kan förbruka kvot och kosta pengar. Vänta normalt minst 60 sekunder mellan anrop. Osäkert utfall kräver manuell bedömning före omförsök.

1. Fråga via `/v1/ask`: `{"question":"Vad är 2 + 2? Svara kort på svenska.","context":[]}`. Granska exakt payload och observerad konfigurationsrevision innan Skicka. Kontrollera giltigt kort svar och att svar inte ger lokala/systemåtgärder eller implicit historik. Explicit spara som anteckning provas separat lokalt.
2. Vardag via `/v2/analyze`, med en ny syntetisk källa, tom kontext/beslut och känd tidszon:

   ```json
   {"mode":"everyday","timeZone":"Europe/Stockholm","fragments":[{"id":"11111111-1111-4111-8111-111111111111:0","text":"I morgon klockan nio ska jag lämna tillbaka en bok.","occurredAt":"2026-10-03T12:00:00+02:00"}],"contextFragments":[],"priorDecisions":[],"contextLimited":false}
   ```

   Kontrollera grundade käll-ID/citat, giltig kalenderdag/tidszon, inga automatiska minnen, inga verkliga kalenderåtgärder och explicit datumgranskning/Ja. Tomma förslagslistor kan vara ett giltigt resultat; strukturen bevisar inte semantisk kvalitet.
3. Lektion via `/v1/lesson-notes`:

   ```json
   {"mode":"lesson","timeZone":"Europe/Stockholm","fragments":[{"id":"22222222-2222-4222-8222-222222222222:0","text":"En procent är en hundradel. Tjugo procent av femtio är tio. Läxa: öva två exempel i morgon efter skolan.","occurredAt":"2026-10-03T12:00:00+02:00"}]}
   ```

   Kontrollera detaljerade avsnitt, exakta citat, enbart plan/task-kandidater, bevarade model-/promptmetadata, nästa intervall och lokal kopiering. Läxförslag kräver Ja. Avbrott/omstart ska bevara färdiga delar och fortsättning ska skicka enbart saknat underlag.

För varje försök registreras tid, gatewayrelease, bundle-/kodrevision, observerad konfigurationsrevision, task, begärd och eventuellt returnerad modell, säkra request-ID:n, HTTP/felkategori, input/output/reasoning-token om rapporterat, latens och faktisk debitering i leverantörskontot. Råa headers, nycklar, svarstexter och URL:er hör inte till driftrapporten. Positiva reasoning-token eller synliga thinking-block avvisas. Saknad usage eller noll rapporterade reasoning-token bevisar inte intern avstängning: verifiera även den faktiska requestens obligatoriska parameterformat och dokumenterat exakt modellkontrakt.

Refusal/truncation, invalid schema, unsupported options, routingbyte, 409 före trafik och inget fallback provas deterministiskt i lokala fixtures. Negativa Access-/gateway-authprov ska använda tom syntetisk kropp och får inte gå vidare till en leverantör. Live-prov ersätter inte samtliga felgrenar, Xcode, native nätverk eller iPhone-acceptans. Svensk precision, latens, batteri och värme mäts enligt [helhetstestplanen](TESTPLAN_HELHET.md) och [Pianissimo-proven](TESTPLAN_PIANISSIMO.md).

## Utökningsgräns

`tasks.mjs` äger Mio-prompt/schema/budget/domänvalidator, `model-profiles.mjs` exakt kontrakt, `adapters.mjs` nativeformat/normalisering och `generation-execution.mjs` routing/deadline/kvot. Adaptrar får inga Mio-tasknamn för att välja prompt. Streamad generering, modellverktyg, multimodala anrop, STT/TTS, embeddings och asynkrona modelljobb är inte produktfunktioner eller annonserade förmågor. En verklig framtida funktion behöver eget typat kontrakt; det finns inget tomt universalramverk. Pianissimo förblir separat privat transkriptionstjänst.
