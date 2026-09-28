# Datamodell för Mio

Helhetsbygge 0.9.0, nyinstallation enligt användarbeslut 2026-09-26. Appidentiteten är `app.mio.assistant`. Det finns ingen migrering från de borttagna prototyperna. Appversionen och JSON-scheman är separata värden.

## Lokala lager

Filerna ligger under appens Application Support:

| Fil | Innehåll | Schema |
|---|---|---|
| `Mio/sessions.json` | Originaltranskript, ljudtider, diagnostik, batteriprover, titel/anteckning/rättningar | Sessionsarray med valfria visningsmetadata |
| `Mio/content-v1.json` | Tidslinjeposter, anteckningar, uppgifter, planer och uttryckliga minnen | `schemaVersion: 1`, `items` |
| `Mio/assistant-v1.json` | Väntande frågor/förslag, lektioner och bearbetade källidentiteter | `schemaVersion: 1`, `suggestions`, `lessons`, `processedSources`, valfritt `analyses` |

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

Exporten har inga ljuddata, token, API-nycklar eller systemkalenderkopior. Avkodning stöder även export utan assistantfält, men appen erbjuder ingen importknapp. Filernas egna schemaVersion är fortfarande 1.

Sessionens enskilda radering tar bort dess lektioner/förslag och lossar manuella poster. Radering av en post avbryter dess Mio-alarm/notis. Fullständig radering avbryter alla egna alarm/notiser, glömmer AI-konfiguration, raderar tre lokala lager och interna exportkopior. En gemensam skrivspärr och tombstones hindrar sena callbacks från att återskapa data. Systemfel ska visas, inte döljas som lyckad radering.

Redan delade exporter, skickade molnfrågor och kalenderkopior ligger utanför appens lokala radering. De behöver hanteras där de sparats.

## Lektionsläge och strukturerad AI-analys

Sessioner har valfritt `captureMode` (`everyday`/`lesson`); saknat fält betyder tidigare vardagssession. Nya lektioner har en egen session och ett avslutat lektionsintervall. Flera oavslutade sessioner efter ett avbrott återställs som avslutade vid nästa appstart, utan automatisk mikrofonstart.

`MioAnalysisRecord` lagrar sessionID, analyserade fragment-ID:n, huvudpunkter med käll-ID/exakt citat, osäkerheter och skapandetid. Fullt transkript dupliceras inte. Fragment-ID består av segmentets UUID och delindex; text delas vid behov utan att originalsegmentet ändras. Alla käll-ID:n/citat valideras före lagring. Även tomma resultat registreras så att samma utdrag inte skickas igen. Deduplicering av förslag jämför typ, rubrik, tid och session; den är inte en allmän semantisk dubblettkontroll.

AI-förslag har valfria `evidence` och `needsDateConfirmation`. Äldre filer saknar dessa fält och kan fortfarande avkodas. Scheman är additivt bakåtkompatibla; version 1 behålls. Ett Nej tar bort förslagets text/citat men lämnar källidentiteter; lektionspunkter och originaltext raderas med sessionen. Export inkluderar analysutkast. Aktiveringssamtycke, kö och tillfällig token lagras inte i analysfilen och exporteras inte.

## Detaljerade lektionsdelar, 2026-09-28

`MioAnalysisRecord` har additiva valfria `sections` och `metadata`. En section har `heading`, `body`, `sourceIDs`, `evidence`. Metadata har `provider`, `model`, `promptVersion`, `lessonIntervalSeconds`. Inga hemligheter lagras här. Schema 1 behålls; äldre filer utan fälten avkodas och bevaras. Gamla highlights visas separat och räknas inte som detaljerade delar.

En färdig detaljerad del registreras även när dess sectionlista är tom. Framsteg och återstående arbete härleds från sessionens fragment-ID:n och sparade detaljerade poster, så inget nytt beständigt samtycke eller köformat behövs. Spara före nästa anrop. Sammanställningen sorteras efter källfragmentens ordning; kopierad text innehåller rubrik, datum, anteckningar, osäkerheter och en markering om bearbetningen är ofullständig, aldrig interna käll-ID:n. Originaltexten ändras inte. Radering tar bort hela analysen och dess metadata som tidigare.

Detaljerade delar analyserar den visningstext som fanns vid sändningen. Senare manuella rättningar ger ingen automatisk omanalys av redan bearbetade fragment. Källcitatet bevaras som bevis för vilket underlag som användes.
