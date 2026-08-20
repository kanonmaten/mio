# Bygg- och teststatus

Senast uppdaterad: 20 augusti 2026.

## Sammanfattning

| Kontroll | Status |
|---|---|
| Statisk projektgranskning | Godkänd |
| GitHub Actions Release-build | Godkänd |
| arm64-IPA skapad och validerad | Godkänd |
| Signering och installation via SideStore | Godkänd |
| Kort telefonrökprov | Godkänt |
| XCTest-körning | Inte körd i nuvarande workflow |
| Långt bakgrunds-/batteritest | Återstår |

Den definitiva kompileringskontrollen är genomförd i GitHub Actions med Xcode 26.6. Den producerade IPA-filen installerades på iPhone 13 via SideStore och appen exporterade därefter ett giltigt fas 1-test.

## Verifierat i projektet

- `Info.plist`, workspace, shared scheme och `PrivacyInfo.xcprivacy` är XML-validerade.
- App-targeten innehåller 9 Swift-filer och test-targeten 2 Swift-filer.
- `UIBackgroundModes = audio` och mikrofonens användningstext finns.
- Integritetsmanifestet deklarerar systemets starttid med anledning `8FFB.1` för absoluta AVFAudio-tidsstämplar.
- Ingen `URLSession`, OpenAI-nyckel eller OpenAI-kod finns i fas 1.
- Ingen `AVAudioFile` används och inget råljud skrivs till fil.
- Varje `AnalyzerInput` får explicit starttid från mikrofonens monotona värdklocka.
- Endast resultat med giltig ljudtid som överlappar ett appbakgrundsintervall räknas som bakgrundsbevis.
- GitHub-workflowen bygger en osignerad arm64-IPA på `macos-26` och behåller artifacten i 14 dagar.

## Verifierat på iPhone 13

Det korta provet den 20 augusti 2026 visade:

- `SpeechTranscriber` kunde inte installera den avancerade svenska resursen.
- Fallback till `DictationTranscriber` med `sv_SE` startade korrekt.
- Fem finala textsegment skapades med giltig ljudtid.
- Mio upptäcktes två gånger, varav en gång i ett verkligt bakgrundsintervall.
- Noll runtimefel och noll rapporterade tappade buffertar.
- Paus tills manuell start stängde flödet; ingen text skapades efter pausen.
- Fem batteriprover låg kvar på 65 % utan laddare.

Detta var ett 2 minuter 30 sekunder långt rökprov. Se [TESTRESULTAT_FAS_1.md](TESTRESULTAT_FAS_1.md) för korrekt tolkning.

## Inte verifierat ännu

- Minst 10 minuter med telefonen uttryckligen låst.
- 60 minuters batteriförbrukning och ett senare 3–4-timmarstest.
- Avbrott och återstart efter alarm eller telefonsamtal.
- Tidsstyrd paus, appomstart, radering och haptisk feedback.
- Objektiv svensk transkriptionskvalitet mot ett känt facit i tyst och kontrollerat bullrig miljö.
- De två skrivna XCTest-filerna; nuvarande Actions-workflow gör Release-build men kör inget simulator-testjobb.

Nästa definitiva steg är alltså funktionstesterna på den fysiska telefonen enligt [TESTPLAN_FAS_1.md](TESTPLAN_FAS_1.md), inte ytterligare statisk bygggranskning.
