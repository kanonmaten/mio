# Bygg- och teststatus

## Granskning och rättningar, 2026-10-05

Grenen `codex/mio-plan-reliability` granskades mot `PLAN.md` med Claude Code och rättades i separata commits (se [ändringsloggen](../CHANGELOG.md)). **Fortfarande ej släppt, inte iOS-byggd och inte telefonverifierad.**

- Överlämningens påstående att Linux-grindarna var gröna gällde bara den ursprungliga värden: GitHub-workflowen **Verifiera Mio på Linux** misslyckades för `4fa92a0` innan någon grind kördes ([körning 37227941960](https://github.com/kanonmaten/mio/actions/runs/37227941960)). Efter CI-rättningen passerade samma `verify.py` för `f4ac563` ([körning 37277380844](https://github.com/kanonmaten/mio/actions/runs/37277380844)): strukturkontroller, verifierartester, Node-tester, Worker-runtime, Pianissimo fake-backend, portabla XCTest, capture recovery och portable concurrency. Detta är första oberoende bekräftelsen av de portabla Swift-testerna.
- Rättningarna i steg 1 passerade samma workflow för `be30bf4` ([körning 37277821957](https://github.com/kanonmaten/mio/actions/runs/37277821957)). Alla rättningar tillsammans passerade samma workflow för `0c571c9` ([körning 37280188338](https://github.com/kanonmaten/mio/actions/runs/37280188338)), med 247 portabla XCTest. Under vägen fångade CI ett eget fel i granskningen (en `_modify`-accessor gav exklusivitetsfel vid varje sparning); den delen återställdes. Ett grönt resultat gäller bara den commit det kördes för.
- Första iOS-körningarna av grenen (IPA-workflowen, [37280837886](https://github.com/kanonmaten/mio/actions/runs/37280837886) och [37283457503](https://github.com/kanonmaten/mio/actions/runs/37283457503)): native strict concurrency, Release-bygge, testkompilering och tre UI-smokeprov inklusive tillgänglighetsgranskning godkända. Två iOS-enhetstester från överlämningen föll: konverteraren gav 16 011 i stället för 16 000 samples per sekund (filtersvans vid strömslut, nu begränsad till faktisk inlängd) och simulatorn rapporterar inget Data Protection-skydd (kontrollen gäller nu fysisk enhet enligt [enhetsprotokollet](ENHETSPROV.md)). Ett race-prov föll en gång och passerade nästa gång; det bevakas. Ingen IPA skapades av dessa körningar.
- Lokalt i granskningsmiljön (Node 22, ej den pinnade 26.10): 125/125 gateway-tester och Worker dry-run/runtime/avbrott inklusive 40 s hängande D1 godkända efter gatewayrättningarna; 27/27 Pianissimo-API-tester med fake-backend; 296 strukturella kontroller. Ingen Swift-kompilator fanns lokalt.
- Inte utfört: IPA-workflowen (Xcode Release, iOS-XCTest inklusive tre UI-smokeprov, native concurrency, IPA), Cloudflare-publicering (ska inkludera `enable_request_signal` och verifiera verkligt klientavbrott), verkliga providerprov och fysiska enhetsprov enligt [enhetsprotokollet](ENHETSPROV.md).

## Helhetsbygge 0.9.0 — överlämnad gren, 2026-10-04

PLAN-steg 1–5 är implementerade och de lokala Linux-grindarna är godkända. Ändringarna är committade och pushade på `codex/mio-plan-reliability`, baserad på `3f99f4072b0ddbe51529c84bfdb9f947855f6e64`. Helheten är fortfarande **ej släppt och inte iOS-verifierad**. Fullständiga post-commit-loggar och kvitto finns i `/tmp/mio-mio-handoff-20261004-final/` på värden där verifieringen kördes; `verification.json` anger commit och arbetskopians digest.

- **274/274 strukturella kontroller**, **4 verifierarprov**, **123/123 Node-tester**, lokala Worker-runtimeprov för faktisk bundle, autentisering, revision, kvot, uppgifter och avbrott, samt **27/27 Pianissimo-API-prov** med fake-backend är godkända. Inga verkliga modell- eller transkriptionsanrop gjordes. Python 3.12.15/uv 0.12.23 gav en Starlette-deprecationsvarning; Python-proven passerade.
- Wrangler och Miniflare utvecklingsverktyg är uppdaterade till `4.147.0` respektive `5.20261001.0-alpha`. En tidigare fullständig npm-granskning visade tre sårbarheter i enbart verktygens utvecklingsberoenden; efter uppdateringen rapporterar `npm audit` noll sårbarheter. Produktionsberoendegranskningen var också ren.
- **235/235 portabla XCTest** godkända med Swift 6.3.3 på Linux. Mikrofonens åtta lifecycle-/notifikationsprov passerar med ersatt AVFoundation-gräns. Den separata complete-concurrencygrinden fann inga relevanta varningar efter att notiser omvandlades till `Sendable`-värden före kööverföring. Dessa resultat bygger inte Mio mot iOS-SDK eller verklig AVFoundation.
- Syntetisk session-store-mätning i R4 på CachyOS: 50/500/2 000 sessioner gav cirka 0,79/7,93/31,71 MB; vid 2 000 sessioner var medianavkodning 439 ms, JSON-kodning 444 ms och metadata-patch med atomisk skrivning 474 ms, med 259 526 656 byte (cirka 248 MiB) processens peak-RSS. Detta är en Linux-baslinje, inte ett iPhone-, batteri- eller databasbytesbeslut.
- Ändringarna innehåller fångst-/sessionstillförlitlighet, appägd workflow- och raderingssamordning, providerneutrala AI-kontrakt/adaptrar, färskhets-/anslutnings-/godkännandeflöden, Linux-/native-verifieringsflöden och svenska drift-/testguider. Tre UI-smokeprov är registrerade i target men inte körda i Xcode.

**Återstår före helheten kan kallas verifierad:** efter separat godkännande, publicera den avsedda Cloudflare-kod-/konfigurationskombinationen och verifiera skyddad status/Access; kör sedan godkända syntetiska providerprov; kör den pushade revisionen genom `xcode-27` för Release, iOS-XCTest, native concurrency och osignerad IPA; granska IPA och installera/prova på iPhone 16 Pro och iPhone 13. Wrangler-kontrollen 2026-10-04 visar fortfarande aktiv Worker-version `4c22cc43-a625-48d1-86e5-e45638cbcb8e` på 100 %. GitHub har ännu ingen lyckad iOS-workflow för denna gren; senaste lyckade körning var för tidigare commit `7901644`. Access-policy, positiv autentisering och deploymentbehörighet är inte fullständigt verifierade. Ingen Cloudflare-publicering, modelltrafik, Xcode-körning, IPA-installation eller fysisk telefonverifiering har gjorts.

## AI-kontext och diagnostik implementerade i arbetskopian, 2026-09-30

AI-kontextplanen från 2026-09-30 implementerades i den dåvarande arbetskopian: skyddad status/v2-kontrakt, begränsad bakåtkontext och nya källor, stabila öppna/stängda beslut, mjuka meningsgränser/sluttext samt textfri diagnostik/export/radering. **Kontrollerna nedan utfördes före commit/push. Ingen publicering, Xcode-körning, installation eller telefonverifiering av denna revision.** Den gamla aktiva Workern nedan är fortfarande inkompatibel med Groq-inställningarna.

- **47/47 Node-tester godkända**, mockade modeller. **Worker dry-run och verklig lokal workerd/Miniflare godkända**: v1/OpenAI, Groq/fråga/lektion/v2, skyddad status, metadata, D1-kvot och status vid felaktig provider/modell/saknad nyckel. Ingen extern modelltrafik.
- **53/53 portabla XCTest godkända med Swift 6.3 på Linux** via `scripts/verify_swift_core.py`: 7 kontext-/beslutsprov, 9 diagnostik-/exportprov, 6 koordinatorprov samt 31 befintliga analys-/assistent-/lagringsprov. Produktionsmodeller, lager, assistent-vymodell och koordinator kompileras. Endast plattformsgränser ersätts: Keychain-konfigurationsladdning och Apples URLSession.bytes; nätstubben kan inte skicka trafik. Ett UIKit-beroende snapshotprov undantas uttryckligen. Dessa är **inte iOS-XCTest eller appkompilering**.
- **44 Swift-filer syntaxkontrollerade med Swift-kompilatorns parser** i Swift 5-läge. **194 portabla projektkontroller godkända**, inklusive faktiska grupprelativa Xcode-sökvägar och alla target-filer, samt `git diff --check`. Parsern typkontrollerar inte SwiftUI/iOS-API:er.
- Regressioner verifierade från felande till godkända för saknad kontext, raderingsrace, kolon i giltiga modellnamn, tyst dubblettsammanslagning, sluttextens väckning av väntan, kontextbegränsning vid gap och anropstakt efter lång statuskontroll. Oberoende kodgranskning slutförd utan kvarstående kritiska/viktiga fynd efter rättningarna; fyra felaktiga nya Xcode-gruppkopplingar fångades och rättades med en först felande sökvägskontroll.
- Exporten är en ögonblicksbild. **Skapa ny export** finns även efter en tidigare export, så nya frågefel/konfigurationsval kan tas med utan innehållsändring. Prov med tom session, tidigare export och senare 503 bekräftar att regenererad fil innehåller den nya händelsen.

Nästa drift-/enhetsgrindar: publicera avsedd gateway efter uttrycklig begäran och läsverifiera aktiv release/status; verkligt syntetiskt Groq-prov med godkänd sändning; Release och iOS-XCTest för exakt denna revision, ny IPA och [D01–D08](TESTPLAN_HELHET.md#ai-kontext-och-diagnostik--nya-prov-ej-körda-på-iphone). Prova särskilt Access, native URLSession/Keychain/filskydd, stopp/paus/lektionsbyte/låst skärm och semantisk kvalitet. Modellen anropas tidigast 60 s efter att föregående sändning avslutats; nätlatens och kö kan därför göra väntan längre än meningsgränsens 120 s. Kvoten 100 anrop/dygn är oförändrad och räcker inte för heldagsanalys.

## AI-driftfel läsverifierat, 2026-09-30

- Aktiv Worker-version `4c22cc43-a625-48d1-86e5-e45638cbcb8e` och dess faktiska kod hämtade med läsanrop. Publicerad kod stöder endast OpenAI och läser äldre OpenAI-inställningar; aktiva bindningar anger Groq/Qwen och saknar OpenAI-nyckel/-modell. Initieringen kan därför inte lyckas och kodens felväg är 503 `gateway_not_configured`. Samma konfigurationsfel reproducerat mot äldre repokod med syntetiska inställningar, utan modelltrafik.
- Anonym `/health` gav HTTP 403 från Access. Telefonanropets exakta status, installerat byggnummer och Access-autentisering kan inte bestämmas från den bifogade tomma exporten. Ingen fungerande Groq-nyckel eller verklig modellåtkomst har verifierats.
- Befintlig arbetskopias **40/40 Node-prov**, **Worker dry-run och lokal OpenAI/Groq-runtime** samt **144 portabla projektkontroller efter dokumentationsändringen** godkända. Alla AI-prov mockade. Ingen publicering, Xcode/XCTest, installation eller telefonverifiering.
- [Utredning och designförslag](AI_FELSOKNING_2026_09_30.md) beskriver saknad AI-diagnostik, bekräftad kontext-/dedupliceringsbrist och rekommenderad begränsad bakåtkontext med mjuka gränser och stabila beslut. Vid utredningstillfället var detta ett förslag; efterföljande godkännande och implementation redovisas ovan. Befintlig Groq-kod kan publiceras efter uttrycklig begäran.

## Pianissimo-driftguide granskad, 2026-09-30

- Guiden använder uttryckliga källsökvägar vid installation, systemd och utvecklarprov. Till `/opt` kopieras bara Python-paketet, `pyproject.toml` och `uv.lock`. Valet av låst Python/systemd/Tailscale jämförs med Docker och terminaldrift, med källor och kvarvarande driftbegränsningar.
- **10 Bash-block och deras inbäddade Python-exempel syntaxkontrollerade.** Kopieringskommandona provade från `/tmp` med mellanslag i en temporär källsökväg: exakt sex serverfiler kopierades med filmode `0644`; syntetiska privata filer, `.venv` och cache uteslöts. `--chown` och root-installationen utfördes inte i detta prov.
- **142 portabla projektkontroller och `git diff --check` godkända.** systemd-filens nya `StateDirectoryMode=0700` syntaxkontrollerad med `systemd-analyze verify` på en temporär kopia där enbart ExecStart-programmet ersattes med `/usr/bin/true`, eftersom `/opt`-installationen saknas. Första försöket blockerades av sandboxens socketbegränsning; kontrollen utanför sandboxen passerade. Detta verifierar inte faktisk tjänstestart eller katalogmode i drift.
- **Aktuell GPU-status läst**, ingen inference körd: RTX 4060 Ti, driver 615.71.09, 8188 MiB totalt och 6398 MiB ledigt vid kontrollen. `nvidia-smi` misslyckades inne i sandboxen men fungerade utanför den. Tidigare GPU-smoke nedan är separat evidens.
- Ingen systeminstallation, hämtning av modellvikter, tjänstestart, Tailscale-ändring, commit/push eller iOS-körning gjord i denna granskning. Nästa prov är installation enligt guiden, autentiserad health, svenskt tal med ordtider, privat HTTPS samt omstart/telefonprov enligt T01–T20.

## Actions-fel och lokal rättning, 2026-09-30

Stegstatus verifierad via GitHub: **Bygg osignerad iPhone-app lyckades** för `a67b0ee`. Testkompileringen misslyckades; XCTest, IPA-paketering och uppladdning hoppades över. Ingen ny IPA producerades av körningen. Detta uppdaterar verifieringsläget från arbetskopians tidigare status nedan.

[Actions 36686984521](https://github.com/kanonmaten/mio/actions/runs/36686984521) för `a67b0ee` misslyckades med exit 65 vid **Kompilera enhetstester**: `TranscriptionTests.swift:47` använde `.1` och `.5`, vilket Swift kräver skrivs `0.1` och `0.5`. Båda är rättade i arbetskopian; rättningen är ännu inte Xcode-verifierad. Loggen innehåller också varningar om infångad svag `self` i samtidiga closures i `MioViewModel`; de var inte de blockerande felen i denna körning. Den tidigare tree-sitter-kontrollen upptäckte inte de ogiltiga decimaltalen och får inte tolkas som kompilatorbevis.

## Pianissimo, bakgrund och inställningar — arbetskopia 2026-09-30

**Inte Xcode-kompilerad, inte XCTest-körd, inte installerad på iPhone och inte driftsatt.** Build 5 nedan gäller tidigare Apple-transkription. Kontrollerna nedan gjordes i arbetskopian före commit/push. Ingen ny iOS-byggkörning eller driftsättning har utförts.

- Implementerat: original Pianissimo bakom API v1, separat ljudfångst/uppladdning, privat Tailscale-adress/Keychain, 60 s RAM-gräns och synliga luckor, nätåterförsök, iOS-avbrottshantering och samlade inställningar. Se [beslut](DECISIONS.md), [driftguide](../transcription-server/README.md) och [20 acceptansprov](TESTPLAN_PIANISSIMO.md).
- **GPU-smoke utförd** på denna CachyOS-värd: RTX 4060 Ti 8 GiB, NVIDIA 615.71.09, Python 3.12.14, torch 2.14.0+cu130, NeMo 2.7.0. Original `KlangAI/pianissimo-sv`, revision `95c85c9b08afff7b48b540984b1e9b693b31ddd4`, laddades på CUDA. Första laddning inklusive hämtning: 41,98 s. 20 s syntetisk tystnad gav tom ordlista, peak allokerat GPU-minne cirka 4788 MiB. Detta verifierar laddning/inference, **inte svensk talprecision, ordalignment eller iPhone-latens**. Ingen privat inspelning användes. Efter rättning av NeMos utfyllnad för korta slutdelar upprepades GPU-provet: cachad laddning 15,87 s, tystnad 0,1/0,5/20 s gav noll ord och 0,05/0,05/0,12 s inference, samma peak 4788 MiB. Dessa tider gäller tystnad, inte svenskt tal.
- **25/25 Python-API-prov godkända** med falsk modell: auth, format/storlek, tidsstämplar, idempotenta retries/konflikt/cache-expiration, överlast, parallell health, laddning och fastnad inference/omstartssignal. Starlette ger en deprecationsvarning för testklientens httpx; inga testfel. Testerna kördes med localhost-tillgång utanför sandboxen.
- **40/40 befintliga Node-gatewaytester godkända**, simulerad text-AI. Första sandboxförsöket misslyckades; körning med localhost-tillgång passerade. Gatewaykoden ändrades inte av motorbytet och ingen riktig AI-trafik skickades.
- **142 portabla projektkontroller godkända**, Python compileall och `git diff --check` godkända. **38 Swift-filer** parserkontrollerade med tree-sitter 0.26.0 / tree-sitter-swift 0.7.3: inga syntaxfel. Detta är inte Swift-typkontroll eller Xcode-kompilering.
- Nya XCTest-fall för ljuddelarnas gränser/flush, tidsluckor, svaridentitet/ordtider, privata adresser/token, äldre lagring/metadata/luckor, transporthälsa och HTTP-återförsök finns men är **ej körda**. Befintligt samtyckesprov omfattar nu även fördröjd text från äldre ljud. Verklig reconnect/cancellation på telefon återstår.
- systemd-enheten syntaxkontrollerad med `systemd-analyze verify` på en temporär kopia där endast ExecStart pekade på den befintliga testmiljöns uvicorn. Originalets `/opt`-installation finns inte ännu. Ingen tjänst, autostart, tailnet-policy eller Tailscale Serve installerades/ändrades; dessa måste verifieras på riktigt enligt guiden.

Nästa grindar: begärd commit/push för ny Release/XCTest/IPA, installation av tjänst och Tailscale, T01–T20 samt hela appens regressionsprov. Mät svensk precision vid delgränser, batteri och låst skärm. Äldre export visade `Session activation failed`, men ingen exakt rotorsak eller förbättrad stabilitet på måltelefonen är bevisad.

Kvarvarande funktionsbegränsning, identifierad vid eftergranskning: vardags-AI samlar flera textdelar per anrop men återför inte tidigare textkontext över gränsen till nästa anrop. En mening/plan som korsar den gränsen kan därför missas eller bli ofullständig. Lokal Mio-kommandotolkning arbetar också per textsegment. Ljudets överlappning löser inte detta. Vardags-AI-bristen har därefter åtgärdats i arbetskopian enligt den nya sektionen ovan; den lokala kommandotolkningen arbetar fortfarande per segment och verkliga modell-/telefonprov återstår.

All status längre ned är daterad historisk evidens och verifierar inte denna arbetskopia.

## Cloudflare livegranskning 2026-09-29

- Worker `mio-private-gateway` har D1-bindningen `MIO_LIMITS` till befintliga `mio-limits`; D1 Studio visar tabellen `mio_budget`. I produktion finns `MIO_AI_PROVIDER=groq`, `MIO_AI_MODEL=qwen/qwen3.8-27b`, `MIO_REQUESTS_PER_DAY=100`, `MIO_REQUESTS_PER_MINUTE=6` och `MIO_LESSON_INTERVAL_SECONDS=60`. `GROQ_API_KEY` och `MIO_GATEWAY_TOKEN` finns som maskerade Secrets; deras innehåll eller giltighet kan inte avläsas i Dashboard. Den äldre textvariabeln `MIO_OPENAI_MODEL` är borttagen.
- Worker Access kräver inloggning för all trafik på både produktions- och förhandsvisningsadresser. Zero Trust-appen `Mio service token` har en Service Auth-policy som inkluderar endast tjänstetoken `Mio iPhone`. Tjänstetoken är aktiverad och löper ut 2027-09-29, men Dashboard anger **Not Seen Yet**: inget lyckat Access-anrop med den har verifierats.
- Anonyma HTTPS-anrop till `/health`, `/v1/ask`, `/v1/analyze` och `/v1/lesson-notes` gav alla HTTP 403 från Cloudflare Access. Detta verifierar den yttre spärren, inte gatewaytoken, Groq-nyckeln, modellåtkomst eller appens anslutning. Ingen AI-trafik skickades.
- Aktiv version `4c22cc43` skapades av ändringen av `MIO_GATEWAY_TOKEN`. De senaste tio versionerna i Dashboard är variabel-/Secret-ändringar; ingen ny gatewaykod eller build visas där. Arbetskopians Groq-/lektionskod är därför **inte verifierad som publicerad**. Den äldre iPhone-build 5 saknar Access-fälten och kan inte nå en Access-skyddad Worker. Nästa steg är publicering av avsedd gatewaykod efter uttrycklig begäran, nytt iOS-bygge/installation och syntetiska anslutnings- och modellprov.

## Anslutningsguide och Access-klient, 2026-09-29

- Ny guide för Groq/Qwen, självständiga provider-/modellbyten, gatewaytoken/rotation och Worker-specifik Access med Service Auth. Officiell Cloudflare-/Groq-dokumentation läst. Vid detta tidigare guidearbete ändrades inget Cloudflare-konto och liveskyddet var ännu inte verifierat; senare livegranskning står ovan.
- Appkoden har valfria Access-fält och gemensam Keychain-lagring med äldre tokenläsning. Tre nya XCTest-fall för format/rotation/headerhantering finns men är **inte körda**. Ingen Xcode-kompilering eller iPhone-verifiering av denna revision.
- **40/40 serverprov godkända** med Node v26.10.0, mockad AI och localhost. Första sandboxkörningen blockerades av `listen EPERM`; körning med nödvändig localhost-åtkomst passerade.
- **Worker dry-run och lokal workerd/Miniflare godkända** med Wrangler 4.141.0: OpenAI/Groq, alla tre AI-rutters auth, D1-kvot och att Access-headers inte vidarebefordras till modellen. Ingen verklig Cloudflare Access-policy provas av mocktestet. Ingen modelltrafik eller publicering.
- **127 portabla strukturkontroller och `git diff --check` godkända**. Dessa är inte Swift-kompilering.
- Nästa enhets-/driftprov: ny IPA, AC01–AC05 samt Qwen med syntetisk fråga/vardag/lektion enligt guiden. Gatewaykoden måste fortfarande publiceras; Access är nu konfigurerat men tjänstetoken behöver provas.

## Ny arbetskopia: AI-/lektionsändringar 2026-09-28

**Inte publicerad, inte Xcode-kompilerad och inte iPhone-verifierad.** Den tidigare build 5 och driftsatta gatewayen nedan innehåller inte dessa ändringar.

- Implementerat i arbetskopian: åtta leverantörspresets + custom, neutralt modellval och separata hemligheter, reasoning av/temperatur 0/strikt schema, detaljerade lektionsdelar med källor och metadata, kopiering, framsteg och manuell fortsättning.
- **40/40 serverprov godkända** med Node v26.10.0 och simulerade modeller. Kontrollerar bland annat nio adapterkonfigurationer, inkompatibilitet, schema, källvalidering, 429, timeout och kvoter. Inga verkliga modell-/betalningsprov.
- **Worker dry-run och lokal workerd/Miniflare godkända**, både OpenAI Responses och Groq Chat Completions inklusive nya lektionsrutten och D1. All upstream-trafik fångad i mock; inget publicerat.
- **121 portabla strukturkontroller godkända**. Sju nya XCTest-fall finns i koden men har inte körts på denna Linux-värd. De 48 godkända testen nedan gäller endast den äldre revisionen.
- Återstår: Xcode Release/XCTest, ny IPA, publicering efter uttrycklig begäran, samt P01–P04 och L06–L11 på telefon med vald modell. Semantisk kvalitet, faktisk temperatur-/reasoningefterlevnad, latens och kostnader är ännu inte verifierade hos leverantörerna.

## Tidigare verifierad revision — build 5


Senast uppdaterad: **2026-09-28**. Helhetsbygge **0.9.0, ej släppt**. **Build 5** för `1b4ae6c` på `main` har klarat Release och **48 XCTest** i Actions 36382509184. IPA:n är nedladdad och kontrollerad. Gatewayens hälsokontroll svarade HTTP 200 den 28 september; riktiga modellprov saknas. Telefonprov för denna revision och verkliga modellprov återstår.

**Build 5 innehåller** installation av stödd svensk SpeechTranscriber vid start och utökad diagnostik. 113 strukturella kontroller passerar. Release, testkompilering och 48 simulatorprov är godkända; automatisk modellinstallation och svenskstöd på måltelefonen är fortfarande **ej verifierade**.

Detta är den gemensamma statuskällan. [Ändringsloggen](../CHANGELOG.md) beskriver innehållet och [helhetstestet](TESTPLAN_HELHET.md) beskriver återstående acceptansprov.

## Historiskt verifieringsläge — build 5, 2026-09-28

| Område | Resultat och begränsning |
|---|---|
| Källkod | Build 5 lägger till installation före fallback och språk-/assetdiagnostik. Build 4 kompletterar build 3 med riktigt lektionsläge, löpande aktiverad AI-tolkning av vanligt samtal, strukturerade systeminstruktioner och bättre motordiagnostik. Den äldre beskrivningen av hela omfånget som färdigt var för bred. |
| Portabel projektkontroll | Godkänd på Linux med `python3 scripts/verify_project.py`: projektregistrering, plist/XML, identitet, version, resurser, lagringsvägar, dokumentlänkar, workflow/Bash och whitespace. |
| Swift-syntaxparser | Tree-sitter-försöket kraschade i lokal parser/bindning och räknas inte som en godkänd kontroll. Xcode har därefter kompilerat den nya appen och godkänt 48 XCTest i build 5. |
| Serverns tester | **22 av 22 godkända**, Node v26.10.0, med simulerad leverantör och lokal HTTP-testserver. Inga verkliga AI-anrop eller kostnader. |
| Appikon | Tre opaka RGB-varianter, 1024 × 1024: standard, mörk och tonad. Standardikonen visuellt granskad som PNG. Ingen verifiering av ikonrendering på iOS ännu. |
| Xcode / Release | **Godkänd** för commit `1b4ae6c` i Actions 36382509184 på runner `GitHub Actions 1000000012` med etiketten `xcode-27`, Xcode 27.0 (27A266a), iOS SDK 27.0. Inga kompilatorvarningar i slutloggen. |
| XCTest | **48 av 48 godkända** för `1b4ae6c` på iOS 27-simulator (iPhone 17). |
| IPA / installation | **0.9.0 (5)** skapad och lokalt ZIP-/plist-/SHA-256-kontrollerad. Identiteten är `app.mio.assistant`, minsta iOS 26.0. **Ingen fysisk installation verifierad.** |
| Design och tillgänglighet | Native Liquid Glass-kontroller och systemnavigation implementerade. iOS-rendering, VoiceOver, större text, mörkt läge och tillgänglighetsinställningar återstår att prova. |
| Telefonprov | Användaren har lämnat ett privat prov från 2026-09-26, se nedan. Byggnummer/enhets- och iOS-version saknas i exporten; inget komplett acceptansprov är styrkt. |
| AI i drift | **Cloudflare Worker publicerad**, D1-kvottabell skapad och separat gatewaytoken sparad som Secret. Vid granskning 2026-09-28 svarar `/health` HTTP 200; det verifierar konfigurationskontrollen, inte nyckelns giltighet, modellåtkomst eller saldo. Ingen riktig modellfråga provad. Molnet i appen är avstängt tills användaren konfigurerar och aktiverar det. |

Serverproven kontrollerar autentisering, routning, exakt godkänd payload, storleksgränser, sanitiserade fel, begränsning av antal anrop, timeout och redirects. De ersätter inte ett prov med en verklig HTTPS-server. De lokala kontrollerna ersätter varken Xcode, XCTest eller fysisk telefon.

Appidentiteten är nu `app.mio.assistant`. De tre lokala lagren ligger under `Mio/`; den raderade prototypen migreras inte. Minsta iOS-version är 26.0 och avsedd byggmiljö är Xcode 27.

## Verifierad IPA

- Byggd appcommit: `1b4ae6ccc41495e0645fb421f789e96785ab6e66` på `main`.
- [Grön Actions-körning 36382509184](https://github.com/kanonmaten/mio/actions/runs/36382509184).
- [Hämta artifacten Mio-IPA](https://github.com/kanonmaten/mio/actions/runs/36382509184/artifacts/10953378415), sparad i 14 dagar. Packa upp ZIP-filen och installera `Mio-unsigned.ipa` via SideStore.
- Version **0.9.0**, build **5**. SHA-256 för IPA:n: `e5dc9c7e9cf07443abfc41fb26d0f4faca9ca8750376811920b4f21d60733a96`.
- ZIP-integritet och Info.plist kontrollerade lokalt. `app.mio.assistant`, minsta iOS 26.0. Inga kompilatorvarningar i byggloggen. Ingen telefoninstallation verifierad.
- Efterföljande dokumentationsändringar ändrar inte den byggda appkoden; servern körs separat.

Historiskt: build 4 (`595e4a8`, Actions 36278717100) klarade 46 XCTest. Build 3 (`f53aaa1`, Actions 36228684153) klarade 39 XCTest. Build 2 (`3d4b041`, Actions 36204571782) klarade också 39 men hade en kalenderdelegatvarning som rättades i build 3. De resultaten verifierar inte nya funktioner i build 5.

## Historisk provordning — 2026-09-28

1. Installera IPA:n enligt [installationsguiden](INSTALLATION.md), först på iPhone 16 Pro.
2. Kör först S01–S07 för svensk talmodell, därefter H01–H15 i [helhetstestet](TESTPLAN_HELHET.md). Börja med syntetiska data och håll AI avstängt.
3. Prova behörigheter, tillgänglighet, dagbyte och radering. Kör sedan låst skärm, avbrott och längre batteriprov enligt [transkriptionstestet](TESTPLAN_V0_1.md).
4. När [Cloudflare-gatewayen](../server/cloudflare/README.md) eller egen server är konfigurerad: kör AI01–AI06, A07–A14 och L01–L05 med syntetiska data.

[Användarguiden](ANVANDNING.md) beskriver de dagliga flödena. Byggfel och telefonfynd ska åtgärdas innan helhetsbygget betraktas som verifierat.

## Historisk evidens

[Telefonprovet 2026-08-20](TESTRESULTAT_V0_1.md) gäller en äldre revision på iPhone 13: 2 min 30 s, fem textsegment, två Mio-detektioner och DictationTranscriber med `sv_SE`. Bara elva sekunders bakgrund finns dokumenterat. Mätvärdena är oförändrade och bevisar inte aktuell versions funktion.

Tidigare statiska kontroller av v0.2.0 och byggflödet finns i projekthistoriken. Den äldre [testplanen v0.2](TESTPLAN_V0_2.md) är historiskt underlag; nya installationer följer helhetstestet.

I den historiska Apple-implementationen krävde `SpeechTranscriber`-installation, bakgrundsdrift och ljudavbrott fysisk telefon. Den aktuella appen använder original Pianissimo utan Apple-/CPU-fallback; paus och avbrott kräver manuell fortsättning. Följ den aktuella [enhetsprovningen](ENHETSPROV.md).

## Registrera nya resultat

Ange **commit, Actions-URL, IPA-kontrollsumma, appversion/byggnummer, iPhone-modell, iOS-version, test-ID, observation och resultat**. Använd Godkänd, Underkänd, Blockerad eller Ej körd. Spara bara avidentifierade slutsatser här; råexporter förvaras privat. En ny revision är inte verifierad av ett äldre grönt resultat.

## Användarens privata export 2026-09-26

Lokalt granskad, inte kopierad till Git eller skickad till AI: tre sessioner, totalt 111 textsegment, inga lagrade assistentförslag eller lektioner. Alla tre startade DictationTranscriber med sv_SE. Två visar ljudavbrott följda av Session activation failed. En längre session var cirka 33 minuter och 45 sekunder och hade batteripunkter 100 → 90 procent; detta är inte ett kontrollerat batteritest.

Exporten saknar appbuild/exakt iOS och tillräcklig diagnostik för att fastställa varför SpeechTranscriber inte valdes. Utan ljudreferens kan igenkänningsprecision inte mätas. Nya diagnostiska fält gör nästa prov mer användbart; inget motorbyte eller förbättrad igenkänningskvalitet är verifierat.

Portabel kontroll efter gatewaytillägget: 113 strukturella kontroller godkända. Server: 22 syntetiska/mockade tester godkända. Nya XCTest-fall för fragment, källvalidering, radering, gammal text vid aktivering och avbruten kö ingår i de 46 godkända XCTest-fallen. Kör L01–L05 och A07–A14 för den nya revisionen.

## Cloudflare-gateway 2026-09-27

`wrangler deploy --dry-run` godkänd med Wrangler 4.141.0. Det faktiska bundlade Worker-paketet har körts i lokal workerd/Miniflare med simulerad modell: hälsa, autentisering, ogiltiga payloads, enskild fråga, analys och beständig dygnsgräns godkända. All modelltrafik fångas i testet, inga riktiga API-anrop. Kvotens atomiska SQL är även provad mot SQLite.

Node-kompatibiliteten krävde explicit hantering av headeralternativ, timers och redirect-status; dessa rättningar ingår i testat paket. Projektkontrollen undantar nu installerade beroenden och genererade Worker-filer.

Efter användarens OAuth-godkännande och e-postverifiering publicerades gatewayen på `https://mio-private-gateway.mio-private-gateway.workers.dev`. Första publicerade kodversion: `4eb6e89a-f2fb-4ff5-8f7f-4468facba325`; därefter lades gatewaytoken till som separat Secret. D1-databasen `mio-limits` skapades och kvotschemat importerades. Inga transkript lagras där.

Första konfigurerade provmodell är `gpt-6-luna`. HTTPS-kontrollen gav väntat 503 `gateway_not_configured` innan `OPENAI_API_KEY` lagts in. Det verifierar publicering och konfigurationsspärr, inte modellåtkomst, autentisering i fullt konfigurerad drift eller AI-kvalitet. Senare hälsokontroll 2026-09-28 gav HTTP 200. Syntetiska prov med riktig modell återstår tills användaren vill använda API-saldo. [Driftguide](../server/cloudflare/README.md).
