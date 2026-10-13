# Mios privata AI-gateway

Gatewayen tar emot frågor, vardagsutdrag och lektionsdelar från appen och skickar dem till Groq. Den kör på din CachyOS-dator bredvid [Pianissimo](../transcription-server/README.md) och nås bara via Tailscale. Ljud skickas aldrig hit och ingen text sparas: den enda filen gatewayen skriver är en räknare med heltal.

Beslut 2026-10-11: gatewayen flyttade från Cloudflare till datorn, och Groq är enda leverantör. Den gamla Cloudflare-koden finns kvar i Git-historiken.

## Installera på datorn (cirka 10 minuter)

Installera [Pianissimo](../transcription-server/README.md) först. Hela ordningen står i [README](../README.md#kom-igång).

1. Skapa en gratis Groq-nyckel på <https://console.groq.com/keys>.
2. Kör från repot, som din vanliga användare:

   ```bash
   ./server/install.sh
   ```

   Skriptet installerar `nodejs`, `qrencode`, `tailscale`, `curl` och `rsync` med pacman om de saknas. Det skapar tjänstekontot `mio-gateway`, frågar efter Groq-nyckeln (den syns inte när du klistrar in), startar systemd-tjänsten och kör `tailscale serve --bg --https=8443 http://127.0.0.1:8787`.
3. Para telefonen:

   ```bash
   mio-pair
   ```

   Skanna QR-koden i Mio under Inställningar → Dator. `mio-pair --text` visar samma värden som text om kameran inte fungerar. Är Pianissimo inte installerat säger `mio-pair` det, och koden innehåller då bara AI. Kör den igen när Pianissimo är installerat och tryck **Para om med QR-kod** i Mio.

Kör `./server/install.sh` igen för att uppdatera; nyckel, token och räknare behålls. `./server/install.sh --ny-groq-nyckel` byter Groq-nyckeln utan att telefonen behöver paras om.

### Var saker ligger

| Sökväg | Innehåll |
|---|---|
| `/opt/mio-gateway/src/` | Gatewayens kod (bara `*.mjs`), ägd av root |
| `/etc/mio-gateway/gateway.env` | Groq-nyckel, gatewaytoken och gränser; root, 0600 |
| `/var/lib/mio-gateway/counters.json` | Minut- och dygnsräknare (bara heltal); 0600 |
| `/etc/systemd/system/mio-gateway.service` | Härdad tjänst: ingen root, skrivskyddat system, 384 MB minne |
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
| `MIO_REQUESTS_PER_MINUTE` | 3 (högst 60) | Gratisnivån tillåter 8 000 token per minut; en lektionsdel är några tusen token |
| `MIO_TOKENS_PER_DAY` | 190 000 (högst 1 000 000, tomt = av) | Gratisnivån tillåter 200 000 token per dygn; marginalen täcker avrundning |
| `MIO_REQUESTS_PER_DAY` | tomt (av) | Valfri extra gräns per UTC-dygn |
| `MIO_LESSON_INTERVAL_SECONDS` | 60 (60–3600) | Minsta tid mellan lektionsdelar |

Räknarna sparas i `counters.json` efter varje reservation, så en omstart nollställer dem inte. Tokenräknaren använder Groqs rapporterade förbrukning. Är dygnets tokens slut svarar gatewayen 429 `local_token_limit` med `Retry-After` till nästa UTC-midnatt, och appen visar när AI fungerar igen. Groqs egna 429-svar skickas vidare med deras `Retry-After`; gatewayen försöker aldrig själv igen.

Varje anrop kräver temperatur 0, `reasoning_effort: "none"`, strikt JSON-schema och inga verktyg. Svar med resonemang, verktygsanrop, refusal eller avkortning avvisas, och varje svar valideras innan appen får det. Ingen tyst reserv-modell eller reserv-leverantör finns.

### Lägga till en leverantör senare

`src/model-profiles.mjs` har en leverantörssöm. En ny leverantör (till exempel Anthropic) kräver en post i `PROVIDERS`, en granskad modell i `reviewedModel` med dokumentationskällor, en adapter i `src/adapters.mjs` om API-formatet skiljer sig, och en nyckel i `gateway.env`. Ett leverantörsprefix eller en OpenAI-kompatibel adress räcker aldrig som bevis.

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

Node 26.10 eller senare i 26-serien. Gatewayen har inga beroenden utöver Node.

```bash
cd server && npm ci --ignore-scripts && npm test
```

Testerna använder en syntetisk Groq-transport; ingen nyckel eller riktig modelltrafik behövs. Ett riktigt prov mot Groq med syntetisk svensk text görs först när gatewayen kör på datorn.
