# Beslut och tekniska kontrakt

Gällande beslut samlade på ett ställe. [Ändringsloggen](../CHANGELOG.md) beskriver levererade ändringar; [status](STATUS.md) beskriver evidens.

| Beslut | Regel | Ursprung |
|---|---|---|
| Privat native-app | SwiftUI, iOS 26+, iPhone 16 Pro först och iPhone 13 senare; ingen App Store-distribution | 2026-08-20 |
| Lokalt ljudflöde | `SpeechAnalyzer` tar emot tidsatta buffertar och kör en transkriptionsmodul åt gången | 2026-08-20 |
| Ingen råljudslagring | Ljud bara tillfälligt i minnet; text, tider och diagnostik lokalt | 2026-08-20 |
| Explicit molnsamtycke | Framtida OpenAI-fråga kräver Ja, minsta kontext och API-nyckel på server | 2026-08-20 |
| Privat installation | Actions bygger osignerad IPA; SideStore signerar. Lokal Mac/Xcode är ett alternativ | 2026-08-20 |
| Enkel Git-rutin | Lokala ändringar granskas före commit/push; privata exporter lämnar aldrig sin privata lagringsplats för repot | 2026-08-20 |
| Manuella funktioner kan utvecklas parallellt | v0.2.0 kräver inte att heldagslyssning är godkänd; öppna långtest kvarstår | 2026-08-24 |
| Separata datalager | Poster, sessioner och assistentdata lagras separat; aktuella kontrakt beskrivs i datamodellen | 2026-08-24 |
| Bevarade original | Sessionstitel, anteckning och texträttningar läggs ovanpå originaltext, tider och bevis | 2026-08-24 |
| Resurs före modulstart | `SpeechTranscriber` endast efter installerad svensk assetstatus; separat installationsknapp | 2026-08-24 |
| Omedelbar fallback | Ingen modellhämtning vid sessionsstart; saknad resurs ger `DictationTranscriber`. Förberedelsefel ger ny analyzer | 2026-08-24 |
| Inga externa integrationer i v0.2.0 | Ingen OpenAI, EventKit, systemalarm eller konto; Kalender och Morgon är lokala vyer | 2026-08-24 |
| Gemensamt Xcode 27-bygge | Ett jobb på `xcode-27` är konfigurerat för Release, XCTest och osignerad IPA med iOS 27 SDK och lägsta iOS-version 26.0 | 2026-09-25 |
| Beständiga namn och versioner | Projektet heter Mio; produktmilstolpar använder v0.x.y enligt roadmapen | 2026-09-22 |

## Ny appidentitet och testtelefon, 2026-09-26

Det tidigare kompatibilitetsbeslutet ersätts efter användarens uttryckliga besked att prototypen är raderad. Bundle identifier är **`app.mio.assistant`**, testidentifierare `app.mio.assistant.tests` och lagringsmapp **`Mio`**. Ingen automatisk fas-migrering finns. Identifierare är stabila och versionsnumret ligger separat i Xcode.

Första enhetsprov sker på **iPhone 16 Pro**, senare på iPhone 13. Xcode 27-bygget och iOS 27-simulatorn behålls; minsta iOS-version är 26.0. En modell/OS-kombination verifierar inte en annan.

