# Mio

Privat SwiftUI-app för iOS 26+ (första testtelefon iPhone 16 Pro, senare även iPhone 13): privat svensk transkription via Pianissimo på egen CachyOS-dator, anteckningar, planering och en diskret vardagsassistent. Ingen App Store-distribution.

**Aktuellt helhetsbygge: 0.9.0 — ej släppt.** Pianissimo-, bakgrunds-, inställnings- och AI-/lektionsändringar i arbetskopian är ännu inte Xcode-byggda eller publicerade; den befintliga build 5 innehåller dem inte. Alla produktdelar utvecklas tillsammans efter beslutet 2026-09-25. Versionsnumret identifierar bygget; det är inte ett påstående om godkända telefonprov. [Status](docs/STATUS.md) skiljer kod, kontroller, Xcode och verklig användning åt.

Aktuell implementation och överlämning finns på grenen `codex/mio-plan-reliability`: läs [den ursprungliga planen](PLAN.md) och [överlämningsguiden](docs/OVERLAMNING_PLAN_2026-10-04.md) för verifierat läge och återstående acceptansprov.

## Funktioner

- **Native gränssnitt:** Liquid Glass för sessionskontroller, systemnavigation och flikar; semantiska läsytor, Dynamic Type och minskad rörelse.
- **Mio:** transkription via Tailscale, manuell fortsättning efter paus/ljudavbrott, Mio-tilltal och förslag med **Ja / Nej / Inte nu**. Mikrofon, transkriptionsanslutning och text-AI visas separat. Förslag granskas med versionskontroll; en senare komplettering kräver ny granskning och bevarar dina utkaständringar.
- **Lektioner:** separat Starta lektion-knapp pausar vardags-Mio. AI kan skriva detaljerade, kopierbara anteckningar efter avslut, med separata läxförslag. Färdiga delar sparas för manuell fortsättning efter avbrott. Anteckningar visar om källtexten är aktuell, äldre eller saknar revisionsunderlag. En rättning ändrar inte sparade delar och skickar inget automatiskt. Äldre sessioner, manuella tidsintervall och råtext finns under Historik och råtext.
- **Kalender:** lokala planer och användarbekräftade kopior till Apple Kalender.
- **Anteckningar:** sökbara anteckningar, uppgifter och synliga uttryckliga minnen.
- **Morgon/Kväll:** lokal dagsöversikt, avklarade uppgifter, sessioner och lektioner; uppdatering vid foreground, dag-/tidszonsbyte och generella dagliga notiser som öppnar dagens översikt.
- **Alarm och påminnelser:** AlarmKit-alarm, återkommande veckodagar och lokala notiser. Behörigheter begärs först när du sparar en systemåtgärd.
- **Valfri AI:** aktivera löpande analys av nya textutdrag för planer/uppgifter utan Mio-tilltal, eller ställ en enskild fråga med förhandsgranskning. Av vid appstart. Ett modellfritt anslutningsprov visar autentisering, protokoll, release, uppgiftsprofiler och delad kapacitet; det bevisar inte leverantörsbehörighet eller modellkvalitet. Profil-/modellbyte görs på servern enligt [bytesguiden](server/PROVIDERS.md), med reasoning av, temperatur 0 och strikt schema. Ändrad konfiguration kräver ny granskning/aktivering. Högst 100 AI-anrop per dygn delas mellan alla uppgifter.
- **Tillfälligt AI-svar:** granska och redigera svaret innan du uttryckligen sparar det som en vanlig lokal anteckning. Ingen frågehistorik, extra AI-komprimering eller systemåtgärd skapas av svaret.
- Lokal versionsmärkt JSON-export och återupptagbar radering av appdata, egna alarm/notiser och serveranslutningar. Raderingsfel visas med nästa steg. Inget råljud sparas.

Utan AI används en enkel lokal kommandogrammatik. Med aktiverad AI kan även vanligt samtal ge förslag; innehåll och tider måste granskas. Lektionsanteckningar är källkopplade AI-utkast från textdelar, inte en garanti för fullständig sammanfattning. [Status](docs/STATUS.md) skiljer det tidigare bygget från dessa rättningar.

## Kom igång

1. Läs [användarguiden](docs/ANVANDNING.md) och sätt upp [Pianissimo, systemd och Tailscale](transcription-server/README.md).
2. Bygg och installera enligt [installation](docs/INSTALLATION.md). Linux kan inte bygga iOS-appen.
3. Kör [verifieringen](docs/VERIFIERING.md) och [helhetstestet](docs/TESTPLAN_HELHET.md) med syntetiska data. Dokumentera därefter [enhets- och mätproven](docs/ENHETSPROV.md) före vardagsanvändning.
4. Om du vill använda moln-AI: följ [Groq, åtkomsttoken och Access steg för steg](server/cloudflare/GROQ_ACCESS.md) för befintlig Worker eller [Cloudflare-grundinstallationen](server/cloudflare/README.md) för drift utan påslagen dator, eller [serverguiden](server/README.md) för egen värd. Manuella poster fungerar utan server. Ljudtranskription kräver din Pianissimo-dator.

## Utveckling

Öppna `Mio.xcodeproj`, välj schemat **Mio**. Appkod finns i `Mio/`, XCTest i `MioTests/`, tre native UI-smokeprov i `MioUITests/`, ljudservern i `transcription-server/` och text-AI-gatewayen i `server/`. Den gemensamma säkra Linuxgrinden körs från repots rot:

```sh
python3 scripts/verify.py
```

Samma grind körs automatiskt i GitHub-workflowen **Verifiera Mio på Linux** vid varje push. [Verifieringsguiden](docs/VERIFIERING.md) beskriver beroenden, låst Python, loggar, Node-stöd, separat concurrencydiagnostik och begränsningarna när Swift hoppas över. Linux ersätter inte native mikrofon/konvertering, Keychain, URLSession, SwiftUI eller Xcode. Xcode/SDK-/IPA-grinden finns i `.github/workflows/build-unsigned-ipa.yml`; varje körning behöver faktisk runner- och revisionskontroll.

Läs [CLAUDE.md](CLAUDE.md) (instruktioner för Claude Code), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md), [datamodell](docs/DATAMODELL.md) och [ändringslogg](CHANGELOG.md). Commit, push och publicering kräver uttrycklig begäran.

## Integritet och kompatibilitet

Lyssningen startas av dig. Ljudet skickas då till din privata server, med högst 60 s ljud i telefonens RAM och inga ljudfiler. Inställningar nås via kugghjulet på varje flik. Spela bara in andra med tydligt samtycke och enligt lokala regler. Exporter kan innehålla känslig text och ska förvaras privat utanför repot. Kalenderkopior kan synkas via ditt kalenderkonto; molnfrågor skickas bara efter ditt godkännande.

Appidentiteten är `app.mio.assistant`. De tre domänlagren är `Mio/content-v1.json`, `Mio/sessions.json` och `Mio/assistant-v1.json`; därtill finns textfri `Mio/diagnostics-v1.json` och en liten ID-baserad raderingsjournal, `Mio/operations-v1.json`. Se [datamodellen](docs/DATAMODELL.md) för skydd, export och återhämtning. Det är en ren installation utan migrering från prototyperna. Projekt, app-target, scheme och produkt heter **Mio**; versionsnumret ligger separat i Xcode.
