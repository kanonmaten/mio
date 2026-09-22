# Ändringslogg

Användarsynliga ändringar och kompatibilitet per version. Versioner följer `vMAJOR.MINOR.PATCH`; [roadmapen](docs/ROADMAP.md) definierar milstolpar och släppkrav. Ingen ny Git-tagg eller release har skapats genom namnbytet.

## v0.2.0 — ej släppt

### Tillagt sedan v0.1.0

- Fem flikar och fem manuella innehållstyper: tidslinjepost, anteckning, uppgift, plan och uttryckligt minne.
- Skapa, redigera, söka, radera och markera uppgifter klara; stabil lokal tidsordning.
- Koppla en post till en session. Lägg titel, anteckning och texträttningar på avslutade sessioner utan att ändra originalbevis.
- Separat versionsmärkt innehållslagring och gemensam JSON-export.
- Synlig status och separat installation av svensk `SpeechTranscriber`-resurs; direkt `DictationTranscriber`-fallback när resursen saknas.
- XCTest för modeller, lagring, migrering, export och Mio-detektion samt separat Xcode 27-previewkontroll.

### Städning 2026-09-22

- Ersatt utvecklingsfaser med v0.1.0–v0.5.0 och definierat vad som krävs för v1.0.0.
- Bytt projekt, mappar, modul, targets och scheme från `MioPhaseTwo` till `Mio`/`MioTests`; `MioApp.swift` och `ContentViews.swift` får beständiga namn.
- Satt appens versionsfält till `0.2.0` (tidigare `0.2`). Byggnumret är separat och fortfarande `1`.
- Byggfiler heter `Mio-unsigned.ipa`, `Mio-buildinfo.txt` och artifacten `Mio-IPA`.
- Nya sessionsexporter heter `Mio-session-*.json`. Radering känner fortfarande igen äldre exportnamn; Git ignorerar både gamla och nya.
- Samlat verifieringsläget i en statussida och båda installationsvägarna i en guide. Kortat introduktion, arbetsflöde och beslut; behållit detaljerade testfall och historiska mätvärden.
- Tagit bort interna utvecklingsfaser ur appens texter. Bygginformationen läser appversion och byggnummer från den byggda appen.

### Kompatibilitet och verifiering

Bundle identifier, lagringsvägar, JSON-schema och migreringsbeteende behålls. Namnbytet kräver ingen ny datamigrering. Bygg- och telefonresultat saknas för denna revision; följ [status](docs/STATUS.md) och [testplanen](docs/TESTPLAN_V0_2.md).

## v0.1.0 — historisk prototyp, telefonprov 2026-08-20

Versionsetiketten tilldelas i efterhand till den tidigare fas 1-prototypen; den påstår inte att en motsvarande Git-tagg, release eller exakt appversionssträng fanns.

- Lokal svensk transkription via `SpeechAnalyzer`, `DictationTranscriber`-fallback, Mio-detektion och paus/stopp.
- Sessionslagring, JSON-export, ljudtider, bakgrundsdiagnostik och batterimätning.
- Molnbyggd IPA installerades via SideStore. Ett 2 min 30 s långt iPhone 13-prov gav fem textsegment, två Mio-detektioner och inga rapporterade runtimefel eller tappade buffertar.
- `SpeechTranscriber`-resursen gick inte att installera i provet. Långa bakgrunds-, batteri-, avbrotts- och kvalitetsprov återstår.

Fullständiga observationer: [historiskt testresultat](docs/TESTRESULTAT_V0_1.md).
