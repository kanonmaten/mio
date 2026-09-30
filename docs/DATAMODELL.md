# Datamodell för Mio

Helhetsbygge 0.9.0, nyinstallation enligt användarbeslut 2026-09-26. Appidentiteten är `app.mio.assistant`. Det finns ingen migrering från de borttagna prototyperna. Appversionen och JSON-scheman är separata värden.

## Lokala lager

Filerna ligger under appens Application Support:

| Fil | Innehåll | Schema |
|---|---|---|
| `Mio/sessions.json` | Originaltranskript, ljudtider, diagnostik, batteriprover, titel/anteckning/rättningar | Sessionsarray med valfria visningsmetadata |
| `Mio/content-v1.json` | Tidslinjeposter, anteckningar, uppgifter, planer och uttryckliga minnen | `schemaVersion: 1`, `items` |
| `Mio/diagnostics-v1.json` | Begränsad textfri AI-anropsjournal | `schemaVersion: 1`, `events` |
| `Mio/assistant-v1.json` | Väntande frågor/förslag, lektioner och bearbetade källidentiteter | `schemaVersion: 1`, `suggestions`, `lessons`, `processedSources`, valfritt `analyses`, `analysisDecisions` |

Lagringen är atomisk och mappar undantas från enhetsbackup. Filskyddet tillåter en pågående ljudsession efter första upplåsning. Inget råljud lagras. Okända innehålls-/assistentscheman får inte skrivas över; explicit total radering är en separat användaråtgärd.

## Innehållspost

`MioContentItem` har UUID, typ (`timeline`, `note`, `task`, `plan`, `memory`), obligatorisk trimmad rubrik, text, skapandetid, uppdateringstid, användarvald `scheduledAt`, valfri `completedAt` och valfri sessionskoppling. Endast uppgifter har klarstatus. En lokal plan är inte automatiskt en systemkalenderpost.

Ordning är fallande vald tid, skapandetid och slutligen UUID. Sökning normaliserar skiftläge, diakritik och teckenbredd med svensk lokal. Sessioner söks på titel, anteckning och visningstext.

## Original och visningslager

En avslutad session får titel, manuell anteckning och separata `correctedText`-fält. Originalets `text`, `createdAt`, `audioStartedAt`, `audioEndedAt`, Mio-detektion, bakgrundsmarkering och tidsgiltighet ändras inte. En aktiv session måste stoppas före redigering.

Lektioner har UUID, sessionID, rubrik, anteckning, start/slut och skapande-/ändringstid. Intervall måste ligga inom avslutad session och får inte överlappa. Visningen väljer originalsegment som överlappar intervallet. Segment delas aldrig; ett gränsöverskridande segment kan därför visas i två lektioner.

## Förslag och frågor

`MioSuggestion` har stabilt UUID, purpose (`content` eller `question`), innehållstyp, rubrik/text, skapandetid/vald tid, valfri session-/segmentkoppling, pending/deferred och uppskjutningstid. Saknad purpose avkodas som content. Frågor använder ingen ny innehållstyp och sparas inte automatiskt som anteckningar.

Ja sparar en innehållspost med förslagets UUID och avför sedan frågan. Ett omförsök efter delvis misslyckad lagring skapar inte dubbletter eller skriver över senare ändringar. Nej tar bort förslagstexten; `processedSources` behåller endast UUID:n för deduplicering. Originaltranskriptet förblir synligt tills sessionen raderas. Inte nu behåller utkastet lokalt.

En AI-fråga stannar lokalt tills användaren går vidare till AI-vyn, väljer eventuell kontext och godkänner den exakta sändningen. Efter lyckat svar avförs inkorgsfrågan när användaren lämnar svaret. Vid fel eller avbryt finns frågan kvar.

## Systemdata och konfiguration

iOS är källa för AlarmKit-alarm och lokala notiser. Postalarm använder postens UUID; notiser `mio.reminder.<UUID>`; dagliga notiser fasta Mio-ID:n. En lista med enbart kända alarm-UUID:n finns i egna UserDefaults så att nekad behörighet inte döljer ett kvarvarande alarm vid radering. Kalenderkopior finns i den kalender användaren väljer och är fristående.

