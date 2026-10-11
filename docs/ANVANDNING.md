# Använd Mio

Detta är guiden för helhetsbygget 0.9.0. Koden behöver först byggas och installationen provas enligt [installation](INSTALLATION.md) och [helhetstest](TESTPLAN_HELHET.md).

## Första gången

Öppna de fem flikarna. Du kan skriva manuella poster direkt, utan mikrofon, notiser eller AI. **Inställningar → Så använder du Mio** innehåller en kort guide i appen.

Öppna kugghjulet på valfri flik → **Transkription**. Spara din privata `https://…ts.net`-adress och token, se sparbekräftelsen och testa anslutningen. Datorn måste vara igång med Pianissimo och Tailscale; iPhone ska vara ansluten till samma tailnet. Följ [driftguiden](../transcription-server/README.md). Det finns ingen Apple-talmodell att installera i det nya bygget.

**Ansluten** visar senast lyckade kontakt. **Ansluter** visas under anslutningskontroll. Vid **Offline** försöker en aktiv session igen automatiskt; högst 60 s ljud kan vänta i RAM. Äldre ljud tappas med synlig lucka. Efter stopp kan du behöva Testa anslutning för en färsk kontroll. iOS-ljudavbrott kan kräva Fortsätt; efter appens tvångsavslutning startas aldrig mikrofonen automatiskt.

Mikrofon, transkriptionsanslutning och text-AI visas separat. En aktiv mikrofon kan alltså fånga ljud medan servern är offline. Vid paus/stopp stängs mikrofonen först; redan fångad sluttext kan avslutas under högst 15 sekunder, fortfarande inom ljudets ursprungliga 60-sekundsgräns. Du kan avbryta väntan. Efter ljudavbrott, ljudvägsbyte eller reset väljer du själv Fortsätt när iOS tillåter; inte heller en tidsvald paus startar mikrofonen automatiskt.

## Fånga och ordna

1. Tryck **Starta Mio** och tillåt mikrofonen. Paus/stopp stänger mikrofonen.
2. Öppna **AI-assistent** och aktivera löpande AI-tolkning när servern är konfigurerad. Säg exempelvis ”Vi ses på biblioteket på tisdag klockan 15”. Mio-tilltal behövs inte i detta läge. Utdrag samlas ungefär en minut; granska förslagen i inkorgen.
3. Tryck **Starta lektion**, ange ämne och starta. Vardags-Mio pausas. Ljudet transkriberas privat på din dator; texten sparas lokalt utan ljudfil.
4. Välj **Avsluta lektionen**. Med AI aktiverad bearbetas texten i delar till huvudpunkter, exempel och läxförslag. Läs dem i **Lektioner**, öppna Textunderlag för att kontrollera citatet. AI kan missa eller misstolka viktigt innehåll.
5. Tryck **Fortsätt Mio** för att återuppta den pausade vardagslyssningen. Mikrofonen startar inte automatiskt efter lektionen.
6. **Lektioner → Historik och råtext** innehåller tidigare sessioner, manuella poster, texträttningar och äldre manuell lektionsindelning. Inga tidigare data är borttagna.

Spela bara in andra med tydligt samtycke och enligt lokala regler. Paus/stopp ska släcka iOS mikrofonindikator. Långvarig drift med låst skärm behöver verifieras på din telefon; tvångsavslutning startar aldrig om lyssningen automatiskt.

## Be Mio föreslå något

Säg till exempel:

- **Mio, anteckna att vi arbetar med procent.**
- **Mio, påminn mig att ta med boken.**
- **Mio, planera tandläkaren.**
- **Mio, kom ihåg att jag föredrar blå pennor.**

Tydliga Mio-kommandon blir lokala frågor i **Mio → Förslag att granska**. Vanlig konversation blir inte automatiskt ett minne. Du kan även använda plusknappen i inkorgen för att skriva ett förslag själv, eller **Hitta lokala Mio-förslag** inne i en sparad session.

Öppna frågan och kontrollera **typ, rubrik, text, datum och tid**. Lokala kommandon tolkar inte datum. AI kan föreslå en tid, men du måste markera att datum och tid är kontrollerade före Ja för AI-planer/uppgifter. Om klockslag saknas ber Mio dig välja det.

Om underlaget kompletteras medan du granskar kan Mio be dig granska den nya versionen. Dina redigerade utkastfält behålls. Ändring av relevanta fält återställer datumkontrollen; en saknad tid ska väljas uttryckligen och får inte råka bli ”nu”.

- **Ja, spara:** skapar posten i Mio. Alarm, notiser och kalenderkopior aktiveras separat.
- **Nej, glöm förslaget:** tar bort frågan. Originaltexten i sessionen finns kvar tills du raderar sessionen.
- **Inte nu:** behåller frågan i inkorgen till senare.

