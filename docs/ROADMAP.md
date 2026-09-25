# Versioner och roadmap

Versioner beskriver produktens omfattning. Ett versionsnummer är inte ett testresultat eller ett löfte om datum.

| Version | Innehåll | Läge |
|---|---|---|
| v0.1.0 | Lokal transkription, Mio-detektion, sessioner, paus och diagnostik | Historisk prototyp; kort telefonprov godkänt, långtest öppna |
| **v0.2.0** | Lokal manuell MVP: fem flikar, poster, sökning, rättningar och export | **Aktuell utvecklingsversion, ej släppt** |
| v0.3.0 | Lokala frågor och förslag med **Ja / Nej / Inte nu**, vibration och förhandsgranskning | Planerad |
| v0.4.0 | Kalenderintegration, alarm/notiser, morgonöversikt och kvällssammanfattning | Planerad; inom iOS begränsningar |
| v0.5.0 | Begränsade OpenAI-svar via server efter uttryckligt godkännande | Planerad; kräver separat integrationsbeslut |
| v1.0.0 | Tillförlitlig privat vardagsapp med accepterad omfattning | Inget datum; kräver dokumenterad stabilitet, batteritid och datakontroll |

Tidigare fas 1–5 motsvarar nu v0.1.0–v0.5.0. Det är en namnkonvention för historik och planering, inte retroaktiva releaser.

## Versionsregler

- `0.MINOR.0`: ny sammanhängande funktionalitet under utveckling. `0.MINOR.PATCH`: rättningar inom samma omfattning.
- `1.0.0`: den överenskomna vardagsprodukten är verifierad. Därefter höjs major vid avsiktligt inkompatibla ändringar, minor för funktioner och patch för rättningar.
- Skriv `v0.2.0` i dokument och taggar, `0.2.0` i Xcodes `MARKETING_VERSION`.
- `CURRENT_PROJECT_VERSION` är ett separat byggnummer; höj inför en ny distribuerad build. Lagringens `schemaVersion` ändras bara när dataformatet kräver det.
- Projektet heter alltid `Mio`. Byt inte bundle identifier eller lagringskatalog vid versionshöjning.
- För ändringar i [CHANGELOG](../CHANGELOG.md) under **ej släppt**. Sätt släppdatum och skapa tagg först efter verifiering och uttrycklig begäran om publicering.

## Nästa steg: verifiera v0.2.0

1. Kör GitHub Actions-jobbet på `xcode-27`: Release, XCTest på iOS 27-simulator och validerad IPA. Kontrollera runnerns tillgänglighet och dokumentera utfallet för exakt commit.
2. Exportera befintlig data privat; installera över Mio med samma appidentitet och signeringskonto.
3. Kör [test A–M](TESTPLAN_V0_2.md): uppgradering, manuellt innehåll, persistens, export, radering, talflöde och tillgänglighet.
4. Kör kvarvarande [transkriptionsprov](TESTPLAN_V0_1.md): låst skärm ≥10 min, batteri ≥60 min, avbrott, pauser och kvalitet. Prova 3–4 timmar först efter ett rimligt timtest.
5. Dokumentera resultat för exakt commit och enhet i [status](STATUS.md).

Manuella funktioner kan verifieras även om heldagslyssningen ännu inte är godkänd. v1.0.0 får däremot inte lova heldagslyssning utan verklig evidens. Råljudslagring och molnsynk av ljud ingår inte i planen.
