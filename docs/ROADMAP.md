# Roadmap

Roadmapen är en prioriteringsordning, inte ett löfte om datum.

## Fas 1 – teknisk genomförbarhet

Status: **kort rökprov godkänt på revisionen från 20 augusti 2026; långt test återstår**.

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

Beslutspunkt för heldagslyssningen: fortsätt endast om bakgrundsstabilitet och batteriförbrukning är rimliga på den riktiga telefonen.

Fas 2:s lokala, manuella delar får utvecklas parallellt eftersom de kan provas utan att anta att heldagslyssningen är godkänd. Det beslutet stänger inte fas 1 och gör inte det korta rökprovet till ett långtest.

## Fas 2 – lokal, manuell MVP

Status: **implementerad i lokal arbetskopia; ännu inte Xcode-kompilerad, Actions-byggd eller iPhone-verifierad**.

Implementerat i källkod:

- fem flikar: Mio, Tidslinje, Kalender, Anteckningar och Morgon;
- gemensam lokal datamodell för tidslinjepost, anteckning, uppgift, plan och uttryckligt minne;
- skapa, redigera, söka, slutföra uppgift och radera manuellt innehåll;
- lokal sessionsindelning med tydlig start och stopp samt redigerbar titel och anteckning efter stopp;
- korrigerad visningstext som bevarar originaltranskription och ljudtider;
- valfri `sessionID`-koppling från en manuell post till en session;
- tekniska projekt-, mapp-, target-, scheme-, produkt- och artifactnamn under `MioPhaseTwo`;
- separat versionsmärkt `MioPhaseTwo/content-v1.json` och `MioPhaseTwo/sessions.json`, med migrering från den äldre sessionssökvägen;
- gemensam versionsmärkt JSON-export;
- en gemensam lokal `SpeechAnalyzer` som kör `SpeechTranscriber` när dess svenska asset är installerad och annars förbereder `DictationTranscriber` direkt, utan att sessionsstarten väntar på hämtning;
- ingen OpenAI-, EventKit- eller alarmintegration.

Den säkra statiska Windows-kontrollen är genomförd. Workflowen är även uppdaterad för att kompilera och faktiskt köra XCTest på en tillgänglig iOS 26-simulator innan IPA:n publiceras, men den aktuella revisionen har ännu inte körts i Actions.

Bundle identifier förblir avsiktligt `se.eyvin.MioPhaseOne` så att fas 2 kan installeras över den befintliga appen och migrera dess lokala data.

Återstår innan fas 2 kan markeras verifierad:

- Xcode-kompilering och faktisk XCTest-körning;
- grön Release-build och validerad IPA i GitHub Actions;
- installation över befintlig app och migreringskontroll på iPhone 13;
- alla testfall i `TESTPLAN_FAS_2.md`;
- regressionsprov av fas 1:s mikrofon-, paus- och transkriptionsflöde på den nya IPA:n.

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
