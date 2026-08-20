# Testplan för Mio fas 1

Målet är inte att visa en snygg demo. Målet är att samla pålitliga bevis från just hennes iPhone 13.

## Före testet

1. Kontrollera att iPhone kör iOS 26 eller senare.
2. Stäng av Strömsparläge för första standardtestet. Senare kan ni göra ett separat test med Strömsparläge.
3. Stoppa Xcodes körning, koppla ur Mac-/laddkabeln och öppna Mio från telefonens hemskärm. Annars förvränger laddning och debugger batteritestet.
4. Notera ungefärlig batteriprocent.
5. Ha wifi vid första starten så att Apple kan hämta svensk språkmodell.
6. Använd först telefonens inbyggda mikrofon, inte AirPods.
7. Gör testet i en kontrollerad miljö. Spela inte in klasskamrater, lärare, kollegor eller andra personer utan deras tydliga tillstånd, och följ skolans eller arbetsplatsens regler.

## Test A — stöd och svensk text, 5 minuter

1. Öppna Mio.
2. Läs kortet **Telefonens stöd**.
3. Kontrollera att **Vald motor** visar antingen:

   - `SpeechTranscriber (avancerad)`, eller
   - `DictationTranscriber (lokal reservmotor)`.

4. Tryck **Starta fas 1-test**.
5. Tillåt mikrofonen.
6. Läs följande testtext långsamt:

   > I dag testar vi Mio på svenska. På matematiklektionen gick vi igenom procent och förändringsfaktor. Läraren sa att provet är på fredag. Mio, kom ihåg att matteprovet är på fredag. Jag ska träffa Emma efter skolan.

7. Vänta tio sekunder.
8. Kontrollera att tidsstämplad text visas.
9. Kontrollera att **Mio upptäckt** är minst 1.

Godkänt: svensk text skapas och Mio hittas som eget ord.

## Test B — låst skärm och bakgrund, minst 10 minuter

1. Låt Mio fortsätta lyssna.
2. Notera klockslaget.
3. Lås telefonen.
4. Efter ungefär två minuter, säg:

   > Bakgrundstest nummer ett. Klockan är ungefär [säg tiden].

5. Efter ytterligare fem minuter, säg:

   > Bakgrundstest nummer två. Mio ska fortfarande lyssna.

6. Vänta två minuter och lås upp telefonen.
7. Öppna Mio om den inte redan visas.
8. Leta efter båda meningarna med tidsstämplar från den låsta perioden.
9. Text som faktiskt överlappar det låsta bakgrundsintervallet ska ha den blå etiketten **BAKGRUND**.
10. I **Bevis från telefonen** ska **Bakgrund/låst skärm loggad** vara grön. En vanlig livscykellogg räcker inte för grönt bevis.

Godkänt: ny text skapades medan skärmen var låst, inte bara före låsningen.

## Test C — paus betyder verkligen av

1. När Mio lyssnar, tryck **Pausa Mio > Tills jag startar igen**.
2. Kontrollera att rubriken blir **Mio är pausad**.
3. Kontrollera att iOS orange mikrofonindikator försvinner.
4. Säg en tydlig mening.
5. Vänta och kontrollera att ingen ny text skapas.
6. Tryck **Fortsätt lyssna**.
7. Säg en ny mening och kontrollera att den nu skapas.

Gör därefter samma sak med **30 minuter** när ni har tid. Tänk på att iOS kan försätta en app utan aktiv mikrofon i vila. Om telefonen är låst kan den planerade fortsättningen därför ske först när appen öppnas igen. Mio visar detta i statusraden.

Godkänt: pausen stänger mikrofonen och manuell fortsättning fungerar utan att tidigare testdata försvinner.

## Test D — ljudavbrott

Gör detta när det passar; ring inte någon utan deras vetskap.

1. Starta Mio.
2. Ta emot ett kort telefonsamtal eller låt ett alarm ringa.
3. Avsluta avbrottet.
4. Säg en ny testmening.
5. Kontrollera **Händelselogg**.

Godkänt: början och slutet på ljudavbrottet loggas. Om iOS ger `shouldResume` ska ny text fortsätta. Om den inte fortsätter ska appen tydligt säga att testet måste startas om.

## Test E — batteri, först 60 minuter och sedan längre

1. Starta med minst cirka 50 % batteri och utan laddare.
2. Låt Mio lyssna i 60 minuter under ungefär normal användning.
3. Lås skärmen en del av tiden och prata ibland.
4. Stoppa Mio efter 60 minuter.
5. Läs **Batteriskillnad** och antalet batteriprover.
6. Skapa och spara testfilen.

Gör senare ett längre 3–4-timmarstest om timtestet ser rimligt ut. Vi sätter ingen godtycklig godkänd procent i förväg; först behöver vi ett verkligt basvärde från telefonen och hennes normala användning.

## Test F — ljudvägsbyte, frivilligt

1. Starta Mio med telefonens mikrofon.
2. Anslut AirPods.
3. Säg en mening.
4. Koppla bort AirPods och säg en ny mening.
5. Kontrollera loggen.

Fas 1 loggar bytet men bygger inte om hela ljudmotorn automatiskt. Om texten stannar ska ni stoppa och starta testet. Resultatet visar vad fas 2 behöver hantera.

## Exportera resultatet

1. Stoppa testet.
2. Scrolla till **Testfil och radering**.
3. Tryck **Skapa testfil**.
4. Tryck **Dela testfil**.
5. Spara JSON-filen i Filer eller skicka den till er själva.

Exporten innehåller tidsstämplad text, batteriprover och diagnostik. Den innehåller aldrig råljud.

Spara också följande tillsammans med filen:

- iPhone-modell: iPhone 13.
- exakt iOS-version.
- vald talmotor i appen.
- om Strömsparläge var på eller av.
- ungefär hur länge skärmen var låst.
- om AirPods användes.

## Fas 1 är klar när

- en svensk lokal Apple-motor är identifierad, eller frånvaron är dokumenterad;
- svensk textkvalitet har bedömts i ett normalt och ett kontrollerat bullrigare rum, utan att spela in ovetande personer;
- text har skapats under låst skärm;
- Mio har upptäckts lokalt;
- paus och stopp bevisligen stänger mikrofonen;
- minst ett 60-minuters batteritest finns;
- minst ett avbrottstest finns;
- testfilen är sparad.
