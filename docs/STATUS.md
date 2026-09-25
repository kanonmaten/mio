# Bygg- och teststatus

Senast uppdaterad: 2026-09-25. Aktuell utvecklingsversion: **v0.2.0, ej släppt**.

Detta är den gemensamma statuskällan. [Ändringsloggen](../CHANGELOG.md) beskriver innehållet, [roadmapen](ROADMAP.md) beskriver planerna och testplanerna beskriver hur beteendet verifieras.

| Kontroll | v0.1.0, historiskt prov 2026-08-20 | v0.2.0, aktuell arbetskopia |
|---|---|---|
| Källkod | Transkriptionsprototyp | Lokal manuell MVP och namn-/dokumentstädning |
| Statisk kontroll | Historiskt godkänd | Se lokal kontroll nedan |
| Xcode / Release / IPA | Historiskt byggd i Actions | Ett `xcode-27`-jobb är konfigurerat; ingen verifierad körning för denna revision |
| XCTest | Ingen dokumenterad körning | iOS 27-simulator är konfigurerad; testkod finns men är ej körd för denna revision |
| Installation | SideStore på iPhone 13 | Ej verifierad för denna revision |
| Telefonprov | 2 min 30 s; begränsad evidens | Test A–M återstår |
| Långtest | Återstår | Återstår även som regression |

## Lokal kontroll av städningen

Godkänt på Linux 2026-09-22: lokala dokumentlänkar; Xcode-projektets filreferenser och Swift-källfiler i targets; scheme och produktnamn; plist/XML; workflow-YAML och inbäddad Bash-syntax; versionsfält och oförändrad appidentitet; bevarade lagringsvägar; nya och äldre exportprefix i radering och Git-ignore; oförändrade historiska telefonmätvärden; whitespace i diff och nya filer.

Detta är statisk kontroll, inte Swift-kompilering eller XCTest. Inga iPhone-resultat har tillkommit.

## Lokal kontroll av Xcode 27-flödet

Godkänt på Linux 2026-09-25: workflow-YAML kan parsas och innehåller exakt ett `xcode-27`-jobb; alla inbäddade Bash-steg klarar syntaxkontroll; simulatorfiltret väljer iOS 27 framför iOS 26 i ett kontrollerat JSON-exempel; Xcode-projektet behåller lägsta iOS-version 26.0 och bundle identifier `se.eyvin.MioPhaseOne`; `git diff --check` är utan anmärkning.

Workflowen kontrollerar den byggda appens iOS-minimum och bundle identifier innan IPA:n laddas upp. Detta är ännu inte provat i GitHub Actions. Varken IPA eller funktion på iOS 26/27 är verifierad av den lokala kontrollen.

## v0.2.0: tester som återstår

| Test | Område | Resultat |
|---|---|---|
| A | Uppgradering och bevarad äldre sessionsdata | Ej körd |
| B | Fem flikar och navigering | Ej körd |
| C | Fem manuella typer och rubrikvalidering | Ej körd |
| D | Redigering, uppgiftsstatus, ordning och persistens | Ej körd |
| E–F | Sessionskoppling, rättningar och bevarat originalbevis | Ej körda |
| G | Svensk sökning | Ej körd |
| H | Versionsmärkt gemensam export | Ej körd |
| I | Enskild och total radering | Ej körd |
| J | Offline och avsaknad av externa integrationer | Ej körd |
| K | Modellinstallation, analyzer och fallback | Ej körd |
| L | Mikrofon, paus och transkriptionsregression | Ej körd |
| M | Dynamic Type och VoiceOver | Ej körd |

Utförliga steg och godkännandekriterier finns i [testplan v0.2](TESTPLAN_V0_2.md). XCTest täcker modeller, svensk sökning, tidsordning, äldre sessionsdata, migrering, lagring, okänd schemaversion, export och Mio-detektion. Befintliga testfiler är inte körbevis.

## Historisk evidens och öppna begränsningar

[Telefonprovet 2026-08-20](TESTRESULTAT_V0_1.md) verifierade `DictationTranscriber` med `sv_SE`, fem textsegment och två Mio-detektioner. Endast elva sekunders bakgrund finns dokumenterat. Det bevisar varken låst skärm under lång tid, batteriförbrukning under en timme eller aktuell versions funktion.

`SpeechTranscriber`-installation, stabil bakgrundsdrift, ljudavbrott och uppgradering av verklig appdata kräver fysisk telefon. Ett ljudvägsbyte kan kräva stopp/start. iOS återstartar inte lyssning efter tvångsavslutning; tidsstyrd paus kan kräva att appen öppnas igen.

## Registrera nya resultat

Ange **commit, Actions-URL, IPA-kontrollsumma, appversion/byggnummer, iPhone-modell, iOS-version, test-ID, observation och resultat**. Använd Godkänd, Underkänd, Blockerad eller Ej körd. Spara bara avidentifierade slutsatser här; råexporter förvaras privat. En ny revision är inte verifierad av ett äldre grönt resultat.
