# Använd Mio

Detta är guiden för helhetsbygget 0.9.0. Koden behöver först byggas och installationen provas enligt [installation](INSTALLATION.md) och [helhetstest](TESTPLAN_HELHET.md).

## Första gången

Öppna de fem flikarna. Du kan skriva manuella poster direkt, utan mikrofon, notiser eller AI. **Mio → Så använder du Mio** innehåller en kort guide i appen.

Under **Telefonens stöd och integritet** kan du kontrollera svensk transkription och vid behov installera SpeechTranscriber-modellen med wifi. Build 5 försöker även installera en stödd men saknad svensk modell när du startar Mio. Under hämtningen visas ett förberedelseläge och mikrofonen har inte startat. Avbryt håller Mio avstängd. Dictation används vid saknat stöd eller installations-/startfel; orsaken finns i händelseloggen. Build 4 har fortfarande separat installation.

## Fånga och ordna

1. Tryck **Starta Mio** och tillåt mikrofonen. Paus/stopp stänger mikrofonen.
2. Öppna **AI-assistent** och aktivera löpande AI-tolkning när servern är konfigurerad. Säg exempelvis ”Vi ses på biblioteket på tisdag klockan 15”. Mio-tilltal behövs inte i detta läge. Utdrag samlas ungefär en minut; granska förslagen i inkorgen.
3. Tryck **Starta lektion**, ange ämne och starta. Vardags-Mio pausas. Lektionens text fångas lokalt utan sparat ljud.
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

Under **Mio → Alarm och påminnelser** kan du skapa fristående alarm, välja veckodagar, se kommande notiser och ta bort dem. Låsskärmen visar generell Mio-text. Prova ett alarm ett par minuter framåt innan du förlitar dig på det.

## Morgon och kväll

**Morgon** visar dagens planer, uppgifter och sådant som ligger kvar sedan tidigare. Byt till **Kväll** för avklarade uppgifter, anteckningar och dagens sessions-/lektionstal. Välj datum för en annan dag.

Översikten räknar och visar sparat innehåll lokalt. Dagliga påminnelser för morgon och kväll ställs in i **Alarm och dagliga påminnelser**; de skickar generell text och öppnar inte mikrofonen.

## Valfri AI

Det finns två separata flöden. **AI-assistent → Aktivera AI-tolkning** ger samtycke till löpande nya vardagsutdrag och lektioner du avslutar medan läget är på. Läget återställs till av när app-processen startar om. Paus/stopp slänger väntande vardagsanalys; Stäng av AI-tolkning stoppar även lektionskön. Redan skickad text kan inte återkallas. Vid nät-/gränsfel stoppas läget och behöver aktiveras igen. En sparad lektion som inte analyserats kan skickas med ett separat godkännande från dess detaljvy.

För **enskilda frågor** följer du stegen nedan:

Hela lokalflödet fungerar utan server. Om du vill aktivera AI:

1. Sätt upp den medföljande servern enligt [Cloudflare-guiden](../server/cloudflare/README.md) utan påslagen egen dator, eller [serverguiden](../server/README.md) för egen värd, med leverantörens API-nyckel enbart på servern.
2. Öppna **Mio → Fråga Mio med AI**. Ange din HTTPS-adress och åtkomsttoken: exakt samma hemliga värde som Workerns `MIO_GATEWAY_TOKEN`, utan `Bearer`. Efter rotation ska det nya värdet sparas även här. Spara anslutningen och slå på **Tillåt molnfrågor**.
3. Skriv frågan. Välj vid behov enstaka poster eller ett kort sessionsutdrag. Korta och rensa texten som ska skickas.
4. Tryck **Granska innan du skickar**. Läs mottagare, exakt fråga och exakt kontext.
5. Välj **Ja, skicka denna fråga till molnet**. Först då görs nätanropet. Avbryt i stället om du inte vill dela texten.

Svaret kan innehålla fel, utför inga åtgärder och sparas inte som historik i appen. En skickad fråga kan inte återkallas. Mios server skriver inga textloggar och begär `store: false`; leverantörens datavillkor gäller ändå. Du stänger av och tar bort anslutningen med **Glöm anslutning och stäng av**.

## Exportera och radera

Stoppa sessionen och gå till **Mio → Export och radering → Skapa lokal export**. Dela/spara JSON-filen privat. Exporten innehåller innehåll, sessioner, förslag, lektioner, AI-anteckningar och diagnostik; aldrig råljud eller åtkomsttoken. Det finns ingen importknapp i detta bygge.

**Radera all lokal data** tar efter bekräftelse bort alla tre lokala datalager, egna alarm/notiser och AI-konfiguration. Redan delade filer, skickade molnfrågor och kalenderkopior kan inte återkallas av detta. Om en systemåtgärd inte kan avbrytas visas ett fel så att du kan hantera den före fortsatt radering.

## Nya AI-val och detaljerade lektionsanteckningar

Detta gäller arbetskopians nya kod; befintlig build 5 behöver ersättas med en ny verifierad IPA och gatewayen behöver uppdateras.

**Byta till Groq:** följ [Cloudflare-bytesguiden](../server/PROVIDERS.md). Modell och API-nyckel ändras på servern; appens adress och gatewaytoken behålls. Reasoning är av, temperatur 0 och strikt JSON används automatiskt. Modellens JSON visas som vanliga anteckningar och förslag i appen.

**Lektion:** tryck Starta lektion, avsluta när undervisningen är slut och öppna lektionen i Lektioner. Med godkänd AI-tolkning kan bearbetningen starta efter avslut; annars aktiverar du AI och väljer **Skapa eller fortsätt detaljerade anteckningar …** samt godkänner sändningen. Låt appen vara öppen medan den bearbetar textdelarna. Du ser antal bearbetade textdelar, detaljerade rubriker/anteckningar och öppningsbara källcitat. Läxor granskas separat med Ja/Nej/Inte nu.

Tryck **Kopiera hela anteckningen** och klistra in den hos valfri AI för att exempelvis få en förklaring eller skapa frågekort. Mio skapar inga sådana läromedel själv. Kopieringen är vanlig läsbar text med rubriker; den innehåller också osäkerheter och tydlig markering om delar återstår. Även när alla delar är bearbetade måste AI-utkastet granskas mot underlaget.

Efter nätfel, kvotfel eller omstart: färdiga detaljerade delar finns kvar. Vänta vid kvotfel, aktivera AI igen och fortsätt från samma lektionsknapp. Redan färdiga delar skickas inte om. Äldre korta huvudpunkter finns kvar separat men räknas inte som detaljerade anteckningar. Mycket långa lektioner kan kräva flera godkända omgångar (högst 100 delar i kön per omgång).

För [Groq, tokenåterställning och Cloudflare Access](../server/cloudflare/GROQ_ACCESS.md) finns en sammanhängande steg-för-steg-guide. Access kräver den nya appens separata Client ID-/Client Secret-fält; de finns inte i build 5.
