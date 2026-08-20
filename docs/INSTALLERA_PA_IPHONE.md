# Installera Mio på hennes iPhone — exakt steg för steg

> **Macen kör Monterey?** Följ inte Xcode-stegen nedan. Xcode 26 kräver minst macOS Sequoia 15.6. Använd i stället [START_HAR_MONTEREY.md](../START_HAR_MONTEREY.md), som bygger på GitHub och installerar från Windows med AltStore.

Den här guiden förutsätter att ni är nybörjare. Gör punkterna i ordning. Ni behöver inte skapa en app i App Store och ni ska inte skriva in någon OpenAI-nyckel.

## Det ni behöver

- En **Mac**. En egen iPhone-app kan inte byggas och signeras från Windows.
- Hennes **iPhone 13 med iOS 26 eller senare**.
- En USB-kabel som klarar data, inte bara laddning.
- Ett vanligt Apple-konto. Gratis **Personal Team** räcker.
- Projektmappen `MioPhaseOne` eller ZIP-filen `MioPhaseOne.zip`.

Apple-kontot som ni lägger till i Xcode behöver inte vara samma Apple-konto som hon använder för iCloud på telefonen.

## Del 1 — kontrollera iOS

På hennes iPhone:

1. Öppna **Inställningar**.
2. Välj **Allmänt > Om**.
3. Läs raden **iOS-version**.
4. Om den är lägre än 26: gå tillbaka till **Allmänt > Programuppdatering** och uppdatera först.

Projektet kan inte byggas för äldre iOS eftersom Apples nya lokala SpeechAnalyzer finns från iOS 26.

## Del 2 — installera rätt Xcode på Macen

