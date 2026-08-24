# Bygg- och teststatus

Senast uppdaterad: 24 augusti 2026.

## Sammanfattning per revision

| Kontroll | Fas 1-revisionen från 20 augusti | Aktuell fas 2-arbetskopia |
|---|---|---|
| Källkodsimplementation | Fas 1-funktioner fanns | Fas 2-funktioner finns i arbetskopian |
| Statisk projektgranskning på Windows | Godkänd för dåvarande revision | Godkänd inom Windows-miljöns gränser |
| Xcode 26-kompilering | Godkänd i GitHub Actions | Inte körd |
| XCTest | Inte körd | Testkod finns, inte körd |
| arm64-IPA | Skapad och validerad | Inte skapad |
| SideStore-installation | Godkänd | Inte genomförd |
| iPhone 13-rökprov | Kort godkänt | Inte genomfört |
| Långt bakgrunds-/batteritest | Återstår | Återstår även som regression |

Den gröna bygg- och telefonstatusen från 20 augusti gäller endast den dåvarande fas 1-revisionen. Den får inte återanvändas som bevis för den nya arbetskopian.

## Historiskt verifierat på iPhone 13

Det 2 minuter 30 sekunder långa provet den 20 augusti 2026 visade:

- `SpeechTranscriber` kunde inte installera den avancerade svenska resursen i det testet.
- Fallback till `DictationTranscriber` med `sv_SE` startade korrekt.
- Fem finala textsegment skapades med giltig ljudtid.
- Mio upptäcktes två gånger, varav en gång i ett verkligt bakgrundsintervall.
- Noll runtimefel och noll rapporterade tappade buffertar.
- Paus tills manuell start stängde flödet; ingen text skapades efter pausen.
- Fem batteriprover låg kvar på 65 % utan laddare.

Se [TESTRESULTAT_FAS_1.md](TESTRESULTAT_FAS_1.md) för korrekt tolkning. Det korta provet stänger inte fas 1.

## Implementerat i fas 2-arbetskopian

Följande finns i källkoden men är ännu inte kompilerings- eller körverifierat:

- femflikars navigering med Mio, Tidslinje, Kalender, Anteckningar och Morgon;
- gemensam modell och manuella flöden för fem lokala innehållstyper;
- svensk sökning, tidsordning, uppgiftsstatus, redigering och radering;
- tekniska projekt-, mapp-, target-, scheme-, produkt- och artifactnamn under `MioPhaseTwo`;
- separat versionsmärkt `MioPhaseTwo/content-v1.json` och `MioPhaseTwo/sessions.json`, med flytt från äldre sessionssökväg;
- valfri sessionskoppling;
- sessionstitel, manuell anteckning och rättad visningstext som bevarar original och ljudtider;
- gemensam versionsmärkt lokal JSON-export;
- gemensam `SpeechAnalyzer` som kör en transkriptionsmodul åt gången och loggar vilken modul som faktiskt startade;
- förbättrad status, reservation och förinstallation för svensk `SpeechTranscriber`-asset;
- direkt sessionsstart med fallback i stället för automatisk `SpeechTranscriber`-hämtning när asseten saknas;
- bevarad `DictationTranscriber`-fallback i en ny analyzer;
- ingen avsiktlig OpenAI-, EventKit- eller alarmintegration.

Testfiler finns för centrala modeller, lagring, export, äldre sessionsdata och Mio-detektion, men ingen aktuell XCTest-körning finns. Se [TESTRESULTAT_FAS_2.md](TESTRESULTAT_FAS_2.md).

## Genomförd statisk kontroll för fas 2

Följande kontroller är godkända i den aktuella arbetskopian:

- aktiva projekt-, mapp-, target-, scheme-, modul-, produkt- och artifactnamn pekar konsekvent på `MioPhaseTwo`;
- kvarvarande `MioPhaseOne`-strängar är begränsade till kompatibel bundle identifier, migreringskälla, historiska exportnamn och fas 1-dokument;
- alla nya app- och testfiler finns i rätt Xcode-grupp och Sources-target;
- projekt-, plist-, scheme- och workspace-XML kan läsas;
- Swift-filernas avgränsare är balanserade och inga tabbar eller uppenbara async-anrop i XCTest-autoclosures hittades;
- relativa Markdown-länkar pekar på befintliga filer och `git diff --check` har inga whitespacefel;
- integritetsdeklarationen har ingen tracking eller insamlad datatyp;
- källkodssökning hittade ingen råljudsfilskrivning, OpenAI-klient, API-nyckel, EventKit-, notifierings- eller nätverksintegration;
- inga känsliga export-, inspelnings-, certifikat- eller provisioneringsfiler har lagts till.

Kontrollen är inte en Swift-kompilering och bevisar inte runtimebeteende. Windows-miljön saknar Swift/Xcode, så Xcode 26 och telefonen är fortfarande facit.

Bundle identifier förblir avsiktligt `se.eyvin.MioPhaseOne` så att den nya builden kan ersätta den befintliga appen och läsa dess lokala container.

## Måste verifieras för fas 2-revisionen

1. Xcode 26-kompilering och faktisk XCTest-körning.
2. GitHub Actions Release-build, arm64-kontroll och IPA-validering.
3. Installation över befintlig Mio via SideStore utan att äldre sessionsdata försvinner.
4. Funktionerna i [TESTPLAN_FAS_2.md](TESTPLAN_FAS_2.md) på iPhone 13.
5. Mikrofon-, paus-, lokal transkriptions- och exportregression på den nya IPA:n.
6. De kvarvarande långa proven i [TESTPLAN_FAS_1.md](TESTPLAN_FAS_1.md).

Tills dessa steg har verklig evidens är korrekt status **implementerad i arbetskopian, inte bygg- eller enhetsverifierad**.
