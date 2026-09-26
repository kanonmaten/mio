# Valfri OpenAI-integration

Den tidigare separata v0.5-planen ingår nu i helhetsbygget 0.9.0, efter användarbeslut 2026-09-25. Klient och server finns i källkod; ingen server är driftsatt eller verklig OpenAI-fråga verifierad genom implementationen. Molnet är avstängt från början.

Flödet är: skriv en fråga eller säg en adresserad Mio-fråga → lokal granskning/Ja/Nej/Inte nu → välj eventuell minsta kontext → exakt sändningspreview → uttryckligt Skicka → egen HTTPS-server → OpenAI-svar. Frågan skickas aldrig av taldetektionen. Ett svar skapar inga poster eller systemåtgärder.

[Serverguiden](../server/README.md) beskriver driftsättning, autentisering, gränser och tester. [Användarguiden](ANVANDNING.md) visar appflödet. Kör AI01–AI06 i [helhetstestet](TESTPLAN_HELHET.md) innan verklig användning.

OpenAI-nyckeln stannar i servermiljön. Telefonen har en annan, privat gatewaytoken i Keychain. Servern skriver inga fråge-/svarsloggar och skickar `store: false`; detta tar inte bort leverantörens regler för missbruksövervakning. Kontrollera [aktuella datavillkor](https://developers.openai.com/api/docs/guides/your-data) vid egen driftsättning och sätt en kostnadsgräns i ditt OpenAI-projekt.
