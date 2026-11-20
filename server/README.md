# Mios privata AI-gateway

Gatewayen tar emot frågor, vardagsutdrag och lektionsdelar från appen och skickar dem till en granskad AI-modell, som standard Mistral (Groq fram till 2026-11-20). Den är ett enda Rust-program (`mio-gateway`) utan Node eller annan körmiljö. Den kör på din CachyOS-dator bredvid [Pianissimo](../transcription-server/README.md) och nås bara via Tailscale. Ljud skickas aldrig hit och ingen text sparas: gatewayen skriver bara två filer med siffror, en räknare för minut och dygn och en räknare för månadens användning.

Beslut 2026-10-11: gatewayen flyttade från Cloudflare till datorn. Beslut 2026-11-17: fler leverantörer kan väljas per uppgift i [Mio Kontroll](../control/README.md), men bara granskade par av leverantör och modell (se [Leverantörer](#leverantörer)). Beslut 2026-11-16: gatewayen skrevs om från Node till Rust med samma beteende mot appen. Den gamla Cloudflare- och Node-koden finns kvar i Git-historiken.

## Installera på datorn (cirka 10 minuter)

Installera [Pianissimo](../transcription-server/README.md) först. Hela ordningen står i [README](../README.md#kom-igång).

1. Skapa en Mistral-nyckel på <https://console.mistral.ai/api-keys> och stäng av träning på din API-data i Mistrals admin-konsol (se [Mistral](#mistral)).
2. Kör från repot, som din vanliga användare:

   ```bash
   ./server/install.sh
   ```

   Skriptet installerar `rust`, `qrencode`, `tailscale` och `curl` med pacman om de saknas och bygger gatewayen med `cargo` (första gången några minuter). Det skapar tjänstekontot `mio-gateway`, frågar efter Mistral-nyckeln (den syns inte när du klistrar in), startar systemd-tjänsten och kör `tailscale serve --bg --https=8443 http://127.0.0.1:8787`.

   Sist kör skriptet `mio-gateway prova` för båda Mistral-paren: ett påhittat svenskt anrop per uppgift för Small 4 och ett lektionsanrop för Large 4. Det är riktig trafik med din nyckel och kostar någon cent. Går båda igenom skrivs paren in som godkända och gatewayen startas om. Går ett prov inte igenom stannar skriptet med felkoden, och AI är av tills ett prov går igenom: kör `./server/install.sh --ny-mistral-nyckel` om nyckeln var fel, annars `./server/install.sh --prova-mistral` senare eller **Prova** i Mio Kontroll.
3. Para telefonen:

   ```bash
   mio-pair
   ```

   Skanna QR-koden i Mio under Inställningar → Parning. `mio-pair --text` visar samma värden som text om kameran inte fungerar. Är Pianissimo inte installerat säger `mio-pair` det, och koden innehåller då bara AI. Kör den igen när Pianissimo är installerat och tryck **Para om med QR-kod** i Mio.

Kör `./server/install.sh` igen för att uppdatera; nycklar, vald leverantör, token och räknare behålls, och inget prov körs. En befintlig Groq-installation står alltså kvar på Groq med samma token, så telefonen behöver inte paras om; du byter till Mistral i Mio Kontroll (lägg in nyckeln, tryck **Prova** för båda paren och välj dem per uppgift).

| Val | Gör |
|---|---|
| `--ny-mistral-nyckel` | Sätter Mistral-nyckeln. Bara raden `MISTRAL_API_KEY` ändras; token, gränser och uppgiftsprofiler står kvar. Är Mistral vald leverantör körs provet efteråt |
| `--ny-groq-nyckel` | Byter Groq-nyckeln på samma sätt. På en dator utan `gateway.env` skapas en Groq-konfiguration som förut |
| `--prova-mistral` | Kör Mistral-provet igen, till exempel efter ett misslyckat |
| `--nyckel-pa-stdin` | Läser nyckeln från stdin i stället för att fråga (det är så [Mio Kontroll](../control/README.md) kör det) |

### Var saker ligger

| Sökväg | Innehåll |
|---|---|
| `/opt/mio-gateway/mio-gateway` | Gatewayen (ett program), ägd av root. Har du en äldre Node-installation tar skriptet bort `/opt/mio-gateway/src/` |
| `/etc/mio-gateway/gateway.env` | Leverantörsnycklar, gatewaytoken, modeller och gränser; root, 0600 |
| `/var/lib/mio-gateway/counters.json` | Minut- och dygnsräknare (bara heltal); 0600 |
| `/var/lib/mio-gateway/usage.json` | Månadens token per uppgift och modell för kreditmätaren (bara siffror och modellnamn, innevarande och förra månaden); 0600. Har filen ett okänt `schemaVersion` skrivs den aldrig över |
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

**Ett nytt försök (2026-11-15).** Gatewayen gör ett enda nytt försök med exakt samma anrop när Groq svarar 429 med en väntetid på högst 20 sekunder, eller vid ett tillfälligt serverfel eller nätfel hos leverantören, och bara om det ryms i anropets tidsgräns (40 sekunder, 180 för en lektion på ett par som resonerar; efter väntan måste en femtedel av gränsen finnas kvar). Längre väntetider skickas vidare till appen med Groqs `Retry-After`. Modell och parametrar ändras aldrig mellan försöken.

Varje anrop kräver resonemang av (hos Groq och Mistral Small 4 `reasoning_effort: "none"`), JSON-schema och inga verktyg, och temperatur 0 för varje modell som tar emot parametern. Det enda undantaget är lektioner på Mistral Large 4, som får resonera (se [Mistral](#mistral)). Svar med resonemang där det ska vara av, verktygsanrop, refusal eller avkortning avvisas, och varje svar valideras innan appen får det. Ingen tyst reserv-modell eller reserv-leverantör finns.

**Validering per förslag (2026-11-15).** Svarets form är allt eller inget. Innehållet granskas däremot per förslag: saknar ett förslag ett citat som finns i källtexten, har ett ogiltigt datum eller bryter mot reglerna för ersättning av ett tidigare beslut tas just det förslaget bort och resten av svaret behålls. Ett citat som bara skiljer sig i skiftläge, blanksteg eller skiljetecken ersätts med den exakta källtexten, och ett klockslag utan tidszon tolkas i anropets tidszon. En lektionssektion utan giltigt citat avvisar fortfarande hela delen, eftersom sektionerna är själva anteckningen.

## Mistral

Beslut 2026-11-19 och 2026-11-20 ([besluten](../docs/DECISIONS.md#grillningen-2026-11-19)). Dokumentationen lästes igen 2026-11-20: [resonemang](https://docs.mistral.ai/inference/conversations/reasoning), [strukturerad utdata](https://docs.mistral.ai/inference/conversations/structured-output/custom), [Large 4](https://docs.mistral.ai/models/mistral-large-4-0), [Small 4](https://docs.mistral.ai/models/mistral-small-4-0-26-03) och [priser](https://docs.mistral.ai/inference/pricing).

| Uppgift | Modell | Resonemang | `max_tokens` |
|---|---|---|---|
| `ask`, `everyday` | Mistral Small 4, `mistral-small-2603` | Av (`reasoning_effort: "none"`) | Som förut: 1 200 och 1 500 |
| `lesson` | Mistral Large 4, `mistral-large-4-0` | `medium` | 12 000 |

- **Bara lektioner resonerar.** Large 4 kan inte stänga av resonemanget (`low`, `medium` eller `high`, aldrig `none`), så den går bara att välja för `lesson`. Står den för `ask` eller `everyday` vägrar gatewayen starta, med koden `provider_options_incompatible`. `mistral-large-4-0` är det ID som är låst till version 4.0; `mistral-large-4` och `mistral-large-latest` är alias som kan flytta.
- **Tanketexten kastas.** Med resonemang svarar Mistral med en lista av delar: en tankedel (`thinking`) och en textdel (`text`). Gatewayen tar bara textdelen och läser aldrig tankedelen, så tanketext hamnar aldrig i loggar, felkoder, svar till appen eller tillståndsfiler. En lista med två textdelar, verktygs- eller referensdelar eller tom text avvisas. För Small 4 och alla andra par avvisas en tankedel som förut, eftersom resonemanget ska vara av.
- **Schemat är inte strikt.** Mistrals sida om strukturerad utdata säger att schemat läggs i systemprompten och nämner inte `strict`. Gatewayen skickar `response_format` som till Groq och validerar varje svar; en ogiltig punkt kastas eller lagas ur källan som förut. `/v2/status` visar `schemaDialect: "json-schema"` för båda modellerna.
- **`max_tokens` för lektioner.** Tänkandet debiteras som utdata och räknas mot `max_tokens`. Mistral anger ingen utdatagräns för Large 4 och inget råd om `max_tokens` med resonemang, så lektionsdelen behåller sina 3 000 token för själva anteckningen och får 9 000 till för tänkandet. Mistral har ingen minutgräns av Groqs slag, så outnyttjat utrymme kostar inget; `MIO_TOKENS_PER_MINUTE_MISTRAL` är tom. Gränsen justeras när provet visar hur mycket Large 4 tänker. Övriga uppgifter har kvar sina gränser.
- **Temperatur.** Gatewayen skickar `temperature: 0` även till Large 4. Mistral skriver inte om parametern fungerar med resonemang på; vägrar Mistral den syns det som `provider_parameters` i provet, och då får paret samma flagga som Anthropic (`temperature: "provider-default"` i `/v2/status`).
- **Provet.** `mio-gateway prova mistral mistral-small-2603` kör alla tre uppgifterna. `mio-gateway prova mistral mistral-large-4-0` kör bara lektionsprovet, eftersom paret inte får användas för något annat; godkänns det blir paret valbart för `lesson`.

**Kostnad.** Priser 2026-11-20 per miljon token: Small 4 0,15 USD in, 0,015 cachad in och 0,60 ut; Large 4 0,70 in, 0,07 cachad in och 2,10 ut. Uppskattningen i besluten är ungefär 7 USD i månaden för vardag och 4 USD för cirka 100 lektioner, alltså runt 11 av de drygt 20 USD som provet av Vibe Pro ger. Gatewayen räknar token per månad, uppgift och modell i `usage.json` och visar en uppskattad kostnad i `/v2/status`; Mio Kontroll visar den som kreditmätare. Det är en uppskattning ur Mistrals siffror i svaren, inte Mistrals faktura.

**Vibe Pro tar slut.** Provet av Vibe Pro gäller i tre månader. Därefter debiteras API-användningen ditt konto, eller så slutar nyckeln fungera. Byt i så fall tillbaka till Groq i Mio Kontroll.

**Träning på din data.** Stäng av att Mistral får träna på din API-data i Mistrals admin-konsol (<https://admin.mistral.ai>). Det gör du själv; gatewayen kan inte ändra det.

## Leverantörer

Varje uppgift (`ask`, `everyday`, `lesson`) kör ett granskat par av leverantör och modell, valt på datorn: `MIO_AI_PROVIDER` och `MIO_AI_MODEL` för alla, och `MIO_AI_TASK_PROFILES` för en enskild uppgift, till exempel `{"lesson":{"provider":"mistral","model":"mistral-large-4-0"}}`. Ingen automatisk reserv: en uppgift utan granskad modell eller nyckel svarar `task_configuration_invalid`. `mio-gateway granskade-modeller` listar paren.

| Leverantör | Modell | Nyckel i `gateway.env` | Läge |
|---|---|---|---|
| Mistral | `mistral-small-2603` (`ask`, `everyday`), `mistral-large-4-0` (bara `lesson`) | `MISTRAL_API_KEY` | Standard i `install.sh`. Kandidater: strikt schema är inte bekräftat. Valbara efter ett godkänt prov (`install.sh` eller Prova i panelen). Se [Mistral](#mistral) |
| Groq | `qwen/qwen3.8-27b` | `GROQ_API_KEY` | Granskad. Gratisnivå, se nedan |
| Anthropic | `claude-haiku-5-5` | `ANTHROPIC_API_KEY` | Granskad 2026-11-17. Tänkandet av, schemat via `output_config.format`, **utan temperatur** (Anthropic vägrar parametern; `/v2/status` visar `"temperature": "provider-default"`). Ingen gratisnivå: 0,10 USD per miljon token in, 0,50 ut |
| NVIDIA NIM | `qwen/qwen3.8-27b` | `NVIDIA_API_KEY` | Kandidat av samma skäl, valbar efter ett godkänt prov |

Mistral Medium 3.5 är borttagen (utfasad 2026-10-31). Cloudflare Workers AI är avböjt: dess JSON-läge garanterar inte schemat. Detaljer och källor i [besluten](../docs/DECISIONS.md).

Tokenbudgeten per minut gäller per leverantör: `MIO_TOKENS_PER_MINUTE` för Groq (8 000 om den saknas) och `MIO_TOKENS_PER_MINUTE_ANTHROPIC`, `_MISTRAL` och `_NVIDIA` för de andra (ingen gräns om den saknas; 2 000–1 000 000).

### Lägga till en leverantör

`src/model_profiles.rs` har leverantörssömmen. En ny leverantör kräver en post i `PROVIDERS`, en modell i `REVIEWED_MODELS` (eller `CANDIDATE_MODELS` tills den är provad) med dokumentationskällor och hur resonemanget stängs av, en adapter i `src/adapters.rs` om API-formatet skiljer sig, syntetiska tester utan nät (svar, avvisning, avkortning, för stort anrop, fel) och en nyckel i `gateway.env`. Panelens lista över tillåtna nycklar (`control/core/src/settings.rs`) följer `PROVIDERS`; ett test håller dem i takt. Ett leverantörsprefix eller en OpenAI-kompatibel adress räcker aldrig som bevis.

### Kommandon för Mio Kontroll

Kontrollpanelen ([`control/`](../control/README.md)) använder tre kommandon i samma program. `kontrollera-konfiguration` och `granskade-modeller` skriver ingenting och skickar inget till en leverantör.

| Kommando | Gör |
|---|---|
| `mio-gateway kontrollera-konfiguration` | Läser en `gateway.env` på stdin på samma sätt som systemd och tjänsten och svarar med JSON: om filen går att starta med, och leverantör, modell och eventuellt felkod per uppgift. Svaret innehåller aldrig nyckel eller token. Avslutar med fel om gatewayen skulle vägra starta eller om en uppgift saknar granskad modell eller nyckel |
| `mio-gateway prova <leverantör> <modell>` | Riktig trafik, bara när du trycker Prova i panelen: ett påhittat svenskt anrop per uppgift med nyckeln i `gateway.env` på stdin, och JSON med resultatet och token per uppgift. Ett par som alltid resonerar (Large 4) provas bara på `lesson`. En kandidat som klarar sina prov blir valbar (`MIO_APPROVED_CANDIDATES`, skrivs av panelens hjälpare eller `install.sh`) |
| `mio-gateway granskade-modeller` | Leverantörerna och de granskade paren av leverantör och modell som JSON, med variabeln för varje nyckel och källorna för granskningen. Varje par har också `reasoning` (`"off"` eller nivån), `tasks` (de uppgifter paret får väljas för) och `prices` (USD per miljon token med datum, eller `null`) |

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

Varje uppgift i `/v2/status` har `reasoning` (`"off"`, eller `"medium"` för lektioner på Large 4) och `schemaDialect` (`"strict-json-schema"`, `"json-schema"` eller `null` utan giltig konfiguration). På toppnivån finns `usage`: månadens token och uppskattade kostnad per uppgift och modell, enligt [kontraktet](../docs/DATAMODELL.md#v2status-resonemang-schema-och-användning); `null` om `usage.json` har ett okänt format. Kapacitetslistan står kvar som äldre appar väntar sig den.

`/v2/status` svarar med `quota: {limit, remaining, resetAt, unit}` där `unit` är `tokens` eller `requests`, eller `quota: null` utan dygnsgräns. Klienter skickar den observerade revisionen som `X-Mio-Configuration-Revision`; en ändrad konfiguration ger 409 `configuration_changed` före kvot och modellanrop.

Gränser: fråga högst 2 000 byte, sex utdrag och 10 000 byte kontext. Analys 1–16 fragment och högst 16 000 byte text. Body högst 40 000 byte med 5 s deadline. Hela anropet högst 40 s, utom lektionsanteckningar när `lesson` står på ett par som resonerar (Mistral Large 4): då högst 180 s, oavsett lektionsrutt. Samma gränser gäller `mio-gateway prova`. `upstreamTimeoutMs` i `/v2/status` visar grundgränsen 40 000. Två samtidiga anrop. Svar från leverantören högst 65 536 byte.

## Verifiera utan modelltrafik

Rust 1.88 eller senare. Beroendena är låsta i `Cargo.lock`.

```bash
cd server && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings
```

Testerna använder en syntetisk transport; ingen nyckel eller riktig modelltrafik behövs. `tests/reasoning_usage.rs` prövar Mistral: att tankedelen kastas för lektioner och avvisas för vardag, att Large 4 inte går att välja för `ask` eller `everyday`, och användningsräknaren. `tests/parity.rs` spelar upp cirka 2 600 indata och 86 hela HTTP-utbyten som spelades in från den sista Node-versionen (`tests/golden/node-parity.json`) och kräver samma svar, inklusive exakt samma bytes till modellen. Fälten som kom till efter inspelningen (`reasoning`, `schemaDialect` och `usage` i `/v2/status`) tas bort före jämförelsen och prövas i egna tester. Ett riktigt prov mot Groq med syntetisk svensk text görs först när gatewayen kör på datorn.
