# Bygg- och teststatus

Senast uppdaterad: **2026-09-26**. Aktuellt helhetsbygge: **0.9.0, ej släppt**. Resultaten nedan gäller den lokala arbetskopian; den lokala kontrollen gjordes före commit, push och Actions-körning. Användaren har därefter godkänt push och bygge; resultat redovisas när körningen är klar.

Detta är den gemensamma statuskällan. [Ändringsloggen](../CHANGELOG.md) beskriver innehållet och [helhetstestet](TESTPLAN_HELHET.md) beskriver återstående acceptansprov.

## Aktuellt verifieringsläge

| Område | Resultat och begränsning |
|---|---|
| Källkod | Hela produktomfånget implementerat i arbetskopian: lokal transkription och innehåll, förslag, lektioner, kalenderkopior, alarm/notiser, dagsöversikt och valfri AI-klient/server. |
| Portabel projektkontroll | Godkänd på Linux med `python3 scripts/verify_project.py`: projektregistrering, plist/XML, identitet, version, resurser, lagringsvägar, dokumentlänkar, workflow/Bash och whitespace. |
| Swift-syntaxparser | Inga nya syntaxfynd jämfört med HEAD. Fyra parserfynd finns även i den oförändrade transkriptionskoden. Tree-sitter är inte Swift-kompilatorn och kontrollerar inte SDK-typer. |
| Serverns tester | **14 av 14 godkända**, Node v26.8.2, med simulerad leverantör och lokal HTTP-testserver. Inga verkliga AI-anrop eller kostnader. |
| Appikon | Tre opaka RGB-varianter, 1024 × 1024: standard, mörk och tonad. Standardikonen visuellt granskad som PNG. Ingen verifiering av ikonrendering på iOS ännu. |
| Xcode / Release | **Ej körd för helhetsbygget.** Linux saknar Xcode och iOS SDK. Workflowen använder ett `xcode-27`-jobb; runnerns faktiska tillgänglighet är inte kontrollerad med en ny körning. |
| XCTest | Nya och befintliga testfall finns och är registrerade i MioTests. **Ej kompilerade eller körda för helhetsbygget.** |
| IPA / installation | **Ingen IPA byggd för denna arbetskopia; ingen installation verifierad.** |
| Design och tillgänglighet | Native Liquid Glass-kontroller och systemnavigation implementerade. iOS-rendering, VoiceOver, större text, mörkt läge och tillgänglighetsinställningar återstår att prova. |
| Telefonprov | **Ej körda.** Först iPhone 16 Pro; därefter iPhone 13. Exakt iOS-version ska registreras för varje prov. |
| AI i drift | **Ingen server driftsatt**, ingen riktig modellfråga provad. Molnet är avstängt tills användaren konfigurerar och aktiverar det. |

Serverproven kontrollerar autentisering, routning, exakt godkänd payload, storleksgränser, sanitiserade fel, begränsning av antal anrop, timeout och redirects. De ersätter inte ett prov med en verklig HTTPS-server. De lokala kontrollerna ersätter varken Xcode, XCTest eller fysisk telefon.

Appidentiteten är nu `app.mio.assistant`. De tre lokala lagren ligger under `Mio/`; den raderade prototypen migreras inte. Minsta iOS-version är 26.0 och avsedd byggmiljö är Xcode 27.

## Nästa kontroller

1. Efter uttrycklig begäran: commit/push av granskad arbetskopia och körning av GitHub Actions. Kontrollera faktisk runner, Release, XCTest och IPA-validering för samma commit.
2. Installera IPA:n enligt [installationsguiden](INSTALLATION.md), först på iPhone 16 Pro.
3. Kör H01–H15 i [helhetstestet](TESTPLAN_HELHET.md). Börja med syntetiska data och håll AI avstängt.
4. Prova behörigheter, tillgänglighet, dagbyte och radering. Kör sedan låst skärm, avbrott och längre batteriprov enligt [transkriptionstestet](TESTPLAN_V0_1.md).
5. När användaren har konfigurerat [servern](../server/README.md): kör AI01–AI06 med en ofarlig fråga och minsta kontext.

[Användarguiden](ANVANDNING.md) beskriver de dagliga flödena. Byggfel och telefonfynd ska åtgärdas innan helhetsbygget betraktas som verifierat.

## Historisk evidens

[Telefonprovet 2026-08-20](TESTRESULTAT_V0_1.md) gäller en äldre revision på iPhone 13: 2 min 30 s, fem textsegment, två Mio-detektioner och DictationTranscriber med `sv_SE`. Bara elva sekunders bakgrund finns dokumenterat. Mätvärdena är oförändrade och bevisar inte aktuell versions funktion.

Tidigare statiska kontroller av v0.2.0 och byggflödet finns i projekthistoriken. Den äldre [testplanen v0.2](TESTPLAN_V0_2.md) är historiskt underlag; nya installationer följer helhetstestet.

`SpeechTranscriber`-installation, stabil bakgrundsdrift och ljudavbrott kräver fysisk telefon. Ett ljudvägsbyte kan kräva stopp/start. iOS återstartar inte lyssning efter tvångsavslutning; tidsstyrd paus kan kräva att appen öppnas igen.

## Registrera nya resultat

Ange **commit, Actions-URL, IPA-kontrollsumma, appversion/byggnummer, iPhone-modell, iOS-version, test-ID, observation och resultat**. Använd Godkänd, Underkänd, Blockerad eller Ej körd. Spara bara avidentifierade slutsatser här; råexporter förvaras privat. En ny revision är inte verifierad av ett äldre grönt resultat.
