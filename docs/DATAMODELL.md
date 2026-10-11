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

`MioContentItem` har UUID, typ (`timeline`, `note`, `task`, `plan`, `memory`), obligatorisk trimmad rubrik, text, skapandetid, uppdateringstid, användarvald `scheduledAt`, valfri `completedAt` och valfri sessionskoppling. Endast uppgifter har klarstatus. En lokal plan är inte automatiskt en systemkalenderpost.

Ordning är fallande vald tid, skapandetid och slutligen UUID. Sökning normaliserar skiftläge, diakritik och teckenbredd med svensk lokal. Sessioner söks på titel, anteckning och visningstext.

## Original och visningslager

En avslutad session får titel, manuell anteckning och separata `correctedText`-fält. Originalets `text`, `createdAt`, `audioStartedAt`, `audioEndedAt`, Mio-detektion, bakgrundsmarkering och tidsgiltighet ändras inte. En aktiv session måste stoppas före redigering.

Ett enda sessionsregister innehåller aktiva, pausade och avslutade sessioner. Separata actor-kommandon uppdaterar capture-checkpoint, slutmarkering, titel/anteckning och rättning. Generationsbundna operations-token avvisar sena skrivningar efter radering; en avslutad session öppnas inte på nytt av ett sent checkpoint. Valfri `mutationRevision` markerar lagrad sessionsändring, och varje segment kan ha valfri `correctionRevision`. Äldre JSON utan fälten avkodas fortfarande.

Lektioner har UUID, sessionID, rubrik, anteckning, start/slut och skapande-/ändringstid. Intervall måste ligga inom avslutad session och får inte överlappa. Visningen väljer originalsegment som överlappar intervallet. Segment delas aldrig; ett gränsöverskridande segment kan därför visas i två lektioner.

## Förslag och frågor

`MioSuggestion` har stabilt UUID, purpose (`content` eller `question`), innehållstyp, rubrik/text, skapandetid/vald tid, valfri session-/segmentkoppling, pending/deferred och uppskjutningstid. Saknad purpose avkodas som content. Frågor använder ingen ny innehållstyp och sparas inte automatiskt som anteckningar.

Ja sparar en innehållspost med förslagets UUID och avför sedan frågan. Ett omförsök efter delvis misslyckad lagring skapar inte dubbletter eller skriver över senare ändringar. Nej tar bort förslagstexten; `processedSources` behåller endast UUID:n för deduplicering. Originaltranskriptet förblir synligt tills sessionen raderas. Inte nu behåller utkastet lokalt.

Förslagets additiva valfria `revision` blir `reviewRevision` (saknat fält = 0). Godkännande kräver samma revision som användaren granskade. En senare AI-komplettering gör granskningen föråldrad; användarens redigerade utkast bevaras och måste granskas igen. Actorägd godkännandeclaim stänger analysbeslut före innehållssparning. Vid relevant utkaständring återställs datumkontrollen. Saknat AI-datum/klockslag kräver ett uttryckligt användarval; ett internt standarddatum är inte ett godkänt datum.

En AI-fråga stannar lokalt tills användaren går vidare till AI-vyn, väljer eventuell kontext och godkänner den exakta sändningen. Efter lyckat svar avförs inkorgsfrågan när användaren lämnar svaret. Vid fel eller avbryt finns frågan kvar.

Frågesvaret och `MioAnswerNoteDraft` finns endast tillfälligt i RAM. Draftets UUID/generation hör till det aktuella svaret. **Granska och spara som anteckning** öppnar ett redigerbart utkast; ett explicit lokalt Spara skapar en `.note` med samma UUID via `saveApprovedIfAbsent`. Om samma ID redan finns bevaras den lagrade posten och senare redigeringar. Detta anropar ingen extra AI, bygger ingen frågehistorik och skapar inga systemåtgärder. Konfigurationsändring/radering ogiltigförklarar osparat svar och draft. Redan uttryckligen sparad anteckning följer vanlig lokal lagring/radering.

## Systemdata och konfiguration

iOS är källa för AlarmKit-alarm och lokala notiser. Postalarm använder postens UUID; notiser `mio.reminder.<UUID>`; dagliga notiser fasta Mio-ID:n. En lista med enbart kända alarm-UUID:n finns i egna UserDefaults så att nekad behörighet inte döljer ett kvarvarande alarm vid radering. Kalenderkopior finns i den kalender användaren väljer och är fristående.

Notisens `userInfo` innehåller endast `mioRoute` (`post`, `morning`, `evening`) och, för post, ett opakt `mioPostID`-UUID. Låsskärmtexten är generell. Extra nycklar/ogiltiga rutter avvisas. En pending rutt hålls till lokala lager har lästs; borttagen post ger säker fallback till dagsfliken. Rutt, flikval och vald översiktsdag är tillfälligt presentationstillstånd och startar aldrig mikrofon eller AI.