I förgrunden kan upptäckt av Mio ge vibration. Frågor kan behöva granskas genom att du öppnar appen när den har varit i bakgrunden.

## Anteckningar, uppgifter och minnen

Använd plusknappen i **Anteckningar** eller historikvyn. Välj typ och fyll i rubrik, text och tid. Du kan koppla posten till en session. Sökningen hittar även svenska ord utan diakritiska tecken, exempelvis `ovning` för `Övning`.

Markera uppgifter klara eller öppna dem igen. Synliga minnen kan ändras och raderas som andra poster. Mio skapar ingen dold profil.

## Kalender och påminnelser

Skapa först en plan i **Kalender** eller en uppgift i **Anteckningar**. Öppna den sparade posten:

- **Lägg en kopia i Kalender:** granska uppgifterna i Apples editor och spara eller avbryt. Kontrollera kalender, start/slut och eventuell notifiering där. Kopian är fristående och kan synkas via kalenderkontot.
- **Påminn mig om posten:** välj en framtida tid och spara. Notisbehörighet frågas första gången. Notiser följer iPhones fokus- och ljudinställningar.
- **Skapa eller ändra postens alarm:** välj tid och spara. AlarmKit frågar om separat alarmbehörighet.

Ändringar av Mio-posten uppdaterar inte automatiskt systemtider eller kalenderkopian. Öppna motsvarande kontroll för att ändra dem. Om du raderar en Mio-post avbryts dess Mio-alarm/notis; kalenderkopior tas bort i Kalender.

Under **Inställningar → Alarm, notiser och behörigheter** kan du skapa fristående alarm, välja veckodagar, se kommande notiser och ta bort dem. Låsskärmen visar generell Mio-text. Prova ett alarm ett par minuter framåt innan du förlitar dig på det.

## Morgon och kväll

**Morgon** visar dagens planer, uppgifter och sådant som ligger kvar sedan tidigare. Byt till **Kväll** för avklarade uppgifter, anteckningar och dagens sessions-/lektionstal. Välj datum för en annan dag.

Översikten räknar och visar sparat innehåll lokalt och uppdateras när du återvänder till appen, vid dagbyte och ändrad tidszon. En uttryckligen vald historisk dag behålls vid vanlig uppdatering. Dagliga påminnelser för morgon och kväll ställs in i **Alarm och dagliga påminnelser**; de visar generell text och öppnar dagens motsvarande översikt. En postnotis öppnar den lokala posten; om den är raderad går du säkert tillbaka till dagsfliken. Ingen notisöppning startar mikrofon, AI eller en systemåtgärd.

## Valfri AI

Det finns två separata flöden. **AI-assistent → Aktivera AI-tolkning** ger samtycke till löpande nya vardagsutdrag och lektioner du avslutar medan läget är på. Läget återställs till av när app-processen startar om. Paus/stopp kan slutföra redan godkänd vardagssluttext och bryter kontexten inför Fortsätt; text före aktiveringen eller över en ljudlucka tas inte med som bakåtkontext. Stäng av AI-tolkning stoppar väntande analys, inklusive lektionskön. Redan skickad text kan inte återkallas. Vid nät-/gräns-/konfigurationsfel stoppas läget och behöver aktiveras igen manuellt. En sparad lektion som inte analyserats kan skickas med ett separat godkännande från dess detaljvy.

**Testa text-AI-anslutning** under anslutningsinställningarna gör ett modellfritt statusanrop. Det visar autentisering, protokoll, gatewayrelease, serverns profiler för fråga/vardag/lektion och delad dagskvot om servern har en. Giltig konfiguration bevisar inte leverantörens API-behörighet, modellåtkomst eller svensk kvalitet. Okänd återstående kvot betyder just okänd, inte noll. Uppgifterna delar serverns minutgräns och eventuell dagsgräns; visat återstående lektionsarbete är en uppskattning, inte reserverad kapacitet.

För **enskilda frågor** följer du stegen nedan:

Manuellt innehåll fungerar utan server. Transkription använder din Pianissimo-server. Om du vill aktivera AI:

1. Sätt upp den medföljande servern enligt [Cloudflare-guiden](../server/README.md) utan påslagen egen dator, eller [serverguiden](../server/README.md) för egen värd, med leverantörens API-nyckel enbart på servern.
2. Öppna **Inställningar → AI-assistent → Anslutning för text-AI**. Ange din HTTPS-adress och åtkomsttoken: exakt samma hemliga värde som Workerns `MIO_GATEWAY_TOKEN`, utan `Bearer`. Efter rotation ska det nya värdet sparas även här. Spara anslutningen och slå på **Tillåt molnfrågor**.
3. Öppna **Mio → Fråga Mio med AI** och skriv frågan. Välj vid behov enstaka poster eller ett kort sessionsutdrag. Korta och rensa texten som ska skickas.
4. Tryck **Granska innan du skickar**. Mio kan kontrollera anslutningen utan att skicka fråga eller källtext. Läs mottagare, vald serverprofil/release, exakt fråga och exakt kontext.
5. Välj **Ja, skicka denna fråga till molnet**. Först då skickas den granskade texten till modellen. Avbryt i stället om du inte vill dela texten. Om serverns konfiguration ändrats behöver du granska på nytt; Mio skickar inte om frågan automatiskt.

