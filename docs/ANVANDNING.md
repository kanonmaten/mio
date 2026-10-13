# Använd Mio

Detta är guiden för helhetsbygget 0.9.0. Koden behöver först byggas och installationen provas enligt [installation](INSTALLATION.md) och [helhetstest](TESTPLAN_HELHET.md).

## Första gången

Flikfältet har tre flikar, **Hem**, **Lektioner** och **Förslag**, och längst till höger en rund mikrofonknapp, **Fånga**. Knappen öppnar Fånga men startar aldrig mikrofonen själv. Från 0.9.1 sparar Apples appar det Mio fångar: händelser i Kalender, att göra i Påminnelser och anteckningar och minnen i Anteckningar. **Inställningar → Så använder du Mio** innehåller en kort guide i appen.

Alla inställningar finns i en panel som glider in från höger: tryck kugghjulet uppe till höger eller svep in från skärmens högra kant. Stäng med **Klar**, ett tryck utanför eller ett svep åt höger. Panelen är en enda sida med avsnitten Dator, AI, Lektioner, Notiser, Mio, Integritet och data samt Om.

**Para datorn:** kör `mio-pair` på datorn ([gatewayguiden](../server/README.md)) och välj **Dator → Skanna QR-kod**. Kameran används bara för koden. Koden innehåller datorns Tailscale-adress och tokens för AI-gatewayen och, om den finns, Pianissimo. Tokens sparas i nyckelringen. Fungerar inte kameran: **Ange uppgifterna manuellt** med värdena från `mio-pair --text` (transkriptionen är valfri). Efter parningen kontrollerar Mio datorn utan att skicka ljud eller använda AI-kvot och visar resultatet. Första gången visas en kort påminnelse om samtycke när du spelar in andra. Datorn måste vara igång med Tailscale; iPhone ska vara i samma tailnet. Se [driftguiden](../transcription-server/README.md) för Pianissimo.

**Ansluten** visar senast lyckade kontakt. **Ansluter** visas under anslutningskontroll. Vid **Offline** försöker en aktiv session igen automatiskt; högst 60 s ljud kan vänta i RAM. Äldre ljud tappas med synlig lucka. Efter stopp kan du behöva Testa anslutning för en färsk kontroll. Efter ett iOS-ljudavbrott startar Mio mikrofonen igen själv; efter appens tvångsavslutning startas den aldrig automatiskt.

Mikrofon, transkriptionsanslutning och text-AI visas separat. En aktiv mikrofon kan alltså fånga ljud medan servern är offline. Vid paus/stopp stängs mikrofonen först; redan fångad sluttext kan avslutas under högst 15 sekunder, fortfarande inom ljudets ursprungliga 60-sekundsgräns. Du kan avbryta väntan. Efter samtal, Siri, ljudvägsbyte eller reset startar Mio mikrofonen igen av sig själv och markerar luckan i transkriptet. Nekar iOS det i bakgrunden får du notisen "Tryck för att fortsätta lyssna"; Mio fortsätter när appen öppnas. Nekas det på skärmen, eller efter tre omstarter på en minut, väljer du Fortsätt. Din egen paus eller ditt stopp ångras aldrig automatiskt, inte heller en tidsvald paus.

## Fånga och ordna

