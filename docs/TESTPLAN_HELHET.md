# Testa hela Mio

Gäller helhetsbygget 0.9.0. Testerna är instruktioner, inte körresultat. Använd syntetiska uppgifter och röster från personer som samtycker. Registrera resultat i [status](STATUS.md).

## Före installation

1. Kör `python3 scripts/verify_project.py` och `npm test --prefix server` i arbetskopian.
2. Bygg exakt avsedd commit i GitHub Actions: Release, XCTest och IPA-validering ska lyckas. Dokumentera faktisk runner, körnings-URL och commit. En gammal grön körning räcker inte.
3. Spara IPA:ns SHA-256 och versions-/byggnummer från artifactens `Mio-buildinfo.txt`.
4. Installera rent med `app.mio.assistant` på iPhone 16 Pro. Ingen gammal prototypdata förväntas. Prova senare också på iPhone 13.
5. Notera telefonmodell och exakt iOS-version. Prova iOS 26 och 27 separat om båda ska stödjas i praktiken.

## Första sammanhängande provet, cirka 20 minuter

| ID | Gör så här | Förväntat |
|---|---|---|
| H01 | Öppna en ren installation. Skapa en manuell post och en kort session, stoppa och starta om appen. | Data finns kvar efter omstart. Ingen mikrofon eller molnfråga startas av sig själv. |
| H02 | Öppna alla fem flikar. Skapa anteckning, uppgift, plan, uttryckligt minne och tidslinjepost. Prova tom rubrik. | Giltiga poster sparas, tom rubrik avvisas. Svensk sökning `ovning` hittar `Övning`. |
| H03 | Starta session, säg ”Vi arbetar med procent. Mio, anteckna att vi behöver öva mer.” | Svensk text visas. Förslaget syns i inkorgen. I förgrunden kan Mio ge vibration. Ingen post eller systemåtgärd skapas ännu. |
| H04 | Säg ”Mio, påminn mig att ta med boken”, ”Mio, planera tandläkaren” och ”Mio, kom ihåg att jag föredrar blå pennor”. | Förslag får rätt typ. Datumet måste väljas i granskningen; fri text skapar ingen dold tidsbokning. |
| H05 | Ändra rubrik och tid på ett förslag; välj Ja. Välj Inte nu på ett annat och Nej på ett tredje. Öppna om sessionen och välj Hitta lokala Mio-förslag. | Exakt en godkänd post. Uppskjuten fråga finns kvar efter omstart. Avvisat förslag återkommer inte från samma textdel. Originaltranskript finns kvar. |
| H06 | Pausa, fortsätt och stoppa. Kontrollera mikrofonindikatorn. | Paus/stopp släcker mikrofonen. Ingen text tillkommer från nytt ljud när Mio är av. |
| H07 | Öppna stoppad session, rätta en textdel, skapa två lektioner med angränsande intervall. Prova en överlappning och ett intervall utanför sessionen. | Giltiga indelningar sparas; felaktiga avvisas. Sekundkontroller fungerar i ett kort prov. Originaltext och ljudtider bevaras i exporten. |
| H08 | Öppna sparad plan → Lägg en kopia i Kalender. Avbryt första gången; spara andra gången. | Bara den sparade kopian finns i vald kalender. Mio läser inte hela kalendern. Ändrad lokal plan ändrar inte kalenderkopian. |
| H09 | Skapa en postpåminnelse två minuter framåt och lås telefonen. | Tillstånd efterfrågas vid Spara. Notisen har generell text och följer fokus-/ljudinställningar. |
| H10 | Skapa ett alarm två minuter framåt. Lås telefonen och prova även med Fokus/tyst läge. Stoppa alarmet; skapa och ta bort ett veckoalarm. | Systemalarmet visas/ljuder enligt telefonens AlarmKit-beteende. Stoppa och avbryt fungerar. Inga privata posttexter på låsskärmen. |
| H11 | Skapa dagens plan, öppen uppgift och avklarad uppgift. Öppna Morgon, byt till Kväll och välj annat datum. Spara och avbryt dagliga påminnelser. | Dagens lokala data visas korrekt, klarstatus ändras och notislistan speglar iOS. Ingen automatisk mikrofonstart. |
| H12 | Slå på flygplansläge. Skapa, sök, redigera och radera lokal data. | Lokala funktioner fungerar; befintliga modeller krävs för tal. AI misslyckas begripligt utan automatisk retry. |
| H13 | Skapa lokal export. Inspektera privat JSON. | `schemaVersion: 2`, `content`, `sessions` och `assistant` finns. Original och correctedText är separata. Inga ljuddata, token eller API-nycklar. |
| H14 | Radera en post med alarm/notis. Radera en session med lektioner/förslag och kopplad manuell post. | Postens systemåtgärder avbryts. Sessionsdata, dess lektioner och förslag försvinner; manuell post finns kvar utan trasig sessionskoppling. Kalenderkopior finns kvar separat. |
| H15 | Med enbart testdata: Radera all lokal data och starta om. | Alla tre datalager är tomma, egna alarm/notiser borta, AI avstängd och token glömd. Ingen sen återkoppling återskapar data. Delade filer och kalenderkopior måste tas bort där de finns. |

