# Bygg- och teststatus

Senast uppdaterad **2026-11-21**. Version **0.9.1, ej släppt** (0.9.0 är revisionen `8f90ddc`, ej taggad). Den här filen innehåller bara vad som faktiskt är kontrollerat. Äldre poster finns i Git-historiken (`git log -- docs/STATUS.md`). [Ändringsloggen](../CHANGELOG.md) beskriver vad koden gör; [helhetstestet](TESTPLAN_HELHET.md) beskriver acceptansproven.

## Grillningen, 2026-11-20–21

[Planen](PLAN_GRILLNING.md) genomförd i fyra vågor, `0832127` till sista commiten. Inget är installerat på datorn, ingen riktig modelltrafik har körts och inget är provat på telefonen.

| Kontroll | Resultat |
|---|---|
| Hela grinden, lokalt | `mio-verify verify` godkänd genom pre-push-kroken före varje push: `01fed99` (våg 2), `a4cbd76` (våg 3), `7be253d` (våg 4) och sista commiten. `swift-core` 456 tester, `project` 356 strukturkontroller, gatewayen 155 tester, Pianissimo 133 tester, Mio Kontroll 120 tester, alla utan fel. |
| Linux-grinden på GitHub | Godkänd i båda jobben för `0832127`, `01fed99`, `a4cbd76` och `7be253d`. |
| Bygg Mio IPA vid push | `01fed99` (#64), `a4cbd76` (#65) och `7be253d` (#66): IPA skapad och enhetstesterna godkända. I #65 föll först `AudioReliabilityTests.testGracefulStopExpiresOriginalAudioBeforeSlowGapCallbackCompletes` (tidsberoende, ljudkoden oförändrad) och godkändes vid omkörning av det felade jobbet. #65 visade också att `actool` godtar den handbyggda `AppIcon.icon`. |
| Bygg Mio IPA med UI-tester och diagnostik | [#67](https://github.com/kanonmaten/mio/actions/runs/44877236904) på `7be253d`, manuell: IPA skapad, 469 enhetstester godkända, diagnostiken `PASS: complete-concurrency diagnostic, no relevant warnings.` (kvar är bara iOS 27-avrådningar för ljud-API:er). UI-testet `testSettingsSheetLeadsToPairingTranscriptionAndAI` föll två gånger: "Avancerat" ligger nu sist i en lat lista och fanns inte förrän den scrollats fram. Testet scrollar nu (`f0058ed`). Den manuella körningen med UI-tester och diagnostik för sista commiten startas efter att den här filen skrivits; resultatet står i överlämningen och förs in här vid nästa ändring. |
| Skärmbilder | Från #67 (ljust läge, simulator): Lektioner, Förslag, Fånga och inställningsarket ser rena ut; arket visar "Något är fel" eftersom simulatorn inte är parad. UI-testerna tar inga bilder i mörkt eller tonat läge och ingen bild av hemskärmen; ikonens PNG-filer i ljust, mörkt och tonat läge är granskade för hand. Glaslagren i `AppIcon.icon` är inte sedda på en enhet. |
| Telefon och dator | Inget provat. Se provlistan i [helhetstestet](TESTPLAN_HELHET.md#efter-grillningen--nya-prov-ej-körda-på-iphone) och [Prov på datorn](../control/README.md#prov-på-datorn). |

## Snabbare CI, 2026-11-20

CI-planen från 2026-11-20 ([beslut](DECISIONS.md#snabbare-utvecklingsslinga-i-ci-2026-11-20)), `aae9ff8` till `ebbbac2`. Tiderna är uppmätta från stegens start- och sluttider i GitHub. "Efter" är push-körningar på den slutliga uppsättningen.

| Vad | Före (#49, Linux #170) | Efter |
|---|---|---|
| IPA uppladdad efter pushen | Ingen push-körning; cirka 2 min efter manuell start (#49) | 1 min 15 s ([#58](https://github.com/kanonmaten/mio/actions/runs/44743278927), `a53084d`), 1 min 51 s ([#60](https://github.com/kanonmaten/mio/actions/runs/44747809326), `ebbbac2`); 1 min 28 s–3 min 14 s i #50–#57 |
| Release-bygget | 1 min 43 s | 1 min 1 s (#58), 1 min 34 s (#60) |
| Testjobbet utan UI-tester | Fanns inte; hela körningen cirka 19 min med UI-tester | 12 min 20 s (#58), 11 min 57 s (#60), 9 min 12 s (#62); 9 min 5 s–20 min i #50–#57. **Målet 8 min nåddes inte.** |
| Kompilera testerna | 4,5 min (9 min i #47) | 5 min 40 s (#58), 4 min 14 s (#60); själva bygget 1 min 40 s utan simulator igång (#52) |
| Enhetstesterna | 4,8 min (1,8 min i #47) | 1 min 50 s (#58), 2 min 25 s (#60) |
| UI-tester | 7 min | Bara nattligen, på `v*`-taggar och manuellt |
| Strikt concurrency-diagnostik | 2,4 min | Bara nattligen, på `v*`-taggar och manuellt |
| Verifiera Mio på Linux, hela körningen | cirka 5,3 min | 2 min 41 s ([184](https://github.com/kanonmaten/mio/actions/runs/44743278956), `a53084d`), 2 min 34 s ([185](https://github.com/kanonmaten/mio/actions/runs/44743760134), `408560c`), 2 min 37 s ([186](https://github.com/kanonmaten/mio/actions/runs/44747809261), `ebbbac2`) |
| Linux: container och apt | cirka 50 s | 26–33 s plus 5–7 s |
| Linux: återställa Rust-cachen | 2 min 8 s | `verify`-jobbet 13 s; `control`-jobbet 53 s, parallellt (körning 186) |
| Linux: `verify` | 1 min 55 s | 1 min 27 s med `--skip-control`; `control`-jobbets clippy och tester 14 s varma (körning 186) |

Varför testjobbet inte når 8 min: en nystartad iOS 27-simulator mättar runnern i 6–15 minuter. I #50 stod xcodebuild tyst i 6 min 42 s innan kompileringen började, i #53 och #59 tog utcheckningen 6–7 min, och i #52 stannade även runnerns egen logg. När simulatorn hade hunnit bli klar tog enhetstesterna 1 min 29 s (#51). Byggcachar (#54–#59) och att starta simulatorn efter kompileringen (#52) hjälpte inte; se besluten.

| Kontroll | Resultat |
|---|---|
| Hela grinden, lokalt (Rust 1.100, Swift 6.4.2) | `mio-verify verify` godkänd genom pre-push-kroken före varje push med kod, senast på `ebbbac2`. Kroken stoppade en push när strukturkontrollen inte godtog plan-jobbet (rättat i `185f6b5`). |
| Linux-grinden på GitHub | Godkänd för den sista commiten i varje push, senast `ebbbac2` (körning 186, båda jobben); körningar för mellanliggande commits avbröts av nästa push. En körning på `185f6b5` föll på `AudioReliabilityTests.testRetryPreservesChunkIdentityAndOriginalExpiry`, ett tidsberoende test som rättades i `7ac9e50`. |
| Bygg Mio IPA vid push | Godkänd för `185f6b5` (#50), `7ac9e50` (#51), `a4468dc` (#52), `26ba0f5` (#53), `4a50a15` (#54), `7ffa809` (#56), `0ab1d4d` (#57), `a53084d` (#58) och `ebbbac2` (#60): IPA skapad och enhetstesterna godkända (370 i #60), UI-tester och diagnostik överhoppade som avsett. ntfy-steget hoppade över sig utan `NTFY_TOPIC`. |
| Bygg Mio IPA med UI-tester och diagnostik | [#63](https://github.com/kanonmaten/mio/actions/runs/44756191768) på `b49c85e`, manuell med `uitester` och `diagnostik`: godkänd i första försöket. IPA skapad, enhetstesterna och alla UI-tester godkända (UI-steget 5 min 38 s), diagnostiken `PASS: complete-concurrency diagnostic, no relevant warnings.` (2 min 36 s). Före rättelsen: [#61](https://github.com/kanonmaten/mio/actions/runs/44747809597) på `ebbbac2`, manuell med `uitester` och `diagnostik`: IPA skapad, enhetstesterna godkända, tre av fyra UI-tester godkända; `testThreeTabsPlusCaptureButtonAndIndependentActivityStates` hängde i simulatorn och startades om (samma häng som #31, #33, #47). Diagnostiken rapporterade fyra concurrency-varningar, men det var tre iOS 27-avrådningar som verifieraren räknade fel (rättat i `36835e7`; riktiga concurrency-varningar: noll). Omkörningen av det felade jobbet godkände alla fyra UI-tester. |
| Nattkörning (`schedule`) | **Inte körd ännu.** Plan-jobbet är provat för push och manuell start; jämförelsen med senaste lyckade nattkörning körs först i natt. |
| Telefon | Ingen ändring i appen. Ingen ny IPA är installerad eller provad på telefonen. |

## Lägsta iOS-version 27.0, 2026-11-18

Lägsta iOS-version höjd till 27.0 och reservvägen för iOS 26.0 i lyssningsraden borttagen ([beslut](DECISIONS.md#lägsta-ios-version-270-2026-11-18)).

| Kontroll | Resultat |
|---|---|
| Hela grinden, lokalt (Rust 1.100, Swift 6.4.2, uv 0.13.8) | `mio-verify verify` godkänd på arbetskopian före commit, alla tolv steg, strukturkontrollen med "Minst iOS 27.0". Samma grind var godkänd på `c9bffb8` före ändringen. |
| Bygg Mio IPA, simulatortester, telefon | **Ej körda.** iOS-bygget med lägsta version 27.0, lyssningsraden och installation via SideStore är overifierade. |

## Mio Kontroll och fler AI-leverantörer 2026-11-17 (`b55fd38`–fas 10)

Kontrollpanelen i `control/` enligt [planen](PLAN_KONTROLLPANEL.md), fas 0 till 10, och fler leverantörer i gatewayen. Se [Mio Kontroll](../control/README.md), [ändringsloggen](../CHANGELOG.md) och [besluten](DECISIONS.md).

| Kontroll | Resultat |
|---|---|
| Hela grinden, lokalt (Rust 1.100, Swift 6.4.2, uv 0.13.9) | `mio-verify verify` godkänd efter varje fas innan den committades, senast på arbetskopian som blev `d2ee211` (fas 9): 286 strukturkontroller, clippy utan varningar för verifieraren, gatewayen och `control/`, 10 tester för verifieraren, 119 gatewaytester (pariteten mot Node oförändrad), 94 tester i `control/` (kärnan, hjälparen och 18 gränssnittstester med låtsade hjälpare i ett fönster utan skärm), 99 pytest, 357 portabla XCTest, 13 återhämtningsprov och portabel concurrency utan varningar. I fas 7 överskred steget `control-tests` grindens tio minuter medan det byggde (inget test underkänt); gränssnittstesterna lades då i ett testprogram och omkörningen godkändes. |
| Linux-grinden på GitHub | Godkänd för varje fas: `b55fd38` (fas 0, körning 44092058162), `1759bf5` (1, 44095535441), `6a019c5` (2, 44114176175), `fce4477` (3, 44125918662), `191ce01` (44142122637), `6fce695` (4, 44145802115), `af86fd3` (5, 44149620116), `580ffcb` (6, 44152473826), `1b924cf` (7, 44158268946) och `58810b8` (8, 44161094020) och `d2ee211` (9, 44163069294). Fas 10 ändrade bara dokument; dess körning står i överlämningen. |
| Den bärbara datorn (Omarchy, Hyprland, Intel HD 6000) | I fas 0: fönstret ritas med det mörka temat och ikonen registreras hos `StatusNotifierWatcher`. Senare sidor är bara provade i gränssnittstesterna. |
| `cachyos-pc` med KDE Plasma 6.8 och NVIDIA | **Inte provat.** Fönstret, rundade hörn, ljust läge, ikonen i Plasmas systemfält, polkit-rutan, Konsole, journalen, viloläget och installationsskriptens nya `commit`-fil är overifierade. Listan står i [Mio Kontroll](../control/README.md#prov-på-datorn). |
| Riktig modelltrafik | **Inte körd.** Anthropic, Mistral och NVIDIA är bara provade mot en syntetisk transport; Prova är aldrig kört mot en leverantör. |
| Telefon | Ingen ändring i appen. Att telefonen fortsätter utan ny parning efter ett modellbyte är **inte provat**. |

## Rättelser efter kodgranskningen 2026-11-17 (`0c6fd84` och framåt)

De 25 fynden från tre ultrareview-körningar på `1d089a0`, ett i taget; se [ändringsloggen](../CHANGELOG.md) och [besluten](DECISIONS.md).

| Kontroll | Resultat |
|---|---|
| Hela grinden, lokalt (Rust 1.100, Swift 6.4.2, uv 0.13.8) | `mio-verify verify` godkänd på den rena commiten `2dacf41`: 266 strukturkontroller, clippy utan varningar för verifieraren och gatewayen, verifierarens tester, 103 gatewaytester (pariteten mot Node oförändrad), 95 pytest, 356 portabla XCTest, 13 återhämtningsprov och portabel concurrency utan varningar. Efter varje ändring av appens kärna kördes `swift-core`, efter varje gatewayändring `cargo test` och clippy. Testet för A4 (batchstorleken) och testet för B3 (godkännandet) underkändes utan sin rättelse. Efteråt sparas överhoppad text över omstart (A1, `c765d5f`): hela grinden godkänd på `c765d5f` och på `2612f9a` med 357 portabla XCTest (första körningen på `c765d5f` överskred tidsgränsen i ett ljudtest utan underkänt påstående; omkörningen godkänd). Linux-grinden på GitHub godkänd för `2612f9a`. |
| Xcode (IPA-workflowen) | [Körning #49](https://github.com/kanonmaten/mio/actions/runs/44075315281) för `2612f9a` (0.9.1, bygge 49), startad av användaren: IPA skapad, 370 enhetstester och fyra UI-tester godkända, native concurrency utan varningar. Därmed är också de ändringar som bara finns för iOS kompilerade: D2 (Parning), E1 (Fråga Mio), E2 (Historik), E4 (förslagets datum), E5 (texten på Fånga), F1 (`TranscriptionClient` och testet i `TranscriptionTests`), F2 (`MioSystemServices`) och resolvern i B1/B2 (`MioStoreBootstrap`). Hur de beter sig på telefonen är **inte provat**. |
| Datorn, Groq och telefonen | **Inte körda.** Ingen riktig modelltrafik och inga anrop till servrarna; `install.sh`, `mio-pair` och Pianissimos installation är inte körda. |

## Aktuellt bygge: helhetsbygget 2026-10-11

Klart på `main`: gateway på datorn med Groq, Pianissimo med förbehandling och talarmärkning, pausstyrda ljuddelar, automatisk omstart av mikrofonen, Live Activity, fortsatt bearbetning av lektionsanteckningar, QR-parning, AI på som standard, inställningspanel, SwiftData och den nya designen (veckoplaneraren, se [DESIGN.md](../DESIGN.md)).

| Kontroll | Resultat |
|---|---|
| Verifieraren i Rust (Rust 1.100, Swift 6.4.2, uv 0.13.8, lokalt, 2026-11-17) | Hela grinden godkänd genom `mio-verify verify --measure-session-store` på den rena commiten med bytet: 266 strukturkontroller, clippy utan varningar och 10 tester för verifieraren, 98 gatewaytester, 95 pytest, 341 portabla XCTest, 13 återhämtningsprov, portabel concurrency utan varningar och långhistoriemätningen. Före raderingen av Pythonskripten jämförda mot dem: identiska genererade Swiftfiler (35), identisk provenans och samma strukturresultat på arbetskopian och tio trasiga kopior (se [besluten](DECISIONS.md)). Python-grinden godkänd som utgångsläge på `2c8d547`. Native concurrency i "Bygg Mio IPA" med Rustversionen är **inte körd**. |
| Gateway i Rust (Rust 1.100, lokalt, 2026-11-16) | Hela `verify.py` godkänd på arbetskopian med Rust-bytet: 264 strukturkontroller, 5 verifierarprov, clippy utan varningar, 98 gatewaytester (varav parität mot cirka 2 600 inspelade fall och 86 HTTP-utbyten från Node-versionen), 95 pytest, 341 portabla XCTest, återhämtningskontrollen och den portabla concurrency-kontrollen. Live mot Node- och Rust-servern sida vid sida: 16 av 16 modellfria anrop gav samma status, rubriker och kropp. `install.sh` och `mio-pair` är **inte körda** på datorn; hjälpkommandona är provade mot en tillfällig fil. Ingen riktig Groq-trafik. |
| Gateway (Node 22.22, lokalt, ersatt 2026-11-16) | 97 av 97 godkända för `ef6b57a` (prompter och release `2026-10-13.2`, sexton källor per anrop); 96 av 96 för `5ba9228`. Tidigare: 95 av 95 för `39e6d02` och `01e98bb`. Syntetisk Groq-transport, ingen riktig modelltrafik. Projektets fästa Node 26.10 fanns inte i molnmiljön. |
| Pianissimo (pytest, lokalt) | 99 av 99 godkända med falska modeller 2026-11-17 med FP16-inställningen (standard `fp16` från samma dag, 99 av 99 och strukturkontrollerna igen efter bytet), i hela grinden `mio-verify verify` (269 strukturkontroller, 103 gatewaytester, 357 portabla XCTest, återhämtning och concurrency godkända). FP16 på GPU:n, dess hastighet och ordfel är **inte provade**. Tidigare 82 av 82 efter säkerhetsuppdateringen 2026-10-12 (NeMo 3.0.0). `pip-audit` på låsfilen: bara två Lightning-råd kvar. NeMo 3.0.0 importerar modellklasserna med de nya versionerna, men riktig modellladdning, Sortformer, svensk talarkvalitet, GPU-minne och effekten av förbehandling är **inte provade**. |
| Strukturkontroll | `verify_project.py`: 249 kontroller, 0 fel för `72dbf43`; 239 kontroller, 0 fel för `01e98bb`. |
| Linux Swift-grind | GitHub-körning 83–86 och 88–90 godkända för `6dd2d20`, `5ba9228`, `ef6b57a`, `8f90ddc`, `32c002c`, `1da32fd` och `b72bf7e` (körning 87 för `62f17ee` avbröts av nästa push). Lokalt med Swift 6.3.3: 330 XCTest och portabel concurrency godkända för `b72bf7e`. Tidigare: godkänd för `7ec91e7`, `f96a4df`, `c10fd3e`, `75b58b8`, `8dc0025`, `e7b41b8`, `72dbf43` och `01e98bb` ([körning 78](https://github.com/kanonmaten/mio/actions/runs/38358567403)). Körning 77 för `0aeda5b` underkänd: testet för AI-genomgångar kompilerade inte (rättat i `01e98bb`). |
| Xcode (IPA-workflowen) | Körning #30 för `8dc0025`: strikt concurrency, Release-bygge med Live Activity-tillägget, alla enhetstester och UI-tester i simulatorn godkända, IPA skapad. Skärmbilderna visade att tonen blev systemblå; rättat i `e7b41b8`. Körning #31 för `e7b41b8`: bygge och enhetstester godkända, men UI-testet för att markera en uppgift klar överskred sin tidsgräns två gånger, eftersom simulatorn för iOS 27 rapporterade appen som upptagen i 60 s efter ett tryck. Orsaken är inte hittad; testets tidsgräns höjdes i `72dbf43`. **Körning #32 för `72dbf43`: allt godkänt** (strikt concurrency, Release-bygge med Live Activity-tillägget, enhetstester och tre UI-tester, skärmbilder med violett ton), IPA skapad: artefakten `Mio-IPA` (sha256 `8955fed6…c913`, version 0.9.0, bygge 5), [körning #32](https://github.com/kanonmaten/mio/actions/runs/38184332670). IPA-filens egen kontrollsumma står i `Mio-buildinfo.txt` i artefakten. Körning #33 för `e009ef3` misslyckades på stegets tidsgräns: samma UI-test hängde och simulatorn stod sedan still; ingen IPA skapades. Workflowen delades därefter upp i enhets- och UI-teststeg; körning #35 för `9089bb3` tog 21 min. Från 2026-10-13 bygger ett eget jobb IPA:n parallellt med testerna. Körning #37 för `034cdbc` och #38 för `8f90ddc` (0.9.0): IPA skapad och enhetstester godkända, men UI-testet för att markera en uppgift klar hängde igen och den native concurrency-diagnosen visade 88 varningsblock i båda (steget stoppar inte jobbet; varningarna finns i SwiftData-predikat, AlarmKit, Live Activity, en miljönyckel och batteriobservatörer, inte i ändringarna från 2026-10-13). **Körning #39 för `b72bf7e` (0.9.1, bygge 39): IPA skapad, enhetstester, tre UI-tester (inklusive Förslag-flikens tillgänglighetsgranskning) och skärmbilder av Hem godkända**; native concurrency oförändrat 88 varningsblock. [Körning #39](https://github.com/kanonmaten/mio/actions/runs/38421316110). |
| Strikt concurrency | Native-steget i "Bygg Mio IPA" underkänt i körning #37–#39 (senast [#39](https://github.com/kanonmaten/mio/actions/runs/38421316110) för `b72bf7e`: 88 varningsblock från fem orsaker), men steget stoppar inte IPA:n. Rättat i `8d9cccc`. Där är hela `verify.py` godkänd i molnmiljön (Swift 6.3.3, Node 26.10): 256 strukturkontroller, 97 Node-tester, 82 pytest, 330 portabla XCTest och den portabla concurrency-kontrollen, som nu kör SIL-isoleringsanalysen. Native-steget är **inte kört** för `8d9cccc`. |
| Telefon | Varken 0.9.0 (bygge 38) eller 0.9.1 (bygge 39) är installerat eller provat. |

## Ändringarna 2026-11-15 och 2026-11-16 (`6777044`–`4aa5d0b`)

AI-kön mot Groqs minutgräns, ett nytt försök i gatewayen, validering per förslag, egna ord i transkriptionen, grafit och blått med glaskort samt ett inställningsark. Se [ändringsloggen](../CHANGELOG.md) och [besluten](DECISIONS.md). `9b0e79a` dämpade det blå ljuset och höjde kontrasten i mörkt läge efter de första skärmbilderna; `56447fe` lade bara till skärmbilder i UI-testerna.

| Kontroll | Resultat |
|---|---|
| Hela `verify.py`, lokalt (Swift 6.4.2, Node 26.13, uv 0.13.8) | Godkänd på arbetskopian som blev `6777044`: 259 strukturkontroller, 101 Node-tester, 95 pytest, 341 portabla XCTest, återhämtningskontrollen och den portabla concurrency-kontrollen. Efter `6777044` ändrades bara färgvärden, dokument och UI-testerna; strukturkontrollen (263) är körd lokalt för dem. Före ändringarna föll ett ljudtest (`testOldReliableSampleExpiresBeforeConversionEvenWhenCallbackIsRecent`) en gång av tre körningar på samma kod; det är tidsberoende och inte utrett. |
| Linux-grinden på GitHub | Godkänd för `6777044` ([körning 43738573061](https://github.com/kanonmaten/mio/actions/runs/43738573061), Swift 6.3.3). |
| Xcode (IPA-workflowen) | Körning #41 för `6777044` och **körning #44 för `56447fe` (0.9.1, bygge 44, Xcode 27.1): IPA skapad, 353 enhetstester och tre UI-tester godkända, native concurrency utan varningar.** [Körning #44](https://github.com/kanonmaten/mio/actions/runs/43762643005); IPA-filens kontrollsumma står i `Mio-buildinfo.txt` i artefakten `Mio-IPA`. UI-testet för inställningar öppnar det nya arket, hittar Dator och stänger med Klar. |
| Skärmbilder från simulatorn | Granskade från körning #44: Hem i ljust och mörkt läge och i största textstorleken, samt Fånga, Inställningar och Förslag i ljust läge (ur UI-testernas resultat). Tom simulator utan parning och utan data, så listor med innehåll, lektioner, transkript och undersidorna i inställningarna är inte sedda. |
| Inställningarnas undersidor | [Körning #45](https://github.com/kanonmaten/mio/actions/runs/43765101756) för `5945fa2`: nytt UI-test öppnar Lektioner och, från inställningsarket, Parning, Transkription och AI, och går tillbaka; godkänt tillsammans med övriga tre UI-tester. Skärmbilderna av sidorna är granskade (ljust läge, oparad simulator). |
| Snabbpausen på Fånga (2026-11-16) | Hela `verify.py` godkänd lokalt på arbetskopian som blev `a2c2fb4`. [Körning #46](https://github.com/kanonmaten/mio/actions/runs/43823942971) för `a2c2fb4`: IPA skapad, 353 enhetstester och fyra UI-tester godkända; UI-testet hittar pausknappen bredvid brickorna, och skärmbilden är granskad. Att pausen faktiskt stoppar AI-anrop är inte provat mot en parad dator. |
| Lika höga brickor (`4aa5d0b`) | [Körning #47](https://github.com/kanonmaten/mio/actions/runs/43826439328): IPA skapad och 353 enhetstester godkända. I första försöket hängde UI-testet för Förslag redan vid appstarten (simulatorn väntade på att appen skulle bli ledig tills tidsgränsen löpte ut) och kördes inte om; de tre andra godkändes. Samma jobb kört en gång till på samma commit: alla fyra UI-tester godkända. Det är samma slags häng som i körning #31, #33, #37 och #38; orsaken är inte hittad, och ett av sex testjobb sedan `6777044` drabbades. Skärmbilden av Fånga visar brickorna i samma höjd. |
| Gatewayen över HTTP mot en efterbildad gratisnivå | Lokalt, gamla (`74dace1`) och nya gatewayen startade på loopback mot en transport som släpper igenom ett anrop bara om prompt + `max_tokens` ryms i 8 000 token per rullande minut (antagande: 4 byte per token). Gamla: en ikapp-batch (12 × 1 000 byte + 4 000 kontext) fick 429 `provider_quota` med 60 s väntan vid varje försök, och en fråga direkt efter en analys fick 429. Nya: ikapp-batcher erbjuds inte, samma batch får 413 `provider_request_too_large` utan kvot, en full vanlig batch går igenom och första frågan direkt efter en analys får svar. Det är en efterbildning, inte Groq. |
| Datorn med servrarna | `cachyos-pc` var offline i Tailscale under arbetet (senast sedd två timmar tidigare), så gatewayen och Pianissimo är **inte ominstallerade eller provade där**. |
| Riktig modelltrafik | **Inte körd.** Groqs 413-beteende, storleksanpassningen, det nya försöket och citatreparationen är bara provade mot en syntetisk transport. |
| GPU | **Inte körd.** Ordlistan för egna ord är provad med en syntetisk modell. |
| Telefon | **Inte installerat eller provat.** Anslutningsförsöken efter vila (Tailscale) och hur glaset ser ut på en riktig skärm är overifierade. |

## Verifierat på telefonen

Bara det som användaren faktiskt provat. Varje rad gäller den revision som står i den; ett nytt bygge kräver nytt prov.

| Datum | Revision | Vad | Resultat |
|---|---|---|---|
| 2026-08-20 | v0.1, iPhone 13 | Transkription 2 min 30 s, Mio-detektion ([mätningar](TESTRESULTAT_V0_1.md)) | Godkänd för den revisionen |
| 2026-09-26 | Före build 5 | Tre sessioner, 111 textsegment, cirka 34 min längsta | Ljudavbrott gav "Session activation failed"; inget kontrollerat batteriprov |
| 2026-10-05 | Build 5 + Cloudflare-gateway | Pianissimo-anslutning efter att en Quad9-DNS-profil stängts av | Fungerar (användarens rapport) |
| 2026-10-05 | Build 5 + Cloudflare-gateway med Groq | En enkel fråga ("hej") | Svar på telefonen (användarens rapport) |
| 2026-10-12 | Bygge 5 (exakt commit okänd), gateway release `2026-10-11.1`, iPhone 16 Pro, iOS 27.2 | Vardags-AI i 26 min enligt exporten: 11 genomgångar och en fråga nådde Groq och svarade med HTTP 200 (21 080 token, samma som Groqs konsol), ett anrop tog slut på tid och skickades om | Delvis: svaren sparades men gav 0 förslag och syntes inte i appen; rättat i `0aeda5b`/`01e98bb`, inte telefonprovat |

## Registrera nya resultat

Ange commit, Actions-URL, IPA-kontrollsumma, version/byggnummer, iPhone-modell, iOS-version, test-ID, observation och resultat (Godkänd, Underkänd, Blockerad eller Ej körd). Spara bara avidentifierade slutsatser här; råexporter förvaras privat.
