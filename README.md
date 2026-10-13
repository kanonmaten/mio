# Mio

Privat SwiftUI-app för iOS 26+ (första testtelefon iPhone 16 Pro, senare även iPhone 13): privat svensk transkription via Pianissimo på egen CachyOS-dator, anteckningar, planering och en diskret vardagsassistent. Ingen App Store-distribution.

**Aktuell version: 0.9.1 — ej släppt och inte provad på telefonen.** 0.9.0 är revisionen `8f90ddc` med rättningarna efter provet 2026-10-13; 0.9.1 lägger till att Apples appar äger posterna ([plan](docs/PLAN_APPLEAPPAR.md)). Båda är byggda och testade i simulatorn, ingen är installerad eller provad på telefonen. Alla produktdelar utvecklas tillsammans efter beslutet 2026-09-25. Versionsnumret identifierar bygget; det är inte ett påstående om godkända telefonprov. [Status](docs/STATUS.md) skiljer kod, kontroller, Xcode och verklig användning åt.

[Planen för tillförlitlighet](PLAN.md) styr 0.9.0 och [planen för Apples appar](docs/PLAN_APPLEAPPAR.md) 0.9.1; [status](docs/STATUS.md) visar verifierat läge och återstående acceptansprov.

## Funktioner

- **Veckoplaneraren (design vald 2026-10-11):** violett grund, vanliga läsytor och Liquid Glass bara på flikfält och knappar; Dynamic Type och minskad rörelse. Tre flikar, **Hem, Lektioner, Förslag**, och en separat rund mikrofonknapp, **Fånga**, längst till höger i flikfältet.
- **Hem:** veckonumret som rubrik, veckans sju dagar (tryck på en dag, pilarna byter vecka, **I dag** går tillbaka), **Nästa** med en enda åtgärd, **N att granska**, dagens översikt med Morgon/Kväll (kväll från kl. 17) och ett rutnät över tolv veckor som bara räknar aktivitet. Morgon- och kvällsnotiser öppnar Hem.
- **Fånga:** transkription via Tailscale, automatisk omstart efter ljudavbrott (aldrig efter din paus eller ditt stopp), Mio-tilltal och förslag med **Ja / Nej / Inte nu**. Mikrofon, transkriptionsanslutning och text-AI visas separat. Förslag granskas med versionskontroll; en senare komplettering kräver ny granskning och bevarar dina utkaständringar.
- **Lektioner:** separat Starta lektion-knapp pausar vardags-Mio. AI kan skriva detaljerade, kopierbara anteckningar efter avslut, med separata läxförslag. Färdiga delar sparas för manuell fortsättning efter avbrott. Anteckningar visar om källtexten är aktuell, äldre eller saknar revisionsunderlag. En rättning ändrar inte sparade delar och skickar inget automatiskt. Äldre sessioner, manuella tidsintervall och råtext finns under Historik och råtext.
- **Apples appar äger posterna (0.9.1):** efter Ja går en händelse till Kalender via Kalenders egen ruta, en att göra-post till Påminnelser och en anteckning eller ett minne till Anteckningar via dela-arket. Mio sparar bara vart den skickades; Hem läser kommande påminnelser.
- **Anteckningar:** sökbara anteckningar, uppgifter och synliga uttryckliga minnen.
- **Lyssningsraden:** ovanför flikfältet medan en session pågår (iOS 26.1+), med en diskret prick, kort status och paus/fortsätt; tryck för Fånga. På iOS 26.0 visar Live Activity läget.
- **Notiser:** valfri morgon- och kvällsnotis samt "Tryck för att fortsätta lyssna". Mios egna alarm togs bort i 0.9.1.
- **AI:** på när datorn är parad (beslut 2026-10-11) och kan pausas på Fånga eller under Inställningar → AI. Nya textutdrag analyseras löpande för planer/uppgifter utan Mio-tilltal, samlat högst var femte minut. **Fråga Mio** (knapp på Hem och Fånga) skickar en enskild fråga direkt och visar upp till tre färdiga frågor som bara fyller i textfältet. Ett modellfritt anslutningsprov visar autentisering, protokoll, release, uppgiftsprofiler och kvot; det bevisar inte leverantörsbehörighet eller modellkvalitet. Gatewayen kör på din dator med Groq och Qwen 3.8 27B ([gatewayguiden](server/README.md)), med reasoning av, temperatur 0 och strikt schema. Gränserna är tre anrop per minut och 190 000 token per dygn.
- **Tillfälligt AI-svar:** granska och redigera svaret innan du uttryckligen sparar det som en vanlig lokal anteckning. Ingen frågehistorik, extra AI-komprimering eller systemåtgärd skapas av svaret.
- Lokal versionsmärkt JSON-export och återupptagbar radering av appdata, egna notiser och serveranslutningar. Raderingsfel visas med nästa steg. Inget råljud sparas.

