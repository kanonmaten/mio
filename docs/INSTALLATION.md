# Bygga och installera Mio

Det nya bygget kräver även [CachyOS/Pianissimo/Tailscale-installation](../transcription-server/README.md). Återanslut Tailscale efter SideStore/LocalDevVPN och kontrollera servern i Mio. Ingen ny IPA har byggts för arbetskopian.

Första testtelefon: iPhone 16 Pro. iPhone 13 provas senare. Lägsta iOS-version: 26.0; Xcode 27 och iOS 27 SDK används för bygget. Aktuellt helhetsbygge: **0.9.0, ej släppt**. [Status](STATUS.md) visar vad som faktiskt har byggts och provats.

**Historisk testfil, saknar Pianissimo-klienten:** **0.9.0 (5)** från [Actions-körning 36382509184](https://github.com/kanonmaten/mio/actions/runs/36382509184). [Hämta Mio-IPA](https://github.com/kanonmaten/mio/actions/runs/36382509184/artifacts/10953378415), packa upp ZIP-filen och installera IPA:n enligt steg 5–8 nedan. Källrevision och SHA-256 finns i [status](STATUS.md).

Huvudvägen är **GitHub Actions → osignerad IPA → SideStore**. Koden kan redigeras på Linux, Windows eller Monterey; iOS-kompilering sker på en Mac med kompatibel Xcode.

## Uppdatera via GitHub Actions och SideStore

1. Kör först [verifieringen](#verifiera-före-bygge) i exakt den arbetskopia som ska byggas. Granska diffen. Färdiga ändringar committas och pushas direkt till `main` (se [CLAUDE.md](../CLAUDE.md)); bevara commit-ID och eventuellt kvarvarande diff-underlag.
2. Öppna repots **Actions → Bygg Mio IPA → Run workflow** och välj branch.
3. Workflowen använder ett jobb med etiketten `xcode-27`: osignerad Release med iOS 27 SDK, separat strikt concurrencydiagnostik, XCTest inklusive tre UI-smokeprov på en tillgänglig iOS 27-simulator och IPA-validering. Kontrollera faktisk tilldelad runner, Xcode-/SDK-version, simulator, diagnostik och slutresultat för samma commit. En runneretikett eller köad körning bevisar inte att miljön är tillgänglig. Bygget kontrollerar att appens lägsta iOS-version är 26.0.
4. Hämta artifacten **Mio-IPA**. Packa upp artifact-ZIP en gång; behåll själva IPA:n orörd. Innehåll: `Mio-unsigned.ipa` och `Mio-buildinfo.txt`. Artifacts sparas enligt workflowen i 14 dagar.
5. Behåll bygginformationen med commit, körnings-ID, verktygsversioner och SHA-256 samt test-/diagnostikloggarna. Registrera gatewayens separata release/bundeldigest och konfigurationsrevision för AI-proven. Flytta IPA:n till Filer på iPhone via en betrodd privat filväg.
6. Installera som **ny app** med bundle identifier `app.mio.assistant`. Prototypen är redan raderad och dess data migreras inte. Vid framtida uppdateringar av denna app behålls den nya identiteten och ditt signeringskonto.
7. Anslut iPhone till Wi-Fi och LocalDevVPN. Öppna **SideStore → My Apps → +** och välj IPA:n.
8. Öppna Mio och kör [helhetstestet](TESTPLAN_HELHET.md), med ren första start och persistens först. Prova enligt [mätprotokollet](TESTPLAN_HELHET.md#mätprotokoll-och-resultatmall) på iPhone 16 Pro och därefter iPhone 13, med exakt iOS-version. iOS 27-bygge och simulatorresultat bevisar inte funktion på iOS 26 eller 27 i fysisk telefon. Kör privat Pianissimo och de dokumenterade ljud-/nät-/långproven; äldre Apple-prov är historik.

Byggsystemet behöver inga Apple-uppgifter eller API-nycklar. `unsigned` betyder att SideStore sköter personlig signering. Ett grönt simulatorjobb verifierar inte mikrofon, bakgrund eller fysisk iPhone.

## SideStore: första installation och förnyelse

SideStore-flödet fungerade i det historiska provet 2026-08-20. Följ deras aktuella [förkrav](https://docs.sidestore.io/docs/installation/prerequisites) och [iLoader-guide](https://docs.sidestore.io/docs/installation/install) för en ny dator eller telefon; tredjepartsverktygens instruktioner kan ändras.

Grundflödet är LocalDevVPN på telefonen → iLoader på datorn → datakabel och betrodd parkoppling → installera SideStore → godkänn utvecklarappen och Utvecklarläge på iPhone → logga in i SideStore med samma signeringskonto. Installera verktygen endast från officiellt länkade källor.

Förnya Mio och SideStore före den kostnadsfria signeringens sjudagarsgräns: Wi-Fi → LocalDevVPN → **My Apps → Refresh All**. Kontrollera räknaren manuellt. Om SideStore har löpt ut kan iLoader behövas igen; radera inte Mio för att lösa signeringsproblem.

Pairing-filer, certifikat och Apple-uppgifter är känsliga och hör aldrig hemma i repot. Se [SideStores felsökning](https://docs.sidestore.io/docs/troubleshooting) och [FAQ](https://docs.sidestore.io/docs/faq) vid pairing- eller appgränsproblem.

## Live Activity och widgettillägget (otestat)

IPA:n innehåller nu tillägget `MioWidgets.appex` (`app.mio.assistant.widgets`) för låsskärmens och Dynamic Islands "Lyssnar"-ruta med Pausa/Fortsätt och Stopp. SideStore måste signera det som ett andra app-ID. Med ett gratiskonto räknas det mot gränsen för app-ID:n per vecka; att det fungerar med SideStore är ännu inte provat på telefonen. Om installationen misslyckas eller rutan aldrig syns: notera felet från SideStore och kontrollera **Inställningar → Mio → Live Activities**. "Fortsätt" öppnar Mio, eftersom iOS inte låter en app i bakgrunden starta mikrofonen.

## Alternativ: direkt med Xcode

Kräver en Mac som stöder vald Xcode-version och telefonens iOS. Kontrollera [Apples kompatibilitetstabell](https://developer.apple.com/xcode/system-requirements); Monterey kan inte bygga detta projekt.

1. Hämta repot och öppna `Mio.xcodeproj`.
2. Lägg till Apple-kontot i Xcode Settings. På app-target **Mio**, välj **Signing & Capabilities → Automatically manage signing → Personal Team**.
3. Använd `app.mio.assistant` på app-target. Den nya appen har en egen sandbox; det krävs ingen åtkomst till den gamla prototypen.
4. Anslut iPhone med datakabel, lås upp, välj Lita på och slutför parkopplingen i Xcodes enhetshantering.
5. Aktivera **Inställningar → Integritet och säkerhet → Utvecklarläge** på telefonen och starta om om iOS begär det.
6. Välj scheme **Mio**, fysisk iPhone och **Product → Run** (`⌘R`). Godkänn utvecklarcertifikatet i telefonens **VPN och enhetshantering** om det krävs.
7. Välj en iPhone-simulator och kör **Product → Test** (`⌘U`) för XCTest. Byt tillbaka till telefonen för verkligt ljudtest.

Tester finns i `MioTests/`: modeller, actorägda lagringspatchar, workflow, förslag, lektioner, avbrott, återupptagbar radering, export och Mio-detektion. `MioUITests/` innehåller tre mindre native smoke-/tillgänglighetsprov. Säkra server-/Worker-/Python-/portableprov körs via [verifieringen](#verifiera-före-bygge). Projektets `Info.plist` innehåller bakgrundsläget `audio`; mikrofonen kräver ändå nytt användartryck efter avbrott/reset/tvångsavslutning. Simulatorns ljudbeteende ersätter inte fysisk telefon.

## Första körning och felsökning

| Situation | Åtgärd |
|---|---|
| Första start | Gå igenom fem flikar, spara/testa privat transkriptionsanslutning och tillåt mikrofonen vid uttrycklig sessionsstart |
| Transkription offline | Följ Pianissimo-guiden: dator vaken, systemd redo, Tailscale på båda enheterna, rätt HTTPS-adress/token. Build 5 kan inte använda ljudservern |
| Mikrofon nekad | Aktivera Mio under **Integritet och säkerhet → Mikrofon** |
| Texten stannar efter ljudavbrott/ljudvägsbyte | Mio ska starta om mikrofonen själv eller visa notisen "Tryck för att fortsätta lyssna". Annars: kontrollera mikrofon-/transkriptionsstatus, välj Fortsätt och spara observationen med textfri händelselogg |
| Raderingen är delvis utförd | Följ bannertexten och välj Försök slutföra raderingen igen. Starta inte nya ändringar eller AI-sändningar medan återhämtningen är blockerad |
| Stabilt Actions-jobb är rött | Spara första tydliga felet, stegets namn, körnings-URL och commit. Senare fel kan vara följdfel |
| Xcode visar signeringsfel | Kontrollera Team och konto; byt inte appidentitet vid uppgradering |
| Telefonen saknas i Xcode | Kontrollera datakabel, upplåsning, betrodd parkoppling, Utvecklarläge och Xcodes iOS-stöd |
| SideStore kan inte förnya | Kontrollera Wi-Fi och LocalDevVPN; förnya SideStore självt och följ officiell felsökning |
| Mio slutar öppnas efter en vecka | Kontrollera signaturens giltighet och förnya, utan att radera appdata |

Spela bara in personer som tydligt samtycker och följ lokala regler. Använd syntetiska data i tester. Spara JSON-exporter privat utanför repot. Vid batteriprov: ingen laddare, Strömsparläge av och dokumenterade start-/slutvärden.

## Användning och valfri server

Efter installation: följ [användarguiden](ANVANDNING.md). AI är avstängd från början och kräver [separat serverkonfiguration](../server/README.md); ingen leverantörsnyckel ska anges i iPhone-appen. Testa text-AI-anslutningen utan modelltrafik före en fråga. Statusprovet visar konfiguration och autentisering, inte verifierad modellåtkomst/kvalitet. Alarm och notiser begär egna tillstånd först vid Spara. Kalenderkopior granskas och sparas i Apples editor.

## Leverantörsbyte och ny lektionsvy

Arbetskopians utökning är inte med i build 5 ovan. Publicera först den avsedda gatewaybundeln med kompatibel konfiguration efter godkännande, läsverifiera aktiv release och skyddad status, bygg därefter aktuell apprevision i Xcode/Actions och installera dess IPA. Höj byggnumret inför den nya distribuerade builden. Nya AI-flöden kräver skyddad `/v2/status` och dess observerade konfigurationsrevision; detaljerade lektioner använder `/v1/lesson-notes`. Gamla klienters v1-rutter behålls, men det gör inte en gammal gateway kompatibel med den nya klienten. Verkliga syntetiska modellanrop kräver separat sändningsgodkännande.

När båda är uppdaterade görs modell-/leverantörsbyte per serveruppgift enligt [Cloudflare-guiden](../server/README.md), utan modellväljare eller ytterligare IPA. Slå av AI under bytet, gör det modellfria anslutningsprovet igen och granska en ny sändning/aktivering. Ett 409-konfigurationsfel skickar inte om frågan automatiskt. Hemligheter kopieras aldrig till repot. Pianissimo installeras separat enligt driftguidens uttryckliga källsökvägar: endast låsta paketfiler/Python-kod går till `/opt/mio-transcription`, systemd-unit separat; hela Mio-repot eller utvecklingsmiljön ska inte kopieras.

## Verifiera före bygge

Linuxgrinden kör säkra lokala och syntetiska kontroller. Den publicerar ingenting och gör inga verkliga modellanrop. GitHub-workflowen **Verifiera Mio på Linux** (`.github/workflows/verify-linux.yml`) kör samma grind vid varje push i containern `swift:6.3.3-noble`; kontrollera resultatet för exakt den commit som ska byggas.

Lokalt krävs Linux, `python3`, `git`, Node **>=26.10.0 <27**, `npm`, `uv` och normalt `swiftc` (eller `SWIFT_EXECUTABLE`). Kommandot verifierar den arbetskopia där skriptet ligger:

```bash
mio_repo_directory="$(git rev-parse --show-toplevel)"
python3 "$mio_repo_directory/scripts/verify.py"
# valfritt: --logs-dir /tmp/mio-verification-<revision> --measure-session-store
```

| Grind | Täcker | Täcker inte |
|---|---|---|
| Struktur | Projektidentitet, targets, länkar, integritets-/konfigurationsregler, workflowinställningar | SwiftUI/iOS-bygge |
| Node och Worker | Gateway, adaptrar, routing, kvot, deadlines och det byggda Worker-paketet med fixtures | Nyckel, modellåtkomst, modellkvalitet, aktiv Access/D1 |
| Privat transkriptions-API | Låst Pythonmiljö, API/cache/deadline med fake-backend | Pianissimo, GPU, svensk kvalitet |
| Portable Swift, capture recovery, strikt concurrency | Modeller, actorpatchar, workflows, återhämtning | AVFoundation, Keychain, URLSession, UIKit/SwiftUI, iOS-filskydd |
| Långhistorik (valfri) | Syntetisk session-store: kodning, patchskrivning, processminne | iPhone, ljud, batteri |

Resultat: `PASS (Linux synthetic gates)`, `FAIL` (exitkod 1) eller `UNAVAILABLE` (exitkod 2). `--skip-swift` ger **PARTIAL**; det är ingen fullständig grind. Loggkatalogens `verification.json` registrerar bascommit, arbetskopians digest, verktygsversioner och grindstatus. Spara den med loggarna; den märker native iOS och verklig leverantör som `NOT RUN`.

Native: workflowen **Bygg Mio IPA** kör concurrencydiagnostik, Release, XCTest med tre UI-smokeprov och IPA-validering. På en Mac kan concurrencygrinden köras direkt med `python3 scripts/verify_concurrency.py --native --log /tmp/mio-native-concurrency.log`. Bevara loggar, `.xcresult`, körnings-URL och `Mio-buildinfo.txt`.

Gatewaypublicering och verkliga syntetiska modellanrop kräver var sitt uttryckligt godkännande. Loggar får bara innehålla textfri diagnostik; källtext, frågor, svar, råljud, tokens, fulla adresser och privata exporter hör inte hemma i loggar eller repo.
