# Mio · fas 1

Mio är en privat iPhone-prototyp som undersöker om en iPhone 13 kan skapa svensk text lokalt under en längre, användarstartad session och fortsätta när appen ligger i bakgrunden eller skärmen är låst — utan orimlig batteriförbrukning.

## Aktuell status

| Del | Status |
|---|---|
| Molnbygge med Xcode 26 | Godkänt i GitHub Actions |
| Installation på iPhone 13 | Godkänd via SideStore |
| Svensk lokal motor | `DictationTranscriber` med `sv_SE` fungerar |
| Avancerad svensk motor | Modelltillgången misslyckades; fallback används |
| Kort bakgrundstest | Godkänt med giltig ljudtid |
| Långt bakgrunds- och batteritest | Återstår |
| OpenAI | Inte inkluderat i fas 1 |

Det första telefonprovet var 2 minuter 30 sekunder. Det bevisar att kärnvägen fungerar, men är för kort för att godkänna heldagsidén. Se [testresultatet](docs/TESTRESULTAT_FAS_1.md) och [testplanen](docs/TESTPLAN_FAS_1.md).

## Det som är byggt

- Tydlig **Starta**, **Stoppa** och **Pausa**.
- Apples lokala `SpeechTranscriber` när den är tillgänglig.
- Automatisk svensk reservmotor med `DictationTranscriber`.
- Fortsatt användarstartad ljudsession via `UIBackgroundModes = audio`.
- Tidsstämplad text som sparas lokalt mellan appstarter.
- Lokal detektion av det fristående ordet **Mio**.
- Batteriprover, bakgrundshändelser, ljudavbrott, ljudvägsändringar och tappade buffertar i diagnostiken.
- Export av testet som JSON och permanent radering av appens lokala fas 1-data.
- Integritetsmanifest och filskydd för den lokala testdatan.
- Enhetstester för Mio-detektion och sessionsstatistik.

## Det som avsiktligt inte finns i fas 1

- Ingen OpenAI-nyckel, server eller nätverksbaserad AI.
- Ingen användarinloggning.
- Inget sparat råljud; mikrofonbuffertar bearbetas tillfälligt i minnet.
- Ingen fullständig kalender, lektionsindelning, dagssammanfattning eller frågesvarsfunktion.
- Ingen App Store- eller TestFlight-distribution.

## Börja här

- Ny Codex-task eller ny utvecklare: läs [AGENTS.md](AGENTS.md) och [arbetsflödet](docs/WORKFLOW.md).
- Förstå slutmålet: läs [produktvisionen](docs/PRODUKTVISION.md).
- Se prioriteringarna: läs [roadmapen](docs/ROADMAP.md) och [beslutsloggen](docs/DECISIONS.md).
- Bygga på Monterey/Windows och installera via SideStore: följ [START_HAR_MONTEREY.md](START_HAR_MONTEREY.md).
- Installera direkt från Xcode på en modern Mac: använd [Xcode-alternativet](docs/INSTALLERA_PA_IPHONE.md).
- Testa telefonen: följ [TESTPLAN_FAS_1.md](docs/TESTPLAN_FAS_1.md).
- Se teknisk status: läs [BYGGSTATUS.md](docs/BYGGSTATUS.md).
- Förstå en framtida OpenAI-integration: läs [OPENAI_SENARE.md](docs/OPENAI_SENARE.md).

## Bygg- och installationsvägar

### Använd väg: GitHub Actions + SideStore

Den lokala Macen kör Monterey och kan inte köra Xcode 26. Koden pushas därför till det privata GitHub-repot, GitHub Actions kompilerar med Xcode 26.6 och SideStore signerar den osignerade IPA-filen med ett personligt Apple-konto på telefonen.

En modern Mac behövs inte lokalt för denna väg. Windows kör inte Xcode men används för GitHub Desktop och SideStores första iLoader-installation.

### Alternativ: direkt från Xcode

En Mac som stöder en Xcode 26-version kan bygga, signera och installera projektet direkt på telefonen med ett kostnadsfritt Personal Team.

## Projektstruktur

```text
.github/workflows/           Molnbygget
MioPhaseOne.xcodeproj/       Xcode-projektet
MioPhaseOne/                 Appkod och integritetsfiler
  Models/
  Services/
MioPhaseOneTests/            Enhetstester
docs/                        Vision, beslut, workflow, status och tester
AGENTS.md                    Varaktig kontext för Codex
START_HAR_MONTEREY.md        GitHub Actions + SideStore
```

Exporterade `Mio-fas-1-*.json`, IPA-filer, pairing-filer, certifikat och hemligheter hör aldrig hemma i repot. `.gitignore` blockerar de vanligaste filtyperna.

## Viktiga begränsningar

- Apple publicerar ingen fast utvecklar-API-lista som kan ersätta kontrollen på telefonen. Den verkliga enheten är facit.
- Bakgrundsljud kan hålla en användarstartad session aktiv. iOS återstartar inte mikrofonen efter tvångsavslutning, omstart eller systemterminering.
- En tidsstyrd paus stänger mikrofonen. iOS kan då vila appen, så fortsatt lyssning kan kräva att appen öppnas igen.
- Ett ljudvägsbyte kan ändra mikrofonformatet. Fas 1 loggar bytet; stoppa och starta om testet om texten upphör.
- Ingen ska spelas in utan tydligt tillstånd och utan att skolans, arbetsplatsens och lagens regler följs.

## Apple-källor för kärnarkitekturen

- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [Apples SpeechAnalyzer-exempel](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [AnalyzerInput med explicit starttid](https://developer.apple.com/documentation/speech/analyzerinput/init%28buffer%3Abufferstarttime%3A%29)
- [Bakgrundslägen i Xcode](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Hantering av ljudavbrott](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
