# Kravmatris för fas 2

Senast uppdaterad: 24 augusti 2026.

**Viktig statusgräns:** implementation i källkod är inte samma sak som en fungerande iPhone-build. Den aktuella fas 2-revisionen är ännu inte Xcode-kompilerad, byggd i GitHub Actions, installerad eller manuellt verifierad.

| Krav | Status i arbetskopian | Automatisk verifiering | GitHub Actions | iPhone 13 | Återstår |
|---|---|---|---|---|---|
| Projekt, mappar, targets, scheme, produkt och artifacts heter `MioPhaseTwo` | Implementerat i arbetskopian | Godkänd statisk namn- och projektkontroll | Ej körd | Ej testat | Kompilera och kontrollera artifactnamn |
| Bundle identifier är fortsatt `se.eyvin.MioPhaseOne` för uppgradering på plats | Implementerat i projektet | Godkänd statisk projektkontroll | Ej körd | Ej testat | Installera över befintlig app och verifiera dataåtkomst |
| Fem flikar: Mio, Tidslinje, Kalender, Anteckningar och Morgon | Implementerat i källkod | Ingen UI-körning | Ej körd | Ej testat | Kompilera och gå igenom alla flikar |
| Gemensam modell för fem innehållstyper | Implementerat i källkod | Testkod finns, ej körd | Ej körd | Ej testat | Kör Codable- och modelltester |
| Skapa och redigera manuella poster | Implementerat i källkod | Ingen körd UI-verifiering | Ej körd | Ej testat | Testa varje typ på telefonen |
| Radera en manuell post | Implementerat i källkod | Repository-testkod finns, ej körd | Ej körd | Ej testat | Testa radering och omstart |
| Markera uppgift som klar/inte klar | Implementerat i källkod | Modellkod finns, testkörning saknas | Ej körd | Ej testat | Testa båda tillstånden och export |
| Lokal tid och stabil tidslinjeordning | Implementerat i källkod | Testkod för stabil skiljeregel finns, ej körd | Ej körd | Ej testat | Verifiera ordning efter redigering och omstart |
| Svensk sökning över poster | Implementerat i källkod | Testkod för skiftläge och diakritik finns, ej körd | Ej körd | Ej testat | Testa svenska sökfall i UI |
| Sökning över sessionstitel, anteckning och visad text | Implementerat i källkod | Testkod finns delvis, ej körd | Ej körd | Ej testat | Testa träff och tomt resultat |
| Valfri koppling från post till session | Implementerat i källkod | Codable-testkod finns, ej körd | Ej körd | Ej testat | Skapa, visa och ta bort koppling |
| Sessionstitel och manuell sessionsanteckning | Implementerat i källkod | Äldre JSON-täckning finns, ej körd | Ej körd | Ej testat | Redigera en avslutad session |
| Rättad text bevarar original och ljudtider | Implementerat i källkod | Testkod finns, ej körd | Ej körd | Ej testat | Kontrollera både UI och export |
| Äldre `MioPhaseOne/sessions.json` migreras till `MioPhaseTwo/sessions.json` | Implementerat i källkod | Migrationstestkod finns, ej körd | Ej körd | Ej testat | Installera över befintlig appdata |
| Separat `MioPhaseTwo/content-v1.json` | Implementerat i källkod | Repository-testkod finns, ej körd | Ej körd | Ej testat | Verifiera persistens på enheten |
| Okänd innehållsschemaversion skrivs inte över | Implementerat i källkod | Testkod finns, ej körd | Ej körd | Ej testat | Kör testet i Xcode |
| Gemensam versionsmärkt JSON-export | Implementerat i källkod | Exporttestkod finns, ej körd | Ej körd | Ej testat | Skapa och granska verklig testexport |
| Radera all lokal sessions- och innehållsdata | Implementerat i källkod | Separata repository-tester finns, ej körda | Ej körd | Ej testat | Exportera testdata och kontrollera total radering |
| Inget råljud sparas | Arkitekturregeln är bevarad i källkod | Godkänd källkodssökning; ingen råljudsfilskrivning hittad | Ej körd | Ej testat | Granska ny IPA och export |
| Ingen OpenAI-, EventKit- eller alarmintegration | Avsiktligt utanför fas 2 | Godkänd källkodssökning | Ej körd | Ej testat | Bekräfta offlinebeteende |
| Gemensam `SpeechAnalyzer` kör vald transkriptionsmodul | Implementerat i källkod och diagnostikhändelse | Godkänd statisk flödeskontroll | Ej körd | Ej testat | Bekräfta analyzer och faktisk modul i händelseloggen |
| Tydlig assetstatus för svensk `SpeechTranscriber` | Implementerat i källkod med `AssetInventory` | Kräver iOS 26/Xcode 26 | Ej körd | Ej testat | Kontrollera stödd, hämtas och installerad |
| Explicit reservation och separat förinstallation av `SpeechTranscriber` | Implementerat i källkod | Kräver iOS 26/Xcode 26 | Ej körd | Ej testat | Testa med wifi och appen öppen |
| `SpeechTranscriber` används först efter installerad assetstatus | Implementerat i källkod | Ingen körning ännu | Ej körd | Ej testat | Bekräfta vald modul på telefonen |
| Sessionsstart hämtar inte `SpeechTranscriber` utan väljer fallback direkt om asseten saknas | Implementerat i källkod | Godkänd statisk flödeskontroll | Ej körd | Ej testat | Mät starttid och kontrollera händelseloggen |
| `DictationTranscriber` med `sv_SE` finns kvar som fallback i en ny analyzer | Implementerat i källkod | Ingen ny körning ännu | Ej körd | Ej testat | Kör regressionsrökprov |
| Mikrofonen är av när Mio är av eller pausad | Befintligt beteende avses vara bevarat | Kan inte bevisas statiskt | Ej körd | Ej testat på nya revisionen | Kontrollera orange indikator |

## Fasgräns

Fas 2 kan bedömas separat som lokal, manuell MVP, men den stänger inte fas 1. Långa bakgrunds-, batteri-, avbrotts- och kvalitetsprov i [TESTPLAN_FAS_1.md](TESTPLAN_FAS_1.md) återstår tills verkliga telefonresultat finns.