1. Öppna **Fånga**, tryck **Starta Mio** och tillåt mikrofonen. Paus/stopp stänger mikrofonen. Medan en session pågår visar lyssningsraden ovanför flikfältet en diskret prick och läget (**Lyssnar**, **Lektion** eller **Pausad**) med paus/fortsätt; tryck på raden för att öppna Fånga. Raden kräver iOS 26.1; på 26.0 visar Live Activity läget.
2. AI är på när datorn är parad. Säg exempelvis ”Vi ses på biblioteket på tisdag klockan 15”; Mio-tilltal behövs inte. Nytt vardagstal samlas och skickas högst var femte minut. Granska förslagen via **N att granska** på Hem.
3. Tryck **Starta lektion**, ange ämne och starta. Vardags-Mio pausas. Ljudet transkriberas privat på din dator; texten sparas lokalt utan ljudfil.
4. Välj **Avsluta lektionen**. Med AI aktiverad bearbetas texten i delar till huvudpunkter, exempel och läxförslag. Läs dem i **Lektioner**, öppna Textunderlag för att kontrollera citatet. AI kan missa eller misstolka viktigt innehåll.
5. Tryck **Fortsätt Mio** för att återuppta den pausade vardagslyssningen. Mikrofonen startar inte automatiskt efter lektionen.
6. **Lektioner → Historik och råtext** innehåller tidigare sessioner, manuella poster, texträttningar och äldre manuell lektionsindelning. Inga tidigare data är borttagna.

Spela bara in andra med tydligt samtycke och enligt lokala regler. Talarmärkningen på din dator analyserar rösterna för att skilja talare åt (talare 1–4). Det sker bara i datorns RAM och raderas när sessionen avslutas eller efter 10 minuter, men det är ändå en analys av andras röster: berätta det när du ber om samtycke, och stäng av den på servern (`MIO_SPEAKER_LABELS=0`) om någon inte vill. Paus/stopp ska släcka iOS mikrofonindikator. Långvarig drift med låst skärm behöver verifieras på din telefon; tvångsavslutning startar aldrig om lyssningen automatiskt.

## Be Mio föreslå något

Säg till exempel:

- **Mio, anteckna att vi arbetar med procent.**
- **Mio, påminn mig att ta med boken.**
- **Mio, planera tandläkaren.**
- **Mio, kom ihåg att jag föredrar blå pennor.**

Tydliga Mio-kommandon blir lokala frågor i fliken **Förslag**, som du också når med **N att granska** på Hem. Vanlig konversation blir inte automatiskt ett minne. Inne i en sparad session finns **Hitta lokala Mio-förslag**.

Öppna frågan och kontrollera **typ, rubrik, text, datum och tid**. Lokala kommandon tolkar inte datum. AI kan föreslå en tid, men du måste markera att datum och tid är kontrollerade före Ja för AI-förslag på händelser och att göra. Texten är det du sa i transkriptet, inte AI:ns ord. Hörs en dag men inget klockslag föreslås **Heldag**; säger du klockslaget senare uppdateras förslaget. Saknas dagen ber Mio dig välja den.

Om underlaget kompletteras medan du granskar kan Mio be dig granska den nya versionen. Dina redigerade utkastfält behålls. Ändring av relevanta fält återställer datumkontrollen; en saknad tid ska väljas uttryckligen och får inte råka bli ”nu”.

- **Ja** skickar förslaget till rätt app:
  - **Händelse:** Kalenders egen ruta öppnas med rubrik, tid eller heldag, det du sa och en länk ifyllda. Välj kalender och notis och tryck **Lägg till**. Mio behöver ingen kalenderbehörighet och läser aldrig kalendern.
  - **Att göra:** påminnelsen skapas direkt i den lista du valt, med eller utan förfallodag och med notis vid klockslaget. Första gången frågar iOS om Mio får använda Påminnelser; Apple har ingen behörighet som bara skriver. Nekar du ligger förslaget kvar med en knapp till Inställningar.
  - **Anteckning och Minne:** dela-arket öppnas med texten. Välj **Anteckningar** och en ny eller befintlig anteckning.
- **Nej, glöm förslaget:** tar bort frågan. Originaltexten i sessionen finns kvar tills du raderar sessionen.
- **Inte nu:** behåller frågan i inkorgen till senare.

I förgrunden kan upptäckt av Mio ge vibration. Frågor kan behöva granskas genom att du öppnar appen när den har varit i bakgrunden.

## Skickat och länken tillbaka

