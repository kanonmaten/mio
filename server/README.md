# Mios privata text-AI-gateway

Valfri server för godkända frågor, vardagsutdrag och detaljerade lektioner. Appens manuella innehåll kräver ingen text-AI. [Pianissimo](../transcription-server/README.md) är en separat privat GPU/Tailscale-tjänst; ljud skickas aldrig till denna gateway och ingen råljudsfil lagras.

Arbetskopian har gemensam Node/Worker-execution, exakta modellprofiler och task-routing. Ingen publicering, verklig modellåtkomst, Xcode-build eller telefonacceptans följer av lokala tester. Den verifierade äldre produktionsbundeln är ännu inkompatibel med Groq-inställningarna; [releaseguiden](cloudflare/GROQ_ACCESS.md) skiljer förberedelse, uttrycklig publicering, read-back och separat sändningsgodkännande.

## Verifiera utan modelltrafik

Stödd Node-version är **>=26.10.0 <27**, med 26.10.0 som testad miniminivå. Runtime använder inbyggda Node-moduler; `npm ci` installerar låsta verktyg för Worker-verifiering. Kör från valfri katalog, med rätt uttrycklig källsökväg:

```bash
npm --prefix "$HOME/Documents/ChatGPT/Mio/server" ci
npm --prefix "$HOME/Documents/ChatGPT/Mio/server" test
WRANGLER_SEND_METRICS=false npm --prefix "$HOME/Documents/ChatGPT/Mio/server" run worker:test
```

Worker-provet bygger med `--dry-run` och kör det faktiska paketet i lokal workerd/Miniflare, inklusive D1, taskprofiler, skyddad v2-status, revisionskontroll, deadline och avbrott. Providertransporten är syntetisk; inga modellnycklar eller inferensanrop används. Repoövergripande entry point:

```bash
python3 "$HOME/Documents/ChatGPT/Mio/scripts/verify.py"
```

Se [installation](../docs/INSTALLATION.md) för plattformsförutsättningar och [status](../docs/STATUS.md) för faktiskt utförda kontroller. Linux/portable Swift ersätter native microphone, converter, UIKit/Keychain och Apple-transportgränser; detta är inte Xcode eller iPhone.

## Konfiguration och egen Node-drift

[Leverantörsguiden](PROVIDERS.md) och [kontraktsmatrisen](../docs/LEVERANTORSKONTRAKT.md) anger exakt provider/model/Secret och separat verklig verifiering. Reasoning OFF, temperatur 0 och strikt schema är obligatoriskt. Nyckeln ligger serverägd; en separat `MIO_GATEWAY_TOKEN` används av appen. Access- och transkriptionstokens är andra hemligheter.

För egen Node-drift kopieras bara gatewayens `server/src/*.mjs` och `server/package.json` till exempelvis `/opt/mio-gateway`. Skapa privat `.env` där, ägd av tjänsteanvändaren med 0600. Kopiera inte hela Mio-repot, Swift/Xcode, exporter, ljud, Git-historik, utvecklingsmiljö eller befintliga hemligheter. `env.example` beskriver globala värden; taskprofiler beskrivs nedan. Leverantörskonto/kostnadskontroll och betrodd HTTPS behövs.

Generera gatewaytoken lokalt och spara privat; den får inte vara samma värde som providerkey:

```bash
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
```

Starta med explicita paths, även genom systemd/processhanterare:

```bash
node --env-file=/opt/mio-gateway/.env /opt/mio-gateway/src/server.mjs
curl --fail --max-time 5 http://127.0.0.1:8787/health
```

Node binder `127.0.0.1:8787`; betrodd HTTPS-proxy på samma värd krävs för telefonen. [Caddy-exemplet](Caddyfile.example) begränsar body och exponerar inte Node-porten. Undvik body/Authorization-/URL-loggning och kör en begränsad tjänsteanvändare. Processens minut/dygnsräknare nollställs vid omstart och delas inte mellan flera Node-processer; leverantörens kostnadsgräns behövs också. [Cloudflare-alternativet](cloudflare/README.md) återanvänder beständiga D1-räknare.

