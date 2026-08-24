# Testplan för Mio fas 2

Målet är att verifiera den lokala, manuella MVP:n på den faktiska iPhone 13 utan att blanda ihop källkod, molnbygge och telefonresultat. Använd endast konstgjort testinnehåll. Exporter kan innehålla privat text och får aldrig läggas i Git-repot.

## Statusord

Använd endast följande resultat per test:

- **Ej körd:** inga aktuella bevis finns.
- **Godkänd:** det förväntade resultatet observerades på den angivna builden och enheten.
- **Underkänd:** det observerade resultatet avvek.
- **Blockerad:** testet kunde inte genomföras; dokumentera den konkreta orsaken.

“Implementerat i källkod” och “GitHub Actions grön” är inte telefonresultat.

## Före testet

1. Notera Git-commit, GitHub Actions-körning, IPA-filens kontrollsumma, exakt iOS-version och iPhone-modell.
2. Kräv en grön Release-build för denna revision. Kör även XCTest i Xcode eller ett Actions-testjobb och dokumentera om testkörning saknas.
3. Exportera viktig befintlig fas 1-data innan uppdateringen.
4. Installera över den befintliga appen med samma Apple-konto och bundle identifier. Radera inte appen inför migreringstestet.
5. Använd endast syntetiska poster och röster från personer som uttryckligen samtycker.
6. Ha wifi för testet av Apples avancerade modell. Övriga manuella tester ska även köras offline.

## Test A — uppgradering och första start

1. Öppna den tidigare versionen och notera minst en sparad session om sådan testdata finns.
2. Installera fas 2-builden över appen.
3. Starta Mio.
4. Kontrollera att appen inte kraschar och att befintliga sessioner fortfarande går att läsa.
5. Kontrollera att äldre sessioner utan fas 2-metadata visas utan påhittad titel, anteckning eller rättning.
6. Kontrollera att det nya manuella innehållslagret börjar tomt om inga fas 2-poster skapats tidigare.

Godkänt: gammal sessionsdata finns kvar oförändrad och den nya datamodellen startar utan fel.

## Test B — fem flikar

1. Öppna flikarna **Mio**, **Tidslinje**, **Kalender**, **Anteckningar** och **Morgon** i tur och ordning.
2. Kontrollera att vald flik markeras och att innehållet motsvarar rubriken.
3. Kontrollera att Kalender endast visar lokala planer och att Morgon inte påstår sig skapa systemalarm.
4. Växla flikar under en pågående och en stoppad session.

Godkänt: alla flikar är nåbara utan krasch eller förlorat lokalt innehåll och senare funktioner framställs inte som aktiva.

## Test C — skapa de fem manuella typerna

Skapa följande syntetiska exempel med olika tider:

| Typ | Rubrik | Exempeltext |
|---|---|---|
| Tidslinjepost | Matematiklektion | Vi gick igenom procent. |
| Anteckning | Fråga till läraren | Be om ett extra exempel. |
| Uppgift | Räkna uppgift 12 | Markera den senare som klar. |
| Plan | Tandläkare | Tisdag klockan 15, endast lokalt. |
| Uttryckligt minne | Favoritpenna | Jag föredrar en blå penna. |

Försök även spara en post med tom rubrik.

Godkänt: alla fem giltiga poster sparas med rätt typ och den tomma rubriken avvisas begripligt.

## Test D — redigering, uppgiftsstatus och tidsordning

1. Ändra rubrik, brödtext och vald tid på minst två poster.
2. Markera uppgiften som klar och sedan som inte klar.
3. Ge två poster samma valda tid.
4. Öppna Tidslinje och kontrollera att ordningen är stabil.
5. Stäng appen helt, öppna den igen och kontrollera samma data och ordning.

Godkänt: skapandetiden behålls, uppdateringstiden ändras, endast uppgifter får klarstatus och resultatet överlever omstart.

## Test E — sessionskoppling och redigerbart lager

1. Starta en ny session och säg en kort syntetisk svensk mening.
2. Stoppa sessionen.
3. Lägg till en titel och en manuell anteckning på sessionen.
4. Rätta ett transkriptionssegment till en annan, icke-tom text.
5. Koppla en manuell post till sessionen.
6. Sök efter den rättade texten och kontrollera att posten visar rätt sessionskoppling.
7. Försök redigera en aktiv session; appen ska kräva att den stoppas först.

Godkänt: metadata och rättning visas och sparas, kopplingen fungerar och en aktiv session kan inte redigeras.

## Test F — originalbevis efter rättning

1. Skapa en gemensam lokal export efter test E.
2. Granska sessionens rättade segment i JSON-filen.
3. Kontrollera att både originalfältet `text` och `correctedText` finns.
4. Kontrollera att `audioStartedAt`, `audioEndedAt`, Mio-markering, bakgrundsmarkering och giltighet för ljudtid inte ändrats av rättningen.

Godkänt: rättningen är ett separat lager och ursprungsbeviset är intakt.

## Test G — svensk sökning

