# Implementation av AI-diagnostik och sammanhang

**Mål:** genomför användarens godkända förslag i `docs/AI_FELSOKNING_2026_09_30.md` efter instruktionen ”Implementera planen”. Ingen publicering, commit/push eller verklig modelltrafik ingår.

**Arkitektur:** versionsmärkt `/v2/analyze` skiljer nya fragment från bakåtkontext. Tidigare beslut återförs som textfria ID-/källkopplingar; modellen kan uttryckligen komplettera ett öppet beslut men inte ändra ett stängt beslut. Lokal, begränsad diagnostik är oberoende av sessioner och ingår additivt i exporten.

**Teknik:** Swift/Foundation/SwiftUI, befintlig JSON-lagring, Node och Cloudflare Worker. Server- och diagnostikdelar har avgränsade filer för parallellt arbete; integration och kösystem utförs i huvuduppgiften.

## Krav och gränser

- Svenska texter, oförändrade original/tidsbevis, schema 1 i befintliga lager och schema 2 i export. Inga råljud, token eller privata textexporter i repot.
- Endast godkänd vardagstext efter aktivering och relevant kontinuitetsgräns. Högst 60 s/4000 byte bakåtkontext, åtta källfragment och 10000 byte totalt, payload 20000 byte.
- Minst 60 s mellan modellanrop; mjuk meningsgräns kan ge ytterligare högst 60 s väntan. Inga extra turdetektionsanrop eller automatiska omförsök. Lektionens 3500-bytekontrakt behålls.
- `/v2/analyze` request: `mode`, `timeZone`, `fragments` (nya), `contextFragments`, `priorDecisions`, `contextLimited`. Hints: `id`, `kind`, `sourceIDs` från kontext, `isOpen`. Kandidater tillför obligatoriskt nullable `replacesID` i v2, inte v1.
- En komplettering måste hänvisa till skickat öppet beslut av samma typ och dess källor; varje kandidat kräver ny källa. Stängda beslut sparar endast ID/typ/käll-ID:n, ingen förslagstext.
- Journal: 200 händelser/sju dagar, okänt schema skyddas, raderingsgeneration avvisar sena writes. Felkropp högst 4096 byte och bara fasta felkoder används.
- Ingen iOS-verifiering påstås från Linux. Pure Foundation-test kan provas med en separat Linux-toolchain om tillgänglig; SwiftUI/Security/SDK och XCTest på iOS kräver Xcode.

## Test- och arbetsordning

1. [x] Gateway: skriv felande v2-/status-/metadata-/kompatibilitetstester; implementera nytt kontrakt/prompt och skyddad status utan modell/kvot; kör hela Node- och Worker-sviterna.
2. [x] Diagnostik: skriv journal-/retention-/okänt-schema-/raderings-/export-/felparsningstester; implementera säkra transporthändelser, statuskontroll, beständig journal och export/radering.
3. [x] Kontext och beslut: tester för tidigare kontext utan gamla analyseringsspärren, explicita kompletteringar, stängda beslut, Unicode/budget, samtycke/luckor, stopp och tidsgräns. Implementera pure context planner, additiva beslut, ny queue timing och stoppintegration.
4. [x] Integration: registrera nya filer i Xcode, uppdatera samtyckestexter, datamodell, beslut, changelog, acceptansprov och verifierad status. Kontrollera gamla v1-/lektions-/exportscheman.
5. [x] Verifiering: fulla säkra lokala sviter, parser-/projektkontroll och diffkontroll. Oberoende kodgranskning; rätta sakliga fynd med regressioner. Redovisa exakt testgräns och kvarvarande telefon-/publiceringsprov.

## Särskild granskningsfokus

- Pause/stopp/lektionsbyte får inte kasta sista nya texten eller återanvända gammal kontext efter en ny kontinuitetsgräns.
- Nät-/lagrings-/raderingsracen får inte skapa privata journalhändelser efter full radering.
- Förslag under användargranskning, Nej och Ja: komplettering får inte ändra godkända poster eller återuppliva samma händelse.
- Källhints som saknas/är tvetydiga får inte leda till tyst semantisk sammanslagning.
- Bytebudget och lång backlog: nya källfragment bevaras; äldre kontext begränsas synligt.

## Arbetsnoteringar

- Befintliga dokumentationsändringar från utredningen bevaras i användarens arbetskopia. Ingen historik/commit skapas utan uttrycklig begäran.
- Avgränsade server-/Swift-diagnostikuppgifter körs parallellt enligt dispatching-parallel-agents; delat v2-kontrakt fastställt före redigering.

- Slutkontroller: 47 Node-tester, Worker dry-run/lokal runtime, 53 portabla Swift XCTest, Swift-parser för 44 filer, 194 strukturkontroller och diffkontroll godkända. Xcode/iOS-XCTest/native transport/Keychain/filskydd/fysisk telefon ej verifierade.
- Granskningsfynd åtgärdade: sluttext väcker väntan; minst 60 s efter sändningsslut; gap markerar begränsad kontext; v2 slår bara ihop uttryckliga kompletteringar; giltiga colon-modellnamn stöds; ny export kan skapas efter senare fel; rätt Xcode-grupper med sökvägskontroll.
- Överlämning: alla ändringar kvar i befintlig arbetskopia på main. Commit och push begärdes därefter av användaren 2026-09-30. Inga tags, publiceringar eller betalda modellprov. Driftfel i den gamla publicerade Workern återstår tills avsedd kod publiceras enligt separat begäran.
