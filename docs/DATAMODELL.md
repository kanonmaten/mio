# Datamodell för Mio

Helhetsbygge 0.9.0, nyinstallation enligt användarbeslut 2026-09-26. Appidentiteten är `app.mio.assistant`. Det finns ingen migrering från de borttagna prototyperna. Appversionen och JSON-scheman är separata värden.

## Lokala lager

Filerna ligger under appens Application Support. Från 2026-10-11 lagras sessioner, innehåll och assistentdata i SwiftData (`Mio/store/Mio.store`, se avsnittet nedan); tabellen beskriver JSON-formatet som migreras en gång, används som reserv när migreringen avbryts och fortfarande är exportformatet:

| Fil | Innehåll | Schema |
|---|---|---|
| `Mio/sessions.json` | Originaltranskript, ljudtider, diagnostik, batteriprover, titel/anteckning/rättningar | Sessionsarray med valfria visningsmetadata |
| `Mio/content-v1.json` | Tidslinjeposter, anteckningar, uppgifter, planer och uttryckliga minnen | `schemaVersion: 1`, `items` |
| `Mio/diagnostics-v1.json` | Begränsad textfri AI-anropsjournal | `schemaVersion: 1`, `events` |
| `Mio/assistant-v1.json` | Väntande frågor/förslag, lektioner och bearbetade källidentiteter | `schemaVersion: 1`, `suggestions`, `lessons`, `processedSources`, valfritt `analyses`, `analysisDecisions` |
| `Mio/metrickit-v1.json` | Apples textfria MetricKit-rapporter (krasch, häng, CPU, disk, minne), högst 40 st, 3 MB och 30 dagar | `schemaVersion: 1`, `reports` |
| `Mio/operations-v1.json` | Påbörjad radering: operations-ID, scope, valfritt mål-ID och avslutade fasta steg | `schemaVersion: 1`, `operations`; inga innehållstexter eller hemligheter |

Det finns **tre domänlager**, plus en begränsad diagnostikjournal och en liten raderingsjournal. Raderingsjournalen tas bort när alla dess steg är slutförda; den är ingen allmän databas eller meddelandekö.

Alla lager och interna exportkopior använder gemensam atomisk skrivning i ägda privata undermappar. På iOS sätts `completeUntilFirstUserAuthentication` under den atomiska filskapningen, före synliga bytes; mappar undantas från enhetsbackup. Privata mappar/filer har även POSIX-mode `0700`/`0600`; en gemensam system-/tempkatalog ändras aldrig till privat katalog. Skydds-/backupfel rapporteras som operationsfel, även om bytes redan hunnit ersättas. **Apple-filskydd och backupbeteende behöver native enhetsprov; Linux bevisar bara sina filsystemgränser.** Inget råljud lagras. Okända innehålls-, assistent-, diagnostik- eller operationsscheman får inte skrivas över.

Varje repository är actorägt och läser senaste validerade tillstånd för ändringar. Filstämpel med ändringstid, storlek och inode används för att upptäcka ersatta filer. Identiteter/relationer valideras; en stale helarray från UI får inte ersätta nya ändringar. Appens workflow håller skrivningar och sammanhängande export/radering åtskilda och returnerar uttryckligen success/failure/cancelled/conflict.

## Innehållspost

`MioContentItem` har UUID, typ (`timeline`, `note`, `task`, `plan`, `memory`), obligatorisk trimmad rubrik, text, skapandetid, uppdateringstid, användarvald `scheduledAt`, valfri `completedAt`, valfri sessionskoppling och valfritt `isAllDay` (2026-10-13; bara uppgifter och planer, `scheduledAt` är då dagens början och saknat fält betyder att tiden gäller). Endast uppgifter har klarstatus. Från 0.9.1 har en ny post alltid det valfria fältet `handoff` (`destination`: `calendar`, `reminders`, `notes` eller `otherApp`; valfritt `externalIdentifier`, som är påminnelsens `calendarItemIdentifier`; `sentAt`). Den är då bara ett kvitto på en överlämning till Apples app: tom text, `scheduledAt` = `sentAt`, inget heldagsfält och ingen klarstatus. Vid uppgraderingen raderas poster utan `handoff` en gång (markeringen `mio.upgrade.0.9.1.legacyItemsRemoved` i UserDefaults). Exporten behåller schema 2; `handoff` är ett additivt fält i `content`.

Ordning är fallande vald tid, skapandetid och slutligen UUID. Sökning normaliserar skiftläge, diakritik och teckenbredd med svensk lokal. Sessioner söks på titel, anteckning och visningstext.

## Original och visningslager

En avslutad session får titel, manuell anteckning och separata `correctedText`-fält. Originalets `text`, `createdAt`, `audioStartedAt`, `audioEndedAt`, Mio-detektion, bakgrundsmarkering och tidsgiltighet ändras inte. En aktiv session måste stoppas före redigering.

Ett enda sessionsregister innehåller aktiva, pausade och avslutade sessioner. Separata actor-kommandon uppdaterar capture-checkpoint, slutmarkering, titel/anteckning och rättning. Generationsbundna operations-token avvisar sena skrivningar efter radering; en avslutad session öppnas inte på nytt av ett sent checkpoint. Valfri `mutationRevision` markerar lagrad sessionsändring, och varje segment kan ha valfri `correctionRevision`. Registret håller också ett rent runtime-index (`sessionID -> arrayindex`) för snabb ersättning av pågående session; indexet exporteras aldrig. Äldre JSON utan fälten avkodas fortfarande.

