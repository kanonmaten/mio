# Omfattning och leverans

Den 25 september 2026 ändrades arbetssättet: bygg hela vardagsappen sammanhängande i stället för att leverera en funktionell version i taget. Användaren har också valt att AI-klient och server ska byggas, med molnet avstängt tills det konfigureras.

**Helhetsbygget identifieras som 0.9.0, ej släppt.** Det ersätter de planerade separata v0.3–v0.5-leveranserna. v0.1.0 är historisk transkriptionsprototyp och v0.2.0 är den tidigare manuella grunden. Dessa etiketter ändrar inga gamla resultat.

## Sammanhängande produkt

| Område | Implementerad omfattning | Verifieringsgräns |
|---|---|---|
| Privat fångst | Privat Pianissimo via Tailscale, begränsade nätomförsök, Mio-detektion, paus/stopp och tidsatta luckor; ingen automatisk mikrofonstart | Fysisk telefon krävs för kvalitet, bakgrund och batteri |
| Innehåll | Fem manuella typer, sökning, redigering, uppgiftsstatus, export/radering | Ren installation och lagring provas på verklig telefon |
| Assistent | Lokala kommandoförslag och aktiverad AI-tolkning av vanligt samtal; Ja/Nej/Inte nu | Modellkvalitet måste provas; innehåll och datum godkänns manuellt |
| Lektioner | Separat lektionsläge pausar vardags-Mio; detaljerade delar, manuell fortsättning, kopiering och källrevisioner via godkänd AI | Originaltext/tidsbevis bevaras; äldre/okänt underlag märks, rättningar skickas inte automatiskt |
| Kalender | Användarbekräftad fristående kalenderkopia | Ingen bakgrundssynk eller läsning av hela kalendern |
| Alarm/notiser | AlarmKit, engångs-/veckoalarm, postpåminnelse, morgon-/kvällsnotis | Behörighet och leverans måste provas på telefon |
| Dagen | Lokal morgon- och kvällsöversikt; godkända notiser öppnar rätt lokal vy | Notiser har opaka ID:n utan privata rubriker; ingen molnsammanfattning |
| AI | Godkänd fråga eller aktiverad löpande tolkning via serverprofiler; anslutning/kapacitet; explicit spara ett svar som anteckning | Av från början; modellfri status bevisar inte leverantörsåtkomst eller kvalitet |

## PLAN.md i arbetskopian, 2026-10-03

De fyra första lokala etappernas grindar är passerade: regressioner för ljud/gateway/lagring/discovery; appägd workflow och generationsskydd; åtskilda tasks/modellprofiler/adaptrar/exekvering; samt sammanhängande UI med tre avgränsade funktioner. Etapp 5 förbereder gemensam verifieringsentrypoint, concurrency-kontroll, syntetisk historikmätning, dokumentation och gatewayrelease `2026-10-03.1`. Exakta aktuella resultat och kvarstående kontroller står i [status](STATUS.md). Detta är källarbete och lokala verifieringsgrindar, inte en släppt eller telefonverifierad produkt.

Servern väljer `ask`/`everyday`/`lesson` från validerade profiler och serverägda nycklar. Skyddad `/v2/status` visar konfiguration, revision och gemensam kapacitet. Nya anrop kräver aktuell revision; ändring leder till ny preview eller aktivering. [Leverantörsmatrisen](LEVERANTORSKONTRAKT.md) listar exakta granskade ID:n, spärrade kontrakt och separat syntetiskt prov. Inga verkliga leverantörsprofiler är verifierade för denna revision.

Lektionsdelar och kopiering märker om underlaget är aktuellt, äldre eller okänt, utan att ändra original eller automatiskt sända rättningar. Svar kan uttryckligen sparas som anteckning. Anslutnings-/kapacitetsvyn visar modellfria taskstatusar, delad kvot och återstående arbete; 100 modellförsök per dygn är fortsatt ett gemensamt tak, inte heldagskapacitet. Notisöppning använder ett lokalt mål-ID och godkänner ingen annan åtgärd.

Read-only produktionskontroll den 3 oktober visar att den gamla OpenAI-bundlen fortfarande är aktiv med Groq-konfiguration. D1-bindningen matchar repot; all-traffic Access och service-token-funktion är ännu inte bevisade. Releasearbetet är därför inte färdigt. Efter exakt godkänd publicering ska bundle, release, profiler och D1/Access läsas tillbaka; skyddad modellfri status och negativa authprov körs först. Verkliga fråga-/vardag-/lektionsprov kräver därefter separat godkännande av syntetisk payload. Xcode/XCTest för samma revision, IPA och fysisk acceptans följer som egna grindar. Se [releaseguiden](../server/cloudflare/GROQ_ACCESS.md).

