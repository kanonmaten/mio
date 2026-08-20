# Beslutslogg

Den här filen fångar beslut som nya Codex-tasks annars lätt skulle behöva gissa på.

## 2026-08-20 – Privat app

Mio byggs för en enda användare och ska inte publiceras i App Store i nuläget. En gratis personlig signering är tillräcklig under prototypfasen.

## 2026-08-20 – Native SwiftUI och iOS 26

Appen byggs i SwiftUI och använder Apples iOS 26-API:er. iPhone 13 med iOS 26 är den verkliga måltelefonen och facit för tillgänglighet och prestanda.

## 2026-08-20 – Lokal taligenkänning först

Heldagsljud ska inte skickas till OpenAI. Appen provar `SpeechTranscriber` och faller tillbaka till `DictationTranscriber` för svenska när det behövs.

Första enhetstestet visade att den avancerade svenska modellen inte kunde installeras (`transcription.sv`, status `Not Installing`). `DictationTranscriber` med `sv_SE` startade och fungerade. Arkitekturen ska därför behandla reservmotorn som den verifierade huvudvägen på den här telefonen tills ett senare test visar något annat.

## 2026-08-20 – Inget sparat råljud

Rått mikrofonljud får bearbetas tillfälligt i minnet men sparas inte som ljudfil. Fas 1 sparar enbart text, tidsdata, batteriprover och diagnostik.

## 2026-08-20 – Molnbygge på grund av Monterey

Utvecklings-Macen kan inte köra Xcode 26. GitHub Actions på `macos-26` är därför den auktoritativa byggmiljön och producerar en osignerad IPA.

## 2026-08-20 – SideStore för privat installation

SideStore med iLoader och LocalDevVPN används för personlig signering, installation och sjudagarsförnyelse. AltStore-flödet övergavs efter återkommande iCloud-komponentfel på Windows.

## 2026-08-20 – OpenAI endast efter uttryckligt Ja

OpenAI läggs till först efter att den lokala grunden är bevisad. API-nyckeln ska ligga på en server, aldrig i appen. En fråga skickas endast efter att användaren sett flödet och aktivt valt **Ja**.

## 2026-08-20 – En enkel Git-rutin

`main` används direkt så länge projektet har en aktiv utvecklare och förändringarna är små. Codex ändrar lokala filer; GitHub Desktop används för granskning, commit och push. Brancher införs först när parallella eller riskfyllda ändringar gör dem motiverade.

## 2026-08-20 – Testexporter stannar utanför repot

Exporterade Mio-sessioner kan innehålla privat tal och ska aldrig checkas in, inte ens i ett privat repository. Endast avidentifierade slutsatser och mätvärden dokumenteras i `docs/TESTRESULTAT_FAS_1.md`.
