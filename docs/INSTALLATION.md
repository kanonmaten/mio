# Bygga och installera Mio

Måltelefon: iPhone 13 med iOS 26+. Aktuell version: **v0.2.0, ej släppt**. [Status](STATUS.md) visar vad som faktiskt har byggts och provats.

Huvudvägen är **GitHub Actions → osignerad IPA → SideStore**. Koden kan redigeras på Linux, Windows eller Monterey; iOS-kompilering sker på en Mac med kompatibel Xcode.

## Uppdatera via GitHub Actions och SideStore

1. Granska och pusha den avsedda commiten enligt [arbetsflödet](WORKFLOW.md).
2. Öppna repots **Actions → Bygg Mio IPA → Run workflow** och välj branch.
3. Workflowen är konfigurerad för stabil Xcode 26.6 på `macos-26`. Det jobbet måste klara Release, XCTest och IPA-validering. Xcode 27-preview är separat och icke blockerande; det kan avmarkeras om runnern är otillgänglig.
4. Hämta artifacten **Mio-IPA**. Packa upp artifact-ZIP en gång; behåll själva IPA:n orörd. Innehåll: `Mio-unsigned.ipa` och `Mio-buildinfo.txt`. Artifacts sparas enligt workflowen i 14 dagar.
5. Behåll bygginformationen med commit, körnings-ID och SHA-256. Flytta IPA:n till Filer på iPhone via en betrodd privat filväg.
6. **Exportera viktig befintlig Mio-data privat före uppdatering. Radera inte appen.** Använd samma signeringskonto och bundle identifier `se.eyvin.MioPhaseOne` för uppgradering på plats.
7. Anslut iPhone till Wi-Fi och LocalDevVPN. Öppna **SideStore → My Apps → +** och välj IPA:n.
8. Öppna Mio och kör [test A–M](TESTPLAN_V0_2.md), med uppgradering och bevarade sessioner först. Kör därefter öppna [transkriptions- och långtest](TESTPLAN_V0_1.md).

Byggsystemet behöver inga Apple-uppgifter eller API-nycklar. `unsigned` betyder att SideStore sköter personlig signering. Ett grönt simulatorjobb verifierar inte mikrofon, bakgrund eller fysisk iPhone.

## SideStore: första installation och förnyelse

SideStore-flödet fungerade i det historiska provet 2026-08-20. Följ deras aktuella [förkrav](https://docs.sidestore.io/docs/installation/prerequisites) och [iLoader-guide](https://docs.sidestore.io/docs/installation/install) för en ny dator eller telefon; tredjepartsverktygens instruktioner kan ändras.

Grundflödet är LocalDevVPN på telefonen → iLoader på datorn → datakabel och betrodd parkoppling → installera SideStore → godkänn utvecklarappen och Utvecklarläge på iPhone → logga in i SideStore med samma signeringskonto. Installera verktygen endast från officiellt länkade källor.

Förnya Mio och SideStore före den kostnadsfria signeringens sjudagarsgräns: Wi-Fi → LocalDevVPN → **My Apps → Refresh All**. Kontrollera räknaren manuellt. Om SideStore har löpt ut kan iLoader behövas igen; radera inte Mio för att lösa signeringsproblem.

Pairing-filer, certifikat och Apple-uppgifter är känsliga och hör aldrig hemma i repot. Se [SideStores felsökning](https://docs.sidestore.io/docs/troubleshooting) och [FAQ](https://docs.sidestore.io/docs/faq) vid pairing- eller appgränsproblem.

## Alternativ: direkt med Xcode

Kräver en Mac som stöder vald Xcode-version och telefonens iOS. Kontrollera [Apples kompatibilitetstabell](https://developer.apple.com/xcode/system-requirements); Monterey kan inte bygga detta projekt.

1. Hämta repot och öppna `Mio.xcodeproj`.
2. Lägg till Apple-kontot i Xcode Settings. På app-target **Mio**, välj **Signing & Capabilities → Automatically manage signing → Personal Team**.
3. Behåll `se.eyvin.MioPhaseOne` vid uppdatering. En ny identifierare skapar en annan app utan åtkomst till den gamla datan; lös signeringsproblem med rätt konto.
4. Anslut iPhone med datakabel, lås upp, välj Lita på och slutför parkopplingen i Xcodes enhetshantering.
5. Aktivera **Inställningar → Integritet och säkerhet → Utvecklarläge** på telefonen och starta om om iOS begär det.
6. Välj scheme **Mio**, fysisk iPhone och **Product → Run** (`⌘R`). Godkänn utvecklarcertifikatet i telefonens **VPN och enhetshantering** om det krävs.
7. Välj en iPhone-simulator och kör **Product → Test** (`⌘U`) för XCTest. Byt tillbaka till telefonen för verkligt ljudtest.

Tester finns i `MioTests/`: modeller, innehållslagring och Mio-detektion. Projektets `Info.plist` innehåller bakgrundsläget `audio`; det garanterar inte automatisk återstart efter tvångsavslutning.

## Första körning och felsökning

| Situation | Åtgärd |
|---|---|
| Första start | Gå igenom fem flikar, invänta Telefonens stöd och tillåt mikrofonen vid sessionsstart |
| Svensk modell saknas | Prova separat **Installera SpeechTranscriber-modell** med Wi-Fi och appen öppen. Starta inte session under installation. Kontrollera status igen; fallback är `DictationTranscriber` med `sv_SE` |
| Mikrofon nekad | Aktivera Mio under **Integritet och säkerhet → Mikrofon** |
| Texten stannar efter ljudvägsbyte | Stoppa/starta sessionen och spara observationen med händelseloggen |
| Stabilt Actions-jobb är rött | Spara första tydliga felet, stegets namn, körnings-URL och commit. Senare fel kan vara följdfel |
| Xcode visar signeringsfel | Kontrollera Team och konto; byt inte appidentitet vid uppgradering |
| Telefonen saknas i Xcode | Kontrollera datakabel, upplåsning, betrodd parkoppling, Utvecklarläge och Xcodes iOS-stöd |
| SideStore kan inte förnya | Kontrollera Wi-Fi och LocalDevVPN; förnya SideStore självt och följ officiell felsökning |
| Mio slutar öppnas efter en vecka | Kontrollera signaturens giltighet och förnya, utan att radera appdata |

Spela bara in personer som tydligt samtycker och följ lokala regler. Använd syntetiska data i tester. Spara JSON-exporter privat utanför repot. Vid batteriprov: ingen laddare, Strömsparläge av och dokumenterade start-/slutvärden.