En analyspost för lektionsanteckningar kan ha det valfria fältet `isUnprocessed: true` (2026-10-13). Den har då tomma `sections`, inga punkter, osäkerheter eller metadata, och betyder att AI:n gav ogiltiga svar för just de textdelarna flera gånger. Delarna räknas som hanterade och skickas aldrig igen automatiskt; lektionen visar originaltexten. Äldre poster utan fältet avkodas som förut.

Lektioner har UUID, sessionID, rubrik, anteckning, start/slut och skapande-/ändringstid. Intervall måste ligga inom avslutad session och får inte överlappa. Visningen väljer originalsegment som överlappar intervallet. Segment delas aldrig; ett gränsöverskridande segment kan därför visas i två lektioner.

## Förslag och frågor

`MioSuggestion` har stabilt UUID, purpose (`content` eller `question`), innehållstyp, rubrik/text, skapandetid/vald tid, valfri session-/segmentkoppling, pending/deferred och uppskjutningstid. Saknad purpose avkodas som content. Frågor använder ingen ny innehållstyp och sparas inte automatiskt som anteckningar.

Ja sparar en innehållspost med förslagets UUID och avför sedan frågan. Ett omförsök efter delvis misslyckad lagring skapar inte dubbletter eller skriver över senare ändringar. Nej tar bort förslagstexten; `processedSources` behåller endast UUID:n för deduplicering. Originaltranskriptet förblir synligt tills sessionen raderas. Inte nu behåller utkastet lokalt.

Ett AI-förslags text byggs i appen av källsegmentens visningstext i transkriptordning (högst 2 000 byte), aldrig av modellens `body` (2026-10-13). AI:ns `scheduledAt` kan vara en tidpunkt eller ett datum utan klockslag (`ÅÅÅÅ-MM-DD`); datumet tolkas som dagens början i begärans tidszon och ger förslagets valfria `isAllDay`. En senare ersättning bygger texten av beslutets alla källor.

Förslagets additiva valfria `revision` blir `reviewRevision` (saknat fält = 0). Godkännande kräver samma revision som användaren granskade. En senare AI-komplettering gör granskningen föråldrad; användarens redigerade utkast bevaras och måste granskas igen. Actorägd godkännandeclaim stänger analysbeslut före innehållssparning. Vid relevant utkaständring återställs datumkontrollen. Saknat AI-datum/klockslag kräver ett uttryckligt användarval; ett internt standarddatum är inte ett godkänt datum.

En AI-fråga stannar lokalt tills användaren går vidare till AI-vyn, väljer eventuell kontext och godkänner den exakta sändningen. Efter lyckat svar avförs inkorgsfrågan när användaren lämnar svaret. Vid fel eller avbryt finns frågan kvar.

Frågesvaret och `MioAnswerNoteDraft` finns endast tillfälligt i RAM. Draftets UUID/generation hör till det aktuella svaret. **Granska och spara som anteckning** öppnar ett redigerbart utkast; ett explicit lokalt Spara skapar en `.note` med samma UUID via `saveApprovedIfAbsent`. Om samma ID redan finns bevaras den lagrade posten och senare redigeringar. Detta anropar ingen extra AI, bygger ingen frågehistorik och skapar inga systemåtgärder. Konfigurationsändring/radering ogiltigförklarar osparat svar och draft. Redan uttryckligen sparad anteckning följer vanlig lokal lagring/radering.

## Systemdata och konfiguration

iOS är källa för lokala notiser: dagliga notiser har fasta Mio-ID:n (`mio.daily.*`). Från 0.9.1 skapar Mio inga alarm eller postnotiser; uppgraderingen avbryter alla Mio-alarm och notiser `mio.reminder.<UUID>` en gång. Påminnelser och kalenderhändelser ägs av Apples appar; Mio läser kommande ofullbordade påminnelser för Hem utan att spara dem och läser aldrig kalendern. En lista med enbart kända alarm-UUID:n finns i egna UserDefaults så att nekad behörighet inte döljer ett kvarvarande alarm vid radering. Kalenderkopior finns i den kalender användaren väljer och är fristående.

Notisens `userInfo` innehåller endast `mioRoute` (`post`, `morning`, `evening`, `resumeListening`) och, för post, ett opakt `mioPostID`-UUID. Låsskärmtexten är generell. Extra nycklar/ogiltiga rutter avvisas. En pending rutt hålls till lokala lager har lästs; `morning`/`evening` öppnar Hem, `resumeListening` öppnar Fånga och borttagen post ger säker fallback till Hem. Rutt, flikval och vald översiktsdag är tillfälligt presentationstillstånd och startar aldrig mikrofon eller AI.

Hems veckonummer, veckorad, tolvveckorsrutnät, Nästa och dagens fas räknas fram ur sparade poster och sessionernas starttider i en härledd runtime-snapshot per datarevision. Aktiviteten är bara antal per dag; ingen text läses och inget nytt lagras.

AI-valet (`mio.ai.enabled`, saknas = på; ersätter `mio.cloud.enabled` som tas bort vid uppgradering) och gatewayens HTTPS-adress (`mio.cloud.server`) finns i egna UserDefaults, liksom `mio.consent.recordingNoticeShown` och engångsmarkeringen `mio.cloud.legacyAccessRemoved.v1`. Gatewaytoken lagras i Keychain under `app.mio.assistant.cloud-gateway` som `{"token":…}` utan Access-par (2026-10-11; äldre Access-uppgifter skrivs om eller raderas en gång), endast tillgänglig på upplåst aktuell enhet. Båda adresserna och tokens kommer från samma parning; ingen QR-kod eller bild sparas. Leverantörens API-nyckel finns enbart på servern. Frågeutkast/svar i AI-vyn är tillfälliga och sparas inte som historik. Uppskjutna inkorgsfrågor finns i assistentlagret.