Svaret kan innehålla fel och utför inga åtgärder. Det är tillfälligt och försvinner när du lämnar frågevyn. Vill du behålla det väljer du **Granska och spara som anteckning**, redigerar rubrik/text och trycker **Spara anteckning lokalt**. Det skapar en vanlig lokal anteckning utan nytt AI-anrop eller frågehistorik; upprepat Spara skriver inte över senare redigeringar. En skickad fråga kan inte återkallas. Mios gateway skriver inga fråge-/svarstextloggar; leverantörens och eventuell mellanliggande gateways datavillkor gäller. Du stänger av och tar bort anslutningen med **Glöm anslutning och stäng av**.

## Exportera och radera

Stoppa sessionen och gå till **Inställningar → Integritet, export och radering → Skapa lokal export**. Dela/spara JSON-filen privat. Exporten innehåller innehåll, sessioner, förslag, lektioner, AI-anteckningar och diagnostik; aldrig råljud eller åtkomsttoken. Det finns ingen importknapp i detta bygge.

**Radera all lokal data** tar efter bekräftelse bort de tre domänlagren, diagnostik, interna exportkopior, egna alarm/notiser och båda serveranslutningarna. En liten journal med bara ID:n och avslutade steg gör att en avbruten radering kan fortsätta efter omstart. Ett fel kan innebära att vissa steg redan är utförda. Följ bannertexten och välj **Försök slutföra raderingen igen**; andra ändringar och AI-sändningar väntar tills raderingen är klar. Redan delade filer, skickade molnfrågor och kalenderkopior kan inte återkallas av detta. Kvarvarande systemåtgärder ska hanteras innan raderingen kan slutföras.

## Nya AI-val och detaljerade lektionsanteckningar

Detta gäller arbetskopians nya kod; befintlig build 5 behöver ersättas med en ny verifierad IPA och gatewayen behöver uppdateras.

**Byta modell eller leverantör:** följ [Cloudflare-guiden](../server/README.md); tillåtna modeller står i [katalogen](../server/README.md). Modell och API-nyckel ändras på servern; appens adress och gatewaytoken behålls. Reasoning är av, temperatur 0 och strikt JSON används automatiskt. Modellens JSON visas som vanliga anteckningar och förslag i appen.

Servern kan ha olika kompatibla profiler för enskild fråga, vardag och lektion. Gör det modellfria anslutningsprovet efter ett byte och aktivera/granska på nytt. Det finns ingen modellväljare i appen eller tyst reservmodell.

**Lektion:** tryck Starta lektion, avsluta när undervisningen är slut och öppna lektionen i Lektioner. Med godkänd AI-tolkning kan bearbetningen starta efter avslut; annars aktiverar du AI och väljer **Skapa eller fortsätt detaljerade anteckningar …** samt godkänner sändningen. Låt appen vara öppen medan den bearbetar textdelarna. Du ser antal bearbetade textdelar, detaljerade rubriker/anteckningar och öppningsbara källcitat. Läxor granskas separat med Ja/Nej/Inte nu.

Tryck **Kopiera hela anteckningen** och klistra in den hos valfri AI för att exempelvis få en förklaring eller skapa frågekort. Mio skapar inga sådana läromedel själv. Kopieringen är vanlig läsbar text med rubriker; den innehåller också osäkerheter och tydlig markering om delar återstår. Även när alla delar är bearbetade måste AI-utkastet granskas mot underlaget.

Efter nätfel, kvotfel eller omstart: färdiga detaljerade delar finns kvar. Vänta vid kvotfel, aktivera AI igen och fortsätt från samma lektionsknapp. Redan färdiga delar skickas inte om. Äldre korta huvudpunkter finns kvar separat men räknas inte som detaljerade anteckningar. Mycket långa lektioner kan kräva flera godkända omgångar (högst 100 delar i kön per omgång).

Om du rättar textunderlaget senare visas att anteckningarna bygger på **äldre text**; när revisionsunderlag saknas anges **okänd aktualitet**. Sparade delar/citat bevaras och rättningen skickas inte automatiskt igen. Kopierad anteckning behåller dessa varningar, ofullständiga delar och eventuella ljudluckor. Granska underlaget även när alla delar är bearbetade.

För [tokens, leverantörsbyte och Cloudflare Access](../server/README.md) finns en sammanhängande steg-för-steg-guide. Access kräver den nya appens separata Client ID-/Client Secret-fält; de finns inte i build 5.
