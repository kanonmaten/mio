# Beslut och tekniska kontrakt

Gällande beslut samlade på ett ställe. [Ändringsloggen](../CHANGELOG.md) beskriver levererade ändringar; [status](STATUS.md) beskriver evidens.

| Beslut | Regel | Ursprung |
|---|---|---|
| Privat native-app | SwiftUI, iOS 26+, iPhone 13; ingen App Store-distribution | 2026-08-20 |
| Lokalt ljudflöde | `SpeechAnalyzer` tar emot tidsatta buffertar och kör en transkriptionsmodul åt gången | 2026-08-20 |
| Ingen råljudslagring | Ljud bara tillfälligt i minnet; text, tider och diagnostik lokalt | 2026-08-20 |
| Explicit molnsamtycke | Framtida OpenAI-fråga kräver Ja, minsta kontext och API-nyckel på server | 2026-08-20 |
| Privat installation | Actions bygger osignerad IPA; SideStore signerar. Lokal Mac/Xcode är ett alternativ | 2026-08-20 |
| Enkel Git-rutin | Lokala ändringar granskas före commit/push; privata exporter lämnar aldrig sin privata lagringsplats för repot | 2026-08-20 |
| Manuella funktioner kan utvecklas parallellt | v0.2.0 kräver inte att heldagslyssning är godkänd; öppna långtest kvarstår | 2026-08-24 |
| Separata datalager | Manuella poster och sessioner lagras separat; schema, export och migrering beskrivs i datamodellen | 2026-08-24 |
| Bevarade original | Sessionstitel, anteckning och texträttningar läggs ovanpå originaltext, tider och bevis | 2026-08-24 |
| Resurs före modulstart | `SpeechTranscriber` endast efter installerad svensk assetstatus; separat installationsknapp | 2026-08-24 |
| Omedelbar fallback | Ingen modellhämtning vid sessionsstart; saknad resurs ger `DictationTranscriber`. Förberedelsefel ger ny analyzer | 2026-08-24 |
| Inga externa integrationer i v0.2.0 | Ingen OpenAI, EventKit, systemalarm eller konto; Kalender och Morgon är lokala vyer | 2026-08-24 |
| Gemensamt Xcode 27-bygge | Ett jobb på `xcode-27` är konfigurerat för Release, XCTest och osignerad IPA med iOS 27 SDK och lägsta iOS-version 26.0 | 2026-09-25 |
| Beständiga namn och versioner | Projektet heter Mio; produktmilstolpar använder v0.x.y enligt roadmapen | 2026-09-22 |

## Kompatibilitet vid namnbytet

Den 24 augusti infördes tekniska namn under `MioPhaseTwo`. Den 22 september ersätts projekt-, target-, modul- och artifactnamnen med `Mio`. Följande värden ändras **inte**:

- `se.eyvin.MioPhaseOne`: samma appidentitet för installation över befintlig app.
- `MioPhaseTwo/content-v1.json` och `MioPhaseTwo/sessions.json`: befintliga lagringsvägar.
- `MioPhaseOne/sessions.json`: migreringskälla när aktuell sessionsfil saknas.
- `schemaVersion: 1`: dataversion, fristående från appversionen.

Nya sessionsexporter använder `Mio-session-`; radering och Git-ignore omfattar även `Mio-fas-1-` och `Mio-fas-2-session-`. Gemensam export fortsätter heta `Mio-lokal-export-`.

## Enheten är facit

Det historiska provet använde `DictationTranscriber` med `sv_SE`; den svenska `SpeechTranscriber`-resursen kunde inte installeras då. Ny resurslogik är inte verifierad av det provet. Bakgrund, batteri och ljudavbrott måste provas på telefonen; en simulator ersätter inte det.