## Export och radering

Gemensam export heter `Mio-lokal-export-ÅÅÅÅ-MM-DD-HHmm-UUID.json` och skrivs under appens ägda temporära `Mio-exports/`. Även enskilda sessionsexporter har unika filnamn. Varje fil skapas skyddad; samma minuts export ersätter inte en äldre fil. Workflowen spärrar nya skrivningar, flushar senaste capture-checkpoint och läser de senaste actorägda lagren för samma lokala snapshot:

```json
{
  "schemaVersion": 2,
  "exportedAt": "ISO-8601-tidpunkt",
  "content": [],
  "sessions": [],
  "assistant": {
    "schemaVersion": 1,
    "suggestions": [],
    "lessons": [],
    "processedSources": [],
    "analyses": []
  }
}
```

Exporten har additiva valfria fält `diagnostics` och `diagnostics.metricReports` (MetricKit-rapporterna); äldre export utan fältet kan fortfarande avkodas. Exporten har inga ljuddata, token, API-nycklar eller systemkalenderkopior. Avkodning stöder även export utan assistantfält, men appen erbjuder ingen importknapp. Filernas egna schemaVersion är fortfarande 1.

Sessionens enskilda radering tar bort dess lektioner/förslag/analysbeslut och lossar manuella poster. Radering av en post avbryter dess Mio-alarm/notis. Fullständig radering avbryter alla egna alarm/notiser, glömmer båda serveranslutningarna och avstänger AI, raderar de tre domänlagren, diagnostiken och interna exportkopior. Kända gamla interna exportnamn städas också; delade systemkataloger raderas inte.

Raderingsavsikten lagras först i `operations-v1.json`. Fasta steg avslutas i rätt ordning och journalen skrivs efter varje lyckat steg. Avbruten/partiell radering återupptas idempotent från journalen; ett fel kan därför betyda att vissa steg redan är gjorda. Återhämtningen försöks vid bootstrap före vanligt arbete. Kvarstående fel spärrar nya ändringar/sändningar och visar **Försök slutföra raderingen igen**. Okänd eller skadad journal skrivs inte över. ID-journalen exporteras inte som innehåll och tas bort först efter fullgjorda steg. Generationsspärrar/tombstones avvisar sena callbacks även om städningen misslyckas. Inga behörigheter, modellfrågor eller mikrofonstarter återförsöks automatiskt av återhämtningen.

Redan delade exporter, skickade molnfrågor och kalenderkopior ligger utanför appens lokala radering. De behöver hanteras där de sparats.

## Lektionsläge och strukturerad AI-analys

Sessioner har valfritt `captureMode` (`everyday`/`lesson`); saknat fält betyder tidigare vardagssession. Nya lektioner har en egen session och ett avslutat lektionsintervall. Flera oavslutade sessioner efter ett avbrott återställs som avslutade vid nästa appstart, utan automatisk mikrofonstart.

`MioAnalysisRecord` lagrar sessionID, analyserade fragment-ID:n, huvudpunkter med käll-ID/exakt citat, osäkerheter och skapandetid. Fullt transkript dupliceras inte. Fragment-ID består av segmentets UUID och delindex; text delas vid behov utan att originalsegmentet ändras. Alla käll-ID:n/citat valideras före lagring. Även tomma resultat registreras så att samma utdrag inte skickas igen. Deduplicering av förslag jämför typ, rubrik, tid och session; den är inte en allmän semantisk dubblettkontroll.

AI-förslag har valfria `evidence` och `needsDateConfirmation`. Äldre filer saknar dessa fält och kan fortfarande avkodas. Scheman är additivt bakåtkompatibla; version 1 behålls. Ett Nej tar bort förslagets text/citat men lämnar källidentiteter; lektionspunkter och originaltext raderas med sessionen. Export inkluderar analysutkast. Aktiveringssamtycke, kö och tillfällig token lagras inte i analysfilen och exporteras inte.

## Detaljerade lektionsdelar, 2026-09-28

`MioAnalysisRecord` har additiva valfria `sections` och `metadata`. En section har `heading`, `body`, `sourceIDs`, `evidence`. Metadata har `provider`, `model`, `promptVersion`, `lessonIntervalSeconds`. Inga hemligheter lagras här. Schema 1 behålls; äldre filer utan fälten avkodas och bevaras. Gamla highlights visas separat och räknas inte som detaljerade delar.

En färdig detaljerad del registreras även när dess sectionlista är tom. Framsteg och återstående arbete härleds från sessionens fragment-ID:n och sparade detaljerade poster, så inget nytt beständigt samtycke eller köformat behövs. Spara före nästa anrop. Sammanställningen sorteras efter källfragmentens ordning; kopierad text innehåller rubrik, datum, anteckningar, osäkerheter och en markering om bearbetningen är ofullständig, aldrig interna käll-ID:n. Originaltexten ändras inte. Radering tar bort hela analysen och dess metadata som tidigare.

Lektioner vars detaljerade anteckningar har begärts men inte är klara listas med enbart UUID i UserDefaults (`mio.workflow.lessonNotesInProgress`). Listan återupptas när AI är på (även efter omstart), rensas från klara eller raderade lektioner och töms vid fullständig radering. Live Activityns tillstånd (fas, sessionsstart, paustid, antal ljudluckor, sessions-UUID, lektion ja/nej) finns bara hos ActivityKit och innehåller aldrig text.