1. Sök efter en rubrik med annan kombination av gemener och versaler.
2. Sök `ovning` efter innehåll som innehåller “Övning”.
3. Sök `FRAGA` efter innehåll som innehåller “Fråga”.
4. Sök efter sessionsrubrik, sessionsanteckning och rättad transkription.
5. Sök efter ett ord som inte finns och töm därefter sökfältet.

Godkänt: sökningen är skiftläges- och diakritikokänslig, visar rätt typer och har begripliga tomlägen.

## Test H — gemensam export

1. Tryck **Skapa lokal export** och därefter **Dela lokal export**.
2. Spara filen privat utanför repot.
3. Kontrollera att filnamnet börjar med `Mio-lokal-export-`.
4. Kontrollera att JSON kan läsas och innehåller `schemaVersion`, `exportedAt`, `content` och `sessions`.
5. Kontrollera att alla fem typer, sessionskopplingen och uppgiftsstatusen finns.
6. Sök i filen efter fältnamn som `rawAudio`, `audioData`, API-nyckel eller autentiseringsuppgift.

Godkänt: exporten är giltig och versionsmärkt, innehåller avsedda textdata men inget råljud eller hemligheter.

## Test I — enskild och fullständig radering

Använd endast testdata och behåll exporten från test H privat.

1. Radera en manuell post och starta om appen.
2. Kontrollera att posten fortfarande är borta.
3. Radera en avslutad session som har en kopplad manuell post.
4. Kontrollera att posten finns kvar men inte längre har en sessionskoppling.
5. Tryck **Radera all lokal data** och läs bekräftelsen innan du fortsätter.
6. Starta om appen och skapa en ny export.

Godkänt: enskild radering består, sessionsrelationen lossas utan att posten försvinner och total radering tömmer både manuellt innehåll och sessioner. Redan delade filer försvinner inte automatiskt.

## Test J — offline och avsaknad av integrationer

1. Säkerställ först att eventuell svensk reservmodell redan finns på telefonen.
2. Slå på flygplansläge.
3. Skapa, redigera, sök och radera en manuell post.
4. Öppna Kalender och Morgon.
5. Kontrollera att ingen OpenAI-inloggning, EventKit-behörighet eller alarmbehörighet efterfrågas.

Godkänt: de manuella funktionerna fungerar lokalt och inga externa integrationer aktiveras.

## Test K — avancerad svensk modell och fallback

1. Stäng av flygplansläge, anslut wifi och håll appen öppen.
2. Stoppa eventuell aktiv session.
3. Läs statusen för den avancerade modellen i **Telefonens stöd**.
4. Om svenska stöds men inte är installerad, tryck **Försök installera avancerad modell**.
5. Dokumentera varje visad status: stödd, hämtas, installerad eller inte stödd/fel.
6. Tryck **Kontrollera igen**.
7. Starta en ny session först efter kontrollen och notera vald motor.
8. Om installationen inte blir klar, kontrollera att `DictationTranscriber` med `sv_SE` fortfarande kan väljas och skapa svensk text.

Godkänt: appen använder inte `SpeechTranscriber` före bekräftad installerad status, visar ett begripligt installationsresultat och behåller fungerande fallback. Att iOS vägrar installera asseten ska dokumenteras som enhetsresultat, inte döljas.

## Test L — mikrofon och fas 1-regression

1. När Mio är av, kontrollera att iOS orange mikrofonindikator inte visas.
2. Tryck **Starta ny session**, tillåt mikrofonen och säg testtexten från fas 1.
3. Kontrollera lokal svensk text och Mio-detektion.
4. Pausa **Tills jag startar igen** och kontrollera att indikatorn försvinner och att ingen ny text skapas.
5. Fortsätt, skapa ny text och tryck **Stoppa sessionen**.
6. Kontrollera åter att indikatorn försvinner.

Godkänt: den nya navigeringen har inte brutit den korta kärnvägen och mikrofonstatusen följer användarens val.

Detta ersätter inte de längre bakgrunds-, batteri-, avbrotts- och kvalitetsproven i [TESTPLAN_FAS_1.md](TESTPLAN_FAS_1.md).

## Test M — tillgänglighet och små skärmar

1. Prova minst en stor Dynamic Type-storlek.
2. Navigera bland flikar, knappar, poster och destruktiva dialoger med VoiceOver.
3. Kontrollera att status inte förmedlas enbart med färg.
4. Kontrollera att tangentbordet inte blockerar spara- eller avbrytknappar.

Godkänt: huvudflödena går att förstå och använda på iPhone 13 utan avklippta avgörande kontroller.

## Fas 2 är verifierad när

- Release-builden för den dokumenterade revisionen är grön i GitHub Actions;
- relevanta XCTest faktiskt har körts och resultaten är dokumenterade;
- samma IPA är installerad och test A–M är genomförda eller har en uttryckligen accepterad avvikelse;
- inga exporter eller andra privata testdata har lagts i repot;
- resultatet finns i [TESTRESULTAT_FAS_2.md](TESTRESULTAT_FAS_2.md).

Fas 2-verifiering innebär inte automatiskt att fas 1:s heldagsidé är godkänd.
