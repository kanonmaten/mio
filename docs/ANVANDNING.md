# Använd Mio

Detta är guiden för helhetsbygget 0.9.0. Koden behöver först byggas och installationen provas enligt [installation](INSTALLATION.md) och [helhetstest](TESTPLAN_HELHET.md).

## Första gången

Öppna de fem flikarna. Du kan skriva manuella poster direkt, utan mikrofon, notiser eller AI. **Mio → Så använder du Mio** innehåller en kort guide i appen.

Under **Telefonens stöd och integritet** kan du kontrollera svensk transkription och vid behov installera SpeechTranscriber-modellen med wifi. Installation är separat från sessionsstart; annars används DictationTranscriber med svenska när telefonen stöder det.

## Fånga och ordna

1. Tryck **Starta ny session** i Mio och tillåt mikrofonen.
2. Säg en vanlig svensk testmening. Den färdiga texten sparas lokalt; ljudet sparas inte.
3. Pausa när du vill stänga mikrofonen tillfälligt. Stoppa när du är klar.
4. Öppna sessionen i **Tidslinje**. Ge den en titel, skriv en anteckning och rätta text vid behov. Originaltext och ljudtider bevaras.
5. Öppna **Lektionsindelning** för att ge olika tidsdelar egna namn. Lektioner får inte överlappa. Sekundkontrollerna under datumfälten hjälper vid korta prov. En textdel över en gräns kan visas i båda lektionerna.

Spela bara in andra med tydligt samtycke och enligt lokala regler. Paus/stopp ska släcka iOS mikrofonindikator. Långvarig drift med låst skärm behöver verifieras på din telefon; tvångsavslutning startar aldrig om lyssningen automatiskt.

## Be Mio föreslå något

Säg till exempel:

- **Mio, anteckna att vi arbetar med procent.**
- **Mio, påminn mig att ta med boken.**
- **Mio, planera tandläkaren.**
- **Mio, kom ihåg att jag föredrar blå pennor.**

Tydliga Mio-kommandon blir lokala frågor i **Mio → Förslag att granska**. Vanlig konversation blir inte automatiskt ett minne. Du kan även använda plusknappen i inkorgen för att skriva ett förslag själv, eller **Hitta lokala Mio-förslag** inne i en sparad session.

Öppna frågan och kontrollera **typ, rubrik, text, datum och tid**. Mio tolkar inte datum i fri text automatiskt.

- **Ja, spara:** skapar posten i Mio. Alarm, notiser och kalenderkopior aktiveras separat.
- **Nej, glöm förslaget:** tar bort frågan. Originaltexten i sessionen finns kvar tills du raderar sessionen.
- **Inte nu:** behåller frågan i inkorgen till senare.

I förgrunden kan upptäckt av Mio ge vibration. Frågor kan behöva granskas genom att du öppnar appen när den har varit i bakgrunden.

## Anteckningar, uppgifter och minnen

Använd plusknappen i **Anteckningar** eller **Tidslinje**. Välj typ och fyll i rubrik, text och tid. Du kan koppla posten till en session. Sökningen hittar även svenska ord utan diakritiska tecken, exempelvis `ovning` för `Övning`.

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

Hela lokalflödet fungerar utan server. Om du vill aktivera AI:

1. Sätt upp den medföljande servern enligt [serverguiden](../server/README.md), med OpenAI-nyckeln enbart på servern.
2. Öppna **Mio → Fråga Mio med AI**. Ange din HTTPS-adress och serverns separata åtkomsttoken. Spara anslutningen och slå på **Tillåt molnfrågor**.
3. Skriv frågan. Välj vid behov enstaka poster eller ett kort sessionsutdrag. Korta och rensa texten som ska skickas.
4. Tryck **Granska innan du skickar**. Läs mottagare, exakt fråga och exakt kontext.
5. Välj **Ja, skicka denna fråga till molnet**. Först då görs nätanropet. Avbryt i stället om du inte vill dela texten.

Svaret kan innehålla fel, utför inga åtgärder och sparas inte som historik i appen. En skickad fråga kan inte återkallas. Mios server skriver inga textloggar och begär `store: false`; leverantörens datavillkor gäller ändå. Du stänger av och tar bort anslutningen med **Glöm anslutning och stäng av**.

## Exportera och radera

Stoppa sessionen och gå till **Mio → Export och radering → Skapa lokal export**. Dela/spara JSON-filen privat. Exporten innehåller innehåll, sessioner, förslag, lektioner och diagnostik; aldrig råljud eller åtkomsttoken. Det finns ingen importknapp i detta bygge.

**Radera all lokal data** tar efter bekräftelse bort alla tre lokala datalager, egna alarm/notiser och AI-konfiguration. Redan delade filer, skickade molnfrågor och kalenderkopior kan inte återkallas av detta. Om en systemåtgärd inte kan avbrytas visas ett fel så att du kan hantera den före fortsatt radering.