Ogiltig gatewaytoken eller numeriska säkerhetsgränser blockerar Node-start. En felaktig modell/provider/options/secret spärrar berörd task men hindrar inte modellfri skyddad discovery för annars giltig gatewaykonfiguration. Worker kan även ge skyddad konfigurationsstatus när globala genereringsinställningar är ogiltiga.

## Task-profiler och status

`MIO_AI_PROVIDER`/`MIO_AI_MODEL` är global default. Valfri `MIO_AI_TASK_PROFILES` är JSON med `ask`, `everyday`, `lesson`, exempelvis:

```json
{"ask":{"provider":"openai","model":"gpt-4.1-mini"},"lesson":{"provider":"groq","model":"qwen/qwen3.8-27b"}}
```

Saknad override ärver global konfiguration. Skild provider använder sin designated serversecret, aldrig en global nyckel från annan provider. Tillåtna profilfält är provider, model, validerade adapterOptions samt custom-kontraktets baseURL/compatibility. Felaktig task spärras explicit; ingen request-time fallback. Alla aliases/snapshots och schema-dialekter finns i matrisen. Legacy `MIO_OPENAI_MODEL` läses endast för OpenAI-konfiguration när det nya namnet saknas.

`GET /health` provar process/Worker, inte providercredentials. Access ska skydda all extern Worker-trafik. `GET /v1/status` bevarar äldre klientkontrakt. Ny **`GET /v2/status`** kräver gatewaytoken och eventuell Access, gör inget modellanrop och reserverar ingen kvot. Svaret innehåller:

- `protocolVersion:2`, `release` och 64 hextecken `configurationRevision`.
- `tasks.ask/everyday/lesson`: configured, provider, model, promptVersion, capabilities, fast configurationError eller null.
- `quota`: limit (högst 100), remaining och resetAt, vilka kan vara null när läsning inte kan bevisas. D1-läsningen är tidsbegränsad och ändrar inga räknare.

Configured betyder granskad lokal konfiguration, inte giltiga providercredentials, saldo, modellåtkomst eller kvalitet. Revisionen binds till offentliga profil-/policy-/gränsval och endpointidentitet utan att exponera URL eller secretfingerprint; giltig secretrotation byter inte revision. Discovery accepterar bounded okända provider-/capabilitynamn, men kontrollerar de förmågor vald task kräver.

Nya klienter skickar den observerade revisionen som `X-Mio-Configuration-Revision` vid varje AI-POST. Ändrad revision ger **409 före body/kvot/providertrafik**, kräver ny preview eller manuell återaktivering och ger ingen automatisk retry. Äldre klienter utan header behåller kontraktet. Appens lyckade discoverycache är 30 sekunder och binds till anslutning/credentials/revision; inställningar, authfel och 409 invalidierar den. Kvarvarande kvot är ett ögonblicksvärde, inte reservation eller modellprov.

## Genereringskontrakt och gränser

Alla genereringsrutter kräver `Authorization: Bearer <gatewaytoken>`, JSON och inga Content-Encoding/redirects. Okända bodyfält avvisas. Servern skickar exakt godkänd payload som användarinnehåll samt fasta taskinstruktioner/schema. Resultatet valideras oberoende efter provider-normalisering; AI kan aldrig utföra systemåtgärder.

| Rutt | Indata och validerat resultat |
|---|---|
| `/v1/ask` | Fråga + explicit valda context-utdrag → endast answer, tillfälligt i appen |
| `/v1/analyze` | Äldre mode/timeZone/fragments-kontrakt → grundade candidates/highlights/uncertainties |
| `/v2/analyze` | Endast everyday; nya fragments, högst en minut contextFragments, priorDecisions och contextLimited → candidates med explicit nullable replacesID |
| `/v1/lesson-notes` | Endast lesson, högst 3500 byte källtext → plan/task-kandidater, detaljerade sections med citat och serverägd metadata |

Fråga är högst 2000 UTF-8-byte, sex context-utdrag, 200 byte etikett/4000 byte text per utdrag och sammanlagt 10000 byte kontext. Analys har 1–8 fragment, högst 4000 byte per fragment och sammanlagt 10000; v2-kontext högst 4000 byte och tolv tidigare beslut. Body är högst 20000 byte och har separat **5 s** deadline. Fråga begär högst 1000 output-tokens; övriga uppgifter 3000. Frågesvaret är högst 16000 byte text. Upstream-envelope är högst 65536 byte, även för fel.

