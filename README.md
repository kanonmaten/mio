# Mio

Privat SwiftUI-app för iOS 26+ (första testtelefon iPhone 16 Pro, senare även iPhone 13): privat svensk transkription via Pianissimo på egen CachyOS-dator, anteckningar, planering och en diskret vardagsassistent. Ingen App Store-distribution.

**Aktuellt helhetsbygge: 0.9.0 — ej släppt.** Design-, Pianissimo-, bakgrunds-, inställnings- och AI-/lektionsändringar i arbetskopian är ännu inte Xcode-byggda eller publicerade; den befintliga build 5 innehåller dem inte. Alla produktdelar utvecklas tillsammans efter beslutet 2026-09-25. Versionsnumret identifierar bygget; det är inte ett påstående om godkända telefonprov. [Status](docs/STATUS.md) skiljer kod, kontroller, Xcode och verklig användning åt.

[Planen för tillförlitlighet](PLAN.md) styr 0.9.0; [status](docs/STATUS.md) visar verifierat läge och återstående acceptansprov.

## Funktioner

- **Veckoplaneraren (design vald 2026-10-11):** violett grund, vanliga läsytor och Liquid Glass bara på flikfält och knappar; Dynamic Type och minskad rörelse. Fyra flikar, **Hem, Lektioner, Kalender, Anteckningar**, och en separat rund mikrofonknapp, **Fånga**, längst till höger i flikfältet.
- **Hem:** veckonumret som rubrik, veckans sju dagar (tryck på en dag, pilarna byter vecka, **I dag** går tillbaka), **Nästa** med en enda åtgärd, **N att granska**, dagens översikt med Morgon/Kväll (kväll från kl. 17) och ett rutnät över tolv veckor som bara räknar aktivitet. Morgon- och kvällsnotiser öppnar Hem.
- **Fånga:** transkription via Tailscale, automatisk omstart efter ljudavbrott (aldrig efter din paus eller ditt stopp), Mio-tilltal och förslag med **Ja / Nej / Inte nu**. Mikrofon, transkriptionsanslutning och text-AI visas separat. Förslag granskas med versionskontroll; en senare komplettering kräver ny granskning och bevarar dina utkaständringar.
- **Lektioner:** separat Starta lektion-knapp pausar vardags-Mio. AI kan skriva detaljerade, kopierbara anteckningar efter avslut, med separata läxförslag. Färdiga delar sparas för manuell fortsättning efter avbrott. Anteckningar visar om källtexten är aktuell, äldre eller saknar revisionsunderlag. En rättning ändrar inte sparade delar och skickar inget automatiskt. Äldre sessioner, manuella tidsintervall och råtext finns under Historik och råtext.
- **Kalender:** lokala planer grupperade per veckonummer och användarbekräftade kopior till Apple Kalender.
- **Anteckningar:** sökbara anteckningar, uppgifter och synliga uttryckliga minnen.
- **Lyssningsraden:** ovanför flikfältet medan en session pågår (iOS 26.1+), med en diskret prick, kort status och paus/fortsätt; tryck för Fånga. På iOS 26.0 visar Live Activity läget.
- **Alarm och påminnelser:** AlarmKit-alarm, återkommande veckodagar och lokala notiser. Behörigheter begärs först när du sparar en systemåtgärd.
- **AI:** på när datorn är parad (beslut 2026-10-11) och kan pausas på Fånga eller under Inställningar → AI. Nya textutdrag analyseras löpande för planer/uppgifter utan Mio-tilltal, samlat högst var femte minut. **Fråga Mio** (knapp på Hem och Fånga) skickar en enskild fråga direkt och visar upp till tre färdiga frågor som bara fyller i textfältet. Ett modellfritt anslutningsprov visar autentisering, protokoll, release, uppgiftsprofiler och kvot; det bevisar inte leverantörsbehörighet eller modellkvalitet. Gatewayen kör på din dator med Groq och Qwen 3.8 27B ([gatewayguiden](server/README.md)), med reasoning av, temperatur 0 och strikt schema. Gränserna är tre anrop per minut och 190 000 token per dygn.
- **Tillfälligt AI-svar:** granska och redigera svaret innan du uttryckligen sparar det som en vanlig lokal anteckning. Ingen frågehistorik, extra AI-komprimering eller systemåtgärd skapas av svaret.
- Lokal versionsmärkt JSON-export och återupptagbar radering av appdata, egna alarm/notiser och serveranslutningar. Raderingsfel visas med nästa steg. Inget råljud sparas.

