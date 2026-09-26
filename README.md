# Mio

Privat SwiftUI-app för iOS 26+ (första testtelefon iPhone 16 Pro, senare även iPhone 13): lokal svensk transkription, anteckningar, planering och en diskret vardagsassistent. Ingen App Store-distribution.

**Aktuellt helhetsbygge: 0.9.0 — ej släppt.** Alla produktdelar utvecklas tillsammans efter beslutet 2026-09-25. Versionsnumret identifierar bygget; det är inte ett påstående om godkända telefonprov. [Status](docs/STATUS.md) skiljer kod, kontroller, Xcode och verklig användning åt.

## Funktioner

- **Native gränssnitt:** Liquid Glass för sessionskontroller, systemnavigation och flikar; semantiska läsytor, Dynamic Type och minskad rörelse.
- **Mio:** lokal transkription, paus/stopp, Mio-tilltal och förslag med **Ja / Nej / Inte nu**. Förslagen kan rättas innan de sparas.
- **Tidslinje:** manuellt innehåll, sessioner, separat rättad text och redigerbar lektionsindelning med bevarade original.
- **Kalender:** lokala planer och användarbekräftade kopior till Apple Kalender.
- **Anteckningar:** sökbara anteckningar, uppgifter och synliga uttryckliga minnen.
- **Morgon/Kväll:** lokal dagsöversikt, avklarade uppgifter, sessioner och lektioner; separata dagliga notiser.
- **Alarm och påminnelser:** AlarmKit-alarm, återkommande veckodagar och lokala notiser. Behörigheter begärs först när du sparar en systemåtgärd.
- **Valfri AI:** fråga via din egen server, manuellt vald kontext och exakt förhandsgranskning före varje sändning. Avstängt från början. OpenAI-nyckeln finns endast på servern.
- Lokal versionsmärkt JSON-export och radering av appdata, egna alarm/notiser och AI-konfiguration. Inget råljud sparas.

Lokala förslag bygger på tydliga svenska kommandon, inte allmän förståelse av samtal. Datum i fri text måste kontrolleras manuellt. Dagsöversikten visar sparade data; den påstår sig inte sammanfatta en lektion med AI.

## Kom igång

1. Läs [användarguiden](docs/ANVANDNING.md).
2. Bygg och installera enligt [installation](docs/INSTALLATION.md). Linux kan inte bygga iOS-appen.
3. Kör [helhetstestet](docs/TESTPLAN_HELHET.md) med syntetiska data före vardagsanvändning.
4. Om du vill använda moln-AI: följ [serverguiden](server/README.md). Appens lokala funktioner kräver ingen server.

## Utveckling

Öppna `Mio.xcodeproj`, välj schemat **Mio**. Appkod finns i `Mio/`, XCTest i `MioTests/` och servern i `server/`. Kör `python3 scripts/verify_project.py` för säkra projektkontroller och `npm test --prefix server` för serverns tester. Xcode/SDK-verifiering sker i `.github/workflows/build-unsigned-ipa.yml`.

Läs [AGENTS](AGENTS.md), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md), [datamodell](docs/DATAMODELL.md) och [ändringslogg](CHANGELOG.md). Commit, push och publicering kräver uttrycklig begäran.

## Integritet och kompatibilitet

Lyssningen startas av dig. Spela bara in andra med tydligt samtycke och enligt lokala regler. Exporter kan innehålla känslig text och ska förvaras privat utanför repot. Kalenderkopior kan synkas via ditt kalenderkonto; molnfrågor skickas bara efter ditt godkännande.

Appidentiteten är `app.mio.assistant`; lagringen ligger i `Mio/content-v1.json`, `Mio/sessions.json` och `Mio/assistant-v1.json`. Det är en ren installation utan migrering från prototyperna. Projekt, target, scheme och produkt heter **Mio**; versionsnumret ligger separat i Xcode.
