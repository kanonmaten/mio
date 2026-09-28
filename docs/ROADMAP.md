# Omfattning och leverans

Den 25 september 2026 ändrades arbetssättet: bygg hela vardagsappen sammanhängande i stället för att leverera en funktionell version i taget. Användaren har också valt att AI-klient och server ska byggas, med molnet avstängt tills det konfigureras.

**Helhetsbygget identifieras som 0.9.0, ej släppt.** Det ersätter de planerade separata v0.3–v0.5-leveranserna. v0.1.0 är historisk transkriptionsprototyp och v0.2.0 är den tidigare manuella grunden. Dessa etiketter ändrar inga gamla resultat.

## Sammanhängande produkt

| Område | Implementerad omfattning | Verifieringsgräns |
|---|---|---|
| Lokal fångst | Svensk SpeechAnalyzer, Mio-detektion, paus/stopp, diagnostik | Fysisk telefon krävs för kvalitet, bakgrund och batteri |
| Innehåll | Fem manuella typer, sökning, redigering, uppgiftsstatus, export/radering | Ren installation och lagring provas på verklig telefon |
| Assistent | Lokala kommandoförslag och aktiverad AI-tolkning av vanligt samtal; Ja/Nej/Inte nu | Modellkvalitet måste provas; innehåll och datum godkänns manuellt |
| Lektioner | Separat lektionsläge pausar vardags-Mio; detaljerade kopierbara anteckningar och läxförslag via valfri kompatibel AI | Originaltext och tidsbevis får aldrig skrivas om |
| Kalender | Användarbekräftad fristående kalenderkopia | Ingen bakgrundssynk eller läsning av hela kalendern |
| Alarm/notiser | AlarmKit, engångs-/veckoalarm, postpåminnelse, morgon-/kvällsnotis | Behörighet och leverans måste provas på telefon |
| Dagen | Lokal morgon- och kvällsöversikt av sparat innehåll | Ingen påstådd semantisk sammanfattning av transkript |
| AI | Enskilda frågor eller aktiverad löpande tolkning → egen HTTPS-server → vald leverantörsadapter | Server/nyckel kräver egen konfiguration; av från början |

## Leveransgrindar

1. Kontrollera projektfiler, privata data, lokala tester och dokumentation.
2. Efter uttryckligt tillstånd: commit/push och GitHub Actions på faktisk tillgänglig `xcode-27`-runner. Release och XCTest måste bli gröna för samma commit.
3. Hämta validerad IPA och installera rent på iPhone 16 Pro med `app.mio.assistant`; prova iPhone 13 senare.
4. Kör [helhetstestet](TESTPLAN_HELHET.md) samt återstående [långtest](TESTPLAN_V0_1.md).
5. Registrera exakt revision, build, enhet och resultat i [status](STATUS.md). Åtgärda verkliga fel innan daglig tillit.

Versionsnumret 1.0.0 används först när accepterad vardagsomfattning är verifierad. Inget datum eller löfte om heldagslyssning ges utan mätningar. Appversion, byggnummer och lagringsschema är separata värden. `CURRENT_PROJECT_VERSION` höjs inför nästa distribuerade build; bundle identifier och beständiga lagringsvägar ändras inte.

Råljudslagring, molnöverföring utan aktiverat samtycke, dold profilering och tyst kalenderbokning ingår inte. Konton och serverdrift behövs enbart om användaren aktiverar AI.

## Identitet och design, 2026-09-26

Användaren har raderat prototypen. Appidentiteten är därför `app.mio.assistant` och lagringsmappen `Mio`, utan fasnamn, personnamn eller appversionsnummer. Ingen tidigare migrering behövs. Native Liquid Glass används för kontroller och navigation; innehållet har semantiska läsytor. Designen behöver visas och provas i verklig iOS, inte bara granskas i källkod.

Förtydligande 2026-09-26: lektionsläge och vanlig samtalstolkning är korrigeringar mot visionen. Första AI-leverantör är OpenAI; andra kan senare implementeras bakom serverns stabila appkontrakt. Driftsättning och verkliga modellprov återstår.

## Arbetskopians utökning 2026-09-28

Leverantörsadaptrar, strikt schema även för frågor och detaljerade lektionsanteckningar med kopiering/fortsättning finns i källkoden. Native ljudmotor och vardagsanalysens aktiveringsregler behålls. Ingen modellväljare, presentation eller frågekortsvy tillkommer. Nästa grindar är Xcode/XCTest för denna ändring, godkänd publicering av gatewayen, ny IPA och syntetiska modell-/telefonprov. Den publicerade äldre gatewayen och build 5 verifierar inte detta arbete.
