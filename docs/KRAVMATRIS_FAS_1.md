# Kravmatris för fas 1

Telefonresultaten bygger på rökprovet den 20 augusti 2026. **Kort godkänt** betyder att funktionen observerades men ännu inte klarade testplanens fulla varaktighet.

| Krav | Implementerat | Telefonresultat | Återstår |
|---|---:|---|---|
| Mikrofon på/av | Ja | Start, paus och användarstopp loggades | Kontrollera indikatorn manuellt vid alla lägen |
| Tydlig status | Ja | Appen kunde startas och pausas | Visuell check enligt testplan |
| Låst skärm/bakgrund | Ja, konfigurerat | Kort godkänt: 1 giltigt segment under 11 s total bakgrund | Minst 10 min med uttryckligen låst skärm |
| Apples avancerade motor | Ja, nytt status-/reservations-/installationsflöde i arbetskopian | `transcription.sv` blev `Not Installing` i det historiska provet | Testa fas 2-flödet på telefonen; markera inte installerad utan nytt bevis |
| Svensk lokal reservmotor | Ja | Godkänt: `DictationTranscriber`, `sv_SE` | Längre kvalitets- och stabilitetstest |
| Tidsstämplad text | Ja | Godkänt: 5 segment med giltig ljudtid | Långt test och kontroll efter avbrott |
| Paus 30 minuter | Ja | Inte testad | Testa tidsstyrd fortsättning |
| Paus 1 timme/tills start | Ja | “Tills start” stängde flödet i korttest; 1 timme inte testad | Manuell fortsättning och 1-timmesläge |
| Lokal Mio-detektion | Ja | Godkänt: 2 detektioner, 1 i bakgrunden | Fler uttal, buller och skiljetecken |
| Haptisk signal | Ja i förgrunden | Kan inte utläsas ur JSON | Bekräfta manuellt |
| Batterimätning | Ja | 5 prover, 65 % → 65 % utan laddare | Minst 60 min, därefter 3–4 timmar |
| Ljudavbrott | Ja | Inget avbrott inträffade | Test med alarm eller samtal |
| Ljudvägsändring | Ja, loggning | En kategoriförändring loggades vid start | Frivilligt AirPods-test |
| Tappade ljudbuffertar | Ja, räknare | 0 i korttest | Långt stresstest |
| Data överlever appstart | Ja | Inte testat över omstart | Stäng och öppna appen |
| Export | Ja | Godkänt: giltig JSON skapades | Fortsatt privat hantering |
| Radera all data | Ja | Inte testat | Exportera kopia och verifiera radering |
| Råljud sparas inte | Ja | Exporten innehöll ingen ljudfil | Behåll som arkitekturregel |
| OpenAI används inte | Ja | Inga OpenAI-händelser eller nycklar | Ingen OpenAI-konfiguration i fas 1 |

## Medvetna fasgränser

Fas 2:s femflikars huvudapp och manuella lokala modell utvecklas nu parallellt med de öppna fas 1-proven. Detta ändrar inte telefonresultaten i tabellen och den nya revisionen behöver ett regressionsprov.

EventKit-kalenderkoppling, systemalarm, automatisk lektionssegmentering, automatisk planigenkänning, kvällssammanfattning och OpenAI-frågor efter **Ja / Nej / Inte nu** hör fortfarande till senare faser. Se [ROADMAP.md](ROADMAP.md), [KRAVMATRIS_FAS_2.md](KRAVMATRIS_FAS_2.md) och [TESTRESULTAT_FAS_1.md](TESTRESULTAT_FAS_1.md).
