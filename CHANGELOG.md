# Ändringslogg

## Granskning och rättningar 2026-10-05 — Claude Code

Planen och implementationen på `codex/mio-plan-reliability` granskades mot `PLAN.md`. Det mesta följde planen; följande fel rättades:

- **CI:** Linux-workflowen kunde aldrig köra (saknat `python3` och git-ägarskap i Swift-containern). Den kör nu `verify.py` vid varje push och är därmed första faktiska kontrollen av de portabla Swift-testerna. Native concurrency i IPA-workflowen är diagnostik som inte stoppar IPA:n.
- **Ljud/tid:** en fångstepok behåller sin svagaste tidsgiltighet; uppskattad tid kan inte längre märkas som värdtid och bevisa bakgrundsfångst. Stopp/paus väntar på sista textresultat och luckor i ordning. Uppskattad tid bevisar bara fångst efter AI-samtycke bortom 60 s-gränsen. Misslyckad bufferkopiering syns som lucka. HTTP-datum i Retry-After tolkas även för transkription.
- **Sessioner/lektioner/radering:** en lektion som aldrig startade lämnas inte öppen och vardagssessionen återställs; avbruten återstart avslutar inte en pausad session. Lektionsslutförande sparas som väntande vid sparfel, återhämtningsspärr och omstart. Radering av en session tar även bort tillfälliga exporter; en raderad session kan inte exporteras från gammal kopia.
- **AI-klient:** fel token i anslutningsprovet visas som behörighetsfel i stället för "inställningarna ändrades". Okända felkoder och extra uppgifter från nyare server kräver inte ny IPA. Serverns väntetid gäller även efter av/på.
- **Gateway:** `enable_request_signal` krävs för att klientavbrott ska nå Workern. `insufficient_quota` är ett kontofel, Gemini `API_KEY_INVALID` ett behörighetsfel, stora felsvar behåller kategori och Retry-After, och hängande D1 ger `budget_store_failed`. `/v1/status` speglar vardagsuppgiftens profil. Dagsgräns över 100 startar inte längre (dokumenterat som uppgraderingsändring).
- **Prestanda:** en uppdatering av den aktiva sessionen sorterar inte längre om hela sessionshistoriken för varje textdel.
- `AGENTS.md` ersattes av `CLAUDE.md` (engelska) och maskinspecifika Codex-sökvägar togs bort ur dokumentationen.

## Arbetskopia 2026-10-04 — PLAN-steg 1–5

- Genomfört den aktuella helhetsplanen på grenen `codex/mio-plan-reliability`: förstärkt ljud-/sessionsägarflöde och backend-avbrott, appägd workflow/radering/export, providerneutrala taskprofiler/adaptrar och granskade wire-kontrakt samt färskhet, anslutningskontroll, explicit frågesvarsgodkännande och återhämtning.
- Tillagt gemensam Linux-verifierare, verifierartester, faktiskt Worker-runtimeprov, fristående complete-concurrencygrind, native Xcode-diagnostik i IPA-workflowen och syntetisk långhistorikmätning. Svenska verifierings-, enhets-, leverantörs- och driftguider uppdaterade.
- Uppdaterat låsta Wrangler- och Miniflare-utvecklingsverktyg efter npm-granskning; den fullständiga beroendegranskningen rapporterar nu noll kända sårbarheter.
- Bevarat den byte-identiska ursprungsplanen som `PLAN.md` i repot och lagt till en kort överlämningsguide med verifieringsunderlag, fortsatt testordning och ej utförda externa/evidenskrävande steg.
- Lokal slutgrind 2026-10-04: 274 strukturella kontroller, 4 verifierarprov, 123 Node-tester, 27 Python fake-backend-tester, 235 portabla XCTest, 8 capture lifecycle-regressioner och complete-concurrencygrind godkända; fullständigt kvitto och Linuxbegränsningar i [status](docs/STATUS.md).
- Ingen Xcode/iOS-SDK-byggning, native XCTest, IPA, installation, fysisk enhet, verklig providertrafik eller Cloudflare-publicering utförd. Aktuell helhet är fortsatt 0.9.0 och ej släppt; dessa evidenskrävande steg återstår enligt överlämningsguiden.

