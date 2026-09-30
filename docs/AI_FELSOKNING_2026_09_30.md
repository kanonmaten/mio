# AI-fel, diagnostik och sammanhang mellan anrop

Utredning 2026-09-30. **Utredningens ursprungliga designförslag godkändes därefter genom ”Implementera planen”. Implementation och verifiering i arbetskopian följs i [status](STATUS.md) och [beslut](DECISIONS.md).** Inga privata exporter eller bilder kopieras till repot. Ingen publicering, modelltrafik eller iOS-körning har utförts.

## Bekräftat driftfel

Cloudflares aktiva deployment är `4c22cc43-a625-48d1-86e5-e45638cbcb8e`, skapad 2026-09-29 som en Secret-ändring. Versionsmetadata och den faktiska publicerade koden hämtades med läsanrop via befintlig Wrangler-inloggning. Inga hemlighetsvärden visas eller sparas.

Den publicerade koden:

- tillåter endast `provider === "openai"`;
- läser `OPENAI_API_KEY` och `MIO_OPENAI_MODEL`;
- saknar Groq-adapter och `/v1/lesson-notes`;
- fångar fel under initiering som HTTP 503 med `gateway_not_configured`.

Den aktiva versionens bindningar anger däremot `MIO_AI_PROVIDER=groq`, `MIO_AI_MODEL=qwen/qwen3.8-27b` och `GROQ_API_KEY`. `OPENAI_API_KEY` och `MIO_OPENAI_MODEL` saknas. Denna kombination kan inte initiera den publicerade gatewayen. Samma fel reproducerades utan nät/modell genom att anropa `loadConfig` från repots äldre revision `c6e6f57` med syntetiska Groq-inställningar: `Endast OpenAI-adaptern finns ännu.`

Ett anonymt GET till `/health` gav HTTP 403 och HTML från det yttre Access-skyddet. Det är separat evidens: det säger inget om telefonens autentisering. Telefonbildens generella serverfel är förenligt med 503, men exporten innehåller ingen anropsstatus som bevisar just telefonanropets väg. Installerat byggnummer och fungerande Access-par är fortfarande okända.

**Direkt åtgärd:** publicera den redan befintliga, uppdaterade gatewaykoden efter uttrycklig begäran. Lägg inte tillbaka OpenAI-inställningar för att kringgå versionsfelet. Behåll Access, gatewaytoken, Groq-inställningar och D1. Kontrollera faktisk aktiv kodversion efter publicering; ett anonymt 403 är inte bevis för fungerande Groq. Verkligt syntetiskt modellprov kräver separat godkänd sändning.

## Varför exporten inte hjälper

Den bifogade exporten har schema 2 och tomma innehålls-, sessions- och assistentlistor. Den säger inte varför AI-anropet misslyckades. Detta är en produktbrist, inte bevis för förlorat innehåll.

`MioCloudService.send` avvisar icke-200 utan att läsa serverns tillåtna felkod. Därför blir exempelvis `gateway_not_configured`, `upstream_unavailable` och `invalid_upstream_answer` oskiljbara för användaren. Övriga nätfel blir samma `.network`; underliggande domän/kod går förlorade. Exportmodellen innehåller bara de tre innehållslagren. Sessionsdiagnostik kan inte hjälpa en enskild fråga utan session, och det finns ingen beständig AI-anropsjournal.

Föreslagen rättning:

