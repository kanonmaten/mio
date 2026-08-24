# Testresultat för fas 1

Den exporterade råfilen innehåller transkriberad text och förvaras privat utanför Git-repot. Här sparas endast de mätvärden och slutsatser som behövs för fortsatt utveckling.

## Rökprov 2026-08-20

- Enhet: iPhone 13 med iOS 26
- Session: 22:29:02–22:31:32 svensk sommartid
- Total sessionstid: 2 minuter 30 sekunder

### Resultat

| Område | Resultat | Bedömning |
|---|---|---|
| `SpeechTranscriber`-modul | `transcription.sv` kunde inte installeras; status `Not Installing` | Inte tillgänglig i detta test |
| `DictationTranscriber`-fallback | `DictationTranscriber`, `sv_SE` | Godkänd i korttest |
| Text | 5 finala segment, alla med giltig ljudtid | Pipeline och export fungerar |
| Mio-detektion | 2 segment innehöll fristående Mio | Godkänd i korttest |
| Bakgrund | 2 intervall, totalt 11 sekunder; 1 segment låg helt i bakgrunden och innehöll Mio | Äkta kort bakgrundsbevis; lång stabilitet återstår |
| Paus | Paus tills manuell start loggades; ingen senare text skapades | Grundbeteendet godkänt |
| Batteri | 5 prover, samtliga 65 %, utan laddare | Mätningen fungerar; testet är för kort för förbrukningsslutsats |
| Fel | 0 fel, 1 varning om avancerad modell | Ingen krasch eller oväntad avslutning |
| Tappade buffertar | 0 rapporterade | Bra i korttest; långt stresstest återstår |
| Råljud/OpenAI | Inget råljud i exporten och inga OpenAI-händelser | Fas 1-kontraktet hölls |

### Transkriptionskvalitet

Korta fraser var begripliga och “Hej Mio” kändes igen två gånger. Ett annat segment saknade Mio-detektion och började med en ovanlig transkribering, men utan ett nedskrivet facit går det inte att avgöra om det var en verklig wake-word-miss. Fem mycket korta segment räcker inte för att bedöma klassrumstal eller normal samtalshastighet.

### Viktig tolkning

JSON-filen bevisar att appen var i bakgrunden när källjudet skapades. Den kan inte ensam skilja skärmlåsning från en annan bakgrundsövergång. Testaren behöver därför notera om telefonen faktiskt var låst. Oavsett är 11 sekunder långt under testplanens krav på minst 10 minuter.

## Nästa testordning

1. Test A med exakt facit i fem minuter.
2. Test B med minst tio minuter låst skärm.
3. Test C med paus och manuell fortsättning.
4. Test D med ett kontrollerat alarm eller samtal.
5. Test E utan laddare i minst 60 minuter.
6. Först därefter ett 3–4-timmarsprov.

Fas 1 ska inte markeras som slutgodkänd förrän punkterna i `TESTPLAN_FAS_1.md` och `KRAVMATRIS_FAS_1.md` är verifierade.