## Dokumentationsrättning 2026-09-30 — efter implementation och push

- AI-felsökningsrapporten skiljer nu genomförda ändringar i `e906585` från återstående Cloudflare-publicering, nytt iOS-bygge och telefon-/modellprov. Gamla rekommendationer och testantal ersätts med implementationsstatus.
- Gatewayguiden beskriver uppdatering av befintlig Worker, bevarande av Secrets/Access/D1 och autentiserad statuskontroll utan modelltrafik. Kontext, stopp/paus och de fyra AI-rutterna dokumenteras enligt aktuell kod. Ingen Cloudflare-publicering utförd genom denna dokumentationsrättning.

## Arbetskopia 2026-09-30 — AI-kontext och diagnostik

- Vardagsanalys v2 separerar nya fragment från högst en minuts godkänd bakåtkontext. Samma öppna förslag kan kompletteras över anropsgränsen; Ja/Nej skyddas med beständiga textfria beslut.
- Mjuka meningsgränser med begränsad extra väntan, minst en minuts väntan efter föregående sändningsslut och hantering av sluttext vid stopp/paus. Kontext återställs vid paus, ljudlucka och lektionsbyte.
- Lokal AI-journal, 200 händelser/sju dagar, med säkra felkoder, HTTP-/nätdata, storlekar, källantal och versionsmetadata. Exporten får diagnostik även utan session och behåller schema 2; Skapa ny export tar med senare AI-fel. Fullständig radering omfattar journalen och avvisar sena writes.
- Skyddad gatewaystatus utan modell-/kvotanrop och tydligt kompatibilitetsfel. Gatewayen stöder Groq/Qwen i arbetskopian; publicerad gammal kod är fortfarande separat och behöver uppdateras efter uttrycklig begäran.
- Verifieringsresultat och kvarvarande Xcode-/telefon-/modellprov anges i [status](docs/STATUS.md). Ingen publicering utförd.

## Utredning 2026-09-30 — AI-driftfel och sammanhang

- Läskontroll av faktiskt publicerad Worker bekräftar äldre OpenAI-kod med nya Groq-inställningar: gatewayen kan inte initieras. Uppdaterad befintlig gateway passerar mocktester och lokal Worker-verifiering; ingen publicering utförd.
- Dokumenterat varför exporten saknar AI-anropsbevis och föreslagit lokal begränsad diagnostik samt separerat nytt underlag/bakåtkontext, mjuka gränser och stabila förslagsbeslut. Detta var ett designförslag vid utredningen; implementationen ovan följer användarens efterföljande godkännande; se [utredningen](docs/AI_FELSOKNING_2026_09_30.md).

## Arbetskopia 2026-09-30 — granskad Pianissimo-driftguide

- Alla källsökvägar uttryckliga: installation, systemd och utvecklarprov fungerar från valfri katalog. Endast serverns Python-kod, paketdefinition och låsfil kopieras till `/opt`; ingen hel projektkopia eller befintlig `.venv`.
- Dokumenterat avvägningen mellan låst Python/systemd och Docker, en varm GPU-process, uppdatering av rätt driftmiljö, förhämtning före laddningstimeout, health/felsökning, Tailscale-taggning och energihantering. Officiella källor granskade; ingen driftsättning.
- systemd anger uttryckligen `StateDirectoryMode=0700` så att tjänstens katalogbehörighet motsvarar installationsguiden även vid start.

## Arbetskopia 2026-09-30 — rättning av testkompilering

- Rättat ogiltiga Swift-decimaltal `.1`/`.5` till `0.1`/`0.5` i TranscriptionTests. Actions 36686984521 stoppades vid testkompilering med dessa fel. Ny Xcode-körning krävs; parserkontrollen fångade inte felet.

## Arbetskopia 2026-09-30 — Pianissimo, bakgrund och inställningar

