# Mios privata AI-server

Valfri Node-server för en privat Mio-användare. Appens lokalflöde kräver ingen server. Detta paket är inte driftsatt automatiskt och saknar inbyggd molnprovisionering. Välj den färdiga [Cloudflare-vägen](cloudflare/README.md) för drift utan påslagen egen dator eller köpt domän. Node/Caddy-vägen nedan finns kvar för egen server.

För byte till Groq eller annan leverantör, följ [modell- och leverantörsguiden](PROVIDERS.md). Den beskriver exakt vilka modeller som tillåts med reasoning av, temperatur 0 och strikt schema.

## Förutsättningar

- Node.js 22 eller senare. Node-servern har inga runtime-beroenden. `npm ci` installerar låsta utvecklingsverktyg för Cloudflare-alternativet.
- Ett konto hos vald AI-leverantör med API-åtkomst och en kostnadsgräns som du själv väljer.
- En HTTPS-domän och en reverse proxy, exempelvis Caddy, på samma värd som Node-processen.
- En slumpad privat gatewaytoken. Den är **inte** leverantörens API-nyckel.

## Prova koden utan OpenAI

Från repots rot:

```sh
npm test --prefix server
```

Tester använder syntetiska data, en lokal HTTP-port och mockad upstream. Ingen API-nyckel behövs och testerna kontaktar inte OpenAI. De verifierar HTTP-kontrakt, autentisering, godkänd kontext, fel, gränser och timeout. De verifierar inte verklig modellåtkomst, HTTPS-driftsättning eller appens nätverk på iPhone.

## Konfigurera på din server

1. Kopiera katalogen `server/` till en privat katalog på din server.
2. Kopiera `env.example` till `.env`. Skydda filen med `chmod 600 .env`.
3. Välj `MIO_AI_PROVIDER`, `MIO_AI_MODEL` och leverantörens API-hemlighet enligt [leverantörsguiden](PROVIDERS.md). För OpenAI används `OPENAI_API_KEY`. Modell väljs uttryckligen; servern gissar inte åt dig.
4. Skapa en separat slumpad gatewaytoken med följande kommando, lokalt på servern. Spara resultatet i `.env` som `MIO_GATEWAY_TOKEN` och privat i telefonens anslutningsfält. Publicera inte resultatet i en chatt eller Git.

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
```

5. Starta från serverkatalogen:

```sh
node --env-file=.env src/server.mjs
```

Node lyssnar bara på `127.0.0.1:8787`. Kontrollera lokalt:

```sh
curl --fail http://127.0.0.1:8787/health
```

För kontinuerlig drift, låt din processhanterare/systemd starta samma kommando med rätt arbetskatalog och en begränsad användare. Håll miljöfilen läsbar bara för den användaren. Servern stoppar vid saknad/ogiltig konfiguration.

6. Anpassa `Caddyfile.example` till din domän, rikta DNS till servern och konfigurera betrodd HTTPS. Exponera endast HTTPS-porten publikt, aldrig Node-port 8787. Caddy måste köras på samma värd för den angivna loopback-adressen. Kontrollera din installation mot [Caddys dokumentation](https://caddyserver.com/docs/quick-starts/https).
7. Använd inga request-/body-/Authorization-loggar i proxyn. Exempelfilen slår inte på accessloggar. Håll server, certifikat och system uppdaterade.
8. I Mio: **Mio → AI-assistent → Konfigurera server och tillåt molnfrågor**. Ange endast HTTPS-origin, exempelvis `https://mio.din-domän.se`, och gatewaytoken. Spara och aktivera molnfrågor. Prova en syntetisk fråga utan kontext och kontrollera sändningspreview.

Servern har ingen installation av OpenAI-nyckeln i appen, ingen OAuth och inga användarkonton. Dela inte gatewaytoken mellan oberoende användare. Rotera den genom att ändra `.env`, starta om servern och spara den nya tokenen i appen.

## Kontrakt

`GET /health` svarar med `{"status":"ok"}` utan upstream-anrop. Det bevisar bara att Node-servern svarar.

`POST /v1/ask` kräver `Authorization: Bearer <gatewaytoken>` och `Content-Type: application/json`:

```json
{
  "question": "Vad betyder procent?",
  "context": [{"label": "Vald anteckning", "text": "Vi övar procent."}]
}
```

Ett lyckat svar är `{"answer":"…"}`. Andra statuskoder ger en fast felkod, aldrig upstreamens privata feltext. Okända fält avvisas. Inga redirects följs av appen eller serverns upstream-anrop.

- Högst 2 000 UTF-8-byte fråga, sex utdrag, 200 byte etikett och 4 000 byte text per utdrag. All kontext högst 10 000 byte; HTTP-body högst 20 000 byte.
- Upstream timeout 40 sekunder. Appens timeout är något längre. Klientavbrott försöker avbryta upstream men återkallar inte redan skickad text eller kostnad.
- Högst två samtidiga upstream-anrop, normalt sex anrop/minut och 100/dygn för alla tre AI-rutter tillsammans. Gränser kan sänkas i `.env`.
- Räknarna finns bara i processminnet och nollställs vid omstart. Kör en process; flera instanser delar inte räknare. Detta är ingen hård månadsbudget: använd även leverantörens kostnadskontroller.
- Enskilda frågesvar begränsas till 1 000 genererade tokens (analys till 3 000) och 16 000 byte text. Ofullständiga svar avvisas.

## Datakontroll

Enskilda frågor visar exakt fråga, etiketter och utdrag före godkännande. Löpande analys har ett separat samtycke till nya utdrag och avslutade lektioner tills läget stängs av. Servern skickar bara den godkända payloaden som användarinnehåll samt fasta svenska systeminstruktioner till vald leverantörs API. Det finns inga verktyg, ingen automatiserad kalender-/minnesåtgärd, ingen konversationshistorik och inga automatiska omförsök.

