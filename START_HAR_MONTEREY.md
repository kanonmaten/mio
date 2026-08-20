# Mio på iPhone — GitHub Actions + SideStore

Detta är huvudguiden för den valda miljön:

- utvecklings-Macen är låst till macOS Monterey;
- hennes iPhone 13 kör iOS 26;
- GitHub Actions bygger med Xcode 26.6;
- SideStore signerar, installerar och förnyar appen;
- appen publiceras inte i App Store.

Molnbygget och den första SideStore-installationen har redan lyckats. Avsnitten om engångsinstallation finns kvar för en ny dator eller ominstallation.

## Kedjan

```text
Lokalt repo
   │ GitHub Desktop: commit + push
   ▼
Privat GitHub-repo
   │ GitHub Actions: Xcode 26.6
   ▼
MioPhaseOne-unsigned.ipa
   │ SideStore + personligt Apple-konto
   ▼
iPhone 13
```

GitHub får källkoden men inga Apple-lösenord eller Mio-sessioner. SideStore får IPA-filen och använder Apple-kontot för personlig signering. Fas 1 skickar inga transkriptioner eller mikrofondata till GitHub, SideStore eller OpenAI.

## Det löpande arbetsflödet

### 1. Synkronisera och granska

1. Öppna GitHub Desktop och välj repot `mio`.
2. Tryck **Fetch origin**.
3. Gör förändringen i Codex-projektet Mio.
4. Granska filerna under **Changes** i GitHub Desktop.
5. Kontrollera att listan inte innehåller IPA, test-JSON, pairing-filer, certifikat eller hemligheter.
6. Skriv en kort commit-rad och klicka **Commit to main**.
7. Klicka **Push origin**.

Läs [docs/WORKFLOW.md](docs/WORKFLOW.md) för hela arbetsrutinen.

### 2. Bygg en ny IPA

1. Öppna repot på GitHub.
2. Välj **Actions**.
3. Klicka **Bygg Mio IPA** i vänsterspalten.
4. Klicka **Run workflow**, välj `main` och bekräfta.
5. Öppna körningen och vänta på en grön bock.

Workflowen:

- hämtar repot på en tillfällig GitHub-Mac;
- väljer Xcode 26.6;
- validerar projekt- och integritetsfiler;
- bygger en riktig arm64-app för iPhone;
- kontrollerar IPA:n och publicerar den som artifact i 14 dagar.

Om körningen blir röd: öppna det första röda steget och skicka den första tydliga felraden samt stegets namn till Codex. Senare rader är ofta följdfel.

### 3. Hämta IPA-filen

1. Öppna den gröna körningens sammanfattning.
2. Scrolla till **Artifacts**.
3. Klicka **MioPhaseOne-IPA**.
4. Packa upp den nedladdade artifact-ZIP-filen en gång.
5. Kontrollera att mappen innehåller:

   ```text
   MioPhaseOne-unsigned.ipa
   MioPhaseOne-buildinfo.txt
   ```

6. Packa inte upp själva `.ipa`-filen.

`unsigned` är korrekt: GitHub kompilerar appen och SideStore skapar den personliga signaturen.

### 4. Flytta IPA-filen till iPhone

Använd en privat filväg som ni redan litar på, exempelvis OneDrive eller iCloud Drive:

1. Lägg `MioPhaseOne-unsigned.ipa` i den valda mappen på Windows.
2. Vänta tills filen är synkroniserad.
3. Öppna **Filer** på iPhone och hämta filen lokalt om en molnsymbol visas.

IPA:n innehåller appkod men inga sparade Mio-sessioner.

### 5. Installera eller uppdatera Mio med SideStore

1. Exportera viktig testdata från den befintliga Mio-appen först.
2. Anslut iPhone till vanligt Wi‑Fi; enbart mobildata räcker inte för SideStores normala flöde.
3. Öppna **LocalDevVPN** och anslut.
4. Öppna **SideStore > My Apps**.
5. Tryck `+` och välj `MioPhaseOne-unsigned.ipa` i Filer.
6. Vänta medan SideStore signerar och installerar appen.
7. Kontrollera att **Mio Fas 1** visas under My Apps och går att öppna.