- Apple-transkriptionen ersatt av original Pianissimo på egen CUDA-server. Stabilt autentiserat API v1, modellrevision/hälsa, loopback + privat Tailscale Serve och systemd med automatisk omstart.
- Mikrofon och nät separerade. 20 s ljuddelar med kontext, högst 60 s RAM-kö, begränsade anrop/retries och tydliga luckor. Stopp stänger mikrofonen och avslutar redan fångad text under högst 15 s med avbrytknapp.
- Ljudavbrott, route changes, foreground och media reset hanteras utan att serverfel avslutar lektionen. Manuell Fortsätt efter iOS-reset. Kort UIKit-bakgrundstid vid avslut; befintligt audio-background mode används för aktiv fångst.
- Samlade inställningar från alla flikar, skilda ljud-/text-AI-anslutningar, Keychain, tydlig sparbekräftelse/status, diskreta tryck och haptics. Ofullständigt ljudunderlag syns också i kopierade lektionsanteckningar.
- Fördröjd text från ljud före AI-aktivering skickas inte som ny vardagsanalys. Original och historiska data bevaras.
- Ny driftguide, API-kontrakt och acceptansmatris. Python-/gatewaytester och GPU-smoke utförda; se status för exakt evidens. Ingen ny iOS-kompilering, installation, driftinstallation, commit eller publicering.

## Arbetskopia 2026-09-29 — anslutning och Access, ej publicerad

- Ny sammanhängande Groq/Qwen-guide: engångsuppdatering, egna framtida provider-/modellbyten, gatewaytoken, rotation och Cloudflare Access med Service Auth samt negativa skyddsprov.
- Grå granskningsknapp förklarar nu att molnfrågor måste vara på och frågetext ifylld. Guiden skiljer Wrangler-påminnelsen från autentiseringsfel och rättar sammanblandningen av `MIO_OPENAI_MODEL` och `MIO_AI_MODEL` för Groq.
- Förtydligad åtkomsttoken i appen och valfria separata Access-fält. Gatewaytoken och Access-par sparas atomiskt i samma Keychain-post, skickas på alla tre AI-rutter och följer aldrig redirects. Befintlig gatewaytoken kan läsas efter uppgradering.
- Wrangler-exemplet väljer Groq/Qwen och bevarar extra Dashboard-variabler. Explicita variabler i filen behöver fortfarande synkas före senare deploy.
- Access-policy måste aktiveras separat i Cloudflare. Inget konto ändrat, ingen publicering eller nytt iOS-bygge utfört.

## Arbetskopia 2026-09-28 — AI och detaljerade lektioner, ej publicerad

- Åtta leverantörspresets och egen kompatibel endpoint; neutralt modellval i Cloudflare med separata API-hemligheter. Reasoning av, temperatur 0, strikt schema även för frågor och tydliga kompatibilitetsfel.
- Detaljerade källkopplade lektionsdelar, modell-/promptmetadata, framsteg och kopiering av hela anteckningen. Sparade delar används vid manuell fortsättning; äldre huvudpunkter bevaras.
- Mindre lektionsbatcher, minst 60 sekunders konfigurerbar takt och väntetid vid kvotfel. Inga automatiska återförsök eller inbyggda läromedel.
- Mocktester och lokal Worker-verifiering; nya XCTest-fall tillagda men ej körda. Ny appkod är inte Xcode-byggd, telefonprovad eller publicerad.


Användarsynliga ändringar och kompatibilitet per version. Versioner följer `vMAJOR.MINOR.PATCH`; [roadmapen](docs/ROADMAP.md) definierar milstolpar och släppkrav. Ingen ny Git-tagg eller release har skapats genom namnbytet.

## Build 5, 2026-09-28 — byggd, telefonprov återstår

- Sessionsstart försöker installera en stödd men saknad svensk SpeechTranscriber-modell före fallback. Avbruten start får inte fortsätta med reservmotorn.
- Motordiagnostik visar svenska språkvarianter i supportedLocales/installedLocales, resolved locale, assetstatus och hämtningsbehov; sessionsexporten får före/efter-händelser. Installations-/startfel vid fallback får felkod och domän.
- Release och 48 XCTest godkända för `1b4ae6c` i Actions 36382509184. IPA 0.9.0 (5) kontrollerad lokalt.
- Instruktioner och enhetsprov uppdaterade. Ingen ny talmotor eller bevisad kvalitetsförbättring; fysisk iPhone-verifiering återstår.

