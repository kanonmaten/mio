# Bygg- och teststatus

Senast uppdaterad: **2026-09-26**. Aktuellt helhetsbygge: **0.9.0, ej släppt**. Helhetsbygget är pushat på `codex/helhetsbygge`. **Build 3 är kompilerad, XCTest-godkänd och paketerad som IPA.** Telefonprov återstår. Dokumentationscommit efter bygget ändrar inte appkoden; den byggda revisionen anges nedan.

Detta är den gemensamma statuskällan. [Ändringsloggen](../CHANGELOG.md) beskriver innehållet och [helhetstestet](TESTPLAN_HELHET.md) beskriver återstående acceptansprov.

## Aktuellt verifieringsläge

| Område | Resultat och begränsning |
|---|---|
| Källkod | Hela produktomfånget implementerat i arbetskopian: lokal transkription och innehåll, förslag, lektioner, kalenderkopior, alarm/notiser, dagsöversikt och valfri AI-klient/server. |
| Portabel projektkontroll | Godkänd på Linux med `python3 scripts/verify_project.py`: projektregistrering, plist/XML, identitet, version, resurser, lagringsvägar, dokumentlänkar, workflow/Bash och whitespace. |
| Swift-syntaxparser | Inga nya syntaxfynd jämfört med HEAD. Fyra parserfynd finns även i den oförändrade transkriptionskoden. Tree-sitter är inte Swift-kompilatorn och kontrollerar inte SDK-typer. |
| Serverns tester | **14 av 14 godkända**, Node v26.8.2, med simulerad leverantör och lokal HTTP-testserver. Inga verkliga AI-anrop eller kostnader. |
| Appikon | Tre opaka RGB-varianter, 1024 × 1024: standard, mörk och tonad. Standardikonen visuellt granskad som PNG. Ingen verifiering av ikonrendering på iOS ännu. |
| Xcode / Release | **Godkänd** för commit `f53aaa1` i Actions 36228684153 på faktisk runner `xcode-27-arm64`, Xcode 27.0 (27A266a), iOS SDK 27.0. Inga kompilatorvarningar i slutloggen. |
| XCTest | **39 av 39 godkända** för `f53aaa1` på iOS 27-simulator (iPhone 17). |
| IPA / installation | **0.9.0 (3)** skapad och lokalt ZIP-/plist-/SHA-256-kontrollerad. Identiteten är `app.mio.assistant`, minsta iOS 26.0. **Ingen fysisk installation verifierad.** |
| Design och tillgänglighet | Native Liquid Glass-kontroller och systemnavigation implementerade. iOS-rendering, VoiceOver, större text, mörkt läge och tillgänglighetsinställningar återstår att prova. |
| Telefonprov | **Ej körda.** Först iPhone 16 Pro; därefter iPhone 13. Exakt iOS-version ska registreras för varje prov. |
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