AI-aktivering och HTTPS-adress finns i egna UserDefaults. Separat gatewaytoken lagras i Keychain under `app.mio.assistant.cloud-gateway`, endast tillgänglig på upplåst aktuell enhet. Leverantörens API-nyckel finns enbart på servern. Frågeutkast/svar i AI-vyn är tillfälliga och sparas inte som historik. Uppskjutna inkorgsfrågor finns i assistentlagret.

## Export och radering

Gemensam export heter `Mio-lokal-export-ÅÅÅÅ-MM-DD-HHmm.json`:

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

Exporten har ett additivt valfritt `diagnostics`-fält; äldre export utan fältet kan fortfarande avkodas. Exporten har inga ljuddata, token, API-nycklar eller systemkalenderkopior. Avkodning stöder även export utan assistantfält, men appen erbjuder ingen importknapp. Filernas egna schemaVersion är fortfarande 1.

Sessionens enskilda radering tar bort dess lektioner/förslag och lossar manuella poster. Radering av en post avbryter dess Mio-alarm/notis. Fullständig radering avbryter alla egna alarm/notiser, glömmer AI-konfiguration, raderar fyra lokala lager och interna exportkopior. En gemensam skrivspärr och tombstones hindrar sena callbacks från att återskapa data. Systemfel ska visas, inte döljas som lyckad radering.

Redan delade exporter, skickade molnfrågor och kalenderkopior ligger utanför appens lokala radering. De behöver hanteras där de sparats.

## Lektionsläge och strukturerad AI-analys

Sessioner har valfritt `captureMode` (`everyday`/`lesson`); saknat fält betyder tidigare vardagssession. Nya lektioner har en egen session och ett avslutat lektionsintervall. Flera oavslutade sessioner efter ett avbrott återställs som avslutade vid nästa appstart, utan automatisk mikrofonstart.

`MioAnalysisRecord` lagrar sessionID, analyserade fragment-ID:n, huvudpunkter med käll-ID/exakt citat, osäkerheter och skapandetid. Fullt transkript dupliceras inte. Fragment-ID består av segmentets UUID och delindex; text delas vid behov utan att originalsegmentet ändras. Alla käll-ID:n/citat valideras före lagring. Även tomma resultat registreras så att samma utdrag inte skickas igen. Deduplicering av förslag jämför typ, rubrik, tid och session; den är inte en allmän semantisk dubblettkontroll.

AI-förslag har valfria `evidence` och `needsDateConfirmation`. Äldre filer saknar dessa fält och kan fortfarande avkodas. Scheman är additivt bakåtkompatibla; version 1 behålls. Ett Nej tar bort förslagets text/citat men lämnar källidentiteter; lektionspunkter och originaltext raderas med sessionen. Export inkluderar analysutkast. Aktiveringssamtycke, kö och tillfällig token lagras inte i analysfilen och exporteras inte.

## Detaljerade lektionsdelar, 2026-09-28

`MioAnalysisRecord` har additiva valfria `sections` och `metadata`. En section har `heading`, `body`, `sourceIDs`, `evidence`. Metadata har `provider`, `model`, `promptVersion`, `lessonIntervalSeconds`. Inga hemligheter lagras här. Schema 1 behålls; äldre filer utan fälten avkodas och bevaras. Gamla highlights visas separat och räknas inte som detaljerade delar.

En färdig detaljerad del registreras även när dess sectionlista är tom. Framsteg och återstående arbete härleds från sessionens fragment-ID:n och sparade detaljerade poster, så inget nytt beständigt samtycke eller köformat behövs. Spara före nästa anrop. Sammanställningen sorteras efter källfragmentens ordning; kopierad text innehåller rubrik, datum, anteckningar, osäkerheter och en markering om bearbetningen är ofullständig, aldrig interna käll-ID:n. Originaltexten ändras inte. Radering tar bort hela analysen och dess metadata som tidigare.

Detaljerade delar analyserar den visningstext som fanns vid sändningen. Senare manuella rättningar ger ingen automatisk omanalys av redan bearbetade fragment. Källcitatet bevaras som bevis för vilket underlag som användes.

## Molnanslutning med Access, 2026-09-29

