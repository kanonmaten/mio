# Bygg- och teststatus

Senast uppdaterad **2026-10-11**. Helhetsbygge **0.9.0, ej släppt**. Den här filen innehåller bara vad som faktiskt är kontrollerat. Äldre poster finns i Git-historiken (`git log -- docs/STATUS.md`). [Ändringsloggen](../CHANGELOG.md) beskriver vad koden gör; [helhetstestet](TESTPLAN_HELHET.md) beskriver acceptansproven.

## Aktuellt bygge: helhetsbygget 2026-10-11

Klart på `main`: gateway på datorn med Groq, Pianissimo med förbehandling och talarmärkning, pausstyrda ljuddelar, automatisk omstart av mikrofonen, Live Activity, fortsatt bearbetning av lektionsanteckningar, QR-parning, AI på som standard, inställningspanel, SwiftData och den nya designen (veckoplaneraren, se [DESIGN.md](../DESIGN.md)).

| Kontroll | Resultat |
|---|---|
| Gateway (Node 22.22, lokalt) | 95 av 95 tester godkända för `39e6d02`. Syntetisk Groq-transport, ingen riktig modelltrafik. Projektets fästa Node 26.10 fanns inte i molnmiljön. |
| Pianissimo (pytest, lokalt) | 82 av 82 godkända för `39e6d02` med falska modeller. Riktig Sortformer, svensk talarkvalitet, GPU-minne och effekten av förbehandling är **inte provade**. |
| Strukturkontroll | `verify_project.py`: 248 kontroller, 0 fel för `e7b41b8` och nästa revision. |
| Linux Swift-grind | Godkänd för `7ec91e7`, `f96a4df`, `c10fd3e`, `75b58b8`, `8dc0025` och `e7b41b8`. |
| Xcode (IPA-workflowen) | Körning #30 för `8dc0025`: strikt concurrency, Release-bygge med Live Activity-tillägget, alla enhetstester och UI-tester i simulatorn godkända, IPA skapad. Skärmbilderna visade att tonen blev systemblå; rättat i `e7b41b8`. Körning #31 för `e7b41b8`: bygge och enhetstester godkända, men UI-testet för att markera en uppgift klar överskred sin tidsgräns två gånger, eftersom simulatorn för iOS 27 rapporterade appen som upptagen i 60 s efter ett tryck. Orsaken är inte hittad; testets tidsgräns höjs i nästa revision. |
| Telefon | Inget av helhetsbygget är installerat eller provat. |

## Verifierat på telefonen

Bara det som användaren faktiskt provat. Varje rad gäller den revision som står i den; ett nytt bygge kräver nytt prov.

| Datum | Revision | Vad | Resultat |
|---|---|---|---|
| 2026-08-20 | v0.1, iPhone 13 | Transkription 2 min 30 s, Mio-detektion ([mätningar](TESTRESULTAT_V0_1.md)) | Godkänd för den revisionen |
| 2026-09-26 | Före build 5 | Tre sessioner, 111 textsegment, cirka 34 min längsta | Ljudavbrott gav "Session activation failed"; inget kontrollerat batteriprov |
| 2026-10-05 | Build 5 + Cloudflare-gateway | Pianissimo-anslutning efter att en Quad9-DNS-profil stängts av | Fungerar (användarens rapport) |
| 2026-10-05 | Build 5 + Cloudflare-gateway med Groq | En enkel fråga ("hej") | Svar på telefonen (användarens rapport) |

## Registrera nya resultat

Ange commit, Actions-URL, IPA-kontrollsumma, version/byggnummer, iPhone-modell, iOS-version, test-ID, observation och resultat (Godkänd, Underkänd, Blockerad eller Ej körd). Spara bara avidentifierade slutsatser här; råexporter förvaras privat.
