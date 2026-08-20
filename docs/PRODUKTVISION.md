# Produktvision för Mio

## Kort version

Mio ska vara en lugn och diskret personlig iPhone-assistent som hjälper en användare att fånga sin dag: lektioner, planer, saker att minnas, frågor och kvällens sammanfattning. Användaren ska alltid kunna se när Mio lyssnar, pausa eller stänga av funktionen och bestämma vad som får sparas eller skickas vidare.

Mio ska inte kännas som en allmän chatbot. Den ska främst organisera det användaren själv har sagt eller hört under en aktiv, användarstartad session.

## Produktprinciper

1. **Kontroll först.** En tydlig På/Av-knapp och pauser på 30 minuter, 1 timme eller tills användaren startar igen.
2. **Lokalt först.** Taligenkänning och enkel Mio-detektion sker på telefonen när det är möjligt.
3. **Diskret.** Mio pratar inte oombedd. När uppmärksamhet behövs används i första hand vibration och en kort fråga.
4. **Samtycke före moln-AI.** En fråga skickas till OpenAI först när användaren uttryckligen väljer **Ja**.
5. **Minns bara med tydliga regler.** Användaren ska kunna se, ändra och glömma sparade minnen.
6. **Inget låtsasvetande.** Mio får hjälpa användaren att se mönster men ska inte påstå sig veta exakt hur hon känner.
7. **Integritet är en funktion.** Lyssningsstatus, radering, export och vad som lämnar telefonen ska vara begripliga.

## Önskad upplevelse

Den långsiktiga appen har fem huvuddelar som nås från en enkel nederkant:

- **Mio:** status, frågor, förslag och väntande bekräftelser.
- **Tidslinje:** dagens lektioner, händelser och sammanhang i tidsordning.
- **Kalender:** manuella poster och planer som Mio föreslår men aldrig sparar utan godkännande.
- **Anteckningar:** skola, lektioner, idéer, viktigt, att göra, frågor och egna anteckningar.
- **Alarm/morgon:** alarm och en kort morgonöversikt baserad på kalender och uttryckliga minnen.

## Centrala funktioner

### Dagens anteckningar

- En aktiv Mio-session kan skapa lokal text och ordna den i tidsblock.
- Lektioner ska senare kunna delas upp efter ämne och start/slut.
- Viktiga uppgifter, läxor, prov och exempel ska kunna lyftas fram.
- Allt ska även gå att skapa och redigera manuellt.

### Planer och kalender

- Direkta kommandon som “Mio, lägg in tandläkaren på tisdag klockan tre” ska skapa ett förslag.
- Planer som råkar nämnas i ett vanligt sammanhang får högst bli ett förslag med **Ja/Nej**.
- Ingen kalenderpost ska skapas tyst.

### “Hej Mio” och frågor

- Det fristående ordet **Mio** upptäcks lokalt.
- Vid en fråga vibrerar telefonen och visar **Vill du ha svar nu?**
- **Ja:** skicka just den godkända frågan och minsta nödvändiga sammanhang.
- **Inte nu:** spara frågan lokalt till senare.
- **Nej:** glöm den väntande frågan.

### Uttryckliga minnen

- Formuleringar som “Mio, kom ihåg att …” kan sparas som synliga minnen.
- Minnen ska kunna listas, ändras och raderas.
- Mio ska inte bygga en dold profil från allt som sägs.

### Kväll och mående

- Mio kan ställa frivilliga, enkla frågor om hur dagen kändes.
- Kvällssammanfattningen kan samla lektioner, planer, viktiga saker och användarens egna måendeord.
- Förslag inför nästa dag ska märkas som förslag, inte fakta.

## När Mio är av

När Mio är av får appen inte använda mikrofonen, skapa automatiska anteckningar, upptäcka planer eller ge automatiska förslag. Manuella anteckningar, kalender och alarm ska fortfarande fungera.

## Avgränsningar

- Mio är inte en ersättning för lärare, vårdpersonal eller professionell rådgivning.
- Mio ska inte vara en allmän matte- eller studiechatbot.
- Heldagsljud ska inte strömmas till OpenAI.
- Appen ska inte försöka kringgå iOS begränsningar efter tvångsavslutning eller omstart.
- Inspelning av andra personer kräver tydligt samtycke och att skolans, arbetsplatsens och lagens regler följs.