Använd samma Apple-konto och samma bundle identifier vid uppdateringar. Installera över den befintliga appen och radera den inte i onödan; det ger bäst chans att behålla lokal data.

En Windows-dator behöver normalt inte vara igång när en IPA installeras från den redan konfigurerade SideStore-appen. Wi‑Fi och LocalDevVPN måste däremot vara aktiva.

## Förnya före sjudagarsgränsen

Appar signerade med ett gratis Apple-konto gäller normalt i sju dagar.

Gör detta ett par gånger i veckan:

1. Anslut iPhone till Wi‑Fi.
2. Slå på LocalDevVPN.
3. Öppna **SideStore > My Apps**.
4. Tryck på Mios återstående dagar eller använd **Refresh All**.
5. Kontrollera att räknaren åter visar ungefär sju dagar.

SideStore kan försöka uppdatera i bakgrunden, men kontrollera manuellt så att appen inte löper ut. Om SideStore själv har löpt ut behövs normalt en dator och iLoader för att installera om SideStore. Följ då SideStores aktuella officiella installationsguide och radera inte Mio först om lokal data är viktig.

## Relevanta iPhone-inställningar

### Utvecklarläge

> **Inställningar > Integritet och säkerhet > Utvecklarläge: På**

### Utvecklarapp

> **Inställningar > Allmänt > VPN och enhetshantering > Utvecklarapp**

Kontot som används av SideStore ska vara betrott. På vissa iOS 26-versioner visas **Tillåt och starta om** i stället för en vanlig Lita på-knapp.

### Mikrofon

Första gången Mio frågar: välj **Tillåt**.

Om behörigheten nekades:

> **Inställningar > Integritet och säkerhet > Mikrofon > Mio Fas 1: På**

### SideStore

- Wi‑Fi måste vara anslutet vid installation, uppdatering och förnyelse.
- LocalDevVPN måste vara ansluten vid samma åtgärder.
- Ett gratis Apple-konto tillåter högst tre aktiva sidoladdade appar inklusive SideStore och högst tio App-ID:n under en sjudagarsperiod.

### Batteritest

> **Inställningar > Batteri > Strömsparläge: Av**

Koppla ur USB/laddning före batteritestet. Mio behöver inte behörighet till kontakter, plats, kamera, bilder eller den äldre separata taligenkänningsprompten i fas 1.

## Första start och telefonprov

1. Öppna **Mio Fas 1**.
2. Vänta tills kortet **Telefonens stöd** är färdigt.
3. Tryck **Starta fas 1-test** och tillåt mikrofonen.
4. Vänta tills rubriken visar **Mio lyssnar**.
5. Kontrollera den orange mikrofonindikatorn.
6. Följ [docs/TESTPLAN_FAS_1.md](docs/TESTPLAN_FAS_1.md).
7. Stoppa testet och exportera JSON-filen.
8. Lägg inte testfilen i GitHub-repot. Skicka den privat till Codex vid analys.

Spela aldrig in lärare, klasskamrater, kollegor eller andra utan tydligt tillstånd och utan att följa skolans, arbetsplatsens och lagens regler.

## Engångsinstallation av SideStore

Detta är endast för en ny dator, ny telefon eller ominstallation. SideStore är en tredjepartslösning i publik beta, inte en Apple-produkt.

### Förbered

1. Ha ett Apple-konto för personlig signering. Det behöver inte vara telefonens vanliga iCloud-konto.
2. Installera **LocalDevVPN** från App Store på iPhone och tillåt VPN-konfigurationen.
3. Installera iTunes på Windows. SideStore rekommenderar i första hand Apples direktnedladdade version; om den inte fungerar kan Microsoft Store-versionen eller Apple Devices-appen provas enligt deras aktuella guide.
4. Hämta och installera **iLoader** från länken i SideStores officiella förkravssida.

