# Bygga och installera Mio

Datorn ska vara uppsatt först (Pianissimo, AI-gatewayen och Tailscale); ordningen står i [README](../README.md#kom-igång). [Status](STATUS.md) visar vad som faktiskt har byggts och provats.

Telefonen behöver iOS 26.0 eller senare (först provad på iPhone 16 Pro). GitHub Actions bygger en osignerad IPA med Xcode 27, och SideStore signerar och installerar den på telefonen. Ingen Mac behövs.

## Bygg och installera

1. Uppdatera datorn först om serverkoden ändrats: `git pull`, sedan `transcription-server/install.sh` och `server/install.sh`. Tokens behålls, så telefonen behöver inte paras om.
2. Kontrollera att **Verifiera Mio på Linux** är grön för den commit du ska bygga.
3. Kör **Actions → Bygg Mio IPA → Run workflow** på `main`. Den bygger Release, kör XCTest och UI-prov på en iOS 27-simulator och kontrollerar IPA:n (cirka 25 minuter).
4. Hämta artifacten **Mio-IPA** (sparas 14 dagar) och packa upp ZIP-filen en gång. Den innehåller `Mio-unsigned.ipa` och `Mio-buildinfo.txt` med commit och SHA-256. Flytta IPA:n till Filer på telefonen.
5. Telefonen på Wi-Fi med LocalDevVPN påslaget: **SideStore → My Apps → +** och välj IPA:n. Appen heter `app.mio.assistant`; en uppdatering behåller dina data.
6. Slå på Tailscale igen efter LocalDevVPN, öppna Mio och kör [helhetstestet](TESTPLAN_HELHET.md).

Ett grönt simulatorjobb bevisar inte mikrofon, bakgrund eller funktion på en riktig telefon.

## SideStore: första installation och förnyelse

För en ny dator eller telefon, följ SideStores egna [förkrav](https://docs.sidestore.io/docs/installation/prerequisites) och [iLoader-guide](https://docs.sidestore.io/docs/installation/install), eftersom de ändras. I korthet:

1. Installera LocalDevVPN på telefonen och iLoader på datorn, från de länkar SideStore anger.
2. Anslut telefonen med kabel och godkänn parkopplingen.
3. Installera SideStore med iLoader, godkänn utvecklarappen och slå på Utvecklarläge på telefonen.
4. Logga in i SideStore med samma Apple-konto som signerar.

Gratiskontots signatur gäller i sju dagar. Förnya innan dess: Wi-Fi och LocalDevVPN på, sedan **My Apps → Refresh All**. Har SideStore hunnit gå ut kan iLoader behövas igen. Radera inte Mio för att lösa ett signeringsproblem, då försvinner dina data.

Pairing-filer, certifikat och Apple-uppgifter hör aldrig hemma i repot. Vid problem: [SideStores felsökning](https://docs.sidestore.io/docs/troubleshooting) och [FAQ](https://docs.sidestore.io/docs/faq).

## Live Activity (otestat)

IPA:n innehåller tillägget `MioWidgets.appex` (`app.mio.assistant.widgets`) för "Lyssnar"-rutan på låsskärmen och i Dynamic Island. SideStore signerar det som ett andra app-ID, vilket räknas mot gratiskontots veckogräns. Syns rutan aldrig: kontrollera **Inställningar → Mio → Live Activities** och notera eventuellt fel från SideStore.

## Alternativ: direkt med Xcode

Kräver en Mac som stöder vald Xcode-version och telefonens iOS. Kontrollera [Apples kompatibilitetstabell](https://developer.apple.com/xcode/system-requirements); Monterey kan inte bygga detta projekt.

1. Hämta repot och öppna `Mio.xcodeproj`.
2. Lägg till Apple-kontot i Xcode Settings. På app-target **Mio**, välj **Signing & Capabilities → Automatically manage signing → Personal Team**.
3. Behåll `app.mio.assistant` som bundle identifier, annars installeras en ny app utan dina data.
4. Anslut iPhone med datakabel, lås upp, välj Lita på och slutför parkopplingen i Xcodes enhetshantering.
5. Aktivera **Inställningar → Integritet och säkerhet → Utvecklarläge** på telefonen och starta om om iOS begär det.
6. Välj scheme **Mio**, fysisk iPhone och **Product → Run** (`⌘R`). Godkänn utvecklarcertifikatet i telefonens **VPN och enhetshantering** om det krävs.
7. Välj en iPhone-simulator och kör **Product → Test** (`⌘U`) för XCTest. Ljud går bara att prova på telefonen.

## Felsökning

| Situation | Åtgärd |
|---|---|
| `mio-pair` visar ingen kod | Kör `server/install.sh` först. Saknar koden transkriptionen: installera Pianissimo och kör `mio-pair` igen |
| Transkription offline | Datorn vaken, `transcription-server/check.sh` redo, Tailscale på i båda enheterna. Se [Pianissimo-guiden](../transcription-server/README.md) |
| AI svarar inte | `systemctl status mio-gateway` på datorn; se [gatewayguiden](../server/README.md) |
| Mikrofon nekad | Slå på Mio under **Integritet och säkerhet → Mikrofon** |
| Texten stannar efter ett avbrott | Mio startar om mikrofonen själv eller visar notisen "Tryck för att fortsätta lyssna". Annars: välj Fortsätt |
| Raderingen är delvis utförd | Följ bannern och välj Försök slutföra raderingen igen |
| Actions-jobbet är rött | Spara första tydliga felet, stegets namn och körnings-URL; senare fel kan vara följdfel |
| SideStore kan inte förnya | Wi-Fi och LocalDevVPN på; förnya SideStore självt och följ deras felsökning |
| Mio öppnas inte efter en vecka | Signaturen har gått ut: förnya, radera inte appen |

## Verifiera före bygge

Linuxgrinden kör lokala kontroller med syntetiska data. Den publicerar ingenting och gör inga riktiga modellanrop. GitHub kör samma grind vid varje push (workflowen Verifiera Mio på Linux, i containern `swift:6.3.3-noble`).

Lokalt behövs Linux, `python3`, `git`, Node 26 (minst 26.10), `npm`, `uv` och `swiftc` (eller `SWIFT_EXECUTABLE`). Kommandot kontrollerar arbetskopian där skriptet ligger:

```bash
mio_repo_directory="$(git rev-parse --show-toplevel)"
python3 "$mio_repo_directory/scripts/verify.py"
# valfritt: --logs-dir /tmp/mio-verification-<revision> --measure-session-store
```

| Grind | Täcker | Täcker inte |
|---|---|---|
| Struktur | Projektidentitet, targets, länkar, integritets-/konfigurationsregler, workflowinställningar | SwiftUI/iOS-bygge |
| Node-gateway | Gateway, Groq-adapter, routing, kvot och sparade räknare, deadlines med fixtures | Nyckel, modellåtkomst, modellkvalitet, installerad tjänst och Tailscale på datorn |
| Privat transkriptions-API | Låst Pythonmiljö, API/cache/deadline med fake-backend | Pianissimo, GPU, svensk kvalitet |
| Portable Swift, capture recovery, strikt concurrency | Modeller, actorpatchar, workflows, återhämtning | AVFoundation, Keychain, URLSession, UIKit/SwiftUI, iOS-filskydd |
| Långhistorik (valfri) | Syntetisk session-store: kodning, patchskrivning, processminne | iPhone, ljud, batteri |

Resultatet är `PASS (Linux synthetic gates)`, `FAIL` (exitkod 1) eller `UNAVAILABLE` (exitkod 2). Med `--skip-swift` blir det `PARTIAL`, och då är Swift inte kontrollerat. `verification.json` i loggkatalogen anger commit, verktygsversioner och vilka grindar som körts; iOS och riktig modelltrafik står alltid som `NOT RUN`.

iOS-koden kontrolleras bara av workflowen Bygg Mio IPA: concurrencydiagnostik, Release-bygge, XCTest med tre UI-prov och kontroll av IPA:n. På en Mac går concurrencydiagnostiken att köra direkt med `python3 scripts/verify_concurrency.py --native --log /tmp/mio-native-concurrency.log`.

Loggar får bara innehålla textfri diagnostik: aldrig källtext, frågor, svar, ljud, tokens, fulla adresser eller exporter.