## Driftalternativ 2026-09-27

- Gatewayen publicerad på användarens Cloudflare-konto efter godkänd inloggning. Kvotdatabas och privat gatewaytoken konfigurerade; OpenAI-nyckel och verkliga modellprov återstår. Första provmodell konfigurerad som `gpt-6-luna`.
- Cloudflare Worker med inkluderad HTTPS-adress: ingen påslagen egen dator eller köpt domän behövs. Samma AI-kontrakt, systeminstruktioner och validering. Beständiga minut-/dygnsräknare i D1, inga lagrade textutdrag.
- Låsta utvecklingsverktyg, mocktester för budget samt genomgångstest av det verkliga Worker-paketet i lokal runtime. Ingen publik tjänst eller verklig AI-trafik har skapats av dessa tester.

## Rättningar efter telefonprov 2026-09-26

- Separat Starta lektion pausar vardags-Mio. Lektioner ersätter tidslinjen som huvudflik; historik och råtext finns kvar under Lektioner.
- Löpande AI-tolkning efter uttrycklig aktivering: planer/uppgifter ur vanligt samtal utan Mio-tilltal, källcitat, tidsgranskning och Ja/Nej/Inte nu. Lektioner får huvudpunkter/läxor som AI-utkast efter avslut.
- Separata svenska systeminstruktioner för frågor och analys, strikt schema och källvalidering, OpenAI-adapter med stabilt appkontrakt för framtida leverantörer. Ingen server driftsatt genom kodändringen.
- Avbrytbara köer, skydd mot historisk text vid aktivering och sena svar vid radering, nya regressionstester. Lokalt stöd även för ”Mio, påminn mig om att …”.
- Tydligare visning av aktiv transkriptionsmotor, specifika fallbackorsaker samt app/iOS-version och felkod i ny diagnostik. Ingen påstådd förbättring av Apples igenkänningsmodell utan nytt telefonprov.

Aktuell evidens och kvarvarande kontroller finns i [status](docs/STATUS.md).

## Helhetsbygge 0.9.0 — ej släppt

Efter användarbeslut 2026-09-25 byggs hela produkten tillsammans. Detta är en sammanhängande utvecklingskandidat, inte en telefonverifierad release.

- Lokal inkorg med redigerbara innehållsförslag och frågor, Ja/Nej/Inte nu och svenska Mio-kommandon. Stabilt godkännande-ID och skydd mot sen detektion efter radering.
- Redigerbar lektionsindelning över avslutade sessioner, med tidsval ned till sekunder och bevarade originalbevis.
- Bekräftade kalenderkopior via Apples editor, AlarmKit-alarm och lokala post-/morgon-/kvällspåminnelser. Privata posttexter visas inte på låsskärmen.
- Lokal morgon- och kvällsöversikt. Mer lättåtkomliga assistentfunktioner; teknisk diagnostik finns i expanderbara avsnitt.
- Valfri AI-klient och separat Node-server. Molnet är avstängt från början; exakt vald text visas före varje sändning. HTTPS, Keychain-gatewaytoken, serverägd OpenAI-nyckel, inga redirects eller automatiska omförsök.
- Nytt separat assistantlager; export schema 2 med bakåtkompatibel avkodning. Total radering omfattar nya lager, systemåtgärder och AI-konfiguration med gemensam skrivspärr.
- Nya XCTest-fall, serverns mocktester, portabel projektkontroll samt användar- och helhetstestguide.
- Ny appikon med standard-, mörk och tonad variant samt redigerbara SVG-original i `design/`.
- Kalendereditorns delegate för över resultatet till huvudaktorn innan SwiftUI-tillstånd ändras.