Under **Förslag → Skickat** ser du vart varje godkänt förslag gick, när och från vilken session. Ändra, bocka av och radera i Kalender, Påminnelser eller Anteckningar; Mio sparar ingen kopia av text, datum eller status. **Glöm** tar bara bort Mios notering.

Länken `mio://session/…` i händelsen, påminnelsen eller anteckningen öppnar sessionen i Mio. Den startar aldrig mikrofon eller AI.

När du uppdaterar till 0.9.1 raderas en gång dina gamla lokala anteckningar, uppgifter, planer och minnen, samt Mios alarm och postpåminnelser. Exportera före uppdateringen om något ska sparas. Morgon- och kvällsnotisen finns kvar under **Inställningar → Notiser**.

## Hem

Hem är veckoplaneraren. Rubriken är veckonumret, till exempel **v. 41**. Under den finns veckans sju dagar, med i dag inringad och små streck för hur mycket som hänt. Tryck på en dag för att se den, byt vecka med pilarna och tryck **I dag** för att komma tillbaka.

- **Nästa** visar nästa påminnelse i dag (även heldag) eller den äldsta som ligger kvar, eller **Starta Mio** när inget finns. Mio läser inte Kalender, så händelser visas inte här.
- **N att granska** öppnar förslagsinkorgen.
- Dagens översikt har **Morgon** och **Kväll**. Morgon visar dagens att göra från Påminnelser och det som ligger kvar sedan tidigare. Kväll visar det du skickat till Apples appar och dagens antal sessioner och lektioner. Från kl. 17 visar Hem kvällen.
- **Tolv veckor** är ett rutnät över dagar då du använt Mio. Det räknar bara sessioner och skickade förslag och läser ingen text.

**Fråga Mio** finns uppe till vänster på Hem och Fånga.

Påminnelserna läses när Hem visas, när du återvänder till appen och när de ändras i Påminnelser; de sparas aldrig i Mio. En uttryckligen vald historisk dag behålls vid vanlig uppdatering. Dagliga notiser för morgon och kväll ställs in under **Inställningar → Notiser**; de visar generell text och öppnar Hem med morgon- respektive kvällsöversikten. En gammal postnotis från före 0.9.1 öppnar Hem. Ingen notisöppning startar mikrofon, AI eller en systemåtgärd; undantaget är **Tryck för att fortsätta lyssna**, som öppnar Fånga och fortsätter en session du själv startat.

## AI

AI är på från början när datorn är parad (beslut 2026-10-11) och startar när appen öppnas. Pausa med reglaget på **Fånga** eller under **Inställningar → AI**; pausen sparas tills du slår på AI igen. Ingen text skickas medan AI är pausad.

- **Vardag:** nytt vardagstal samlas och skickas högst var femte minut, så att en dags lyssning ryms i Groqs gratiskvot (200 000 token per dygn). Paus/stopp skickar redan fångad text direkt.
- **Lektioner:** delarna skickas med minst 60 sekunder emellan.
- **Kvot:** när datorn svarar 429 (även `local_token_limit`) väntar Mio enligt `Retry-After` och visar **AI fortsätter kl. HH:MM**. Vid en lång paus hoppas vardagstalet under pausen över; texten finns kvar lokalt. Svarar inte datorn försöker Mio igen efter fem minuter.
- **Förslag** sparas fortfarande först när du väljer Ja.

**Kontrollera anslutningen** under Dator och **AI → Kapacitet och uppgifter** gör modellfria statusanrop: gatewayversion, profiler och återstående dagskvot. De bevisar inte modellens svarskvalitet.

**Enskilda frågor:** tryck **Fråga Mio** på Hem eller Fånga. Upp till tre färdiga frågor, byggda på telefonen från senaste lektionen och nästa händelse eller att göra-post, kan fylla i textfältet; inget skickas förrän du själv skickar. Skriv eller ändra frågan, välj vid behov enstaka poster eller sessionsutdrag och tryck **Skicka frågan**. Frågan skickas direkt utan förhandsgranskning; svaret valideras innan det visas. Svaret kan innehålla fel och utför inga åtgärder. Det försvinner när du lämnar vyn om du inte väljer **Granska och spara som anteckning**. En skickad fråga kan inte återkallas.

