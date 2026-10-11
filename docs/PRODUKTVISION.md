# Produktvision

Mio ska hjälpa en användare att fånga och ordna sin dag: lektioner, anteckningar, uppgifter, planer, uttryckliga minnen och senare sammanfattningar. En diskret vardagsassistent, inte en allmän studiechatbot.

## Produktregler

- **Användaren styr:** tydlig lyssningsstatus, På/Av, paus och radering. När Mio är av används inte mikrofonen; manuellt innehåll fungerar fortfarande.
- **Privat och användarstyrt:** svensk transkription på egen Pianissimo-server via Tailscale; Mio-detektion och lagring på telefonen. Ljudöverföring bara under användarstartad session, högst 60 s ljud i RAM vid avbrott och inga ljudfiler. Text-AI går via användarens egen gateway på datorn, är på när datorn är parad och kan pausas.
- **Bekräfta före åtgärd:** automatiskt föreslagna planer, uppgifter och minnen är förslag tills användaren godkänner dem. Kalenderposter skapas aldrig tyst.
- **Diskret återkoppling:** vibration och kort fråga; inget oombett tal. Ja godkänner, Nej glömmer och Inte nu sparar en väntande fråga lokalt.
- **Synliga minnen:** användaren kan granska, ändra och glömma. Ingen dold profilering eller påstådd kunskap om hur användaren känner.
- **Begriplig integritet:** visa vad som sparas, exporteras och eventuellt skickas. Inspelning av andra kräver samtycke och att lokala regler följs.

## Delar i appen

| Del | Helhetsbyggets omfattning | Kontroll |
|---|---|---|
| Hem | Veckoplaneraren: veckonummer, veckans dagar, en tydlig nästa sak, antal att granska, dagens morgon- eller kvällsöversikt och tolv veckors aktivitet | Härlett från lokala data; bara antal, ingen text i aktivitetsrutnätet |
| Fånga | Lokal session, text, serverstatus, paus/stopp, AI-paus samt lokala frågor/förslag; separat rund knapp i flikfältet | Granskning med Ja/Nej/Inte nu; enskilda frågor skickas direkt men svaret valideras; AI kan pausas |
| Lektioner | Separat läge pausar vardags-Mio; AI skriver detaljerade kopierbara anteckningar samt separata läxförslag | Originaltext och tider bevaras; AI-utkast har textunderlag |
| Kalender | Lokala planer per veckonummer och bekräftade systemkalenderkopior | Inga tysta åtgärder eller dold synk |
| Anteckningar | Anteckningar, uppgifter och uttryckliga minnen | Synliga, redigerbara, raderbara |

Måendecheckar ska vara frivilliga och förslag tydligt märkta. Mio ersätter inte lärare, vård eller professionell rådgivning. Funktionerna planeras i [roadmapen](ROADMAP.md); faktisk verifiering finns i [status](STATUS.md).

Användarbeslut 2026-09-25: bygg dessa delar tillsammans. AI-stöd och server ingår i koden, men molnet är avstängt tills användaren konfigurerar det. Läs [användarguiden](ANVANDNING.md) för det konkreta flödet.

## Förtydligande efter telefonprov, 2026-09-26

Vanliga samtal ska kunna ge plan- och uppgiftsförslag utan väckningsord. Användaren har uttryckligen valt löpande textanalys efter aktivering av AI-läget. Inget minne eller kalenderinlägg skapas tyst. Äldre dokument nämnde tidslinje för dagens innehåll; råa sessioner som huvudflöde var ett implementationsval, inte kärnan i visionen. Historiken bevaras som en sekundär vy.

En lektion är ett eget fångstläge med en separat knapp. Vardags-Mio pausas under lektionen och fortsätts uttryckligen efter avslut. Utan AI sparas lokalt textunderlag. Med aktiverad AI tas anteckningsutkast fram efter avslut, med citat som går att kontrollera. Ingen separat ljudinspelning sparas.

## Förtydligande 2026-09-28

Mio ska bevara detaljerade lektionsanteckningar: förklaringar, begrepp, exempel, arbetssteg och läxor. Användaren kopierar dem till valfri vanlig AI för vidare lärande. Presentationer, frågekort och avancerade undervisningsupplägg ingår inte i Mio. En lektion kan ta flera minuter att bearbeta; utförlighet följer innehållet, inte ett visst sidantal.

AI-leverantör och kompatibel modell byts i Cloudflare, utan modellväljare i appen. Reasoning ska vara av, temperatur 0 och svaren strikt strukturerade. Modeller som inte uppfyller kraven stoppas. Förslag blir inte handlingar utan användarens Ja.

## Veckoplaneraren, 2026-10-11

Användaren valde designen veckoplaneraren: violett grund, vanliga läsytor för anteckningar, transkript och listor, och Liquid Glass bara på flikfält och knappar. Appen har fyra flikar, Hem, Lektioner, Kalender och Anteckningar, och en separat rund mikrofonknapp, Fånga. Morgon-fliken är borta; morgon- och kvällsöversikten finns på Hem. Varje skärm ska ha en tydlig nästa sak.

Samma dag flyttade AI-gatewayen från Cloudflare till användarens dator bredvid Pianissimo, med Groq som enda leverantör. Modell byts på datorn, fortfarande utan modellväljare i appen. Reasoning av, temperatur 0 och strikt schema gäller som förut.
