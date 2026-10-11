# Beslut och tekniska kontrakt

Aktuella beslut står först. Daterade avsnitt bevarar beslutens historia; ett senare uttryckligt beslut ersätter ett äldre där de skiljer sig. [Ändringsloggen](../CHANGELOG.md) beskriver källändringar; [status](STATUS.md) beskriver faktiskt utförda kontroller.

## Fångst på telefonen: återstart, rundupptagning, pausdelar och talare, 2026-10-11

Användarbeslut 2026-10-11 som ersätter regeln "ingen automatisk mikrofonåterstart" från 2026-09-29.

- **Återstart efter avbrott:** när iOS meddelar att ett avbrott (samtal, Siri) är slut, efter media services reset, efter en ljudvägsändring som stoppat motorn och efter `AVAudioEngineConfigurationChange` aktiverar Mio ljudsessionen och startar motorn igen, men bara så länge användaren lyssnar. Paus och stopp tar bort fångsten, så de kan aldrig ångras automatiskt. `.shouldResume` behandlas som en uppspelningsledtråd: Mio försöker oavsett. Luckan markeras som tidigare ("Mikrofonen var avbruten."). Nekar iOS (typiskt i bakgrunden) görs ett nytt försök efter 1 s; därefter visas notisen "Tryck för att fortsätta lyssna", sessionen väntar och motorn startas när appen blir aktiv. Nekas det i förgrunden pausas Mio som förut med Fortsätt. Högst tre automatiska omstarter per minut, sedan krävs Fortsätt, så en ljudvägsloop kan inte snurra. Notisbehörighet efterfrågas när mikrofonen startas på skärmen, eftersom iOS inte kan visa frågan i bakgrunden. Apple garanterar inte någon `.ended`-notis ([Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)); därför försöker även förgrunden. iOS 27:s nya livscykelnotiser används inte ännu eftersom appen riktar sig mot iOS 26. Förkastat: att alltid kräva Fortsätt (användarens beslut) och att återstarta utan gräns.
- **Rundupptagning:** `.record` + `.measurement` behålls (ingen röstbehandling som tystar avlägsna röster). När ljudvägen redan är den inbyggda mikrofonen väljs en datakälla vars `supportedPolarPatterns` innehåller `.omnidirectional` med `setPreferredDataSource(_:)` och `setPreferredPolarPattern(_:)` efter kategori, läge och aktivering, som Apple kräver. Bara det som skiljer ändras, eftersom varje ändring konfigurerar om ljudvägen. Stöds det inte behålls iOS val tyst och händelseloggen säger det. Externa mikrofoner (headset) lämnas orörda.
- **Pausdelar:** `SpeechPauseDetector` mäter energi i 20 ms-ramar. Första tydliga paus (minst 300 ms under brusgolv × 2 eller 3 % av talnivån) efter 8 s ägt ljud blir snitt, mitt i pausen, när 1 s högerkontext finns. Annars tvingas snittet när 22 s + 1 s finns, i det tystaste 300 ms-fönstret, vid lika det senaste. Största begäran blir 1 + 22 + 1 = 24 s (768 044 byte); hälsokontrollen kräver nu den kapaciteten. Som mest 23 s plus en tapp hålls mellan snitten; 60-sekundersregeln är oförändrad. Förkastat: röstaktivitetsmodell (batteri och beroende), längre fönster (latens och 60-sekundersregeln).
- **Talare:** `speaker` per ord avkodas tolerant (saknas, `null`, fel typ eller utanför 1–4 blir okänd). Varje talarbyte inom en del blir ett eget textsegment med `speaker`; utan talare blir det ett segment per del som förut. Namnbyte är ett visningslager i `MioSession.speakerNames` och kräver avslutad session. AI-utdrag får prefixet "Talare N: " med neutrala nummer; egna namn lämnar aldrig telefonen. När användaren stoppar sessionen anropas `DELETE /v1/sessions/{id}` en gång, utan omförsök.

Ej verifierat på telefon: att iOS 26 tillåter återaktivering av `.record` i bakgrunden efter samtal och Siri, notisen som reserv, att rundupptagning faktiskt väljs i `.measurement`-läge på iPhone 16 Pro, och pausdetektorns trösklar på riktigt rumsljud.

## Pianissimo: dämpade samtal med flera talare, 2026-10-11

Användargodkänd plan: PC-tjänsten ska klara samtal där flera personer hörs dämpat. API v1 behålls; allt nytt är additivt.

