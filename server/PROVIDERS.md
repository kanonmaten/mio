# Byta text-AI-leverantör och modell

Denna guide gäller arbetskopians serverprofiler och [granskade kontraktsmatris](../docs/LEVERANTORSKONTRAKT.md). **Publicera först kompatibel gatewaykod efter uttrycklig begäran.** Den äldre OpenAI-bundeln blir inte en Groq-gateway genom variabler. Modellbyte i en redan kompatibel katalog kräver därefter ingen klientmodellväljare eller ny IPA; konfigurationsändring kräver ny granskning/aktivering i appen.

## Presets och tillåtna modeller

| `MIO_AI_PROVIDER` | Leverantörshemlighet | Kataloggräns |
|---|---|---|
| `groq` | `GROQ_API_KEY` | Endast `qwen/qwen3.8-27b` |
| `openai` | `OPENAI_API_KEY` | Exakt OpenAI-lista med uttryckliga aliases/snapshots i matrisen |
| `vercel` | `VERCEL_AI_GATEWAY_API_KEY` | Granskade `openai/`-aliases; enbart OpenAI-routning |
| `openrouter` | `OPENROUTER_API_KEY` | Granskade OpenAI 4.x-ID:n; ingen providerfallback |
| `gemini` | `GEMINI_API_KEY` | Native `gemini-2.5-flash` och `gemini-2.5-flash-lite` |
| `anthropic` | `ANTHROPIC_API_KEY` | Exakta Claude 4.5-aliases/snapshots i matrisen |
| `mistral`, `deepseek` | `MISTRAL_API_KEY`, `DEEPSEEK_API_KEY` | Samtliga profiler spärrade tills obligatoriska kontrakt etablerats |
| `custom` | `MIO_AI_API_KEY` | Exakt ID och explicit operatörskontrakt enligt nedan |

Modellåtkomst, nyckel, saldo och svensk kvalitet är inte verifierade genom denna tabell. Ingen godtycklig snapshot, nytt familjeprefix eller gatewayprefix är stödbevis. Obligatorisk policy är reasoning OFF, temperatur 0 och strikt schema; okända/incompatible profiler avvisas före kvot/modelltrafik. Det finns ingen tyst fallback.

## Globala värden och task-profiler

Globala `MIO_AI_PROVIDER` och `MIO_AI_MODEL` gäller när en task saknar override. `MIO_AI_MODEL` har företräde; `MIO_OPENAI_MODEL` läses endast som äldre konfigurationsnamn för OpenAI när det nya saknas. Det är aldrig request-time fallback.

Valfri `MIO_AI_TASK_PROFILES` är JSON med enbart `ask`, `everyday`, `lesson`. Ett exempel på explicit skild routing:

```json
{"ask":{"provider":"openai","model":"gpt-4.1-mini"},"everyday":{"provider":"groq","model":"qwen/qwen3.8-27b"},"lesson":{"provider":"gemini","model":"gemini-2.5-flash-lite"}}
```

Exemplet väljer tre konton och är ingen aktiveringsrekommendation. Varje provider behöver sin egen serverägda Secret; global leverantörsnyckel återanvänds inte för annan provider. Saknad override ärver global konfiguration. Ett ogiltigt task-objekt spärrar den tasken, medan ogiltig JSON/okända toppnycklar spärrar hela profiluppsättningen. Status anger en fast `configurationError`, utan credentialvärden. `adapterOptions` måste följa matrisens exakta whitelist; endpoint/compatibility-fält tillåts endast för custom-profiler.

1. Stäng av AI-tolkning och avsluta/avbryt pågående arbete.
2. Granska exakt modell och kontrakt i matrisen. Lägg nyckeln i vald providers Secret, aldrig telefon/Git/chatt.
3. Uppdatera globala värden och eventuell task-JSON i Node-miljön eller Cloudflare Variables and Secrets. Node kräver processomstart; Worker läser requestens aktuella miljö.
4. Inför Wrangler-publicering: jämför samtliga explicita `vars` i `wrangler.jsonc` med Dashboard. `keep_vars:true` bevarar extra värden men skyddar inte mot explicit motstridiga värden i filen.
5. Efter godkänd ändring: använd modellfri **Testa text-AI-anslutning**, kontrollera skyddad `/v2/status`, release/task-revision/kvot. Modellstatus kan vara granskad utan fungerande providercredentials.
6. En fråga måste förhandsgranskas igen; löpande analys återaktiveras manuellt. 409 skickar inte automatiskt om en POST.
7. Verkligt modellprov kräver separat godkännande av [exakt syntetiskt material](../docs/LEVERANTORSKONTRAKT.md#separat-godkänt-syntetiskt-modellprov).

Behåll domän, gatewaytoken, D1 och Access vid vanliga modellbyten. Credentialrotation är separat autentisering; konfigurationsrevisionen innehåller ingen secretfingerprint. Återgå endast till en kompatibel kod/konfigurationskombination. Den gamla OpenAI-koden med Groq-variabler är ingen fungerande rollback.

## Egen endpoint

Använd `custom`, eget exakt modell-ID, HTTPS `MIO_AI_BASE_URL` och `MIO_AI_API_KEY`. Sätt `MIO_AI_COMPATIBILITY=chat-none-strict` enbart efter granskning av verkligt Chat Completions-kontrakt med `reasoning_effort:none`, temperatur 0 och `response_format.json_schema.strict:true`. Ett custom task-override behöver motsvarande explicit `baseURL`/`compatibility` för sin modell. Inga godtyckliga headers, credentials i URL, redirects, query/fragment, egen port eller lokala/IP-värdar tillåts. Operatörsförsäkran är inte automatisk modellverifiering.

## Kvot och fel

Alla fyra genereringsrutter delar högst **100 anrop per UTC-dygn**, normalt sex/minut enligt medföljande driftkonfiguration och två samtidiga anrop per process/Worker-instans. Utan explicit minutinställning använder Groq en/minut. Cloudflare använder befintliga beständiga D1-räknare; Node använder processminne. Misslyckat eller osäkert försök kan ha förbrukat kvot. Ingen unsafe refund, automatisk text-AI-retry eller dagsgränshöjning finns.

Lektionsdelar har högst 3500 byte källtext och 3000 output-tokens; frågor högst 1000 output-tokens. Normalt minst 60 sekunder mellan lektionsanrop (60–3600 kan konfigureras). Frågor och vardagsanalys delar samma pott, så 100/dag räcker inte för kontinuerlig heldagsanalys. Vid 429 visar appen lokal minut/dag/concurrency eller providerkvot, väntetid när känd och manuell återaktivering. Status kan visa okänd kvarvarande kvot; restarbete är aldrig reserverad kapacitet.

Gatewayauth, providercredentials/konto, modell/parametrar, refusal/truncation, kvot, budgetlager, deadline och transport har fasta skilda felkategorier. Upstreamtext, keys, fulla URL:er och råa felobjekt exponeras inte. [Serverkontraktet](README.md) och [Cloudflare-guiden](cloudflare/GROQ_ACCESS.md) beskriver kontroll- och releaseförfarandet.
