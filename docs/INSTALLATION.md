# Bygga och installera Mio

Första testtelefon: iPhone 16 Pro. iPhone 13 provas senare. Lägsta iOS-version: 26.0; Xcode 27 och iOS 27 SDK används för bygget. Aktuellt helhetsbygge: **0.9.0, ej släppt**. [Status](STATUS.md) visar vad som faktiskt har byggts och provats.

Färdig testfil: **0.9.0 (5)** från [Actions-körning 36382509184](https://github.com/kanonmaten/mio/actions/runs/36382509184). [Hämta Mio-IPA](https://github.com/kanonmaten/mio/actions/runs/36382509184/artifacts/10953378415), packa upp ZIP-filen och installera IPA:n enligt steg 5–8 nedan. Källrevision och SHA-256 finns i [status](STATUS.md).

Huvudvägen är **GitHub Actions → osignerad IPA → SideStore**. Koden kan redigeras på Linux, Windows eller Monterey; iOS-kompilering sker på en Mac med kompatibel Xcode.

## Uppdatera via GitHub Actions och SideStore

1. Granska och pusha den avsedda commiten enligt [arbetsflödet](WORKFLOW.md).
2. Öppna repots **Actions → Bygg Mio IPA → Run workflow** och välj branch.
3. Workflowen kör ett jobb på GitHubs `xcode-27`-runner: Release med iOS 27 SDK, XCTest på iOS 27-simulator och IPA-validering. Runnern är en offentlig förhandsversion; kontrollera att jobbet faktiskt startar och slutförs. Bygget kontrollerar att appens lägsta iOS-version är 26.0.
4. Hämta artifacten **Mio-IPA**. Packa upp artifact-ZIP en gång; behåll själva IPA:n orörd. Innehåll: `Mio-unsigned.ipa` och `Mio-buildinfo.txt`. Artifacts sparas enligt workflowen i 14 dagar.
5. Behåll bygginformationen med commit, körnings-ID och SHA-256. Flytta IPA:n till Filer på iPhone via en betrodd privat filväg.
6. Installera som **ny app** med bundle identifier `app.mio.assistant`. Prototypen är redan raderad och dess data migreras inte. Vid framtida uppdateringar av denna app behålls den nya identiteten och ditt signeringskonto.
7. Anslut iPhone till Wi-Fi och LocalDevVPN. Öppna **SideStore → My Apps → +** och välj IPA:n.
8. Öppna Mio och kör [helhetstestet](TESTPLAN_HELHET.md), med ren första start och persistens först. Prova IPA:n på den iOS-version som ska användas; iOS 27-bygge och simulatorresultat bevisar inte funktion på iOS 26 eller 27 i fysisk telefon. Kör därefter öppna [transkriptions- och långtest](TESTPLAN_V0_1.md).

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
3. Använd `app.mio.assistant` på app-target. Den nya appen har en egen sandbox; det krävs ingen åtkomst till den gamla prototypen.
4. Anslut iPhone med datakabel, lås upp, välj Lita på och slutför parkopplingen i Xcodes enhetshantering.
5. Aktivera **Inställningar → Integritet och säkerhet → Utvecklarläge** på telefonen och starta om om iOS begär det.
6. Välj scheme **Mio**, fysisk iPhone och **Product → Run** (`⌘R`). Godkänn utvecklarcertifikatet i telefonens **VPN och enhetshantering** om det krävs.
7. Välj en iPhone-simulator och kör **Product → Test** (`⌘U`) för XCTest. Byt tillbaka till telefonen för verkligt ljudtest.

Tester finns i `MioTests/`: modeller, innehållslagring, förslag, lektioner, radering, export och Mio-detektion. Serverns tester körs med `npm test --prefix server`. Projektets `Info.plist` innehåller bakgrundsläget `audio`; det garanterar inte automatisk återstart efter tvångsavslutning.

## Första körning och felsökning

| Situation | Åtgärd |
|---|---|
| Första start | Gå igenom fem flikar, invänta Telefonens stöd och tillåt mikrofonen vid sessionsstart |
| Svensk modell saknas | Build 5 försöker installera stödd svensk SpeechTranscriber vid Starta Mio. Använd Wi-Fi och håll appen öppen; separat förinstallation finns också. Läs stödfälten och händelseloggens fallbackorsak om hämtning/start misslyckas |
| Mikrofon nekad | Aktivera Mio under **Integritet och säkerhet → Mikrofon** |
| Texten stannar efter ljudvägsbyte | Stoppa/starta sessionen och spara observationen med händelseloggen |
| Stabilt Actions-jobb är rött | Spara första tydliga felet, stegets namn, körnings-URL och commit. Senare fel kan vara följdfel |
| Xcode visar signeringsfel | Kontrollera Team och konto; byt inte appidentitet vid uppgradering |
| Telefonen saknas i Xcode | Kontrollera datakabel, upplåsning, betrodd parkoppling, Utvecklarläge och Xcodes iOS-stöd |
| SideStore kan inte förnya | Kontrollera Wi-Fi och LocalDevVPN; förnya SideStore självt och följ officiell felsökning |
| Mio slutar öppnas efter en vecka | Kontrollera signaturens giltighet och förnya, utan att radera appdata |

Spela bara in personer som tydligt samtycker och följ lokala regler. Använd syntetiska data i tester. Spara JSON-exporter privat utanför repot. Vid batteriprov: ingen laddare, Strömsparläge av och dokumenterade start-/slutvärden.

## Användning och valfri server

Efter installation: följ [användarguiden](ANVANDNING.md). AI är avstängd från början och kräver [separat serverkonfiguration](../server/README.md); ingen OpenAI-nyckel ska anges i iPhone-appen. Alarm och notiser begär egna tillstånd först vid Spara. Kalenderkopior granskas och sparas i Apples editor.

## Leverantörsbyte och ny lektionsvy

Arbetskopians AI-utökning är inte med i build 5 ovan. Publicera först den nya gatewaykoden efter godkännande, bygg därefter aktuell apprevision i Xcode/Actions och installera dess IPA. Höj byggnumret inför den nya distribuerade builden. Den nya appen använder `/v1/lesson-notes`; en äldre gateway ger 404 där. Gamla appversioners `/v1/ask` och `/v1/analyze` behålls i den nya gatewayen.

När båda är uppdaterade görs modell-/leverantörsbyte enligt [Cloudflare-guiden](../server/PROVIDERS.md), utan ytterligare IPA. Slå av AI i telefonen under bytet och slå på igen efter konfigurering och publicering. Hemligheter kopieras aldrig till repot.
