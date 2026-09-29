# Mio: Groq, inloggning och Cloudflare Access — steg för steg

Den här guiden använder **Groq → `qwen/qwen3.8-27b`**. Du kan sedan själv byta till andra modeller i [Mios kompatibilitetskatalog](../PROVIDERS.md#presets-och-tillåtna-modeller), utan Codex. Guiden skiljer engångsuppdatering från vanliga modellbyten.

**Läget 2026-09-29:** källkoden har leverantörsbyte och nu även valfria Access-fält. Den tidigare publicerade gatewayen och iPhone-build 5 innehåller inte allt detta. Källkodens ändring aktiverar inte Cloudflare Access i ditt konto. Den nya appkoden behöver byggas och installeras; denna guide är inte bevis för genomförd driftsättning.

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
6. Aktivera molnfrågor och gör det syntetiska provet i steg 6. Med Access aktiverat behövs även dess par.

Mio accepterar 32–256 bokstäver/siffror/bindestreck/understreck. En lösenordshanterares standardlösenord kan innehålla otillåtna symboler som `!`, `+`, `/` eller `=`. Cloudflare kan spara ett sådant värde trots att Mios app/server avvisar det. Blanksteg, radbrytning, `Bearer ` och citattecken gör också värdet ogiltigt. Klistra aldrig in hemligheter i chatten, Git, skärmbilder eller en URL.

## 2. Engångsuppdateringen som behövs nu

**Bara variabler räcker inte på den gamla OpenAI-gatewayen.** Publicera den nya gatewaykoden en gång. Bygg/installera den nya appen för detaljerade lektionsanteckningar och Access-fälten. Publicering och nytt iOS-bygge görs separat; inget av detta körs automatiskt av guiden.

På datorn, från repots rot:

```sh
cd server
npm ci
npx wrangler login
```

Webbinloggningen gäller administration av Cloudflare, inte Mio. Använd kontot som äger `mio-private-gateway` och den befintliga `mio-limits`-databasen. **Skapa inte en ny Worker eller databas vid uppdatering.**

Kontrollera `server/wrangler.jsonc`: rätt Worker/databas samt `MIO_AI_PROVIDER=groq` och `MIO_AI_MODEL=qwen/qwen3.8-27b`. Ange inga nycklar i filen. Den nya filen har `keep_vars: true` för att bevara extra Dashboard-variabler, men värden som uttryckligen finns i filen kan fortfarande ersätta motsvarande Dashboard-värden. Synka därför modell/provider före senare kodpubliceringar.

Skapa din Groq-nyckel i [Groq Console](https://console.groq.com/keys). Från `server/`, kör:

```sh
npx wrangler secret put GROQ_API_KEY
```

Klistra in Groq-nyckeln vid prompten. Behåll din `MIO_GATEWAY_TOKEN` om du känner till värdet; annars följ steg 1. Kör kontroller och publicera den avsedda koden:

```sh
npm test
WRANGLER_SEND_METRICS=false npm run worker:test
npx wrangler deploy
```

De första två kommandona använder simulerad AI. **Det sista uppdaterar din live-Worker.** Följ sedan [iOS-installationen](../../docs/INSTALLATION.md) för ett nytt bygge från aktuell källkod. Aktivera Access när den uppdaterade appen finns på telefonen; annars blockeras den äldre appen tills den uppdaterats. För att stänga åtkomsten omedelbart kan Access aktiveras tidigare, med detta avbrott som följd.

För ett helt nytt Cloudflare-konto finns databasstegen i [driftguiden](README.md#en-gång-konton-och-installation).

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

4. Spara/publicera ändringen med **Deploy**. Behåll domänen och gatewaytoken vid vanliga modellbyten. Ta bort den äldre textvariabeln `MIO_OPENAI_MODEL` om den finns, för tydlighet.
5. Gör steg 6. Modellen väljs på servern; Groqs Playground-inställningar påverkar inte Mio.

Koden skickar temperatur 0, `reasoning_effort: none` och strikt JSON-schema. Qwen-ID:t finns i Groqs [lista för strikt schema](https://console.groq.com/docs/structured-outputs); `none` stänger av reasoning enligt [Groqs reasoningdokumentation](https://console.groq.com/docs/reasoning). Detta verifierar dokumenterat stöd, inte svensk kvalitet eller åtkomst på ditt konto.

Sex anrop/minut är **Mios tak, inte ett löfte om Groqs kapacitet**. Groq har även tokengränser och andra anrop kan dela dem. Lektionsdelar väntar normalt minst 60 sekunder; vardagsanalys och frågor delar samma dagskvot. Vid 429 väntar du och fortsätter manuellt. Höj inte gränser bara för att komma runt fel.

## 4. Nästa gång: byt själv utan Codex

När den nya gatewaykoden väl körs behöver ett vanligt byte bara detta:

1. Välj en rad i [kompatibilitetskatalogen](../PROVIDERS.md#presets-och-tillåtna-modeller). Kopiera exakt provider och modell-ID, inklusive eventuellt prefix.
2. I samma **Variables and Secrets**: ändra `MIO_AI_PROVIDER`, ändra `MIO_AI_MODEL`, lägg till rätt leverantörsnyckel som **Secret** enligt tabellen.
3. Tryck **Deploy** och prova en liten fråga utan privat kontext. Vid problem: återställ tidigare provider/modell/nyckel och publicera igen.

**Behåll Mios serveradress, gatewaytoken och Access-par.** Ingen ny IPA behövs för katalogbyten. Du behöver inte rotera token vid modellbyte. En gammal leverantörsnyckel används inte när en annan provider valts; den kan tas bort när du inte behöver återgång.

Exempel tillbaka till OpenAI: `MIO_AI_PROVIDER=openai`, `MIO_AI_MODEL=gpt-4.1-mini`, Secret `OPENAI_API_KEY`. Exempel tillbaka till Qwen: `groq`, `qwen/qwen3.8-27b`, `GROQ_API_KEY`.

**Begränsning:** katalogen är medvetet begränsad. Ett nytt modellnamn på leverantörens webbplats blir inte automatiskt tillåtet i Mio. HTTP 422 betyder att kombinationen behöver kompatibilitetsgranskning/kodändring, inte att du ska ändra token. Det finns ingen tyst reservmodell. Egen endpoint med `custom` är ett avancerat kontrakt, inte en genväg runt modellkraven.

## 5. Skydda Workern med Zero Trust / Access

### Vad finns redan?

Källkoden kräver korrekt gatewaytoken för alla tre AI-rutter **före** D1-kvot och modelltrafik. D1 begränsar godkända anrop även över omstarter. Utan Access kan obehöriga ändå skicka anrop som startar Workern och avvisas där; `/health` är också öppen. Anropskvoten för AI skyddar alltså inte Worker-invokationer mot skräptrafik.

Cloudflare Access kontrollerar anrop före Workern. Guidens val är **Access på hela just denna Worker, All traffic**, samt Mios befintliga gatewaytoken. Den som enbart känner till domänen ska stoppas vid Access. Detta eliminerar inte trafik mot Cloudflares nätverk och är ingen garanti mot all överbelastning eller läckta hemligheter. [Cloudflares Worker-skydd](https://developers.cloudflare.com/workers/configuration/cloudflare-access/).

### A. Skapa ett Access-par

1. Öppna **Zero Trust** i Cloudflare och slutför kontots introduktion om det inte är aktiverat.
2. **Access controls → Service credentials → Service Tokens → Create Service Token**.
3. Namn: `Mio iPhone`. Välj giltighetstid och spara **Client ID**, **Client Secret** och utgångsdatum privat.
4. Gå till **Access controls → Policies → Add a policy** (äldre meny: Access → Policies). Namnge den `Mio service token`. Skapa policyn med **Action: Service Auth**, **Include → Service Token → Mio iPhone**. Välj just denna token. Använd inte `Bypass`, `Everyone` eller `Any valid service token`.

Service-token-paret är en separat maskininloggning. `Allow` kan kräva webbinloggning, som Mio inte genomför. [Cloudflares service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/) och [Access-policyer](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/).

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

Börja med tester som inte gör modellfrågor. Sätt din **offentliga adress**, utan nycklar, i kommandot:

```sh
curl -i --max-time 15 'https://mio-private-gateway.mio-private-gateway.workers.dev/health'
```

Utan Access svarar en konfigurerad Worker 200 och `{"status":"ok"}`. **Med Access ska detta anonyma prov blockeras eller hänvisas till inloggning, inte ge gatewayens JSON.** Följ inte redirect med `-L`. Att du redan är inloggad i webbläsaren gör webbläsaren olämplig för det anonyma provet.

Kontrollera även AI-rutterna utan token och med tom syntetisk kropp:

```sh
for route in ask analyze lesson-notes; do
  curl -i --max-time 15 -X POST \
    -H 'Content-Type: application/json' --data '{}' \
    "https://mio-private-gateway.mio-private-gateway.workers.dev/v1/$route"
done
```

Efter Access-aktivering ska samtliga stoppas av Access. En JSON-401 från Mio visar endast att gatewaytoken fungerar som spärr; den visar att anropet kom fram till Workern. Prova också eventuella andra domäner/previews i **Domains & Routes**; de får inte ge en öppen bakväg.

På telefonen, med syntetiska data:

1. Rätt Access-par + avsiktligt fel gatewaytoken: ska nekas av Mio, ingen modellfråga.
2. Rätt gatewaytoken + avsiktligt fel Access Secret: ska stoppas av Access, ingen modellfråga. Ange hela paret vid varje ändring.
3. Återställ rätt värden. Ställ **”Vad är 2 + 2?”**, utan kontext, granska och tryck Skicka. **Detta använder Groqs API-kvot och kan kosta pengar.** Kontrollera svar samt vald modell/användning i Groq Console.
4. Prova sedan ett kort vardagsutdrag och en syntetisk lektion. De använder olika rutter. Aktivera AI-tolkning separat; en sparad anslutning räcker inte.

`/health` visar endast att gatewayens lokala konfigurationskontroll passerar. Den provar inte Groq-nyckel, saldo eller modellåtkomst. Bekräfta skydd i Access-loggen och provresultaten; ett sparat formulär är inte ett godkänt anslutningsprov. Slå inte på request-bodyloggning med privat text.

## 7. Felsökning och rotation

| Symtom | Kontrollera |
|---|---|
| Granska innan du skickar är grå | Slå på **Tillåt molnfrågor** och skriv text under **Din fråga**. Knappen kontrollerar inte token mot servern; AI-tolkning behöver inte vara på |
| Mio säger ogiltig token innan anrop | 32–256 tillåtna tecken. Bara hemliga värdet; inga blanksteg, `Bearer` eller citattecken |
| ”Anslutningen sparades” men inget fungerar | Spara är lokal lagring. Gör ett riktigt syntetiskt prov |
| JSON 401 `unauthorized` | Worker körs men `MIO_GATEWAY_TOKEN` skiljer sig från telefonens värde. Kontrollera rätt Worker och att rotationen publicerats |
| 403, HTML eller inloggningsredirect | Access-par, giltighet och policyn `Service Auth`; Mio följer inte webbinloggning |
| 422 | Provider/modell saknas i Mios katalog eller leverantören avvisade anropets parametrar |
| 503 `gateway_not_configured` | Saknad/felaktig serverkonfiguration eller hemlighet för vald provider |
| 502 efter providerbyte | Bland annat fel leverantörsnyckel, saknad modellåtkomst eller ett ogiltigt modellsvar. Gatewayen döljer detaljer för att skydda data |
| 429 | Mios eller leverantörens kvot. Vänta; höj inte blint. Dagskvoten återställs vid UTC-dygn, inte svensk midnatt |
| 404 på `/v1/lesson-notes` | Den nya gatewaykoden är inte publicerad på adressen |
| Modellen återställs efter kodpublicering | Värdet fanns även i `wrangler.jsonc`. Uppdatera filen till ditt Dashboard-val före nästa deploy |

**Gatewayrotation:** nytt slumpvärde i Workerns `MIO_GATEWAY_TOKEN` → Deploy → samma värde i Mio → Spara → prov. Övriga nycklar behålls.

**Groq-rotation:** ny Groq API key → Workerns `GROQ_API_KEY` → Deploy → prov. Ingenting behöver ändras i telefonen.

**Access-rotation:** hantera service token under Zero Trust, spara aktuellt Client ID/Client Secret och uppdatera båda i Mio. Kontrollera utgångsdatum; spärrad eller utgången token släpper inte igenom appen. Radera/spärra den gamla service tokenen när den inte ska fungera längre. [Cloudflares tokenhantering](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

Lokala frågor, transkription och sparade poster fungerar utan molnanslutning. Inga riktiga hemligheter ingår i exemplen.

## 8. Vad skickas löpande till AI?

**Ja: med AI-tolkning på skickar Mio nya vardagsutdrag för att hitta planer/uppgifter även utan ”Mio”-tilltal.** Det är avsikten i produktbeslutet 2026-09-26 och det som den nuvarande koden gör. Det är inte ett anrop per ord eller mening.

| Situation | Molntrafik |
|---|---|
| AI-tolkning av | Ingen automatisk vardagsanalys. Lokal transkription kan fortsätta |
| AI-tolkning på, vardagssession med ny text | Samlar text ungefär en minut och skickar avgränsade delar, högst åtta fragment/10 000 byte per anrop; minst cirka 60 sekunder mellan anrop |
| Tystnad/ingen ny text | Inga tomma periodiska AI-frågor |
| Vanligt småprat med ny text | Kan skickas. Det finns inget lokalt relevansfilter före molnet; AI kan svara med tomma förslagslistor |
| Vardags-Mio pausas/stoppas | Väntande vardagsanalys kastas; redan skickad text kan inte återkallas |
| Lektion avslutas med godkänt AI-läge | Separata detaljerade anteckningar, högst 3500 byte källtext per del, normalt minst 60 sekunders intervall |
| Enskild fråga | Förhandsgranskning och Skicka krävs; ingen annan kontext än den du valt |

Varje anrop innehåller instruktioner, schema och textunderlag och förbrukar leverantörskvot även om inget planförslag hittas. Med kontinuerligt tal kan standardens 100 anrop per UTC-dygn motsvara ungefär 100 minuters vardagsanalys; frågor och lektionsdelar tar ur samma pott. Detta är inte en heldagsbudget.

AI-tolkning är av vid ny appstart. Spara anslutning eller Tillåt molnfrågor aktiverar inte automatiskt löpande tolkning. Förslag kräver alltid Ja. Om du inte vill skicka vardagssamtal löpande: lämna AI-tolkning av och använd enskilda godkända frågor. Arbetskopian kan också bearbeta en avslutad historisk lektion efter ett separat val. Denna guide ändrar inte analysbeteendet.

### Varning efter ändrade Runtime variables and secrets

Meddelandet **Update your Wrangler configuration with these changes to keep deployments in sync** är en påminnelse om att synka lokala inställningar inför nästa kodpublicering. Det är inte ett autentiseringsfel. JSONC- och TOML-exemplen är två alternativa filformat; Mio använder bara `server/wrangler.jsonc`. Synka textvariabler med `wrangler.jsonc` enligt steg 2. Secrets ska inte kopieras till filen. [Wranglers konfiguration](https://developers.cloudflare.com/workers/wrangler/configuration/).

Meddelandet **This Worker is not protected by Access** betyder att Worker-specifik policy saknas. En domän-/kontopolicy kan ändå gälla; kontrollera detta och kör det anonyma provet i steg 6. Det är skilt från frågan om Mios egen gatewaytoken är korrekt. Spara den exakta varningen och Mios feltext vid felsökning, aldrig hemligheten.

### Om Dashboard visar Groq tillsammans med MIO_OPENAI_MODEL

Cloudflare återger variablerna du matat in; den kontrollerar inte att Mio använder rätt namn. För Groq ska **`MIO_AI_MODEL=qwen/qwen3.8-27b`** finnas, tillsammans med **`MIO_AI_PROVIDER=groq`** och Secret **`GROQ_API_KEY`**. Den nya gatewayen läser `MIO_OPENAI_MODEL` endast som äldre reservinställning för OpenAI. En Qwen-modell i den gamla variabeln räcker alltså inte. Ta bort `MIO_OPENAI_MODEL` för tydlighet och spara/publicera.

Om du fortfarande kör den äldre OpenAI-gatewayen måste även koden uppdateras enligt steg 2. Att korrigera variabelnamnet installerar inte Groq-adaptern. Den lokala Wrangler-filen i arbetskopian innehåller redan de rätta Groq-variablerna, men har inte publicerats genom guidearbetet.

**Proton Pass fungerar som generator:** välj ett slumpat lösenord med exempelvis 48 tecken, bokstäver och siffror, utan specialtecken. Spara exakt samma värde i Workerns Secret `MIO_GATEWAY_TOKEN` och i Mios åtkomsttokenfält. Välj inte lösenfras. En grå granskningsknapp säger inget om huruvida tokenen är rätt; se tabellen ovan innan du roterar igen.
