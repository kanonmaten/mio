# Mios privata AI-server

Valfri Node-server för en privat Mio-användare. Appens lokalflöde kräver ingen server. Detta paket är inte driftsatt automatiskt och saknar inbyggd molnprovisionering. Använd en server/domän du själv kontrollerar.

## Förutsättningar

- Node.js 22 eller senare. Inga npm-bibliotek behöver installeras.
- Ett OpenAI-projekt med API-åtkomst och en kostnadsgräns som du själv väljer.
- En HTTPS-domän och en reverse proxy, exempelvis Caddy, på samma värd som Node-processen.
- En slumpad privat gatewaytoken. Den är **inte** din OpenAI-nyckel.

## Prova koden utan OpenAI

Från repots rot:

```sh
npm test --prefix server
```

Tester använder syntetiska data, en lokal HTTP-port och mockad upstream. Ingen API-nyckel behövs och testerna kontaktar inte OpenAI. De verifierar HTTP-kontrakt, autentisering, godkänd kontext, fel, gränser och timeout. De verifierar inte verklig modellåtkomst, HTTPS-driftsättning eller appens nätverk på iPhone.

## Konfigurera på din server

1. Kopiera katalogen `server/` till en privat katalog på din server.
2. Kopiera `env.example` till `.env`. Skydda filen med `chmod 600 .env`.
3. Fyll i `OPENAI_API_KEY` och `MIO_OPENAI_MODEL` med en textmodell som ditt OpenAI-projekt har åtkomst till och som stöder Responses API. Modell väljs uttryckligen; servern gissar inte åt dig.
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
8. I Mio: **Fråga Mio med AI → Din privata server**. Ange endast HTTPS-origin, exempelvis `https://mio.din-domän.se`, och gatewaytoken. Spara och aktivera molnfrågor. Prova en syntetisk fråga utan kontext och kontrollera sändningspreview.

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
- Högst två samtidiga upstream-anrop, normalt sex frågor/minut och 100/dygn. Gränser kan sänkas i `.env`.
- Räknarna finns bara i processminnet och nollställs vid omstart. Kör en process; flera instanser delar inte räknare. Detta är ingen hård månadsbudget: använd även OpenAI-projektets kostnadskontroller.
- Svaret begränsas till 1 000 genererade tokens och 16 000 byte text. Ofullständiga svar avvisas.

## Datakontroll

Appen visar exakt fråga, etiketter och utdrag före ett särskilt godkännande. Servern skickar bara detta som användarinnehåll samt fasta svenska systeminstruktioner till `https://api.openai.com/v1/responses`. Det finns inga verktyg, ingen automatiserad kalender-/minnesåtgärd, ingen konversationshistorik och inga automatiska omförsök.

Servern skriver inga frågor, svar, IP-adresser eller credentials till logg eller databas. Den begär `store: false`. Detta innebär inte att OpenAI saknar all datalagring; kontrollera [OpenAI:s datakontroller](https://developers.openai.com/api/docs/guides/your-data). [Responses API-kontraktet](https://developers.openai.com/api/reference/resources/responses/methods/create) är källa för anropsformatet.

Telefonens **Glöm anslutning** tar bort lokal token/URL och stänger av AI. Det raderar inte en redan skickad fråga hos leverantören. Byt/återkalla servernyckel och token vid misstänkt läcka. Använd endast testdata i [AI01–AI06](../docs/TESTPLAN_HELHET.md) tills din egen installation är verifierad.
