# Bygg- och teststatus

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

Kvarvarande funktionsbegränsning, identifierad vid eftergranskning: vardags-AI samlar flera textdelar per anrop men återför inte tidigare textkontext över gränsen till nästa anrop. En mening/plan som korsar den gränsen kan därför missas eller bli ofullständig. Lokal Mio-kommandotolkning arbetar också per textsegment. Ljudets överlappning löser inte detta; begränsad textkontext, deduplicering och regressionstester återstår.

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

## Aktuellt verifieringsläge

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

## Nästa kontroller

1. Installera IPA:n enligt [installationsguiden](INSTALLATION.md), först på iPhone 16 Pro.
2. Kör först S01–S07 för svensk talmodell, därefter H01–H15 i [helhetstestet](TESTPLAN_HELHET.md). Börja med syntetiska data och håll AI avstängt.
3. Prova behörigheter, tillgänglighet, dagbyte och radering. Kör sedan låst skärm, avbrott och längre batteriprov enligt [transkriptionstestet](TESTPLAN_V0_1.md).
4. När [Cloudflare-gatewayen](../server/cloudflare/README.md) eller egen server är konfigurerad: kör AI01–AI06, A07–A14 och L01–L05 med syntetiska data.

[Användarguiden](ANVANDNING.md) beskriver de dagliga flödena. Byggfel och telefonfynd ska åtgärdas innan helhetsbygget betraktas som verifierat.

## Historisk evidens

[Telefonprovet 2026-08-20](TESTRESULTAT_V0_1.md) gäller en äldre revision på iPhone 13: 2 min 30 s, fem textsegment, två Mio-detektioner och DictationTranscriber med `sv_SE`. Bara elva sekunders bakgrund finns dokumenterat. Mätvärdena är oförändrade och bevisar inte aktuell versions funktion.

Tidigare statiska kontroller av v0.2.0 och byggflödet finns i projekthistoriken. Den äldre [testplanen v0.2](TESTPLAN_V0_2.md) är historiskt underlag; nya installationer följer helhetstestet.

`SpeechTranscriber`-installation, stabil bakgrundsdrift och ljudavbrott kräver fysisk telefon. Ett ljudvägsbyte kan kräva stopp/start. iOS återstartar inte lyssning efter tvångsavslutning; tidsstyrd paus kan kräva att appen öppnas igen.

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
