# Roadmap

Roadmapen är en prioriteringsordning, inte ett löfte om datum.

## Fas 1 – teknisk genomförbarhet

Status: **kort rökprov godkänt, långt test återstår**.

Klart:

- GitHub Actions kompilerar en osignerad arm64-IPA med Xcode 26.
- SideStore installerar appen på iPhone 13.
- `DictationTranscriber` fungerar lokalt med `sv_SE`.
- Lokal Mio-detektion fungerar i förgrunden och i ett kort bakgrundsintervall.
- Paus tills manuell start stängde mikrofonflödet i korttestet.
- JSON-export med tidsstämplar, diagnostik och batteriprover fungerar.

Återstår innan fas 1 kan stängas:

- minst 10 minuter med låst skärm och de två planerade testfraserna;
- minst 60 minuters batteritest utan laddare, därefter 3–4 timmar om utfallet ser rimligt ut;
- avbrottstest med alarm eller samtal;
- verifiering av manuell fortsättning samt tidsstyrd paus;
- appomstart/persistens, radering och haptisk signal;
- transkriptionskvalitet med känt facit i tyst och kontrollerat bullrig miljö.

Beslutspunkt: fortsätt endast om bakgrundsstabilitet och batteriförbrukning är rimliga på den riktiga telefonen.

## Fas 2 – lokal, manuell MVP

- Gemensam datamodell för tidslinje, anteckning, uppgift, plan och uttryckligt minne.
- Manuell tidslinje och manuella anteckningar.
- Lokal sessionsindelning med tydlig start, stopp och redigering.
- Sökning, radering och export.
- Grundläggande femflikars navigering.
- Ingen OpenAI-integration ännu.

## Fas 3 – diskret Mio-flöde

- Förbättrad lokal Mio-detektion och väntande fråga.
- Vibration samt **Ja / Nej / Inte nu**.
- Lokala förslag till plan, uppgift eller minne med obligatorisk bekräftelse.
- Tydlig granskningsvy över vad som ska sparas eller skickas.

## Fas 4 – kalender, alarm och sammanfattningar

- EventKit-baserad kalenderintegration med systembehörighet.
- Lokala notiser/alarm inom de gränser iOS tillåter.
- Morgonöversikt och kvällssammanfattning.
- Försiktig lektionsindelning och kategorisering med redigerbara resultat.

## Fas 5 – begränsade OpenAI-svar

- En liten server som äger API-nyckeln.
- Endast uttryckligen godkända frågor.
- Minsta nödvändiga kontext och `store: false` där det stöds.
- Kostnadsgränser, loggning och tydlig radering.
- Pilot med konstgjorda data före verklig privat dagskontext.

## Senare eller endast efter nytt beslut

- Mer avancerad automatisk lektionssegmentering.
- Långsiktig mönsteranalys.
- Betald Apple Developer-distribution/TestFlight.
- Lagring eller molnsynkronisering av råljud; detta är inte planerat.