Utan AI används en enkel lokal kommandogrammatik. Med aktiverad AI kan även vanligt samtal ge förslag; innehåll och tider måste granskas. Lektionsanteckningar är källkopplade AI-utkast från textdelar, inte en garanti för fullständig sammanfattning. [Status](docs/STATUS.md) skiljer det tidigare bygget från dessa rättningar.

## Kom igång

Gör stegen i den här ordningen. Skripten på datorn körs som din vanliga användare, inte med `sudo`.

1. Installera Pianissimo på datorn med `transcription-server/install.sh`. Första gången tar det ungefär en halvtimme. Se [Pianissimo-guiden](transcription-server/README.md).
2. Installera AI-gatewayen på samma dator med `server/install.sh` (cirka 10 minuter, du behöver en Groq-nyckel). Se [gatewayguiden](server/README.md).
3. Installera Tailscale på telefonen, logga in med samma konto som på datorn och slå på VPN On Demand.
4. Installera Mio på telefonen enligt [installationen](docs/INSTALLATION.md).
5. Kör `mio-pair` på datorn och skanna QR-koden i Mio under Inställningar → Dator.

`mio-pair` hämtar tokens från båda installationerna, så kör den först när steg 1 och 2 är klara. Kör du den utan Pianissimo får koden bara med AI. Installera då Pianissimo, kör `mio-pair` igen och tryck Para om med QR-kod i Mio.

Fortsätt sedan med [användarguiden](docs/ANVANDNING.md) och [helhetstestet](docs/TESTPLAN_HELHET.md). Anteckningar och planer fungerar utan dator, men inte transkription och AI.

## Utveckling

Öppna `Mio.xcodeproj`, välj schemat **Mio**. Appkod finns i `Mio/`, XCTest i `MioTests/`, tre native UI-smokeprov i `MioUITests/`, ljudservern i `transcription-server/` och text-AI-gatewayen i `server/`. Den gemensamma säkra Linuxgrinden körs från repots rot:

```sh
python3 scripts/verify.py
```

Samma grind körs automatiskt i GitHub-workflowen **Verifiera Mio på Linux** vid varje push. [Verifieringsavsnittet](docs/INSTALLATION.md#verifiera-före-bygge) beskriver beroenden, grindar och begränsningar. Linux ersätter inte native mikrofon/konvertering, Keychain, URLSession, SwiftUI eller Xcode. Xcode/SDK-/IPA-grinden finns i `.github/workflows/build-unsigned-ipa.yml`; varje körning behöver faktisk runner- och revisionskontroll.

Läs [CLAUDE.md](CLAUDE.md) (instruktioner för Claude Code), [vision](docs/PRODUKTVISION.md), [roadmap](docs/ROADMAP.md), [beslut](docs/DECISIONS.md), [datamodell](docs/DATAMODELL.md) och [ändringslogg](CHANGELOG.md). Färdiga ändringar committas och pushas direkt till `main`; publicering och verkliga modellanrop kräver uttrycklig begäran.

## Integritet och kompatibilitet

Lyssningen startas av dig. Ljudet skickas då till din privata server, med högst 60 s ljud i telefonens RAM och inga ljudfiler. Inställningar finns i en panel som glider in från höger. Spela bara in andra med tydligt samtycke och enligt lokala regler. Exporter kan innehålla känslig text och ska förvaras privat utanför repot. Det du skickar till Kalender, Påminnelser och Anteckningar synkas via dina Apple-konton. När AI är på skickas text via din dator till Groq; förslag sparas först efter ditt Ja.

Appidentiteten är `app.mio.assistant`. Sessioner, innehåll och assistentdata ligger i SwiftData (`Mio/store/Mio.store`), migrerat en gång från `content-v1.json`, `sessions.json` och `assistant-v1.json`; textfri `Mio/diagnostics-v1.json`, `Mio/metrickit-v1.json` och den ID-baserade raderingsjournalen `Mio/operations-v1.json` är kvar som JSON. Se [datamodellen](docs/DATAMODELL.md) för skydd, export och återhämtning. Ingen data migreras från prototyperna. Projekt, app-target, scheme och produkt heter **Mio**; versionsnumret ligger separat i Xcode.
