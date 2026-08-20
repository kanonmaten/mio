# OpenAI läggs till efter fas 1

Det finns medvetet **ingen OpenAI-kod, API-nyckel eller kostnad** i fas 1.

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

OpenAI uppger att API-data inte används för modellträning om kunden inte aktivt väljer det. Standardloggar för missbruksövervakning kan ändå behållas i upp till 30 dagar; läs [Data controls](https://developers.openai.com/api/docs/guides/your-data#default-usage-policies-by-endpoint) innan fas 2 går skarpt.

## Vad vi gör när fas 1 är testad

1. Läs vilken lokal Apple-motor telefonen valde och hur stabil bakgrundslyssningen var.
2. Bygg lokal frågedetektion efter ordet Mio.
3. Bygg rutan **Ja / Nej / Inte nu**.
4. Skapa en mycket liten server med hemlig API-nyckel och användarautentisering.
5. Börja med en lätt OpenAI-modell och korta svar.
6. Lägg in hårda kostnadsgränser på servern.
7. Testa med konstgjorda frågor innan någon verklig privat dagskontext skickas.

Ni behöver alltså inte skapa OpenAI-konto, köpa API-krediter eller lämna ut en nyckel nu. Vi gör det sist, när den lokala grunden är bevisad.

