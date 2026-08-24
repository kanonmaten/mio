# Mio · fas 2

Mio är en privat iPhone-app för en användare. Fas 2 bygger vidare på den lokala svenska transkriptionen med en manuell MVP för tidslinje, anteckningar, uppgifter, lokala planer och uttryckliga minnen. Allt innehåll stannar lokalt om användaren inte själv delar en export.

## Aktuell status

| Del | Status |
|---|---|
| Fas 1, kort telefonrökprov | Godkänt den 20 augusti 2026 på den då byggda revisionen |
| Fas 1, långt bakgrunds-, batteri- och avbrottstest | Återstår |
| Fas 2, implementation i källkod | Finns i lokal arbetskopia |
| Fas 2, statisk Windows-granskning | Godkänd inom miljöns gränser |
| Fas 2, Xcode-kompilering och XCTest | Inte körda ännu |
| Fas 2, GitHub Actions och ny IPA | Inte körda ännu |
| Fas 2, installation och iPhone-test | Inte genomförda ännu |
| OpenAI, EventKit och systemalarm | Inte inkluderade i fas 2 |

Det första telefonprovet var 2 minuter 30 sekunder. Det bevisar den korta fas 1-kärnvägen men är för kort för att godkänna heldagsidén. Fas 2 utvecklas parallellt utan att fas 1 markeras som slutgodkänd. Se [fas 1-resultatet](docs/TESTRESULTAT_FAS_1.md), [fas 2-statusen](docs/TESTRESULTAT_FAS_2.md) och [roadmapen](docs/ROADMAP.md).

## Fas 2 i arbetskopian

- Fem flikar: **Mio**, **Tidslinje**, **Kalender**, **Anteckningar** och **Morgon**.
- En gemensam lokal modell för tidslinjepost, anteckning, uppgift, plan och uttryckligt minne.
- Manuell skapa, redigera, söka, slutföra uppgift och radera.
- Lokal, stabil tidsordning och valfri koppling mellan en manuell post och en transkriptionssession.
- Sessionstitel, manuell sessionsanteckning och korrigerad visningstext utan att originaltext eller ljudtider skrivs över.
- Versionsmärkt lagring i `MioPhaseTwo/content-v1.json` och `MioPhaseTwo/sessions.json`; om den nya sessionsfilen saknas flyttas en äldre `MioPhaseOne/sessions.json` säkert vid första läsningen.
- Gemensam versionsmärkt JSON-export med manuellt innehåll och sessioner.
- `SpeechAnalyzer` tar emot de tidsatta ljudbuffertarna och kör en transkriptionsmodul åt gången; det är analysmotorn, inte en tredje språkmodell.
- `SpeechTranscriber` med sin nyare lokala modell provas först när den svenska asseten har verifierats som installerad. `DictationTranscriber` med `sv_SE` finns kvar som den verifierade kompatibilitetsfallbacken från fas 1.
- `AssetInventory` visar, reserverar och installerar assetar för modulerna. En separat installationsknapp kan förbereda `SpeechTranscriber` före sessionsstart.

Detta är en beskrivning av källkoden, inte ett påstående om att den nya revisionen kompilerar eller fungerar på iPhone. Följ [kravmatrisen](docs/KRAVMATRIS_FAS_2.md) och [testplanen](docs/TESTPLAN_FAS_2.md) för verifiering.

## Avsiktligt utanför fas 2

- Ingen OpenAI-nyckel, server, inloggning eller nätverksbaserad AI.
- Ingen EventKit-koppling eller skrivning till systemkalendern.
- Inga systemalarm, automatiska morgonöversikter eller kvällssammanfattningar.
- Ingen automatisk tolkning som skapar planer, uppgifter eller minnen utan bekräftelse.
- Inget sparat råljud; mikrofonbuffertar bearbetas endast tillfälligt i minnet.
- Ingen App Store- eller TestFlight-distribution.

## Börja här

