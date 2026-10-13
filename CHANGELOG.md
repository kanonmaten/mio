# Ändringslogg

## Helhetsbygget 2026-10-11 (pågår)

- **Snabbare "Bygg Mio IPA" (2026-10-13):** IPA:n byggs i ett eget jobb parallellt med testerna och väntas vara klar efter cirka 5 minuter i stället för 21. Simulatorn startar medan testerna kompileras, concurrency-diagnosen körs sist i testjobbet och skärmbilderna av Hem tas bara när rutan "Ta skärmbilder" bockas i vid start. Artefakterna heter som förut (`Mio-IPA`, `Mio-screenshots`); diagnostiken delas i `Mio-native-ipa` och `Mio-native-tests`. Ingen appkod är ändrad. Inte körd ännu.
- **AI-svar utan förslag syns (2026-10-13):** i telefonprovet 2026-10-12 nådde alla 12 anrop Groq och kom tillbaka (11 vardagsgenomgångar och en fråga, 21 080 token), men modellen gav 0 förslag och appen visade inget, så det såg ut som att svaren försvann. Nu visar Hem "AI granskade senast kl. HH:MM · inga förslag" (eller antal förslag) och leder till sessionen, där en ny sektion, AI-genomgångar, listar varje svar med tid, antal textdelar, antal förslag och AI:ns frågor om texten. Inget nytt sparas; vyn läser befintliga analysposter. Vardagsprompten (version `2026-10-13.1`, gateway-release `2026-10-13.1`) gör nu en tydlig plan eller uppgift med konkret klockslag till ett förslag med oklar dag och frågan i förslagets text, i stället för att bara lägga den som osäkerhet, och skriver inte längre "inget hittades" som osäkerhet. Reklam och annat TV-ljud blir fortfarande aldrig förslag. Kräver omstart av gatewayen på datorn; inget riktigt modellanrop är gjort med den nya prompten.
- **`mio-pair` fungerar utan Pianissimo (2026-10-12):** skriptet avslutades tyst utan QR-kod om `/etc/mio-transcription.conf` saknades. Nu visas koden med bara AI och ett besked om att köra `mio-pair` igen efter Pianissimo-installationen. README har en ordnad uppsättning (Pianissimo, gateway, Tailscale, app, parning), Pianissimo-guiden beskriver QR-parningen i stället för att skriva av token, `docs/INSTALLATION.md` är omskriven och kortare, och `CLAUDE.md` är nedkortad.
- **Avbrott tappar inte längre väntande vardagstext (2026-10-12):** när ett samtal, Siri eller ett fel stoppade mikrofonen kastades text som väntade på femminutersfönstret, och ett pågående AI-anrop avbröts. Nu skickas den direkt som vid paus och stopp, ett pågående anrop får bli klart, och ljudluckan håller isär sammanhanget före och efter avbrottet. Nytt portabelt XCTest genom arbetsflödet (misslyckas utan ändringen).
- **AI når Groq även med låst telefon (2026-10-12):** i telefonprovet skickades inget till Groq. Gatewaytoken gick inte att läsa med låst skärm, AI stängdes av tyst och kön försvann ("Föredrar blå pennor" kom från den lokala regeln för "kom ihåg", inte från AI). Gatewayns och Pianissimos token sparas nu som `AfterFirstUnlockThisDeviceOnly` (flyttas en gång vid start), och en låst Keychain får AI att vänta på upplåsning i stället för att stänga av. Vid start skickas osänd vardagstext från de senaste 12 timmarna ikapp om den fångades med AI på; redan analyserad text skickas aldrig igen. Nya portabla XCTest för samtyckesloggen, låst Keychain och ikappsändningen. Keychain-flytten och upplåsningsväntan är bara kompilerade för iOS i IPA-workflowen, inte här.
- **IPA-workflowen tål en hängd simulator (2026-10-12):** körning #33 för `e009ef3` stoppades av stegets 35-minutersgräns. UI-testet för att markera en uppgift klar hängde igen (simulatorn rapporterade appen som upptagen), därefter stod simulatorn still: ett enhetstest med 2 s väntan stod i 10 min medan xcodebuild samlade diagnostik, och `simctl shutdown` tog 9 min. Nu körs enhetstesterna först och för sig (utan parallella kloner och utan diagnostikinsamling), UI-testerna i ett eget steg med egen resultatfil och ett nytt försök vid fel, och avstängningen av simulatorn är begränsad till 60 s. Jobbets gräns är 60 min. Ingen appkod är ändrad.
- **Säkerhetsuppdateringar i Pianissimo (2026-10-12):** NeMo 3.0.0, transformers 5.19, huggingface-hub 2.2, hydra-core 1.3.7, fsspec 2026.7 och pytest 9.0.3 tar bort alla kända sårbarheter i låsfilen utom två Lightning-råd (kontrollerat med pip-audit) som bara gäller `load_from_checkpoint`; Mio anropar den aldrig, och Lightning kan inte uppgraderas förrän NVIDIA släpper NeMos låsning (2.6.6 bryter NeMos import). Modellklasserna och anropen är kontrollerade mot NeMo 3.0.0, men ingen modell har laddats på GPU med de nya versionerna.
- **Ny design, veckoplaneraren (du valde den 2026-10-11):** violett grund med vanliga läsytor och Liquid Glass bara på flikfält och knappar. Fyra flikar (Hem, Lektioner, Kalender, Anteckningar) och en separat rund mikrofonknapp, Fånga, längst till höger i flikfältet. Morgon-fliken är borta.
- **Hem** har veckonumret som rubrik ("v. 41"), en rad med veckans sju dagar (i dag inringad, tre små streck visar hur mycket som hänt), "Nästa" med en enda åtgärd, "3 att granska", dagens morgon- eller kvällsöversikt (kväll från kl. 17) och ett rutnät över tolv veckor. Tryck på en dag för att se den, pilarna byter vecka. "Fråga Mio" öppnas från Hem och Fånga.
- **Designsystemet** är dokumenterat i [DESIGN.md](DESIGN.md), härlett ur koden efter slutgranskningen. Granskningen gav: parning som nästa steg när datorn inte är parad, veckoraden i två rader och staplade rubriker vid största textstorlekarna, rundade veckonummer och dagnummer, ett djupare violett mörkt läge och ett felmeddelande när en uppgift inte kan markeras klar.
- **Lyssningsraden** ovanför flikfältet visar diskret en prick och "Lyssnar", "Lektion" eller "Pausad" med paus/fortsätt; tryck för Fånga. Den kräver iOS 26.1; på 26.0 visar Live Activity läget.
- **Kalender** grupperar kommande planer per vecka ("Den här veckan · v. 41", "Nästa vecka · v. 42"). Lektioner visar veckonummer vid varje lektion. Listorna ligger på den violetta grunden.
- **Fråga Mio** visar upp till tre färdiga frågor byggda på telefonen (senaste lektionen, nästa plan eller uppgift). Ett tryck fyller bara i frågan; inget skickas förrän du trycker Skicka.
- Ny portabel logik med XCTest: svenska veckonummer (ISO 8601), dagsaktivitet (bara antal, ingen text), tolvveckorsrutnätet, "Nästa" och dagens fas.
- Live Activity: nytt widgettillägg `MioWidgets` (`app.mio.assistant.widgets`, inbäddat i appens PlugIns) visar "Lyssnar · tid", "Pausad" eller "Avbrott" och antal ljudluckor på låsskärmen och i Dynamic Island. Tiden ritas av systemet, så rutan uppdateras bara vid paus, fortsättning, avbrott och nya luckor. Knapparna Pausa och Stopp är App Intents (`LiveActivityIntent`) som körs i appen; Fortsätt öppnar Mio. Ingen transkriptionstext visas. Kompilerat och SideStore-signerat tillägg är otestat.
- Lektionsanteckningar efter "Avsluta lektion" (eller "Skapa eller fortsätt") visas som iOS 26 `BGContinuedProcessingTask` med iOS egen förloppsruta (klara textdelar av totalt), så arbetet kan fortsätta när du lämnar appen. Avbryter iOS eller du uppgiften stoppas bara den lektionens anteckningar; sparade delar finns kvar och resten återupptas automatiskt nästa gång AI är på, även efter omstart. Inget `processing`-bakgrundsläge lagt till (Apples dokumentation kräver det inte; otestat på telefon).
- "Markera som klar" och radering av poster: AlarmKit- och notisborttagning samt läsning av alarmlistan körs nu utanför huvudtråden, så gränssnittet inte fryser (misstänkt orsak till UI-testhänget i körning #22–#23).
- Nya portabla XCTest: Live Activity-tillståndet, förloppet för lektionsanteckningar, stopp av en lektions anteckningar och återupptagning efter omstart. `verify_project.py` kontrollerar widgettillägget och IPA-workflowen kräver `.appex` i paketet.
- Fångst på telefonen: efter samtal, Siri, media reset eller ändrad ljudväg startar Mio mikrofonen igen av sig själv och markerar luckan, men aldrig efter din paus eller ditt stopp. Nekar iOS i bakgrunden visas notisen "Tryck för att fortsätta lyssna" och Mio fortsätter när appen öppnas. Högst tre automatiska omstarter per minut. Den inbyggda mikrofonen begär rundupptagning när den stöds.
- Ljudet styckas vid naturliga pauser (8–22 s ägt ljud, 1 s kontext per sida, högst 24 s per begäran) med en energibaserad pausdetektor (`SpeechPauseDetector`, XCTest i Linux-grinden). Hälsokontrollen kräver nu 24 s/768 044 byte.
- Talare: ord från PC:n kan ha `speaker` 1–4. Varje talarbyte blir ett eget textsegment, transkriptet visar "Talare 1/2/3" där talaren byts, och du kan byta namn på en talare i en avslutad session (bara visning, originalet ändras inte). AI ser "Talare N: " men aldrig egna namn. Stopp ber PC:n radera sessionens talarminne (`DELETE /v1/sessions/{id}`).
- Lagring: sessioner, innehåll och assistentdata flyttar från hela JSON-filer till SwiftData (`Mio/store/Mio.store`) med radvisa skrivningar, så att en ny textrad inte längre skriver om hela filen. Vid första start migreras JSON-filerna en gång i en transaktion, antalen kontrolleras och filerna flyttas till `Mio/backup-pre-swiftdata/`, som raderas vid nästa lyckade start. Okänt schema eller oläslig fil: ingen migrering, inget raderas, appen kör vidare på JSON och visar ett meddelande. Exporten är oförändrad JSON; raderingsjournalen och diagnostikfilen ligger kvar.
- Diagnostik: Apples MetricKit-rapporter (krasch, häng, CPU, disk, minne) sparas textfritt på telefonen (högst 40 st, 3 MB, 30 dagar), visas under Inställningar → Om → Diagnostik med dela/kopiera och ingår i exporten. `os.Logger` med kategorierna capture, transcription, ai och storage loggar aldrig användartext.
- Nya portabla XCTest för migreringsbesluten (okänt schema, antalskontroll, krasch före och efter markören, backup som aldrig skrivs över) och för MetricKit-arkivet. SwiftData-delen är okompilerad här och inte telefonprovad.
- Inget av detta är kompilerat eller telefonprovat i denna ändring.
- **En parning, "Din dator":** Inställningar → Dator skannar QR-koden från `mio-pair` (VisionKit, bara QR, ingen bild sparas) eller tar fyra manuella fält; transkriptionen är valfri. Koden valideras strikt (version 1, bara https, giltig värd, Pianissimo på `.ts.net`, token `[A-Za-z0-9_-]{32,256}`, aldrig leverantörsnycklar). Efter parningen görs en modellfri kontroll. Cloudflare Access-fält, -huvuden och -hemligheter är borttagna; sparade Access-uppgifter rensas en gång vid uppgradering. Ny `NSCameraUsageDescription`.
- **AI alltid på:** "Tillåt molnfrågor" och bekräftelsedialogerna är borta. AI är på när datorn är parad, startar vid appstart och återkomst, och kan pausas med ett sparat reglage på Mio-fliken eller under Inställningar → AI. Enskilda frågor skickas direkt men svaret valideras fortfarande; förslag kräver fortfarande Ja. Engångspåminnelse om samtycke vid parning. En uppgradering med en gammal sparad server startar pausad.
- **Vardagstext samlas** och skickas högst var femte minut (lektionsdelar minst 60 s isär). 429/`Retry-After`, även `local_token_limit`, pausar i stället för att stänga av AI och visar "AI fortsätter kl. HH:MM"; ett nätfel provas igen efter fem minuter.
- **En inställningspanel** glider in från höger (knappen uppe till höger eller svep från högerkanten), en sida med Dator, AI, Lektioner, Påminnelser, Mio, Integritet och data, Om. Liquid Glass bara på panelens ram; Reduce Motion tonar, Reduce Transparency ger fast bakgrund, VoiceOver får modal panel med escape. Spridda inställningsingångar är borttagna.
- Nya portabla XCTest för QR-parsern, schemaläggningen och AI-standardvalet. Inte kompilerat eller telefonprovat.

## AI-gatewayen flyttar till datorn med Groq, 2026-10-11

- Gatewayen kör nu på din CachyOS-dator bredvid Pianissimo, bakom `tailscale serve --https=8443`. `server/install.sh` installerar allt: tjänstekonto, Groq-nyckel (dold inmatning, fil som bara root kan läsa), härdad systemd-tjänst och Tailscale. `mio-pair` visar en QR-kod med datorns adress och båda tokens; ingenting sparas.
- Groq `qwen/qwen3.8-27b` är enda leverantör. OpenAI-, Vercel-, Gemini-, Anthropic-, OpenRouter-, NVIDIA- och custom-adaptrarna, Cloudflare Worker, D1, Access-guiden och Caddy-exemplet är borttagna ur repot (finns i Git-historiken). Leverantörssömmen finns kvar för ett senare byte till Anthropic.
- Ny dygnsgräns i token (`MIO_TOKENS_PER_DAY`, installationen sätter 190 000 under gratisnivåns 200 000) och tre anrop per minut som standard. Minut-, dygns- och tokenräknarna sparas i `/var/lib/mio-gateway/counters.json` och överlever omstart. `/v2/status` visar kvotens enhet (`unit: tokens|requests`); appen visar "token" efter kvoten.
- Release `2026-10-11.1`. 95 gatewaytester passerar lokalt med Node 26.11.1; inget riktigt Groq-anrop är gjort än.

## Gatewayn publicerad, 2026-10-05

- `mio-private-gateway` kör release `2026-10-05.1` (`/v2`). NIM:s gratisnivå svarade inte inom 40 s; aktuellt val är nu Groq `qwen/qwen3.8-27b`, med Groqs gratisgränser dokumenterade i katalogen. Driftguiden förklarar att Dashboardens Deploy bara ändrar inställningar och aldrig publicerar ny kod. Felsökning av Pianissimo-anslutningen: en DNS-profil (t.ex. Quad9) på iPhonen kan hindra `…ts.net`-uppslag.

## IPA-workflowens testtid, 2026-10-05

- Körning #23: ljudtestet passerade. UI-testet fastnar direkt efter tryck på "Markera … som klar": appen blir aldrig inaktiv ("App event loop idle notification not received"). Samma appkod passerade i körning #20, så något i den nya simulatorn blockerar troligen huvudtråden när uppgiften avslutas och dess alarm/påminnelse tas bort (AlarmKit/notiser i `MioSystemServices.cancelActions`). Workflowen skriver nu ut huvudtrådens stack ur testets spindump för att visa exakt vilket anrop som blockerar.
- Körning #22 visade två namngivna fel. `testGracefulDrainCancelsAtFifteenSecondsEvenWhenAudioIsFresh` (och systertestet för långsam lucka) flyttade testklockan innan ljuddelen faktiskt skickats; på en belastad simulator hinner konverteringen inte klart inom 200 yields. Testerna väntar nu på att begäran är igång, och `waitUntil` begränsas av verklig tid (10 s) i stället för antal yields. `MioUISmokeTests.testTaskCompletionHasNamedAccessibleHitArea` överskred 2 min; orsaken syns inte i loggen, så workflowen skriver nu ut de sista stegen i varje misslyckat test.
- Körning #21 avbröts när jobbet nådde 30 minuter under iOS-testerna (körning #20 behövde 18 min för samma steg). Varje test har nu en tidsgräns (normalt 2 min, högst 5 min), så ett test som hänger misslyckas med sitt namn i stället för att tysta förbruka jobbet. Teststeget får högst 35 min och jobbet 50 min.

## Enklare Pianissimo-installation med automatisk uppdatering, 2026-10-05

- `transcription-server/install.sh` installerar eller uppdaterar hela tjänsten med ett kommando: verktyg, tjänstekonto, Python och låsta paket, konfiguration med ny token, modellnedladdning, systemd och Tailscale Serve (om Tailscale redan är inloggat). Fungerar från valfri sökväg till arbetskopian.
- `check.sh` kontrollerar autentiserad `/health` utan att token hamnar i kommandoraden; `--wait` väntar tills modellen är redo.
- `update-model.sh` och `mio-pianissimo-update.timer` håller Pianissimo på senaste versionen varje natt, med automatisk återgång om den nya inte blir redo inom 5 minuter.
- `transcription-server/README.md` skrevs om från ~220 rader manuella steg till en kort guide: installera, Tailscale, telefonen, kontroll, uppdatering och avinstallation.

## NVIDIA NIM, ingen dagsgräns och städad dokumentation, 2026-10-05

- **Gateway:** ny provider `nvidia` med enbart `deepseek-ai/deepseek-v4.1-flash`. Tänkandet stängs av med NIM:s mallflaggor och `reasoning_content` avvisas. GLM 5.3 (Flash) och Kimi K3 är spärrade eftersom de alltid tänker. `nvapi-`-formade värden avvisas som modell-ID.
- **Kvot:** `MIO_REQUESTS_PER_DAY` är valfri; tom eller `0` betyder ingen dagsgräns och `/v2/status` ger då `quota: null`. Ett satt värde får vara upp till 1 000 000. `wrangler.jsonc` väljer NIM med 20 anrop/minut. Release `2026-10-05.1`.
- **App:** godtar dagsgränser över 100 i status och visar "ingen daglig gräns" i stället för den fasta texten om 100 anrop.
- **Dokumentation:** `docs/` minskade från 20 filer till 9. Historiska v0.1/v0.2-planer, kravmatris, OpenAI-noten, AI-felsökningen 2026-09-30, överlämningen 2026-10-04, `WORKFLOW.md` och `docs/superpowers/` togs bort (finns i git-historiken). Pianissimo- och enhetsproven ingår nu i `TESTPLAN_HELHET.md`, verifieringen i `INSTALLATION.md` och leverantörskontrakten i `server/README.md`. `GROQ_ACCESS.md` ersattes av en leverantörsneutral `server/README.md`.

## Granskning och rättningar 2026-10-05 — Claude Code

Planen och implementationen på `codex/mio-plan-reliability` granskades mot `PLAN.md`. Det mesta följde planen; följande fel rättades:

- **CI:** Linux-workflowen kunde aldrig köra (saknat `python3` och git-ägarskap i Swift-containern). Den kör nu `verify.py` vid varje push och är därmed första faktiska kontrollen av de portabla Swift-testerna. Native concurrency i IPA-workflowen är diagnostik som inte stoppar IPA:n.
- **Ljud/tid:** en fångstepok behåller sin svagaste tidsgiltighet; uppskattad tid kan inte längre märkas som värdtid och bevisa bakgrundsfångst. Stopp/paus väntar på sista textresultat och luckor i ordning. Uppskattad tid bevisar bara fångst efter AI-samtycke bortom 60 s-gränsen. Misslyckad bufferkopiering syns som lucka. HTTP-datum i Retry-After tolkas även för transkription.
- **Sessioner/lektioner/radering:** en lektion som aldrig startade lämnas inte öppen och vardagssessionen återställs; avbruten återstart avslutar inte en pausad session. Lektionsslutförande sparas som väntande vid sparfel, återhämtningsspärr och omstart. Radering av en session tar även bort tillfälliga exporter; en raderad session kan inte exporteras från gammal kopia.
- **AI-klient:** fel token i anslutningsprovet visas som behörighetsfel i stället för "inställningarna ändrades". Okända felkoder och extra uppgifter från nyare server kräver inte ny IPA. Serverns väntetid gäller även efter av/på.
- **Gateway:** `enable_request_signal` krävs för att klientavbrott ska nå Workern. `insufficient_quota` är ett kontofel, Gemini `API_KEY_INVALID` ett behörighetsfel, stora felsvar behåller kategori och Retry-After, och hängande D1 ger `budget_store_failed`. `/v1/status` speglar vardagsuppgiftens profil. Dagsgräns över 100 startar inte längre (dokumenterat som uppgraderingsändring).
- **Prestanda:** en uppdatering av den aktiva sessionen sorterar inte längre om hela sessionshistoriken för varje textdel.
- `AGENTS.md` ersattes av `CLAUDE.md` (engelska) och maskinspecifika Codex-sökvägar togs bort ur dokumentationen.

## Arbetskopia 2026-10-04 — PLAN-steg 1–5

- Genomfört den aktuella helhetsplanen på grenen `codex/mio-plan-reliability`: förstärkt ljud-/sessionsägarflöde och backend-avbrott, appägd workflow/radering/export, providerneutrala taskprofiler/adaptrar och granskade wire-kontrakt samt färskhet, anslutningskontroll, explicit frågesvarsgodkännande och återhämtning.
- Tillagt gemensam Linux-verifierare, verifierartester, faktiskt Worker-runtimeprov, fristående complete-concurrencygrind, native Xcode-diagnostik i IPA-workflowen och syntetisk långhistorikmätning. Svenska verifierings-, enhets-, leverantörs- och driftguider uppdaterade.
- Uppdaterat låsta Wrangler- och Miniflare-utvecklingsverktyg efter npm-granskning; den fullständiga beroendegranskningen rapporterar nu noll kända sårbarheter.
- Bevarat den byte-identiska ursprungsplanen som `PLAN.md` i repot och lagt till en kort överlämningsguide med verifieringsunderlag, fortsatt testordning och ej utförda externa/evidenskrävande steg.
- Lokal slutgrind 2026-10-04: 274 strukturella kontroller, 4 verifierarprov, 123 Node-tester, 27 Python fake-backend-tester, 235 portabla XCTest, 8 capture lifecycle-regressioner och complete-concurrencygrind godkända; fullständigt kvitto och Linuxbegränsningar i [status](docs/STATUS.md).
- Ingen Xcode/iOS-SDK-byggning, native XCTest, IPA, installation, fysisk enhet, verklig providertrafik eller Cloudflare-publicering utförd. Aktuell helhet är fortsatt 0.9.0 och ej släppt; dessa evidenskrävande steg återstår enligt överlämningsguiden.

## Dokumentationsrättning 2026-09-30 — efter implementation och push

- AI-felsökningsrapporten skiljer nu genomförda ändringar i `e906585` från återstående Cloudflare-publicering, nytt iOS-bygge och telefon-/modellprov. Gamla rekommendationer och testantal ersätts med implementationsstatus.
- Gatewayguiden beskriver uppdatering av befintlig Worker, bevarande av Secrets/Access/D1 och autentiserad statuskontroll utan modelltrafik. Kontext, stopp/paus och de fyra AI-rutterna dokumenteras enligt aktuell kod. Ingen Cloudflare-publicering utförd genom denna dokumentationsrättning.

## Arbetskopia 2026-09-30 — AI-kontext och diagnostik

- Vardagsanalys v2 separerar nya fragment från högst en minuts godkänd bakåtkontext. Samma öppna förslag kan kompletteras över anropsgränsen; Ja/Nej skyddas med beständiga textfria beslut.
- Mjuka meningsgränser med begränsad extra väntan, minst en minuts väntan efter föregående sändningsslut och hantering av sluttext vid stopp/paus. Kontext återställs vid paus, ljudlucka och lektionsbyte.
- Lokal AI-journal, 200 händelser/sju dagar, med säkra felkoder, HTTP-/nätdata, storlekar, källantal och versionsmetadata. Exporten får diagnostik även utan session och behåller schema 2; Skapa ny export tar med senare AI-fel. Fullständig radering omfattar journalen och avvisar sena writes.
- Skyddad gatewaystatus utan modell-/kvotanrop och tydligt kompatibilitetsfel. Gatewayen stöder Groq/Qwen i arbetskopian; publicerad gammal kod är fortfarande separat och behöver uppdateras efter uttrycklig begäran.
- Verifieringsresultat och kvarvarande Xcode-/telefon-/modellprov anges i [status](docs/STATUS.md). Ingen publicering utförd.

## Utredning 2026-09-30 — AI-driftfel och sammanhang

- Läskontroll av faktiskt publicerad Worker bekräftar äldre OpenAI-kod med nya Groq-inställningar: gatewayen kan inte initieras. Uppdaterad befintlig gateway passerar mocktester och lokal Worker-verifiering; ingen publicering utförd.
- Dokumenterat varför exporten saknar AI-anropsbevis och föreslagit lokal begränsad diagnostik samt separerat nytt underlag/bakåtkontext, mjuka gränser och stabila förslagsbeslut. Detta var ett designförslag vid utredningen; implementationen ovan följer användarens efterföljande godkännande; se utredningen.

## Arbetskopia 2026-09-30 — granskad Pianissimo-driftguide

- Alla källsökvägar uttryckliga: installation, systemd och utvecklarprov fungerar från valfri katalog. Endast serverns Python-kod, paketdefinition och låsfil kopieras till `/opt`; ingen hel projektkopia eller befintlig `.venv`.
- Dokumenterat avvägningen mellan låst Python/systemd och Docker, en varm GPU-process, uppdatering av rätt driftmiljö, förhämtning före laddningstimeout, health/felsökning, Tailscale-taggning och energihantering. Officiella källor granskade; ingen driftsättning.
- systemd anger uttryckligen `StateDirectoryMode=0700` så att tjänstens katalogbehörighet motsvarar installationsguiden även vid start.

## Arbetskopia 2026-09-30 — rättning av testkompilering

- Rättat ogiltiga Swift-decimaltal `.1`/`.5` till `0.1`/`0.5` i TranscriptionTests. Actions 36686984521 stoppades vid testkompilering med dessa fel. Ny Xcode-körning krävs; parserkontrollen fångade inte felet.

## Arbetskopia 2026-09-30 — Pianissimo, bakgrund och inställningar

- Apple-transkriptionen ersatt av original Pianissimo på egen CUDA-server. Stabilt autentiserat API v1, modellrevision/hälsa, loopback + privat Tailscale Serve och systemd med automatisk omstart.
- Mikrofon och nät separerade. 20 s ljuddelar med kontext, högst 60 s RAM-kö, begränsade anrop/retries och tydliga luckor. Stopp stänger mikrofonen och avslutar redan fångad text under högst 15 s med avbrytknapp.
- Ljudavbrott, route changes, foreground och media reset hanteras utan att serverfel avslutar lektionen. Manuell Fortsätt efter iOS-reset. Kort UIKit-bakgrundstid vid avslut; befintligt audio-background mode används för aktiv fångst.
- Samlade inställningar från alla flikar, skilda ljud-/text-AI-anslutningar, Keychain, tydlig sparbekräftelse/status, diskreta tryck och haptics. Ofullständigt ljudunderlag syns också i kopierade lektionsanteckningar.
- Fördröjd text från ljud före AI-aktivering skickas inte som ny vardagsanalys. Original och historiska data bevaras.
- Ny driftguide, API-kontrakt och acceptansmatris. Python-/gatewaytester och GPU-smoke utförda; se status för exakt evidens. Ingen ny iOS-kompilering, installation, driftinstallation, commit eller publicering.

## Arbetskopia 2026-09-29 — anslutning och Access, ej publicerad

- Ny sammanhängande Groq/Qwen-guide: engångsuppdatering, egna framtida provider-/modellbyten, gatewaytoken, rotation och Cloudflare Access med Service Auth samt negativa skyddsprov.
- Grå granskningsknapp förklarar nu att molnfrågor måste vara på och frågetext ifylld. Guiden skiljer Wrangler-påminnelsen från autentiseringsfel och rättar sammanblandningen av `MIO_OPENAI_MODEL` och `MIO_AI_MODEL` för Groq.
- Förtydligad åtkomsttoken i appen och valfria separata Access-fält. Gatewaytoken och Access-par sparas atomiskt i samma Keychain-post, skickas på alla tre AI-rutter och följer aldrig redirects. Befintlig gatewaytoken kan läsas efter uppgradering.
- Wrangler-exemplet väljer Groq/Qwen och bevarar extra Dashboard-variabler. Explicita variabler i filen behöver fortfarande synkas före senare deploy.
- Access-policy måste aktiveras separat i Cloudflare. Inget konto ändrat, ingen publicering eller nytt iOS-bygge utfört.

## Arbetskopia 2026-09-28 — AI och detaljerade lektioner, ej publicerad

- Åtta leverantörspresets och egen kompatibel endpoint; neutralt modellval i Cloudflare med separata API-hemligheter. Reasoning av, temperatur 0, strikt schema även för frågor och tydliga kompatibilitetsfel.
- Detaljerade källkopplade lektionsdelar, modell-/promptmetadata, framsteg och kopiering av hela anteckningen. Sparade delar används vid manuell fortsättning; äldre huvudpunkter bevaras.
- Mindre lektionsbatcher, minst 60 sekunders konfigurerbar takt och väntetid vid kvotfel. Inga automatiska återförsök eller inbyggda läromedel.
- Mocktester och lokal Worker-verifiering; nya XCTest-fall tillagda men ej körda. Ny appkod är inte Xcode-byggd, telefonprovad eller publicerad.


Användarsynliga ändringar och kompatibilitet per version. Versioner följer `vMAJOR.MINOR.PATCH`; [roadmapen](docs/ROADMAP.md) definierar milstolpar och släppkrav. Ingen ny Git-tagg eller release har skapats genom namnbytet.

## Build 5, 2026-09-28 — byggd, telefonprov återstår

- Sessionsstart försöker installera en stödd men saknad svensk SpeechTranscriber-modell före fallback. Avbruten start får inte fortsätta med reservmotorn.
- Motordiagnostik visar svenska språkvarianter i supportedLocales/installedLocales, resolved locale, assetstatus och hämtningsbehov; sessionsexporten får före/efter-händelser. Installations-/startfel vid fallback får felkod och domän.
- Release och 48 XCTest godkända för `1b4ae6c` i Actions 36382509184. IPA 0.9.0 (5) kontrollerad lokalt.
- Instruktioner och enhetsprov uppdaterade. Ingen ny talmotor eller bevisad kvalitetsförbättring; fysisk iPhone-verifiering återstår.

## Driftalternativ 2026-09-27

- Gatewayen publicerad på användarens Cloudflare-konto efter godkänd inloggning. Kvotdatabas och privat gatewaytoken konfigurerade; OpenAI-nyckel och verkliga modellprov återstår. Första provmodell konfigurerad som `gpt-6-luna`.
- Cloudflare Worker med inkluderad HTTPS-adress: ingen påslagen egen dator eller köpt domän behövs. Samma AI-kontrakt, systeminstruktioner och validering. Beständiga minut-/dygnsräknare i D1, inga lagrade textutdrag.
- Låsta utvecklingsverktyg, mocktester för budget samt genomgångstest av det verkliga Worker-paketet i lokal runtime. Ingen publik tjänst eller verklig AI-trafik har skapats av dessa tester.

## Rättningar efter telefonprov 2026-09-26

- Separat Starta lektion pausar vardags-Mio. Lektioner ersätter tidslinjen som huvudflik; historik och råtext finns kvar under Lektioner.
- Löpande AI-tolkning efter uttrycklig aktivering: planer/uppgifter ur vanligt samtal utan Mio-tilltal, källcitat, tidsgranskning och Ja/Nej/Inte nu. Lektioner får huvudpunkter/läxor som AI-utkast efter avslut.
- Separata svenska systeminstruktioner för frågor och analys, strikt schema och källvalidering, OpenAI-adapter med stabilt appkontrakt för framtida leverantörer. Ingen server driftsatt genom kodändringen.
- Avbrytbara köer, skydd mot historisk text vid aktivering och sena svar vid radering, nya regressionstester. Lokalt stöd även för ”Mio, påminn mig om att …”.
- Tydligare visning av aktiv transkriptionsmotor, specifika fallbackorsaker samt app/iOS-version och felkod i ny diagnostik. Ingen påstådd förbättring av Apples igenkänningsmodell utan nytt telefonprov.

Aktuell evidens och kvarvarande kontroller finns i [status](docs/STATUS.md).

## Helhetsbygge 0.9.0 — ej släppt

Efter användarbeslut 2026-09-25 byggs hela produkten tillsammans. Detta är en sammanhängande utvecklingskandidat, inte en telefonverifierad release.

- Lokal inkorg med redigerbara innehållsförslag och frågor, Ja/Nej/Inte nu och svenska Mio-kommandon. Stabilt godkännande-ID och skydd mot sen detektion efter radering.
- Redigerbar lektionsindelning över avslutade sessioner, med tidsval ned till sekunder och bevarade originalbevis.
- Bekräftade kalenderkopior via Apples editor, AlarmKit-alarm och lokala post-/morgon-/kvällspåminnelser. Privata posttexter visas inte på låsskärmen.
- Lokal morgon- och kvällsöversikt. Mer lättåtkomliga assistentfunktioner; teknisk diagnostik finns i expanderbara avsnitt.
- Valfri AI-klient och separat Node-server. Molnet är avstängt från början; exakt vald text visas före varje sändning. HTTPS, Keychain-gatewaytoken, serverägd OpenAI-nyckel, inga redirects eller automatiska omförsök.
- Nytt separat assistantlager; export schema 2 med bakåtkompatibel avkodning. Total radering omfattar nya lager, systemåtgärder och AI-konfiguration med gemensam skrivspärr.
- Nya XCTest-fall, serverns mocktester, portabel projektkontroll samt användar- och helhetstestguide.
- Ny appikon med standard-, mörk och tonad variant samt redigerbara SVG-original i `design/`.
- Kalendereditorns delegate för över resultatet till huvudaktorn innan SwiftUI-tillstånd ändras.

Efter uppdaterat användarbeslut 2026-09-26 används appidentiteten `app.mio.assistant` och lagring under `Mio`; gammal fasmigrering har tagits bort. Första telefonprov sker på iPhone 16 Pro, senare iPhone 13. Native Liquid Glass tillagt i sessionskontrollerna med systemnavigation, semantiska läsytor och stöd för minskad rörelse. Användaren har godkänt commit, push och IPA-bygge; ingen servertjänst driftsätts och ingen release taggas. Faktiskt verifieringsläge dokumenteras i [status](docs/STATUS.md).

## v0.2.0 — ej släppt

### Tillagt sedan v0.1.0

- Fem flikar och fem manuella innehållstyper: tidslinjepost, anteckning, uppgift, plan och uttryckligt minne.
- Skapa, redigera, söka, radera och markera uppgifter klara; stabil lokal tidsordning.
- Koppla en post till en session. Lägg titel, anteckning och texträttningar på avslutade sessioner utan att ändra originalbevis.
- Separat versionsmärkt innehållslagring och gemensam JSON-export.
- Synlig status och separat installation av svensk `SpeechTranscriber`-resurs; direkt `DictationTranscriber`-fallback när resursen saknas.
- XCTest för modeller, lagring, migrering, export och Mio-detektion.

### Byggflöde 2026-09-25

- Ersatt separata Xcode 26.6- och Xcode 27-jobb med ett Xcode 27-jobb som bygger Release, kör XCTest på iOS 27-simulator och skapar osignerad IPA.
- Bygget kontrollerar iOS 27 SDK, appens lägsta iOS-version 26.0 och oförändrad bundle identifier i den byggda appen. iOS 26 och 27 behöver fortfarande provas på fysisk telefon.

### Städning 2026-09-22

- Ersatt utvecklingsfaser med v0.1.0–v0.5.0 och definierat vad som krävs för v1.0.0.
- Bytt projekt, mappar, modul, targets och scheme från `MioPhaseTwo` till `Mio`/`MioTests`; `MioApp.swift` och `ContentViews.swift` får beständiga namn.
- Satt appens versionsfält till `0.2.0` (tidigare `0.2`). Byggnumret är separat och fortfarande `1`.
- Byggfiler heter `Mio-unsigned.ipa`, `Mio-buildinfo.txt` och artifacten `Mio-IPA`.
- Nya sessionsexporter heter `Mio-session-*.json`. Radering känner fortfarande igen äldre exportnamn; Git ignorerar både gamla och nya.
- Samlat verifieringsläget i en statussida och båda installationsvägarna i en guide. Kortat introduktion, arbetsflöde och beslut; behållit detaljerade testfall och historiska mätvärden.
- Tagit bort interna utvecklingsfaser ur appens texter. Bygginformationen läser appversion och byggnummer från den byggda appen.

### Kompatibilitet och verifiering

Bundle identifier, lagringsvägar, JSON-schema och migreringsbeteende behålls. Namnbytet kräver ingen ny datamigrering. Bygg- och telefonresultat saknas för denna revision; följ [status](docs/STATUS.md) och testplanen.

## v0.1.0 — historisk prototyp, telefonprov 2026-08-20

Versionsetiketten tilldelas i efterhand till den tidigare fas 1-prototypen; den påstår inte att en motsvarande Git-tagg, release eller exakt appversionssträng fanns.

- Lokal svensk transkription via `SpeechAnalyzer`, `DictationTranscriber`-fallback, Mio-detektion och paus/stopp.
- Sessionslagring, JSON-export, ljudtider, bakgrundsdiagnostik och batterimätning.
- Molnbyggd IPA installerades via SideStore. Ett 2 min 30 s långt iPhone 13-prov gav fem textsegment, två Mio-detektioner och inga rapporterade runtimefel eller tappade buffertar.
- `SpeechTranscriber`-resursen gick inte att installera i provet. Långa bakgrunds-, batteri-, avbrotts- och kvalitetsprov återstår.

Fullständiga observationer: [historiskt testresultat](docs/TESTRESULTAT_V0_1.md).
