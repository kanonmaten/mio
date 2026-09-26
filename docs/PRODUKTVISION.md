# Produktvision

Mio ska hjälpa en användare att fånga och ordna sin dag: lektioner, anteckningar, uppgifter, planer, uttryckliga minnen och senare sammanfattningar. En diskret vardagsassistent, inte en allmän studiechatbot.

## Produktregler

- **Användaren styr:** tydlig lyssningsstatus, På/Av, paus och radering. När Mio är av används inte mikrofonen; manuellt innehåll fungerar fortfarande.
- **Lokalt först:** transkription och Mio-detektion på telefonen. Inget sparat råljud och ingen ström av heldagsljud till molnet.
- **Bekräfta före åtgärd:** automatiskt föreslagna planer, uppgifter och minnen är förslag tills användaren godkänner dem. Kalenderposter skapas aldrig tyst.
- **Diskret återkoppling:** vibration och kort fråga; inget oombett tal. Ja godkänner, Nej glömmer och Inte nu sparar en väntande fråga lokalt.
- **Synliga minnen:** användaren kan granska, ändra och glömma. Ingen dold profilering eller påstådd kunskap om hur användaren känner.
- **Begriplig integritet:** visa vad som sparas, exporteras och eventuellt skickas. Inspelning av andra kräver samtycke och att lokala regler följs.

## Delar i appen

| Del | Helhetsbyggets omfattning | Kontroll |
|---|---|---|
| Mio | Lokal session, text, stödstatus, paus/stopp samt lokala frågor/förslag | Granskning med Ja/Nej/Inte nu; Enskilda AI-frågor kräver sändningsgodkännande; löpande tolkning kräver aktiverat läge |
| Lektioner | Separat läge pausar vardags-Mio; AI väljer huvudpunkter, exempel och läxor | Originaltext och tider bevaras; AI-utkast har textunderlag |
| Kalender | Lokala planer och bekräftade systemkalenderkopior | Inga tysta åtgärder eller dold synk |
| Anteckningar | Anteckningar, uppgifter och uttryckliga minnen | Synliga, redigerbara, raderbara |
| Morgon | Dagens lokala översikt, kvällsläge, alarm och dagliga notiser | Lokal dataöversikt, ingen påstådd semantisk AI-sammanfattning |

Måendecheckar ska vara frivilliga och förslag tydligt märkta. Mio ersätter inte lärare, vård eller professionell rådgivning. Funktionerna planeras i [roadmapen](ROADMAP.md); faktisk verifiering finns i [status](STATUS.md).

Användarbeslut 2026-09-25: bygg dessa delar tillsammans. AI-stöd och server ingår i koden, men molnet är avstängt tills användaren konfigurerar det. Läs [användarguiden](ANVANDNING.md) för det konkreta flödet.

## Förtydligande efter telefonprov, 2026-09-26

Vanliga samtal ska kunna ge plan- och uppgiftsförslag utan väckningsord. Användaren har uttryckligen valt löpande textanalys efter aktivering av AI-läget. Inget minne eller kalenderinlägg skapas tyst. Äldre dokument nämnde tidslinje för dagens innehåll; råa sessioner som huvudflöde var ett implementationsval, inte kärnan i visionen. Historiken bevaras som en sekundär vy.

En lektion är ett eget fångstläge med en separat knapp. Vardags-Mio pausas under lektionen och fortsätts uttryckligen efter avslut. Utan AI sparas lokalt textunderlag. Med aktiverad AI tas anteckningsutkast fram efter avslut, med citat som går att kontrollera. Ingen separat ljudinspelning sparas.