1. På Macen, öppna ** > Om den här datorn** och notera macOS-versionen.
2. Det enklaste är att uppdatera Macen till senaste macOS-versionen som den stöder.
3. Installera Xcode från **Mac App Store**.
4. Om App Store säger att Xcode inte stöds, använd Apples [aktuella tabell över Xcode-krav](https://developer.apple.com/xcode/system-requirements):

   - macOS Tahoe 26.2 eller senare: använd Xcode 26.6 eller senare kompatibel version.
   - macOS Sequoia 15.6: använd högst Xcode 26.3.
   - äldre macOS än 15.6: uppdatera macOS först.

5. Starta Xcode.
6. Godkänn licensen om den visas.
7. Låt Xcode installera sina extra komponenter. Det kan ta en stund.
8. Om Xcode saknar iOS-stöd: öppna **Xcode > Settings > Components** och installera iOS Platform Support. Apple beskriver detta i [komponentguiden](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).

## Del 3 — flytta projektet till Macen

Om ni har fått `MioPhaseOne.zip`:

1. Flytta ZIP-filen till Macen via exempelvis USB-minne, AirDrop, iCloud Drive eller Google Drive.
2. Dubbelklicka på ZIP-filen i Finder.
3. En mapp som heter `MioPhaseOne` skapas.
4. Lägg gärna mappen i **Dokument** så att den inte raderas av misstag.

Öppna sedan mappen och dubbelklicka på:

> `MioPhaseOne.xcodeproj`

Xcode ska öppna ett projekt med en blå projektikon och mapparna `MioPhaseOne` och `MioPhaseOneTests` i vänsterspalten.

## Del 4 — lägg till ett gratis Apple-konto i Xcode

1. I Xcode, öppna **Xcode > Settings**.
2. Välj fliken **Apple Accounts**.
3. Klicka på `+`.
4. Logga in med ett vanligt Apple-konto.
5. Godkänn Apple Developer Agreement om Apple frågar.
6. Kontrollera att kontot visas med texten **Personal Team**.

Ni behöver inte betala 99 USD per år för fas 1.

## Del 5 — ställ in signering

1. Stäng Settings-fönstret så att projektet syns igen.
2. Klicka på den **blå projektikonen `MioPhaseOne`** högst upp i Xcodes vänsterspalt.
3. I mittenkolumnen under **TARGETS**, klicka på **MioPhaseOne**. Välj inte test-targeten.
4. Öppna fliken **Signing & Capabilities**.
5. Markera **Automatically manage signing**.
6. Vid **Team**, välj ert namn med texten **Personal Team**.
7. Vid **Bundle Identifier** står från början `se.eyvin.MioPhaseOne`.
8. Om Xcode visar ett rött fel om att identifieraren inte är tillgänglig, ändra den till något unikt, exempelvis:

   > `se.ertfornamn.mio.phase1`

   Använd bara bokstäver, siffror, punkter och bindestreck — inga å, ä, ö eller mellanslag.

9. Vänta tills den röda signeringsraden försvinner. Xcode skapar testcertifikat och profil automatiskt.
10. Under capabilities ska **Background Modes** vara aktiverat. Projektets `Info.plist` innehåller redan läget `audio`; ändra inte det.

Apples bakgrundsläge gör fortsatt, användarstartad ljudinspelning möjlig när appen går i bakgrunden. Det garanterar inte återstart efter att användaren tvångsstängt appen. Se [Apples bakgrundsguide](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes).

## Del 6 — parkoppla hennes iPhone med kabel

För en telefon med iOS 26 ska första parkopplingen göras med kabel.

1. Anslut hennes iPhone till Macen med datakabeln.
2. Lås upp telefonen.
3. Om telefonen frågar **Lita på den här datorn?**, tryck **Lita på** och skriv telefonens kod.
4. I Xcode, öppna **Xcode > Open Developer Tool > Device Hub**.
5. Om er Xcode-version i stället visar **Window > Devices and Simulators**, öppna det; Apple har ändrat namnet mellan versioner.
6. Klicka på hennes iPhone i listan.
7. Klicka **Pair** eller **Register** om knappen visas.
8. Vänta tills Xcode har förberett enheten. Koppla inte ur kabeln under förberedelsen.

Se [Apples Device Hub-guide](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub).

## Del 7 — slå på Utvecklarläge på telefonen

Alternativet kan bli synligt först efter kabelparkopplingen.

1. På iPhone, öppna **Inställningar > Integritet och säkerhet**.
2. Scrolla längst ner till **Utvecklarläge**.
3. Slå på Utvecklarläge.
4. Tryck **Starta om**.
5. Efter omstart: lås upp telefonen.
6. Bekräfta **Aktivera** och ange telefonens kod.

Om Utvecklarläge inte syns: anslut kabeln igen, lås upp telefonen och välj den i Device Hub. Apples guide finns [här](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Del 8 — bygg och installera Mio

1. Gå tillbaka till projektfönstret i Xcode.
2. Högst upp, bredvid projektnamnet, finns en meny för körmål. Klicka på den.
3. Välj hennes **fysiska iPhone**. Välj inte en iPhone Simulator.
4. Kontrollera att schemat till vänster om telefonen heter **MioPhaseOne**.
5. Klicka på ▶ uppe till vänster, eller välj **Product > Run**, eller tryck `⌘R`.
6. Första bygget kan ta några minuter.
7. Xcode ska därefter installera appen **Mio Fas 1** på hemskärmen och öppna den.

### Om telefonen inte litar på utvecklaren

Formuleringen varierar mellan iOS-versioner:

1. Öppna **Inställningar > Allmänt > VPN och enhetshantering** på iPhone.
2. Tryck på utvecklarcertifikatet med Apple-kontots namn.
3. Välj **Lita på**, eller **Tillåt och starta om** om det är knappen som visas.
4. Följ telefonens instruktioner.
5. Kör sedan appen igen från Xcode med ▶.

## Del 9 — första starten i Mio

1. I appen, vänta tills kortet **Telefonens stöd** är färdigt.
2. Tryck **Starta fas 1-test**.
3. iPhone frågar om **Mikrofon**. Tryck **Tillåt**.
4. Appen ska inte be om separat taligenkänningsbehörighet; SpeechAnalyzer arbetar lokalt och behöver bara mikrofonbehörigheten.
5. Om den svenska modellen inte redan finns kan iOS hämta den. Ha wifi, låt appen vara öppen och vänta.
6. När rubriken blir **Mio lyssnar**, säg några svenska meningar och ordet Mio.

Den orange mikrofonindikatorn i iOS visar när mikrofonen används.

## Del 10 — kör testerna i Xcode (frivilligt men rekommenderat)

De automatiska testerna kräver ingen riktig mikrofon.

1. Välj en iPhone-simulator i körmålsmenyn.
2. Välj **Product > Test**, eller tryck `⌘U`.
3. Xcodes testpanel ska visa gröna markeringar för `MioWakeWordDetectorTests` och `PhaseOneModelsTests`.
4. Välj därefter hennes riktiga telefon igen för det verkliga ljudtestet.

## Vanliga fel

### “Signing for MioPhaseOne requires a development team”

Gå tillbaka till **Signing & Capabilities** och välj ert **Personal Team**.

### “Bundle identifier is not available”

Byt Bundle Identifier till en mer unik variant, exempelvis `se.ertfornamn.mio.phase1.2026`.

### Telefonen syns inte som körmål

- Använd en datakabel.
- Lås upp telefonen.
- Tryck Lita på telefonen.
- Öppna Device Hub och vänta tills förberedelsen är klar.
- Kontrollera att Xcode-versionen stöder telefonens iOS-version.

### “Developer Mode disabled”

Gör Del 7 och starta om telefonen.

### Mikrofonen nekades av misstag

På telefonen: öppna **Inställningar**, scrolla till **Mio Fas 1** och slå på **Mikrofon**. Det går också via **Integritet och säkerhet > Mikrofon**.

### Ingen svensk motor hittas

Detta är ett giltigt fas 1-resultat, inte ett handhavandefel. Ta en skärmbild av kortet **Telefonens stöd**. Appen testar både SpeechTranscriber och DictationTranscriber. Vi använder resultatet för nästa tekniska beslut.

### Texten stannar efter AirPods eller kabelbyte

Ljudformatet kan ändras när ljudvägen byts. Stoppa Mio och starta ett nytt test. Händelsen finns i loggen.

### Xcode visar röda kompileringsfel

Öppna Issue Navigator med varningstriangeln i vänsterspalten. Kopiera den **första röda felraden** eller ta en tydlig skärmbild. Senare fel är ofta följdfel. Skicka den första raden till Codex tillsammans med Xcode-versionen.

## Begränsningen med ett gratis Personal Team

Apple anger för kostnadsfri testning bland annat högst 10 App-ID:n, 3 testenheter per plattform och 3 utvecklingsappar per enhet. Testprofilen går ut efter ungefär **7 dagar**.

När appen slutar öppnas efter en vecka:

1. Anslut telefonen till Macen.
2. Öppna projektet i Xcode.
3. Välj telefonen.
4. Klicka ▶ igen.

Det bygger och installerar en ny sjudagarsversion. Läs Apples [kontoöversikt](https://developer.apple.com/help/account/basics/about-your-developer-account) och [medlemsjämförelse](https://developer.apple.com/support/compare-memberships/).

Ett betalt Apple Developer Program blir relevant först för exempelvis TestFlight och enklare långvarig distribution. Det behövs inte för fas 1.
