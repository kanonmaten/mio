# Mios text-AI-gateway på Cloudflare

Gatewayen `mio-private-gateway` är en Cloudflare Worker. Den tar emot godkända frågor, vardagsutdrag och lektionsdelar från appen och skickar dem till vald textmodell. Transkriptionen går **inte** hit; den kräver den separata [Pianissimo-tjänsten](../../transcription-server/README.md).

Guiden gäller den befintliga installationen. Ett helt nytt konto står sist.

**Läge 2026-10-05:** den aktiva Workern kör fortfarande äldre OpenAI-kod (version `4c22cc43-…`), som saknar NIM, Groq, taskprofiler och `/v2`. Att bara ändra variabler i Dashboard räcker därför inte. Ny kod måste publiceras först (steg 3).

## 1. Vilken hemlighet är vilken?

| Namn | Var den skapas | Var den används |
|---|---|---|
| Serveradress | Workerns domän under Workers & Pages | Mio: HTTPS-adress utan path |
| `MIO_GATEWAY_TOKEN` | Du genererar en slumpsträng (se nedan) | Workerns Secret **och** samma värde i Mio → åtkomsttoken |
| `NVIDIA_API_KEY` | [build.nvidia.com](https://build.nvidia.com) → logga in → **Get API Key** (`nvapi-…`) | Endast Workerns Secret |
| Access Client ID + Secret | Zero Trust → Service Tokens (steg 4) | Mio: två separata Access-fält |
| Cloudflare-inloggning/API-token | Ditt Cloudflare-konto | Bara för att publicera; anges aldrig i Mio |

Mio har inget konto. "Logga in" betyder att spara serveradress och hemligheter på telefonen. Skriv bara själva värdet, utan `Bearer` eller citattecken. Klistra aldrig in hemligheter i chatt, Git, skärmbilder eller URL:er.

**Ny gatewaytoken** (32–256 tecken, bara bokstäver, siffror, `-` och `_`):

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
```

En lösenordshanterare fungerar också om du väljer bokstäver och siffror utan specialtecken. Workerns Secret kan inte läsas tillbaka; har du tappat värdet, skapa ett nytt och spara det på båda ställena.

## 2. Byt leverantör eller modell

Aktuellt val är **NVIDIA NIM → `deepseek-ai/deepseek-v4.1-flash`**. Se [katalogen](../PROVIDERS.md) för andra tillåtna modeller och varför GLM 5.3 och Kimi K3 är spärrade.

1. Stäng av AI-tolkning i Mio och låt pågående anrop bli klara.
2. Cloudflare Dashboard → **Workers & Pages → mio-private-gateway → Settings → Variables and Secrets**.
3. Sätt värdena. **Text** och **Secret** är olika typer i dialogen:

   | Namn | Typ | Värde |
   |---|---|---|
   | `MIO_AI_PROVIDER` | Text | `nvidia` |
   | `MIO_AI_MODEL` | Text | `deepseek-ai/deepseek-v4.1-flash` |
   | `NVIDIA_API_KEY` | Secret | Din `nvapi-…`-nyckel |
   | `MIO_REQUESTS_PER_MINUTE` | Text | `20` (NIM tillåter 40/min per nyckel) |
   | `MIO_LESSON_INTERVAL_SECONDS` | Text | `60` |
   | `MIO_GATEWAY_TOKEN` | Secret | Behåll befintlig |

4. **Ta bort** `MIO_REQUESTS_PER_DAY` (ingen daglig gräns; eller ange ett heltal om du vill ha en), `MIO_OPENAI_MODEL` och, när du inte längre behöver gå tillbaka, `GROQ_API_KEY`. Kontrollera att `MIO_AI_TASK_PROFILES` saknas eller pekar på det du vill; den går före de globala värdena.
5. Spara med **Deploy**. Gör sedan steg 5.

Behåll serveradress, gatewaytoken, D1-databas och Access-par vid modellbyten; ingen ny IPA behövs. Exempel tillbaka till Groq: `groq`, `qwen/qwen3.8-27b`, Secret `GROQ_API_KEY`.

Modellen väljs bara på servern. HTTP 422 betyder att kombinationen inte finns i katalogen; det är inget tokenfel. Det finns ingen automatisk reservmodell.

## 3. Publicera ny gatewaykod

Krävs nu (gammal kod är aktiv) och varje gång koden ändras. Kör från den granskade checkouten. Node **>=26.10.0 <27**.

```bash
mio_server="/sökväg/till/Mio/server"   # ändra till din granskade checkout
wrangler() { node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" "$@"; }
npm --prefix "$mio_server" ci
npm --prefix "$mio_server" test
WRANGLER_SEND_METRICS=false npm --prefix "$mio_server" run worker:test
node --input-type=module -e 'console.log((await import(process.argv[1])).RELEASE)' "$mio_server/src/status.mjs"
wrangler whoami
```

Testerna gör inga riktiga modellanrop. Jämför sedan [`wrangler.jsonc`](../wrangler.jsonc) med Dashboard: Worker `mio-private-gateway`, D1-binding `MIO_LIMITS` → `mio-limits` med samma database-ID, `preview_urls:false`, och samma textvariabler som i steg 2. `keep_vars:true` behåller extra Dashboard-värden, men en variabel som står i filen skriver över Dashboard. Secrets står aldrig i filen.

**Först när du uttryckligen bestämt dig för att publicera:**

```bash
wrangler deploy
wrangler deployments list
```

Skapa ingen ny databas, importera inte om schemat och nollställ inga räknare. Rollback: publicera en tidigare **kompatibel** kod/konfiguration via `wrangler rollback` eller Dashboard. Gammal OpenAI-kod med NIM-variabler fungerar inte. Se [Cloudflares versionsmodell](https://developers.cloudflare.com/workers/versions-and-deployments/).

Dashboard-varningen *Update your Wrangler configuration…* betyder bara att `wrangler.jsonc` bör spegla dina Dashboard-värden före nästa deploy.

## 4. Skydda Workern med Cloudflare Access

Gatewaytoken stoppar obehöriga AI-anrop före kvot och modell, men Workern startar ändå för varje anrop och `/health` är öppen. Access stoppar trafiken före Workern.

**A. Skapa service token**

1. **Zero Trust → Access controls → Service credentials → Service Tokens → Create Service Token**, namn `Mio iPhone`. Spara Client ID, Client Secret och utgångsdatum privat.
2. **Access controls → Policies → Add a policy**, namn `Mio service token`, **Action: Service Auth**, **Include → Service Token → Mio iPhone**. Använd inte `Bypass`, `Everyone` eller `Any valid service token`.

**B. Koppla till hela Workern**

1. **Workers & Pages → mio-private-gateway → Access → Protect this Worker behind Access**, välj **All traffic** (inte bara previews), **Apply Access**.
2. Öppna applikationen under **Zero Trust → Access controls → Applications**, koppla Service Auth-policyn och ta bort andra Allow-/Bypass-policyer. Spara.
3. Kontrollera **Domains & Routes**: varje alternativ adress måste vara skyddad eller avstängd.

**C. I Mio**

**Mio → AI-assistent → Konfigurera server och tillåt molnfrågor**: HTTPS-adress, åtkomsttoken (= `MIO_GATEWAY_TOKEN`), slå på **Använd Cloudflare Access**, fyll i Client ID och Client Secret, tryck **Spara anslutning**. Paret sparas i Keychain och skickas i egna headers, aldrig vidare till modelleverantören. Lämnas båda Access-fälten tomma behålls sparat par för samma server.

Källor: [Worker-skydd](https://developers.cloudflare.com/workers/configuration/cloudflare-access/), [service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/), [policyer](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/).

## 5. Kontrollera anslutning och skydd

**Modellfri status.** I Mio: **Testa text-AI-anslutning**. Det anropar skyddad `GET /v2/status`, gör inget modellanrop och förbrukar ingen kvot. Förvänta:

- release `2026-10-05.1` och protocolVersion 2,
- uppgifterna `ask`, `everyday`, `lesson` som `nvidia · deepseek-ai/deepseek-v4.1-flash`,
- "Servern har ingen daglig gräns" (kvoten är `null` när `MIO_REQUESTS_PER_DAY` saknas).

`configured:true` betyder giltig lokal konfiguration, inte att nyckeln, saldot eller modellen fungerar. Ny konfiguration ger 409 en gång i appen; granska och aktivera igen.

**Negativa prov utan credentials.** Ska stoppas av Access (403 eller redirect), inte ge Mios JSON:

```bash
read -r -p 'Mios HTTPS-origin utan path: ' mio_origin; mio_origin="${mio_origin%/}"
for route in health v1/status v2/status; do
  curl -sS --max-time 15 -o /dev/null -w "$route %{http_code}\n" "$mio_origin/$route"
done
for route in v1/ask v1/analyze v1/lesson-notes v2/analyze; do
  curl -sS --max-time 15 -o /dev/null -w "$route %{http_code}\n" -X POST \
    -H 'Content-Type: application/json' --data '{}' "$mio_origin/$route"
done
```

En JSON-401 betyder att anropet nådde Workern och bara gatewaytoken stoppade det: Access saknas på den adressen. Rätt Access-par med fel gatewaytoken ska ge 401 före kvot.

**Riktigt modellprov.** Först efter ett separat beslut: kör de [tre syntetiska proven](../PROVIDERS.md#separat-godkänt-syntetiskt-modellprov). De verifierar strikt JSON, reasoning av och svensk kvalitet hos NIM.

## 6. Felsökning

| Symtom | Orsak och åtgärd |
|---|---|
| Granska innan du skickar är grå | Slå på **Tillåt molnfrågor** och skriv en fråga. Knappen testar inte servern |
| Ogiltig token innan anrop | 32–256 tillåtna tecken, inga blanksteg, `Bearer` eller citattecken |
| JSON 401 `unauthorized` | `MIO_GATEWAY_TOKEN` skiljer sig mellan Worker och telefon, eller rotationen är inte publicerad |
| 403, HTML eller inloggningssida | Access-par, giltighet eller policyn är inte `Service Auth` |
| 404 på `/v2/status` eller `/v1/lesson-notes` | Gammal gatewaykod körs; gör steg 3 |
| 422 | Provider/modell finns inte i [katalogen](../PROVIDERS.md) eller leverantören avvisade parametrarna |
| 422 `task_configuration_invalid` | Läs uppgiftens `configurationError` i statusvyn; provider, modell eller Secret är fel |
| 429 | Mios minutgräns, eventuell dagsgräns, två samtidiga anrop, eller NIM:s 40/min. Vänta och fortsätt manuellt |
| 502 efter byte | Fel eller saknad leverantörsnyckel, saknad modellåtkomst eller ogiltigt modellsvar |
| 503 `gateway_not_configured` | Ogiltig variabel, t.ex. `MIO_REQUESTS_PER_DAY` som inte är ett positivt heltal |
| 503 `budget_store_failed` | D1 svarade inte; ingen modelltrafik startades |
| Modellen återställs efter deploy | Värdet står i `wrangler.jsonc`; uppdatera filen till ditt Dashboard-val |

**Rotation.** Gatewaytoken: nytt värde i Workerns Secret → Deploy → samma värde i Mio. NVIDIA-nyckel: ny nyckel i `NVIDIA_API_KEY` → Deploy; inget ändras i telefonen. Access: nytt service token i Zero Trust → båda fälten i Mio → spärra det gamla.

## 7. Kvot och vad som skickas till AI

Alla fyra genereringsrutter delar en beständig D1-räknare: `MIO_REQUESTS_PER_MINUTE` (högst 60) och, om satt, `MIO_REQUESTS_PER_DAY`. Utan dagsgräns gäller bara minutgränsen, två samtidiga anrop per Worker-instans och NIM:s egna 40/min. Reservationen sker före modellanropet, så ett misslyckat anrop kan ha förbrukat kvot. Text-AI gör inga automatiska omförsök. D1 lagrar bara heltalsräknare.

| Situation | Vad skickas |
|---|---|
| AI-tolkning av (standard vid appstart) | Inget automatiskt |
| AI-tolkning på, ny vardagstext | Ungefär en minuts ny text åt gången, med högst 60 s/4000 byte tidigare kontext; minst 60 s mellan anrop. Det finns inget lokalt relevansfilter, så vanligt småprat kan skickas |
| Tystnad | Inget |
| Lektion avslutas med AI på | Detaljerade anteckningar i delar om högst 3500 byte, minst 60 s mellan delarna |
| Enskild fråga | Bara det du granskat och skickat |

Med kontinuerligt tal blir det ungefär ett anrop per minut, alltså under minutgränsen men långt över den tidigare gränsen på 100 per dag. Förslag kräver alltid Ja. Vill du inte skicka vardagssamtal löpande: lämna AI-tolkning av och använd enskilda frågor.

Loggning av text, nycklar och råa leverantörsfel är avstängd. Kör inte `wrangler tail` med privat text.

## Helt nytt Cloudflare-konto

Bara om du själv bygger en ny installation, aldrig för vanlig uppdatering:

```bash
wrangler login
wrangler d1 create mio-limits          # skriv in det nya database_id i wrangler.jsonc
wrangler d1 execute mio-limits --remote --file "$mio_server/cloudflare/schema.sql"
wrangler secret put NVIDIA_API_KEY
wrangler secret put MIO_GATEWAY_TOKEN
```

Fortsätt sedan med steg 3–5.
