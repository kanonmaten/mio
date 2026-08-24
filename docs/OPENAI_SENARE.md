# OpenAI läggs tidigast till i fas 5

Det finns medvetet **ingen OpenAI-kod, API-nyckel eller kostnad** i fas 1 eller fas 2. Fas 2 är en helt lokal, manuell MVP utan konto, server eller moln-AI. Fas 3 bygger först det lokala bekräftelseflödet och fas 5 kan därefter införa begränsade OpenAI-svar genom en server.

## Varför OpenAI inte ska lyssna hela dagen

All-dagsljudet ska hanteras lokalt av Apple på telefonen. Att strömma allt till en molnmodell skulle ge sämre integritet, mer nätverks- och batterianvändning och en löpande kostnad. Mio behöver inte en stor modell för att hitta ordet Mio, skapa rå transkription eller upptäcka enkla lokala signaler.

OpenAI ska bara användas när det finns en tydlig uppgift som användaren godkänt, exempelvis:

- hon säger en fråga efter “Mio”;
- telefonen vibrerar och visar **Vill du ha svar nu?**;
- hon trycker **Ja**;
- först då skickas just frågan och minsta nödvändiga sammanhang.

Trycker hon **Nej** raderas den väntande frågan. **Inte nu** sparar den lokalt tills hon väljer den senare.

## Säker arkitektur senare

```text
iPhone (lokal mikrofon och transkription)
        │
        │ endast uttryckligen godkänd fråga
        ▼
Vår lilla HTTPS-server
        │ API-nyckeln finns endast här
        ▼
OpenAI Responses API med store: false
        │
        ▼
Kort svar tillbaka till Mio
```

API-nyckeln får **aldrig** läggas direkt i Swift-koden eller i appens `Info.plist`. OpenAI säger uttryckligen att nycklar inte ska exponeras i klientkod; de ska laddas säkert på servern. Se [API Overview](https://developers.openai.com/api/reference/overview#backwards-compatibility).

## Integritetsregler vi bör bygga in

1. Skicka bara en fråga efter ett aktivt **Ja**.
2. Skicka inte hela dagens transkription som standard.
3. Välj en liten, relevant lokal kontext, exempelvis bekräftad kalenderpost eller ett uttryckligt minne.
4. Anropa Responses API med `store: false`.
5. Visa i appen exakt vad som ska skickas innan första riktiga testet.
6. Lägg till en knapp som raderar lokala väntande frågor och OpenAI-relaterad historik.
7. Logga kostnad/tokenmängd per godkänd fråga så att den aldrig blir en överraskning.

OpenAI uppger att API-data inte används för modellträning om kunden inte aktivt väljer det. Standardloggar för missbruksövervakning kan ändå behållas i upp till 30 dagar; kontrollera aktuella [Data controls](https://developers.openai.com/api/docs/guides/your-data#default-usage-policies-by-endpoint) igen innan ett fas 5-pilottest.

## Stegordning före OpenAI

1. Slutför fas 1:s bakgrunds-, batteri-, avbrotts- och kvalitetstest på telefonen.
2. Bygg och verifiera fas 2:s lokala manuella datamodell, redigering, sökning, radering och export.
3. Bygg i fas 3 lokal frågedetektion efter ordet Mio samt rutan **Ja / Nej / Inte nu** utan att göra nätverksanrop.
4. Visa exakt vilken fråga och minsta kontext som skulle skickas och testa flödet med konstgjorda data.
5. Ta ett nytt beslut om server, autentisering, dataskydd, aktuell OpenAI-policy och kostnadsgränser.
6. Skapa först därefter en liten server som ensam äger API-nyckeln.
7. Börja med en lätt modell och korta svar i en kontrollerad fas 5-pilot.

Ni behöver alltså inte skapa OpenAI-konto, köpa API-krediter eller lämna ut en nyckel under fas 2. OpenAI görs sist, när den lokala grunden och samtyckesflödet är verifierade.
