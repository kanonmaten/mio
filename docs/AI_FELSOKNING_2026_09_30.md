# AI-fel: genomförda rättningar och kvarvarande driftsättning

Uppdaterad 2026-09-30 efter implementation och commit/push av **`e906585`**. Det tidigare designförslaget är genomfört i källkoden. **Publicering i Cloudflare, nytt iOS-bygge och telefonprov återstår.** Att koden är pushad till GitHub uppdaterar inte automatiskt Workern eller appen på telefonen.

## Genomfört i källkoden

| Område | Implementerat |
|---|---|
| AI-fel och export | Beständig textfri journal, högst 200 händelser/sju dagar; säkra HTTP-/gateway-/nätfel, storlekar och versionsmetadata. Export fungerar utan session och kan återskapas med Skapa ny export efter senare fel |
| Serverkompatibilitet | Skyddad `GET /v1/status` utan modelltrafik eller D1-kvot. Klienten kräver det nya sammanhangskontraktet och använder ingen tyst fallback |
| Sammanhang över anropsgränser | `POST /v2/analyze` skiljer nya `fragments` från `contextFragments`. Högst 60 sekunder/4000 byte tidigare godkänd text; totalt åtta fragment/10000 byte källtext/20000 byte JSON. Nya fragment kapas inte |
| Förslagsbeslut | Textfria `priorDecisions` och uttrycklig `replacesID` kompletterar samma öppna förslag. Ja/Nej stänger beslutet; sena svar får inte ändra godkända poster eller återuppliva stängda beslut |
| Timing och avbrott | Normalt 60 s samling, högst 60 s extra mjuk meningsväntan. Nästa sändning tidigast 60 s efter föregående sändningsslut. Stopp/paus väcker väntan för kvarvarande godkänd text; nästa lyssning får ny kontextgräns. Ljudluckor bryter kontinuitet |
| Integritet och radering | Inga råljud, frågor, svar, transkriptkopior eller hemligheter i journalen. Okänt schema skyddas och sena writes avvisas efter total radering |

Lektioner behåller `/v1/lesson-notes` och budgeten 3500 byte. Enskilda frågor kräver fortfarande exakt sändningsgodkännande. Detaljer finns i [datamodellen](DATAMODELL.md) och [besluten](DECISIONS.md).

Vid implementationskontrollen passerade **53 portabla Swift-kärntester**, **47 Node-tester**, lokal Worker-runtime och **194 projektkontroller**. Detta verifierar inte native iOS-transport, SwiftUI, telefonens bakgrundsbeteende eller modellens svenska kvalitet. Se [exakt teststatus](STATUS.md).

## Driftfelet som hittades före rättningen

Vid läskontrollen 2026-09-30 var aktiv Cloudflare-version `4c22cc43-a625-48d1-86e5-e45638cbcb8e`. Dess faktiska kod stödde bara OpenAI och läste `OPENAI_API_KEY`/`MIO_OPENAI_MODEL`. Bindningarna angav däremot Groq/Qwen och `GROQ_API_KEY`, utan dessa OpenAI-inställningar. Initieringen kunde därför inte lyckas; kodens felväg var 503 `gateway_not_configured`. Samma konflikt reproducerades med syntetisk konfiguration utan modelltrafik.

Ett anonymt anrop gav 403 från Cloudflare Access. Det bevisade det yttre skyddet, inte telefonens autentisering. Den bifogade exporten var tom och saknade då AI-anropsjournal, så telefonanropets exakta status kunde inte fastställas. Detta beskriver **den äldre kod som lästes vid kontrollen**, inte en ny livekontroll efter implementationen.

## Det som behöver göras med Cloudflare/gatewayen