- Ny Codex-task eller ny utvecklare: läs [AGENTS.md](AGENTS.md) och [arbetsflödet](docs/WORKFLOW.md).
- Förstå slutmålet: läs [produktvisionen](docs/PRODUKTVISION.md).
- Se prioriteringarna och besluten: läs [ROADMAP.md](docs/ROADMAP.md) och [DECISIONS.md](docs/DECISIONS.md).
- Förstå lagring och export: läs [DATAMODELL_FAS_2.md](docs/DATAMODELL_FAS_2.md).
- Se verifieringsläget: läs [BYGGSTATUS.md](docs/BYGGSTATUS.md), [KRAVMATRIS_FAS_2.md](docs/KRAVMATRIS_FAS_2.md) och [TESTRESULTAT_FAS_2.md](docs/TESTRESULTAT_FAS_2.md).
- Bygga på Monterey/Windows och installera via SideStore: följ [START_HAR_MONTEREY.md](START_HAR_MONTEREY.md).
- Installera direkt från Xcode på en modern Mac: använd [INSTALLERA_PA_IPHONE.md](docs/INSTALLERA_PA_IPHONE.md).
- Testa fas 2: följ [TESTPLAN_FAS_2.md](docs/TESTPLAN_FAS_2.md).
- Slutföra fas 1-proven: följ [TESTPLAN_FAS_1.md](docs/TESTPLAN_FAS_1.md).
- Förstå en senare OpenAI-integration: läs [OPENAI_SENARE.md](docs/OPENAI_SENARE.md).

## Bygg- och installationsvägar

### Huvudväg: GitHub Actions + SideStore

Den lokala Macen kör Monterey och kan inte köra Xcode 26. Koden pushas därför till det privata GitHub-repot, GitHub Actions kompilerar med Xcode 26.6, kör XCTest i en iOS 26-simulator och bygger IPA:n. SideStore signerar sedan den osignerade IPA-filen med ett personligt Apple-konto på telefonen.

En modern Mac behövs inte lokalt för denna väg. Windows kör inte Xcode men används för GitHub Desktop och SideStores första iLoader-installation.

### Alternativ: direkt från Xcode

En Mac som stöder en Xcode 26-version kan bygga, signera och installera projektet direkt på telefonen med ett kostnadsfritt Personal Team.

## Projektstruktur

```text
.github/workflows/           Molnbygget
MioPhaseTwo.xcodeproj/       Xcode-projektet
MioPhaseTwo/                 Appkod, lokala modeller och integritetsfiler
  Models/
  Services/
MioPhaseTwoTests/            Automatiska tester
docs/                        Vision, beslut, datamodell, status och testplaner
AGENTS.md                    Varaktig kontext för Codex
START_HAR_MONTEREY.md        GitHub Actions + SideStore
```

Projekt, appmapp, testmapp, target, scheme, produkt och artifacts heter nu `MioPhaseTwo`. Appens användarnamn är fortfarande **Mio**. Bundle identifier är avsiktligt kvar som `se.eyvin.MioPhaseOne`, eftersom den identifierar den redan installerade appen och dess lokala container.

Exporterade `Mio-fas-1-*.json`, `Mio-fas-2-session-*.json`, `Mio-lokal-export-*.json`, IPA-filer, pairing-filer, certifikat och hemligheter hör aldrig hemma i repot.

## Viktiga begränsningar

- Den verkliga iPhone 13 är facit för Apple-API:er, modellassetar, bakgrundsbeteende och prestanda.
- Bakgrundsljud kan hålla en användarstartad session aktiv. iOS återstartar inte mikrofonen efter tvångsavslutning, omstart eller systemterminering.
- En tidsstyrd paus stänger mikrofonen. iOS kan då vila appen, så fortsatt lyssning kan kräva att appen öppnas igen.
- Ett ljudvägsbyte kan ändra mikrofonformatet. Stoppa och starta om sessionen om texten upphör.
- `SpeechTranscriber` får inte startas i `SpeechAnalyzer` förrän `AssetInventory` rapporterar att modulens svenska asset är installerad. Vid fel förbereds en ny `SpeechAnalyzer` med `DictationTranscriber`.
- Ingen ska spelas in utan tydligt tillstånd och utan att skolans, arbetsplatsens och lagens regler följs.

## Apple-källor för kärnarkitekturen

- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [Apples SpeechAnalyzer-exempel](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [AnalyzerInput med explicit starttid](https://developer.apple.com/documentation/speech/analyzerinput/init%28buffer%3Abufferstarttime%3A%29)
- [Bakgrundslägen i Xcode](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Hantering av ljudavbrott](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
