# Mios privata AI-gateway

Gatewayen tar emot frågor, vardagsutdrag och lektionsdelar från appen och skickar dem till en granskad AI-modell, som standard Groq. Den är ett enda Rust-program (`mio-gateway`) utan Node eller annan körmiljö. Den kör på din CachyOS-dator bredvid [Pianissimo](../transcription-server/README.md) och nås bara via Tailscale. Ljud skickas aldrig hit och ingen text sparas: den enda filen gatewayen skriver är en räknare med heltal.

Beslut 2026-10-11: gatewayen flyttade från Cloudflare till datorn. Beslut 2026-11-17: fler leverantörer kan väljas per uppgift i [Mio Kontroll](../control/README.md), men bara granskade par av leverantör och modell (se [Leverantörer](#leverantörer)). Beslut 2026-11-16: gatewayen skrevs om från Node till Rust med samma beteende mot appen. Den gamla Cloudflare- och Node-koden finns kvar i Git-historiken.

## Installera på datorn (cirka 10 minuter)

Installera [Pianissimo](../transcription-server/README.md) först. Hela ordningen står i [README](../README.md#kom-igång).

1. Skapa en gratis Groq-nyckel på <https://console.groq.com/keys>.
2. Kör från repot, som din vanliga användare:

   ```bash
   ./server/install.sh
   ```

   Skriptet installerar `rust`, `qrencode`, `tailscale` och `curl` med pacman om de saknas och bygger gatewayen med `cargo` (första gången några minuter). Det skapar tjänstekontot `mio-gateway`, frågar efter Groq-nyckeln (den syns inte när du klistrar in), startar systemd-tjänsten och kör `tailscale serve --bg --https=8443 http://127.0.0.1:8787`.
3. Para telefonen:

   ```bash
   mio-pair
   ```

   Skanna QR-koden i Mio under Inställningar → Parning. `mio-pair --text` visar samma värden som text om kameran inte fungerar. Är Pianissimo inte installerat säger `mio-pair` det, och koden innehåller då bara AI. Kör den igen när Pianissimo är installerat och tryck **Para om med QR-kod** i Mio.

Kör `./server/install.sh` igen för att uppdatera; nyckel, token och räknare behålls. `./server/install.sh --ny-groq-nyckel` byter Groq-nyckeln utan att telefonen behöver paras om; bara nyckelraden i `gateway.env` ändras, så gränser, port och uppgiftsprofiler du ställt in finns kvar. Med `--nyckel-pa-stdin` läser skriptet nyckeln från stdin i stället för att fråga (det är så [Mio Kontroll](../control/README.md) kör det); utan valet beter det sig som förut.

### Var saker ligger

| Sökväg | Innehåll |
|---|---|
| `/opt/mio-gateway/mio-gateway` | Gatewayen (ett program), ägd av root. Har du en äldre Node-installation tar skriptet bort `/opt/mio-gateway/src/` |
| `/etc/mio-gateway/gateway.env` | Groq-nyckel, gatewaytoken och gränser; root, 0600 |
| `/var/lib/mio-gateway/counters.json` | Minut- och dygnsräknare (bara heltal); 0600 |
| `/etc/systemd/system/mio-gateway.service` | Härdad tjänst: ingen root, skrivskyddat system, högst 128 MB minne (använder cirka 6 MB) |
| `/usr/local/bin/mio-pair` | Visar QR-koden för parning; sparar ingenting |

Felsökning: `systemctl status mio-gateway`, `journalctl -u mio-gateway -n 50` och `curl http://127.0.0.1:8787/health`. Loggen innehåller aldrig frågor, svar, nycklar eller tokens.

## Parningskoden

QR-koden innehåller kompakt JSON:

```json
{"mio":1,"aiURL":"https://dator.tailnet.ts.net:8443","aiToken":"…","transcriptionURL":"https://dator.tailnet.ts.net","transcriptionToken":"…"}
```

`transcriptionURL` och `transcriptionToken` är `null` när Pianissimo inte är installerat än. Appen sparar tokens i nyckelringen. Koden visas bara i terminalen; stäng den efteråt.

## Groq och gränser

| Värde | Inställning | Varför |
|---|---|---|
| Modell | `qwen/qwen3.8-27b` | Enda granskade modellen: stöder `reasoning_effort: "none"` och strikt JSON-schema |
| `MIO_REQUESTS_PER_MINUTE` | 10 (högst 60) | Stoppar bara en klient som skenar; det är tokengränsen per minut som styr |
| `MIO_TOKENS_PER_MINUTE` | 8 000 (tomt eller 0 = av) | Gratisnivåns gräns. Groq räknar prompt **plus reserverat svar** (`max_tokens`), så gatewayen anpassar varje anrop till den |
| `MIO_TOKENS_PER_DAY` | 190 000 (högst 1 000 000, tomt = av) | Gratisnivån tillåter 200 000 token per dygn; marginalen täcker avrundning |
| `MIO_REQUESTS_PER_DAY` | tomt (av) | Valfri extra gräns per UTC-dygn |
| `MIO_LESSON_INTERVAL_SECONDS` | 60 (60–3600) | Minsta tid mellan lektionsdelar |

Räknarna sparas i `counters.json` efter varje reservation, så en omstart nollställer dem inte. Tokenräknaren använder Groqs rapporterade förbrukning. Är dygnets tokens slut svarar gatewayen 429 `local_token_limit` med `Retry-After` till nästa UTC-midnatt, och appen visar när AI fungerar igen.

**Storlek per anrop (2026-11-15).** På gratisnivån släpper Groq bara igenom ett anrop om prompt + `max_tokens` ryms i minutens 8 000 token; annars svarar Groq 413, och det hjälper aldrig att vänta. Gatewayen uppskattar därför promptens storlek (tre UTF-8-byte per token, vilket överskattar svensk text) och krymper svarsutrymmet så att anropet ryms. Ryms inte ens ett kort svar avvisas anropet direkt med 413 `provider_request_too_large`, utan att kvot dras, och appen delar då underlaget i mindre delar. Samma kod används om Groq ändå svarar 413. Större vardagsbatcher (`analysis-backlog-v1`) erbjuds bara när minutgränsen är av eller minst 20 000 token.

**Ett nytt försök (2026-11-15).** Gatewayen gör ett enda nytt försök med exakt samma anrop när Groq svarar 429 med en väntetid på högst 20 sekunder, eller vid ett tillfälligt serverfel eller nätfel hos leverantören, och bara om det ryms i anropets 40 sekunder. Längre väntetider skickas vidare till appen med Groqs `Retry-After`. Modell och parametrar ändras aldrig mellan försöken.

Varje anrop kräver resonemang av (hos Groq `reasoning_effort: "none"`), strikt JSON-schema och inga verktyg, och temperatur 0 för varje modell som tar emot parametern. Svar med resonemang, verktygsanrop, refusal eller avkortning avvisas, och varje svar valideras innan appen får det. Ingen tyst reserv-modell eller reserv-leverantör finns.

**Validering per förslag (2026-11-15).** Svarets form är allt eller inget. Innehållet granskas däremot per förslag: saknar ett förslag ett citat som finns i källtexten, har ett ogiltigt datum eller bryter mot reglerna för ersättning av ett tidigare beslut tas just det förslaget bort och resten av svaret behålls. Ett citat som bara skiljer sig i skiftläge, blanksteg eller skiljetecken ersätts med den exakta källtexten, och ett klockslag utan tidszon tolkas i anropets tidszon. En lektionssektion utan giltigt citat avvisar fortfarande hela delen, eftersom sektionerna är själva anteckningen.

## Leverantörer

Varje uppgift (`ask`, `everyday`, `lesson`) kör ett granskat par av leverantör och modell, valt på datorn: `MIO_AI_PROVIDER` och `MIO_AI_MODEL` för alla, och `MIO_AI_TASK_PROFILES` för en enskild uppgift, till exempel `{"lesson":{"provider":"anthropic","model":"claude-haiku-5-5"}}`. Ingen automatisk reserv: en uppgift utan granskad modell eller nyckel svarar `task_configuration_invalid`. `mio-gateway granskade-modeller` listar paren.

| Leverantör | Modell | Nyckel i `gateway.env` | Läge |
|---|---|---|---|
| Groq | `qwen/qwen3.8-27b` | `GROQ_API_KEY` | Granskad. Gratisnivå, se nedan |
| Anthropic | `claude-haiku-5-5` | `ANTHROPIC_API_KEY` | Granskad 2026-11-17. Tänkandet av, schemat via `output_config.format`, **utan temperatur** (Anthropic vägrar parametern; `/v2/status` visar `"temperature": "provider-default"`). Ingen gratisnivå: 0,10 USD per miljon token in, 0,50 ut |
| Mistral | `mistral-small-2603`, `mistral-medium-3-5` | `MISTRAL_API_KEY` | Kandidat: strikt schema är inte bekräftat. Valbar efter ett godkänt prov (Prova i panelen) |
| NVIDIA NIM | `qwen/qwen3.8-27b` | `NVIDIA_API_KEY` | Kandidat av samma skäl, valbar efter ett godkänt prov |

Cloudflare Workers AI är avböjt: dess JSON-läge garanterar inte schemat. Detaljer och källor i [besluten](../docs/DECISIONS.md).

Tokenbudgeten per minut gäller per leverantör: `MIO_TOKENS_PER_MINUTE` för Groq (8 000 om den saknas) och `MIO_TOKENS_PER_MINUTE_ANTHROPIC`, `_MISTRAL` och `_NVIDIA` för de andra (ingen gräns om den saknas; 2 000–1 000 000).

### Lägga till en leverantör

`src/model_profiles.rs` har leverantörssömmen. En ny leverantör kräver en post i `PROVIDERS`, en modell i `REVIEWED_MODELS` (eller `CANDIDATE_MODELS` tills den är provad) med dokumentationskällor och hur resonemanget stängs av, en adapter i `src/adapters.rs` om API-formatet skiljer sig, syntetiska tester utan nät (svar, avvisning, avkortning, för stort anrop, fel) och en nyckel i `gateway.env`. Panelens lista över tillåtna nycklar (`control/core/src/settings.rs`) följer `PROVIDERS`; ett test håller dem i takt. Ett leverantörsprefix eller en OpenAI-kompatibel adress räcker aldrig som bevis.

### Kommandon för Mio Kontroll

Kontrollpanelen ([`control/`](../control/README.md)) använder tre kommandon i samma program. `kontrollera-konfiguration` och `granskade-modeller` skriver ingenting och skickar inget till en leverantör.

| Kommando | Gör |
|---|---|
| `mio-gateway kontrollera-konfiguration` | Läser en `gateway.env` på stdin på samma sätt som systemd och tjänsten och svarar med JSON: om filen går att starta med, och leverantör, modell och eventuellt felkod per uppgift. Svaret innehåller aldrig nyckel eller token. Avslutar med fel om gatewayen skulle vägra starta eller om en uppgift saknar granskad modell eller nyckel |
| `mio-gateway prova <leverantör> <modell>` | Riktig trafik, bara när du trycker Prova i panelen: ett påhittat svenskt anrop per uppgift med nyckeln i `gateway.env` på stdin, och JSON med resultatet per uppgift. En kandidat som klarar alla tre blir valbar (`MIO_APPROVED_CANDIDATES`, skrivs av panelens hjälpare) |
| `mio-gateway granskade-modeller` | Leverantörerna och de granskade paren av leverantör och modell som JSON, med variabeln för varje nyckel och källorna för granskningen |

## API

Alla genereringsrutter kräver `Authorization: Bearer <gatewaytoken>` och JSON utan Content-Encoding. Okända fält avvisas.

| Rutt | Indata och validerat resultat |
|---|---|
| `GET /health` | `{"status":"ok"}`, utan token; provar bara processen |
| `GET /v1/status`, `GET /v2/status` | Konfiguration, kapacitet och `configurationRevision`; inget modellanrop, ingen kvot |
| `POST /v1/ask` | Fråga + valda utdrag → endast `answer` |
| `POST /v1/analyze` | Äldre analyskontrakt → grundade candidates/highlights/uncertainties |
| `POST /v2/analyze` | Vardagsutdrag med kontext → candidates med `replacesID` |
| `POST /v1/lesson-notes` | Högst 3 500 byte källtext → plan/task-kandidater och detaljerade sections med citat |

`/v2/status` svarar med `quota: {limit, remaining, resetAt, unit}` där `unit` är `tokens` eller `requests`, eller `quota: null` utan dygnsgräns. Klienter skickar den observerade revisionen som `X-Mio-Configuration-Revision`; en ändrad konfiguration ger 409 `configuration_changed` före kvot och modellanrop.

Gränser: fråga högst 2 000 byte, sex utdrag och 10 000 byte kontext. Analys 1–16 fragment och högst 16 000 byte text. Body högst 40 000 byte med 5 s deadline. Hela anropet högst 40 s. Två samtidiga anrop. Svar från Groq högst 65 536 byte.

## Verifiera utan modelltrafik

Rust 1.88 eller senare. Beroendena är låsta i `Cargo.lock`.

```bash
cd server && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings
```

Testerna använder en syntetisk Groq-transport; ingen nyckel eller riktig modelltrafik behövs. `tests/parity.rs` spelar upp cirka 2 600 indata och 86 hela HTTP-utbyten som spelades in från den sista Node-versionen (`tests/golden/node-parity.json`) och kräver samma svar, inklusive exakt samma bytes till modellen. Ett riktigt prov mot Groq med syntetisk svensk text görs först när gatewayen kör på datorn.