- **Förbehandling** före modellen, modelloberoende och bara i RAM: DC-borttagning, 80 Hz högpass (nollfas via FFT så ordtider står still), nivå mot cirka −23 dBFS på talliknande ramar med högst +20 dB och ingen förstärkning av ren tystnad eller jämnt brus, mjuk toppbegränsning. Av med `MIO_PREPROCESS=0`. Förkastat: brusreducering, eftersom den ofta höjer ordfelen för modern taligenkänning ([arXiv 2512.17562](https://arxiv.org/abs/2512.17562)); scipy, eftersom numpy räcker och inte lägger till ett beroende; ett vanligt IIR-filter, eftersom dess fasfördröjning skulle flytta ordtiderna.
- **Talarmärkning** med NVIDIA Streaming Sortformer `nvidia/diar_streaming_sortformer_4spk-v2` (CC-BY-4.0, NeMo, redan i GPU-beroendena). Valfritt `speaker` 1–4/`null` per ord. Talarcachen hålls per session bara i RAM och raderas vid sessionsslut (`DELETE /v1/sessions/{id}`), efter 10 minuter utan ny del eller vid omstart. Ett fel i talarsteget ger aldrig fel på transkriptionen. Talarmodellen låses till en commit vid installation och uppdateras inte på natten. Av med `MIO_SPEAKER_LABELS=0`.
- **Pausstyrda delar:** appen skär 8–22 s ägt ljud vid pauser plus 1 s kontext per sida. 22 + 2 = 24 s ryms exakt i serverns befintliga gräns, som därför inte ändras.
- **Mätning:** `transcription-server/scripts/measure_wer.py` jämför ordfelfrekvens med och utan förbehandling på publikt svenskt tal (FLEURS sv_se) under syntetiskt dämpade villkor och två överlappande talare.

Ej verifierat: den riktiga Sortformer-körningen (skriven mot källkoden i NeMo 2.7.0 utan GPU-prov), svensk talarkvalitet (modellen är främst tränad på engelska), extra GPU-minne och latens, samt om förbehandlingen faktiskt sänker ordfelen. Mät med skriptet på datorn innan förbehandlingen eller talarmärkningen betraktas som förbättringar.

## Live Activity och fortsatt bearbetning, 2026-10-11

Användarbeslut (helhetsplanen 2026-10-11): Lyssnandet syns på låsskärmen och lektionsanteckningar ska bli klara även när appen lämnas.

- **Live Activity** i ett eget widgettillägg, utan App Group: allt tillstånd ligger i ActivityKits content state (fas, sessionsstart, paustid, antal luckor). Tiden visas med `Text(timerInterval:)`, så inga täta uppdateringar behövs. Pausa/Stopp är `LiveActivityIntent` som körs i appens process och anropar samma paus/stopp som knapparna i appen. Fortsätt använder `supportedModes = .foreground(.immediate)` och öppnar appen, eftersom iOS inte tillåter att mikrofonen startas från bakgrunden. Förkastat: `AudioRecordingIntent` för att starta inspelning från låsskärmen (oklart samspel, kräver telefonprov) och App Group för delat tillstånd (kräver extra rättighet med gratiskonto).
- **`BGContinuedProcessingTask`** (iOS 26) med unik identifierare per begäran under jokertecknet `app.mio.assistant.lesson-notes.*` och strategin `.fail`. Själva arbetet körs i analyskoordinatorn oavsett; uppgiften speglar bara förloppet och stoppar arbetet när iOS avslutar den (Apples rekommendation i utvecklarforumet). Inget `processing`-bakgrundsläge, eftersom Apples dokumentation inte kräver det. Ej verifierat på telefon.

Källor: [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados), [WWDC25 Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/), [forumtråd om jokerteckenidentifierare](https://developer.apple.com/forums/thread/799126), [forumtråd om start och avslut](https://developer.apple.com/forums/thread/807370), [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent), [supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes).

## Pianissimo följer senaste versionen, 2026-10-05

Användarbeslut: transkriptionsservern ska alltid köra senaste `KlangAI/pianissimo-sv`, inte en fast revision.

- `install.sh` installerar allt med ett kommando och används även för att uppdatera. Vid första installationen väljs den senaste revisionen på Hugging Face (`main`).
- Timern `mio-pianissimo-update.timer` kör `update-model.sh` varje natt runt 04:00. En ny revision laddas ner och tjänsten startas om med den. Den godkänns först när `/health` rapporterar exakt den revisionen inom 5 minuter; annars återställs föregående revision automatiskt. Gamla revisioner tas bort från cachen efter lyckat byte.
- Konfigurationen och API:t anger fortfarande en exakt 40-teckens revision, så det syns vilken version som körde. Python-beroendena (NeMo 2.7.0 m.fl.) är fortsatt låsta i `uv.lock`; en modellversion som kräver nyare NeMo blir inte redo och rullas tillbaka.

Avvägning: nya modellversioner kommer utan föregående manuellt prov. Återgången skyddar mot en version som inte laddar, men inte mot sämre svensk precision eller ändrade ordtider. Ett byte mitt i användning ger en kort lucka; därför sker det på natten. Ersätter "pinned revision" i beslutet 2026-09-29.

## Text-AI via NVIDIA NIM utan dagsgräns, 2026-10-05

Användarbeslut: byt textleverantör från Groq/Qwen till **NVIDIA NIM med `deepseek-ai/deepseek-v4.1-flash`**, och ta bort Mios dagsgräns.

- **Modell:** DeepSeek V4.1 Flash är den enda av de jämförda (GLM 5.3, GLM 5.3 Flash, Kimi K3) som kan stänga av tänkandet. GLM 5.3 och 5.3 Flash avvisar `disabled` med HTTP 400; Kimi K3 saknar instant-läge. De bryter därmed kravet på reasoning OFF och är spärrade i katalogen. V4.1 Flash är dessutom snabbast (~227 token/s, ~1 s till första token).
- **Adapter:** ny provider `nvidia` (Chat Completions mot `integrate.api.nvidia.com/v1`, Secret `NVIDIA_API_KEY`). Reasoning stängs av med `chat_template_kwargs: {thinking:false, enable_thinking:false}` i stället för `reasoning_effort:none`, som hos NIM är en tankebudget och inte ett av-läge. Svar med `reasoning_content` avvisas.
- **Dagsgräns:** 100 per dygn var Mios eget tak, inte leverantörens. NIM:s gratisnivå har bara 40 anrop/minut per nyckel. `MIO_REQUESTS_PER_DAY` är nu valfri (tom eller `0` = ingen gräns, annars 1–1 000 000); `/v2/status` rapporterar då `quota: null`. Minutgränsen (högst 60, konfigurerad 20) och två samtidiga anrop finns kvar som skydd mot skenande loopar. Detta avviker medvetet från PLAN.md:s icke-mål "quota increases"; PLAN.md själv ändras inte.
- **Ej verifierat:** att NIM tillämpar `response_format.json_schema` strikt (NIM:s exempel använder `nvext.guided_json`), samt svensk kvalitet, latens och verklig tillgänglighet. Det avgörs av det separata syntetiska modellprovet efter publicering. Mio validerar varje svar lokalt oavsett.

Avvägning: utan dagsgräns kan kontinuerlig vardagsanalys (~1 anrop/minut) gå hela dagen, men ett fel som loopar begränsas bara av minutgränsen. Gratisnivåns villkor kan ändras utan förvarning; vid behov kan en dagsgräns åter sättas med en variabel.

## Tillförlitlighet, sammanhängande flöden och leverantörsgränser, 2026-10-03

PLAN.md genomförs i ordning i en isolerad arbetskopia. Det här beslutet gäller den nya koden, inte den äldre publicerade gatewayen eller tidigare telefonprov. Helhetsbygge 0.9.0 är fortsatt ej släppt. Appidentitet, iOS 26-minimum och filnamnen `content-v1.json`, `sessions.json` och `assistant-v1.json` behålls.

- Appen äger en workflow-koordinator för start, paus, stopp, vardag–lektion, radering och återställning. Typade resultat visar om en åtgärd blev utförd, delvis utförd, avbruten eller misslyckad. En generationsgräns och övervakade arbeten hindrar gamla callbacks från att spara efter stopp, avstängning, anslutningsbyte eller radering. Start av nästa fångstläge väntar på föregående ljudavslut; sessionsskrivning gör begränsade patchar mot senast lagrade data.
- De tre domänlagren förblir separata. En gemensam skyddad atomisk skrivväg och en minimal journal över identifierare återhämtar avbruten radering utan privata titlar, text eller credentials. Okända innehållsscheman skrivs inte över. Export följer samma generationsgräns; ett sent resultat återskapar inte raderat innehåll. Ingen databas eller distribuerad kö införs utan uppmätt behov.
- Original Pianissimo på privat GPU/Tailscale är enda talmotor. Mikrofonen startas av användaren och återstartar aldrig efter processavslut. RAM-ljudets 60-sekundersgräns gäller även under avslut och nätväntan. Förfall, terminalt fel och rester vid hårt avslut ger synliga luckor med ljudtid; sena svar kan inte fylla dem. Begränsade nätomförsök är skilda från mikrofonstart. Ingen råljudsfil, Apple-/CPU-/molnfallback eller publik ljudport tillkommer.
- Textgatewayen skiljer Mio-taskdefinition, exakt modellprofil, nativeadapter och exekvering. Profilerna `ask`, `everyday` och `lesson` väljer provider/modell på servern och ärver global konfiguration om en override saknas. En felaktig override spärrar sin task; ogiltigt profil-JSON spärrar alla. Avsedda leverantörshemligheter väljs på servern. Ingen klientmodellväljare, generell AI-SDK eller tyst fallback införs.
- Reasoning helt av, temperatur 0 och strikt schema är obligatoriska för alla aktuella tasks. Gemini använder sitt nativeformat. Mistral och DeepSeek är spärrade tills exakta kontrakt kan etableras; ett providerprefix eller dolt tänkande är inte stödbevis. [Den granskade matrisen](../server/README.md) skiljer dokumentgranskning och lokala fixtures från verklig kontoåtkomst och kvalitet. Inga verkliga leverantörsprofiler är ännu verifierade för den nya revisionen.
- Skyddad modellfri `/v2/status` ger taskprofiler, konfigurationsrevision och delad kvot; `/v1/status` bevaras för äldre klienter. Nya AI-anrop skickar observerad revision och kräver ny preview/aktivering vid 409. Secrets ingår inte i revisionsfingeravtrycket. Status bevisar gatewaykontakt och lokal konfiguration, inte leverantörens nyckel, modellåtkomst eller kvalitet. Klienten accepterar begränsade okända metadata men kräver den valda taskens kontrakt och validerar varje domänresultat.
- Hela operationen efter request body har 40 sekunders deadline, även D1, fetch, response-läsning och domänvalidering; body har separat femsekundersgräns. Deadline skiljs från klientavbrott. Förbrukningen är gemensamt högst 100 modellförsök per dygn. Osäker sen kvotreservation återbetalas inte och ger inget automatiskt modellanrop. Befintlig D1-bindning och Access-skydd ska bevaras vid release.
- Tre kompletteringar ingår: anslutning/kapacitet med högst 30 sekunders statuscache och synligt återstående lektionsarbete; öppning av rätt lokal vy från godkända notiser med enbart opaka mål-ID:n; explicit **Spara som anteckning** för ett validerat frågesvar. Att visa ett svar skapar ingen beständig historik, post eller systemåtgärd.
- Detaljerade lektionsdelar sparar den faktiskt skickade källrevisionen. UI och kopiering märker aktuell, äldre eller okänd revision; legacy utan bevis får ingen påhittad revision. Rättningar ändrar bara visning och skickas inte automatiskt till AI. Omstart bevarar färdiga delar, men fortsatt molnarbete kräver explicit återaktivering av det löpande läget och dess samtycke. Delar sammanställs lokalt i källordning utan extra komprimeringsanrop; läxförslag kräver Ja.

Avvägning: uttryckliga ägare, revisionskontroller och begränsade journaler tillför viss kod och underhåll men gör races och återhämtning prövbara utan nytt ramverk. Modellfri discovery minskar kostnad och exponering; kort cache minskar statuslatens men kan visa en nyligen ändrad profil tills nästa kontroll. Chunkvis transkription och delvis lektionsbearbetning begränsar minne och kontext men kan ge väntan, luckor och upprepningar. Svensk precision, faktisk telefonlatens, batteri, värme och total driftkostnad är fortfarande omätta för denna revision. Lokal Linuxverifiering ersätter inte Xcode, IPA, installation eller fysisk acceptans.

Gatewayrelease `2026-10-03.1` förbereds lokalt. Read-only kontroll den 3 oktober visar fortfarande äldre OpenAI-kod tillsammans med Groq-variabler i produktion. All-traffic Access och service-token har inte verifierats; anonym 403 räcker inte som bevis. Exakt kodbundle och konfigurering måste läsas tillbaka efter separat godkänd publicering. Syntetisk verklig modelltrafik godkänns därefter separat enligt [serverguiden](../server/README.md) och [kontraktsmatrisen](../server/README.md). Historiska mätvärden ändras inte.

## Historisk grund, 2026-08–09

Tabellen beskriver den tidigare grundens beslut. Apple-transkription och de historiska versionsavgränsningarna har senare uttryckligen ersatts nedan.

| Beslut | Regel | Ursprung |
|---|---|---|
| Privat native-app | SwiftUI, iOS 26+, iPhone 16 Pro först och iPhone 13 senare; ingen App Store-distribution | 2026-08-20 |
| Lokalt ljudflöde | `SpeechAnalyzer` tar emot tidsatta buffertar och kör en transkriptionsmodul åt gången | 2026-08-20 |
| Ingen råljudslagring | Ljud bara tillfälligt i minnet; text, tider och diagnostik lokalt | 2026-08-20 |
| Explicit molnsamtycke | Framtida OpenAI-fråga kräver Ja, minsta kontext och API-nyckel på server | 2026-08-20 |
| Privat installation | Actions bygger osignerad IPA; SideStore signerar. Lokal Mac/Xcode är ett alternativ | 2026-08-20 |
| Enkel Git-rutin | Lokala ändringar granskas och verifieras före commit; färdigt arbete pushas direkt till `main` utan grenar eller PR (2026-10-05). Privata exporter lämnar aldrig sin privata lagringsplats för repot | 2026-08-20 |
| Manuella funktioner kan utvecklas parallellt | v0.2.0 kräver inte att heldagslyssning är godkänd; öppna långtest kvarstår | 2026-08-24 |
| Separata datalager | Poster, sessioner och assistentdata lagras separat; aktuella kontrakt beskrivs i datamodellen | 2026-08-24 |
| Bevarade original | Sessionstitel, anteckning och texträttningar läggs ovanpå originaltext, tider och bevis | 2026-08-24 |
| Resurs före modulstart | `SpeechTranscriber` endast efter installerad svensk assetstatus; separat installationsknapp | 2026-08-24 |
| Installation före fallback | Ersätter omedelbar fallback: stödd saknad svensk resurs installeras vid start. Verkliga fel ger ny analyzer för Dictation; avbryt startar inte fallback | 2026-09-28 |
| Inga externa integrationer i v0.2.0 | Ingen OpenAI, EventKit, systemalarm eller konto; Kalender och Morgon är lokala vyer | 2026-08-24 |
| Gemensamt Xcode 27-bygge | Ett jobb på `xcode-27` är konfigurerat för Release, XCTest och osignerad IPA med iOS 27 SDK och lägsta iOS-version 26.0 | 2026-09-25 |
| Beständiga namn och versioner | Projektet heter Mio; produktmilstolpar använder v0.x.y enligt roadmapen | 2026-09-22 |

## Ny appidentitet och testtelefon, 2026-09-26

Det tidigare kompatibilitetsbeslutet ersätts efter användarens uttryckliga besked att prototypen är raderad. Bundle identifier är **`app.mio.assistant`**, testidentifierare `app.mio.assistant.tests` och lagringsmapp **`Mio`**. Ingen automatisk fas-migrering finns. Identifierare är stabila och versionsnumret ligger separat i Xcode.

Första enhetsprov sker på **iPhone 16 Pro**, senare på iPhone 13. Xcode 27-bygget och iOS 27-simulatorn behålls; minsta iOS-version är 26.0. En modell/OS-kombination verifierar inte en annan.

Liquid Glass används för centrala knappar och systemets navigation/flikar. Innehåll använder semantiska bakgrunder och färger. Dynamic Type, VoiceOver, Minska rörelse och Minska genomskinlighet ingår i telefonproven. Riktlinjer: [Apples material](https://developer.apple.com/design/human-interface-guidelines/materials), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## Enheten är facit

Det historiska provet använde `DictationTranscriber` med `sv_SE`; den svenska `SpeechTranscriber`-resursen kunde inte installeras då. Ny resurslogik är inte verifierad av det provet. Bakgrund, batteri och ljudavbrott måste provas på telefonen; en simulator ersätter inte det.

## Helhetsbeslut 2026-09-25

Användaren ersätter arbetet version för version med ett sammanhängande helhetsbygge och väljer att även bygga AI-klient och server, med molnet avstängt tills egen konfiguration finns. Regeln om inga integrationer i v0.2.0 gäller den historiska versionen; den begränsar inte helhetsbygget 0.9.0.

- Lokala frågor/förslag och lektionsmetadata har ett separat `assistant-v1.json`. Originalsessioner och `content-v1.json` behåller sina text-/bevisformat; den aktuella rotmappen är Mio enligt beslutet ovan. Gemensam export använder schema 2 och kan läsa äldre schema 1 utan assistantfält.
- Enkel svensk kommandogrammatik ger lokala utkast. Frågor till AI skiljs från innehållsförslag; inget föreslaget minne eller plan skrivs till innehållslagret utan Ja. Samma förslags-ID används vid omförsök för att undvika dubbletter.
- Ja/Nej/Inte nu är knappar i appen. Röstigenkänning av ett fristående ”ja” utlöser inga åtgärder. Tid i fri text måste granskas och väljas manuellt.
- Lektioner är redigerbara namn, anteckningar och intervall över avslutade sessioner. De delar eller ändrar aldrig originalsegment.
- Systemkalendern använder `EKEventEditViewController`: användaren granskar och sparar en fristående kopia. Ingen kalenderläsning eller automatisk tvåvägssynk. Kopian kan synkas av det valda kalenderkontot och raderas i Kalender.
- AlarmKit används för riktiga engångs-/veckoalarm med systemets stopp. Ingen egen nedräkning/snooze eller Live Activity-extension. Notiser är separata och följer systemets inställningar. Låsskärmtext innehåller inga privata postrubriker.
- Dagsöversikten visar sparade poster och antal sessioner/lektioner lokalt. Den ger inte sken av att vara en semantisk transkriptionssammanfattning.
- AI-klienten har ett explicit sändningsgodkännande per fråga. Kontext börjar tom och väljs/redigeras manuellt. Gatewaytoken ligger i Keychain, serveradress/aktiveringsval i egna UserDefaults; OpenAI-nyckeln ligger endast i serverns miljö. HTTPS krävs och redirect följs inte.
- Servern använder Responses API med `store: false`, auth, fasta storleks-/tidsgränser och förbrukningsgränser. Ingen textlogg eller beständig frågehistorik skrivs. Leverantörens egna datavillkor gäller fortfarande. Se [serverguiden](../server/README.md).
- En gemensam skrivspärr skyddar fullständig radering mot pågående/eftersläpande UI-skrivningar. En misslyckad systemavbrytning får inte rapporteras som lyckad total radering.

Referenser för plattformsval: [EventKitUI utan generell kalenderåtkomst](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [AlarmKit](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit), [Apples privacy-manifest](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest). SDK-kompatibiliteten måste slutligen verifieras av Xcode för aktuell revision.

## Korrigerat assistentflöde, 2026-09-26

Användaren har efter telefonprov bekräftat löpande analys av korta textutdrag efter uttrycklig aktivering, och vill ha tydliga systeminstruktioner med OpenAI först och möjlighet att byta leverantör senare. Detta förtydligar de äldre reglerna ovan:

- AI är av i varje ny app-process. Aktivering godkänner framtida vardagstext och text från lektioner som avslutas medan läget är på. En historisk lektion kräver ett separat val. Äldre vardagstext tas inte med vid aktivering, även när en vardagssession ligger pausad bakom en lektion.
- Vardagsutdrag samlas ungefär en minut, högst åtta fragment/10 000 byte per anrop. Paus/stopp kastar väntande vardagsanalys. Avstängning/radering avbryter relevanta anrop och sena svar får inte återskapa data. Redan skickad text/kostnad kan inte återkallas.
- Separat Starta lektion stoppar vardagens ljudflöde före lektionsstart. Efter avslut är vardags-Mio pausat tills Fortsätt Mio väljs. AI ger källkopplade delanteckningar; inget råljud sparas. Manuell historisk lektionsindelning bevaras men är inte det primära flödet.
- `/v1/analyze` lämnar endast validerade plan-/uppgifts-/anteckningsutkast och lektionspunkter. Inga automatiska minnen, verktyg eller externa åtgärder. Datum tolkas mot källtid/tidszon, saknade tider är null, och användaren måste kontrollera tid före godkännande av AI-planer/uppgifter.
- Serverns `prompts.mjs` skiljer vardag, lektion, källmaterial och instruktioner. `provider.mjs` isolerar OpenAI-anrop och svarstolkning. Endast OpenAI-adaptern är implementerad; modell väljs i servermiljön. Byte kräver modellprov, inte enbart ändring av URL.
- För enskilda frågor gäller fortfarande exakt sändningspreview. Gatewaytoken ligger i Keychain och hålls dessutom i arbetsminnet under det aktiverade analysläget för låst skärm. Ändrad anslutning stänger av läget. API-nyckeln finns bara på servern.

Källcitat och schema är tekniska kontroller, inte ett bevis på semantisk korrekthet eller skydd mot alla promptinjektioner. Modellens verkliga urval och svenska datumtolkning måste provas med syntetiska exempel före vardagsbruk.

## Drift utan egen påslagen dator, 2026-09-27

Användaren vill slippa en påslagen egen dator och föredrar gratis drift. Cloudflare Workers med workers.dev-adress förbereds därför som alternativ till egen Node/Caddy-värd. Modellen körs fortfarande hos OpenAI. Direkt API från en privat klient är tekniskt möjligt men skulle kräva API-nyckeln på telefonen; gatewayen behåller serverägd nyckel. Samma systeminstruktioner, HTTP-kontrakt och validering återanvänds.

En D1-tabell med fyra heltalsräknare ger global minut-/dygnskvot över Worker-omstarter. Inga texter, nycklar eller IP-adresser lagras där. Cloudflare-konto och egna hemligheter krävs före driftsättning; inga resurser är skapade genom kodändringen. [Driftguide](../server/README.md).

## Svensk talmodell 2026-09-28 — källändring, ej telefonverifierad

Apples [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) skiljer stödda/nedladdningsbara språk från installerade. [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory) hanterar hämtning innan analyzerstart. [WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/) visar detta flöde för långvarig transkription.

Val: behåll Apples lokala kedja, men försök installation när `supportedLocale(equivalentTo:)` hittar svenska. Det tar bort antagandet att en saknad installation kräver omedelbar fallback. Första start kan ta längre tid och kräva nät; efter installation används lokala resurser. Ingen avgiftsbelagd AI-tjänst används för talet. Både separat förinstallation och installation vid start finns. Dictation förblir reserv vid saknat stöd eller faktiskt fel.

Alternativet att alltid starta Dictation ger snabbare första start men kan permanent lämna den nyare modellen oanvänd. WhisperKit eller annan motor tillför modellhantering och underhåll; inget sådant byte görs före enhetsprov enligt användarens instruktion. Precision, batteri, värme och faktisk startlatens är inte jämförda på måltelefonen och får inte antas bättre. API-stödet kräver iOS 26+, men språk/hårdvarustöd kontrolleras vid körning.

Diagnostiken visar tillgänglighet, resolved svensk locale, svenska poster i supportedLocales och installedLocales, assetstatus och hämtningsbehov. Före/efter start sparas detta som vanliga diagnostikhändelser i befintlig sessionsexport. Fallbackfel innehåller domän/kod. Tom installedLocales innebär inte att svenska är ostött.

## Utbytbar AI och detaljerade lektioner, 2026-09-28

Ersätter det tidigare beslutet om enbart OpenAI och korta lektionspunkter för nya appversioner. [Leverantörsguiden](../server/README.md) innehåller aktuella katalogen, officiella API-källor och exakt Cloudflare-konfiguration.

- Responses-, Chat Completions- och Messages-adaptrar normaliserar samma kontrakt. Serverägda separata nycklar och neutrala `MIO_AI_PROVIDER`/`MIO_AI_MODEL`; ingen modellväljare i appen. Legacy `MIO_OPENAI_MODEL` läses endast som OpenAI-fallback för konfiguration, aldrig som modellfallback vid anropsfel.
- Reasoning av, temperatur 0 och strikt schema är krav. Vissa modeller saknar avstängning och avvisas. En konservativ katalog minskar risken för tyst ignorerade parametrar men kan behöva uppdateras. Egen kompatibel endpoint kräver operatörens uttryckliga försäkran. Inga verkliga modellprov är ännu gjorda; mocktester verifierar våra requestformat och kontrollflöden.
- Vercel/OpenRouter lägger till en mellanhand. De medföljande katalogvalen begränsar dessa till OpenAI-routning utan leverantörsfallback. Direkt Groq undviker den extra mellanhanden för användarens Qwen-val. Datavillkor gäller per leverantör; endast Responses-format begär `store: false`.
- Ny `/v1/lesson-notes` håller gamla `/v1/analyze` kompatibel. Tydlig egen systemprompt skriver utförliga avsnitt och faktiska läxförslag, inga läromedel. Högst 3500 byte källtext och 3000 output-tokens per anrop; inga råljud eller hela heldagar till molnet.
- Delresultat sparas atomiskt tillsammans med förslag. Varje del har käll-ID/exakt citat och serverägd modell-/promptmetadata. Kopiering sammanställer delar i källordning utan ytterligare AI-anrop; detta bevarar detaljer och minskar kostnad men kan lämna upprepningar och ämnen som fortsätter över delgränser. Ingen global redaktionell omskrivning görs.
- Standardtakten är minst 60 sekunder mellan lektionsanrop; intervallet kan höjas på servern. Längre väntan begränsar förbrukning men ger högre total latens. 429 stoppar arbetet med väntetid och manuell fortsättning. Färdiga detaljerade delar hoppas över efter omstart; aktiveringssamtycket återställs fortfarande. Ingen automatisk bakgrundsfortsättning eller återförsöksslinga.
- Temperaturen och schemat förbättrar kontrollen över formatet men bevisar inte urval, fakta eller lektionskvalitet. Svenska modellprov, precision, latens och kostnad måste mätas; lokala ändringar i text-AI säger inget om mikrofonens batteriförbrukning.

## Cloudflare Access som yttre skydd, 2026-09-29

Gatewaytoken behålls. Valfritt service-token-par i iOS ger stöd för Cloudflare Access före Worker-invokation, utan webbinloggning eller extra modellmellanhand. Paret lagras i samma Keychain-post och skickas i separata headers, aldrig till AI-leverantören. Befintlig D1-kvot begränsar modelltrafik, inte obehöriga Worker-invokationer. Worker-skydd med All traffic föredras framför enbart domänskydd för att täcka alternativa adresser. Kontoaktivering sker enligt [guiden](../server/README.md), inte genom Swift-koden.

Detta tillför två hemlighetsfält och hantering av giltighet/rotation, men ingen extra AI-kostnad eller bakgrundsprocess på telefonen. Access adderar nätverkskontroll och ett driftberoende; faktisk latens/batteripåverkan och kontots prisvillkor är inte mätta. Enbart gatewaytoken är enklare men avvisar först inne i Workern. Webbinloggning har valts bort eftersom klienten använder korta API-anrop utan cookies eller redirects. Verklig Access-konfiguration och iPhone-funktion återstår att verifiera. [Cloudflares dokumentation](https://developers.cloudflare.com/workers/configuration/cloudflare-access/).

## 2026-09-30: original Pianissimo via privat Tailscale

Användarens uttryckliga motorbyte ersätter tidigare krav på verifierad Apple-fallback. Apple SpeechAnalyzer/SpeechTranscriber/DictationTranscriber tas ur aktiv kod. Original `KlangAI/pianissimo-sv` körs serverägt via NeMo/PyTorch/CUDA och låst beroendemiljö (revisionen följer senaste versionen sedan 2026-10-05). Ingen kvantisering, CPU-fallback eller publik port. Appen känner bara [API v1](../transcription-server/API.md); modellbyte bakom kompatibelt kontrakt kräver ingen ny app.

20 s ägda ljuddelar med 1 s överlappande kontext ger få och enkla HTTP-anrop. Förväntad produktlatens är 15–30 s; riktig svensk precision/latens och ord vid delgränser återstår att mäta. WebSocket/streaming och HA väljs bort för ett personligt enanvändarprojekt. Downtime vid PC-omstart accepteras. Tailscale Serve terminerar HTTPS privat och systemd startar/återstartar en ensam modellprocess. Token och tailnet-behörighet är separata skydd.

Jämfört med Apple-lösningen blir ingen Apple-svenskmodell nödvändig på telefonen. Precision är ännu inte jämförd. Inference flyttas från telefonen till GPU:n, men nätverk och mikrofon kostar fortfarande batteri; nettovinsten måste mätas. Ingen tokenbaserad ASR-kostnad, däremot egen el/GPU och beroende av vaken dator/Tailscale. Python/GPU-drivrutin innebär mer serverunderhåll. Enkel loopback-tjänst med health, hårda tidsgränser och omstart bedöms passa bättre än distribuerad kö/autoskalning.

Ljud bara i RAM: högst 60 s från äldsta sample på telefonen, kortare vid stopp. Förfallna delar markeras som luckor och sena svar ignoreras. Samma chunk-ID vid retry, kort servercache av textsvar. Appens lokala original, ljudtider och schemahistorik bevaras; luckor följer med kopierade lektionsanteckningar. Text-AI förblir separat och kräver befintliga godkännanden. Ljudstart, inte ankomsttid, avgör om fördröjd vardagstext ligger efter AI-samtycket.

Aktiv användarstyrd mikrofon använder AVAudioSession `.record`/`.measurement` och befintligt audio-background mode. Ljudmotorn har en serialiserad kö, återhämtar sig vid tillåtna avbrott och kontrollerar riktiga buffertar. Nätfel pausar inte fångsten så länge mikrofonen fungerar. Efter media reset krävs uttryckligt Fortsätt enligt Apple. Kort `beginBackgroundTask` skyddar avslut/sparande, inte generell bakgrundsdrift. Tvångsavslutning/OS-terminering återstartar aldrig mikrofonen. Äldre `Session activation failed` är en observation, ingen bevisad rotorsak; den nya arkitekturen är inte telefonverifierad.

Inställningar samlas under kugghjulet i alla flikar. Separata sidor för transkription, valfri text-AI och integritet/data; status visar verifierad serverkontakt, inte påstådd insyn i Tailscales VPN. Sparbekräftelse ska finnas även när en ny konfiguration skickar reset-notifikationer. Haptics är diskreta och avstängningsbara; rörelse respekterar tillgänglighet.

Källor: [Pianissimo-modellkort](https://huggingface.co/KlangAI/pianissimo-sv), [NeMo installation](https://docs.nvidia.com/nemo/speech/3.0.0/starthere/install.html), [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve), [iOS VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand), [Apple interruptions](https://developer.apple.com/documentation/AVFAudio/handling-audio-interruptions), [media services reset](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification), [bakgrundstid](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time), [AVAudioEngineConfigurationChange](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange).

## Begränsad kontinuitet och AI-diagnostik, 2026-09-30

Användarens ”Implementera planen” godkänner utredningens beteendeändringar i arbetskopian. Detta ersätter den tidigare regeln att paus/stopp kastar väntande vardagsanalys; avstängning, anslutningsbyte och radering fortsätter att avbryta och avvisa sena svar. Ingen publicering eller modelltrafik godkänns av detta beslut.

- Kombinera normalt en minuts batching med högst en minuts tidigare godkänd text och en mjuk meningsgräns. Inga extra modell-/turdetektionsanrop. Nytt underlag väntar normalt 60 s och kan vänta ytterligare högst 60 s vid en oavslutad mening; nätlatens och förbrukningens minsta intervall kan ändå försena arbetet. Stoppets sluttext kan skickas utan mjuk väntan men nästa sändning sker tidigast 60 s efter att föregående sändning avslutats, även om dess statuskontroll tog tid. iOS-bakgrundskörning är fortfarande en enhetsberoende begränsning.
- En versionsmärkt v2-rutt håller nya källor åtskilda från kontext. Stabila textfria beslut ger uttryckliga kompletteringar av öppna utkast och skyddar Ja/Nej. Kontextbegränsning synliggörs för modellen och i diagnostiken. Tvetydiga beslut slås inte ihop. Lektioner behåller v1/3500-byteformatet.
- Skyddad `/v1/status` kontrollerar syntaktisk konfiguration och v2-capability utan modelltrafik/kvot. Klienten vägrar inkompatibel gateway; ingen tyst fallback. Nyckelns verkliga giltighet kräver modellprov. Releaseheaders och en lokal begränsad journal gör även misslyckade frågor utan session felsökbara.

Avvägning: överlapp kostar fler inputtoken och håller upp till en minut extra godkänd text i samma API-anrop; budgeten begränsar det. Mjuk väntan minskar avhuggna meningar utan ny detektionsmodell, men ger extra latens och är ingen säker konversationsslutsdetektor. Varken modellens semantik eller transcriptprecision garanteras. Enbart tystnadsdetektion valdes bort eftersom pauser kan ligga mitt i en mening; en extra semantisk modell valdes bort för batteri, latens, drift och kostnad. En hel historik/minnessammanfattning valdes bort för integritet och underhåll. Se primärkällorna i utredningen. Dygnskvoten 100 är oförändrad och gäller tillsammans för frågor/vardag/lektioner; det är ingen heldagskapacitet.
