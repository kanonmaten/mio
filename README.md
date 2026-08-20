# Mio · Fas 1

Det här är en privat, inbyggd iPhone-prototyp som svarar på den första avgörande frågan: kan hennes iPhone 13 lyssna länge, skapa svensk text lokalt och fortsätta när skärmen är låst utan orimlig batteriförbrukning?

## Det som är byggt

- Tydlig **Starta**, **Stoppa** och **Pausa** (30 minuter, 1 timme eller tills man startar igen).
- Apples lokala `SpeechTranscriber` används om svenska stöds.
- Automatisk lokal reservmotor med `DictationTranscriber` för iPhone/språk som inte stöds av den avancerade motorn.
- Reservmotorn använder långtidsläge med tätare finalisering, så Mio-detektion och lokal lagring inte behöver vänta till slutet av en lång inspelning.
- Fortsatt ljudsession i bakgrunden och med låst skärm via `UIBackgroundModes = audio`.
- Tidsstämplad svensk text som sparas lokalt mellan appstarter. Varje ljudbuffert får en explicit tidskod, så avbrott och tappade buffertar inte trycker ihop tidslinjen.
- Lokal detektion av det fristående ordet **Mio** och en diskret haptisk signal när appen är synlig.
- Batteriprov varje minut, appens bakgrundshändelser, ljudavbrott, ljudvägsändringar och tappade ljudbuffertar loggas.
- Apples integritetsmanifest deklarerar den monotona systemklocka som endast används för korrekta AVFAudio-tidsstämplar; själva upptiden exporteras aldrig.
- En tydlig bevislista i appen och export av hela testet som JSON.
- Permanent radering av all fas 1-data.
- Enhetstester för Mio-detektion, batteriberäkning och sessionsstatistik.

## Det som avsiktligt inte finns i fas 1

- Ingen OpenAI-nyckel och inga OpenAI-anrop.
- Ingen server eller användarinloggning.
- Mikrofonljud bearbetas tillfälligt i minnet, men inget råljud sparas som ljudfil.
- Ingen fullständig kalender, lektionsindelning, dagssammanfattning eller frågesvarsfunktion ännu.
- Ingen App Store- eller TestFlight-distribution.

Allt ovan är medvetet. Vi behöver först mäta Apples svenska motor, bakgrundsbeteende och batteri på den riktiga telefonen. Resultatet avgör arkitekturen för nästa fas.

## Börja här

### Om utvecklings-Macen kör Monterey

Följ [START_HAR_MONTEREY.md](START_HAR_MONTEREY.md). Den vägen använder GitHub Actions med Xcode 26 för molnbygget och AltStore Classic på Windows för kostnadsfri signering och installation.

### Om ni har en Mac som stöder Xcode 26

1. Läs [INSTALLERA_PA_IPHONE.md](docs/INSTALLERA_PA_IPHONE.md) från början till slut.
2. Installera och öppna appen på hennes iPhone.
3. Följ [TESTPLAN_FAS_1.md](docs/TESTPLAN_FAS_1.md).
4. Skapa testfilen i appen och spara den tills vi fortsätter.

OpenAI-planen finns i [OPENAI_SENARE.md](docs/OPENAI_SENARE.md). Kravspårningen finns i [KRAVMATRIS_FAS_1.md](docs/KRAVMATRIS_FAS_1.md).

## Tekniska krav

- iPhone med iOS 26 eller senare. Projektets deployment target är iOS 26.0 eftersom SpeechAnalyzer-API:erna introducerades där.
- Mac med en Xcode 26-version som stöder Macens macOS-version.
- Gratis Apple-konto räcker för direktinstallation via ett Personal Team.
- Första installationen måste byggas på en Mac. Windows kan inte signera eller installera en egen iOS-app.

## Projektstruktur

```text
MioPhaseOne.xcodeproj
MioPhaseOne/
  MioPhaseOneApp.swift
  ContentView.swift
  PhaseOneViewModel.swift
  Models/
  Services/
  Info.plist
  PrivacyInfo.xcprivacy
MioPhaseOneTests/
docs/
.github/workflows/build-unsigned-ipa.yml
START_HAR_MONTEREY.md
```

## Viktiga begränsningar att testa

- Apple publicerar ingen fast språklista för utvecklar-API:t. Appens kontroll på hennes iPhone är facit.
- Bakgrundsljud tillåter en användarstartad aktiv inspelning. iOS återstartar inte mikrofonen efter tvångsavslutning, omstart eller systemterminering.
- Under en tidsbestämd paus är mikrofonen verkligen av. Därför kan iOS försätta appen i vila; planerad fortsättning kan då ske först när appen öppnas igen. Appen säger detta uttryckligen.
- Byte av mikrofon, AirPods eller annan ljudväg loggas. Om texten stannar efter ett byte ska testet stoppas och startas om.

## Källor för de Apple-specifika valen

- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [Apples SpeechAnalyzer-exempel](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [AnalyzerInput med explicit starttid](https://developer.apple.com/documentation/speech/analyzerinput/init%28buffer%3Abufferstarttime%3A%29)
- [Bakgrundslägen i Xcode](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Hantering av ljudavbrott](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
