# Arbetsflöde för Mio

## Vad är en Codex-task?

En task är en separat chatt i Codex. Använd en task per tydligt resultat, exempelvis:

- “Fas 1 – analysera ett 60-minuterstest”
- “Fix – återstart efter ljudavbrott”
- “Fas 2 – modell för manuella anteckningar”

En ny task i Mio-projektet kan läsa samma lokala repository. Den får inte automatiskt hela ord-för-ord-historiken från andra chattar. Varaktig kontext ska därför finnas i `AGENTS.md` och `docs/`, medan tasken håller diskussionen om ett enskilt resultat fokuserad.

## Källan till sanningen

```text
Idé eller testresultat
        ↓
Codex-task i det lokala Mio-projektet
        ↓
Filer i C:\Users\eyvin\Documents\GitHub\mio
        ↓
GitHub Desktop: granska → commit → push
        ↓
GitHub Actions: bygg osignerad IPA
        ↓
SideStore: signera → installera → förnya
        ↓
iPhone-test → avidentifierad slutsats tillbaka till docs
```

Den lokala Git-mappen är arbetskopian. GitHub är historik, backup och byggstart. En ZIP eller IPA är aldrig en redigerbar huvudversion.

## Inför varje ändring

1. Öppna GitHub Desktop och välj `mio`.
2. Tryck **Fetch origin**.
3. Kontrollera att inga oväntade lokala ändringar finns.
4. Öppna rätt task i Codex-projektet Mio.
5. Beskriv mål, vad som ingår, vad som inte ingår och hur resultatet ska verifieras.

Promptmall:

```text
Mål: ...

Ingår:
- ...

Inte nu:
- ...

Klart när:
- ...

Läs AGENTS.md och relevanta docs först.
Ändra lokala filer och verifiera det du kan.
Commit eller push inte utan att jag uttryckligen ber om det.
```

## Efter Codex-arbetet

1. Läs sammanfattningen och öppna **Changes** i GitHub Desktop.
2. Kontrollera att inga exporter, nycklar, certifikat eller IPA-filer finns i listan.
3. Granska diffen. Fråga Codex om något är oklart.
4. Skriv en kort commit-rad, exempelvis:

   - `docs: dokumentera första enhetstestet`
   - `fix: återställ ljudsession efter avbrott`
   - `feat: lägg till manuell anteckning`
   - `test: täck Mio-detektion med skiljetecken`

5. Klicka **Commit to main** och därefter **Push origin**.
6. Öppna GitHub **Actions > Bygg Mio IPA > Run workflow** när en ny telefonbyggnad behövs.
7. Hämta artifact-ZIP, packa upp den en gång och installera `.ipa` via SideStore.
8. Exportera viktig lokal testdata före uppdatering. Installera över befintlig Mio med samma Apple-konto; radera inte appen i onödan.

## När en task ska fortsätta eller avslutas

Fortsätt samma task när ni felsöker eller förfinar samma mål. Starta en ny task när resultatet är ett annat. Avsluta med att dokumentera beslut, verifiering och nästa steg i repot så att nästa task inte behöver gissa.

## Filer som aldrig ska checkas in

- `*.ipa` och nedladdade artifacts
- `Mio-fas-1-*.json` och andra riktiga testexporter
- `*.mobiledevicepairing`
- `*.p12`, `*.mobileprovision`, `*.cer`, `*.pem`, `*.key` och andra certifikat/nycklar
- `.env`, API-nycklar och Apple-inloggning
- råljud eller skärmbilder med privat dagsinnehåll

## Enkel branchregel

Använd `main` för små, sekventiella ändringar. Skapa en separat branch först när en förändring är riskfylld, tar flera dagar eller ska utvecklas parallellt. Ett litet projekt blir inte mer professionellt av fler Git-steg än det faktiskt behöver.
