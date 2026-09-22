# Framtida OpenAI-integration — v0.5.0

Plan, inte implementerad funktion. v0.2.0 behöver inget OpenAI-konto, ingen nyckel och inga API-krediter.

Flöde: lokal fråga efter Mio → visa fråga och vald kontext → **Ja / Nej / Inte nu** → vid Ja, egen HTTPS-server → kort svar. Nej glömmer frågan; Inte nu behåller den lokalt.

## Krav före pilot

1. Verifiera lokalt dataflöde, transkription och bekräftelser med syntetiska data.
2. Besluta om server, autentisering, dataskydd, budget och radering.
3. Förvara API-nyckeln endast på servern. Skicka bara den godkända frågan och minsta relevanta kontext, aldrig heldagsljud.
4. Granska aktuella API-villkor, datalagring och tillgängliga lagringskontroller innan implementation; avsikten är `store: false` där det stöds.
5. Visa skickat innehåll, begränsa kostnad och logga förbrukning utan att skapa onödiga privata loggar.

Aktuella officiella referenser att kontrollera inför integration: [API-översikt](https://developers.openai.com/api/reference/overview), [datakontroller](https://developers.openai.com/api/docs/guides/your-data).
