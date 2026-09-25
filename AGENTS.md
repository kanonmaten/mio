# Mio – instruktioner för Codex

## Läs först

Läs [README](README.md), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md) och [status](docs/STATUS.md). Läs [datamodell](docs/DATAMODELL.md) vid lagringsarbete och relevant [testplan](docs/TESTPLAN_V0_2.md) eller [installation](docs/INSTALLATION.md) före ändringar.

## Produkt och version

- Privat SwiftUI-app för iPhone 13/iOS 26+: lokal svensk transkription och en diskret vardagsassistent.
- **v0.2.0 är aktuell, ej släppt.** v0.1.0 är den historiska transkriptionsprototypen. Versioner ersätter tidigare fasnamn.
- v0.2.0 har manuella poster och sessioner; ingen OpenAI-, EventKit-, alarm- eller kontointegration. Inget råljud sparas.
- Korttestet från 2026-08-20 gäller den äldre revisionen. Bygge, XCTest, installation och telefonresultat ska alltid hållas isär.

## Invarianter

- Projekt, target, scheme och Swift-modul heter `Mio`; tester heter `MioTests`. Namnen följer inte versionen.
- Behåll `se.eyvin.MioPhaseOne` som appens bundle identifier och `MioPhaseTwo/content-v1.json`, `MioPhaseTwo/sessions.json` som lagringsvägar. Äldre `MioPhaseOne/sessions.json` migreras bara när den aktuella filen saknas. Dessa namn är beständiga kompatibilitetsvärden.
- Rättningar är visningslager: ändra aldrig originaltranskription, ljudtider eller diagnostiskt bevis. Okända innehållsscheman får inte skrivas över.
- `SpeechAnalyzer` kör en transkriptionsmodul åt gången. Välj `SpeechTranscriber` endast med installerad svensk asset; annars direkt `DictationTranscriber` med `sv_SE`. Sessionsstart får inte starta modellhämtningen. Vid förberedelsefel används en ny analyzer för fallback.
- Lagra aldrig råljud. Commit aldrig privata exporter, inspelningar, pairing-filer, certifikat, Apple-uppgifter eller API-nycklar. Framtida molnfrågor kräver uttryckligt godkännande, minsta kontext och serverägd nyckel.
- Dokumentera krav på samtycke och lokala regler vid inspelning av andra.

## Arbetsrutin

- Kontrollera `git status`, bevara orelaterade ändringar och håll ändringar avgränsade. Omorganisera inte Swift-kod för utseendets skull.
- Svenska i användartexter och projektdokument; engelska i Swift-identifierare och tekniska kodkommentarer. Kommentera främst icke uppenbara invarianten kring integritet, timing och samtidighet.
- Uppdatera [CHANGELOG](CHANGELOG.md) för relevanta ändringar. Ändra [STATUS](docs/STATUS.md) endast utifrån utförda kontroller; roadmap vid ändrad plan och beslut vid ändrad arkitektur.
- Bevara historiska mätvärden i `docs/TESTRESULTAT_V0_1.md`. Ändra inte dem utan verkligt nytt underlag.
- Commit, push, tagga eller publicera bara på uttrycklig begäran.

## Verifiering och överlämning

Linux/Windows kan inte bygga iOS-appen. Workflowen använder GitHubs `xcode-27`-runner för Release, XCTest och osignerad IPA i ett jobb. Runnern är en offentlig förhandsversion; kontrollera faktisk runnerstatus och byggresultat när ett bygge körs. SideStore signerar IPA:n lokalt.

Kör relevanta säkra statiska kontroller. Rapportera vad som ändrats, vad som faktiskt testats och nästa enhetsprov. Påstå aldrig att en revision är kompilerad, installerad eller telefonverifierad utan evidens för just den revisionen.
