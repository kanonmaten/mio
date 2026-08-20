# Från ZIP till Mio på iPhone — Monterey + molnbygge + AltStore

Det här är guiden för er situation:

- utvecklings-Macen är låst till macOS Monterey;
- hennes iPhone 13 kör iOS 26;
- GitHub bygger appen på en tillfällig Mac med Xcode 26;
- Windows och AltStore Classic signerar och installerar appen på telefonen;
- appen ska inte publiceras i App Store.

Följ delarna i ordning. Ni ska **inte** lägga in Apple-lösenord, OpenAI-nycklar eller privata inspelningar på GitHub.

## Det ni behöver

- ZIP-filen `MioPhaseOne.zip` från Codex.
- En Windows 10- eller Windows 11-dator där ni får installera program.
- Hennes iPhone 13 med iOS 26.
- En USB-kabel som klarar data.
- Ett kostnadsfritt GitHub-konto.
- Ett Apple-konto för kostnadsfri signering.

Apple-kontot för AltStore behöver inte vara samma konto som telefonens iCloud-konto. Ett separat Apple-konto enbart för Mio minskar konsekvenserna om ni någon gång vill sluta använda AltStore. Använd samma valda konto varje gång ni förnyar Mio.

## Så fungerar kedjan

```text
MioPhaseOne.zip
       │
       ▼
Privat GitHub-repository
       │ GitHub Actions kör Xcode 26
       ▼
MioPhaseOne-unsigned.ipa
       │ AltStore signerar med ert Apple-konto
       ▼
Hennes iPhone 13
```

GitHub får bara projektets källkod. AltStore får IPA-filen och använder Apple-kontot för signering. Fas 1 skickar inga transkriptioner eller mikrofondata till GitHub, AltStore eller OpenAI.

---

## Del 1 — packa upp rätt ZIP på Windows

1. Hämta `MioPhaseOne.zip` till Windows-datorn.
2. Högerklicka på ZIP-filen.
3. Välj **Extrahera alla**.
4. Klicka **Extrahera**.
5. Öppna den skapade mappen `MioPhaseOne`.
6. Kontrollera att den innehåller åtminstone:

   ```text
   .github
   MioPhaseOne
   MioPhaseOneTests
   MioPhaseOne.xcodeproj
   docs
   README.md
   START_HAR_MONTEREY.md
   ```

7. Öppna `.github`, sedan `workflows`, och kontrollera att filen `build-unsigned-ipa.yml` finns.

Om du bara ser ännu en mapp som heter `MioPhaseOne`, öppna den. Det är **innehållet** ovan som senare ska laddas upp till GitHub, inte en extra yttersta mapp.

## Del 2 — skapa ett privat GitHub-projekt

