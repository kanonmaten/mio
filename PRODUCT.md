# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

En person som använder och underhåller appen själv. Hen använder Mio som stöd i vardagen och i skolan: lektioner, läxor, kalender och korta anteckningar. Appen öppnas många gånger om dagen, morgon, under skoldagen och på kvällen (svar 2026-10-11: "Alla").

## Product Purpose

Mio lyssnar när användaren själv startar mikrofonen, transkriberar svenska privat på användarens egen dator (Pianissimo) och gör om det som sägs till förslag, lektionsanteckningar, påminnelser och kalenderkopior. Målet är mindre att komma ihåg och färre steg: en tydlig nästa sak att göra per skärm. Lyckat är när användaren litar på att inget viktigt tappas bort och inte behöver tänka på appen.

## Positioning

Allt tal stannar hos användaren: inget ljud sparas, transkriptionen sker på den egna datorn över Tailscale och AI går via användarens egen gateway. Inga moln-STT, inget konto, ingen App Store.

## Operating Context

- Används i klassrum, korridorer, på bussen och hemma. Andra människor ser ofta skärmen; lyssnandet ska därför se diskret ut (svar 2026-10-11: "Diskret").
- Mikrofonen kan gå länge i bakgrunden med låst skärm; Live Activity visar att den lyssnar och låter användaren pausa.
- Lektioner blir detaljerade anteckningar med källcitat; läxförslag och andra förslag kräver alltid ett uttryckligt Ja.
- Installeras med SideStore och ett gratis Apple-konto. Första testtelefon iPhone 16 Pro, målet är även iPhone 13. iOS 26+.

## Capabilities and Constraints

- Fyra flikar: Hem, Lektioner, Kalender, Anteckningar, plus en separat mikrofonknapp. En inställningspanel från höger.
- AI är på som standard när datorn är parad, med snabbpaus. Enskilda frågor skickas utan förhandsgranskning; förslag kräver Ja.
- Groqs gratisnivå: vardagsutdrag analyseras i omgångar högst var femte minut, och dygnets tokens kan ta slut. Appen visar då när AI fungerar igen.
- Rättelser är ett visningslager; originaltranskriptet ändras aldrig. Talarnamn är också ett visningslager.
- Inga icke-mål i 0.9.0: ingen chatthistorik, strömmande svar, TTS eller automatiska åtgärder.

## Brand Commitments

- Namnet Mio.
- Röst: kort och lugn svenska (svar 2026-10-11: "Kort och lugn"). Inga utrop, ingen peppning, ingen skuld. Detaljer bakom ⓘ.
- Utseende valt 2026-10-11: violett instrumentpanel i stil med CardPointers blandat med bankappars glas. Liquid Glass bara på kontroller och navigering; anteckningar, transkript och listor är vanliga läsytor.
- Hem ändras med tiden på dagen (morgon, skoldag, kväll).
- Synliga framsteg: rutnät med 12 veckors svit och räknare som "3 att granska".

## Evidence on Hand

Användarens riktiga data finns bara på telefonen och får inte användas i skärmbilder eller i repot. Exempeltext i förhandsvisningar och tester ska vara syntetisk och märkt som sådan. Inga skärmbilder av den nya designen finns än.

## Product Principles

1. En tydlig nästa sak per skärm; resten bakom ⓘ eller ett steg in.
2. Användaren bestämmer: mikrofonen, förslag och allt som lämnar telefonen sker bara på hens initiativ eller med Ja.
3. Diskret i rummet, tydlig för användaren.
4. Ärlig status: visa luckor, kvot och fel med vanliga ord i stället för att dölja dem.
5. Mindre friktion slår fler funktioner.

## Accessibility & Inclusion

- Låg kognitiv belastning: korta texter, få val per vy, synliga framsteg, inga tidspressande animationer.
- Dynamic Type upp till de största storlekarna, mörkt läge, Reduce Motion och Reduce Transparency (glaset blir ogenomskinligt).
- Svenska i allt användaren ser.
