# Plan: efter grillningen 2026-11-19

**Läge 2026-11-19:** inget av detta är byggt. Planen är **nästa steg** för Mio och ska tas innan annat nytt arbete. Mio Kontroll ska först provas på datorn ([listan](../control/README.md#prov-på-datorn)), eftersom kreditmätaren och Prova finns där.

Användarens svar i en grillning 2026-11-19. Mios riktiga användare är användarens flickvän. Hon går på gymnasiet, har 4–6 lektioner om dagen och är inte särskilt teknisk, så varje text och varje steg i appen ska vara tydligt utan förkunskaper. Datorn `cachyos-pc` är alltid på. Hon skickar resultaten till Apples appar och kopierar lektionsanteckningar till en annan AI för att plugga.

Planen är skriven för att köras fas för fas i Claude Code. Varje fas slutar med grinden (`mio-verify verify`), en commit och en push till `main`. Swift-delar som bara finns för iOS provas först i "Bygg Mio IPA", och den körs bara när användaren säger till. Allt som beror på telefonen markeras **ej verifierat** tills det är provat.

## Beslut som planen utgår från

Fas 0 skriver in dem i [DECISIONS.md](DECISIONS.md) med de bortvalda alternativen.

| Fråga | Val | Bortvalt |
|---|---|---|
| AI-leverantör | Mistral blir standard i `server/install.sh` under de tre månaderna med Mistral Pro (cirka $15 API-krediter i månaden enligt prissidan). Groq `qwen/qwen3.8-27b` står kvar som granskat och valbart i Mio Kontroll | Bara Mistral; Groq kvar som standard |
| Modell per uppgift | `everyday` och `ask`: Mistral Small 4 (`mistral-small-2603`) med `reasoning_effort: "none"`. `lesson`: Mistral Large 4 med `reasoning_effort: "medium"` | Large 4 överallt (kan inte stänga av resonemang, cirka $28/mån bara för vardag); Small 4 överallt; Mistral Medium 3.5 (utfasad 2026-10-31); GLM 5.3 och GLM 5.3 Flash (saknar `none`, den stora kostar dubbelt så mycket som Large 4); DeepSeek V4.1 Flash (Public Preview, ID:t skiljer mellan sidorna) |
| Resonemang | **Regeländring godkänd:** bara uppgiften `lesson` får resonera, på nivån medium. Tankedelarna kastas i gatewayen och sparas, loggas eller visas aldrig. Strikt schema och validering gäller som förut. `everyday` och `ask` har resonemang av | Resonemang för alla uppgifter; valbar nivå per uppgift |
| Prova | Användaren trycker Prova i Mio Kontroll själv. Claude kör ingen riktig modelltrafik | Claude kör `mio-gateway prova` |
| Kostnad | Ungefär $7/mån för vardag och $4/mån för cirka 100 lektioner, alltså $11 av $15 | |
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

## Fas 0: beslut och regler

- [ ] Skriv avsnittet "Grillningen, 2026-11-19" i [DECISIONS.md](DECISIONS.md) med tabellen ovan (val och bortvalt) och källorna längst ned.
- [ ] Ändra reglerna i `CLAUDE.md` (användaren godkände dem 2026-11-19):
  - AI-raden: Mistral är det `server/install.sh` sätter upp. Groq står kvar som granskat.
  - "Every call has reasoning off" blir: reasoning är av för `ask` och `everyday`. `lesson` får resonera på den granskade nivån, och tankedelarna kastas i gatewayen och lagras eller visas aldrig.
  - "Suggestions need an explicit Yes" blir: förslag kräver ett uttryckligt Ja. En direkt instruktion ("Mio, kom ihåg/notera") är ett Ja för Påminnelser och Mio-anteckningar och kan ångras i 24 timmar. Kalenderhändelser skapas aldrig tyst.
- [ ] Uppdatera [PRODUKTVISION.md](PRODUKTVISION.md) med samma två ändringar ("Bekräfta före åtgärd").
- [ ] Kör `cargo run --locked --manifest-path tools/Cargo.toml -- project`. Om strukturkontrollen letar efter de gamla regeltexterna ändras kontrollen i `tools/` och dess svenska meddelanden lämnas som de är.

## Fas 1: gatewayen för Mistral

Läs först [gatewayguiden](../server/README.md) och lärdomen om [innehållsberoende fel](../.trail/learnings/2026-11-17-ai-batch-failures-caused-by-the-kanonmaten.md).

- [ ] Kontrollera Mistrals dokumentation igen innan koden skrivs. Modellsidan för Large 4 ger ID:t, så skriv inget ID ur minnet; `mistral-large-4-0` och `mistral-large-4` förekommer båda. Källor: [resonemang](https://docs.mistral.ai/inference/conversations/reasoning.md), [strukturerad utdata](https://docs.mistral.ai/inference/conversations/structured-output/custom.md), [Large 4](https://docs.mistral.ai/models/mistral-large-4-0), [Small 4](https://docs.mistral.ai/models/mistral-small-4-0-26-03), [priser](https://docs.mistral.ai/inference/pricing).
- [ ] `server/src/model_profiles.rs`:
  - [ ] Ta bort `mistral-medium-3-5` ur `CANDIDATE_MODELS`.
  - [ ] Lägg till Large 4 som kandidat med `ReasoningOff` ersatt av en resonemangsinställning, till exempel `Reasoning::Effort("medium")`. Large 4 tar inte `none`, så den får aldrig väljas för `ask` eller `everyday`.
  - [ ] Bind resonemang till uppgiften: ett par som resonerar går bara att välja för `lesson`. Gatewayen vägrar starta (`provider_options_incompatible`) om ett sådant par står för en annan uppgift.
  - [ ] Small 4 behåller `reasoning_effort: "none"`. Sätt `schema_dialect` till strikt om dokumentationen bekräftar `strict: true` i `json_schema`, annars får provet avgöra det.
  - [ ] Om temperaturen avvisas när resonemang är på: använd samma flagga som för Anthropic (`temperature: false`), syns i `/v2/status`.
- [ ] `server/src/adapters.rs`:
  - [ ] Bygg `response_format: {type: "json_schema", json_schema: {name, schema, strict: true}}` för Mistral.
  - [ ] Skicka `reasoning_effort: "medium"` för lektionsprofilen.
  - [ ] Svarstolkningen: idag avvisas en lista med en `thinking`-del (rad cirka 290). För en profil som får resonera: ta bara textdelen (`type: "text"`), kasta tankedelen utan att logga den och avvisa allt annat (flera textdelar, verktygsanrop, tom text). Profiler med resonemang av fortsätter att avvisa tankedelar.
  - [ ] Räkna `reasoning_tokens` i användningen men lägg aldrig tanketext i loggar, fel eller tillståndsfilen.
- [ ] `server/src/config.rs`: `max_tokens` för lektioner måste rymma tänkandet. Mät i provet och sätt en egen gräns för `lesson`, i stället för att höja alla uppgifter. Mistral har ingen minutgräns som Groqs gratisnivå, så `MIO_TOKENS_PER_MINUTE_MISTRAL` lämnas tom som standard.
- [ ] Användningsräknaren för kreditmätaren: `record_usage` i `server/src/server.rs` räknar redan token. Spara per månad, uppgift och modell (in, cachad in, ut, resonemang) i gatewayens tillståndsfil och visa det i `/v2/status`. Lägg priserna i en granskad tabell bredvid modellen, med datum och källa.
- [ ] `server/install.sh`: Mistral som standardval (`MISTRAL_API_KEY`), modellerna ovan per uppgift, och en befintlig Groq-installation lämnas orörd med samma token, så att telefonen inte behöver paras om.
- [ ] `server/README.md`: leverantörstabellen, kostnaden, att Pro-krediterna tar slut efter tre månader, och att Mistrals admin-konsol bör stängas av för träning på API-data (användaren gör det själv).
- [ ] Tester med syntetisk transport: att tankedelen kastas, att en tankedel avvisas för `everyday`, att Large 4 inte går att välja för `ask`, användningsräknaren, och att pariteten med Node fortfarande håller (`cargo test --locked`, clippy utan varningar).

## Fas 2: Mio Kontroll

Läs först `control/README.md`, `control/DESIGN.md` och lärdomarna om [gpui-kit 0.10](../.trail/learnings/2026-11-17-gpui-kit-0-10-gaps-to-kanonmaten.md) och [UI-testerna i ett testprogram](../.trail/learnings/2026-11-17-keep-mio-kontroll-s-ui-tests-kanonmaten.md).

- [ ] AI-sidan (`control/app/src/ai.rs`, `control/core/src/ai_settings.rs`): Mistral-kandidaterna överst, med en Prova-knapp per kandidat och uppgift. Visa vad Prova kostar och att den går till Mistral.
- [ ] Kreditmätaren: token och uppskattad kostnad den här månaden per uppgift och modell, mot en krediträkning som användaren skriver in (standard $15). Gul vid 80 %, röd vid 100 %. Data från `/v2/status`.
- [ ] Visa vilken uppgift som resonerar och på vilken nivå, och att Large 4 bara går att välja för Lektion.
- [ ] Övervakning: en skrivbordsnotis när gatewayen eller Pianissimo har stannat eller startat om fler än tre gånger på tio minuter (från journalen i `control/core/src/journal.rs` och `status.rs`).
- [ ] Gränssnittstester i det befintliga testprogrammet, och ett nytt prov i listan [Prov på datorn](../control/README.md#prov-på-datorn) för Prova mot Mistral.

## Fas 3: lektioner

- [ ] Lektionsschemat i gatewayen (`server/src/prompts.rs`, `analysis.rs`, `validate_lesson_result`): lägg till `examHints` (högst åtta, varje punkt med ett citat ur källtexten som valideras som i dag), först i anteckningen. Höj schemaversionen och ta med det i appens avkodning.
- [ ] Prompten: leta efter "det här kommer på provet", "kom ihåg", "viktigt" och liknande. Hellre för få provtips än gissningar.
- [ ] Appen: avsnittet "Viktigt till provet" först i anteckningen och med i kopieringen.
- [ ] Talare: lägg etiketten "Lärare" på den som pratar mest och "Elev 1, 2…" på de andra, som visningslager (originalet ändras inte). Hon kan byta namn. Skicka etiketten till lektionsanalysen så att lärarens ord väger tyngst.
- [ ] Lugn vy under lektionen: tid, lyssnarprick och antal provtips och läxor hittills. Transkriptet ett tryck bort. Live Activity som i dag.
- [ ] Granskningsark när anteckningarna är klara: lektionens förslag med datumfältet förifyllt eller tomt, Ja eller Nej för varje. Notisen "Anteckningarna från lektionen är klara" öppnar arket.
- [ ] Mät tiden från lektionsslut till färdiga anteckningar i provet. Målet är under fem minuter.

## Fas 4: vardagsfångst och "Mio, …"

- [ ] Väckningsfraserna "Mio, kom ihåg" och "Mio, notera" i den lokala detekteringen. Ensamt "Mio" räknas inte längre som direkt tilltal. Uppdatera grammatiken utan AI och testerna för Mio-detektion.
- [ ] Direkt anteckning: sparas direkt efter typ (Påminnelser eller Mio-anteckning) med Ångra i 24 timmar under Förslag. En kalenderhändelse läggs under Förslag och öppnar Kalenders ruta.
- [ ] Vibrationer: två korta för sparat och en lång för inte förstått, bara vid direkt tilltal. Förslag som plockats upp i bakgrunden ger ingen vibration.
- [ ] Batteri: pausa vardagsfångst under 20 % eller i strömsparläge och visa varför. Hon kan starta igen direkt. **Lektioner pausas aldrig av batteriet.** Skriv ett test för just det.
- [ ] Tystnad: efter 20 minuter utan tal en notis "Lyssnar Mio fortfarande?". Utan svar inom fem minuter pausar Mio. Ingen automatisk omstart (befintlig regel).
- [ ] Lagring: vardagstranskript äldre än 30 dagar raderas vid start och i bakgrunden. Lektioner, anteckningar och godkända förslag sparas. Om SwiftData-schemat behöver ändras sker det via `VersionedSchema` och migreringsplanen. Kommentera regeln.
- [ ] Egna ord från telefonen: när hon rättar ett ord frågar Mio om det ska bli ett eget ord. Vid Ja skickas det via Tailscale till ordlistan på datorn (ny väg i Pianissimo, autentiserad med parningen). Ordet skickas aldrig vidare till AI-leverantören, och ett fel får aldrig stoppa transkriptionen.
- [ ] Lokal räkning (utan text) av hur ofta hon trycker Nej eller Ångra på direkta anteckningar, för att se om fraserna löses ut fel.

## Fas 5: Hem, notiser och prov

- [ ] Ämne per lektion: avgör först hur Mio vet ämnet. Hon ville inte ha ett schema. Förslag att ta med användaren: AI föreslår ämnet efter lektionen och hon bekräftar det i granskningsarket. Nedräkningen och provpaketet bygger på det här.
- [ ] Hem: nedräkning till prov från godkända provplaner, synlig från en vecka före.
- [ ] "Inför provet": en knapp i provförslaget och på Hem som kopierar ämnets provtips och lektionsanteckningar sedan förra provet.
- [ ] Morgonnotis med dagens prov och läxor, avstängd tills hon slår på den (texten syns på låsskärmen). Kvällsnotis med antal förslag att granska, som öppnar Förslag.

## Fas 6: enkelhet för henne

- [ ] Inställningsarket: överst notiser, tider, AI-paus, lagring, säkerhetskopia och en rad "Allt fungerar" eller "Något är fel". Parning, kvot, release och diagnostik under ett ihopfällt Avancerat. Fortfarande ett enda ark (befintlig regel).
- [ ] Gå igenom alla feltexter i appen: en mening och en åtgärd, på vanlig svenska, utan HTTP-koder eller engelska. Knappen "Skicka felrapport" öppnar dela-arket med textfri diagnostik.
- [ ] Sidan "Kontrollera allt": mikrofon, notiser, Påminnelser, Tailscale, datorn, Pianissimo och AI, en grön eller röd rad var med en åtgärd.
- [ ] Signeringens slut: läs `ExpirationDate` ur `embedded.mobileprovision` i appen och visa antal dagar kvar i inställningarna. En lokal notis 24 timmar före med stegen: 1. Stäng av Tailscale. 2. Öppna SideStore och slå på LocalDevVPN. 3. Tryck Uppdatera vid Mio. 4. Stäng av LocalDevVPN och slå på Tailscale igen. **Ej verifierat** tills det är provat med en SideStore-installation.
- [ ] Säkerhetskopia varje natt under laddning (`BGProcessingTask`): den versionsmärkta JSON-exporten skickas via Tailscale till datorn, krypteras där och sparas i 14 kopior. Återställning i inställningarna. Aldrig till molnet. Mio Kontroll visar senaste kopian.

## Fas 7: ikonen

- [ ] Rita ikonen i Icon Composer: hela ordet "mio" i rundade gemener, o:et som en ring med en liten ljudvåg, i Mios blå ton (aldrig violett). Separata lager för bakgrund, ord och ljudvåg, så att iOS 27 ritar glas samt mörkt och tonat läge.
- [ ] Behåll PNG-filerna i `Mio/Assets.xcassets/AppIcon.appiconset` som reserv och byt ut dem mot samma motiv.
- [ ] Granska skärmbilderna från "Bygg Mio IPA" i ljust, mörkt och tonat läge.

## Sist: överlämning

- [ ] [CHANGELOG.md](../CHANGELOG.md) för det som syns för användaren, och [STATUS.md](STATUS.md) bara med kontroller som faktiskt körts.
- [ ] Be användaren köra "Bygg Mio IPA" och Prova i Mio Kontroll.
- [ ] Lägg till telefonprov i [helhetstestet](TESTPLAN_HELHET.md): en hel lektion med provtips och läxor, en skoldag med vardagsfångst och låg batterinivå (lektionen fortsätter), direkt anteckning med Ångra, signeringsnotisen och en återställning från säkerhetskopian.

## Öppna frågor

Användaren valde att inte gå igenom dem 2026-11-19. Ta upp dem när fasen som berörs börjar.

1. Ämne per lektion (se fas 5).
2. Språklektioner: Pianissimo är en svensk modell. Vad som händer på engelska, spanska och tyska är inte bestämt.
3. Vilken telefon hon har (iPhone 13 eller annan), och därmed batteri och värme under en hel skoldag.
4. Om användaren själv också ska använda Mio mot samma dator.
5. Mistrals träning på API-data och vad som händer efter de tre månaderna (Groq igen, betala för Mistral eller blanda). Varning vid 80 % av krediten är med i fas 2.
6. Om skolan tillåter att lektioner spelas in, och om Mio ska påminna om att fråga läraren.
7. Mikrofon i klassrummet (telefonen på bänken eller en extern mikrofon).
8. Mätning av Pianissimo i FP16 på RTX 4060 Ti innan hon börjar.