1. Öppna [github.com](https://github.com) i Edge eller Chrome.
2. Logga in eller skapa ett kostnadsfritt konto.
3. Klicka på `+` högst upp till höger.
4. Välj **New repository**.
5. Skriv repository-namnet:

   > `mio-phase-one`

6. Välj **Private**.
7. Markera inte **Add a README file**.
8. Välj ingen `.gitignore` och ingen licens.
9. Klicka **Create repository**.

Projektet ska vara privat eftersom detta är er privata prototyp. Det innehåller ännu ingen personlig dagsdata, men det finns ingen anledning att publicera källkoden.

## Del 3 — ladda upp projektet på rätt nivå

På den tomma repository-sidan:

1. Klicka länken **uploading an existing file**.
2. Gå till Utforskaren i Windows.
3. Öppna den uppackade mappen som direkt innehåller `.github`, `MioPhaseOne.xcodeproj` och `README.md`.
4. Tryck `Ctrl+A` så att **allt innehåll** markeras.
5. Dra de markerade filerna och mapparna till GitHubs uppladdningsruta.
6. Vänta tills GitHub har räknat färdigt alla filer.
7. Kontrollera särskilt att följande sökväg syns i listan:

   > `.github/workflows/build-unsigned-ipa.yml`

8. Skriv exempelvis `Första Mio-bygget` i rutan för commit-meddelande.
9. Klicka **Commit changes**.

### Viktig kontroll

När uppladdningen är klar ska repositoryts första nivå visa ungefär:

```text
.github/
MioPhaseOne/
MioPhaseOneTests/
MioPhaseOne.xcodeproj/
docs/
README.md
```

Om allt i stället ligger under en enda extra mapp som heter `MioPhaseOne/`, ligger arbetsflödet för djupt och GitHub hittar det inte. Börja då om i ett nytt tomt repository och ladda upp **innehållet** i mappen.

## Del 4 — starta molnbygget

1. Klicka fliken **Actions** högst upp på GitHub-sidan.
2. Om GitHub visar en knapp som heter exempelvis **I understand my workflows, go ahead and enable them**, klicka den.
3. I vänsterspalten, klicka **Bygg Mio IPA**.
4. Klicka **Run workflow** till höger.
5. Låt grenen vara `main`.
6. Klicka den gröna knappen **Run workflow**.
7. Sidan visar snart en ny körning med en gul cirkel.
8. Klicka på körningen för att följa den.
9. Vänta tills cirkeln blir en grön bock. Första gången tar normalt några minuter.

Arbetsflödet gör följande utan Apple-lösenord:

- startar en tillfällig GitHub-Mac;
- väljer Xcode 26.6;
- validerar projektets plist- och integritetsfiler;
- kompilerar en riktig arm64-iPhone-app;
- kontrollerar IPA-filen;
- laddar upp resultatet som en GitHub-artifact.

### Om bygget blir rött

1. Klicka den röda körningen.
2. Klicka jobbet **Kompilera med Xcode 26**.
3. Öppna det första steget med ett rött kryss.
4. Kopiera den första tydliga felraden och stegets namn.
5. Skicka dem till Codex. Försök inte rätta alla följdfel samtidigt.

## Del 5 — hämta IPA-filen

När GitHub-körningen är grön:

1. Öppna körningens sammanfattningssida.
2. Scrolla längst ner till **Artifacts**.
3. Klicka **MioPhaseOne-IPA**.
4. Windows hämtar filen `MioPhaseOne-IPA.zip`.
5. Högerklicka på den hämtade ZIP-filen och välj **Extrahera alla**.
6. I den uppackade mappen ska det finnas:

   ```text
   MioPhaseOne-unsigned.ipa
   MioPhaseOne-buildinfo.txt
   ```

7. Öppna gärna `MioPhaseOne-buildinfo.txt` och kontrollera att den nämner Xcode 26 och ett SHA-256-värde.
8. Packa **inte** upp `.ipa`-filen. AltStore ska få filen precis som den är.

Ordet `unsigned` är korrekt. GitHub kompilerar appen, medan AltStore skapar den kostnadsfria personliga signaturen vid installationen.

---

## Del 6 — installera Apples Windows-komponenter

AltStore rekommenderar Apples direktnedladdade versioner av iTunes och iCloud, inte Microsoft Store-versionerna.

1. Öppna **Inställningar > Appar > Installerade appar** i Windows.
2. Om iTunes eller iCloud är installerade från Microsoft Store, avinstallera just de Store-versionerna först.
3. Följ AltStores officiella [Windows-guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).
4. Hämta och installera iTunes från länken som AltStore anger för Windows 64-bitars.
5. Hämta och installera iCloud från länken som AltStore anger.
6. Starta om Windows om installationsprogrammen ber om det.
7. Starta iTunes en gång och godkänn eventuella licensrutor.
8. Starta iCloud en gång. Ni behöver inte aktivera synkronisering av privata bilder eller dokument för Mios skull.

Om ni redan använder Apples nyare Windows-appar och inte vill avinstallera dem, stanna här och fråga Codex. AltStores officiella huvudväg använder fortfarande de komponenter som beskrivs i deras guide.

## Del 7 — installera AltServer på Windows

1. Gå till [altstore.io](https://altstore.io/).
2. Under **AltStore Classic**, hämta **AltServer Windows**.
   Välj inte AltStore PAL; PAL är EU-marknadsplatsen och kan inte importera vår fristående IPA. Den här guiden använder AltStore Classic.
3. Packa upp `AltInstaller.zip`.
4. Kör `Setup.exe`.
5. Slutför installationen.
6. Öppna Start-menyn och sök efter **AltServer**.
7. Högerklicka AltServer och välj **Kör som administratör**.
8. Om Windows-brandväggen frågar, tillåt AltServer på **Privata nätverk**. Offentliga nätverk behövs inte.
9. AltServer syns som en liten romb i aktivitetsfältets meddelandefält. Klicka uppåtpilen vid klockan om ikonen är dold.

## Del 8 — anslut och godkänn telefonen

1. Anslut hennes iPhone 13 till Windows-datorn med datakabeln.
2. Lås upp telefonen.
3. Om telefonen frågar **Lita på den här datorn?**, tryck **Lita på**.
4. Skriv telefonens kod.
5. Öppna iTunes.
6. Kontrollera att en liten telefonikon visas i iTunes.
7. Klicka telefonikonen.
8. Markera gärna **Synkronisera med denna iPhone via Wi‑Fi** och klicka **Använd**. Det hjälper senare för automatisk förnyelse men är inte ett krav när kabeln sitter i.
9. Låt telefonen vara upplåst under nästa del.

## Del 9 — installera AltStore på iPhone

1. Kontrollera att AltServer fortfarande körs som administratör.
2. Klicka AltServer-ikonen vid Windows-klockan.
3. Välj **Install AltStore**.
4. Välj hennes iPhone.
5. Skriv Apple-kontot som ni har valt för signering.
6. Skriv lösenordet när AltServer frågar.
7. Godkänn tvåfaktorskoden om Apple visar en sådan på en betrodd enhet.
8. Vänta på AltServers meddelande att installationen lyckades.
9. Kontrollera att appen **AltStore** har dykt upp på telefonens hemskärm eller i Appbiblioteket.

AltStore uppger att Apple-ID och lösenord skickas till Apple för autentisering, inte till GitHub eller Mio. AltStore är ändå en tredjepartslösning. Använd ett separat Apple-konto om ni inte vill använda hennes vanliga iCloud-konto.

## Del 10 — slå på Utvecklarläge på iPhone

På hennes iPhone:

1. Öppna **Inställningar**.
2. Välj **Integritet och säkerhet**.
3. Scrolla längst ner.
4. Tryck **Utvecklarläge**.
5. Slå på reglaget.
6. Tryck **Starta om**.
7. Efter omstart: lås upp telefonen.
8. Bekräfta **Aktivera**.
9. Skriv telefonens kod.

Om Utvecklarläge inte syns, anslut telefonen igen, lås upp den och försök installera AltStore en gång till. Alternativet brukar bli synligt efter att telefonen har fått en utvecklarapp.

## Del 11 — lita på utvecklarcertifikatet

Formuleringen kan skilja sig något mellan iOS 26-versioner:

1. Öppna **Inställningar > Allmänt**.
2. Välj **VPN och enhetshantering**.
3. Under **Utvecklarapp**, tryck på Apple-kontot ni använde i AltServer.
4. Tryck **Lita på “[Apple-kontot]”**.
5. Bekräfta **Lita på**.
6. Om iOS visar **Verifiera app**, tryck den medan telefonen har internetanslutning.
7. Öppna AltStore.

Om menyn **VPN och enhetshantering** saknas har ingen utvecklarapp installerats färdigt. Gå tillbaka till Del 9.

## Del 12 — ställ in AltStore för förnyelse

1. Öppna AltStore på iPhone.
2. Om AltStore ber om Apple-kontot, logga in med **samma konto** som användes i AltServer.
3. Tillåt **Lokalt nätverk** om iOS frågar. Detta används för att hitta AltServer på er egen wifi.
4. Öppna **Inställningar > Allmänt > Bakgrundsuppdatering** på iPhone.
5. Tryck **Bakgrundsuppdatering** högst upp och välj **Wi‑Fi** eller **Wi‑Fi och mobildata**.
6. Kontrollera att reglaget för **AltStore** är på.
7. Öppna **Inställningar > Batteri** och stäng av **Strömsparläge** under installation och fas 1-test.
8. Se till att iPhone och Windows-datorn är på samma privata wifi.
9. Låt AltServer vara igång i Windows när AltStore ska installera eller förnya appar.

Automatisk förnyelse är “best effort”. Öppna därför AltStore manuellt ett par gånger i veckan och kontrollera hur många dagar som återstår.

---

## Del 13 — flytta IPA-filen till iPhone

Välj ett sätt som ni redan litar på, exempelvis OneDrive, iCloud Drive eller en egen e-postbilaga.

Exempel med OneDrive:

1. På Windows, lägg `MioPhaseOne-unsigned.ipa` i en OneDrive-mapp.
2. Vänta tills filen visar att den har synkroniserats.
3. På iPhone, öppna appen **Filer**.
4. Tryck **Bläddra**.
5. Öppna OneDrive-platsen.
6. Kontrollera att `MioPhaseOne-unsigned.ipa` syns.
7. Tryck länge på filen och välj **Hämta nu** om en molnsymbol visas.

IPA-filen innehåller appkod men inga privata transkriptioner eller inspelningar.

## Del 14 — installera Mio med AltStore

1. Kontrollera att Windows-datorn är på.
2. Kontrollera att AltServer körs som administratör.
3. Ha iPhone på samma wifi eller låt USB-kabeln sitta i.
4. Öppna **AltStore** på iPhone.
5. Öppna fliken **My Apps**.
6. Tryck `+` högst upp.
7. Fönstret **Filer** öppnas.
8. Välj `MioPhaseOne-unsigned.ipa`.
9. Om AltStore frågar, logga in med samma Apple-konto igen.
10. Vänta medan AltStore signerar och installerar appen.
11. När installationen är klar ska **Mio Fas 1** visas i My Apps och på hemskärmen/Appbiblioteket.

Med ett gratis Apple-konto får högst tre sidoladdade appar vara aktiva samtidigt. AltStore själv räknas normalt som en av dem. Om gränsen är full, avaktivera en annan sidoladdad app i AltStore.

### Snabb reservväg om importen i AltStore inte fungerar

1. Låt telefonen vara ansluten med kabel.
2. Håll `Shift` nedtryckt på Windows-tangentbordet.
3. Klicka samtidigt AltServer-ikonen vid klockan.
4. Välj **Sideload .ipa…**.
5. Välj `MioPhaseOne-unsigned.ipa`.

Den direkta reservvägen måste normalt göras om manuellt inom sju dagar och ger sämre automatisk förnyelse än installation via AltStore-appen.

## Del 15 — alla relevanta iPhone-inställningar för Mio

Kontrollera följande på iPhone:

### Utvecklarläge

> **Inställningar > Integritet och säkerhet > Utvecklarläge: På**

### Utvecklarcertifikat

> **Inställningar > Allmänt > VPN och enhetshantering > Utvecklarapp: Betrodd**

### Mikrofon

Första gången frågar Mio själv. Tryck **Tillåt**.

Om ni råkade trycka nej:

> **Inställningar > Integritet och säkerhet > Mikrofon > Mio Fas 1: På**

I vissa iOS 26-versioner finns samma reglage även under:

> **Inställningar > Appar > Mio Fas 1 > Mikrofon: På**

### Strömsparläge under testet

> **Inställningar > Batteri > Strömsparläge: Av**

Det gör batterimätningen jämförbar och minskar risken att iOS begränsar bakgrundsarbete under första testet.

### AltStore-förnyelse

> **Inställningar > Allmänt > Bakgrundsuppdatering > AltStore: På**

Om iOS har frågat om lokalt nätverk:

> **Inställningar > Appar > AltStore > Lokalt nätverk: På**

Mio behöver inte kontakt-, plats-, kamera-, foto- eller separat taligenkänningsbehörighet i fas 1.

## Del 16 — första starten av Mio

1. Öppna **Mio Fas 1**.
2. Läs kortet **Telefonens stöd**.
3. Tryck **Starta fas 1-test**.
4. När iOS frågar om mikrofonen, tryck **Tillåt**.
5. Appen ska inte fråga om separat taligenkänning.
6. Om Apples svenska modell behöver hämtas, låt appen vara öppen och telefonen vara ansluten till wifi.
7. Vänta tills rubriken visar **Mio lyssnar**.
8. Säg:

   > I dag testar vi Mio på svenska. Mio, kom ihåg att matteprovet är på fredag.

9. Kontrollera att text visas och att räknaren **Mio upptäckt** ökar.
10. Kontrollera att iOS visar den orange mikrofonindikatorn när Mio lyssnar.
11. Tryck **Stoppa Mio** och kontrollera att mikrofonindikatorn försvinner.

Gå därefter vidare till `docs/TESTPLAN_FAS_1.md`.

## Del 17 — låst skärm och bakgrund

För att testa den viktigaste funktionen:

1. Starta Mio inne i appen.
2. Vänta tills svensk text fungerar i förgrunden.
3. Lås sedan skärmen utan att tvångsstänga appen.
4. Säg testmeningarna från testplanen under den låsta perioden.
5. Lås upp och kontrollera märkningen **BAKGRUND**.

Svep inte bort Mio från appväxlaren. Ett aktivt, användarstartat ljudläge kan fortsätta i bakgrunden, men iOS återstartar inte en tvångsstängd app.

Spela inte in lärare, klasskamrater, kollegor eller andra personer utan deras tydliga tillstånd och utan att följa skolans eller arbetsplatsens regler.

---

## Del 18 — förnya appen före sjudagarsgränsen

Med ett gratis Apple-konto upphör AltStore-appar normalt efter sju dagar.

Gör detta minst ett par gånger i veckan:

1. Starta Windows-datorn.
2. Starta iTunes/iCloud-komponenterna om de inte redan körs.
3. Starta AltServer som administratör.
4. Lägg Windows-datorn och iPhone på samma privata wifi, eller anslut kabeln.
5. Öppna AltStore på iPhone.
6. Öppna **My Apps**.
7. Tryck **Refresh All**, eller tryck på Mios återstående dagar.
8. Vänta tills räknaren åter visar sju dagar.

Använd alltid samma Apple-konto. **Radera inte Mio** bara för att signaturen har gått ut; en förnyelse ovanpå den befintliga appen har bäst chans att behålla lokal testdata. Exportera ändå testfilen regelbundet till Filer som säkerhetskopia.

Om både AltStore och Mio redan har gått ut:

1. Anslut telefonen med kabel.
2. Installera AltStore igen från AltServer enligt Del 9 utan att först radera AltStore.
3. Öppna AltStore och förnya eller installera samma Mio-IPA igen.

## Del 19 — när vi ändrar koden senare

1. Ladda upp de ändrade projektfilerna till samma privata GitHub-repository.
2. GitHub skapar en ny commit.
3. Öppna **Actions > Bygg Mio IPA > Run workflow**.
4. Hämta den nya artifact-ZIP-filen.
5. Packa upp artifact-ZIP-filen men inte själva IPA-filen.
6. Installera den nya IPA-filen via AltStore med samma Apple-konto.

Så länge bundle identifier och Apple-konto är samma ska den nya versionen behandlas som en uppdatering. Exportera viktig testdata före uppdateringen för säkerhets skull.

## Vanliga problem

### Actions-fliken visar inget arbetsflöde

Filen ligger troligen för djupt. Den måste finnas exakt här från repositoryts första nivå:

> `.github/workflows/build-unsigned-ipa.yml`

### GitHub-körningen står bara i kö

Vänta några minuter och ladda om sidan. Kontrollera även **Settings > Actions > General** och att GitHub Actions är tillåtet för repositoryt. En privat repository använder kontots inkluderade Actions-kvot.

### GitHub-körningen blir röd

Öppna första röda steget och skicka den första tydliga felraden till Codex.

### Den hämtade filen är ännu en ZIP

Det är normalt: GitHub packar varje artifact i en ZIP. Packa upp just artifact-ZIP-filen en gång. Filen som slutar på `.ipa` ska därefter lämnas orörd.

### AltServer hittar inte telefonen

- använd en datakabel;
- lås upp telefonen;
- tryck **Lita på**;
- kontrollera att iTunes ser telefonen;
- kör AltServer som administratör;
- tillåt AltServer genom Windows-brandväggen på privat nätverk.

### “Could not find AltServer” i AltStore

- använd samma wifi på Windows och iPhone;
- undvik skol-/gästwifi som blockerar enheter från varandra;
- prova kabel;
- kontrollera att AltServer körs;
- kontrollera AltStores behörighet till lokalt nätverk.

### “Developer Mode disabled”

Gör Del 10 och låt telefonen starta om.

### “Untrusted Developer” eller “Integrity could not be verified”

Gör Del 11, kontrollera internetanslutningen och verifiera utvecklarappen.

### “Maximum of 3 apps”

Öppna AltStore > My Apps och avaktivera en annan sidoladdad app. AltStore och Mio behöver två av de tre platserna.

### Mio öppnades tidigare men stängs direkt nu

Signaturen har sannolikt gått ut. Förnya enligt Del 18. Radera inte appen först om ni vill behålla lokal data.

### Ingen svensk motor hittas

Det är ett giltigt fas 1-resultat. Ta en skärmbild av **Telefonens stöd** och skicka den tillsammans med exakt iOS-version.

## Säkerhetsregler

- Lägg aldrig ett Apple-lösenord i GitHub-filer, Actions-inställningar eller Swift-kod.
- Lägg aldrig en OpenAI-nyckel i appen eller på GitHub.
- GitHub-arbetsflödet behöver inga hemligheter för den osignerade byggnaden.
- Använd ett privat repository.
- Ladda inte upp exporterade Mio-sessioner till kodrepositoryt.
- Installera AltServer endast från AltStores officiella webbplats.
- Exportera testdata före ominstallation eller större ändringar.

## Officiella referenser

- [GitHubs aktuella macOS-runner med Xcode 26](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [GitHub Actions och artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows)
- [AltStore: installation på Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
- [AltStore: AltServer och förnyelse](https://faq.altstore.io/altstore-classic/altserver)
- [AltStore: sjudagarsgränsen](https://faq.altstore.io/altstore-classic/your-altstore)