## AI-prov efter egen serverkonfiguration

Använd [serverguiden](../server/README.md). Verkliga OpenAI-anrop kan kosta pengar och kräver din konfiguration. Kör först serverns mockade testsvit, sedan dessa telefonprov med en ofarlig fråga.

| ID | Prov | Förväntat |
|---|---|---|
| AI01 | Ny installation eller glömd anslutning. Öppna AI-vyn utan att aktivera. | Molnet är av. Inga nätanrop sker vid visning eller konfigurationssparning. |
| AI02 | Ange HTTPS-server och separat gatewaytoken; aldrig OpenAI-nyckeln i appen. Slå på, skriv fråga och välj ett litet syntetiskt utdrag. | Urval börjar tomt. Preview visar exakt fråga, etiketter, utdrag och mottagare. Redigering av kopian ändrar inte originalet. |
| AI03 | Avbryt preview, öppna igen och skicka uttryckligen. | Avbryt skickar inget. Skicka ger ett svar utan att skapa eller ändra någon lokal post/systemåtgärd. |
| AI04 | Säg ”Mio, fråga varför himlen är blå”. Välj Inte nu, öppna senare och gå vidare till AI-granskning. | Röstfrågan stannar lokalt i inkorgen tills du väljer att skicka. Ingen kontext följer med automatiskt. Fel/avbryt lämnar frågan väntande; lyckat svar avför den. |
| AI05 | Prova fel token, frånkopplat nät, för långt utdrag och en server som svarar med redirect. Avbryt även medan svar inväntas. | Begripliga fel; ingen credential/privat text skickas till redirectmål; ingen automatisk retry eller sent svar efter avbryt. |
| AI06 | Glöm anslutningen och försök igen. Radera all lokal data medan andra vyer tidigare varit öppna. | Molnet är avstängt. Inga gamla frågor/utdrag eller svar ligger kvar i öppen AI-vy; token ingår aldrig i export. |

## Felvägar och tillgänglighet

- Neka mikrofon-, notis- och alarmbehörigheter var för sig. Manuella funktioner ska fortfarande fungera. En vanlig post utan systemåtgärder ska gå att radera; kvarvarande systemalarm får inte döljas som lyckad radering.
- Prova stora Dynamic Type-storlekar och VoiceOver på iPhone 16 Pro och senare iPhone 13. Prova ljust/mörkt läge, Minska rörelse och Minska genomskinlighet. Glassessionsknappar, systemflikar och navigation ska förbli läsbara med tydliga tryckytor. Ja/Nej/Inte nu, datum, spara, avbryt och destruktiva bekräftelser ska gå att nå.
- Prova många snabba tryck, byte av flik medan sparande pågår, upprepad export och radering. Dubbeltryck får inte skapa dubbletter. Radering ska vänta/avvisas begripligt när en skrivning pågår.
- XCTest täcker okänt schema, idempotent godkännande, relationer, JSON-kompatibilitet, raderingsspärr och sen detektion. Kör dem med Xcode; läsbar testkod är inte bevis för ett körresultat.
- Prova dagbyte, sommartidsbyte och ändrad tidszon för dagens listor, veckoalarm och dagliga notiser. Ingen daglig notis får innehålla känslig text.

## Långprov och acceptans

Kör [transkriptions- och långtestet](TESTPLAN_V0_1.md): låst skärm minst 10 minuter, batteri minst 60 minuter utan laddare, ljudavbrott och ljudvägsbyte. Först därefter ett 3–4-timmarsprov. Gamla mätningar i [historiken](TESTRESULTAT_V0_1.md) bevaras.

Anteckna **Godkänd / Underkänd / Blockerad / Ej körd** per test med commit, Actions-URL, IPA-hash, version/build, telefon och iOS. En installerad app är inte automatiskt telefonverifierad, och gröna mocktester verifierar inte en verklig OpenAI-server. Börja vardagsanvändning först efter godkända kärnflöden och dokumenterade accepterade begränsningar.
