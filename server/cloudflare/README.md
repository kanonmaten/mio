# Mio utan en påslagen egen dator

Cloudflare Workers kör den lilla gatewayen vid anrop. AI-modellen körs hos OpenAI. Telefonen behöver internet, men din dator behöver inte vara på. En `workers.dev`-adress ingår, så du behöver inte köpa en egen domän eller konfigurera Caddy.

Workers och D1 har kostnadsfria nivåer. Det passar Mios begränsade privata trafik, men är ingen garanti om evigt gratis drift eller viss tillgänglighet. AI-modellens API debiteras separat. Se [Workers-priser](https://developers.cloudflare.com/workers/platform/pricing/), [workers.dev](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/) och [OpenAI API](https://platform.openai.com/).

Direkta API-anrop från en privat telefon är tekniskt möjliga med en egen nyckel på enheten. Den valda lösningen behåller nyckeln i molnets hemlighetslager enligt [OpenAI:s rekommendation](https://developers.openai.com/api/reference/overview). Mio innehåller varken din API-nyckel eller en gemensam nyckel som alla installationer delar.

## En gång: konton och installation

Du behöver ett eget Cloudflare-konto och ett OpenAI-projekt med API-åtkomst. Följ OpenAI-kontots instruktioner för betalning och användningskontroller. Klistra aldrig in API-nyckeln i chatten eller Git.

Från repots `server/`-katalog, med en aktuell Node 22 LTS eller senare:

```sh
npm ci
npx wrangler login
npx wrangler d1 create mio-limits
```

Logga in i webbläsaren och verifiera Cloudflare-kontots e-postadress. Sista kommandot skapar en liten kvotdatabas i ditt konto. Kopiera dess `database_id` till D1-delen av `server/wrangler.jsonc`. Den incheckade konfigurationen pekar på Mios befintliga databas; skapa inte en ny vid en vanlig uppdatering. Databasen innehåller bara minut-/dygnsräknare, inga transkript eller nycklar.

1. Kontrollera `MIO_OPENAI_MODEL` i `wrangler.jsonc`. Första provmodellen är `gpt-6-luna`; projektets åtkomst och svensk analyskvalitet behöver verifieras med riktiga API-prov. Vid byte krävs en modell med Responses API och Structured Outputs.
2. Behåll `MIO_AI_PROVIDER=openai`. Andra leverantörer kräver en ny serveradapter; appens API ändras inte.
3. Skapa kvottabellen och publicera gatewayen:

```sh
npx wrangler d1 execute mio-limits --remote --file cloudflare/schema.sql
npx wrangler deploy
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put MIO_GATEWAY_TOKEN
```

`secret put` frågar efter värdet i terminalen. API-nyckeln hör bara till första fältet. Gatewaytoken ska vara en **annan** slumpad hemlighet. Generera den lokalt, spara den privat och använd samma värde i det andra hemlighetsfältet och i Mio:

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
```

Alternativt lägger du in API-nyckeln i Cloudflares webbgränssnitt: **Workers & Pages → mio-private-gateway → Settings → Variables and Secrets → Add**. Välj typen **Secret**, namnet `OPENAI_API_KEY` och klistra in värdet där. Spara/publicera ändringen. Skapa nyckeln i ditt eget [OpenAI-projekt](https://platform.openai.com/api-keys); skicka den inte till Codex-chatten. API-användning debiteras separat från ChatGPT-abonnemanget.

Tjänsten svarar med ett konfigurationsfel tills hemligheterna finns. Kör inte `wrangler tail` eller request-/bodyloggning med privat text. `observability` är av i den medföljande konfigurationen. Cloudflares och OpenAI:s egna drift-/datavillkor gäller fortfarande.

## Koppla telefonen

Wrangler visar din HTTPS-adress, exempelvis `https://mio-private-gateway.ditt-namn.workers.dev`.

1. Öppna adressen med `/health` på slutet. `{"status":"ok"}` visar att gatewayen är igång; det bevisar inte att modellen fungerar.
2. I Mio: **AI-assistent → Konfigurera server och tillåt molnfrågor**. Skriv adressen **utan** `/health`, samt gatewaytoken. Spara och tillåt molnfrågor.
3. Fråga ”Vad är 2 + 2?” utan kontext, granska och skicka. Kontrollera både svaret och OpenAI-projektets faktiska användning.
4. Aktivera **AI-tolkning** separat. Prova A07–A14 och L01–L05 i [helhetstestet](../../docs/TESTPLAN_HELHET.md) med syntetiska meningar.

## Gränser och drift

Båda rutterna delar en beständig gräns: standard sex anrop per minut och 100 per UTC-dygn. En atomisk D1-skrivning reserverar ett anrop före modelltrafik; fel räknas också. Ingen kvot kan reserveras när databasen är otillgänglig. Två samtidiga modellförfrågningar tillåts per Worker-instans; den globala minuttakten och dygnskvoten begränsas i databasen.

Gränsen 100 kan räcka ungefär 100 minuters aktiv vardagsanalys om ett utdrag skickas varje minut; frågor och lektionsdelar delar samma pott. Vid 429 stoppas AI-läget och lokal transkription fortsätter. Ändra dygnsgränsen först efter kostnadsprov. En anropskvot är inte en exakt valutabudget.

En omstart eller ny Worker-instans nollställer inte D1-räknarna. Att radera databasen gör det, så gör inte det för att lösa vanliga driftfel. Nyckelrotation: kör respektive `secret put` igen och spara ny gatewaytoken på telefonen. AI-läget behöver återaktiveras efter ändrad anslutning.

## Vad som går att testa utan konton

Från `server/`:

```sh
npm test
WRANGLER_SEND_METRICS=false npm run worker:test
```

Första kommandot provar kontrakt och SQLite-kvot. Det andra bygger med `--dry-run` och kör det riktiga Worker-paketet i lokal workerd/Miniflare med simulerad modell och lokal D1. Inga riktiga modellfrågor görs. Tester ersätter inte driftsättningsprov, modellkvalitet eller iPhone-prov. Node-kompatibiliteten följer [Cloudflares HTTP-stöd](https://developers.cloudflare.com/workers/runtime-apis/nodejs/http/).