Liquid Glass används för centrala knappar och systemets navigation/flikar. Innehåll använder semantiska bakgrunder och färger. Dynamic Type, VoiceOver, Minska rörelse och Minska genomskinlighet ingår i telefonproven. Riktlinjer: [Apples material](https://developer.apple.com/design/human-interface-guidelines/materials), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## Enheten är facit

Det historiska provet använde `DictationTranscriber` med `sv_SE`; den svenska `SpeechTranscriber`-resursen kunde inte installeras då. Ny resurslogik är inte verifierad av det provet. Bakgrund, batteri och ljudavbrott måste provas på telefonen; en simulator ersätter inte det.

## Helhetsbeslut 2026-09-25

Användaren ersätter arbetet version för version med ett sammanhängande helhetsbygge och väljer att även bygga AI-klient och server, med molnet avstängt tills egen konfiguration finns. Regeln om inga integrationer i v0.2.0 gäller den historiska versionen; den begränsar inte helhetsbygget 0.9.0.

- Lokala frågor/förslag och lektionsmetadata har ett separat `assistant-v1.json`. Originalsessioner och `content-v1.json` behåller sina text-/bevisformat; den aktuella rotmappen är Mio enligt beslutet ovan. Gemensam export använder schema 2 och kan läsa äldre schema 1 utan assistantfält.
- Enkel svensk kommandogrammatik ger lokala utkast. Frågor till AI skiljs från innehållsförslag; inget föreslaget minne eller plan skrivs till innehållslagret utan Ja. Samma förslags-ID används vid omförsök för att undvika dubbletter.
- Ja/Nej/Inte nu är knappar i appen. Röstigenkänning av ett fristående ”ja” utlöser inga åtgärder. Tid i fri text måste granskas och väljas manuellt.
- Lektioner är redigerbara namn, anteckningar och intervall över avslutade sessioner. De delar eller ändrar aldrig originalsegment.
- Systemkalendern använder `EKEventEditViewController`: användaren granskar och sparar en fristående kopia. Ingen kalenderläsning eller automatisk tvåvägssynk. Kopian kan synkas av det valda kalenderkontot och raderas i Kalender.
- AlarmKit används för riktiga engångs-/veckoalarm med systemets stopp. Ingen egen nedräkning/snooze eller Live Activity-extension. Notiser är separata och följer systemets inställningar. Låsskärmtext innehåller inga privata postrubriker.
- Dagsöversikten visar sparade poster och antal sessioner/lektioner lokalt. Den ger inte sken av att vara en semantisk transkriptionssammanfattning.
- AI-klienten har ett explicit sändningsgodkännande per fråga. Kontext börjar tom och väljs/redigeras manuellt. Gatewaytoken ligger i Keychain, serveradress/aktiveringsval i egna UserDefaults; OpenAI-nyckeln ligger endast i serverns miljö. HTTPS krävs och redirect följs inte.
- Servern använder Responses API med `store: false`, auth, fasta storleks-/tidsgränser och förbrukningsgränser. Ingen textlogg eller beständig frågehistorik skrivs. Leverantörens egna datavillkor gäller fortfarande. Se [serverguiden](../server/README.md).
- En gemensam skrivspärr skyddar fullständig radering mot pågående/eftersläpande UI-skrivningar. En misslyckad systemavbrytning får inte rapporteras som lyckad total radering.

Referenser för plattformsval: [EventKitUI utan generell kalenderåtkomst](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [AlarmKit](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit), [Apples privacy-manifest](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest). SDK-kompatibiliteten måste slutligen verifieras av Xcode för aktuell revision.

## Korrigerat assistentflöde, 2026-09-26

Användaren har efter telefonprov bekräftat löpande analys av korta textutdrag efter uttrycklig aktivering, och vill ha tydliga systeminstruktioner med OpenAI först och möjlighet att byta leverantör senare. Detta förtydligar de äldre reglerna ovan:

- AI är av i varje ny app-process. Aktivering godkänner framtida vardagstext och text från lektioner som avslutas medan läget är på. En historisk lektion kräver ett separat val. Äldre vardagstext tas inte med vid aktivering, även när en vardagssession ligger pausad bakom en lektion.
- Vardagsutdrag samlas ungefär en minut, högst åtta fragment/10 000 byte per anrop. Paus/stopp kastar väntande vardagsanalys. Avstängning/radering avbryter relevanta anrop och sena svar får inte återskapa data. Redan skickad text/kostnad kan inte återkallas.
- Separat Starta lektion stoppar vardagens ljudflöde före lektionsstart. Efter avslut är vardags-Mio pausat tills Fortsätt Mio väljs. AI ger källkopplade delanteckningar; inget råljud sparas. Manuell historisk lektionsindelning bevaras men är inte det primära flödet.
- `/v1/analyze` lämnar endast validerade plan-/uppgifts-/anteckningsutkast och lektionspunkter. Inga automatiska minnen, verktyg eller externa åtgärder. Datum tolkas mot källtid/tidszon, saknade tider är null, och användaren måste kontrollera tid före godkännande av AI-planer/uppgifter.
- Serverns `prompts.mjs` skiljer vardag, lektion, källmaterial och instruktioner. `provider.mjs` isolerar OpenAI-anrop och svarstolkning. Endast OpenAI-adaptern är implementerad; modell väljs i servermiljön. Byte kräver modellprov, inte enbart ändring av URL.
- För enskilda frågor gäller fortfarande exakt sändningspreview. Gatewaytoken ligger i Keychain och hålls dessutom i arbetsminnet under det aktiverade analysläget för låst skärm. Ändrad anslutning stänger av läget. API-nyckeln finns bara på servern.

Källcitat och schema är tekniska kontroller, inte ett bevis på semantisk korrekthet eller skydd mot alla promptinjektioner. Modellens verkliga urval och svenska datumtolkning måste provas med syntetiska exempel före vardagsbruk.
