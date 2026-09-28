# Byta AI-leverantör och modell

Gäller den nya arbetskopian från 2026-09-28. **Gatewaykoden måste publiceras först.** Den redan publicerade äldre gatewayen kan inte byta till Groq genom enbart variabler. Det nya lektionsgränssnittet behöver också en ny appbuild. Därefter kräver vanliga modellbyten ingen ny IPA.

## Enkelt: Groq i Cloudflare

1. Stäng av AI-tolkningen i Mio under bytet.
2. Öppna **Workers & Pages → mio-private-gateway → Settings → Variables and Secrets** i [Cloudflare](https://dash.cloudflare.com/).
3. Lägg till/ändra följande vanliga textvariabler:

   | Namn | Värde |
   |---|---|
   | `MIO_AI_PROVIDER` | `groq` |
   | `MIO_AI_MODEL` | `qwen/qwen3.8-27b` |
   | `MIO_LESSON_INTERVAL_SECONDS` | `60` |
   | `MIO_REQUESTS_PER_MINUTE` | `1` |
   | `MIO_REQUESTS_PER_DAY` | `100` |

4. Lägg till **Secret** med namnet `GROQ_API_KEY` och din Groq-nyckel som värde. Den ska inte skrivas i appen, Git eller chatten. Lämna `MIO_GATEWAY_TOKEN` oförändrad.
5. Spara och publicera konfigurationen. Kontrollera `/health`, men kom ihåg att det inte gör något modellprov.
6. I Mio används samma serveradress och gatewaytoken. Skicka först en liten syntetisk fråga med sändningsgodkännande. Aktivera sedan AI-tolkningen och prova en kort lektion.

Reasoning är av, temperaturen är 0 och svar begärs med strikt JSON-schema automatiskt. Det är inte inställningar du behöver hitta i appen eller Groqs Playground. Playground-inställningar påverkar inte Mios API-anrop.

`MIO_AI_MODEL` har företräde framför det äldre `MIO_OPENAI_MODEL`. Den gamla variabeln läses endast när leverantören är OpenAI och den nya saknas. Rensa gärna bort den gamla modellvariabeln för tydlighet. Gamla API-hemligheter används inte när en annan leverantör valts.

**Vid senare Wrangler-publicering:** variabler i `wrangler.jsonc` kan ersätta Dashboard-värden. Uppdatera därför de icke-hemliga värdena i den filen till ditt val före nästa kodpublicering. API-nycklar ska fortsatt vara Secrets, aldrig läggas i filen.

## Presets och tillåtna modeller

Tabellen visar den implementerade kompatibilitetskatalogen, inte godkända riktiga modellprov. Modellåtkomst och leverantörens aktuella utbud måste provas på ditt konto. Okända modeller stoppas lokalt med HTTP 422 före modelltrafik.

| `MIO_AI_PROVIDER` | Hemlighet | Modeller i katalogen |
|---|---|---|
| `groq` | `GROQ_API_KEY` | `qwen/qwen3.8-27b` |
| `openai` | `OPENAI_API_KEY` | `gpt-6-luna`, `gpt-6-sol`, `gpt-5.1`, `gpt-5.2`, `gpt-5.4`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `gpt-4o`, `gpt-4o-mini`; även datumversioner av dessa |
| `vercel` | `VERCEL_AI_GATEWAY_API_KEY` | Samma OpenAI-modeller med prefix `openai/`; routning begränsas till OpenAI |
| `openrouter` | `OPENROUTER_API_KEY` | Samma OpenAI-modeller med prefix `openai/`; kräver parameterstöd, endast OpenAI, utan leverantörsfallback |
| `gemini` | `GEMINI_API_KEY` | `gemini-2.5-flash`, `gemini-2.5-flash-lite` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5`, `claude-sonnet-4-5`, `claude-opus-4-5`; även deras datumversioner |
| `mistral` | `MISTRAL_API_KEY` | `mistral-small-latest`, `mistral-medium-latest`, `mistral-large-latest` |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-flash`, `deepseek-v4-pro` via Responses |
| `custom` | `MIO_AI_API_KEY` | Eget modell-ID, med uttryckligt kompatibilitetskontrakt nedan |

Leverantörsstöd betyder inte att varje modell på plattformen är tillåten. Exempelvis nekas GPT-6 Astra, Groqs GPT-OSS och Gemini Pro/3 eftersom katalogen inte kan uppfylla kravet på helt avstängd reasoning. Katalogen kan utökas efter dokumentationsgranskning och modellprov. Ingen fallback till vanligt JSON-läge eller en annan modell finns.

### Egen kompatibel endpoint

Använd `MIO_AI_PROVIDER=custom`, `MIO_AI_MODEL=<exakt ID>`, `MIO_AI_BASE_URL=https://din-vard.example/v1` och hemligheten `MIO_AI_API_KEY`. Sätt dessutom `MIO_AI_COMPATIBILITY=chat-none-strict` **endast när du verifierat** att endpointen verkligen stöder Chat Completions, `reasoning_effort: none`, temperatur 0 och `response_format.json_schema.strict: true` för modellen. Detta är operatörens kompatibilitetsförsäkran, inte automatisk upptäckt av modellförmågor. En server som tyst ignorerar parametrar går inte att upptäcka säkert från ett enda korrekt svar.

HTTPS krävs, utan URL-lösenord, nycklar i query, fragment eller egen port. Inga redirects följs. Endpointen kan ta emot din text och nyckel; välj bara en betrodd värd. Servern avvisar felaktiga svar och synliga reasoningfält/token, men kan inte granska leverantörens interna implementation.

## Förbrukning och väntetider

Alla anrop delar minut-/dygnskvoten. Cloudflare använder beständiga D1-räknare även efter omstart. Ett misslyckat modellförsök räknas också. `MIO_LESSON_INTERVAL_SECONDS` tillåter 60–3600 sekunder och skickas med lektionssvaret för nästa del; första intervallet i en ny app-process är minst 60 sekunder. Enskilda frågor omfattas av serverkvoten men inte appens lektionskö.

Lektionsanrop innehåller högst 3500 byte källtext och begär högst 3000 output-tokens; enskilda frågor högst 1000 output-tokens. Schema och systemprompt tar också tokens. Detta är inte en exakt tokenbudget eller garanti mot kvotfel. Groqs fria Qwen-kvot är vid dokumentationskontrollen 8000 tokens/minut och 200000/dygn. Andra anrop på kontot delar kvoten. Höj inte takten utan mätning. [Groqs kvoter](https://console.groq.com/docs/rate-limits).

Vid 429 visar Mio en väntetid från `Retry-After` (annars 60 sekunder), stoppar AI och kräver manuell fortsättning. Dagskvoten kan kräva längre väntan än den generella minutindikeringen. Färdiga lektionsdelar skickas inte igen. Inga automatiska omförsök, betalda reservmodeller eller månatliga kostnadslöften finns. Gratis hosting hos Vercel är inte samma sak som obegränsat gratis modell-API.

## API-kontrakt och granskade källor

Appen använder fortfarande `/v1/ask` och `/v1/analyze`. Nya detaljerade anteckningar använder `/v1/lesson-notes`, samma gatewayauth och kvotpott. Gatewayen använder Responses (OpenAI, Vercel, DeepSeek), Chat Completions (Groq, Gemini, OpenRouter, Mistral, custom) eller Messages (Anthropic). Alla svar valideras lokalt, även när leverantören redan erbjuder schemastyrd generering. Strikt schema garanterar struktur, inte fakta.

Granskade format: [Groq reasoning](https://console.groq.com/docs/api-reference), [Groq strikt schema](https://console.groq.com/docs/structured-outputs), [OpenAI Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), [Gemini-kompatibilitet](https://ai.google.dev/gemini-api/docs/openai), [Anthropic strukturerade svar](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [Mistral Chat](https://docs.mistral.ai/api/endpoint/chat), [DeepSeek Responses](https://api-docs.deepseek.com/api/create-response/), [DeepSeek thinking](https://api-docs.deepseek.com/guides/thinking_mode/), [Vercel Responses](https://vercel.com/docs/ai-gateway/sdks-and-apis/responses), [Vercel routing](https://vercel.com/docs/ai-gateway/models-and-providers/provider-options), [OpenRouter reasoning](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).

Varje vald leverantör och eventuell gateway har egna datavillkor och kontokrav. Mio skriver inga transkript till serverlogg/D1. `store: false` används på Responses-anrop; det är inte ett generellt löfte om att leverantören saknar annan lagring.