1. **Publicera den nya koden på befintliga `mio-private-gateway`.** Använd `server/` från `e906585` eller en senare granskad revision. Ändringar av variabler/Secrets installerar inte Groq-adaptern eller v2-rutten. Behåll den befintliga domänen, D1-databasen `mio-limits` och bindningen `MIO_LIMITS`; ingen ny databas eller schemaändring behövs för denna rättning.
2. **Kontrollera konfigurationen före publicering.** `MIO_AI_PROVIDER=groq`, `MIO_AI_MODEL=qwen/qwen3.8-27b`; Secrets `GROQ_API_KEY` och `MIO_GATEWAY_TOKEN`. Behåll befintliga fungerande hemligheter. Deras giltighet är ännu inte verifierad; ersätt dem endast om de saknas eller visar sig felaktiga. `server/wrangler.jsonc` innehåller rätt provider/modell och `keep_vars: true`; explicit angivna filvärden behöver fortfarande stämma med Dashboard före deploy. [Cloudflares konfigurationsregler](https://developers.cloudflare.com/workers/wrangler/configuration/#source-of-truth).
3. **Behåll Access-skyddet.** Policyn ska vara `Service Auth` för telefonens service token och skydda hela Workern. Den uppdaterade appen behöver både gatewaytoken och Access Client ID/Client Secret. Anonym 403 är väntat med detta skydd; det ska inte lösas genom att stänga av Access.
4. **Verifiera aktiv release och autentiserad status efter deploy.** Kontrollera Deployments och hämta `/v1/status` med alla tre autentiseringsuppgifterna. För denna kod ska status ge `protocolVersion: 2`, `release: "2026-09-30.1"`, `configured: true`, provider `groq`, modell `qwen/qwen3.8-27b` och capability `analysis-context-v2`. Statuskontrollen gör inget modellanrop och använder ingen AI-kvot. Den bevisar inte nyckelns giltighet, saldo eller modellkvalitet.
5. **Gör därefter ett godkänt syntetiskt modellprov**, till exempel ”Vad är 2 + 2?” utan kontext, och kontrollera användningen hos Groq. Detta använder API-kvot och kan kosta pengar. Prova sedan vardagskontext och en lektion med syntetiskt underlag.

Från repots rot, i en terminal med rätt Cloudflare-konto:

```sh
cd server
npm ci
npx wrangler login
npm test
WRANGLER_SEND_METRICS=false npm run worker:test
npx wrangler deploy
npx wrangler deployments list
```

`login` behövs om Wrangler inte redan är inloggat. **`deploy` ändrar live-Workern**; övriga prov ovan gör ingen verklig modelltrafik. Wrangler publicerar den nya versionen direkt enligt [Cloudflares deploymentmodell](https://developers.cloudflare.com/workers/versions-and-deployments/). Kommandona är instruktioner; de har inte körts som publicering i detta arbete.

Detaljerade steg och ett autentiserat statusprov utan hemligheter i kommandoraden finns i [gatewayguiden](../server/cloudflare/GROQ_ACCESS.md#2-engångsuppdateringen-som-behövs-nu) och [dess anslutningskontroll](../server/cloudflare/GROQ_ACCESS.md#6-kontrollera-anslutning-och-skydd).

## Det som behöver göras på telefonen

Bygg den nya apprevisionen med Release/iOS-XCTest i Xcode/Actions, höj byggnumret inför distribution och installera den verifierade IPA:n enligt [installationsguiden](INSTALLATION.md). Build 5 innehåller inte Access-fälten eller dessa nya funktioner. GitHub-workflowen startas manuellt och har inte startats genom pushen.

Spara befintlig serveradress, gatewaytoken och Access-par i den nya appen. Gör [D01–D08](TESTPLAN_HELHET.md#ai-kontext-och-diagnostik--nya-prov-ej-körda-på-iphone), särskilt delade meningar, datumkorrigering, Ja/Nej under pågående svar, stopp/paus, låst skärm och ny export efter ett fel. Aktivera löpande AI separat; en sparad anslutning aktiverar inte läget.

## Varför lösningen valdes och vad den inte garanterar

Begränsad bakåtkontext med mjuka gränser valdes och implementerades. Enbart tystnad/interpunktion är osäkra ledtrådar till avslutad tanke; en extra semantisk detektionsmodell skulle ge ytterligare drift, latens och kostnad. [Deepgram](https://developers.deepgram.com/docs/understand-endpointing-interim-results) skiljer slutligt textsegment från avslutat yttrande, och [AssemblyAI](https://www.assemblyai.com/docs/universal-streaming/turn-detection) beskriver risken att tänkpauser delar en tur. Ingen ny molntranskription införs.

Fönstret kan missa hänvisningar längre bakåt än en minut. Nätlatens och anropstakt kan förlänga väntan utöver den mjuka gränsens 120 s; iOS kan avbryta bakgrundsarbetet. Dessa beteenden och semantisk kvalitet kräver telefon-/modellprov. Standardkvoten **100 anrop per UTC-dygn**, gemensam för frågor/vardag/lektioner, är oförändrad och utgör ingen heldagsbudget.
