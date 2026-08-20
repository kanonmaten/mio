# Kravmatris för fas 1

| Krav | Implementerat | Bevis i projektet | Måste verifieras på iPhone |
|---|---:|---|---:|
| Mikrofon på/av | Ja | `PhaseOneViewModel.startListening()` / `stopListening()` | Ja |
| Tydlig status | Ja | Statushuvud med lyssnar, pausad och av | Ja |
| Låst skärm/bakgrund | Ja, konfigurerat | `UIBackgroundModes = audio`; godkänt bevis kräver att resultatets ljudintervall överlappar ett bakgrundsintervall | Ja, detta är fasens huvudtest |
| Kontroll av Apples avancerade motor | Ja | `SpeechCapabilityService.inspect()` | Ja |
| Svensk lokal reservmotor | Ja | `DictationTranscriber(.progressiveLongDictation)` | Ja |
| Tidsstämplad text | Ja | Varje ljudbuffert får explicit starttid; Speech-resultatets ljudintervall mappas till väggklocka i `TranscriptSegment` + lokal JSON | Ja |
| Paus 30 minuter | Ja | `PauseLength.thirtyMinutes` | Ja; iOS kan kräva att appen öppnas igen |
| Paus 1 timme/tills start | Ja | `PauseLength` och UI-menyn | Ja |
| Lokal Mio-detektion | Ja | `MioWakeWordDetector` + tester | Ja med verkligt tal |
| Haptisk signal | Ja i förgrunden | `UINotificationFeedbackGenerator` | Ja |
| Batterimätning | Ja | prov varje minut och vid viktiga händelser | Ja över minst 60 min |
| Ljudavbrott | Ja | interruption notifications + logg + försök till återstart | Ja med samtal/alarm |
| Ljudvägsändring | Ja, loggning | route-change notification | Ja; automatisk ombyggnad är fas 2 |
| Tappade ljudbuffertar | Ja | bounded stream och droppräknare | Ja under långt test |
| Data överlever appstart | Ja | `SessionRepository` | Ja |
| Export | Ja | lokal JSON via ShareLink | Ja |
| Radera all data | Ja | raderingsknapp + bekräftelse | Ja |
| Råljud sparas inte | Ja | ingen ljudfil skapas | Ja genom beteende/lagring |
| OpenAI används inte | Ja | ingen SDK, nyckel eller nätverkskod | Ingen OpenAI-konfiguration krävs |

## Medvetna fasgränser

Följande hör till senare faser: femflikars huvudapp, kalenderkoppling, alarm, lektionssegmentering, automatisk planigenkänning, långsiktiga uttryckliga minnen, kvällssammanfattning och OpenAI-frågor efter Ja/Nej/Inte nu.

Det vore riskabelt att bygga dem innan telefonprovet visar vilken svensk motor som faktiskt finns, hur låst skärm fungerar och vad batterikostnaden blir.
