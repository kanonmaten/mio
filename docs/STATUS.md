# Bygg- och teststatus

Senast uppdaterad **2026-10-11**. Helhetsbygge **0.9.0, ej släppt**. Den här filen innehåller bara vad som faktiskt är kontrollerat. Äldre poster finns i Git-historiken (`git log -- docs/STATUS.md`). [Ändringsloggen](../CHANGELOG.md) beskriver vad koden gör; [helhetstestet](TESTPLAN_HELHET.md) beskriver acceptansproven.

## Aktuellt bygge: helhetsbygget 2026-10-11

Pågår på `main`: gateway på datorn med Groq, Pianissimo med förbehandling och talarmärkning, pausstyrda ljuddelar, automatisk omstart av mikrofonen, Live Activity, fortsatt bearbetning av lektionsanteckningar, QR-parning, AI på som standard, inställningspanel och SwiftData. Omdesignen är inte gjord än.

| Kontroll | Resultat |
|---|---|
| Gateway (Node 26.11.1, lokalt) | 95 av 95 tester godkända för `f420638`. Syntetisk Groq-transport, ingen riktig modelltrafik. |
| Pianissimo (pytest, lokalt) | 82 av 82 godkända för `40164c3` med falska modeller. Riktig Sortformer, svensk talarkvalitet, GPU-minne och effekten av förbehandling är **inte provade**. |
| Strukturkontroll | `verify_project.py`: 250 kontroller, 0 fel för `b024cf2`. |
| Linux Swift-grind | Godkänd för `938281f` och `88515cf`. Underkänd för `b024cf2` (dubbel deklaration i lagringsmigreringen, rättad i `f821202`). `f821202` och senare **kunde inte köras**: GitHub startar inga jobb på grund av kontots betalning eller utgiftsgräns. |
| Xcode (IPA-workflowen) | Körning #25 för `938281f`: strikt concurrency, Release-bygge med Live Activity-tillägget och kompilering av enhetstester godkända; testkörningen avbröts när #26 startades. #26 för `b024cf2` startade aldrig (samma betalningsstopp). **Ingen IPA för helhetsbygget finns än.** |
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