Utan AI används en enkel lokal kommandogrammatik. Med aktiverad AI kan även vanligt samtal ge förslag; innehåll och tider måste granskas. Lektionsanteckningar är källkopplade AI-utkast från textdelar, inte en garanti för fullständig sammanfattning. [Status](docs/STATUS.md) skiljer det tidigare bygget från dessa rättningar.

## Kom igång

1. Läs [användarguiden](docs/ANVANDNING.md) och sätt upp [Pianissimo, systemd och Tailscale](transcription-server/README.md).
2. Bygg och installera enligt [installation](docs/INSTALLATION.md). Linux kan inte bygga iOS-appen.
3. Kör [verifieringen](docs/INSTALLATION.md#verifiera-före-bygge) och [helhetstestet](docs/TESTPLAN_HELHET.md) med syntetiska data, inklusive mätprotokollet, före vardagsanvändning.
4. För AI: installera gatewayen på datorn och para telefonen med QR-koden enligt [gatewayguiden](server/README.md). Manuella poster fungerar utan dator. Ljudtranskription kräver din Pianissimo-dator.

## Utveckling

Öppna `Mio.xcodeproj`, välj schemat **Mio**. Appkod finns i `Mio/`, XCTest i `MioTests/`, tre native UI-smokeprov i `MioUITests/`, ljudservern i `transcription-server/` och text-AI-gatewayen i `server/`. Den gemensamma säkra Linuxgrinden körs från repots rot:

```sh
python3 scripts/verify.py
```

Samma grind körs automatiskt i GitHub-workflowen **Verifiera Mio på Linux** vid varje push. [Verifieringsavsnittet](docs/INSTALLATION.md#verifiera-före-bygge) beskriver beroenden, grindar och begränsningar. Linux ersätter inte native mikrofon/konvertering, Keychain, URLSession, SwiftUI eller Xcode. Xcode/SDK-/IPA-grinden finns i `.github/workflows/build-unsigned-ipa.yml`; varje körning behöver faktisk runner- och revisionskontroll.

Läs [CLAUDE.md](CLAUDE.md) (instruktioner för Claude Code), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md), [datamodell](docs/DATAMODELL.md) och [ändringslogg](CHANGELOG.md). Färdiga ändringar committas och pushas direkt till `main`; publicering och verkliga modellanrop kräver uttrycklig begäran.

## Integritet och kompatibilitet

Lyssningen startas av dig. Ljudet skickas då till din privata server, med högst 60 s ljud i telefonens RAM och inga ljudfiler. Inställningar finns i en panel som glider in från höger. Spela bara in andra med tydligt samtycke och enligt lokala regler. Exporter kan innehålla känslig text och ska förvaras privat utanför repot. Kalenderkopior kan synkas via ditt kalenderkonto. När AI är på skickas text via din dator till Groq; förslag sparas först efter ditt Ja.

Appidentiteten är `app.mio.assistant`. Sessioner, innehåll och assistentdata ligger i SwiftData (`Mio/store/Mio.store`), migrerat en gång från `content-v1.json`, `sessions.json` och `assistant-v1.json`; textfri `Mio/diagnostics-v1.json`, `Mio/metrickit-v1.json` och den ID-baserade raderingsjournalen `Mio/operations-v1.json` är kvar som JSON. Se [datamodellen](docs/DATAMODELL.md) för skydd, export och återhämtning. Ingen data migreras från prototyperna. Projekt, app-target, scheme och produkt heter **Mio**; versionsnumret ligger separat i Xcode.