Detaljerade delar analyserar den visningstext som fanns vid sändningen. Senare manuella rättningar ger ingen automatisk omanalys av redan bearbetade fragment. Källcitatet bevaras som bevis för vilket underlag som användes.

Nya `MioLesson` och detaljerade `MioAnalysisRecord` kan ha valfria `sourceRevisions`: segment-ID och den `correctionRevision` som hörde till underlaget. Revisionsmetadata stannar lokalt och ändrar inte serverns källtextkontrakt. Original utan rättning har källrevision 0; en äldre rättning utan revisionsbevis är okänd. Källjämförelse visar **aktuell**, **äldre** eller **okänd**. Äldre poster utan metadata anges aldrig som verifierat aktuella. Sparade delar, användarredigeringar, citat och ordning bevaras även om en rättning ändrar antal textfragment. Kopiering märker ofullständigt arbete, ljudluckor och äldre/okänt källunderlag. Rättning ger ingen automatisk omanalys eller ny molnsändning.

## Molnanslutning med Access, 2026-09-29 (ersatt 2026-10-11)

Keychain-posten `app.mio.assistant.cloud-gateway` / `gateway-token` innehåller efter nästa sparning ett JSON-objekt med gatewaytoken och valfritt Access-par. Äldre post med enbart tokensträng kan läsas. Alla hemligheter uppdateras i en Keychain-skrivning med `AfterFirstUnlockThisDeviceOnly` (från 2026-10-12; äldre `WhenUnlocked`-poster flyttas en gång vid start), ingår aldrig i export och raderas tillsammans vid glömd anslutning/fullständig radering. Ändrad server kräver att hemligheter anges igen. Anslutningens jämförelse inkluderar Access-paret vid förhandsgranskning. Sparning/radering skickar samma återställningsnotis som tidigare och stoppar pågående analys. Inga innehållsscheman ändras.

## Privat transkription, 2026-09-30

`TranscriptSegment` har valfria `transcriptionMetadata` (modell/revision/motor) och `sourceChunkID` för proveniens och deduplicering. `MioSession.captureGaps` är en valfri lista med UUID, start/slut och orsak. Äldre JSON utan dessa fält avkodas; originals text/tider och äldre motorfält ändras inte. Sessions- och exportscheman byter inte version för dessa additiva fält. Ofullständigt ljudunderlag märks både i lektionsvy och kopierad anteckning.

Transkriptionsadress ligger i `mio.transcription.server` (UserDefaults); separat token i Keychain (`app.mio.assistant.transcription`, `access-token`, AfterFirstUnlockThisDeviceOnly från 2026-10-12). Aktiv session håller sin fasta adress/token i RAM för användarstartad fångst med låst skärm. Detta kräver ändå telefonprov. Ny adress kräver ny token. Inställningsbyte är spärrat under fångst och återkallar gammal klient. Token, ljudbuffertar och WAV-delar ingår aldrig i lagring eller export. Högst 60 s från äldsta samples ursprungliga tid behålls i RAM, även under retry/stopp. Paus/stopp släcker mikrofonen först; redan fångad slutdel kan dräneras högst 15 s och inom den ursprungliga 60-sekundsgränsen. Därefter rensas egna ljudreferenser; bortfall markeras som lucka. Radering rensar/avbryter väntande arbete. Servern har en kort textcache för identiska retries, se [API](../transcription-server/API.md).

Talare (2026-10-11): `TranscriptSegment.speaker` är ett valfritt heltal 1–4 från PC:n och hör till originalunderlaget; en del med flera talare sparas som ett segment per talarbyte med samma `sourceChunkID`. `MioSession.speakerNames` är en valfri ordlista talarnummer → namn (högst 40 tecken), ett visningslager som bara ändras i avslutade sessioner och aldrig skriver om segmenten. Båda fälten är additiva; äldre data avkodas som utan talare. Ljudet styckas nu vid pauser (8–22 s ägt ljud, högst 24 s per begäran); som mest cirka 23 s väntar mellan snitten, inom samma 60-sekundersgräns.

Löpande vardags-AI får bara segment vars **ljudstart** ligger efter aktiveringen. Ett fördröjt transkript från tidigare ljud räknas inte som nytt godkänt underlag. En ljuddel som korsar samtyckesgränsen kan därför hoppas över konservativt.

## AI-kontext och diagnostik, 2026-09-30

Vardagsanalys använder `/v2/analyze`: `fragments` är enbart nya källor, `contextFragments` innehåller högst 60 sekunder/4000 byte tidigare godkänd text inom samma lyssningskontinuitet. Alla fragment behåller identitet och text; äldre kontext kan uteslutas helt med `contextLimited`. Kontexten trimmas inkrementellt i appen med löpande byte-/antalbudget före slutlig wire-validering, men kontraktsgränserna är oförändrade. Totalt högst åtta fragment/10000 byte/20000 byte JSON. Nya batcher reserverar kontextutrymme med högst fem fragment/6000 byte. När mer än en sådan batch väntar och gatewayn anger kapabiliteten `analysis-backlog-v1` (2026-10-13) får en batch tolv nya fragment/12000 byte, och anropet högst sexton fragment/16000 byte/40000 byte JSON. Kontext går aldrig före aktiveringen eller över en ljudlucka/paus/lektionsgräns. Lektionens kontrakt ändras inte.

