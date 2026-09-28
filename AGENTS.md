# Mio – instruktioner för Codex

## Läs först

Läs [README](README.md), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md) och [status](docs/STATUS.md). Läs [datamodell](docs/DATAMODELL.md) vid lagringsarbete och relevant [testplan](docs/TESTPLAN_HELHET.md) eller [installation](docs/INSTALLATION.md) före ändringar.

## Produkt och version

- Privat SwiftUI-app för iOS 26+: första prov på iPhone 16 Pro, fortsatt mål även iPhone 13; lokal svensk transkription och en diskret vardagsassistent.
- **Helhetsbygge 0.9.0 är aktuellt, ej släppt.** Efter användarbeslut 2026-09-25 byggs hela produkten tillsammans; v0.1.0/v0.2.0 är historisk grund.
- Helheten har lokala poster/sessioner/förslag/lektioner, EventKitUI-kopior, AlarmKit och notiser samt valfri AI via egen server. AI är avstängd från början; den äldre OpenAI-gatewayen är publicerad. Arbetskopians nya leverantörsstöd och detaljerade lektionsanteckningar är inte publicerade eller Xcode-/telefonverifierade; verkliga modellprov återstår. Inget råljud sparas.
- Korttestet från 2026-08-20 gäller den äldre revisionen. Bygge, XCTest, installation och telefonresultat ska alltid hållas isär.

## Invarianter

- Projekt, target, scheme och Swift-modul heter `Mio`; tester heter `MioTests`. Namnen följer inte versionen.
- Appidentiteten är `app.mio.assistant` (tester `app.mio.assistant.tests`). Data ligger under `Mio/`: `content-v1.json`, `sessions.json`, `assistant-v1.json`. Användaren har raderat prototypen; ingen migrering av äldre fasvägar krävs. Namn innehåller inte personnamn eller appversion.
- Använd Apples native navigation, semantiska färger och Dynamic Type. Liquid Glass hör till kontroller/navigation; läsytor ska förbli tydliga. Prova mörkt läge, större text, Minska rörelse och Minska genomskinlighet.
- Rättningar är visningslager: ändra aldrig originaltranskription, ljudtider eller diagnostiskt bevis. Okända innehållsscheman får inte skrivas över.
- `SpeechAnalyzer` kör en transkriptionsmodul åt gången. Kontrollera svenskstöd med `supportedLocale(equivalentTo:)`, inte genom frånvaro i `installedLocales`. Om svenska stöds ska sessionsstart försöka installera saknad asset via `AssetInventory` innan analysen startar. Använd `DictationTranscriber` först vid saknat stöd eller ett verkligt installations-/förberedelsefel, med ny analyzer. Avbruten start får inte starta fallback. Logga tillgänglighet, resolved locale, svenska i supported/installedLocales, assetstatus och fallbackorsak. Byt inte till annat talramverk innan detta verifierats på mål-iPhonen.
- Lagra aldrig råljud. Commit aldrig privata exporter, inspelningar, pairing-filer, certifikat, Apple-uppgifter eller API-nycklar. Enskilda molnfrågor kräver sändningsgodkännande. Löpande analys kräver explicit aktiverat läge och använder enbart nya vardagsutdrag samt godkända lektioner; minsta kontext och serverägd nyckel gäller båda.
- AI-adaptrar ska kräva reasoning av (inte bara dold), temperatur 0 och leverantörens strikta JSON-schema. Ingen tyst parameter-/modellfallback. Katalogen i `server/src/provider.mjs` måste granskas vid nya modeller; ett providerprefix är inte bevis för stöd. Egna endpoints kräver explicit `chat-none-strict`-kontrakt. Alla svar, även enskilda frågor, valideras innan appen använder dem.
- Detaljerade lektioner använder `/v1/lesson-notes`: högst 3500 byte källtext per del, normalt minst 60 sekunder mellan anrop, sparade delar med källcitat och modell-/promptmetadata. Kopiering sammanställer delar lokalt; ofullständiga anteckningar måste märkas. Inga presentationer, frågekort eller extra AI-komprimering. Läxförslag kräver Ja. Äldre `highlights` får inte räknas som färdiga detaljerade anteckningar.
- Dokumentera krav på samtycke och lokala regler vid inspelning av andra.

## Arbetsrutin

- Sök aktuell officiell dokumentation före betydande tekniska beslut; för Apple/iOS, börja med Apple-dokumentation och WWDC. Jämför precision, batteri, latens, tillförlitlighet, integritet, kostnad, komplexitet och underhåll. Dokumentera val och bortval; markera enhetsberoende beteende som overifierat tills det provats. Gröna tester bevisar inte rätt arkitektur.
- Kontrollera `git status`, bevara orelaterade ändringar och håll ändringar avgränsade. Omorganisera inte Swift-kod för utseendets skull.
- Svenska i användartexter och projektdokument; engelska i Swift-identifierare och tekniska kodkommentarer. Kommentera främst icke uppenbara invarianten kring integritet, timing och samtidighet.
- Uppdatera [CHANGELOG](CHANGELOG.md) för relevanta ändringar. Ändra [STATUS](docs/STATUS.md) endast utifrån utförda kontroller; roadmap vid ändrad plan och beslut vid ändrad arkitektur.
- Bevara historiska mätvärden i `docs/TESTRESULTAT_V0_1.md`. Ändra inte dem utan verkligt nytt underlag.
- Commit, push, tagga eller publicera bara på uttrycklig begäran.

## Verifiering och överlämning

Linux/Windows kan inte bygga iOS-appen. Workflowen använder GitHubs `xcode-27`-runner för Release, XCTest och osignerad IPA i ett jobb. Runnern är en offentlig förhandsversion; kontrollera faktisk runnerstatus och byggresultat när ett bygge körs. SideStore signerar IPA:n lokalt.

Kör relevanta säkra statiska kontroller. Rapportera vad som ändrats, vad som faktiskt testats och nästa enhetsprov. Påstå aldrig att en revision är kompilerad, installerad eller telefonverifierad utan evidens för just den revisionen.
