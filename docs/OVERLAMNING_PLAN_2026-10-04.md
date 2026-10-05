# Överlämning — Mio helhetsbygge 0.9.0

**Datum:** 2026-10-04
**Gren:** `codex/mio-plan-reliability`
**Utgångspunkt:** `3f99f4072b0ddbe51529c84bfdb9f947855f6e64` (`origin/main` vid överlämningen)

Det här är en orientering för nästa verktyg och utvecklare, inte en ersättning för specifikationer och testplaner. Den fullständiga implementeringsplanen finns nu som [`PLAN.md`](../PLAN.md). Den är byte-identisk med den tillhandahållna filen: SHA-256 `9b1031ef06eaa5d4da770188617678544c1e3fbfa7debbc16a339ee8f6f9a895` (31 472 byte). Den ursprungliga sökvägen i Downloads saknas; återfunnen kopia finns i användarens papperskorg.

## Vad grenen innehåller

Alla fem plansteg är implementerade i denna arbetsgren:

1. **Tillförlitlighet:** ljuddelars tidsgränser, giltiga tidsstämplar och synliga ljudluckor; capture/interruption-återhämtning utan automatisk mikrofonstart; sessionspatchar som skyddar sena writes och radering; avgränsade gatewaydeadlines, striktare scheman/datum och utökad discovery.
2. **Workflow-ägarskap:** appägd samordning av fångsthändelser, lektionsslutförande, förslagsbeslut, radering och export; explicita resultat, generationer/avbrott och återupptagbar raderingsjournal.
3. **Provideroberoende gateway:** separata uppgifter, granskade modellprofiler, provideradaptrar och exekveringspolicy; `ask`/`everyday`/`lesson`-routing, skyddad `/v2/status`, konfigurationsrevision och fail-closed-beteende utan tyst fallback.
4. **Flöden och UX:** anslutnings-/kapacitetsprov, färskhet och konflikter för lektionsanteckningar, notisnavigation, uttryckligt sparande av AI-svar, återhämtning och små UI-smokeprov.
5. **Releaseunderlag:** Linuxverifierare/CI, strict-concurrency-diagnostik, native Xcode-workflow, syntetisk session-store-mätning, svenska dokument och driftinstruktioner.

Pinnade utvecklingsverktyg är uppdaterade till Wrangler `4.147.0` och Miniflare `5.20261001.0-alpha`. En tidigare npm-granskning hittade tre sårbarheter i enbart utvecklingsberoendeträdet; den fullständiga granskningen efter uppdatering rapporterade noll.

## Lokal verifiering

Senaste integrerade Linuxkörningen var grön: 274 strukturella kontroller, 4 verifierartester, 123 Node-tester, Worker dry-run/runtime/avbrott, 27 fake-backend API-tester, 235 portabla XCTest, 8 capture-regressioner, portable strict-concurrency och session-store-mätning. `docs/STATUS.md` redovisar begränsningarna; kvitto och fullständiga loggar från den post-commit-körning som följer överlämningen ligger i `/tmp/mio-mio-handoff-20261004-final/` på den ursprungliga värden. Kommandot är:

```sh
python3 scripts/verify.py --measure-session-store --logs-dir /tmp/mio-mio-handoff-20261004-final
```

Linuxresultatet bygger inte appen mot iOS-SDK och bevisar inte AVFoundation, Keychain, URLSession, UIKit/SwiftUI, IPA-installation, provideråtkomst, batteri eller telefonbeteende. Pythonprovet använde fake-backend; modell- och transkriptionsanrop utanför fixtures gjordes inte.

## Återstår — följ PLAN.md:s ordning

1. **Publicera den avsedda Cloudflare-kod-/konfigurationskombinationen och läsverifiera den.** Senaste läskontroll såg fortfarande Worker-version `4c22cc43-a625-48d1-86e5-e45638cbcb8e` aktiv på 100 %, äldre OpenAI-kod medan konfigurationen använder Groq. Bevara befintlig D1, räknare, Secrets och Access-regler. Verifiera aktiv release, autentiserad `/v2/status`, negativ gateway-/Access-åtkomst och skydd på alternativa adresser. Anonym 403 är inte bevis för full Access-konfiguration; deployscope/OAuth är inte fastställd. **Denna Git-begäran gav inte godkännande för Cloudflare-deploy.** Läs först [gatewayguiden](../server/cloudflare/README.md) och [Access-/Groq-guiden](../server/cloudflare/GROQ_ACCESS.md).
2. **Kör exakt revisions iOS-grind på GitHub.** `build-unsigned-ipa.yml` använder `workflow_dispatch`, så push startar inte jobbet automatiskt. Efter push: `gh workflow run build-unsigned-ipa.yml --ref codex/mio-plan-reliability`, följ sedan den nya körningen med `gh run watch <run-id>`. Kontrollera faktisk `xcode-27`-runner, Xcode/SDK, Release, XCTest, native concurrency, IPA-SHA och buildprovenance. Granska artefakten innan installation.
3. **Genomför verkliga providerprov med endast syntetiska texter efter separat sändningsgodkännande.** Prova fråga, vardagsanalys och detaljerad lektion; kontrollera begäran om reasoning av, temperatur 0, strikt schema, validerade svar, rapporterad usage och att inget tyst fallback sker. Ingen sådan trafik har skickats.
4. **Installera och prova fysiskt, först iPhone 16 Pro och därefter iPhone 13.** Följ [enhetsprotokollet](ENHETSPROV.md), [helhetstestet](TESTPLAN_HELHET.md) och [installationsguiden](INSTALLATION.md): svenska referensfraser/segmentgränser, låst skärm, nätverksbyte, serveromstart, avbrott/media reset, återhämtning, batteri/värme/latens, Keychain, URLSession, filskydd, AlarmKit/notiser, VoiceOver, större text, mörkt läge och Reduce Motion/Transparency. Redovisa bygg-, XCTest-, IPA-, installations- och telefonresultat separat.

Ingen Cloudflare-publicering, verklig modelltrafik, Xcode-körning, IPA-installation eller fysisk enhetstest har gjorts för denna gren. Moln-AI är avstängt från början. Inget råljud sparas. Fortsätt inte med ändringar som lägger till chatthistorik, cloud/Apple/CPU-tal, automatisk failover eller andra uttryckliga non-goals i [`PLAN.md`](../PLAN.md).

## Läs vidare

- [Aktuell status och verifieringsgränser](STATUS.md)
- [Gemensam verifieringsguide](VERIFIERING.md)
- [Helhetstest och acceptansmatris](TESTPLAN_HELHET.md)
- [Providerkontrakt och testprocedur](LEVERANTORSKONTRAKT.md)
- [Datamodell och lagringsinvarianter](DATAMODELL.md)
- [Beslut och versionsplan](DECISIONS.md) och [roadmap](ROADMAP.md)
- [Transkriptionsserver och privat drift](../transcription-server/README.md)

Hämta grenen i en annan checkout med `git fetch origin` och `git switch --track origin/codex/mio-plan-reliability`. Följ sedan repots [`CLAUDE.md`](../CLAUDE.md) (ersatte `AGENTS.md` 2026-10-05), håll AI-/ljudintegritetsinvarianterna ovan och uppdatera status endast efter utförda kontroller.