`analysisDecisions` i assistentlagret är additivt valfritt. Varje beslut har förslags-ID, sessionID, typ, källfragment-ID:n och `isClosed`. `priorDecisions` skickar bara beslut kopplade till vald kontext, med `isOpen`, aldrig tidigare förslagstext. En v2-kandidat har nullable `replacesID` och minst en ny källa. En komplettering uppdaterar samma öppna förslags-ID och behåller skapandetid/uppskjutning. Ja/Nej stänger beslutet och tar bort förslagstext; ett sent svar kontrolleras mot senaste lagrade beslut. V2 slår bara ihop förslag via `replacesID`; även identiska nya fristående kandidater behåller egna beslut/källor. Bearbetningsposter registrerar bara nya fragment. Sessionsradering tar även bort dess beslut.

`diagnostics` i schema 2-exporten innehåller appversion/build, OS, maskinidentifierare, tidszon, fyra konfigurationsbooleans och journalens lagringsstatus/händelser. Den sparar högst 200 händelser i sju dagar oberoende av sessioner. Varje händelse innehåller fast operation/rutt, tid/duration, byteantal, HTTP-status, tillåten gatewayfelkod, Retry-After, tillåten nätfel-domän/-kod och säkra release-/provider-/modell-/prompt-/request-ID-/CF-Ray-fält. Analys kan ha fragmentantal, källtidsintervall, köstorlek och kontextbegränsning. Inga frågor, transkript, svar, felkroppar, fullständiga URL:er, headerdumpningar, hemligheter eller råljud lagras. Okänt journalschema skrivs inte över; lagringsfel märks i exporten. Raderingsgeneration och starttidsgräns avvisar sena händelser efter total radering.

Diagnostik kan additivt innehålla bounded/sanerad konfigurationsrevision, faktiskt returnerad modell, upstream request-ID och rapporterade input-/output-/reasoning-tokenantal. Okända leverantörsnamn får visas endast som säkra protokollidentifierare; de ger inte automatiskt modellstöd. Otillåtna URL-/nyckelliknande eller för stora metadata tas bort. Saknad usage bevisar inte frånvaro av intern reasoning.

Modellfri skyddad `/v2/status` ger aktuell release, offentlig konfigurationsrevision, tre uppgifter (`ask`, `everyday`, `lesson`) och delad kvot. Uppgiftens kompatibilitet och konfigurationsfel visas separat. Revisionen härleds utan publicerade hemligheter eller secret-fingerprints. En kort lyckad discoverycache är anslutnings- och revisionsbunden och ogiltigförklaras vid inställnings-/auth-/409-fel. Fryst revision följer godkänd fråga och aktiverad analys; serverns ändrade konfiguration kräver ny granskning/manuell aktivering, aldrig automatiskt nytt POST. Cache, samtycke och kö sparas inte som innehåll.

## SwiftData-lager och diagnostik, 2026-10-11

Sessioner, innehåll och assistentdata ligger i en SwiftData-databas, `Mio/store/Mio.store`, med ett versionerat schema (`MioSchemaV1`, version 1.0.0) och en `SchemaMigrationPlan` utan steg ännu. Ingen CloudKit. Mappen `store/` har samma skydd som övriga lager (`completeUntilFirstUserAuthentication`, ingen backup, `0700`).

- Varje rad har identitetskolumner (sessions-, segment-, post-, förslags- eller lektions-ID, ordningstal) och en `payload` med samma Codable-JSON som i filerna. Nya valfria fält i värdetyperna, t.ex. `speaker` och `speakerNames`, följer därför med utan schemaändring.
- Tabeller: sessionshuvud (sessionen utan text och luckor), transkriptsegment, ljudluckor, innehållsposter, förslag, lektioner, analyser (detaljerade lektionsdelar markeras), analysbeslut och bearbetade källor.
- Skrivningar är radvisa: repositoryt jämför med senast sparade tillstånd och ändrar bara berörda rader. Live-fångst lägger bara till nya segmentrader. Varje ändring sparas i en `ModelContext.transaction`; fel rullar tillbaka och nästa läsning hämtar om allt.
- Repositoryn är `@ModelActor`-actorer bakom samma anropsformer som JSON-actorerna. Över actorgränser skickas bara värdetyper, aldrig `@Model`-objekt. Linux-testerna använder JSON-actorerna.

**Engångsmigrering vid start.** `content-v1.json`, `sessions.json` och `assistant-v1.json` läses med dagens avkodare. Är något schema okänt eller en fil oläslig migreras ingenting, inget raderas, appen kör vidare på JSON-filerna och visar ett svenskt meddelande. Annars skrivs allt i en enda transaktion, antal sessioner, segment, luckor, poster, förslag, lektioner, analyser, beslut och källor jämförs, och först därefter skrivs markören `Mio/swiftdata-migration-v1.json` (`verified`). JSON-filerna flyttas sedan till `Mio/backup-pre-swiftdata/` (markören blir `backedUp`); en befintlig backup skrivs aldrig över. Mappen raderas vid nästa lyckade start, och direkt vid radering i appen. Avbrott före markören ger en ny, idempotent migrering; avbrott efter den slutför bara flytten. Okänd markör stoppar allt.

`diagnostics-v1.json` ligger kvar som fil. Raderingsjournalen `operations-v1.json` och generationsspärrarna behålls: de skyddar mot sena fångst-callbacks efter radering och täcker steg utanför databasen (alarm, notiser, nycklar). Exporten är oförändrad JSON.

**MetricKit och loggning.** En `MXMetricManagerSubscriber` sparar Apples textfria JSON-rapporter i `Mio/metrickit-v1.json` (högst 40, 3 MB, 30 dagar; okänt schema skrivs inte över). Sidan Inställningar → Om → Diagnostik visar datum, typ och en sifferbaserad sammanfattning med dela/kopiera; rapporterna ingår i exporten och raderas med diagnostiken. `os.Logger` (subsystem `app.mio.assistant`, kategorierna `capture`, `transcription`, `ai`, `storage`) loggar bara fasta meddelanden och heltal, aldrig användartext.

