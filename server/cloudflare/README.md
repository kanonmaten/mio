# Text-AI-gateway på Cloudflare

Workers kör gatewayen vid anrop; vald textmodell körs hos sin leverantör. Transkriptionen behöver fortfarande den separata [privata Pianissimo/GPU-tjänsten](../../transcription-server/README.md). Cloudflare-drift gör inte ljudflödet oberoende av den datorn.

[Groq/Access/releaseguiden](GROQ_ACCESS.md) gäller den befintliga `mio-private-gateway`. [Taskprofiler](../PROVIDERS.md) och [kontraktsmatris](../../docs/LEVERANTORSKONTRAKT.md) beskriver modellval och faktisk verifieringsgräns. Workers/D1 och modell-API har separata [drift-/prissättningsvillkor](https://developers.cloudflare.com/workers/platform/pricing/); en anropskvot är ingen valuta- eller tillgänglighetsgaranti.

## Befintlig installation först

Arbetskopian använder befintlig `MIO_LIMITS` → `mio-limits`. **En vanlig kod-/modelluppdatering skapar ingen ny Worker/D1 och importerar inte om kvotschemat.** Behåll räknare, hemligheter, gatewaytoken och Access-policy. Bara textfria heltalsräknare ligger i D1.

Read-only granskning 2026-10-03 bekräftade samma D1 och globala Groq/Qwen-val (sex/minut, 100/UTC-dygn, 60 s lektionsintervall), men aktiv kod är fortfarande äldre OpenAI-only och saknar nya routes. `workers.dev` var aktiverad och previews av. Anonyma health/v2-status gav 403; konkret All traffic/Service Auth och autentiserad åtkomst är ändå **overifierade**. Gamla skärmbilder och en anonym 403 ersätter inte aktuellt policy-/autentiseringsprov. Inga inställningar eller hemligheter ändrades genom granskningen.

Nästa externa steg kräver uttrycklig publiceringsbegäran och den exakta granskade kod/konfigurationskombinationen, följt av read-back och separat syntetiskt sändningsgodkännande. Enbart Dashboard-variabler installerar inte Groq-adaptern.

## Lokal verifiering, katalogoberoende

Node **>=26.10.0 <27**; miniminivån 26.10.0 är testad. Sökvägen måste peka på den avsedda granskade checkouten; den ursprungliga main-kopian och en separat worktree kan innehålla olika kod.

```bash
npm --prefix "$HOME/Documents/ChatGPT/Mio/server" ci
npm --prefix "$HOME/Documents/ChatGPT/Mio/server" test
WRANGLER_SEND_METRICS=false npm --prefix "$HOME/Documents/ChatGPT/Mio/server" run worker:test
```

Detta installerar låsta utvecklingsverktyg och kör lokal syntetisk AI/D1, inklusive faktiskt byggt Worker-paket, v2-status/routing/revision samt tidsgränser/avbrott. Det skickar inga providerfrågor. Repoentry point med Swift/Python/struktur:

```bash
python3 "$HOME/Documents/ChatGPT/Mio/scripts/verify.py"
```

Det är Linux-/källverifiering; Xcode/IPA/installation/iPhone har separata grindar. [Cloudflare beskriver Worker-HTTP:s skillnader från Node](https://developers.cloudflare.com/workers/runtime-apis/nodejs/http/), därför provas båda runtimes.

## En gång för ett helt nytt eget konto

Detta avsnitt gäller ny provisionering som du själv valt. Det gäller **inte** den befintliga Mio-uppdateringen. Skapa först Cloudflare-konto och vald providers API-åtkomst/kostnadskontroll. Nycklar ska endast in i serverns Secrets.

Alla block anger källkatalogen. Ändra sökvägen till din avsedda checkout innan körning:

```bash
mio_server="$HOME/Documents/ChatGPT/Mio/server"
npm --prefix "$mio_server" ci
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" login
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" d1 create mio-limits
```

Webbinloggningen är för administration, inte Mio. Spara det **nya egna** databas-ID:t i din konfiguration med binding `MIO_LIMITS`; ersätt inte en befintlig installations databas för att nollställa kvot. För en ny tom databas importeras [schemat](schema.sql) en gång:

```bash
mio_server="$HOME/Documents/ChatGPT/Mio/server"
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" d1 execute mio-limits --remote --file "$mio_server/cloudflare/schema.sql"
```

Välj exakt provider/model från matrisen, normalt den medföljande Groq/Qwen-konfigurationen, och separata provider-/gatewayhemligheter. Lägg dem privat i Dashboard → Worker → Variables and Secrets, eller med namngiven `secret put` efter uttryckligt vald ändring:

```bash
mio_server="$HOME/Documents/ChatGPT/Mio/server"
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" secret put GROQ_API_KEY
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" secret put MIO_GATEWAY_TOKEN
```

Prompterna tar hemliga värden lokalt; använd inte chatten eller Git. Ny gatewaytoken genereras lokalt och ska vara skild från providerkey. Varken secretrotation eller publicering är del av verifieringskommandona. Följ releaseguidens hela ordning och aktivera All traffic/Service Auth innan appanslutningen godkänns.

## Efter godkänd publicering

Kontrollera aktiv version/bundle/release och matchande offentliga vars/taskprofiler. `keep_vars:true` bevarar extra Dashboard-värden men explicit `vars` i `wrangler.jsonc` kan ersätta motsvarande värden. Bevara `preview_urls:false`, vald Worker, D1 och Secrets. Använd endast kompatibel kod/konfiguration vid rollback.

På telefonen sparas HTTPS-origin, separat gatewaytoken och eventuell Access Client ID/Secret i respektive fält. **Testa text-AI-anslutning** använder endast skyddad `/v2/status`, visar taskprofiler och delad kvot; ingen modellfråga skickas. `configured:true` är inte providercredentials, saldo eller svensk kvalitet. Ny konfigurationsrevision kräver ny preview/aktivering. Kontrollera sedan [negativa skyddsprov](GROQ_ACCESS.md#6-kontrollera-anslutning-och-skydd).

Verkliga fråga/vardag/lektion-prov körs först efter separat godkännande av [syntetisk payload/profil/anropsantal](../../docs/LEVERANTORSKONTRAKT.md#separat-godkänt-syntetiskt-modellprov). De kan kosta pengar. Ny matching IPA och iPhone-acceptans behövs efteråt.

## Kvot, integritet och återhämtning

Alla fyra genereringsrutter delar befintlig beständig D1-minut/dygnskvot: normalt sex/minut och högst **100 per UTC-dygn**. Två samtidiga genereringar tillåts per Worker-instans; det är ingen global concurrencytjänst. En atomisk reservation sker före providertrafik och fel kan förbruka kvot. En sen okansellerbar D1-operation får aldrig starta senare modelltrafik eller unsafe refund. Budget-storefel stoppar generering med eget 503; den post-body deadline som omfattar hela kedjan är 40 s.

Skyddade `/v1/status` och `/v2/status` reserverar ingen AI-kvot. V2 läser bara kvarvarande räknare med en kort tidsgräns; kvarvarande kapacitet kan därför vara okänd. En omstart/deploy nollställer inte D1. Radera inte databasen eller höj dagsgränsen för att lösa fel. 100 delade anrop räcker inte för kontinuerlig heldagsanalys; appen visar kvarvarande lektionsarbete som förväntat, inte reserverat.

Text/keys/IP/adressloggar och råa providerfel används inte. Medföljande observability är av; behåll body/Authorization-loggning avstängd och kontrollera externa datavillkor. Kör inte `wrangler tail` med privat text. Text-AI har manuella retries, och sparade lektionsdelar fortsätts manuellt utan att dupliceras. Transkription har egen bounded RAM-/retry-/expiry-policy och inga råljudsfiler.