Efter uppdaterat användarbeslut 2026-09-26 används appidentiteten `app.mio.assistant` och lagring under `Mio`; gammal fasmigrering har tagits bort. Första telefonprov sker på iPhone 16 Pro, senare iPhone 13. Native Liquid Glass tillagt i sessionskontrollerna med systemnavigation, semantiska läsytor och stöd för minskad rörelse. Användaren har godkänt commit, push och IPA-bygge; ingen servertjänst driftsätts och ingen release taggas. Faktiskt verifieringsläge dokumenteras i [status](docs/STATUS.md).

## v0.2.0 — ej släppt

### Tillagt sedan v0.1.0

- Fem flikar och fem manuella innehållstyper: tidslinjepost, anteckning, uppgift, plan och uttryckligt minne.
- Skapa, redigera, söka, radera och markera uppgifter klara; stabil lokal tidsordning.
- Koppla en post till en session. Lägg titel, anteckning och texträttningar på avslutade sessioner utan att ändra originalbevis.
- Separat versionsmärkt innehållslagring och gemensam JSON-export.
- Synlig status och separat installation av svensk `SpeechTranscriber`-resurs; direkt `DictationTranscriber`-fallback när resursen saknas.
- XCTest för modeller, lagring, migrering, export och Mio-detektion.

### Byggflöde 2026-09-25

- Ersatt separata Xcode 26.6- och Xcode 27-jobb med ett Xcode 27-jobb som bygger Release, kör XCTest på iOS 27-simulator och skapar osignerad IPA.
- Bygget kontrollerar iOS 27 SDK, appens lägsta iOS-version 26.0 och oförändrad bundle identifier i den byggda appen. iOS 26 och 27 behöver fortfarande provas på fysisk telefon.

### Städning 2026-09-22

- Ersatt utvecklingsfaser med v0.1.0–v0.5.0 och definierat vad som krävs för v1.0.0.
- Bytt projekt, mappar, modul, targets och scheme från `MioPhaseTwo` till `Mio`/`MioTests`; `MioApp.swift` och `ContentViews.swift` får beständiga namn.
- Satt appens versionsfält till `0.2.0` (tidigare `0.2`). Byggnumret är separat och fortfarande `1`.
- Byggfiler heter `Mio-unsigned.ipa`, `Mio-buildinfo.txt` och artifacten `Mio-IPA`.
- Nya sessionsexporter heter `Mio-session-*.json`. Radering känner fortfarande igen äldre exportnamn; Git ignorerar både gamla och nya.
- Samlat verifieringsläget i en statussida och båda installationsvägarna i en guide. Kortat introduktion, arbetsflöde och beslut; behållit detaljerade testfall och historiska mätvärden.
- Tagit bort interna utvecklingsfaser ur appens texter. Bygginformationen läser appversion och byggnummer från den byggda appen.

### Kompatibilitet och verifiering

Bundle identifier, lagringsvägar, JSON-schema och migreringsbeteende behålls. Namnbytet kräver ingen ny datamigrering. Bygg- och telefonresultat saknas för denna revision; följ [status](docs/STATUS.md) och [testplanen](docs/TESTPLAN_V0_2.md).

## v0.1.0 — historisk prototyp, telefonprov 2026-08-20

Versionsetiketten tilldelas i efterhand till den tidigare fas 1-prototypen; den påstår inte att en motsvarande Git-tagg, release eller exakt appversionssträng fanns.

- Lokal svensk transkription via `SpeechAnalyzer`, `DictationTranscriber`-fallback, Mio-detektion och paus/stopp.
- Sessionslagring, JSON-export, ljudtider, bakgrundsdiagnostik och batterimätning.
- Molnbyggd IPA installerades via SideStore. Ett 2 min 30 s långt iPhone 13-prov gav fem textsegment, två Mio-detektioner och inga rapporterade runtimefel eller tappade buffertar.
- `SpeechTranscriber`-resursen gick inte att installera i provet. Långa bakgrunds-, batteri-, avbrotts- och kvalitetsprov återstår.

Fullständiga observationer: [historiskt testresultat](docs/TESTRESULTAT_V0_1.md).