## Exportera och radera

Stoppa sessionen och gå till **Inställningar → Integritet och data → Export, radering och behörigheter → Skapa lokal export**. Dela/spara JSON-filen privat. Exporten innehåller innehåll, sessioner, förslag, lektioner, AI-anteckningar och diagnostik; aldrig råljud eller åtkomsttoken. Det finns ingen importknapp i detta bygge.

**Radera all lokal data** tar efter bekräftelse bort de tre domänlagren, diagnostik, interna exportkopior, egna notiser och datorns parning. En liten journal med bara ID:n och avslutade steg gör att en avbruten radering kan fortsätta efter omstart. Ett fel kan innebära att vissa steg redan är utförda. Följ bannertexten och välj **Försök slutföra raderingen igen**; andra ändringar och AI-sändningar väntar tills raderingen är klar. Redan delade filer, skickade molnfrågor och det du skickat till Kalender, Påminnelser och Anteckningar påverkas inte. Kvarvarande systemåtgärder ska hanteras innan raderingen kan slutföras.

## Nya AI-val och detaljerade lektionsanteckningar

Detta gäller arbetskopians nya kod; befintlig build 5 behöver ersättas med en ny verifierad IPA och gatewayen behöver uppdateras.

**Byta modell eller leverantör:** följ [gatewayguiden](../server/README.md). Modell och API-nyckel ändras på datorn; telefonens parning behålls. Reasoning är av, temperatur 0 och strikt JSON används automatiskt. Modellens JSON visas som vanliga anteckningar och förslag i appen.

Servern kan ha olika kompatibla profiler för enskild fråga, vardag och lektion. Gör det modellfria anslutningsprovet efter ett byte och aktivera/granska på nytt. Det finns ingen modellväljare i appen eller tyst reservmodell.

**Lektion:** tryck Starta lektion, avsluta när undervisningen är slut och öppna lektionen i Lektioner. När AI är på startar bearbetningen efter avslut; annars väljer du **Skapa eller fortsätt detaljerade anteckningar** när AI är på igen. Bearbetningen fortsätter i bakgrunden med iOS förloppsruta; avbryts den finns sparade delar kvar och resten fortsätter nästa gång AI är på. Du ser antal bearbetade textdelar, detaljerade rubriker/anteckningar och öppningsbara källcitat. Läxor granskas separat med Ja/Nej/Inte nu.

Tryck **Kopiera hela anteckningen** och klistra in den hos valfri AI för att exempelvis få en förklaring eller skapa frågekort. Mio skapar inga sådana läromedel själv. Kopieringen är vanlig läsbar text med rubriker; den innehåller också osäkerheter och tydlig markering om delar återstår. Även när alla delar är bearbetade måste AI-utkastet granskas mot underlaget.

Efter nätfel, kvotfel eller omstart: färdiga detaljerade delar finns kvar. Vid kvotfel fortsätter Mio själv efter väntetiden; annars fortsätter du från samma lektionsknapp. Redan färdiga delar skickas inte om. Äldre korta huvudpunkter finns kvar separat men räknas inte som detaljerade anteckningar. Mycket långa lektioner kan kräva flera godkända omgångar (högst 100 delar i kön per omgång).

Om du rättar textunderlaget senare visas att anteckningarna bygger på **äldre text**; när revisionsunderlag saknas anges **okänd aktualitet**. Sparade delar/citat bevaras och rättningen skickas inte automatiskt igen. Kopierad anteckning behåller dessa varningar, ofullständiga delar och eventuella ljudluckor. Granska underlaget även när alla delar är bearbetade.

Cloudflare Access används inte längre: gatewayen nås bara via Tailscale, och sparade Access-uppgifter tas bort från telefonen vid första starten av det nya bygget.
