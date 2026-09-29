# Mio

Privat SwiftUI-app för iOS 26+ (första testtelefon iPhone 16 Pro, senare även iPhone 13): lokal svensk transkription, anteckningar, planering och en diskret vardagsassistent. Ingen App Store-distribution.

**Aktuellt helhetsbygge: 0.9.0 — ej släppt.** Nya AI-/lektionsändringar i arbetskopian är ännu inte Xcode-byggda eller publicerade; den befintliga build 5 innehåller dem inte. Alla produktdelar utvecklas tillsammans efter beslutet 2026-09-25. Versionsnumret identifierar bygget; det är inte ett påstående om godkända telefonprov. [Status](docs/STATUS.md) skiljer kod, kontroller, Xcode och verklig användning åt.

## Funktioner

- **Native gränssnitt:** Liquid Glass för sessionskontroller, systemnavigation och flikar; semantiska läsytor, Dynamic Type och minskad rörelse.
- **Mio:** lokal transkription, paus/stopp, Mio-tilltal och förslag med **Ja / Nej / Inte nu**. Förslagen kan rättas innan de sparas.
- **Lektioner:** separat Starta lektion-knapp pausar vardags-Mio. AI kan skriva detaljerade, kopierbara anteckningar efter avslut, med separata läxförslag. Färdiga delar sparas för manuell fortsättning efter avbrott. Äldre sessioner, manuella tidsintervall och råtext finns under Historik och råtext.
- **Kalender:** lokala planer och användarbekräftade kopior till Apple Kalender.
- **Anteckningar:** sökbara anteckningar, uppgifter och synliga uttryckliga minnen.
- **Morgon/Kväll:** lokal dagsöversikt, avklarade uppgifter, sessioner och lektioner; separata dagliga notiser.
- **Alarm och påminnelser:** AlarmKit-alarm, återkommande veckodagar och lokala notiser. Behörigheter begärs först när du sparar en systemåtgärd.
- **Valfri AI:** aktivera löpande analys av nya textutdrag för planer/uppgifter utan Mio-tilltal, eller ställ en enskild fråga med förhandsgranskning. Av vid appstart. Byt kompatibel modell/leverantör på servern enligt [bytesguiden](server/PROVIDERS.md); nyckeln finns endast på servern. Reasoning av, temperatur 0 och strikt schema krävs.
- Lokal versionsmärkt JSON-export och radering av appdata, egna alarm/notiser och AI-konfiguration. Inget råljud sparas.

Utan AI används en enkel lokal kommandogrammatik. Med aktiverad AI kan även vanligt samtal ge förslag; innehåll och tider måste granskas. Lektionsanteckningar är källkopplade AI-utkast från textdelar, inte en garanti för fullständig sammanfattning. [Status](docs/STATUS.md) skiljer det tidigare bygget från dessa rättningar.

## Kom igång

1. Läs [användarguiden](docs/ANVANDNING.md).
2. Bygg och installera enligt [installation](docs/INSTALLATION.md). Linux kan inte bygga iOS-appen.
3. Kör [helhetstestet](docs/TESTPLAN_HELHET.md) med syntetiska data före vardagsanvändning.
4. Om du vill använda moln-AI: följ [Groq, åtkomsttoken och Access steg för steg](server/cloudflare/GROQ_ACCESS.md) för befintlig Worker eller [Cloudflare-grundinstallationen](server/cloudflare/README.md) för drift utan påslagen dator, eller [serverguiden](server/README.md) för egen värd. Appens lokala funktioner kräver ingen server.

## Utveckling

Öppna `Mio.xcodeproj`, välj schemat **Mio**. Appkod finns i `Mio/`, XCTest i `MioTests/` och servern i `server/`. Kör `python3 scripts/verify_project.py` för säkra projektkontroller och `npm test --prefix server` för serverns tester. Xcode/SDK-verifiering sker i `.github/workflows/build-unsigned-ipa.yml`.

Läs [AGENTS](AGENTS.md), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md), [datamodell](docs/DATAMODELL.md) och [ändringslogg](CHANGELOG.md). Commit, push och publicering kräver uttrycklig begäran.

## Integritet och kompatibilitet

Lyssningen startas av dig. Spela bara in andra med tydligt samtycke och enligt lokala regler. Exporter kan innehålla känslig text och ska förvaras privat utanför repot. Kalenderkopior kan synkas via ditt kalenderkonto; molnfrågor skickas bara efter ditt godkännande.

Appidentiteten är `app.mio.assistant`; lagringen ligger i `Mio/content-v1.json`, `Mio/sessions.json` och `Mio/assistant-v1.json`. Det är en ren installation utan migrering från prototyperna. Projekt, target, scheme och produkt heter **Mio**; versionsnumret ligger separat i Xcode.