1. En separat lokal diagnostikjournal, även när ingen session finns. Atomisk lagring, backupundantag och samma filskydd som övriga textlager. Högst 200 händelser och sju dagars retention är föreslagna startvärden. Okänt journalschema får inte skrivas över. Fullständig radering omfattar journalen och spärrar sena diagnostikskrivningar.
2. Exportens valfria `diagnostics` innehåller appversion/build, systemversion, maskinidentifierare, tidszon, ögonblicksbild av aktiverings-/konfigurationsstatus och journalen. Additivt fält behåller schema 2 och äldre avkodning. Dokumentation och H13 uppdateras först vid implementation.
3. Varje anrop får lokalt ID, tid, operation/rutt, varaktighet, request-/response-byteantal, HTTP-status, tillåten gatewayfelkod, begränsad Retry-After och validerade korrelations-ID:n såsom CF-Ray. Nätfel sparar domän och numerisk kod, aldrig godtycklig felbeskrivning. Analys anger nya respektive kontextfragment, källintervall, köstorlek och eventuella kontextbegränsningar. Journalen sparar ingen fråga, transkriptkopia, svarstext, råljud, token eller godtycklig header/svarskropp.
4. Klienten läser en liten, storleksbegränsad JSON-felkropp och känner endast igen förutbestämda felkoder. HTML, okända fält och leverantörens råfel visas eller lagras aldrig. Feltext skiljer Access/auth, ej konfigurerad gateway, inkompatibel modell, kvot, timeout och ogiltigt svar. Kvot/timeout startar ingen automatisk återförsöksslinga.
5. Servern kompletterar med en autentiserad kapabilitets-/statuskontroll utan modelltrafik: protokoll, releaseidentifierare, stödda rutter, modell/provider/promptversion och konfigurationsstatus. Nyckel närvarande betyder inte verifierad nyckel. Ofarlig konfigurationsmetadata hålls tillgänglig även när modellkonfigurationen inte kan initieras; Access och gatewayautentisering ska fortfarande skydda den. Modell- och promptmetadata för fråga/vardag kan återföras i validerade headers utan att bryta de strikta nuvarande svarskropparna.

## Bekräftad gränsbrist

`MioAnalysisCoordinator.observe` väljer bara nya segment efter aktiveringssamtycket. Väntande text slås ihop, men text från ett avslutat AI-anrop används inte i nästa. `MioAnalysisRequest.batches` delar efter fragment-/bytebudget. Modellen har därför inget sammanhang över dessa gränser. Pianissimos ljudöverlapp löser ordtranskription, inte text-AI:ns sammanhang.

En enkel extra minut i samma `fragments` fungerar inte med nuvarande lagring: `MioAssistantRepository.applyAnalysis` returnerar 0 för **hela resultatet** om något fragment redan analyserats. Nuvarande dubblettkontroll jämför dessutom rubrik/typ/tid och endast fortfarande befintliga förslag. Ett omskrivet eller avvisat förslag kan återkomma om nya källfragment införs utan att beslutets identitet bevaras.

## Alternativ och rekommendation

| Lösning | Sammanhang och tillförlitlighet | Latens, kostnad och integritet | Komplexitet |
|---|---|---|---|
| Alltid föregående minut | Hjälper över vanliga gränser men saknar skydd mot dubbletter, korrigeringar och tankar längre än fönstret | Fler input-token och mer återutsänd text; ungefär dubbelt källunderlag vid jämnt minutflöde | Liten klientändring men nödvändiga ändringar i validering/lagring |
| Vänta tills samtalet verkar slut | Kan samla en hel tanke men tystnad eller interpunktion bevisar inte att samtalet är färdigt | Oförutsägbar väntan vid långa samtal; separat semantisk modell innebär drift-/precisionstest och eventuellt fler anrop | Högre komplexitet, särskilt med svensk kvalitet och nuvarande 20 s transkriptionsdelar |
| **Begränsad bakåtkontext + mjuka gränser + stabila beslut** | Förenar nya delar med föregående text; minskar för tidiga förslag och hanterar upprepning/korrigering | Kontrollerad extra input, inga separata AI-anrop för samtalsslut; befintlig minst-minut-takt behålls | Måttlig ändring av befintligt analysflöde och dess kontrakt; rekommenderas |