## Kontrakt efter grillningen

Skrivna 2026-11-20 i fas 0 av [planen](arkiv/PLAN_GRILLNING.md), efter [besluten](DECISIONS.md#grillningen-2026-11-19). Gatewayen, Pianissimo, Mio Kontroll och appen byggs mot dem samtidigt. Ett spår som behöver ändra ett kontrakt säger till i stället för att ändra det själv. Alla tillägg är additiva: en äldre app, panel eller server ska fortsätta fungera mot en nyare motpart, och den nyare ska känna igen den äldre på att fältet eller förmågan saknas.

### Direkta anteckningar och fångstregler (våg 2, 2026-11-20)

- `MioSuggestion.direct` och `MioContentItem.direct` är valfria och additiva (ursprung och tidpunkt för en direkt instruktion; äldre data avkodas utan fälten). Ångra finns i 24 timmar från den tidpunkten. SwiftData-schemat är oförändrat, eftersom fälten ligger i radernas JSON.
- `mio.direct.tally.v1` i UserDefaults räknar sparade, väntande, ångrade och Nej för direkta instruktioner, bara heltal. Nollställs vid fullständig radering.
- Notisrutten `stillListening` (tystnadsfrågan) läggs till bland de tillåtna `mioRoute`; den öppnar Fånga och startar aldrig mikrofonen.
- En avslutad vardagssession raderas när den slutade för mer än 30 dagar sedan, vid start och när appen går till bakgrunden. Lektionssessioner, sessioner som delats in i lektioner, anteckningar och godkända poster sparas.

### Lektioner och egna ord i appen (våg 3, 2026-11-21)

- `MioSession.subject` (valfritt, 1–40 tecken, bara på en avslutad lektionssession; tomt tar bort det), `MioAnalysisRecord.examHints` och `subjectSuggestion` ligger i radernas JSON. `MioAnalysisFragment.speakerRole` skickas bara till `/v2/lesson-notes`. SwiftData-schemat är oförändrat.
- Notisrutten `lessonReview` med `userInfo` `{"mioRoute":"lessonReview","mioSessionID":"<UUID>"}` (extra nycklar avvisas), notis-ID `app.mio.lesson.notes-ready.<UUID>` och generell text. Öppnar Lektioner och granskningsarket, eller Hem om lektionen är borta.
- `mio.lesson.notesLatency.v1` (sessions-ID, sekunder och tid, högst 30) och `mio.vocabulary.asked.v1` (64-bitars FNV-1a-hashar av normaliserade fraser, aldrig orden) i UserDefaults. Båda nollställs vid fullständig radering.
- `mio.lesson.notesReadyAnnounced.v1`: UUID:n för lektioner som redan fått granskningsarket eller notisen, högst 200 (äldsta först ut), nollställs vid fullständig radering. Citat i `examHints`, `sections`, `candidates` och huvudpunkter får vara upp till 2 400 byte i appen, samma som gatewayen. Kastas provtips får delen en textfri osäkerhet om hur många som inte visas.

### Prov, notiser, signering och säkerhetskopia i appen (våg 4, 2026-11-21)

- `MioContentItem.exam` är valfritt och additivt: `{date, isAllDay, subject?}`, och sätts bara när en godkänd plan eller påminnelse ser ut som ett prov och har ett datum. SwiftData-schemat är oförändrat.
- UserDefaults: `mio.daily.morning.detail` (Bool, saknas = av), `mio.daily.morning.minutes` och `mio.daily.evening.minutes` (sparad tid), `mio.backup.lastAttempt.v1` (`{at, failure}`, utan innehåll, nollställs vid fullständig radering).
- Notis-ID: `mio.daily.<kind>.ÅÅÅÅMMDD` (en per dag, 14 dagar framåt; den upprepade `mio.daily.morning` står kvar när detaljreglaget är av) och `app.mio.signing.renew` (utan `userInfo`). Rutten `evening` öppnar nu Förslag, med den generella texten "Granska dagens förslag i Mio."
- `BGTaskSchedulerPermittedIdentifiers` har `app.mio.assistant.backup`, och `UIBackgroundModes` har `processing`.
- En vald kopia att återställa ligger som `Mio/restore-pending.json`, med `Mio/restore-pending-meta.json` bredvid (`{schemaVersion: 1, stagedAt, deletionGeneration, failedAttempts}`, utan innehåll), till nästa start, högst 24 timmar. Varje radering (allt, en session eller en post) tar bort den direkt, och total radering görs inte om filen inte går att ta bort. `mio.restore.deletionGeneration.v1` räknar påbörjade raderingar och nollställs aldrig; en kopia som valts före en radering vägras vid start. En kopia som inte går att kontrollera tas bort med ett besked, och skrivningen försöks högst två gånger. Medan en återställning väntar startar ingen fångst eller lektion.
- `mio.backup.lastAttempt.v1` har det valfria fältet `retry`. Efter nätverksfel eller timeout görs högst tre nya försök samma natt (15 min, 45 min, 2 h); efter andra fel väntar kopian cirka 20 timmar. Ett låst Keychain ger utfallet `keychain_locked` och stänger aldrig av AI. Total radering, glömd och bytt parning avbryter den schemalagda begäran. Total radering tar bort alla `mio.daily.*`-nycklar.

### `/v2/status`: resonemang, schema och användning

Varje post under `tasks` får två fält:

- `reasoning`: `"off"` eller den granskade nivån (`"low"`, `"medium"`, `"high"`). Bara `lesson` kan ha något annat än `"off"`; gatewayen vägrar starta (`provider_options_incompatible`) om ett resonerande par står för `ask` eller `everyday`.
- `schemaDialect`: modellprofilens `schema_dialect`, `"strict-json-schema"` eller `"json-schema"` (schemat ligger i prompten och följs inte garanterat; gatewayen validerar svaret). `null` när uppgiften saknar giltig konfiguration.

På toppnivån kommer `usage` (alltid med, även när inget anrop gjorts):

```json
"usage": {
  "month": "2026-11",
  "currency": "USD",
  "estimatedCost": 3.42,
  "entries": [
    { "task": "lesson", "provider": "mistral", "model": "mistral-large-…",
      "requests": 12, "inputTokens": 40000, "cachedInputTokens": 0, "outputTokens": 21000, "reasoningTokens": 9000,
      "estimatedCost": 0.0721, "pricesAsOf": "2026-11-20" }
  ]
}
```

- `month` är innevarande kalendermånad i UTC. Räknarna börjar om vid månadsskiftet. En post per kombination av uppgift, leverantör och modell som har använts under månaden, sorterad på uppgift (`ask`, `everyday`, `lesson`) och sedan leverantör och modell.
- Token är leverantörens egna siffror ur svarets `usage`. `outputTokens` är allt som debiteras som utdata, resonemang inräknat; om en leverantör redovisar resonemanget utanför sin utdatasiffra lägger adaptern ihop dem. `reasoningTokens` är den del av `outputTokens` som var resonemang (0 om leverantören inte redovisar det). `cachedInputTokens` är den del av `inputTokens` som debiterades som cachad.
- Både lyckade och ogiltiga svar räknas, eftersom leverantören debiterar dem. Ett anrop utan `usage` i svaret räknas i `requests` men inte i token.
- `estimatedCost` = (in − cachad in) × inpris + cachad in × cachat pris + ut × utpris, med priser per miljon token ur en granskad pristabell bredvid modellen i `server/src/model_profiles.rs` (datum och källa per pris). En modell utan pris i tabellen (till exempel Groqs gratisnivå) får `estimatedCost: null` och `pricesAsOf: null`, och toppnivåns `estimatedCost` räknar bara posterna med pris. Kostnaden avrundas till fyra decimaler.
- Räknarna sparas i `/var/lib/mio-gateway/usage.json` (0600, `{"schemaVersion":1,"months":{"2026-11":[…]}}`, bara siffror och identifierare, innevarande och förra månaden). En okänd `schemaVersion` skrivs aldrig över; då svarar `/v2/status` med `usage: null` och journalen får en rad. Ingen text, ingen tanketext och inga nycklar.

Mio Kontroll läser `usage` för kreditmätaren och visar `reasoning` per uppgift. Kreditgränsen (standard $20) är panelens egen inställning och skickas inte till gatewayen.

### Lektionsanteckningar version 2: provtips, talarroller och ämne

Gatewayen får rutten `POST /v2/lesson-notes` och lägger förmågan `lesson-notes-v2` i `tasks.lesson.capabilities` (bredvid `lesson-notes-v1`). `POST /v1/lesson-notes` är oförändrad, och paritetstesterna mot Node gäller den. Appen använder v2 när förmågan finns och annars v1.

**Begäran** är som v1 (`mode: "lesson"`, `timeZone`, `fragments`, högst 3 500 byte källtext) med ett valfritt fält per fragment:

- `speakerRole`: `"teacher"` eller `"student"`. Saknas när talaren är okänd. Appen räknar fram rollen per lektion ur originalsegmentens `speaker`: den talare som har flest tecken i lektionen är `teacher`, övriga `student`. Rollen följer inte namnen hon själv ger talarna. Inga talarnamn skickas.

**Svaret** följer JSON-schemat `mio_lesson_notes_v2`:

```json
{
  "examHints": [ { "text": "…", "sourceIDs": ["<uuid>:0"], "evidence": "exakt citat" } ],
  "subject": "Biologi",
  "candidates": [],
  "sections": [],
  "uncertainties": []
}
```

- `examHints`: 0–8 per svar. `text` 1–300 tecken. `sourceIDs` 1–4 ID:n ur begärans fragment. `evidence` är ett exakt citat ur en av källorna och lagas eller kastas på samma sätt som för `sections`. En ogiltig punkt kastas; resten av svaret står kvar. Prompten ber bara om sådant läraren uttryckligen pekar ut ("det här kommer på provet", "kom ihåg", "viktigt" och liknande) och hellre för få än gissningar.
- `subject`: ämnet som modellen föreslår (1–40 tecken, till exempel "Biologi") eller `null` när det inte går att säga. Bara ett förslag: appen visar det i granskningsarket och sparar det först när hon bekräftar eller ändrar det (antagandet i fas 5).
- `candidates`, `sections` och `uncertainties` som i v1. Svarets metadata (`provider`, `model`, `promptVersion`, `lessonIntervalSeconds`) och rubriker som i v1, med en egen promptversion för v2.

**Tidsgräns (tillägg efter våg 2):** när `lesson` står på ett par som resonerar (`reasoning` är inte `"off"`) får hela anropet till `/v1/lesson-notes` och `/v2/lesson-notes` ta högst 180 s i gatewayen i stället för 40 s, eftersom tänkandet får upp till 12 000 token. Övriga anrop behåller 40 s. Appens tidsgräns för lektionsanteckningar är 200 s, så att gatewayens fel (`provider_timeout` med mera) hinner fram före appens egen. Förmågan `reasoning-off` i `tasks.lesson.capabilities` finns kvar för äldre appar; appen kräver den inte längre för `lesson` och läser `reasoning` i stället. Ej verifierat: hur lång tid Large 4 tar och om iOS låter anropet gå klart i bakgrunden.

**I appen** får `MioAnalysisRecord` de additiva valfria fälten `examHints` (samma form som ovan) och `subjectSuggestion`; lektionen får det valfria `subject` (det hon bekräftat). Äldre data avkodas utan fälten. En lektion med flera delar visar alla delars provtips i källordning, utan exakta dubbletter, först i anteckningen och i kopieringen ("Viktigt till provet").

### Egna ord från telefonen

Pianissimo får rutten `POST /v1/vocabulary`, med samma Bearer-token som transkriptionen (från parningen).

- Kropp: `{"phrase": "Åsa Lindqvist"}`, JSON, högst 1 024 byte. `phrase` trimmas och måste sedan vara 1–100 byte UTF-8 utan radbrytningar eller andra kontrolltecken och får inte börja med `#`. Okända fält avvisas.
- Ordet läggs sist i `/var/lib/mio-transcription/vocabulary-phone.txt` (tjänstens egen katalog, 0600), om det inte redan finns där eller i `/etc/mio-transcription-vocabulary.txt` (exakt jämförelse). Pianissimo läser båda filerna, `/etc`-filen först, och använder högst 500 rader sammanlagt. Listan laddas om före nästa transkription utan omstart.
- Svar 200 `{"added": true, "vocabulary": 37}` (`added: false` om ordet redan fanns; `vocabulary` som i `/health`). 400 `invalid_phrase`, 401 vid fel token, 409 `vocabulary_full` när 500 rader redan används, 413 för stor kropp.
- Utöver svaren ovan: 507 `vocabulary_storage_failed` när filen inte går att skriva, 415 `json_required` och 408 `body_timeout`. Omladdningen har en egen gräns på 15 s; blir den inte klar svarar `/v1/transcribe` 503 `vocabulary_reloading` med `Retry-After`, som appen redan försöker igen efter, och förra ordlistan gäller.
- `/health` får det additiva fältet `vocabularyUpload: true`. Appen frågar bara om ett eget ord när fältet finns.
- Ordet skrivs aldrig i loggen och skickas aldrig vidare, varken till gatewayen eller till en AI-leverantör. Ett fel när ordet sparas eller laddas får aldrig stoppa transkriptionen: en rad i journalen och ordlistan som den var.
- Appen skickar bara ord hon har sagt Ja till, ett anrop per ord, och försöker inte igen i en slinga: vid fel visas en mening och ordet kan skickas igen från rättningen.

### Säkerhetskopian

Gatewayen tar emot kopian, eftersom appen redan når den med en egen token via Tailscale.

- `PUT /v2/backup` med `Authorization: Bearer <gatewaytoken>` och `Content-Type: application/json`. Kroppen är appens versionsmärkta export (`schemaVersion: 2`, se [Export och radering](#export-och-radering)), högst 32 MB, med 120 s deadline. Rutten har egna gränser och räknas inte mot AI-kvoten eller tokenbudgeten, och kroppen skickas aldrig till en leverantör. Gatewayen kontrollerar bara att kroppen är ett JSON-objekt med `schemaVersion` 2 och `exportedAt`; innehållet tolkas inte.
- Gatewayen krypterar kopian med XChaCha20-Poly1305 under en nyckel i `/var/lib/mio-gateway/backup.key` (32 slumpade byte, 0600, skapas vid första kopian) och skriver den till `/var/lib/mio-gateway/backups/<id>.mio-backup`, där `id` är `ÅÅÅÅMMDDTHHMMSSZ-<8 hex>`. Skrivningen sker till en temporär fil som döps om när den är klar. Bara de 14 senaste sparas; äldre raderas efter en lyckad skrivning. Nyckeln ligger på samma krypterade disk som kopiorna: krypteringen skyddar kopior som flyttas eller säkerhetskopieras vidare från katalogen, inte mot den som redan är root på datorn. Aldrig till molnet.
- Svar 201 `{"id": "…", "createdAt": "ISO-8601", "bytes": 123456, "kept": 14}`. 400 `invalid_backup`, 401, 413 för stor kropp, 507 `backup_storage_failed` om disken inte går att skriva.
- `GET /v2/backups` → `{"backups": [{"id": "…", "createdAt": "…", "bytes": 123456}]}`, nyaste först. `GET /v2/backups/<id>` → den dekrypterade exporten som `application/json`; 404 `backup_not_found`. Högst en hämtning åt gången hålls i minnet; en till köar upp till 120 s och får sedan 429 `backup_busy` med `Retry-After`. Utöver det: 500 `backup_unreadable` (fel nyckel eller trasig fil), 408 `request_timeout`, 415 `json_required`. En ny kopia raderas aldrig av sin egen rensning.
- `/v2/status` får `backup: {"latestAt": "ISO-8601" | null, "count": 0–14, "bytes": summa}`. Fältet saknas hos en gateway utan säkerhetskopia; appen visar och schemalägger kopian bara när det finns. Mio Kontroll visar senaste kopian ur samma fält, via den hjälpare som redan hämtar `/v2/status`.
- I appen: en `BGProcessingTask` som kräver ström och nätverk skickar exporten en gång per natt. Tid och resultat för senaste försöket sparas lokalt utan innehåll. Återställningen i inställningarna hämtar en vald kopia och ersätter appens lokala data först efter en bekräftelse, bara om exportens schema är känt, och aldrig medan fångst pågår.
