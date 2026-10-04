# Mio: Groq, inloggning och Cloudflare Access — steg för steg

Den här guiden använder **Groq → `qwen/qwen3.8-27b`**. Du kan sedan själv byta till andra modeller i [Mios kompatibilitetskatalog](../PROVIDERS.md#presets-och-tillåtna-modeller), utan Codex. Guiden skiljer engångsuppdatering från vanliga modellbyten.

**Aktuellt read-only läge 2026-10-03:** Dashboard har Groq/Qwen (6/minut, 100/UTC-dygn, 60 s), samma D1 och provider-/gatewayhemlighetsnamn, men aktiv version `4c22cc43-a625-48d1-86e5-e45638cbcb8e` kör äldre OpenAI-only-kod. Den saknar Groq, taskprofiler, v2-status/v2-analys och detaljerade lektioner. Anonyma `/health` och `/v2/status` gav 403; previews var av. Aktuell All traffic/Service Auth-policy och autentiserad åtkomst är ändå overifierade. Det är ingen bekräftelse på provideråtkomst eller fungerande rollback.

**Historik 2026-09-29:** en tidigare Dashboard-granskning rapporterade Access aktiverat och service-token ännu inte använd. Det är ett daterat underlag, inte bevis för dagens policy eller den nya revisionen. Den gamla iPhone-builden verifierar inte arbetskopian. Publicering, matching Xcode/IPA och telefonprov återstår separat.

## 1. Vilken token är vilken?

| Uppgift | Var finns/skapas den? | Var används den? |
|---|---|---|
| Serveradress | Workerns domän under Workers & Pages | Mio: HTTPS-adress utan `/health` eller `/v1/ask` |
| **Mios åtkomsttoken** | Du väljer en slumpad hemlighet och sparar som **`MIO_GATEWAY_TOKEN`** under Workerns Secrets | **Samma hemliga värde i Mio → åtkomsttoken** |
| Groq API key | [Groq Console → API Keys](https://console.groq.com/keys) | Bara Workerns Secret **`GROQ_API_KEY`** |
| Access Client ID + Client Secret | Cloudflare Zero Trust → Service Tokens, steg 5 | Nya Mio-appens två separata Access-fält |
| Cloudflare API token / Wrangler-inloggning | Cloudflare-kontot, för administration | Hantera/publicera Workern; ska inte anges i Mio |

Mio har inget användarkonto med e-post/lösenord. Att ”logga in” betyder att spara serveradress och hemligheter på telefonen. Appen skickar gatewaytoken som `Authorization: Bearer …`. Du skriver **bara värdet**, utan `Bearer`, citattecken eller namnet `MIO_GATEWAY_TOKEN`.

**Om du roterade Workerns `MIO_GATEWAY_TOKEN` var det rätt token.** Efter att ändringen publicerats måste du även spara det nya värdet i Mio. Den gamla kopian på telefonen uppdateras inte automatiskt. Om rotationen skedde under My Profile → API Tokens eller Zero Trust → Service Tokens var det en annan token.

### Jag vet inte värdet längre

Workerns sparade Secret går inte att läsa tillbaka i klartext. Ersätt det:

1. Stäng av AI i Mio.
2. Generera en ny slumpad sträng lokalt. I en terminal på din egen dator:

   ```sh
   node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
   ```

3. Spara strängen privat i din lösenordshanterare. Den blir 43 tecken. Använd inte ett vanligt lösenord eller en Groq-nyckel.
4. [Cloudflare Dashboard](https://dash.cloudflare.com/) → **Workers & Pages → mio-private-gateway → Settings → Variables and Secrets**. Redigera `MIO_GATEWAY_TOKEN` (eller Add om den saknas), välj **Secret**, klistra in strängen och spara/publicera med **Deploy**.
5. Klistra in **exakt samma sträng** i Mios fält för ny åtkomsttoken. Tryck **Spara anslutning**. Spara är endast lokal lagring; det testar inte servern.
6. Aktivera molnfrågor och gör först modellfri anslutningskontroll i steg 6. Med Access behövs även dess par. Ett modellprov kräver separat sändningsgodkännande.

Mio accepterar 32–256 bokstäver/siffror/bindestreck/understreck. En lösenordshanterares standardlösenord kan innehålla otillåtna symboler som `!`, `+`, `/` eller `=`. Cloudflare kan spara ett sådant värde trots att Mios app/server avvisar det. Blanksteg, radbrytning, `Bearer ` och citattecken gör också värdet ogiltigt. Klistra aldrig in hemligheter i chatten, Git, skärmbilder eller en URL.

## 2. Publicera exakt granskad kod efter godkännande

Arbetskopians release är `2026-10-03.1`; [serverguiden](../README.md) beskriver fyra separata ansvar, taskprofiler och v2-status. Historisk commit/build visar inte att denna kod är publicerad eller iOS-verifierad. Variabeländring installerar inte den nya bundeln.

Före publiceringsbegäran ska den avsedda checkouten/revisionen, lokala kontroller, bundeldigest och offentliga vars/taskprofiler vara granskade. Utveckling i en worktree ligger inte automatiskt i huvudkatalogen. Nedanstående exempel använder en uttrycklig källsökväg; ändra den till **exakt den granskade checkouten**. Releasekontrollen vägrar den gamla koden:

```bash
mio_server="$HOME/Documents/ChatGPT/Mio/server"
test -f "$mio_server/src/task-profiles.mjs"
node --input-type=module -e 'const { RELEASE } = await import(process.argv[1]); if (RELEASE !== "2026-10-03.1") process.exit(1); console.log(RELEASE)' "$mio_server/src/status.mjs"
npm --prefix "$mio_server" ci
npm --prefix "$mio_server" test
WRANGLER_SEND_METRICS=false npm --prefix "$mio_server" run worker:test
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" whoami
```

Kontrollerna gör syntetiska anrop. Befintlig Wrangler-auth återanvänds. Om senare auktoriserad publicering kräver nya OAuth-scopes slutför användaren webbinloggningen; inga Secrets ska klistras in i chatten. Utvecklingsverktygen är låsta och kräver Node >=26.10.0 <27. Repoentry point finns i [serverguiden](../README.md#verifiera-utan-modelltrafik).

Jämför `wrangler.jsonc` med Dashboard: Worker `mio-private-gateway`, befintlig D1-binding `MIO_LIMITS`, samma `mio-limits`/database-ID, befintliga Secrets, provider/model/taskprofiler, kvot/intervall samt `preview_urls:false`. `keep_vars:true` skyddar inte uttryckliga motstridiga värden i filen. Skapa ingen ny databas, importera inte om schema och nollställ inga räknare. Behåll fungerande hemligheter/Access; rotation är ett separat beslut.

**Först efter uttrycklig publiceringsbegäran**, från samma granskade källsökväg:

```bash
mio_server="$HOME/Documents/ChatGPT/Mio/server"
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" deploy
node "$mio_server/node_modules/wrangler/bin/wrangler.js" --cwd "$mio_server" deployments list
```

Det första kommandot ändrar livekod. Registrera och read-verifiera aktiv version/release/bundle samt autentiserad `/v2/status`. Verifiera negativa Access/gateway-auth och alternativa adresser enligt steg 6. Publiceringsgodkännande är inte sändningsgodkännande: [tre exakta syntetiska modellprov](../../docs/LEVERANTORSKONTRAKT.md#separat-godkänt-syntetiskt-modellprov) godkänns separat. Följ sedan [iOS-installationen](../../docs/INSTALLATION.md) med samma revision och prova native-/telefonflöden.

Om CLI-publicering inte fungerar används samma verifierade bundle/konfiguration genom kontots stödda publiceringsflöde, med samma read-back. Rollback kräver kompatibel kod/konfiguration; äldre OpenAI-kod med Groq-vars är inte en fungerande återgång. [Cloudflares versions-/deploymentmodell](https://developers.cloudflare.com/workers/versions-and-deployments/).

Nytt eget konto har separata [engångssteg](README.md#en-gång-för-ett-helt-nytt-eget-konto); de ska aldrig köras för vanlig uppdatering av befintlig Mio.

## 3. Välj Qwen hos Groq i webbgränssnittet

Efter engångsuppdateringen:

1. Stäng av AI-tolkning i Mio och låt pågående anrop avslutas.
2. Öppna **Workers & Pages → mio-private-gateway → Settings → Variables and Secrets**.
3. Sätt följande värden. **Text** och **Secret** är olika typer i Add/Edit-dialogen:

   | Namn | Typ | Värde |
   |---|---|---|
   | `MIO_AI_PROVIDER` | Text | `groq` |
   | `MIO_AI_MODEL` | Text | `qwen/qwen3.8-27b` |
   | `GROQ_API_KEY` | Secret | Din nyckel från Groq |
   | `MIO_GATEWAY_TOKEN` | Secret | Din egen åtkomsttoken från steg 1 |
   | `MIO_LESSON_INTERVAL_SECONDS` | Text | `60` |
   | `MIO_REQUESTS_PER_MINUTE` | Text | `6` |
   | `MIO_REQUESTS_PER_DAY` | Text | `100` |

4. Efter uttryckligt vald ändring: spara/publicera **Deploy**. Behåll domänen/gatewaytoken och granska eventuell `MIO_AI_TASK_PROFILES`; overrides kan annars välja andra profiler än global Qwen. Inför senare kodpublicering ska explicita Wrangler-vars matcha Dashboard. Ingen automatisk modellfallback finns.
5. Gör steg 6. Modellen väljs på servern; Groqs Playground-inställningar påverkar inte Mio.

Koden skickar temperatur 0, `reasoning_effort: none` och strikt JSON-schema. Qwen-ID:t finns i Groqs [lista för strikt schema](https://console.groq.com/docs/structured-outputs); `none` stänger av reasoning enligt [Groqs reasoningdokumentation](https://console.groq.com/docs/reasoning). Detta verifierar dokumenterat stöd, inte svensk kvalitet eller åtkomst på ditt konto.

Sex anrop/minut är **Mios tak, inte ett löfte om Groqs kapacitet**. Groq har även tokengränser och andra anrop kan dela dem. Lektionsdelar väntar normalt minst 60 sekunder; vardagsanalys och frågor delar samma dagskvot. Vid 429 väntar du och fortsätter manuellt. Höj inte gränser bara för att komma runt fel.

## 4. Nästa gång: byt själv utan Codex

När den nya gatewaykoden väl körs behöver ett vanligt byte bara detta:

1. Välj en rad i [kompatibilitetskatalogen](../PROVIDERS.md#presets-och-tillåtna-modeller). Kopiera exakt provider och modell-ID, inklusive eventuellt prefix.
2. I samma **Variables and Secrets**: ändra `MIO_AI_PROVIDER`, ändra `MIO_AI_MODEL`, lägg till rätt leverantörsnyckel som **Secret** enligt tabellen.
3. Efter godkänd konfigurationsändring: **Deploy**, modellfri `/v2/status`, ny preview/aktivering och separat godkänt syntetiskt modellprov. Vid problem återställs endast en kompatibel kod/konfigurationskombination; inget automatiskt omförsök eller ny provider väljs.

**Behåll Mios serveradress, gatewaytoken och Access-par.** Ingen ny IPA behövs för katalogbyten. Du behöver inte rotera token vid modellbyte. En gammal leverantörsnyckel används inte när en annan provider valts; den kan tas bort när du inte behöver återgång.

Exempel tillbaka till OpenAI: `MIO_AI_PROVIDER=openai`, `MIO_AI_MODEL=gpt-4.1-mini`, Secret `OPENAI_API_KEY`. Exempel tillbaka till Qwen: `groq`, `qwen/qwen3.8-27b`, `GROQ_API_KEY`.

**Begränsning:** katalogen är medvetet begränsad. Ett nytt modellnamn på leverantörens webbplats blir inte automatiskt tillåtet i Mio. HTTP 422 betyder att kombinationen behöver kompatibilitetsgranskning/kodändring, inte att du ska ändra token. Det finns ingen tyst reservmodell. Egen endpoint med `custom` är ett avancerat kontrakt, inte en genväg runt modellkraven.

## 5. Skydda Workern med Zero Trust / Access

### Vad finns redan?

Källkoden kräver korrekt gatewaytoken för alla fyra AI-rutter (`/v1/ask`, `/v1/analyze`, `/v1/lesson-notes`, `/v2/analyze`) **före** D1-kvot och modelltrafik. Även `/v1/status` och `/v2/status` kräver gatewaytoken utan AI-kvotreservation; v2 läser bara aktuell D1-kvot. D1 begränsar godkända modellanrop även över omstarter. Utan Access kan obehöriga ändå skicka anrop som startar Workern och avvisas där; `/health` är också öppen. Anropskvoten för AI skyddar alltså inte Worker-invokationer mot skräptrafik.

Cloudflare Access kontrollerar anrop före Workern. Guidens val är **Access på hela just denna Worker, All traffic**, samt Mios befintliga gatewaytoken. Den som enbart känner till domänen ska stoppas vid Access. Detta eliminerar inte trafik mot Cloudflares nätverk och är ingen garanti mot all överbelastning eller läckta hemligheter. [Cloudflares Worker-skydd](https://developers.cloudflare.com/workers/configuration/cloudflare-access/).

### A. Skapa ett Access-par

1. Öppna **Zero Trust** i Cloudflare och slutför kontots introduktion om det inte är aktiverat.
2. **Access controls → Service credentials → Service Tokens → Create Service Token**.
3. Namn: `Mio iPhone`. Välj giltighetstid och spara **Client ID**, **Client Secret** och utgångsdatum privat.
4. Gå till **Access controls → Policies → Add a policy** (äldre meny: Access → Policies). Namnge den `Mio service token`. Skapa policyn med **Action: Service Auth**, **Include → Service Token → Mio iPhone**. Välj just denna token. Använd inte `Bypass`, `Everyone` eller `Any valid service token`.

Service-token-paret är en separat maskininloggning. `Allow` kan kräva webbinloggning, som Mio inte genomför. [Cloudflares service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/) och [Access-policyer](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/).

**Session Duration:** kontrollera aktuellt val i kontot. Mio skickar Client ID/Secret på varje anrop och använder ingen webbläsarsession. Tjänstetokens separata utgångsdatum måste kontrolleras och registreras privat; en historisk giltighetsuppgift är inte bevis för aktuellt par. [Cloudflares sessionshantering](https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/) och [service-tokenhantering](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

### B. Koppla policyn till hela Workern

1. **Workers & Pages → mio-private-gateway → Access → Protect this Worker behind Access**.
2. Välj **All traffic**, så att även produktion skyddas. `Previews only` räcker inte.
3. Skapa skyddet med en policy för ditt eget Cloudflare-konto om snabbvyn bara erbjuder kontoinloggning. Tryck **Apply Access**.
4. Öppna den skapade applikationen under **Zero Trust → Access controls → Applications** (kan heta **Access → Applications**). Redigera dess policyer och koppla **Service Auth**-policyn från A. Ta bort den tillfälliga kontopolicyn och andra Allow-/Bypass-policyer om endast telefonens service token ska släppas igenom. Spara.
5. Bekräfta att skyddet gäller **mio-private-gateway och All traffic**. Detta omfattar dess domäner och previews. Behåll dessutom `preview_urls: false` i Wrangler-filen. Om du i stället skyddar en enskild domän måste varje alternativ Worker-adress skyddas eller stängas separat.

Avancerade policyer redigeras i Zero Trust efter att Worker-skyddet skapats. [Officiell instruktion](https://developers.cloudflare.com/workers/configuration/cloudflare-access/). Denna repoändring skapar inte policyn i ditt konto.

### C. Lägg Access-paret i den uppdaterade Mio-appen

**Mio → AI-assistent → Konfigurera server och tillåt molnfrågor** (äldre vy kan heta Fråga Mio med AI):

- HTTPS-adress: din befintliga domän.
- Åtkomsttoken: samma värde som `MIO_GATEWAY_TOKEN`.
- Slå på **Använd Cloudflare Access**.
- **Access Client ID**: Client ID från A.
- **Access Client Secret**: Client Secret från A.
- Tryck **Spara anslutning**, slå på **Tillåt molnfrågor** och prova steg 6.

Saknas Access-fälten kör du en äldre appbuild. Paret kan inte klistras in i fältet åtkomsttoken. Ny kod sparar alla tre värden tillsammans i Keychain på telefonen, utanför export, och skickar Access-paret i separata headers på alla AI-rutter. De skickas inte vidare till Groq. Ingen webbinloggning eller cookie krävs.

Båda Access-fälten tomma behåller sparat par på samma server. För att byta paret fyller du i båda igen. Stäng av Access-reglaget och spara för att radera paret lokalt; det stänger **inte** av policyn i Cloudflare. Vid ändrad serveradress behöver alla hemligheter anges igen.

## 6. Kontrollera anslutning och skydd

### Modellfri status och verifiering av publicerad revision

Efter publicering: använd nya appens **Testa text-AI-anslutning** eller en kontrollerad skyddad GET `/v2/status`. Ange aktuellt Access-par och gatewaytoken privat, följ inga redirects och skriv inte ut headers/credentials/URL/rå felkropp. Status gör inget modellanrop och ingen kvotreservation.

Kontrollera release `2026-10-03.1`, protocolVersion 2, 64 hextecken konfigurationsrevision, taskprofiler (`ask`, `everyday`, `lesson`) med rätt provider/model/capabilities/configurationError och quota högst 100. Kvarvarande kvot/reset kan vara okända. Jämför även aktiv Worker-version/bundeldigest. `configured:true` bevisar lokal konfiguration, inte providercredentials, saldo eller modellkvalitet. Gamla `/v1/status` är kompatibilitetsgränssnitt; v2 behövs för nya profiler/revision/kapacitet.

### Negativa skyddsprov utan modelltrafik

Kontrollera aktuell Worker-specifik **All traffic**-policy och exakt service token i Zero Trust. Anonym 403/redirect visar bara att det anropet spärrats; det bevisar inte att rätt policy/par/alternativa adress gäller. Med korrekt Access-par men fel gatewaytoken ska Mio ge 401 före kvot. Fel Access-par ska stoppas före Worker. Kör inga kompletta giltiga AI-payloads i negativa prov.

En anonym kontroll kan köras i Bash med offentlig HTTPS-origin utan credentials. Resultatet skriver endast HTTP-kod och följer ingen redirect:

```bash
read -r -p 'Mios HTTPS-origin utan nycklar eller path: ' mio_origin
mio_origin="${mio_origin%/}"
for mio_route in health v1/status v2/status; do
  curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}\n' "$mio_origin/$mio_route"
done
```

Access ska stoppa dessa före gatewayens JSON. Testa även alla genereringsrutter utan credentials med en **tom** syntetisk kropp:

```bash
read -r -p 'Mios HTTPS-origin utan nycklar eller path: ' mio_origin
mio_origin="${mio_origin%/}"
for mio_route in v1/ask v1/analyze v1/lesson-notes v2/analyze; do
  curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}\n' \
    -X POST -H 'Content-Type: application/json' --data '{}' "$mio_origin/$mio_route"
done
```

En JSON-401 från Mio visar att anropet nådde Workern och endast gatewaytoken spärrade det. Kontrollera även övriga Domains & Routes; alternativa adresser får inte skapa bypass. Previews hålls av. Bevara skyddet vid publicering, och dokumentera policy/read-back samt negativa/positiva authprov utan hemligheter.

### Separat sändningsgodkännande

Efter skyddad status/read-back godkänns [exakt syntetisk fråga/vardag/lektion](../../docs/LEVERANTORSKONTRAKT.md#separat-godkänt-syntetiskt-modellprov), profiler och anropsantal separat. Först därefter Skicka/aktivera läget; det kan förbruka kvot och kosta pengar. Requestparametrar, reported reasoning-usage, grundning, datum och metadata kontrolleras enligt matrisen. Aktiverings-/frågesamtycke i appen bevaras; statuskontroll aktiverar inte mikrofon eller analys.

## 7. Felsökning och rotation

| Symtom | Kontrollera |
|---|---|
| Granska innan du skickar är grå | Slå på **Tillåt molnfrågor** och skriv text under **Din fråga**. Knappen kontrollerar inte token mot servern; AI-tolkning behöver inte vara på |
| Mio säger ogiltig token innan anrop | 32–256 tillåtna tecken. Bara hemliga värdet; inga blanksteg, `Bearer` eller citattecken |
| ”Anslutningen sparades” men inget fungerar | Spara är lokal lagring. Testa först modellfri text-AI-anslutning, därefter separat godkänt syntetiskt modellprov |
| JSON 401 `unauthorized` | Worker körs men `MIO_GATEWAY_TOKEN` skiljer sig från telefonens värde. Kontrollera rätt Worker och att rotationen publicerats |
| 403, HTML eller inloggningsredirect | Access-par, giltighet och policyn `Service Auth`; Mio följer inte webbinloggning |
| 422 | Provider/modell saknas i Mios katalog eller leverantören avvisade anropets parametrar |
| 422 `task_configuration_invalid` | Läs taskens fasta configurationError i v2-status; provider/model/options/Secret är lokalt ogiltigt, inget modellanrop ska startas |
| 503 `budget_store_failed` | D1-reservation kunde inte genomföras; gör inga antagna refunds eller sena modellförsök |
| 502 efter providerbyte | Bland annat fel leverantörsnyckel, saknad modellåtkomst eller ett ogiltigt modellsvar. Gatewayen döljer detaljer för att skydda data |
| 429 | Lokal minut/dag/concurrency eller providerkvot. Följ väntetid/manuell fortsättning; högst100/dag. UTC-dygn gäller |
| 404 på `/v2/status`, `/v2/analyze` eller `/v1/lesson-notes` | Kontrollera att den nya gatewaykoden är publicerad och aktiv på adressen |
| Modellen återställs efter kodpublicering | Värdet fanns även i `wrangler.jsonc`. Uppdatera filen till ditt Dashboard-val före nästa deploy |

**Gatewayrotation:** nytt slumpvärde i Workerns `MIO_GATEWAY_TOKEN` → Deploy → samma värde i Mio → Spara → prov. Övriga nycklar behålls.

**Groq-rotation:** ny Groq API key → Workerns `GROQ_API_KEY` → Deploy → prov. Ingenting behöver ändras i telefonen.

**Access-rotation:** hantera service token under Zero Trust, spara aktuellt Client ID/Client Secret och uppdatera båda i Mio. Kontrollera utgångsdatum; spärrad eller utgången token släpper inte igenom appen. Radera/spärra den gamla service tokenen när den inte ska fungera längre. [Cloudflares tokenhantering](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

Manuella poster och historik fungerar utan text-AI. Transkription kräver egen privat Pianissimo/Tailscale-anslutning. Inga riktiga hemligheter ingår i exemplen.

## 8. Vad skickas löpande till AI?

**Ja: med AI-tolkning på skickar Mio nya vardagsutdrag för att hitta planer/uppgifter även utan ”Mio”-tilltal.** Det är avsikten i produktbeslutet 2026-09-26 och det som den nuvarande koden gör. Det är inte ett anrop per ord eller mening.

| Situation | Molntrafik |
|---|---|
| AI-tolkning av | Ingen automatisk vardagsanalys. Lokal transkription kan fortsätta |
| AI-tolkning på, vardagssession med ny text | Samlar normalt en minut, med högst en extra minut vid mjuk meningsgräns. V2 skiljer ny text från högst 60 s/4000 byte tidigare godkänd kontext; totalt högst åtta fragment/10 000 byte. Nästa sändning tidigast 60 s efter föregående sändningsslut |
| Tystnad/ingen ny text | Inga tomma periodiska AI-frågor |
| Vanligt småprat med ny text | Kan skickas. Det finns inget lokalt relevansfilter före molnet; AI kan svara med tomma förslagslistor |
| Vardags-Mio pausas/stoppas med AI-läget fortsatt godkänt | Väntan väcks för kvarvarande godkänd text. Ny lyssning får ny kontextgräns; redan skickad text kan inte återkallas |
| Lektion avslutas med godkänt AI-läge | Separata detaljerade anteckningar, högst 3500 byte källtext per del, normalt minst 60 sekunders intervall |
| Enskild fråga | Förhandsgranskning och Skicka krävs; ingen annan kontext än den du valt |

Varje anrop innehåller instruktioner, schema och textunderlag och förbrukar leverantörskvot även om inget planförslag hittas. Med kontinuerligt tal kan standardens 100 anrop per UTC-dygn motsvara ungefär 100 minuters vardagsanalys; frågor och lektionsdelar tar ur samma pott. Detta är inte en heldagsbudget.

AI-tolkning är av vid ny appstart. Spara anslutning eller Tillåt molnfrågor aktiverar inte automatiskt löpande tolkning. Förslag kräver alltid Ja. Om du inte vill skicka vardagssamtal löpande: lämna AI-tolkning av och använd enskilda godkända frågor. Arbetskopian kan också bearbeta en avslutad historisk lektion efter ett separat val. Manuell fortsatt lektionsbearbetning från avstängt läge visar uttryckligt samtycke även till nya vardagsutdrag och senare avslutade lektioner. Sparade delar bevaras, rättningar märker äldre/okänd källa och inget korrigerat material skickas automatiskt igen.

### Varning efter ändrade Runtime variables and secrets

Meddelandet **Update your Wrangler configuration with these changes to keep deployments in sync** är en påminnelse om att synka lokala inställningar inför nästa kodpublicering. Det är inte ett autentiseringsfel. JSONC- och TOML-exemplen är två alternativa filformat; Mio använder bara `server/wrangler.jsonc`. Synka textvariabler med `wrangler.jsonc` enligt steg 2. Secrets ska inte kopieras till filen. [Wranglers konfiguration](https://developers.cloudflare.com/workers/wrangler/configuration/).

Meddelandet **This Worker is not protected by Access** betyder att Worker-specifik policy saknas. En domän-/kontopolicy kan ändå gälla; kontrollera detta och kör det anonyma provet i steg 6. Det är skilt från frågan om Mios egen gatewaytoken är korrekt. Spara den exakta varningen och Mios feltext vid felsökning, aldrig hemligheten.

### Om Dashboard visar Groq tillsammans med MIO_OPENAI_MODEL

Cloudflare återger variablerna du matat in; den kontrollerar inte att Mio använder rätt namn. För Groq ska **`MIO_AI_MODEL=qwen/qwen3.8-27b`** finnas, tillsammans med **`MIO_AI_PROVIDER=groq`** och Secret **`GROQ_API_KEY`**. Den nya gatewayen läser `MIO_OPENAI_MODEL` endast som äldre reservinställning för OpenAI. En Qwen-modell i den gamla variabeln räcker alltså inte. Ta bort `MIO_OPENAI_MODEL` för tydlighet och spara/publicera.

Om du fortfarande kör den äldre OpenAI-gatewayen måste även koden uppdateras enligt steg 2. Att korrigera variabelnamnet installerar inte Groq-adaptern. Den lokala Wrangler-filen i arbetskopian innehåller redan de rätta Groq-variablerna, men har inte publicerats genom guidearbetet.

**Proton Pass fungerar som generator:** välj ett slumpat lösenord med exempelvis 48 tecken, bokstäver och siffror, utan specialtecken. Spara exakt samma värde i Workerns Secret `MIO_GATEWAY_TOKEN` och i Mios åtkomsttokenfält. Välj inte lösenfras. En grå granskningsknapp bevisar inte att tokenen är rätt; se tabellen ovan innan du roterar igen.
