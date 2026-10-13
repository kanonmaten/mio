# Beslut och tekniska kontrakt

Aktuella beslut står först. Daterade avsnitt bevarar beslutens historia; ett senare uttryckligt beslut ersätter ett äldre där de skiljer sig. [Ändringsloggen](../CHANGELOG.md) beskriver källändringar; [status](STATUS.md) beskriver faktiskt utförda kontroller.

## Strikt concurrency i det riktiga iOS-targetet, 2026-10-13

Sedan körning #37 (`034cdbc`) underkänner det native concurrency-steget i "Bygg Mio IPA" (Xcode 27, `SWIFT_STRICT_CONCURRENCY=complete`) med 88 varningsblock, medan den portabla kontrollen på Linux var godkänd. Blocken kom från fem orsaker. Varje orsak är rättad i koden så att kompilatorn kan bevisa säkerheten. Inget är tystat med `@preconcurrency` eller `nonisolated(unsafe)`.

- **`#Predicate` i SwiftData-lagret:** Foundations makro kräver `KeyPath & Sendable`, och i Swift 5-läge antas en nyckelväg som `\.sessionID` inte vara Sendable. Valt: byggvärdet `SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES = YES` för Mio-targetet (Debug och Release). Det slår på [SE-0418](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md), som redan gäller i Swift 6-läge: kompilatorn härleder Sendable ur det nyckelvägen fångar, och här fångar den ingenting. Apple (DTS) rekommenderar samma byggvärde för projekt som är kvar på Swift 5 ([Apple Developer Forums](https://developer.apple.com/forums/thread/765429)); Apples SwiftData-dokumentation säger inget om detta. Bortvalt: Swift 6-läge för hela targetet (gör varningar i alla filer till fel, större ändring), `@preconcurrency import` av Foundation eller SwiftData (döljer alla Sendable-fel från modulen) och att vänta till Swift 6.
- **AlarmKit:** `AlarmManager` är inte Sendable och dess asynkrona metoder är `@concurrent`. Att anropa dem på `alarmManager`-egenskapen skickade huvudaktörens tillstånd ut ur aktören. Valt: `requestAuthorization()` och `schedule(id:configuration:)` körs i två `nonisolated` statiska hjälpare mot `AlarmManager.shared`, samma mönster som `removeSystemEntries`. Bara Sendable-svar (`AuthorizationState`, `Alarm`) kommer tillbaka. Bortvalt: `nonisolated(unsafe)` på egenskapen och `@preconcurrency import AlarmKit`.
- **Live Activity:** `Activity` är inte Sendable och `update`/`end` är `@concurrent`, så en sparad instans på huvudaktören kunde inte skickas till dem. Valt: kontrollern sparar bara aktivitetens id och sessions-id och slår upp aktiviteten i `Activity.activities` med en vanlig `for`-loop före varje anrop. Ett uppslag med closure (`first(where:)`) knyter resultatet till huvudaktören igen. En aktivitet som användaren stängt förblir stängd resten av sessionen, även när systemet tagit bort den ur listan. Bortvalt: en egen actor som äger instansen (ger samma varning, eftersom `@concurrent` lämnar varje actor), `nonisolated(unsafe)` och `@preconcurrency import ActivityKit`.
- **Inställningsmiljön:** `OpenMioSettingsKey.defaultValue` är nu beräknad i stället för en sparad statisk closure, så det finns inget delat globalt tillstånd.
- **`MioViewModel.deinit`:** blir `isolated deinit` ([SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md); runtimestödet finns i iOS 26, Mios lägsta version). Observatörstoken för batteriet är huvudaktörens tillstånd och tas bort där. Deras block håller modellen svagt, så en något senare borttagning kan inte anropa en frigjord modell. Bortvalt: `@preconcurrency import ObjectiveC`, som kompilatorn föreslog, och `nonisolated(unsafe)` på listan.
- **Portabla kontrollen:** `verify_concurrency.py` utan `--native` körde `swiftc -typecheck`. Varningarna "sending … risks causing data races" kommer från regionbaserad isolering, ett SIL-steg som `-typecheck` aldrig kör, och därför var Linux grön. Kontrollen kör nu `-wmo -emit-sil` med samma kommande funktion som Mio-targetet. Med den gamla `deinit` hittar den nu batterivarningen även på Linux.

Steget i IPA-workflowen är fortfarande diagnostik (`continue-on-error`). Om det ska stoppa IPA:n efter en grön native-körning är användarens beslut (PLAN.md: rätta först, skärp sedan). Ej verifierat: native-bygget med ändringarna och, på telefonen, att en nystartad Live Activity finns i `Activity.activities` så att uppdatering och avslut träffar den.

## Rättningar efter provet och Apples appar, 2026-10-13

Användarbeslut 2026-10-13 efter exporten samma dag. Hela planen står i [PLAN_APPLEAPPAR.md](PLAN_APPLEAPPAR.md); här står besluten och vad som valdes bort.

- **Namn:** Anteckning, Att göra, Händelse (tidigare Plan) och Minne överallt. Lagrade värden ändras inte. Mios inställningsdel "Påminnelser" byter namn till Notiser i 0.9.1. Bortvalt för Plan: Tillfälle och Bokning (Händelse är Apples ord i Kalender).
- **0.9.0:** ett lektionsblock som underkänns två gånger delas i två halvor; en halva som underkänns igen markeras "kunde inte bearbetas" med originaltexten synlig och lektionen fortsätter (bortvalt: hoppa över hela blocket direkt, stanna och fråga). Förslagets text är det användaren sa, byggt i appen ur källsegmenten; prompten ber inte längre om förtydligande i `body`. Detta ersätter den delen av beslutet "Tomma AI-svar visas och oklar dag ger förslag". Prov, möten och bokningar är alltid händelser; annat blir händelse med klockslag och annars att göra. Datum utan klockslag blir heldag och uppdateras om ett klockslag hörs innan användaren svarat (bortvalt: spärra Ja, snabbval i förslaget). Långa köer slås ihop till större anrop och Hem visar eftersläpningen. Transkriptionen mäts med FLEURS och ett uppläst känt stycke; privata inspelningar mäts aldrig och råljud sparas aldrig.
- **0.9.1:** Apple äger posterna och Mio sparar bara en överlämning med länk (bortvalt: kopia i båda, eller att Mio glömmer allt). Händelser skickas via Kalenders egen redigerare utan behörighet (bortvalt: åtkomst som bara skriver, full kalenderåtkomst). Att göra-poster skapas direkt med full åtkomst till Påminnelser, eftersom Apple saknar åtkomst som bara skriver påminnelser (bortvalt: dela-arket utan datum, Genvägar). Anteckningar och minnen går via dela-arket till Anteckningar, som saknar API (bortvalt: Genvägar, kopiera och öppna). Kalender-fliken, plusknappen, lokala poster, AlarmKit och postnotiser tas bort; befintliga poster raderas vid uppgraderingen. Anteckningar-fliken blir Förslag. Hem läser kommande påminnelser men inte kalendern.

Genomfört i 0.9.0: när mer än en vardagsbatch väntar skickas tolv nya textdelar per anrop i stället för fem, men bara om gatewayn anger `analysis-backlog-v1` i `/v2/status`, så en gateway som inte startats om aldrig får en batch den underkänner. Gatewayns gräns blir sexton källor, 16 000 byte text och 40 000 byte body. I exporten var varje anrop cirka 1 800–2 200 token, där den fasta prompten var största delen, så färre och större anrop sparar också token. Hem visar "AI ligger N min efter" när den äldsta köade vardagstexten är äldre än 10 min. Bortvalt: köa nyast först (sammanhanget och ersättningar bygger på källordning).

Genomfört i 0.9.0: heldag uttrycks som `scheduledAt` i formen `ÅÅÅÅ-MM-DD` i stället för nya fält `date` och `time`, eftersom en äldre app då bara ser ett saknat datum och gatewayns resultatversion kan vara kvar. Prompterna har versionen `2026-10-13.2` (vardag, v2 och lektion) och gatewayns release är `2026-10-13.2`.

Version: användaren valde senare 2026-10-13 att behålla 0.9.1 för Apple-delen och att 0.9.0 är revisionen `8f90ddc` med rättningarna. Det ersätter beslutet "Byggnummer från IPA-körningen, version 0.9.0 kvar" i den delen; byggnumret följer fortfarande IPA-körningen. Ingen av versionerna är verifierad på telefonen, och ingen tagg är skapad. Bortvalt: att räkna allt till det ej släppta 0.9.0.

Genomfört i 0.9.1: överlämningen sparas som en innehållspost med valfritt `handoff` (destination, Påminnelsers ID, tid), utan text, datum eller status, så godkännande, radering och export (schema 2) återanvänds utan schemaändring. Bortvalt: en egen SwiftData-tabell och export 3 (ny `VersionedSchema` för samma information). En påminnelse får länken `mio://session/<id>?forslag=<id>` (eller `mio://forslag/<id>`), och Mio letar efter den länken före ny sparning, så ett nytt Ja efter ett lokalt skrivfel aldrig ger två påminnelser. Inspelning i Kalenders redigerare och dela-arket registreras även om AI hunnit uppdatera förslaget, eftersom användarens sparning i Apples ruta är det som gäller. Gamla poster raderas en gång vid start (bara i appen, aldrig i testernas arbetsflöden), därefter alla Mio-alarm och `mio.reminder.*`; morgon- och kvällsnotisen behålls. AlarmKit-nyckeln och rensningskoden ligger kvar i 0.9.1 så att gamla alarm kan avbrytas.

Ej verifierat: allt som rör telefonen i 0.9.1 och modellens följsamhet till klassningen och datumregeln.

## AI-utskick när telefonen är låst och ikappsändning, 2026-10-12

Användarbeslut 2026-10-12 efter telefonprovet samma dag, där inget nådde Groq. Kompletterar "samlade vardagsutskick" från 2026-10-11.

- **Orsak:** gatewaytoken låg i Keychain som `WhenUnlockedThisDeviceOnly`. När femminutersfönstret stängdes med låst telefon kunde token inte läsas, det tolkades som ändrad parning och AI stängdes av med kön. Nästa start räknade all tidigare text som redan sedd.
- **Keychain:** gatewayns och Pianissimos token sparas som `AfterFirstUnlockThisDeviceOnly` och flyttas en gång vid start. De går att läsa med låst skärm efter första upplåsningen sedan omstart, är fortfarande bundna till enheten (följer aldrig med till en annan telefon) och ingår aldrig i export. Apple rekommenderar den klassen för poster som behövs i bakgrunden ([kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)).
- **Låst Keychain är inte en ändrad parning:** kan token inte läsas (`errSecInteractionNotAllowed`) väntar AI på upplåsning och behåller kön.
- **Ikappsändning:** vid start skickas vardagstext från de senaste 12 timmarna som fångades medan AI var på men aldrig analyserades (appen stängdes, kön tömdes). En textfri samtyckeslogg (`mio.ai.consentLog.v1`: tider för på, paus och överhoppade kvotpauser, högst 24 h) avgör vad som fångades med AI på. Redan analyserad text, lektioner, text under paus och text som hoppats över under en lång kvotpaus skickas aldrig. Avslutade sessioner skickas utan att vänta på nytt femminutersfönster men med minst 60 s mellan anrop; högst 60 delar köas, de nyaste först.
- **Avbrott, fel och paus** skickar redan fångad vardagstext direkt i stället för att kasta den; ett pågående anrop får bli klart. Ljudluckan håller isär sammanhanget före och efter.
- **Stängs appen medan ett anrop pågår** bryts anslutningen och gatewayn avbryter Groq-anropet. Svaret sparas inte, texten räknas inte som analyserad och skickas ikapp vid nästa start. Har Groq redan börjat kan anropet ha räknats mot dagens token.

Förkastat: att spara kön på disk (dubbel sanning bredvid transkriptet och processade källor) och att behålla `WhenUnlocked` och bara vänta (AI skulle stå still så länge telefonen ligger låst i fickan). Ej verifierat på telefon.

## Veckoplaneraren, 2026-10-11

Användarbeslut 2026-10-11: appen får designen veckoplaneraren. Ersätter de fem flikarna Mio, Lektioner, Kalender, Anteckningar och Morgon.

- **Utseende:** violett grund, vanliga läsytor för anteckningar, transkript och listor, och Liquid Glass bara på flikfält och knappar.
- **Flikar:** Hem, Lektioner, Kalender och Anteckningar, plus Fånga som separat rund mikrofonknapp längst till höger (iOS 26-flik med rollen `.search`). Fånga ersätter Mio-fliken och startar aldrig mikrofonen bara för att den öppnas. Morgon-fliken är borta; morgon- och kvällsöversikten ligger på Hem (kväll från kl. 17), och morgon-/kvällsnotiser öppnar Hem.
- **Hem:** veckonumret som rubrik, veckans sju dagar, Nästa, antal att granska, dagens översikt och ett rutnät över tolv veckor. Veckor följer svensk ISO 8601-regel (måndag först, vecka 1 innehåller årets första torsdag). Aktiviteten räknas lokalt ur sessioner och poster och lagras inte; bara antal, ingen text.
- **Lyssningsraden** ovanför flikfältet använder `tabViewBottomAccessory(isEnabled:)`, som kräver iOS 26.1; på 26.0 visar Live Activity och Fånga läget. Den är medvetet diskret: en prick och kort status, ingen röd färg eller vågform.
- **Fråga Mio** öppnas från Hem och Fånga och visar upp till tre frågor byggda på telefonen. Ett tryck fyller bara i fältet.

Ej verifierat på telefon: läsbarhet på violett grund i ljust och mörkt läge, största Dynamic Type, Reduce Motion/Transparency, iPhone 13-layouten och lyssningsraden.

## AI-gatewayen på datorn med Groq, 2026-10-11

Användarbeslut 2026-10-11. Ersätter Cloudflare Worker, D1 och Access (beslut 2026-09-27 och 2026-09-29) och NVIDIA NIM (2026-10-05).

- Node-gatewayen kör på användarens CachyOS-dator bredvid Pianissimo, bakom `tailscale serve --https=8443`. `server/install.sh` installerar tjänsten och `mio-pair` visar parningskoden. Leverantörsnyckeln finns bara på datorn.
- Groq `qwen/qwen3.8-27b` är enda leverantör tills appen är bekräftad fungerande. Leverantörssömmen finns kvar så att Anthropic kan läggas till senare. Inget tyst byte av modell eller leverantör.
- Installationen sätter 190 000 token per dygn (under gratisnivåns 200 000) och tre anrop per minut. Räknarna sparas på disk och överlever omstart.
- Worker-, D1- och Access-koden är borttagen ur repot. Nedmontering av de publicerade Cloudflare-resurserna och byte av den gamla Groq-nyckeln kräver separat godkännande.

Avvägning: datorn måste vara igång för AI, precis som för transkription, men inget konto hos Cloudflare och ingen publik adress behövs. Inget riktigt Groq-anrop är gjort ännu.

## En parning, AI alltid på och samlade vardagsutskick, 2026-10-11

Användarbeslut (helhetsplanen 2026-10-11, avsnitt D och E). Ersätter "AI av vid start", "Tillåt molnfrågor", förhandsgranskning före varje fråga och Cloudflare Access i appen.

- **Parning:** en QR-kod från `mio-pair` (`{"mio":1,"aiURL","aiToken","transcriptionURL"|null,"transcriptionToken"|null}`) ersätter två separata inställningar. Skanning med VisionKit `DataScannerViewController` (bara QR) efter `isSupported`/`isAvailable`; fyra manuella fält som reserv. Parsern (`MioPairingPayload`) är portabel och strikt: okända nycklar, annan version, http, sökväg/fråga/användare och felaktiga token avvisas. Förkastat: AVFoundation-metadata direkt (mer egen kod) och kamerabibliotek (beroende).
- **AI på som standard** när datorn är parad (`mio.ai.enabled`, saknas = på). Pausen sparas. Enskilda frågor skickas utan förhandsgranskning; varje svar valideras ändå och förslag kräver Ja. En uppgradering med sparad gammal server startar pausad, så inget skickas till en gammal Cloudflare-gateway utan att användaren väljer det.
- **Utskick:** vardagstext samlas i fönster om fem minuter (`MioAnalysisSchedule`), så att en dags lyssning ryms i Groqs 200 000 token per dygn; lektionsdelar behåller minst 60 s. 429 med `Retry-After` (även `local_token_limit`, `local_day_limit` till kvotens återställning) och nätfel (5 min) pausar och fortsätter automatiskt. Vid paus längre än fem minuter hoppas vardagstalet under pausen över i stället för att köas.
- **Inställningar** i en panel från höger med Liquid Glass bara på ramen; raderna är vanliga grupperade rader.

Källor: [DataScannerViewController](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller), [DataScannerViewControllerDelegate](https://developer.apple.com/documentation/visionkit/datascannerviewcontrollerdelegate), [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), [accessibilityAction(_:_:)](https://developer.apple.com/documentation/swiftui/view/accessibilityaction(_:_:)). Ej verifierat på telefon: skanningen, kamerafrågan, kantsvepet bredvid listors svepåtgärder, VoiceOver-fokus och femminutersfönstret i verklig drift.

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

Ej verifierat: den riktiga Sortformer-körningen (skriven mot källkoden i NeMo 2.7.0 utan GPU-prov; signaturerna är oförändrade i NeMo 3.0.0), svensk talarkvalitet (modellen är främst tränad på engelska), extra GPU-minne och latens, samt om förbehandlingen faktiskt sänker ordfelen. Mät med skriptet på datorn innan förbehandlingen eller talarmärkningen betraktas som förbättringar.

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
| Gemensamt Xcode 27-bygge | Två parallella jobb på `xcode-27` (sedan 2026-10-13): ett för Release och osignerad IPA, ett för XCTest, UI-tester och concurrency-diagnos, med iOS 27 SDK och lägsta iOS-version 26.0 | 2026-09-25 |
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

## SwiftData i stället för hela JSON-filer, 2026-10-11

Sessioner, innehåll och assistentdata lagras i SwiftData (iOS 26) med ett `VersionedSchema` och en `SchemaMigrationPlan`. Raderna har identitetskolumner och Codable-payload, så modellerna i appen förblir värdetyper och nya valfria fält kräver ingen schemaändring. Skälet är minnestoppen vid helfilsomskrivning (cirka 248 MiB) och skrivvolymen under lång fångst. Bortvalt: egen SQLite (mer kod och underhåll), Core Data direkt (äldre API utan fördel här) och fortsatt JSON uppdelad per session (löser inte assistentdokumentet och kräver egen transaktionslogik). JSON-actorerna finns kvar som reserv vid avbruten migrering och för Linux-testerna. Raderingsjournalen och generationsspärrarna behålls, eftersom de skyddar steg och callbacks utanför databasen. Beteende på enheten (filskydd för SQLite-filerna, transaktioner, `#Index`, prestanda med riktiga data) är overifierat. Källor: [SwiftData](https://developer.apple.com/documentation/swiftdata), [VersionedSchema](https://developer.apple.com/documentation/swiftdata/versionedschema), [ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor), [MetricKit](https://developer.apple.com/documentation/metrickit).

## Tomma AI-svar visas och oklar dag ger förslag, 2026-10-13

Användaren valde 2026-10-13 båda åtgärderna efter telefonprovet, där 11 giltiga vardagssvar gav 0 förslag och inget syntes i appen. Appen visar nu varje vardagsgenomgång (Hem och sessionen) som presentation över befintliga `MioAnalysisRecord`; antalet förslag räknas fram ur de textfria besluten, där det senaste svaret vars nya fragment ingår i beslutets källor äger beslutet. Inget nytt fält eller schema. Bortvalt: spara antalet i posten (kräver fält och exportändring, äldre poster saknar det) och en notis per tomt svar (stör var femte minut).

Vardagsprompten får en egen regel: en tydlig plan eller uppgift med konkret handling eller klockslag blir en kandidat med `scheduledAt=null` och frågan om dagen i body, även med begränsat sammanhang; förslag kräver fortfarande Ja. `uncertainties` får inte beskriva underlaget eller säga att inget hittades. Bortvalt: sänka trösklarna generellt (TV-ljud och småprat ger då brus) och efterbearbeta osäkerheter till förslag i appen (gissning utanför modellens grundning). Regeln ligger bara i v2-tillägget, så frågor och lektioner behåller sina promptversioner. Effekten på `qwen/qwen3.8-27b` är **inte provad** med riktiga anrop.

## IPA och tester i två parallella jobb, 2026-10-13

Användaren valde 2026-10-13 att snabba upp "Bygg Mio IPA". Körning #35 tog 21 min, varav cirka 4,5 min kompilering (tre gånger) och resten simulatorn: enhetstester 7 min, UI-tester 4,8 min och skärmbilder 4 min. Nu bygger ett jobb Release och IPA (väntat cirka 5 min) medan ett annat kör testerna. Simulatorn börjar starta innan testerna kompileras, concurrency-diagnosen ligger sist i testjobbet och skärmbilderna körs bara när rutan bockas i vid start. Avvägning: IPA:n kan laddas ner innan testerna är klara, så en revision är testad först när testjobbet är grönt; två körare används samtidigt. Bortvalt: cache av byggfiler mellan körningar (bräckligt på värdade Mac-körare, högst någon minut) och parallella tester (togs bort efter hänget i körning #33). Tidsvinsterna är uppskattningar tills en körning har mätts.

## Byggnummer från IPA-körningen, version 0.9.0 kvar, 2026-10-13

Användaren valde 2026-10-13 att behålla versionen 0.9.0, eftersom den namnger det ej släppta helhetsbygget, och att byggnumret ska sättas automatiskt. IPA-jobbet skickar `CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER` till Release-bygget och kontrollerar värdet i appen och widgettillägget; `Mio-buildinfo.txt` kopplar numret till commiten. Bortvalt: 0.9.1 nu (antyder att 0.9.0 var klar) och manuell höjning i projektfilen (glömdes bort sedan bygge 5, så installationer gick inte att skilja åt). Körningsnumret ökar alltid, så SideStore och iOS ser varje IPA som nyare.
