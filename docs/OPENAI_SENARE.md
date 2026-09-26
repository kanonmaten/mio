# AI-integrationen

OpenAI är första leverantör, med möjlighet att lägga till andra på servern senare. Appen använder de stabila kontrakten `/v1/ask` och `/v1/analyze`. Endast OpenAI-adaptern är implementerad. Ingen server eller modellåtkomst är verifierad genom kodändringen.

- **Enskild fråga:** välj minsta kontext → läs exakt preview → Skicka. Svaret utför inga åtgärder.
- **Löpande assistent:** konfigurera anslutning → aktivera AI-tolkning uttryckligen → korta nya textutdrag analyseras utan krav på Mio-tilltal. Resultat blir förslag med Ja/Nej/Inte nu.
- **Lektion:** separat knapp pausar vardags-Mio. När lektionen avslutas kan aktiverad AI ta fram huvudpunkter, exempel och läxor med källcitat. Historiska lektioner kräver ett eget sändningsval.

[Svenska systeminstruktioner](../server/src/prompts.mjs) skiljer uppgifterna, behandlar transkript som källmaterial, kräver källstöd och förbjuder automatiska minnen/åtgärder. [Leverantörsadaptern](../server/src/provider.mjs) innehåller OpenAI-formatet. Byte av modell behöver verkliga kvalitetsprov; ett strikt schema garanterar inte att innehållet är rätt.

[Serverguiden](../server/README.md) ger installationssteg från början. [Användarguiden](ANVANDNING.md) och [helhetstestet](TESTPLAN_HELHET.md) beskriver prov på telefonen. API-nyckeln ska aldrig finnas i appen eller klistras in i chatten. Telefonen använder en separat gatewaytoken. Ingen råljudslagring och inga textloggar i Mios server; leverantörens [datavillkor](https://developers.openai.com/api/docs/guides/your-data) gäller ändå.