## Leveransgrindar

1. Kontrollera projektfiler, privata data, lokala tester och dokumentation med den gemensamma verifieringsentrypointen. Registrera Linuxvärden separat från native- och telefonresultat.
2. Efter uttryckligt tillstånd: commit/push och GitHub Actions på faktisk tillgänglig `xcode-27`-runner. Release och XCTest måste bli gröna för samma commit.
3. Hämta validerad IPA och installera rent på iPhone 16 Pro med `app.mio.assistant`; prova iPhone 13 senare.
4. Kör [helhetstestet](TESTPLAN_HELHET.md) samt återstående [långtest](TESTPLAN_V0_1.md).
5. Registrera exakt revision, build, enhet och resultat i [status](STATUS.md). Åtgärda verkliga fel innan daglig tillit.

Versionsnumret 1.0.0 används först när accepterad vardagsomfattning är verifierad. Inget datum eller löfte om heldagslyssning ges utan mätningar. Appversion, byggnummer och lagringsschema är separata värden. `CURRENT_PROJECT_VERSION` höjs inför nästa distribuerade build; bundle identifier och beständiga lagringsvägar ändras inte.

Råljudslagring, molnöverföring utan aktiverat samtycke, dold profilering och tyst kalenderbokning ingår inte. Serverdrift och Tailscale behövs för transkription. Manuella poster och lokal historik fungerar utan server.

## Identitet och design, 2026-09-26

Användaren har raderat prototypen. Appidentiteten är därför `app.mio.assistant` och lagringsmappen `Mio`, utan fasnamn, personnamn eller appversionsnummer. Ingen tidigare migrering behövs. Native Liquid Glass används för kontroller och navigation; innehållet har semantiska läsytor. Designen behöver visas och provas i verklig iOS, inte bara granskas i källkod.

Förtydligande 2026-09-26: lektionsläge och vanlig samtalstolkning är korrigeringar mot visionen. Första AI-leverantör är OpenAI; andra kan senare implementeras bakom serverns stabila appkontrakt. Driftsättning och verkliga modellprov återstår.

## Arbetskopians utökning 2026-09-28

Leverantörsadaptrar, strikt schema även för frågor och detaljerade lektionsanteckningar med kopiering/fortsättning finns i källkoden. Detta var planen den 28 september; efterföljande beslut nedan ersätter Apple-transkriptionen. Ingen modellväljare, presentation eller frågekortsvy tillkommer. Nästa grindar är Xcode/XCTest för denna ändring, godkänd publicering av gatewayen, ny IPA och syntetiska modell-/telefonprov. Den publicerade äldre gatewayen och build 5 verifierar inte detta arbete.

## Pianissimo och bakgrund, 2026-09-30

Prioriterad implementation finns i arbetskopian: (1) versionsmärkt ljud-API/originalmodell och driftpaket, (2) mikrofon separerad från nätet och begränsad RAM-kö, (3) sessionsbevarande vid avbrott/luckor och iOS-lifecycle, (4) samlade inställningar/status/återkoppling, (5) dokumentation och tester. Ingen HA, publik ljudport eller lokal Apple-fallback.

Återstående leveransgrindar: nytt Xcode-bygge och XCTest, installera systemd/Tailscale enligt driftguiden, därefter [Pianissimo-acceptansprov](TESTPLAN_PIANISSIMO.md), särskilt svensk precision över chunkgränser, låst skärm, omstart, nätbyte och batteri. GPU-laddning i utvecklingsmiljö ersätter inte dessa prov.

## Kontext och AI-diagnostik, 2026-09-30

Godkänd plan implementeras i arbetskopian: lokal textfri journal/export, skyddad gatewaystatus och versionsmärkt vardagskontext med stabila förslagsbeslut. Återstående grindar är publicering efter uttrycklig begäran, Release/XCTest/ny IPA och [D01–D08](TESTPLAN_HELHET.md#ai-kontext-och-diagnostik--nya-prov-ej-körda-på-iphone). Den gamla publicerade OpenAI-koden är inkompatibel med dagens Groq-konfiguration; implementationen ändrar inte drift utan publicering.
