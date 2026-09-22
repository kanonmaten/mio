# Datamodell för v0.2.0

Införd i v0.2.0. Se [status](STATUS.md) för verifiering. Lagringsnamnen nedan behålls över appversioner; namnbytet till Mio ändrar inte dataformatet.

## Syfte

v0.2.0 lägger till ett gemensamt, helt lokalt innehållslager för manuella poster utan att skriva om den sessionsdata som samlades in i v0.1.0. Modellen ska göra det möjligt att skapa och ordna vardagsinnehåll nu, samtidigt som originaltranskriptioner och deras tekniska bevis förblir intakta.

## Två separata lokala lager

| Sökväg i appens Application Support | Innehåll | Versionsregel |
|---|---|---|
| `MioPhaseTwo/sessions.json` | Sessioner, originaltranskriptioner, ljudtider, diagnostik och batteriprover | Befintligt format behålls. Nya valfria metadatafält kan saknas i äldre filer. |
| `MioPhaseTwo/content-v1.json` | Manuellt innehåll från v0.2.0 | Dokumentet innehåller `schemaVersion: 1`. Okända versioner ska rapporteras och får inte skrivas över. |

Vid en uppgradering med samma bundle identifier letar appen efter äldre `MioPhaseOne/sessions.json` om den nya sessionsfilen saknas. Filen avkodas först, skrivs atomiskt till `MioPhaseTwo/sessions.json` och tas därefter bort från den äldre platsen. Sessionsschema, fältvärden och identiteter bevaras semantiskt även om JSON-formateringen kan ändras vid återkodning. Migreringen gör inte om sessioner till manuella poster; en manuell post kan i stället ha en valfri koppling genom `sessionID`.

## Gemensam innehållspost

Alla fem manuella typer använder samma grundmodell:

| Fält | Typ | Regel |
|---|---|---|
| `id` | UUID | Stabil unik identitet. |
| `kind` | enum | `timeline`, `note`, `task`, `plan` eller `memory`. |
| `title` | text | Obligatorisk efter trimning. |
| `body` | text | Valfri beskrivning eller anteckning. |
| `createdAt` | tidpunkt | Sätts när posten skapas och ändras inte vid redigering. |
| `updatedAt` | tidpunkt | Uppdateras när posten ändras. |
| `scheduledAt` | tidpunkt | Den lokala tid som visas i tidslinje eller planering. Det är inte en systemkalenderpost. |
| `completedAt` | tidpunkt eller null | Används endast för uppgifter. Övriga typer ska lagra null. |
| `sessionID` | UUID eller null | Valfri relation till en session i aktiva `MioPhaseTwo/sessions.json`, inklusive en migrerad v0.1.0-session. |

Typerna visas på svenska som **Tidslinjepost**, **Anteckning**, **Uppgift**, **Plan** och **Uttryckligt minne**. Ett uttryckligt minne skapas manuellt av användaren; appen bygger ingen dold profil från vanlig text.

## Ordning och sökning

- Poster sorteras fallande på `scheduledAt`, därefter `createdAt` och slutligen UUID som stabil skiljeregel.
- Sökning omfattar typens svenska namn, rubrik och brödtext.
- Sökning normaliserar skiftläge, diakritiska tecken och teckenbredd med svensk lokal.
- Sessioner kan sökas på egen titel, manuell anteckning och den text som visas efter en eventuell rättning.

## Redigerbart lager över sessioner

En avslutad session kan få:

- en valfri titel;
- en valfri manuell anteckning;
- en valfri `correctedText` för varje transkriptionssegment.

Rättningen är ett visningslager. Följande ursprungsfält ska alltid bevaras:

- originalfältet `text`;
- `audioStartedAt` och `audioEndedAt`;
- `createdAt`;
- Mio-detektion;
- bakgrundsmarkering och giltighet för ljudtid.

Äldre `sessions.json` utan titel, anteckning eller rättningar ska kunna läsas med dessa fält som tomma. En aktiv session måste stoppas innan metadata eller text rättas.

Om en session raderas ska manuella poster inte raderas automatiskt. Deras `sessionID` ska i stället tas bort så att posten fortfarande är användbar utan en trasig relation.

## Lokal lagring och radering

- Båda lagren skrivs atomiskt i appens sandbox.
- Lagringen använder filskydd som tillåter en redan startad bakgrundssession efter telefonens första upplåsning.
- De beständiga mapparna undantas från enhetsbackup.
- **Radera all lokal data** ska radera både sessioner och manuellt innehåll efter en tydlig bekräftelse.
- Delade kopior som redan finns i Filer, mejl eller en annan app ligger utanför Mios sandbox och kan inte återkallas av appen.
- Inget lager får innehålla sparat råljud.

## Gemensam export

Den lokala exporten heter `Mio-lokal-export-ÅÅÅÅ-MM-DD-HHmm.json` och innehåller:

```json
{
  "schemaVersion": 1,
  "exportedAt": "ISO-8601-tidpunkt",
  "content": [],
  "sessions": []
}
```

`content` innehåller de fem manuella typerna. `sessions` innehåller sessionernas originaldata plus eventuella titlar, anteckningar och rättningar. Exporten innehåller aldrig råljud, API-nycklar, certifikat eller pairing-information.

Exportformatet är versionsmärkt men v0.2.0 innehåller ingen importfunktion. En framtida schemaändring måste få en uttrycklig migrering eller ett nytt filnamn; okända schemaversioner får inte tyst skrivas över.

## Avsiktliga gränser

- En plan är endast lokal och skrivs inte till EventKit eller systemkalendern.
- Morgonfliken skapar inga systemalarm eller lokala notiser i v0.2.0.
- Ingen post skickas till OpenAI eller någon annan extern AI-tjänst.
- Automatisk plan-, uppgifts- eller minnesdetektion hör till senare versioner och kräver då uttrycklig bekräftelse.
