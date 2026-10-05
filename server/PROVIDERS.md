# Text-AI-leverantörer och modeller

Detta är Mios katalog över tillåtna leverantörer och modeller, och kontraktet varje adapter måste uppfylla. Koden finns i [model-profiles.mjs](src/model-profiles.mjs) och [adapters.mjs](src/adapters.mjs). Hur du byter i Cloudflare står i [Cloudflare-guiden](cloudflare/README.md#2-byt-leverantör-eller-modell).

**Inga leverantörsprofiler är modellprovade för aktuell revision.** Katalogen bygger på dokumentationsgranskning. Lokala fixtures, autentiserad status, verklig kontoåtkomst och svensk kvalitet är olika bevis.

## Krav på varje modell

Alla Mio-uppgifter kräver:

- **Reasoning helt av.** Dold reasoning räcker inte. Modeller som alltid tänker är spärrade.
- **Temperatur 0.**
- **Strikt JSON-schema** i leverantörens eget format.
- **Oberoende validering** av varje svar i servern innan appen använder det.

Det finns ingen tyst parameter-, modell- eller leverantörsfallback. En okänd eller inkompatibel profil avvisas före kvot och modelltrafik. Ett nytt modellnamn hos leverantören blir inte automatiskt tillåtet; det kräver granskning och kodändring.

## Katalog

| `MIO_AI_PROVIDER` | Secret | Tillåtna modell-ID:n | Hur reasoning stängs av |
|---|---|---|---|
| `nvidia` | `NVIDIA_API_KEY` | `deepseek-ai/deepseek-v4.1-flash` | `chat_template_kwargs: {thinking:false, enable_thinking:false}` |
| `groq` | `GROQ_API_KEY` | `qwen/qwen3.8-27b` | `reasoning_effort: none` |
| `openai` | `OPENAI_API_KEY` | Se OpenAI-listan nedan | `reasoning.effort: none`; 4.x saknar reasoning |
| `vercel` | `VERCEL_AI_GATEWAY_API_KEY` | `openai/` + `gpt-6-luna`, `gpt-6-sol`, `gpt-5.2`, `gpt-5.4`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `gpt-4o`, `gpt-4o-mini` | Som OpenAI, endast OpenAI-routning |
| `openrouter` | `OPENROUTER_API_KEY` | `openai/` + `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `gpt-4o`, `gpt-4o-mini`, `gpt-4o-2024-08-06`, `gpt-4o-2024-11-20`, `gpt-4o-mini-2024-07-18` | `reasoning.enabled:false`, `only:[openai]`, inga fallbacks |
| `gemini` | `GEMINI_API_KEY` | `gemini-2.5-flash`, `gemini-2.5-flash-lite` | `thinkingBudget: 0` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-5`(`-20250929`), `claude-haiku-4-5`(`-20251001`), `claude-opus-4-5`(`-20251101`) | `thinking.type: disabled` |
| `mistral`, `deepseek` | `MISTRAL_API_KEY`, `DEEPSEEK_API_KEY` | Inga, spärrade | Full OFF/strikt sluttext är inte etablerat |
| `custom` | `MIO_AI_API_KEY` | Exakt ID med operatörskontrakt, se nedan | `reasoning_effort: none` |

OpenAI direkt: `gpt-6-luna`, `gpt-6-sol`, `gpt-5.1` (`-2025-11-13`), `gpt-5.2` (`-2025-12-11`), `gpt-5.4` (`-2026-03-05`), `gpt-4.1` (`-2025-04-14`), `gpt-4.1-mini` (`-2025-04-14`), `gpt-4.1-nano` (`-2025-04-14`), `gpt-4o` (`-2024-08-06`, `-2024-11-20`) och `gpt-4o-mini` (`-2024-07-18`). Inga andra datumändelser är tillåtna.

### Groq (aktuellt val)

`qwen/qwen3.8-27b` med `GROQ_API_KEY`, reasoning av via `reasoning_effort: none` och strikt JSON-schema. Groqs gratisnivå begränsar per organisation (fler nycklar ger inte mer), enligt tredjepartssammanställningar 2026-10-05 eftersom Groqs egen sida inte kunde hämtas: **30 anrop/min, 1 000 anrop/dygn, 8 000 token/min och 200 000 token/dygn**. Kontrollera de exakta värdena för ditt konto under console.groq.com → Settings → Limits. Token per minut begränsar först: en lektionsdel är några tusen token, en kort fråga några hundra. Mio har `MIO_REQUESTS_PER_MINUTE=20` och ingen egen dagsgräns; Groqs 429 visas som kvotfel utan automatiskt omförsök. Heldagsanalys ryms inte i 200 000 token/dygn.

### NVIDIA NIM (tidigare val)

**Observerat 2026-10-05:** efter publicering svarade NIM:s gratisnivå inte inom Mios 40 s-gräns på en enkel fråga från telefonen, och användarens direkta prov mot NIM fick inget svar. Gatewayn bytte därför till Groq. Orsaken (kö på delad gratiskapacitet eller schema-vägen) är inte fastställd.

Granskat 2026-10-05. NIM:s värdade API på `https://integrate.api.nvidia.com/v1` är OpenAI-kompatibelt. Gratisnivån har **40 anrop per minut per API-nyckel**, delat mellan alla modeller, och ingen dagskvot. Mio sätter därför `MIO_REQUESTS_PER_MINUTE=20` och ingen daglig gräns.

- **DeepSeek V4.1 Flash** tänker om inte båda mallflaggorna stängs av. Mio skickar dem alltid och avvisar svar med `reasoning_content`. Snabb (~1 s till första token).
- **GLM 5.3, GLM 5.3 Flash och Kimi K3 är spärrade**: de kan inte stänga av tänkandet (Z.ai svarar HTTP 400 på `disabled`; K3 saknar instant-läge).
- **Ej verifierat:** att NIM tillämpar `response_format.json_schema` strikt (NIM:s egna exempel använder `nvext.guided_json`), och svensk kvalitet. Det avgörs av det syntetiska modellprovet nedan. Mio validerar ändå varje svar lokalt.

Källor: [NIM-modellsida](https://build.nvidia.com/deepseek-ai/deepseek-v4.1-flash), [NIM API-referens](https://docs.api.nvidia.com/nim/reference/deepseek-ai-deepseek-v4-1-flash), [Z.ai om GLM 5.3 Flash](https://docs.z.ai/guides/vlm/glm-5.3-flash), [Kimi K3](https://docs.together.ai/docs/kimi-k3-quickstart).

### Övriga källor

Groq: [strikt utdata](https://console.groq.com/docs/structured-outputs), [reasoning](https://console.groq.com/docs/reasoning). OpenAI: [modellsidor](https://developers.openai.com/api/docs/models/gpt-6-luna) och [modellguiden](https://developers.openai.com/api/docs/guides/latest-model). Gemini: [strukturerat utdata](https://ai.google.dev/gemini-api/docs/generate-content/structured-output), [thinking](https://ai.google.dev/gemini-api/docs/thinking). Anthropic: [strukturerade svar](https://platform.claude.com/docs/en/build-with-claude/structured-outputs). Vercel: [katalog](https://ai-gateway.vercel.sh/v1/models). OpenRouter: [strikt schema](https://openrouter.ai/docs/guides/features/structured-outputs), [routning](https://openrouter.ai/docs/guides/routing/provider-selection). Mistrals [`none`](https://docs.mistral.ai/studio/conversations/reasoning) är minimalt dolt tänkande, inte OFF.

## Task-profiler

`MIO_AI_PROVIDER` och `MIO_AI_MODEL` gäller alla uppgifter. Valfri `MIO_AI_TASK_PROFILES` är JSON med enbart `ask`, `everyday` och `lesson`:

```json
{"ask":{"provider":"nvidia","model":"deepseek-ai/deepseek-v4.1-flash"},"lesson":{"provider":"gemini","model":"gemini-2.5-flash-lite"}}
```

- En saknad uppgift ärver global konfiguration.
- Varje provider använder sin egen Secret; en nyckel återanvänds aldrig för en annan provider.
- Ett ogiltigt task-objekt spärrar den uppgiften. Ogiltig JSON eller okända toppnycklar spärrar alla.
- `MIO_OPENAI_MODEL` läses bara som äldre namn för OpenAI när `MIO_AI_MODEL` saknas.

Tillåtna `adapterOptions`: OpenRouter `dataCollection` (`allow`/`deny`) och `zeroDataRetention`; Vercel `zeroDataRetention` och `disallowPromptTraining`; Anthropic `serviceTier` (`auto`/`standard_only`). Övriga: inga. Alternativen kan aldrig ändra reasoning, temperatur, schema, verktyg, credentials eller fallback.

## Egen endpoint

Använd `custom` med exakt modell-ID, `MIO_AI_BASE_URL` (HTTPS, utan credentials, query, fragment, egen port eller lokal/IP-värd) och `MIO_AI_API_KEY`. Sätt `MIO_AI_COMPATIBILITY=chat-none-strict` endast när endpointen bevisligen stöder Chat Completions med `reasoning_effort:none`, temperatur 0 och `response_format.json_schema.strict:true`. Ett task-override behöver samma `baseURL`/`compatibility`. Inga redirects följs. Operatörens försäkran är inte modellverifiering.

## Separat godkänt syntetiskt modellprov

Gör detta först efter godkänd publicering och lyckad modellfri status. Godkänn exakt profil och högst tre anrop separat; de kan kosta pengar. Vänta minst 60 s mellan anropen och skicka inte om automatiskt.

1. **Fråga** `/v1/ask`: `{"question":"Vad är 2 + 2? Svara kort på svenska.","context":[]}`. Förvänta ett kort korrekt svar utan lokala åtgärder.
2. **Vardag** `/v2/analyze`:

   ```json
   {"mode":"everyday","timeZone":"Europe/Stockholm","fragments":[{"id":"11111111-1111-4111-8111-111111111111:0","text":"I morgon klockan nio ska jag lämna tillbaka en bok.","occurredAt":"2026-10-03T12:00:00+02:00"}],"contextFragments":[],"priorDecisions":[],"contextLimited":false}
   ```

   Förvänta grundade käll-ID/citat och korrekt datum/tidszon. Tomma listor kan vara giltiga.
3. **Lektion** `/v1/lesson-notes`:

   ```json
   {"mode":"lesson","timeZone":"Europe/Stockholm","fragments":[{"id":"22222222-2222-4222-8222-222222222222:0","text":"En procent är en hundradel. Tjugo procent av femtio är tio. Läxa: öva två exempel i morgon efter skolan.","occurredAt":"2026-10-03T12:00:00+02:00"}]}
   ```

   Förvänta detaljerade avsnitt med exakta citat och ett läxförslag som kräver Ja.

Registrera tid, gatewayrelease, konfigurationsrevision, task, begärd och returnerad modell, HTTP/felkategori, tokenanvändning, latens och debitering. Spara inga nycklar, råa headers eller svarstexter. Positiva reasoning-token eller synliga thinking-block avvisas. Noll rapporterade reasoning-token bevisar inte ensamt att tänkandet är av.

## Utökningsgräns

`tasks.mjs` äger prompt, schema och domänvalidering; `model-profiles.mjs` exakta kontrakt; `adapters.mjs` nativeformat; `generation-execution.mjs` routing, deadline och kvot. Streaming, modellverktyg, multimodala anrop, STT/TTS och embeddings ingår inte.