Servern skriver inga frågor, svar, IP-adresser eller credentials till logg eller databas. Responses-adaptrarna begär `store: false`. Övriga API:er använder sina respektive datavillkor. Detta innebär inte att leverantörerna saknar annan datalagring; för OpenAI, kontrollera [OpenAI:s datakontroller](https://developers.openai.com/api/docs/guides/your-data). [Responses API-kontraktet](https://developers.openai.com/api/reference/resources/responses/methods/create) är källa för anropsformatet.

Telefonens **Glöm anslutning** tar bort lokal token/URL och stänger av AI. Det raderar inte en redan skickad fråga hos leverantören. Byt/återkalla servernyckel och token vid misstänkt läcka. Använd endast testdata i [AI01–AI06](../docs/TESTPLAN_HELHET.md) tills din egen installation är verifierad.

## Löpande textanalys och lektionsanteckningar

`POST /v1/analyze` använder samma autentisering och gränser. JSON innehåller `mode` (`everyday`/`lesson`), IANA-`timeZone` och 1–8 `fragments` med `id` (segment-UUID:delindex), `text`, `occurredAt` (ISO-8601 med offset). Varje fragment får vara 4 000 UTF-8-byte, sammanlagt 10 000. Appen skickar enbart färdig text, aldrig råljud.

Svaret har `candidates` (högst sex), `highlights` (högst åtta, bara lektion) och `uncertainties` (högst sex). Kandidater innehåller typ, rubrik, text, nullable `scheduledAt`, käll-ID:n och exakt citat. Server och app avvisar okända källor, citat som inte finns i underlaget, ogiltiga tider och automatiska minnen. Det bevisar inte att modellens tolkning är korrekt; användaren granskar utkastet.

[Systeminstruktionerna](src/prompts.mjs) beskriver svensk vardagsanalys, negation/osäkerhet, undervisning, datum, ingen dold profil och åtskillnad mellan data och instruktioner. [Adaptrarna](src/provider.mjs) använder leverantörens strikta schemaformat utan verktyg. [Kompatibilitetskatalogen](PROVIDERS.md) anger modellbegränsningar. Egna kvalitetsprov krävs vid byte. En ändring av modell i `.env` kräver omstart.

Vardagsanalys gör normalt högst ett anrop per minut; lektionsdelar minst 60 sekunder emellan (konfigurerbart uppåt). iOS bakgrundskörning kan fördröja arbetet. Dagsgränsen 100 kan därför nås efter cirka 100 aktiva analysminuter och tidigare om frågor/lektioner också skickas. Appen stoppar AI-läget vid fel, utan automatisk återförsöksslinga. Ändra gränsen först efter att ha mätt verklig användning/kostnad. Räknarna är inte en beständig månadsbudget.

## Detaljerade lektionsanteckningar

`POST /v1/lesson-notes` har samma indatafält som analys, men endast `mode=lesson` och högst 3500 byte källtext. Svaret har `candidates` (endast läxor/planer), `sections` med `heading`, `body`, `sourceIDs`, `evidence`, samt `uncertainties`. Servern lägger till `metadata` med `provider`, `model`, `promptVersion` och `lessonIntervalSeconds`. Modellen får inte själv ange metadata.

Appen sparar färdiga delar och sammanställer ett kopierbart dokument lokalt utan ett extra sammanfattningsanrop. Avbrott kräver aktivering och manuell fortsättning från lektionen; redan sparade detaljerade delar skickas inte igen. Äldre korta huvudpunkter räknas inte som detaljerade anteckningar. Högst 100 delar köas per godkänd omgång; vid längre underlag fortsätter användaren med resterande delar. Ingen bakgrundsbearbetning utlovas när appen stängts.

## Om du börjar utan konto eller server

1. Välj leverantör enligt [guiden](PROVIDERS.md) och konfigurera API-åtkomst där. Skapa en API-nyckel som bara används i serverns privata `.env`, aldrig i telefonen eller chatten.
2. Välj en tillgänglig modell ur kompatibilitetskatalogen. Fyll i dess exakta modell-ID. Modellkvalitet, svarstid och verklig kostnad provas med syntetiska exempel innan löpande lyssning aktiveras.
3. Du kan först köra servern på din dator med stegen ovan och kontrollera `/health` samt mocktesterna. iPhone kräver en betrodd HTTPS-adress som når servern; `localhost` på telefonen är telefonen själv. Vanlig lokal HTTP fungerar inte som appanslutning.
4. För ständig åtkomst behövs en påslagen värd och HTTPS/domän. Ingen serverplats köps eller skapas av detta repo. När driftplatsen är vald används samma Node-process bakom Caddy enligt ovan.
5. Kör AI01–AI06 samt A07–A14 och L01–L05 i [testplanen](../docs/TESTPLAN_HELHET.md). Börja med syntetiska meningar och låg dagsgräns. Kontrollera faktiska modellresultat i appen, inte bara att servern svarar 200.

En fungerande `/health` betyder inte att API-nyckel, modell eller betalning fungerar. Det första verkliga modellprovet kräver din konfigurerade server och kan kosta pengar. Installationsstegen lämnar AI avstängt tills du själv aktiverar det.

## Kostnadsfri molngateway

[Cloudflare-guiden](cloudflare/README.md) beskriver Workers, inkluderad HTTPS-adress och en beständig D1-kvot som bara lagrar räknare. Dessa räknare ersätter processens dygnsgräns som enda kostnadsskydd i molnet. Ingen privat dator behöver vara på. API-användningen debiteras separat. Ingen tjänst har driftsatts förrän användarens konto och hemligheter konfigurerats.
