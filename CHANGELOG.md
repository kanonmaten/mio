# Ändringslogg

Användarsynliga ändringar och kompatibilitet per version. Versioner följer `vMAJOR.MINOR.PATCH`; [roadmapen](docs/ROADMAP.md) definierar milstolpar och släppkrav. Ingen ny Git-tagg eller release har skapats genom namnbytet.

## Helhetsbygge 0.9.0 — ej släppt

Efter användarbeslut 2026-09-25 byggs hela produkten tillsammans. Detta är en sammanhängande utvecklingskandidat, inte en telefonverifierad release.

- Lokal inkorg med redigerbara innehållsförslag och frågor, Ja/Nej/Inte nu och svenska Mio-kommandon. Stabilt godkännande-ID och skydd mot sen detektion efter radering.
- Redigerbar lektionsindelning över avslutade sessioner, med tidsval ned till sekunder och bevarade originalbevis.
- Bekräftade kalenderkopior via Apples editor, AlarmKit-alarm och lokala post-/morgon-/kvällspåminnelser. Privata posttexter visas inte på låsskärmen.
- Lokal morgon- och kvällsöversikt. Mer lättåtkomliga assistentfunktioner; teknisk diagnostik finns i expanderbara avsnitt.
- Valfri AI-klient och separat Node-server. Molnet är avstängt från början; exakt vald text visas före varje sändning. HTTPS, Keychain-gatewaytoken, serverägd OpenAI-nyckel, inga redirects eller automatiska omförsök.
- Nytt separat assistantlager; export schema 2 med bakåtkompatibel avkodning. Total radering omfattar nya lager, systemåtgärder och AI-konfiguration med gemensam skrivspärr.
- Nya XCTest-fall, serverns mocktester, portabel projektkontroll samt användar- och helhetstestguide.
- Ny appikon med standard-, mörk och tonad variant samt redigerbara SVG-original i `design/`.

Efter uppdaterat användarbeslut 2026-09-26 används appidentiteten `app.mio.assistant` och lagring under `Mio`; gammal fasmigrering har tagits bort. Första telefonprov sker på iPhone 16 Pro, senare iPhone 13. Native Liquid Glass tillagt i sessionskontrollerna med systemnavigation, semantiska läsytor och stöd för minskad rörelse. Användaren har godkänt commit, push och IPA-bygge; ingen servertjänst driftsätts och ingen release taggas. Faktiskt verifieringsläge dokumenteras i [status](docs/STATUS.md).

## v0.2.0 — ej släppt

### Tillagt sedan v0.1.0

- Fem flikar och fem manuella innehållstyper: tidslinjepost, anteckning, uppgift, plan och uttryckligt minne.
- Skapa, redigera, söka, radera och markera uppgifter klara; stabil lokal tidsordning.
- Koppla en post till en session. Lägg titel, anteckning och texträttningar på avslutade sessioner utan att ändra originalbevis.
- Separat versionsmärkt innehållslagring och gemensam JSON-export.
- Synlig status och separat installation av svensk `SpeechTranscriber`-resurs; direkt `DictationTranscriber`-fallback när resursen saknas.
- XCTest för modeller, lagring, migrering, export och Mio-detektion.

### Byggflöde 2026-09-25

- Ersatt separata Xcode 26.6- och Xcode 27-jobb med ett Xcode 27-jobb som bygger Release, kör XCTest på iOS 27-simulator och skapar osignerad IPA.
- Bygget kontrollerar iOS 27 SDK, appens lägsta iOS-version 26.0 och oförändrad bundle identifier i den byggda appen. iOS 26 och 27 behöver fortfarande provas på fysisk telefon.

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
