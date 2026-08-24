# Arbetsflöde för Mio

## Vad är en Codex-task?

En task är en separat chatt i Codex. Använd en task per tydligt resultat, exempelvis:

- “Fas 1 – analysera ett 60-minuterstest”
- “Fix – återstart efter ljudavbrott”
- “Fas 2 – modell för manuella anteckningar”
- “Fas 2 – analysera uppgradering och lokal persistens”

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
GitHub Actions: kör XCTest + bygg osignerad IPA
        ↓
SideStore: signera → installera → förnya
        ↓
iPhone-test → avidentifierad slutsats tillbaka till docs
```

Den lokala Git-mappen är arbetskopian. GitHub är historik, backup och byggstart. En ZIP eller IPA är aldrig en redigerbar huvudversion.

## Håll verifieringsnivåerna isär

Använd dessa nivåer i statusrapporter och dokument:

1. **Implementerat i källkod** — filerna finns, men kan fortfarande innehålla kompileringsfel.
2. **Statiskt kontrollerat på Windows** — endast de kontroller som faktiskt kördes är godkända.
3. **XCTest körd** — kräver en dokumenterad testkörning med Xcode; testfiler som bara finns är inte körda tester.
4. **GitHub Actions byggd** — den angivna revisionens Release-build och IPA-steg är gröna.
5. **Installerad** — exakt den IPA:n har installerats på telefonen.
6. **Verifierad på iPhone** — ett namngivet testfall har körts med observerat resultat.

En äldre grön build eller ett äldre telefonprov gäller inte automatiskt efter kodändringar. Fas 2 ska dokumenteras i `KRAVMATRIS_FAS_2.md` och `TESTRESULTAT_FAS_2.md`; fas 1-resultatet från den 20 augusti ska ligga kvar som historik.

## Inför varje ändring

1. Öppna GitHub Desktop och välj `mio`.
2. Tryck **Fetch origin**.
3. Kontrollera att inga oväntade lokala ändringar finns.
4. Öppna rätt task i Codex-projektet Mio.
5. Beskriv mål, vad som ingår, vad som inte ingår och hur resultatet ska verifieras.
6. Läs rätt kravmatris och testplan för fasen. För lagringsändringar i fas 2, läs även `DATAMODELL_FAS_2.md`.

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
8. Exportera viktig lokal testdata före uppdatering. Inför första fas 2-installationen ska åtminstone befintlig fas 1-session exporteras privat.
9. Installera över befintlig Mio med samma Apple-konto och bundle identifier; radera inte appen i onödan.
10. Kör [TESTPLAN_FAS_2.md](TESTPLAN_FAS_2.md) för fas 2 och dokumentera resultatet mot commit, Actions-körning och enhet. Kör kvarvarande [TESTPLAN_FAS_1.md](TESTPLAN_FAS_1.md) separat.

## När en task ska fortsätta eller avslutas

Fortsätt samma task när ni felsöker eller förfinar samma mål. Starta en ny task när resultatet är ett annat. Avsluta med att dokumentera beslut, verifiering och nästa steg i repot så att nästa task inte behöver gissa.

## Filer som aldrig ska checkas in

- `*.ipa` och nedladdade artifacts
- `Mio-fas-1-*.json`, `Mio-lokal-export-*.json` och andra riktiga testexporter
- `*.mobiledevicepairing`
- `*.p12`, `*.mobileprovision`, `*.cer`, `*.pem`, `*.key` och andra certifikat/nycklar
- `.env`, API-nycklar och Apple-inloggning
- råljud eller skärmbilder med privat dagsinnehåll

## Enkel branchregel

Använd `main` för små, sekventiella ändringar. Skapa en separat branch först när en förändring är riskfylld, tar flera dagar eller ska utvecklas parallellt. Ett litet projekt blir inte mer professionellt av fler Git-steg än det faktiskt behöver.