AI-aktivering och HTTPS-adress finns i egna UserDefaults. Separat gatewaytoken lagras i Keychain under `app.mio.assistant.cloud-gateway`, endast tillgänglig på upplåst aktuell enhet. Leverantörens API-nyckel finns enbart på servern. Frågeutkast/svar i AI-vyn är tillfälliga och sparas inte som historik. Uppskjutna inkorgsfrågor finns i assistentlagret.

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

## Molnanslutning med Access, 2026-09-29

Keychain-posten `app.mio.assistant.cloud-gateway` / `gateway-token` innehåller efter nästa sparning ett JSON-objekt med gatewaytoken och valfritt Access-par. Äldre post med enbart tokensträng kan läsas. Alla hemligheter uppdateras i en Keychain-skrivning med `WhenUnlockedThisDeviceOnly`, ingår aldrig i export och raderas tillsammans vid glömd anslutning/fullständig radering. Ändrad server kräver att hemligheter anges igen. Anslutningens jämförelse inkluderar Access-paret vid förhandsgranskning. Sparning/radering skickar samma återställningsnotis som tidigare och stoppar pågående analys. Inga innehållsscheman ändras.

## Privat transkription, 2026-09-30

`TranscriptSegment` har valfria `transcriptionMetadata` (modell/revision/motor) och `sourceChunkID` för proveniens och deduplicering. `MioSession.captureGaps` är en valfri lista med UUID, start/slut och orsak. Äldre JSON utan dessa fält avkodas; originals text/tider och äldre motorfält ändras inte. Sessions- och exportscheman byter inte version för dessa additiva fält. Ofullständigt ljudunderlag märks både i lektionsvy och kopierad anteckning.

Transkriptionsadress ligger i `mio.transcription.server` (UserDefaults); separat token i Keychain (`app.mio.assistant.transcription`, `access-token`, WhenUnlockedThisDeviceOnly). Aktiv session håller sin fasta adress/token i RAM för användarstartad fångst med låst skärm. Detta kräver ändå telefonprov. Ny adress kräver ny token. Inställningsbyte är spärrat under fångst och återkallar gammal klient. Token, ljudbuffertar och WAV-delar ingår aldrig i lagring eller export. Högst 60 s från äldsta samples ursprungliga tid behålls i RAM, även under retry/stopp. Paus/stopp släcker mikrofonen först; redan fångad slutdel kan dräneras högst 15 s och inom den ursprungliga 60-sekundsgränsen. Därefter rensas egna ljudreferenser; bortfall markeras som lucka. Radering rensar/avbryter väntande arbete. Servern har en kort textcache för identiska retries, se [API](../transcription-server/API.md).

Talare (2026-10-11): `TranscriptSegment.speaker` är ett valfritt heltal 1–4 från PC:n och hör till originalunderlaget; en del med flera talare sparas som ett segment per talarbyte med samma `sourceChunkID`. `MioSession.speakerNames` är en valfri ordlista talarnummer → namn (högst 40 tecken), ett visningslager som bara ändras i avslutade sessioner och aldrig skriver om segmenten. Båda fälten är additiva; äldre data avkodas som utan talare. Ljudet styckas nu vid pauser (8–22 s ägt ljud, högst 24 s per begäran); som mest cirka 23 s väntar mellan snitten, inom samma 60-sekundersgräns.

Löpande vardags-AI får bara segment vars **ljudstart** ligger efter aktiveringen. Ett fördröjt transkript från tidigare ljud räknas inte som nytt godkänt underlag. En ljuddel som korsar samtyckesgränsen kan därför hoppas över konservativt.

## AI-kontext och diagnostik, 2026-09-30

Vardagsanalys använder `/v2/analyze`: `fragments` är enbart nya källor, `contextFragments` innehåller högst 60 sekunder/4000 byte tidigare godkänd text inom samma lyssningskontinuitet. Alla fragment behåller identitet och text; äldre kontext kan uteslutas helt med `contextLimited`. Totalt högst åtta fragment/10000 byte/20000 byte JSON. Nya batcher reserverar kontextutrymme med högst fem fragment/6000 byte. Kontext går aldrig före aktiveringen eller över en ljudlucka/paus/lektionsgräns. Lektionens kontrakt ändras inte.

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

**MetricKit och loggning.** En `MXMetricManagerSubscriber` sparar Apples textfria JSON-rapporter i `Mio/metrickit-v1.json` (högst 40, 3 MB, 30 dagar; okänt schema skrivs inte över). Sidan Inställningar → Om Mio → Diagnostik visar datum, typ och en sifferbaserad sammanfattning med dela/kopiera; rapporterna ingår i exporten och raderas med diagnostiken. `os.Logger` (subsystem `app.mio.assistant`, kategorierna `capture`, `transcription`, `ai`, `storage`) loggar bara fasta meddelanden och heltal, aldrig användartext.
