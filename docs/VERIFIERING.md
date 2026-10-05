# Verifiera Mio

Den gemensamma Linuxgrinden kör säkra lokala och syntetiska kontroller. Den publicerar ingenting och gör inga verkliga modellanrop. Paketverktygen kan hämta låsta publika utvecklingsberoenden. Aktuella utförda resultat finns i [status](STATUS.md); fysiska prov dokumenteras enligt [enhetsprotokollet](ENHETSPROV.md).

## Arbetskopia och verktyg

Kommandot verifierar den arbetskopia där själva skriptet finns, oavsett aktuell katalog. Resultat från en kopia bevisar inte innehållet i en annan; kontrollera revision/diff. GitHub-workflowen **Verifiera Mio på Linux** (`.github/workflows/verify-linux.yml`) kör samma grind automatiskt vid varje push, i containern `swift:6.3.3-noble`.

Linuxgrinden kräver `python3`, `git`, `node`, `npm`, `uv` och normalt `swiftc`. Testad miniminivå för Node är **26.10.0**, med deklarerat stöd **>=26.10.0 <27**. CI använder Node 26.10.0, Swift 6.3.3, uv 0.12.22 och en låst Python 3.12-miljö utan inferens-/GPU-extra. Pythonmiljön skapas separat i loggkatalogen; den återanvänder inte en gammal trasig interpretersymlänk. Om kompilatorn inte finns i `PATH` kan `SWIFT_EXECUTABLE` ange dess absoluta sökväg. Plattformarnas nativeverktyg och SDK ersätts inte av dessa versioner.

Verifieraren skapar först den låsta Python-testmiljön. Den innehåller även PyYAML för att alltid parsa och kontrollera de obligatoriska Xcode- och Linux-workflowernas säkerhetskritiska jobbinställningar samt syntaxen i deras Bash-steg.

Alla följande kommandon är oberoende av aktuell katalog, även om terminalen råkar stå i `transcription-server`:

```bash
mio_repo_directory="$(git rev-parse --show-toplevel)"
python3 "$mio_repo_directory/scripts/verify.py"
```

Skriptet väljer då en ny `/tmp/mio-verify-*`-katalog. För en uttrycklig loggplats och det syntetiska långhistorikprovet:

```bash
mio_repo_directory="$(git rev-parse --show-toplevel)"
python3 "$mio_repo_directory/scripts/verify.py" \
  --logs-dir /tmp/mio-verification-plan \
  --measure-session-store
```

Välj en ny loggkatalog för varje revision/körning så att äldre bevis inte skrivs över. Hjälptexten finns med `python3 "$mio_repo_directory/scripts/verify.py" --help`. Skriptet kräver Linux; på macOS används Xcode/XCTest och den separata nativegrinden nedan.

## Vad Linuxgrinden täcker

| Grind | Underlag | Gräns för resultatet |
|---|---|---|
| Struktur | Projektidentitet, filer/targets, integritets- och konfigurationsregler | Bygger inte SwiftUI eller iOS |
| Verifieringsverktyg | Tester av själva verifierarnas fel- och diagnostikhantering | Bevisar inte produktens nativebeteende |
| Node | Låst installation och gateway-/adapter-/routing-/deadlineprov med fixtures | Bevisar inte leverantörsnyckel, modellåtkomst eller modellkvalitet |
| Privat transkriptions-API | Låst Pythonmiljö och API-/cache-/deadlineprov med fake-backend | Laddar inte Pianissimo eller GPU och mäter inte svensk transkriptionskvalitet |
| Worker | Det faktiskt byggda Worker-paketets lokala runtimeprov | Publicerar inte gatewayen och provar inte aktiv Access/D1-konfiguration |
| Portable Swift | Modeller, actorpatchar, workflows, tillstånd och regressioner med ersatta nativegränser | Bevisar inte AVFoundation, Keychain, URLSession, UIKit/SwiftUI eller iOS-filskydd |
| Capture recovery | Deterministiskt avbrotts-/generations-/återhämtningsflöde | Ersätter inte mikrofon- och systemhändelser i en fysisk telefon |
| Strikt concurrency | Separat complete-concurrencydiagnostik för den portabla kärnan | En grön Linuxdiagnostik kompilerar inte app-targeten mot iOS-SDK |
| Långhistorik, valfritt | Syntetisk faktisk session-store: avkodning, JSON-kodning/atomisk patchskrivning och processminne | Linuxvärden; inget bevis för iPhone, ljud, batteri eller behov av databasbyte |

