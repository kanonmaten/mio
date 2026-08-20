# Byggstatus

Status den 20 augusti 2026:

- Projektstruktur: statiskt kontrollerad.
- `Info.plist`, workspace och shared scheme: XML-validerade.
- Xcode-objekt: alla referenser definierade och alla objekt-ID:n giltiga 24-teckens hexvärden.
- Target membership: 9 Swift-filer i app-target och 2 Swift-filer i test-target.
- Bakgrundsljud: `UIBackgroundModes = audio` och Xcode capability markerad.
- Mikrofontext: `NSMicrophoneUsageDescription` finns.
- Integritetsmanifest: `PrivacyInfo.xcprivacy` är XML-validerat och deklarerar systemets starttid med Apples anledning `8FFB.1` för absoluta AVFAudio-tidsstämplar.
- OpenAI/nätverk: ingen `URLSession`, API-nyckel eller OpenAI-kod i app-target.
- Råljudsfiler: ingen `AVAudioFile` och ingen ljudfil skrivs.
- Ljudtidslinje: varje `AnalyzerInput` får explicit starttid från mikrofonens monotona värdklocka; avbrott och tappade buffertar bevaras som tidsluckor.
- Bakgrundsbevis: endast resultat med giltig ljudtid som överlappar ett registrerat bakgrundsintervall räknas som godkänt.
- Oberoende Swift-, Xcode- och kravgranskningar utförda; deras P1-fynd har arbetats in.
- Ljudbuffertar lämnas från Apples realtids-tap till konverteringsuppgiften enligt samma grundmönster som Apples SpeechAnalyzer-exempel. Eftersom `AVAudioPCMBuffer` inte formellt är `Sendable` måste ett långt stresstest på telefonen fortfarande kontrollera att inga ljudglapp eller korrupta segment uppstår.
- Monterey-alternativ: `.github/workflows/build-unsigned-ipa.yml` bygger en osignerad arm64-IPA på GitHubs `macos-26`-runner med Xcode 26.6, validerar IPA:n och publicerar den som en tillfällig artifact.
- Den separata guiden `START_HAR_MONTEREY.md` täcker privat GitHub-repository, molnbygge, AltStore på Windows, Utvecklarläge, certifikattillit, mikrofon, förnyelse och första telefonprovet.

Det som inte går att göra på byggdatorn:

- Den här arbetsmiljön är Windows och har inte Xcode eller Apples iOS-SDK.
- Projektet är därför inte kompilerat med `xcodebuild` här.
- GitHub-arbetsflödet kan inte köras förrän användaren har laddat upp projektet till sitt privata repository och tryckt **Run workflow**. Den första gröna körningen blir den definitiva molnkompileringen.
- Enhetstesterna är skrivna men kan först köras i Xcode 26 på en Mac.
- Mikrofon, svensk modell, låst skärm, ljudavbrott och batteri kan bara slutverifieras på den riktiga iPhone 13.

Första definitiva byggverifieringen är **Product > Build** eller `⌘B` på Macen. Om Xcode visar ett fel: kopiera den första röda felraden och Xcode-versionen. Fortsätt inte att felsöka alla följdfel samtidigt.