Keychain-posten `app.mio.assistant.cloud-gateway` / `gateway-token` innehåller efter nästa sparning ett JSON-objekt med gatewaytoken och valfritt Access-par. Äldre post med enbart tokensträng kan läsas. Alla hemligheter uppdateras i en Keychain-skrivning med `WhenUnlockedThisDeviceOnly`, ingår aldrig i export och raderas tillsammans vid glömd anslutning/fullständig radering. Ändrad server kräver att hemligheter anges igen. Anslutningens jämförelse inkluderar Access-paret vid förhandsgranskning. Sparning/radering skickar samma återställningsnotis som tidigare och stoppar pågående analys. Inga innehållsscheman ändras.

## Privat transkription, 2026-09-30

`TranscriptSegment` har valfria `transcriptionMetadata` (modell/revision/motor) och `sourceChunkID` för proveniens och deduplicering. `MioSession.captureGaps` är en valfri lista med UUID, start/slut och orsak. Äldre JSON utan dessa fält avkodas; originals text/tider och äldre motorfält ändras inte. Sessions- och exportscheman byter inte version för dessa additiva fält. Ofullständigt ljudunderlag märks både i lektionsvy och kopierad anteckning.

Transkriptionsadress ligger i `mio.transcription.server` (UserDefaults); separat token i Keychain (`app.mio.assistant.transcription`, `access-token`, WhenUnlockedThisDeviceOnly). Aktiv session håller sin fasta adress/token i RAM så att låst skärm fungerar efter användarstart. Ny adress kräver ny token. Inställningsbyte är spärrat under fångst och återkallar gammal klient. Token, ljudbuffertar och WAV-delar ingår aldrig i lagring eller export. Hela RAM-kön rensas vid avslut/radering; servern har en kort textcache för retries, se [API](../transcription-server/API.md).

Löpande vardags-AI får bara segment vars **ljudstart** ligger efter aktiveringen. Ett fördröjt transkript från tidigare ljud räknas inte som nytt godkänt underlag. En ljuddel som korsar samtyckesgränsen kan därför hoppas över konservativt.

## AI-kontext och diagnostik, 2026-09-30

Vardagsanalys använder `/v2/analyze`: `fragments` är enbart nya källor, `contextFragments` innehåller högst 60 sekunder/4000 byte tidigare godkänd text inom samma lyssningskontinuitet. Alla fragment behåller identitet och text; äldre kontext kan uteslutas helt med `contextLimited`. Totalt högst åtta fragment/10000 byte/20000 byte JSON. Nya batcher reserverar kontextutrymme med högst fem fragment/6000 byte. Kontext går aldrig före aktiveringen eller över en ljudlucka/paus/lektionsgräns. Lektionens kontrakt ändras inte.

`analysisDecisions` i assistentlagret är additivt valfritt. Varje beslut har förslags-ID, sessionID, typ, källfragment-ID:n och `isClosed`. `priorDecisions` skickar bara beslut kopplade till vald kontext, med `isOpen`, aldrig tidigare förslagstext. En v2-kandidat har nullable `replacesID` och minst en ny källa. En komplettering uppdaterar samma öppna förslags-ID och behåller skapandetid/uppskjutning. Ja/Nej stänger beslutet och tar bort förslagstext; ett sent svar kontrolleras mot senaste lagrade beslut. V2 slår bara ihop förslag via `replacesID`; även identiska nya fristående kandidater behåller egna beslut/källor. Bearbetningsposter registrerar bara nya fragment. Sessionsradering tar även bort dess beslut.

`diagnostics` i schema 2-exporten innehåller appversion/build, OS, maskinidentifierare, tidszon, fyra konfigurationsbooleans och journalens lagringsstatus/händelser. Den sparar högst 200 händelser i sju dagar oberoende av sessioner. Varje händelse innehåller fast operation/rutt, tid/duration, byteantal, HTTP-status, tillåten gatewayfelkod, Retry-After, tillåten nätfel-domän/-kod och säkra release-/provider-/modell-/prompt-/request-ID-/CF-Ray-fält. Analys kan ha fragmentantal, källtidsintervall, köstorlek och kontextbegränsning. Inga frågor, transkript, svar, felkroppar, fullständiga URL:er, headerdumpningar, hemligheter eller råljud lagras. Okänt journalschema skrivs inte över; lagringsfel märks i exporten. Raderingsgeneration och starttidsgräns avvisar sena händelser efter total radering.
