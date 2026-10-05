# Arbetsflöde

En task per tydligt resultat. Varaktig kontext finns i [CLAUDE.md](../CLAUDE.md) och dokumentationen; chatthistorik ersätter inte dessa.

## Ändra

1. Kontrollera `git status` och hämta remote-status med `git fetch origin`. Integrera uppströmsändringar utan att skriva över lokalt arbete.
2. Läs relevanta beslut, datamodell och testfall. Beskriv mål och verifiering.
3. Ändra lokalt. Använd `main` för små sekventiella arbeten; en separat branch för riskfyllda eller parallella ändringar.
4. Granska diffen. Uppdatera [ändringsloggen](../CHANGELOG.md); uppdatera [status](STATUS.md) bara med faktiska resultat.
5. Kontrollera att privata exporter, nycklar, certifikat och IPA-filer inte följer med. Commit och push sker bara på uttrycklig begäran.

GitHub Desktop kan användas för samma Git-steg. Ingen Windows-specifik mappsökväg krävs; arbeta i projektets lokala checkout.

## Bygg och prova

Följ [installationsguiden](INSTALLATION.md): pushad commit → manuellt Actions-bygge → validerad IPA → SideStore → fysiskt telefonprov. Linux kan redigera koden men inte köra Xcode.

Rapportera alltid **källkod → statiska kontroller → Xcode/XCTest → IPA → installation → telefonprov** separat. Ange commit och enhet när ett testresultat registreras. En version eller ett grönt simulatorjobb räcker inte som bevis för fungerande app.

## Avsluta

Sammanfatta ändringar, kontroller, begränsningar och nästa steg. Dokumentera beslut i repot. För en release: följ versionsreglerna i [roadmapen](ROADMAP.md); ändra inte gamla testresultat till gröna bara för att kod är implementerad.