### Installera SideStore med kabel

1. Anslut iPhone med en datakabel, lås upp den och välj **Lita på den här datorn**.
2. Öppna iLoader.
3. Logga in med det valda Apple-kontot; skiftläget i adressen spelar roll.
4. Välj rätt iPhone.
5. Välj **Install SideStore (Stable)**.
6. På iPhone, öppna **Inställningar > Allmänt > VPN och enhetshantering** och godkänn utvecklarappen.
7. Slå på **Utvecklarläge** under **Integritet och säkerhet** och låt telefonen starta om om iOS kräver det.
8. Anslut LocalDevVPN, öppna SideStore och logga in med samma Apple-konto.
9. Öppna **My Apps** och tryck först på SideStores egen **7 DAYS**-räknare så att SideStore förnyar sig själv med rätt appgrupp.

SideStores pairing-information kan bli ogiltig efter en iOS-uppdatering, återställning eller ibland utan tydlig orsak. Ersätt den då via iLoader enligt den aktuella felsökningsguiden. Pairing-filer är känsliga och får aldrig laddas upp till GitHub eller skickas till andra.

## Ny dator: hämta repot professionellt

Använd inte GitHubs webbsida för att ladda upp mappar på nytt.

1. Installera GitHub Desktop.
2. Välj **File > Clone repository**.
3. Välj `kanonmaten/mio`.
4. Behåll en enda lokal arbetskopia, normalt:

   `C:\Users\eyvin\Documents\GitHub\mio`

5. Koppla Codex-projektet Mio till samma mapp.

## Vanliga problem

### Actions-fliken visar inget workflow

Kontrollera att filen finns exakt som `.github/workflows/build-unsigned-ipa.yml` från repots rot och att Actions är tillåtet under **Settings > Actions > General**.

### Artifacten är en ZIP

Det är normalt. Packa upp artifact-ZIP-filen en gång men lämna `.ipa` orörd.

### SideStore kan inte installera eller förnya

- kontrollera vanligt Wi‑Fi;
- anslut LocalDevVPN;
- uppdatera först SideStore själv;
- starta om SideStore och LocalDevVPN;
- stäng tillfälligt av DNS-blockerare;
- ersätt pairing-informationen via iLoader om felet nämner pairing eller UDID.

### “Maximum of 3 apps”

Ett gratis Apple-konto har tre aktiva appplatser och SideStore använder en. Avaktivera en annan sidoladdad app om gränsen är full.

### Mio öppnades tidigare men stängs nu direkt

Signaturen har sannolikt löpt ut. Förnya i SideStore. Radera inte Mio först om ni vill behålla lokal data.

### Ingen avancerad svensk motor

Det första iPhone-testet visade detta och appen gick korrekt över till `DictationTranscriber` med `sv_SE`. Det är den verifierade vägen på den aktuella telefonen.

## Säkerhetsregler

- Lägg aldrig Apple-lösenord, API-nycklar, pairing-filer eller certifikat i GitHub.
- Ladda aldrig upp exporterade Mio-sessioner till kodrepot.
- Installera iLoader, SideStore och LocalDevVPN endast via SideStores officiella dokumentation och länkade officiella källor.
- Exportera testdata före ominstallation eller större uppdatering.
- GitHub-workflowen behöver inga hemligheter för den osignerade byggnaden.

## Officiella referenser

- [SideStore: förkrav och LocalDevVPN](https://docs.sidestore.io/docs/installation/prerequisites)
- [SideStore: installation med iLoader](https://docs.sidestore.io/docs/installation/install)
- [SideStore: vanliga frågor och begränsningar](https://docs.sidestore.io/docs/faq)
- [SideStore: felsökning](https://docs.sidestore.io/docs/troubleshooting)
- [GitHub Actions och workflows](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows)
- [GitHubs macOS 26-runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
