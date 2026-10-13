# Bygg- och teststatus

Senast uppdaterad **2026-10-13**. Helhetsbygge **0.9.0, ej släppt**. Den här filen innehåller bara vad som faktiskt är kontrollerat. Äldre poster finns i Git-historiken (`git log -- docs/STATUS.md`). [Ändringsloggen](../CHANGELOG.md) beskriver vad koden gör; [helhetstestet](TESTPLAN_HELHET.md) beskriver acceptansproven.

## Aktuellt bygge: helhetsbygget 2026-10-11

Klart på `main`: gateway på datorn med Groq, Pianissimo med förbehandling och talarmärkning, pausstyrda ljuddelar, automatisk omstart av mikrofonen, Live Activity, fortsatt bearbetning av lektionsanteckningar, QR-parning, AI på som standard, inställningspanel, SwiftData och den nya designen (veckoplaneraren, se [DESIGN.md](../DESIGN.md)).

| Kontroll | Resultat |
|---|---|
| Gateway (Node 22.22, lokalt) | 95 av 95 tester godkända för `39e6d02` och, med vardagsprompt `2026-10-13.1`, för `01e98bb`. Syntetisk Groq-transport, ingen riktig modelltrafik. Projektets fästa Node 26.10 fanns inte i molnmiljön. |
| Pianissimo (pytest, lokalt) | 82 av 82 godkända med falska modeller, senast efter säkerhetsuppdateringen 2026-10-12 (NeMo 3.0.0). `pip-audit` på låsfilen: bara två Lightning-råd kvar. NeMo 3.0.0 importerar modellklasserna med de nya versionerna, men riktig modellladdning, Sortformer, svensk talarkvalitet, GPU-minne och effekten av förbehandling är **inte provade**. |
| Strukturkontroll | `verify_project.py`: 249 kontroller, 0 fel för `72dbf43`; 239 kontroller, 0 fel för `01e98bb`. |
| Linux Swift-grind | Godkänd för `7ec91e7`, `f96a4df`, `c10fd3e`, `75b58b8`, `8dc0025`, `e7b41b8`, `72dbf43` och `01e98bb` ([körning 78](https://github.com/kanonmaten/mio/actions/runs/38358567403)). Körning 77 för `0aeda5b` underkänd: testet för AI-genomgångar kompilerade inte (rättat i `01e98bb`). |
| Xcode (IPA-workflowen) | Körning #30 för `8dc0025`: strikt concurrency, Release-bygge med Live Activity-tillägget, alla enhetstester och UI-tester i simulatorn godkända, IPA skapad. Skärmbilderna visade att tonen blev systemblå; rättat i `e7b41b8`. Körning #31 för `e7b41b8`: bygge och enhetstester godkända, men UI-testet för att markera en uppgift klar överskred sin tidsgräns två gånger, eftersom simulatorn för iOS 27 rapporterade appen som upptagen i 60 s efter ett tryck. Orsaken är inte hittad; testets tidsgräns höjdes i `72dbf43`. **Körning #32 för `72dbf43`: allt godkänt** (strikt concurrency, Release-bygge med Live Activity-tillägget, enhetstester och tre UI-tester, skärmbilder med violett ton), IPA skapad: artefakten `Mio-IPA` (sha256 `8955fed6…c913`, version 0.9.0, bygge 5), [körning #32](https://github.com/kanonmaten/mio/actions/runs/38184332670). IPA-filens egen kontrollsumma står i `Mio-buildinfo.txt` i artefakten. Körning #33 för `e009ef3` misslyckades på stegets tidsgräns: samma UI-test hängde och simulatorn stod sedan still; ingen IPA skapades. Workflowen delades därefter upp i enhets- och UI-teststeg; körning #35 för `9089bb3` tog 21 min. Från 2026-10-13 bygger ett eget jobb IPA:n parallellt med testerna (inte körd ännu). |
| Telefon | Inget av helhetsbygget är installerat eller provat. |

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
