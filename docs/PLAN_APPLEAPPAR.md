# Plan: rättningar efter provet 2026-10-13 och Apples appar

Användarbeslut 2026-10-13, efter genomgång av exporten från samma dag. Del A rättar 0.9.0. Del B flyttar ägandet av händelser, att göra-poster, anteckningar och minnen till Apples appar i 0.9.1. [`PLAN.md`](../PLAN.md) (tillförlitlighetsplanen för 0.9.0) gäller fortfarande och ändras inte; den här planen kompletterar den.

## Vad exporten visade

| Iakttagelse | Orsak |
|---|---|
| Lektionen Installationsteknik stannade på "40 av 56 textdelar" | Blocket 08:13:21–08:15:04 underkändes sex gånger av gatewayns validering (`invalid_lesson_result`, HTTP 502). Mio försökte om samma block varje gång, så de sista 16 delarna kom aldrig fram. |
| Vardagsanalysen låg cirka 75 min efter (kl. 12:21 behandlades tal från 11:06) | Kön var 13–16 fönster lång, Groq svarade 429 (`provider_quota`) tre gånger, och de sex omförsöken av lektionsblocket tog anrop från samma kvot. |
| Uppgiften "Religionsprov" fick AI:ns fråga som text | Vardagsprompten säger uttryckligen att modellen ska be om förtydligande i `body` när datum saknas (`server/src/prompts.mjs`, beslutet 2026-10-13). |
| Inget klockslag | AI:n såg bara 11:04 "Jag har religionsprov på torsdag." Meningen "klockan 15." kom 11:13:54 men hade inte nåtts av analysen när exporten togs. "På torsdag" gav `scheduledAt=null` i stället för ett datum. |
| Provet blev uppgift och syntes inte i Kalender | Ett prov är en händelse, men regeln skilde bara på "har klockslag". En lokal plan är heller ingen kalenderpost. |
| Transkriptionen har många ordfel ("svamptråda", "störnbrytare", "tändtål") | Inte mätt på riktigt tal ännu ([Pianissimo-guiden](../transcription-server/README.md#mäta-ordfelfrekvens)). |

## Namn

Samma ord överallt: typväljare, filter, förslag, Hem, notiser och dokumentation.

| Typ (lagrat värde) | Nytt namn | Tidigare |
|---|---|---|
| `note` | Anteckning | Anteckning / "Noter" |
| `task` | Att göra | Uppgift |
| `plan` | Händelse | Plan |
| `memory` | Minne | Uttryckligt minne / "Minnen" |

Lagrade värden och exportens fält ändras inte; bara visningsnamnen. Händelse är samma ord som Apples svenska Kalender använder. Mios inställningsdel "Påminnelser" heter **Notiser** från 0.9.1, så den inte förväxlas med Apples app Påminnelser.

## Del A, 0.9.0: rättningar

Ordning: A1, A2, A3, A4, A5. A6 gör användaren på datorn.

### A1. Fastnat lektionsblock (dela, sen hoppa över)

- Bara ett underkänt svar räknas: HTTP 502 med `invalid_lesson_result` eller en annan valideringskod. 429, nätfel och timeout pausar som i dag och räknas inte.
- Efter två underkännanden av samma block delas det i två halvor i källordning. En halva som underkänns två gånger till markeras **kunde inte bearbetas**; originaltexten visas på sin plats i anteckningarna och lektionen fortsätter med nästa block.
- Förloppet visar till exempel "54 av 56 textdelar bearbetade, 2 kunde inte bearbetas". Kopiering tar med originaltexten för de delarna, märkt som obearbetad.
- Markeringen sparas med segment-ID och korrigeringsrevision. Om transkriptet rättas kan delen försökas igen; annars försöker Mio aldrig om den automatiskt.
- Detta tar också bort den kvotförbrukning som gjorde vardagsanalysen sen.

### A2. Det du sa, inte AI:ns fråga

- Förslagets text byggs **i appen** av källsegmenten (`sourceIDs`), alltså det du faktiskt sa, till exempel "Jag har religionsprov på torsdag. Klockan 15." Rättningar i visningslagret används om de finns; originalet ändras aldrig.
- Prompten slutar be om förtydligande i `body`. Saknas datum eller tid anger fälten det, och granskningen visar det.
- Modellens `body` används inte som posttext. Fältet finns kvar i schemat tills gatewayn får en ny resultatversion, så att äldre klienter fortsätter fungera.

### A3. Datum, heldag och klassning

- **Vad det är + tid:** prov, möten, bokningar och andra saker som sker vid en viss tidpunkt blir alltid **händelse**. Något du ska göra blir händelse om det har klockslag, annars **att göra**, med förfallodag om en dag nämns ("lämna in senast fredag").
- **Veckodagar och relativa dagar** ("på torsdag", "i morgon", "nästa vecka på måndag") räknas fram mot källans tid och tidszon. "Torsdag" betyder nästa torsdag efter källtiden, eller samma dag om den är en torsdag och klockslaget inte har passerat.
- **Datum utan klockslag** blir heldag. `scheduledAt` i gatewayns resultat får också vara ett datum utan klockslag (`ÅÅÅÅ-MM-DD`); en äldre app läser det som saknat datum. Det ersatte den först planerade uppdelningen i `date` och `time`, som hade krävt en ny resultatversion. Appen sparar heldag som ett nytt valfritt fält, `isAllDay`, i förslaget och innehållsposten. Det är Codable-payload, så ingen ändring av SwiftData-schemat behövs ([beslut](DECISIONS.md#swiftdata-i-stället-för-hela-json-filer-2026-10-11)). Ingen påhittad standardtid.
- **Senare klockslag:** säger du "klockan 15" efteråt ersätter analysen det öppna förslaget (`replacesID` finns redan) så att heldagen blir 15:00 innan du svarat. Har du redan svarat Ja skapas ingen dubblett; tiden ändrar du själv.
- Granskningen spärrar inte Ja för heldag. Saknas även datum krävs ett val som i dag.

### A4. Eftersläpningen

- **Större utskick när kön är lång:** ligger mer än ett vardagsfönster i kö slås fönstren ihop till ett anrop, i källordning, så långt gatewayns gräns för indata räcker. Femminutersregeln och 60 s mellan anrop gäller fortfarande. De exakta gränserna sätts mot dagens tokenbudget i koden och skrivs in i DECISIONS.md.
- **Eftersläpning på Hem:** när den äldsta oanalyserade vardagstexten är mer än 10 min gammal visar Hem "AI ligger N min efter". Värdet räknas fram vid visning och lagras inte.

### A5. Namnen

Visningsnamnen enligt tabellen ovan, i 0.9.0. Filtret i Anteckningar blir Alla, Anteckningar, Att göra och Minnen; händelser ligger i Kalender-fliken tills den tas bort i 0.9.1.

### A6. Mät transkriptionen (användaren, på datorn)

- Kör `scripts/measure_wer.py` på FLEURS enligt [guiden](../transcription-server/README.md#mäta-ordfelfrekvens), med och utan förbehandling. Skriptet får aldrig användas på privata inspelningar, och Mio sparar aldrig råljud.
- Rumsprov: läs upp ett känt stycke text (till exempel 20 FLEURS-meningar) för Mio i ett klassrum eller liknande, på normalt avstånd. Jämför transkriptet i exporten med texten. Bara text sparas, som vanligt.
- Resultaten förs in i STATUS.md; `TESTRESULTAT_V0_1.md` rörs inte. Ändringar i Pianissimo eller förbehandlingen planeras först när siffrorna finns.

### Prov på telefonen för 0.9.0

1. En lektion på minst 30 min: anteckningarna blir klara, och eventuella obearbetade delar visas med originaltext.
2. Säg "Jag har prov i X på torsdag", vänta och säg "klockan 15". Förslaget visar Händelse, nästa torsdag, först heldag och sedan 15:00, med dina egna ord som text.
3. "Jag ska lämna in labbrapporten på fredag" blir Att göra med förfallodag fredag.
4. Hem visar eftersläpningen när AI ligger efter.

## Del B, 0.9.1: Apples appar äger posterna

Versionen höjs till 0.9.1 med den första commiten i del B. 0.9.0 är då den sista revisionen före den. En tagg kräver användarens godkännande.

### Var allt hamnar

| Typ | Destination | Väg | Behörighet |
|---|---|---|---|
| Händelse | Kalender | Ja öppnar Kalenders egen redigerare (`EKEventEditViewController`) med titel, start, slut eller heldag, anteckning och URL ifyllda; du väljer kalender och notis och trycker Lägg till | Ingen. Redigeraren körs utanför Mios process, som kalenderkopian i dag |
| Att göra | Påminnelser | Mios granskning (titel, dina ord, valfritt datum, valfri tid, lista) och sedan Ja, som skapar en `EKReminder` direkt | Full åtkomst till Påminnelser (`NSRemindersFullAccessUsageDescription`). Apple har ingen åtkomst som bara skriver påminnelser |
| Anteckning | Anteckningar | Ja öppnar dela-arket (`UIActivityViewController`) med texten; du väljer ny eller befintlig anteckning | Ingen. Anteckningar saknar API |
| Minne | Anteckningar | Som anteckning | Ingen |

Kalender och Påminnelser är skilda appar med skilda behörigheter. Mio ber aldrig om att få läsa kalendern; full åtkomst gäller bara Påminnelser.

### Detaljer per typ

- **Händelse:** standardlängd 1 h (Kalenders standard) när klockslag finns, annars heldag. Avbryter du redigeraren ligger förslaget kvar.
- **Att göra:** listväljaren börjar på senast valda lista, första gången på standardlistan. Utan datum sparas posten utan förfallodag. Med klockslag får den en notis vid tiden (`EKAlarm`); brådskande och tidig påminnelse ändrar du i Påminnelser.
- **Nekad åtkomst till Påminnelser:** förslaget ligger kvar under Förslag med texten "Mio har inte åtkomst till Påminnelser" och en knapp till Inställningar. Mio byter aldrig väg i tysthet.
- **Anteckning och minne:** texten är rubriken, dina ord och Mio-länken. När dela-arket avslutas som klart markeras förslaget som skickat med mottagande app. Mio vet inte vilken anteckning texten hamnade i.

### Innehåll och länk tillbaka

- Anteckningsfältet innehåller dina ord ur transkriptet (A2), aldrig AI:ns text.
- URL-fältet (för anteckningar och minnen en rad i texten) innehåller `mio://session/<UUID>`, som öppnar sessionen i Mio. Länken tolkas som notisrutterna: bara ett UUID, okända delar avvisas, och den startar aldrig mikrofon eller AI. Det kräver en ny URL-typ i `Info.plist`.

### Vad Mio sparar

- En **överlämning** per godkänt förslag: förslagets ID, typ, rubrik, destination (Kalender, Påminnelser eller den app dela-arket rapporterade), tid och sessions-ID, och för Påminnelser `calendarItemIdentifier`. Inga datum, ingen status och ingen kopia av texten. Apple äger posten.
- Genomfört: överlämningen är en innehållspost med det valfria fältet `handoff`, tom text och `scheduledAt` = sändningstiden. Godkännandet, raderingen och exporten (schema 2, additivt fält) återanvänds, och SwiftData-schemat ändras inte. Det ersatte idén om en egen tabell och export 3.
- Kalenders redigerare används utan behörighet och lämnar inget ID som Mio sparar.

### Vad som försvinner

- **Kalender-fliken.** Flikarna blir Hem, Lektioner, Förslag och Fånga.
- **Plusknappen** för att skapa poster själv i Mio. Skriv direkt i Apples appar.
- **Mios lokala poster.** Vid uppgraderingen raderas alla befintliga anteckningar, uppgifter, planer och minnen (användarens val). Exportera före uppgraderingen om något ska sparas. Genomfört som en engångsåtgärd vid start: poster utan `handoff` raderas via det vanliga innehållslagret. Ingen schemaändring behövs, eftersom det är rader som tas bort och inte struktur.
- **Mios alarm och postnotiser:** AlarmKit-alarm (även fristående alarm med veckodagar), `mio.reminder.<UUID>` och knappen "Lägg en kopia i Kalender". Kvarvarande alarm och notiser tas bort vid uppgraderingen. `NSAlarmKitUsageDescription` och AlarmKit-koden för rensningen behålls i 0.9.1 så att gamla alarm säkert kan avbrytas; de tas bort i en senare version.
- **Kvar:** morgon- och kvällsnotisen och "Tryck för att fortsätta lyssna", under inställningsdelen **Notiser**.

### Förslag-fliken

Anteckningar-fliken byter namn till **Förslag**. Överst ligger förslag att granska (Ja, Nej, Inte nu). Under dem finns **Skickat**: överlämningarna med typ, rubrik, destination, tid och länk till sessionen.

### Hem

- Veckoraden, Nästa och morgon- och kvällsvyn läser kommande påminnelser som inte är klara, via full åtkomst till Påminnelser, plus sessioner, lektioner och antal förslag att granska.
- Händelser i Kalender visas inte, eftersom Mio inte läser kalendern.
- Tolvveckorsrutnätet räknar sessioner och överlämningar, bara antal.
- Utan åtkomst till Påminnelser visar Hem bara Mios egna delar.

### AI

- Kandidattyperna är `plan` (händelse), `task` (att göra) och `note` (anteckning). Minnen skapas fortfarande bara av den lokala regeln "kom ihåg".
- Regeln från A3 och datum utan klockslag gäller oförändrat. Inga autonoma åtgärder: varje överlämning kräver Ja, och för händelser och anteckningar även Apples egen ruta.

### Dokumentation

DATAMODELL.md (överlämningar, export 3, borttaget innehållslager), ANVANDNING.md, DECISIONS.md, ROADMAP.md, TESTPLAN_HELHET.md, CHANGELOG.md och DESIGN.md (flikarna).

### Prov på telefonen för 0.9.1

1. Behörighetsfrågan för Påminnelser visas en gång, med Mios svenska förklaring. Neka först och kontrollera texten och knappen, godkänn sedan.
2. En att göra-post med tid hamnar i vald lista med notis och länk; nästa gång föreslås samma lista.
3. En händelse öppnar Kalenders redigerare ifylld; efter Lägg till syns den i Kalender. Heldag fungerar.
4. Anteckning och minne via dela-arket till Anteckningar.
5. `mio://`-länken från Påminnelser och Kalender öppnar rätt session.
6. Uppgraderingen tar bort gamla poster, alarm och postnotiser och lämnar morgon- och kvällsnotisen kvar.
7. Hem visar kommande påminnelser; en avbockad försvinner.

## Ej verifierat

Allt i del B som rör telefonen: om redigeraren lämnar tillbaka ett händelse-ID utan behörighet, hur dela-arket rapporterar Anteckningar, notisen vid `EKAlarm`, Mio-länken från Apples appar och läsningen av påminnelser med många listor. Modellens följsamhet till den nya klassningen och datumregeln kräver riktiga anrop.

## Källor

- [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store): full åtkomst för påminnelser, åtkomst som bara skriver finns bara för händelser.
- [TN3152: Migrating to the latest calendar access levels](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels): `NSRemindersFullAccessUsageDescription`.
- [Discover Calendar and EventKit, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10052/): EventKitUI-redigeraren utan behörighet.
- [EKEventEditViewController](https://developer.apple.com/documentation/eventkitui/ekeventeditviewcontroller), [EKReminder](https://developer.apple.com/documentation/eventkit/ekreminder), [EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm), [UIActivityViewController](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller).
- Apple publicerar inget API för Anteckningar; dela-arket och Genvägar är de enda vägarna. Genvägar valdes bort.
