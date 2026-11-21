# Dokumentation

Här beskrivs hur Mio fungerar och varför. Det som ska göras, fel och prov som väntar finns i [Linear](https://linear.app/kanonmaten), inte här.

## Använda Mio

- [Användarguiden](ANVANDNING.md): hur du fångar, kör lektioner, granskar förslag och ändrar inställningar.
- [Installationen](INSTALLATION.md): bygga och installera appen med SideStore, och vad verifieringen täcker.
- [Pianissimo](../transcription-server/README.md), [gatewayen](../server/README.md) och [Mio Kontroll](../control/README.md): delarna på datorn, var och en med installation och felsökning.

## Hur Mio är byggt

- [Datamodellen](DATAMODELL.md): lagring, schemaversioner, export, säkerhetskopia och vad som aldrig sparas.
- [Pianissimos API](../transcription-server/API.md): protokollet mellan appen och transkriptionen.
- [Designen](../DESIGN.md) för appen och [designen för Mio Kontroll](../control/DESIGN.md). [PRODUCT.md](../PRODUCT.md) beskriver vem Mio är till för och vilka principer designen följer.

## Beslut och läge

- [Besluten](DECISIONS.md): varje större val med datum, skäl och det som valdes bort. Nyast först.
- [Status](STATUS.md): vad som faktiskt är kontrollerat, på vilken commit och med vilket resultat.
- [Helhetstestet](TESTPLAN_HELHET.md): hur proven på telefonen och datorn går till och när de räknas som godkända. Vilka prov som återstår står i Linear med etiketten Prov.
- [Ändringsloggen](../CHANGELOG.md): vad varje version ändrar för den som använder Mio.

## Arkiv

[`arkiv/`](arkiv/README.md) har planer som är genomförda och gamla mätningar. De är flyttade dit oförändrade och gäller inte längre som instruktioner.
