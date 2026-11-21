# Plan: efter grillningen 2026-11-19

**Läge 2026-11-20:** inget av detta är byggt. Planen är **nästa steg** för Mio och ska tas innan annat nytt arbete; CI-planen som fick gå före är klar. Planen är omskriven 2026-11-20 för att köras som ett goal med subagenter (se nästa avsnitt). Provet av Mio Kontroll på datorn ([listan](../control/README.md#prov-på-datorn)) gör användaren själv, och det stoppar inte körningen.

Användarens svar i en grillning 2026-11-19. Mios riktiga användare är användarens flickvän. Hon går på gymnasiet, har 4–6 lektioner om dagen och är inte särskilt teknisk, så varje text och varje steg i appen ska vara tydligt utan förkunskaper. Datorn `cachyos-pc` är alltid på. Hon skickar resultaten till Apples appar och kopierar lektionsanteckningar till en annan AI för att plugga.

Planen körs i vågor där flera subagenter arbetar samtidigt. Varje våg slutar med grinden (`mio-verify verify`), commits och en push till `main`. Swift-delar som bara finns för iOS provas i "Bygg Mio IPA", som startar av sig själv vid push av appfiler och som Claude får köra när som helst (användarens beslut 2026-11-20). Allt som beror på telefonen eller datorn markeras **ej verifierat** tills det är provat.

## Så körs planen som ett goal

Repo: `/home/kanonmaten/Projects/mio`. Starta med till exempel `/goal Kör docs/PLAN_GRILLNING.md till slut enligt avsnittet "Så körs planen som ett goal"`.

Klart när allt det här gäller:
- Varje ruta i planen är ikryssad, eller märkt `(hoppad: <skäl>)` där planen tillåter det.
- Hela `verify` är godkänd lokalt på sista commiten, och för exakt den commiten är båda jobben i "Verifiera Mio på Linux" gröna, liksom en manuell körning av "Bygg Mio IPA" med `uitester` och `diagnostik` på.
- `CHANGELOG.md`, `docs/STATUS.md` och `docs/DECISIONS.md` är uppdaterade, och överlämningen (sist i planen) är skriven.

Regler medan goal-körningen pågår:
- Fråga inte mellan punkterna. Besluten står i tabellen nedan. Där planen skriver **antagande** gäller antagandet tills användaren säger annat, och det skrivs in i `docs/DECISIONS.md` som antagande.
- Stanna och fråga användaren bara för: riktig modelltrafik (Prova, `mio-gateway prova`, `server/install.sh` och liknande), en tagg, Cloudflare, något på datorn utanför repot (paket, tjänster, `~/.cargo`), force-push, eller en ändring som försvagar en regel i `CLAUDE.md` mer än fas 0 säger.
- Det som bara går att prova på telefonen eller datorn markeras **ej verifierat** och läggs i överlämningens provlista. Det stoppar inte körningen.
- Git: commit på `main`, inga grenar eller pull requests. Om sessionen ändå ligger i en worktree pushas `HEAD:main`. Pre-push-kroken kräver en ren arbetskopia och kör hela `verify`, så pusha bara mellan vågorna när ingen subagent har osparade ändringar. Följ CI i bakgrunden (`gh run watch <id> --exit-status` med `run_in_background`) och börja nästa våg under tiden. Bekräfta CI för exakt commit innan en våg räknas som klar.
- Ett fel på ett känt ostadigt ställe (ett UI-test som hänger i iOS 27-simulatorn, se körning #31, #33 och #47 i STATUS.md) får en `gh run rerun --failed`. Ett andra fel är ett riktigt fel: rätta det eller backa vågens commit.
- Kryssa rutorna i den här filen allt eftersom.

### Subagenter och vågor

Huvudsessionen leder: den delar ut arbete, granskar diffar, uppdaterar dokumenten, committar och pushar. Subagenterna skriver koden. De arbetar i samma arbetskopia, eftersom `CLAUDE.md` förbjuder grenar, så varje spår äger sina egna filer. En subagent committar aldrig. Den lämnar en kort rapport: ändrade filer, kontroller som körts och med vilket resultat, och vad som är ej verifierat. Huvudsessionen committar spårets filer med uttryckliga sökvägar (`git add <filer>`), aldrig `git add -A` medan ett annat spår arbetar.

| Spår | Äger | Kontroller spåret kör |
|---|---|---|
| Gateway | `server/`, `transcription-server/` | `cd server && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings`; `cd transcription-server && uv sync --locked --extra test --python 3.12 && uv run pytest tests` |
| Kontroll | `control/` | clippy och test för `control/` enligt tabellen i `CLAUDE.md` |
| App | `Mio/`, `MioWidgets/`, `MioTests/`, `MioUITests/`, `Mio.xcodeproj/` | `swift-core` och `project` |
| Ikon | `Mio/Assets.xcassets/AppIcon.appiconset/` och den nya ikonfilen (inte `project.pbxproj`) | `project` |
| Huvudsessionen | `docs/`, `CHANGELOG.md`, `README.md`, `CLAUDE.md`, `tools/` och den här planen | `project`, `tools`-testerna och hela `verify` |

Bara en App-agent åt gången, eftersom appens stora filer (till exempel `MioViewModel.swift`) delas av nästan alla app-punkter. Ge varje subagent planens punkter ordagrant, kontraktet från fas 0 och de lärdomar som fasen säger ska läsas. Använd Explore-agenter för uppslag i Apples och Mistrals dokumentation, så att huvudsessionens kontext räcker hela körningen.

| Våg | Samtidigt | Push |
|---|---|---|
| 1 | Huvudsessionen: fas 0 | efter fas 0 |
| 2 | Gateway: fas 1. Kontroll: fas 2 mot kontraktet. App: fas 4 utom egna ord | när alla tre är klara |
| 3 | Gateway: serverdelarna av fas 3 (`examHints`), fas 4 (egna ord) och fas 6 (säkerhetskopians mottagare). App: fas 3 och egna ord i fas 4. Kontroll: säkerhetskopian i fas 6 | när alla tre är klara |
| 4 | App: fas 5 och sedan fas 6. Ikon: fas 7 | när båda är klara |
| 5 | Huvudsessionen: överlämningen | sist |

Efter varje våg och före pushen granskar en subagent vågens diff mot reglerna i `CLAUDE.md` och planens punkter (till exempel `/code-review high` på de nya commitarna). Bekräftade fel rättas i samma våg.

## Beslut som planen utgår från

Fas 0 skriver in dem i [DECISIONS.md](DECISIONS.md) med de bortvalda alternativen.

| Fråga | Val | Bortvalt |
|---|---|---|
| AI-leverantör | Mistral blir standard i `server/install.sh` under de tre månaderna med ett gratis prov av Vibe Pro, som ger mer än $20 i API-användning i månaden (användarens uppgift 2026-11-20). Groq `qwen/qwen3.8-27b` och Claude Haiku 5.5 hos Anthropic står kvar som granskade och valbara i Mio Kontroll | Bara Mistral; Groq kvar som standard |
| Schema hos Mistral | **Regeländring (användarens val 2026-11-20):** Mistral dokumenterar inte `strict` för `json_schema` och lägger schemat i systemprompten. Mistral får ändå köras. Gatewayen skickar schemat som i dag och validerar varje svar, och en ogiltig punkt kastas eller repareras ur källan som förut. `/v2/status` visar `schema_dialect: json-schema` för Mistral | Groq kvar som standard för att behålla strikt schema |
| Modell per uppgift | `everyday` och `ask`: Mistral Small 4 (`mistral-small-2603`) med `reasoning_effort: "none"`. `lesson`: Mistral Large 4 med `reasoning_effort: "medium"` | Large 4 överallt (kan inte stänga av resonemang, cirka $28/mån bara för vardag); Small 4 överallt; Mistral Medium 3.5 (utfasad 2026-10-31); GLM 5.3 och GLM 5.3 Flash (saknar `none`, den stora kostar dubbelt så mycket som Large 4); DeepSeek V4.1 Flash (Public Preview, ID:t skiljer mellan sidorna) |
| Resonemang | **Regeländring godkänd:** bara uppgiften `lesson` får resonera, på nivån medium. Tankedelarna kastas i gatewayen och sparas, loggas eller visas aldrig. Strikt schema och validering gäller som förut. `everyday` och `ask` har resonemang av | Resonemang för alla uppgifter; valbar nivå per uppgift |
| Prova | Användaren trycker Prova i Mio Kontroll själv. Claude kör ingen riktig modelltrafik | Claude kör `mio-gateway prova` |
| Kostnad | Ungefär $7/mån för vardag och $4/mån för cirka 100 lektioner, alltså $11 av drygt $20. Priser 2026-11-20 per miljon token: Small 4 $0,15 in och $0,60 ut, Large 4 $0,70 in och $2,10 ut, cachad indata en tiondel | |
| Provtips | Avsnittet "Viktigt till provet" först i lektionsanteckningen, varje punkt med citat | Markering i texten; lista per ämne |
| Läxdatum | Föreslaget datum (eller tomt) som hon justerar när hon säger Ja | Eget schema i Mio; läsa Kalender |
| Lektionsstart | Öppna appen och tryck Starta lektion, som nu | Schema, widgets och Action-knappen |
| Under lektionen | Lugn vy: tid, en diskret lyssnarprick och antal provtips och läxor hittills. Transkriptet finns ett tryck bort | Löpande transkript |
| Talare | Den som pratar mest visas som "Lärare", övriga som "Elev 1, 2…". Bara ett visningslager som hon kan ändra | Neutrala etiketter |
| Granska efter lektionen | Ett ark med lektionens förslag direkt när anteckningarna är klara | Bara under Förslag |
| Egna ord | När hon rättar ett ord frågar Mio om det ska bli ett eget ord. Vid Ja skickas det till ordlistan på datorn | Hela listan i inställningarna |
| Vardagsfångst | Stora delar av dagen | |
| Låg batterinivå | Vardagsfångst pausas under 20 % eller i strömsparläge, och hon kan alltid starta igen. **En lektion avbryts aldrig på grund av batteriet** | |
| Lång tystnad | Efter cirka 20 minuter utan tal frågar en notis om Mio ska fortsätta lyssna. Utan svar pausar Mio. Ingen automatisk omstart | |
| Lagring | Vardagstranskript raderas efter 30 dagar. Godkända förslag, anteckningar och lektioner sparas | 7 dagar; för alltid; eget val |
| Andra människors tal | Som i dag | Bara hennes röst till AI; filtrera bort andra |
| Vibration | Bara vid direkt tilltal ("Mio, …"). Det som plockas upp i bakgrunden väntar tyst under Förslag | Vibration vid varje förslag |
| Direkt anteckning | **Regeländring godkänd:** "Mio, kom ihåg …" och "Mio, notera …" räknas som Ja. Påminnelser och Mio-anteckningar sparas direkt, med Ångra i 24 timmar. En kalenderhändelse väntar under Förslag och öppnar Kalenders ruta (inga tysta kalenderposter) | Ja på skärmen; Ja med rösten |
| Vart det hamnar | Efter typ: påminnelse till Påminnelser, tid och plats till Kalender (via rutan), övrigt som Mio-anteckning | Alltid Apple Anteckningar; alltid Mio |
| Väckningsfras | Två ord: både "Mio, kom ihåg" och "Mio, notera" fungerar | "Mio" ensamt; "Hej Mio" |
| Återkoppling | Två korta vibrationer: sparat. En lång: inte förstått | Ljud i AirPods |
| Hem | Nedräkning till prov ("Biologiprov om 3 dagar") från en vecka före | Dagens lektioner; läxor |
| Inför provet | En knapp som kopierar ämnets provtips och lektionsanteckningar sedan förra provet | Bara provtips |
| Fråga Mio | Oförändrad (används sällan) | Fråga om en lektion |
| Morgon och kväll | Morgon: dagens prov och läxor (hon slår på det själv, eftersom texten syns på låsskärmen). Kväll: antal förslag att granska | Neutral text |
| Inställningar | Det enkla överst, det tekniska under ett ihopfällt Avancerat | Dold utvecklarmeny |
| Fel | En mening och en åtgärd, plus "Skicka felrapport" med textfri diagnostik | Som i dag |
| Uppsättning | Användaren sätter upp telefonen. Mio får en sida "Kontrollera allt" | Guidad introduktion |
| Signering | SideStore med manuell uppdatering, eftersom Tailscale och LocalDevVPN inte kan vara på samtidigt. Notis dagen innan signeringen går ut, med mycket tydliga steg | Betalt utvecklarkonto; automatisk uppdatering |
| Säkerhetskopia | Varje natt under laddning skickas exporten via Tailscale till datorn, krypterad, 14 kopior, återställning i inställningarna | iCloud Drive; ingen |
| Övervakning | Mio Kontroll visar en skrivbordsnotis när en tjänst har stannat eller startar om gång på gång | Push till telefonen; hennes app visar vem hon ska fråga |
| Ikon | Hela ordet "mio" där o:et är en ring med en liten ljudvåg, gjord i Icon Composer med Liquid Glass-lager i Mios blå ton | Bara symbol; stort M |
| Integritetssida | Ingen ny | "Vad Mio skickar vart" |

## Fas 0: beslut, regler och kontrakt

Huvudsessionen gör fasen själv. Den är kort, och vågorna efter den bygger på den.

- [x] Skriv avsnittet "Grillningen, 2026-11-19" i [DECISIONS.md](DECISIONS.md) med tabellen ovan (val och bortvalt) och källorna längst ned.
- [x] Ändra reglerna i `CLAUDE.md` (användaren godkände dem 2026-11-19 och 2026-11-20):
  - AI-raden: Mistral är det `server/install.sh` sätter upp. Groq och Haiku 5.5 står kvar som granskade.
  - "strict JSON schema" blir: strikt schema där leverantören har det. Hos Mistral ligger schemat i prompten och gatewayen validerar varje svar.
  - "Every call has reasoning off" blir: reasoning är av för `ask` och `everyday`. `lesson` får resonera på den granskade nivån, och tankedelarna kastas i gatewayen och lagras eller visas aldrig.
  - "Suggestions need an explicit Yes" blir: förslag kräver ett uttryckligt Ja. En direkt instruktion ("Mio, kom ihåg/notera") är ett Ja för Påminnelser och Mio-anteckningar och kan ångras i 24 timmar. Kalenderhändelser skapas aldrig tyst.
- [x] Uppdatera [PRODUKTVISION.md](PRODUKTVISION.md) med ändringarna om resonemang och direkta anteckningar ("Bekräfta före åtgärd").
- [x] Skriv kontrakten som spåren i våg 2 och 3 bygger mot, i ett avsnitt "Kontrakt efter grillningen" i [DATAMODELL.md](DATAMODELL.md). Spåren får inte ändra dem; behövs en ändring säger spåret till huvudsessionen.
  - `/v2/status`: användning per månad, uppgift och modell (in, cachad in, ut, resonemang), uppskattad kostnad i USD med prisernas datum, och resonemangsnivån per uppgift.
  - Lektionsresultatet: den nya schemaversionen med `examHints` (text och citat, högst åtta) och hur talarnas roller (Lärare, Elev) skickas med.
  - Egna ord från telefonen: metod, sökväg och svar för den nya vägen i Pianissimo, autentiserad med parningen.
  - Säkerhetskopian: vägen dit telefonen skickar exporten, vem som tar emot den, och vad Mio Kontroll läser för att visa senaste kopian.
- [x] Kör `cargo run --locked --manifest-path tools/Cargo.toml -- project`. Om strukturkontrollen letar efter de gamla regeltexterna ändras kontrollen i `tools/` och dess svenska meddelanden lämnas som de är.

## Fas 1: gatewayen för Mistral

Läs först [gatewayguiden](../server/README.md) och lärdomen om [innehållsberoende fel](../.trail/learnings/2026-11-17-ai-batch-failures-caused-by-the-kanonmaten.md).

- [x] Kontrollera Mistrals dokumentation igen innan koden skrivs. Modellsidan för Large 4 ger ID:t, så skriv inget ID ur minnet. Den 2026-11-20 gav resonemangssidan både `mistral-large-4-0` och `mistral-large-4`; välj det som är låst till en version och inte ett alias som kan flytta. Large 4 (släppt 2026-11-05) tar `low`, `medium` och `high`, aldrig `none`. Källor: [resonemang](https://docs.mistral.ai/inference/conversations/reasoning.md), [strukturerad utdata](https://docs.mistral.ai/inference/conversations/structured-output/custom.md), [Large 4](https://docs.mistral.ai/models/mistral-large-4-0), [Small 4](https://docs.mistral.ai/models/mistral-small-4-0-26-03), [priser](https://docs.mistral.ai/inference/pricing).
- [x] `server/src/model_profiles.rs`:
  - [x] Ta bort `mistral-medium-3-5` ur `CANDIDATE_MODELS`.
  - [x] Lägg till Large 4 som kandidat med `ReasoningOff` ersatt av en resonemangsinställning, till exempel `Reasoning::Effort("medium")`. Large 4 tar inte `none`, så den får aldrig väljas för `ask` eller `everyday`.
  - [x] Bind resonemang till uppgiften: ett par som resonerar går bara att välja för `lesson`. Gatewayen vägrar starta (`provider_options_incompatible`) om ett sådant par står för en annan uppgift.
  - [x] Small 4 behåller `reasoning_effort: "none"`. Båda Mistral-modellerna behåller `schema_dialect: "json-schema"`, eftersom dokumentationen 2026-11-20 inte nämner `strict` (se beslutet om schema hos Mistral).
  - [x] Om temperaturen avvisas när resonemang är på: använd samma flagga som för Anthropic (`temperature: false`), syns i `/v2/status`.
- [x] `server/src/adapters.rs`:
  - [x] Behåll `response_format` som `chat_request` bygger det i dag (`json_schema` med namn, schema och `strict` från generationen). Lita inte på att Mistral följer det; valideringen avgör.
  - [x] Skicka `reasoning_effort: "medium"` för lektionsprofilen.
  - [x] Svarstolkningen: idag avvisas en lista med en `thinking`-del (rad cirka 290). För en profil som får resonera: ta bara textdelen (`type: "text"`), kasta tankedelen utan att logga den och avvisa allt annat (flera textdelar, verktygsanrop, tom text). Profiler med resonemang av fortsätter att avvisa tankedelar.
  - [x] Räkna `reasoning_tokens` i användningen men lägg aldrig tanketext i loggar, fel eller tillståndsfilen.
- [x] `server/src/config.rs`: `max_tokens` för lektioner måste rymma tänkandet. Sätt en egen gräns för `lesson` med marginal för tänkandet, i stället för att höja alla uppgifter, och välj den utifrån Mistrals dokumentation. Användaren mäter med Prova (överlämningen), och gränsen justeras efter det. Mistral har ingen minutgräns som Groqs gratisnivå, så `MIO_TOKENS_PER_MINUTE_MISTRAL` lämnas tom som standard.
- [x] Användningsräknaren för kreditmätaren: `record_usage` i `server/src/server.rs` räknar redan token, men bara som en summa. Adaptrarna måste lämna in, cachad in, ut och resonemang var för sig. Spara per månad, uppgift och modell (in, cachad in, ut, resonemang) i gatewayens tillståndsfil och visa det i `/v2/status`. Lägg priserna i en granskad tabell bredvid modellen, med datum och källa.
- [x] `server/install.sh`: i dag kan skriptet bara Groq (det kontrollerar en `gsk_`-nyckel, har valet `--ny-groq-nyckel` och skriver en modell för alla uppgifter). Gör Mistral till standardval (`MISTRAL_API_KEY`) med modellerna ovan per uppgift. En ny installation ber om Mistral-nyckeln och kör sedan `mio-gateway prova` för båda Mistral-paren, eftersom det är användaren som kör skriptet. Paren godkänns bara om provet går igenom; annars stannar skriptet med en tydlig text. En befintlig Groq-installation lämnas orörd med samma token, så att telefonen inte behöver paras om, och byter till Mistral i Mio Kontroll. Claude kör aldrig skriptet.
- [x] `server/README.md`: leverantörstabellen, kostnaden, att Vibe Pro-provet tar slut efter tre månader, och att Mistrals admin-konsol bör stängas av för träning på API-data (användaren gör det själv).
- [x] Tester med syntetisk transport: att tankedelen kastas, att en tankedel avvisas för `everyday`, att Large 4 inte går att välja för `ask`, användningsräknaren, och att pariteten med Node fortfarande håller (`cargo test --locked`, clippy utan varningar).

## Fas 2: Mio Kontroll

Läs först `control/README.md`, `control/DESIGN.md` och lärdomarna om [gpui-kit 0.10](../.trail/learnings/2026-11-17-gpui-kit-0-10-gaps-to-kanonmaten.md) och [UI-testerna i ett testprogram](../.trail/learnings/2026-11-17-keep-mio-kontroll-s-ui-tests-kanonmaten.md).

- [x] AI-sidan (`control/app/src/ai.rs`, `control/core/src/ai_settings.rs`): avsnittet "Prova modellerna" finns redan, med en Prova-knapp per par. Bygg ut det: Mistral-kandidaterna överst, och visa vad Prova kostar och att den går till Mistral.
- [x] Kreditmätaren: token och uppskattad kostnad den här månaden per uppgift och modell, mot en kreditgräns som användaren skriver in (standard $20). Data från `/v2/status` enligt kontraktet i fas 0; i testerna med påhittade värden. Gul vid 80 %, röd vid 100 %. Data från `/v2/status`.
- [x] Visa vilken uppgift som resonerar och på vilken nivå, och att Large 4 bara går att välja för Lektion.
- [x] Övervakning: en skrivbordsnotis när gatewayen eller Pianissimo har stannat eller startat om fler än tre gånger på tio minuter (från journalen i `control/core/src/journal.rs` och `status.rs`).
- [x] Gränssnittstester i det befintliga testprogrammet, och ett nytt prov i listan [Prov på datorn](../control/README.md#prov-på-datorn) för Prova mot Mistral.

## Fas 3: lektioner

- [x] Lektionsschemat i gatewayen (`server/src/prompts.rs`, `analysis.rs`, `validate_lesson_result`): lägg till `examHints` (högst åtta, varje punkt med ett citat ur källtexten som valideras som i dag), först i anteckningen. Höj schemaversionen och ta med det i appens avkodning.
- [x] Prompten: leta efter "det här kommer på provet", "kom ihåg", "viktigt" och liknande. Hellre för få provtips än gissningar.
- [x] Appen: avsnittet "Viktigt till provet" först i anteckningen och med i kopieringen.
- [x] Talare: talarnamn finns redan ("Talare N", som kan bytas när sessionen har stoppats). Lägg etiketten "Lärare" på den som pratar mest och "Elev 1, 2…" på de andra, som visningslager (originalet ändras inte). Hon kan byta namn. Skicka etiketten till lektionsanalysen så att lärarens ord väger tyngst.
- [x] Lugn vy under lektionen: tid, lyssnarprick och antal provtips och läxor hittills. Transkriptet ett tryck bort. Live Activity som i dag.
- [x] Granskningsark när anteckningarna är klara: lektionens förslag med datumfältet förifyllt eller tomt, Ja eller Nej för varje. Notisen "Anteckningarna från lektionen är klara" öppnar arket.
- [x] Spara tiden från lektionsslut till färdiga anteckningar lokalt (utan text) och visa den i diagnostiken. Målet är under fem minuter; mätningen på telefonen står i överlämningen.

## Fas 4: vardagsfångst och "Mio, …"

- [x] Väckningsfraserna "Mio, kom ihåg" och "Mio, notera" i den lokala detekteringen. Ensamt "Mio" räknas inte längre som direkt tilltal. Uppdatera grammatiken utan AI och testerna för Mio-detektion.
- [x] Direkt anteckning: sparas direkt efter typ (Påminnelser eller Mio-anteckning) med Ångra i 24 timmar under Förslag. En kalenderhändelse läggs under Förslag och öppnar Kalenders ruta.
- [x] Vibrationer: två korta för sparat och en lång för inte förstått, bara vid direkt tilltal. Förslag som plockats upp i bakgrunden ger ingen vibration.
- [x] Batteri: pausa vardagsfångst under 20 % eller i strömsparläge och visa varför. Hon kan starta igen direkt. **Lektioner pausas aldrig av batteriet.** Skriv ett test för just det.
- [x] Tystnad: efter 20 minuter utan tal en notis "Lyssnar Mio fortfarande?". Utan svar inom fem minuter pausar Mio. Ingen automatisk omstart (befintlig regel).
- [x] Lagring: vardagstranskript äldre än 30 dagar raderas vid start och i bakgrunden. Lektioner, anteckningar och godkända förslag sparas. Om SwiftData-schemat behöver ändras sker det via `VersionedSchema` och migreringsplanen. Kommentera regeln.
- [x] Egna ord från telefonen: när hon rättar ett ord frågar Mio om det ska bli ett eget ord. Vid Ja skickas det via Tailscale till ordlistan på datorn (ny väg i Pianissimo, autentiserad med parningen). Ordet skickas aldrig vidare till AI-leverantören, och ett fel får aldrig stoppa transkriptionen.
- [x] Lokal räkning (utan text) av hur ofta hon trycker Nej eller Ångra på direkta anteckningar, för att se om fraserna löses ut fel.

## Fas 5: Hem, notiser och prov

- [x] Ämne per lektion. Hon ville inte ha ett schema. **Antagande** för goal-körningen: AI föreslår ämnet efter lektionen och hon bekräftar eller ändrar det i granskningsarket. Skriv antagandet i DECISIONS. Nedräkningen och provpaketet bygger på det här.
- [x] Hem: nedräkning till prov från godkända provplaner, synlig från en vecka före.
- [x] "Inför provet": en knapp i provförslaget och på Hem som kopierar ämnets provtips och lektionsanteckningar sedan förra provet.
- [x] Morgonnotis med dagens prov och läxor, avstängd tills hon slår på den (texten syns på låsskärmen). Kvällsnotis med antal förslag att granska, som öppnar Förslag.

## Fas 6: enkelhet för henne

- [x] Inställningsarket: överst notiser, tider, AI-paus, lagring, säkerhetskopia och en rad "Allt fungerar" eller "Något är fel". Parning, kvot, release och diagnostik under ett ihopfällt Avancerat. Fortfarande ett enda ark (befintlig regel).
- [x] Gå igenom alla feltexter i appen: en mening och en åtgärd, på vanlig svenska, utan HTTP-koder eller engelska. Knappen "Skicka felrapport" öppnar dela-arket med textfri diagnostik.
- [x] Sidan "Kontrollera allt": mikrofon, notiser, Påminnelser, Tailscale, datorn, Pianissimo och AI, en grön eller röd rad var med en åtgärd.
- [x] Signeringens slut: läs `ExpirationDate` ur `embedded.mobileprovision` i appen och visa antal dagar kvar i inställningarna. En lokal notis 24 timmar före med stegen: 1. Stäng av Tailscale. 2. Öppna SideStore och slå på LocalDevVPN. 3. Tryck Uppdatera vid Mio. 4. Stäng av LocalDevVPN och slå på Tailscale igen. **Ej verifierat** tills det är provat med en SideStore-installation.
- [x] Säkerhetskopia varje natt under laddning (`BGProcessingTask`): den versionsmärkta JSON-exporten skickas via Tailscale till datorn, krypteras där och sparas i 14 kopior. Återställning i inställningarna. Aldrig till molnet. Mio Kontroll visar senaste kopian.

## Fas 7: ikonen

- [x] Rita ikonen: hela ordet "mio" i rundade gemener, o:et som en ring med en liten ljudvåg, i Mios blå ton (aldrig violett). Separata lager för bakgrund, ord och ljudvåg, så att iOS 27 ritar glas samt mörkt och tonat läge. Icon Composer är ett Mac-program och går inte att köra här, så bygg `.icon`-filen för hand (lagren som SVG och filens JSON) enligt Apples dokumentation. Huvudsessionen lägger in den i `project.pbxproj` efter våg 4, och "Bygg Mio IPA" visar om `actool` godtar den. Godtas den inte efter två försök: märk punkten `(hoppad: <felet>)` och låt användaren göra filen i Icon Composer.
- [x] Behåll PNG-filerna i `Mio/Assets.xcassets/AppIcon.appiconset` som reserv och byt ut dem mot samma motiv.
- [ ] Hämta skärmbilderna från "Bygg Mio IPA" (`gh run download`) och granska dem i ljust, mörkt och tonat läge.

## Sist: överlämning

- [ ] [CHANGELOG.md](../CHANGELOG.md) för det som syns för användaren, och [STATUS.md](STATUS.md) bara med kontroller som faktiskt körts.
- [ ] Kör "Bygg Mio IPA" för sista commiten med `uitester` och `diagnostik` på, och vänta tills den är grön.
- [ ] Skriv överlämningen till användaren: vad som ändrats, vilka commitar som är provade och var, och vad användaren själv gör. Det är `./server/install.sh` på datorn, Prova för Mistral i Mio Kontroll (och gränsen för `lesson` efter mätningen), att stänga av träning på API-data i Mistrals konsol, provet av Mio Kontroll på datorn, telefonproven nedan, och de antaganden som gjorts.
- [x] Lägg till telefonprov i [helhetstestet](TESTPLAN_HELHET.md): en hel lektion med provtips och läxor, en skoldag med vardagsfångst och låg batterinivå (lektionen fortsätter), direkt anteckning med Ångra, signeringsnotisen och en återställning från säkerhetskopian.

## Öppna frågor

Användaren valde att inte gå igenom dem 2026-11-19. Ingen av dem stoppar goal-körningen: fråga 1 har ett antagande i fas 5, och de andra ändrar inget i planen. Ta upp dem med användaren i överlämningen.

1. Ämne per lektion (se fas 5).
2. Språklektioner: Pianissimo är en svensk modell. Vad som händer på engelska, spanska och tyska är inte bestämt.
3. Vilken telefon hon har (iPhone 13 eller annan), och därmed batteri och värme under en hel skoldag.
4. Om användaren själv också ska använda Mio mot samma dator.
5. Mistrals träning på API-data och vad som händer när Vibe Pro-provet tar slut efter tre månader (Groq igen, betala för Mistral eller blanda). Varning vid 80 % av krediten är med i fas 2.
6. Om skolan tillåter att lektioner spelas in, och om Mio ska påminna om att fråga läraren.
7. Mikrofon i klassrummet (telefonen på bänken eller en extern mikrofon).
8. ~~Mätning av Pianissimo i FP16 på RTX 4060 Ti innan hon börjar.~~ Besvarad 2026-11-17: FP16 är standard utan mätning först (se DECISIONS).