Varje grind får en egen logg. Första fel stoppar körningen och ger `FAIL` samt exitkod 1. Saknat verktyg eller fel plattform ger `UNAVAILABLE` och exitkod 2. Ett fullständigt godkänt resultat heter `PASS (Linux synthetic gates)`.

Om Swift saknas kan övriga kontroller köras med följande uttryckliga undantag:

```bash
mio_repo_directory="$(git rev-parse --show-toplevel)"
python3 "$mio_repo_directory/scripts/verify.py" --skip-swift
```

Detta ger **PARTIAL**, och Swift core/capture/concurrency anges som **SKIPPED**. Exitkod 0 i denna körning betyder att de utförda delarna klarade sig; den är inte en fullständig godkänd grind. `--measure-session-store` kräver ändå Swift för mätningen.

## Bevara revisionsbevis

Loggkatalogens `verification.json` registrerar bascommit, om arbetskopian är ändrad, hela arbetskopians SHA-256, separat kod-/konfigurationsdigest, Node-/uv-versioner, grindstatus och tidsåtgång. Digesten omfattar spårade och icke ignorerade nya filer; den beskriver alltså en ändrad arbetskopia bättre än enbart bascommit. Spara kvittot tillsammans med loggarna. Markdownändringar ingår i hela arbetskopians digest men inte kod-/konfigurationsdigesten.

Kvittot märker native iOS och verklig leverantör som `NOT RUN`. Ett lokalt kvitto blir inte Xcode-, IPA-, installations- eller telefonbevis genom att kopieras till en statusrapport. Behåll de separata resultaten för exakt avsedd release: appcommit/diff, gatewayrelease/bundeldigest/konfigurationsrevision och transkriptionsserverns paket-/modellrevision.

Långhistorikprovet sparar mätdata i `session-store.json`. Redovisa fixturestorlek, verktyg, maskin, antal repetitioner, tider och processminne enligt den faktiska mätutmatningen. Jämför endast körningar med samma fixture och villkor. En syntetisk stor historik motiverar undersökning; den visar inte att verkliga telefondata behöver migreras till SQLite eller SwiftData. Fysisk ljudkonvertering, förfrågningsantal, GPU, värme och batteri har ett eget protokoll i [enhetsproven](ENHETSPROV.md).

## Native iOS, IPA och installation

Den dedikerade concurrencygrinden ska köras på en Mac med kompatibel Xcode och iOS-SDK, mot den avsedda arbetskopians verkliga **Mio**-target. Byt exempelvägen till dess absoluta Mac-sökväg:

```bash
mio_native_repo_directory='/absolute/path/to/Mio'
python3 "$mio_native_repo_directory/scripts/verify_concurrency.py" \
  --native --log /tmp/mio-native-concurrency.log
```

Linux kan inte utföra den nativegrinden. Full diagnostiklogg ska bevaras och relevanta concurrencyvarningar åtgärdas. `verify.py` har inget generellt `--native`-läge.

Workflowen **Bygg Mio IPA** använder den särskilda nativegrinden, osignerad Release, XCTest inklusive tre UI-smokeprov och IPA-validering i samma jobb. Kontrollera faktiskt tilldelad `xcode-27`-runner, Xcode-/SDK-version, simulator och slutresultat. Runneretiketten, en publicerad workflowdefinition eller ett äldre grönt jobb bevisar inte ett nytt bygge. Bevara Release-/testbygg-/XCTest-/concurrencyloggar, `.xcresult`, körnings-URL och `Mio-buildinfo.txt` med appens commit, workflowprovenance och IPA-SHA-256.

Följ därefter [installationsguiden](INSTALLATION.md). Registrera den installerade IPA:ns hash, signering/installationsdatum och telefonens iOS-version innan de fysiska proven startar. Simulatorprov är användbart för navigation och UI, men telefonens mikrofon, RAM-ljud, privata nät, systemtillstånd och batteri kräver separat evidens.

Gatewaypublicering och verkliga syntetiska modellanrop kräver respektive uttryckliga godkännande. Den [granskade leverantörsmatrisen](LEVERANTORSKONTRAKT.md) håller kontrakt/fixtures, faktisk modellåtkomst och fysisk kvalitet åtskilda. Ett modellfritt anslutningsprov validerar skyddad status, uppgifter och revision; det testar inte providerautentisering eller modellkvalitet.

Operativa loggar får bara innehålla begränsad textfri diagnostik och sanerad metadata. Källtext, frågor, svar, råljud, tokens, fulla adresser, pairing-filer och privata exporter hör inte hemma i loggar eller repo. Granska bevismaterial innan det delas.