Hela operationen efter body begränsas till **40 s**, inklusive kvotreservation, fetch, bounded bodyläsning, parsing och domänvalidering. Deadline skiljs från klientavbrott. Sena D1-reservationer kan ha förbrukat kvot men får aldrig starta senare inferens eller osäker refund. Slots/listeners frigörs på alla utgångar. Node och Worker använder samma executionpolicy med separat faktisk Worker-runtimecoverage.

Fyra genereringsrutter delar högst **100/UTC-dygn**, med medföljande konfiguration sex/minut och två samtidiga anrop per instans. Gränser kan sänkas; dagsgränsen kan inte höjas över 100. **Observera vid uppgradering:** en befintlig installation med `MIO_REQUESTS_PER_DAY` över 100 startar inte längre (Worker svarar 503 `gateway_not_configured`) förrän värdet sänkts. Konfigurationsrevisionen innehåller även gatewayns release, så varje ny publicering ger 409 `configuration_changed` en gång och kräver ny granskning/aktivering i appen. En D1-kvotkontroll som överskrider deadline ger 503 `budget_store_failed`, inte `upstream_timeout`. Workern kräver kompatibilitetsflaggan `enable_request_signal` för att klientavbrott ska nå gatewayn. Lektionsintervallet är 60–3600 s, normalt minst 60 s även efter lång status-/modellväntan. Frågor, vardagsanalys och lektioner delar kvot; detta räcker inte för heldags minutanalys. Misstänkt timeout/avbrott får inte automatiskt skickas om eftersom kostnad/kvot kan ha uppstått.

## Diagnostik, samtycke och lektioner

Fasta felkategorier skiljer gatewayauth, providercredentials/konto, modell/parametrar, refusal/truncation, providerkvot, lokal minut/dag/concurrency, budget-store, timeout och transport. Retry-After normaliseras från bounded sekunder eller HTTP-datum. Inga råa providerfel återges.

Svar kan ha säkra `X-Mio-Release/Provider/Model/Prompt-Version/Request-ID/Configuration-Revision` och valfri returned-model/upstream-request-ID/numerisk usage. Konfigurerad modell och faktiskt returnerad modell hålls isär. Text, credentials, fulla URL:er och råa felobjekt loggas inte; D1 innehåller bara räknare. `store:false` begärs i Responses-adaptrarna, men leverantörens övriga datavillkor gäller ändå.

Enskild fråga har exakt preview/Ja och tillfälligt svar. Explicit lokal granskning/sparande som anteckning använder befintligt contentlager, stabilt ID och inga extra modellfrågor; ingen implicit svarshistorik. Löpande analys kräver aktivt samtycke, återställs vid ny process och tar endast nya vardagsutdrag samt godkända lektioner. All sändning använder minsta bounded kontext. Mikrofon och privat transkription är egna status-/styrflöden.

Detaljerade lektionsdelar sparas atomiskt med källcitat och modell/promptmetadata. Kopiering sammanställer dem lokalt utan extra AI. Äldre highlights räknas inte som färdiga detaljerade anteckningar. Avbrott/omstart behåller färdiga delar; fortsättning kräver manuellt val. Valfria lokala källrevisioner visar aktuell/äldre/okänd efter rättning, bevarar original/citat/egna anteckningar och ändrar inte serverpayloaden. Rättat material skickas aldrig automatiskt igen.

## Nästa externa grind

Efter lokala kontroller: jämför exakta kod-/bundle-/releasevärden och produktionsinställningar, få uttrycklig publiceringsbegäran, bevara Worker/D1/Secrets/Access och read-verifiera aktiv version samt autentiserad v2-status. Kontrollera negativa Access/gatewayauth och alternativa adresser. Först efter separat sändningsgodkännande körs [tre syntetiska modellprov](../docs/LEVERANTORSKONTRAKT.md#separat-godkänt-syntetiskt-modellprov). Därefter behövs matching Xcode/XCTest/IPA, installation och iPhone-acceptans. [Groq/Access-guiden](cloudflare/GROQ_ACCESS.md) beskriver den konkreta ordningen.