Rekommendationen är en projektanpassad slutsats, inte ett verifierat kvalitetsresultat. [Deepgram skiljer slutligt textsegment från avslutat yttrande](https://developers.deepgram.com/docs/understand-endpointing-interim-results) och beskriver sammanslagning av flera slutliga delar. [AssemblyAI beskriver semantisk och akustisk turdetektion](https://www.assemblyai.com/docs/universal-streaming/turn-detection); tänkpauser kan felaktigt dela tal vid enbart tystnadsdetektion. Det motiverar att gränser behandlas som ledtrådar. Ingendera källan bevisar svensk precision eller att en mänsklig samtalstur motsvarar en färdig plan i Mio. Ingen ny molntranskription införs.

### Föreslaget beteende för vardag

- **Separata nya källor och kontext.** Ett versionsmärkt analyskontrakt skiljer `newFragments` från `contextFragments`. Modellen får läsa båda, men varje nytt/ändrat förslag måste använda minst en ny källa. Endast de nya fragmenten registreras som analyserade. Källcitat kontrolleras mot exakt skickade fragment; käll-ID:n och originaltider bevaras. Gamla klienter/rutter behålls, och en ny klient stoppar med begripligt versionsfel om gatewayen saknar kontraktet. Ingen tyst nedgradering utan sammanhang.
- **Fönster.** Skicka normalt högst 60 s direkt föregående godkänd vardagstext i samma session. Föreslagen gemensam budget är fortfarande åtta fragment och 10 000 byte källtext/20 000 byte payload, med högst 4 000 byte bakåtkontext. Nytt underlag får inte kapas för att göra plats: batchstorlek anpassas och äldre kontext prioriteras bort först. Kontextbegränsning journalförs och modellen instrueras att markera otillräckligt underlag. Förslag om längre fönster kräver kvalitets-/kostnadsmätning.
- **Mjuka gränser.** Analysera ungefär en gång per minut som tidigare. Vid uppenbar fortsättning vid gränsen kan sändningen skjutas upp till nästa färdiga 20 s-del; sätt ett föreslaget hårt tak på 120 s väntan för äldsta nya text. Tal-/ordtider och interpunktion är ledtrådar, inte säker samtalsslutsdetektion. Saknad interpunktion får inte orsaka oändlig väntan. Om det fortfarande är ofullständigt ska modellen avstå från säkra detaljer och markera osäkerhet. Sista texten vid användarens stopp måste tas om hand inom befintlig takt; eventuell iOS-avbruten bearbetning märks och kräver manuellt nytt samtycke, utan bakgrundslöfte.
- **Stabila förslagsbeslut.** Bevara en beslutskoppling till källor och händelseidentitet, inte enbart modellens rubrik. En komplettering får uppdatera ett väntande utkast med spårbara nya källor; godkända poster ändras aldrig tyst. Avvisade händelser återkommer inte genom omskrivning av samma underlag. En uttrycklig senare ny plan ska däremot kunna föreslås. Låg säkerhet vid sammanslagning leder till synlig fråga, inte en tyst sammanslagning. Exakt identitets-/uppdateringskontrakt behöver fastställas i implementationens spec; detta är designens mest krävande del.
- **Samtycke och avbrott.** Kontext får aldrig hämtas från tiden före aktivering, en annan session, vardag före lektion eller ett raderat underlag. Avstängning, konfigurationsbyte, paus/lektionsbyte och radering rensar relevant arbetskontext och avvisar sena svar. Ljudluckor bryter kontinuitet: fragment före och efter får inte framställas som en komplett mening. Bara lokala begränsade textreferenser behövs; ingen AI-genererad dold minnesprofil och ingen serverägd samtalshistorik.

Exempel: första delen ”Vi ses på biblioteket” och nästa ”på tisdag klockan femton” kan ge ett förslag med båda källorna. Om nästa del säger ”nej, torsdag i stället” används en spårbar komplettering av det väntande utkastet. En redan godkänd plan ändras inte utan ny granskning.

Lektionsanteckningar har ett separat kontrakt och budget på 3500 byte; vardagsfönstret får inte appliceras på dem automatiskt. En eventuell senare lektionsövergångskontext måste rymmas inom samma budget, bevara anteckningarnas ordning och inte räknas som nya färdiga delar. Ingen extra komprimeringsmodell föreslås.

### Precision, batteri och underhåll

Mer lokal textkontext kräver ingen extra GPU-transkription och inget extra turdetektionsanrop. Extra input-token kan öka kostnad och modelllatens; detta ska mätas med syntetiskt material. Telefonens mikrofondrift och befintliga transkriptionsanrop fortsätter, så batteriförbättring får inte påstås. Begränsad lokal textbearbetning bedöms enklare att underhålla än ännu en svensk semantisk ljudmodell. Kontextfönstret kan ändå missa en hänvisning flera minuter bakåt; systemet ska fråga när underlag saknas.

Den lästa aktiva konfigurationen har också ett tak på **100 modellanrop per UTC-dygn**, gemensamt för frågor, vardag och lektioner. Vid ett analyserbart vardagsanrop varje minut räcker det till cirka 100 minuter sådan bearbetning; tysta minuter utan ny text använder inga anrop, och frågor/lektioner minskar återstående utrymme. Kontextöverlapp får därför inte skapa ett extra anrop per del. Detta är en separat kapacitetsbegränsning, inte förklaringen till det bekräftade initieringsfelet. En senare kvotändring kräver uttryckligt val utifrån verklig kostnad och användning.

Groqs aktuella officiella dokumentation listar [Qwen med strikt schema](https://console.groq.com/docs/structured-outputs) och [reasoning_effort=none som faktisk avstängning](https://console.groq.com/docs/reasoning). Dessa delar stämmer med arbetskopians adapter. Det bevisar inte kontoåtkomst, verkligt temperaturbeteende, kvalitet eller att den publicerade äldre koden har dessa funktioner.

## Kontroller utförda nu

- Arbetskopian var ren vid start; utredningen ändrar endast dokumentation.
- `npm test --prefix server`: **40/40 godkända**, mockad AI.
- `WRANGLER_SEND_METRICS=false npm run worker:test --prefix server`: **dry-run och lokal Worker-runtime godkända** för OpenAI/Groq, fråga/analys/lektion, metadata/takt och beständig D1-kvot. Inga externa modellanrop.
- `python3 scripts/verify_project.py`: **142 godkända före dokumentationsändringen, 144 efter**, ingen Swift-kompilering/XCTest.
- Publicerad version och dess kod/bindningar lästa; anonym Access-spärr HTTP 403 kontrollerad. Historiskt konfigurationsfel reproducerat med syntetiska inställningar.
- Ingen publicering, commit/push, ändring av hemligheter/Access, iOS-kompilering, installation eller telefonverifiering.

## Regressioner inför implementation

1. Delad mening, tre eller fler delar, saknad interpunktion, tänkpaus och senare datumkorrigering. Modellkvalitet bedöms separat från mockad transport.
2. Redan analyserad kontext får inte stoppa nytt resultat; kontext ensam får inte skapa nya förslag. Nej/Ja/Inte nu, omstart och omskrivna rubriker återupplivar inte samma beslut.
3. Samtyckesgräns, fördröjd transkription, sessions-/lektionsbyte, verklig ljudlucka, paus/stopp, konfigurationsbyte och radering under väntan/anrop.
4. Svenska multibyte-tecken, fragment-/bytebudget, mycket text/backlog och lång oavslutad tanke: inget nytt underlag förloras tyst och begränsning syns.
5. 401/403/redirect/503, tillåtna/okända felkoder, HTML-fel, 429/Retry-After, nätfel/timeout och för stora felkroppar. Journal utan session, retention/omstart, okänt schema och fullständig radering. Hemligheter och privat text får inte läcka genom fel/headers.
6. Gamla exporter/gatewayversioner och lektionskontrakt bevaras. Xcode Release/XCTest och telefonprov gäller exakt den nya revisionen; de lokala kontrollerna ovan verifierar inte ännu föreslagna ändringar.

Nästa steg: uttrycklig publiceringsbegäran för den befintliga testade Groq-gatewayen; granskning av designförslaget före implementation av diagnostik och nytt sammanhangskontrakt.
