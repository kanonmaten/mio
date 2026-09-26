# Bygg- och teststatus

Senast uppdaterad: **2026-09-27**. Helhetsbygge **0.9.0, ej släppt**. Tidigare build 3 är merged till `main` och kompilerad/XCTest-godkänd. Efter användarens telefonexport och förtydliganden finns nya rättningar i arbetskopian; de har ännu inte byggts med Xcode.
Detta är den gemensamma statuskällan. [Ändringsloggen](../CHANGELOG.md) beskriver innehållet och [helhetstestet](TESTPLAN_HELHET.md) beskriver återstående acceptansprov.

## Aktuellt verifieringsläge

| Område | Resultat och begränsning |
|---|---|
| Källkod | Arbetskopian kompletterar build 3 med riktigt lektionsläge, löpande aktiverad AI-tolkning av vanligt samtal, strukturerade systeminstruktioner och bättre motordiagnostik. Den äldre beskrivningen av hela omfånget som färdigt var för bred. |
| Portabel projektkontroll | Godkänd på Linux med `python3 scripts/verify_project.py`: projektregistrering, plist/XML, identitet, version, resurser, lagringsvägar, dokumentlänkar, workflow/Bash och whitespace. |
| Swift-syntaxparser | Tree-sitter-försöket kraschade i lokal parser/bindning och räknas inte som en godkänd kontroll. Xcode krävs för den nya revisionen. |
| Serverns tester | **19 av 19 godkända**, Node v26.8.2, med simulerad leverantör och lokal HTTP-testserver. Inga verkliga AI-anrop eller kostnader. |
| Appikon | Tre opaka RGB-varianter, 1024 × 1024: standard, mörk och tonad. Standardikonen visuellt granskad som PNG. Ingen verifiering av ikonrendering på iOS ännu. |
| Xcode / Release | **Godkänd** för commit `f53aaa1` i Actions 36228684153 på faktisk runner `xcode-27-arm64`, Xcode 27.0 (27A266a), iOS SDK 27.0. Inga kompilatorvarningar i slutloggen. |
| XCTest | **39 av 39 godkända** för `f53aaa1` på iOS 27-simulator (iPhone 17). |
| IPA / installation | **0.9.0 (3)** skapad och lokalt ZIP-/plist-/SHA-256-kontrollerad. Identiteten är `app.mio.assistant`, minsta iOS 26.0. **Ingen fysisk installation verifierad.** |
| Design och tillgänglighet | Native Liquid Glass-kontroller och systemnavigation implementerade. iOS-rendering, VoiceOver, större text, mörkt läge och tillgänglighetsinställningar återstår att prova. |
| Telefonprov | Användaren har lämnat ett privat prov från 2026-09-26, se nedan. Byggnummer/enhets- och iOS-version saknas i exporten; inget komplett acceptansprov är styrkt. |
| AI i drift | **Ingen server driftsatt**, ingen riktig modellfråga provad. Molnet är avstängt tills användaren konfigurerar och aktiverar det. |

Serverproven kontrollerar autentisering, routning, exakt godkänd payload, storleksgränser, sanitiserade fel, begränsning av antal anrop, timeout och redirects. De ersätter inte ett prov med en verklig HTTPS-server. De lokala kontrollerna ersätter varken Xcode, XCTest eller fysisk telefon.

Appidentiteten är nu `app.mio.assistant`. De tre lokala lagren ligger under `Mio/`; den raderade prototypen migreras inte. Minsta iOS-version är 26.0 och avsedd byggmiljö är Xcode 27.

## Verifierad IPA

- Byggd commit: `f53aaa1f0c18537d96bc80b21b3e55924ca5d537` på `codex/helhetsbygge`.
- [Grön Actions-körning 36228684153](https://github.com/kanonmaten/mio/actions/runs/36228684153).
- [Hämta artifacten Mio-IPA](https://github.com/kanonmaten/mio/actions/runs/36228684153/artifacts/10902176166), sparad i 14 dagar. Packa upp ZIP-filen en gång och installera `Mio-unsigned.ipa` via SideStore.
- Version **0.9.0**, build **3**. SHA-256 för själva IPA:n: `43ed053b55c93d41046be4de45686ff906f690a4e1e79d0cd5f2c22dd1f138ec`.

Första körningen, [36204571782](https://github.com/kanonmaten/mio/actions/runs/36204571782), godkände också Release och 39 XCTest för `3d4b041` (build 2), men rapporterade en samtidighetsvarning i kalenderdelegaten. Build 3 rättar den och är filen som ska användas.

## Nästa kontroller

1. Installera IPA:n enligt [installationsguiden](INSTALLATION.md), först på iPhone 16 Pro.
2. Kör H01–H15 i [helhetstestet](TESTPLAN_HELHET.md). Börja med syntetiska data och håll AI avstängt.
3. Prova behörigheter, tillgänglighet, dagbyte och radering. Kör sedan låst skärm, avbrott och längre batteriprov enligt [transkriptionstestet](TESTPLAN_V0_1.md).
4. När användaren har konfigurerat [servern](../server/README.md): kör AI01–AI06 med en ofarlig fråga och minsta kontext.

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

Portabel kontroll för rättningarna: 107 strukturella kontroller godkända före Xcode. Server: 19 syntetiska/mockade tester godkända. Nya XCTest-fall för fragment, källvalidering, radering, gammal text vid aktivering och avbruten kö är skrivna men ännu inte körda. Kör L01–L05 och A07–A14 för den nya revisionen.
