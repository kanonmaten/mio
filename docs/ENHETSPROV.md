# Fysiska enhetsprov och mätprotokoll

Denna mall anger kommande prov. Den innehåller inga nya telefonresultat eller uppmätta kvalitets-/prestandalöften. Kör först [verifieringsgrinden](VERIFIERING.md), exakt revisions Xcode/XCTest/IPA-kontroll och [installation](INSTALLATION.md). Använd [helhetstestplanen](TESTPLAN_HELHET.md) och [Pianissimo-testplanen](TESTPLAN_PIANISSIMO.md) tillsammans med mallen. Daterade äldre resultat i [TESTRESULTAT_V0_1](TESTRESULTAT_V0_1.md) gäller endast sin historiska revision.

## Provenance och ordning

Prova först på **iPhone 16 Pro**, därefter **iPhone 13**. Registrera faktisk iOS 26-/27-version där den kan provas; ett resultat på ena systemversionen överförs inte till den andra. En otillgänglig kombination markeras **ej körd** med orsak.

Fyll i följande före varje körning:

| Underlag | Registrera |
|---|---|
| App | Commit, eventuell diff-/kodkonfigurationsdigest, byggnummer, Actions-URL, runner, Xcode/SDK, XCTest-/concurrencyresultat och IPA-SHA-256 |
| Installation | Installerad IPA/hash, datum, signeringsväg och att appidentiteten är `app.mio.assistant` |
| Telefon | Modell, exakt iOS-version, batterihälsa, ledigt lagringsutrymme, Strömsparläge, termiskt utgångsläge och startbatteri |
| Text-AI | Gatewayrelease, bundeldigest, skyddad status-/konfigurationsrevision, valda ask/everyday/lesson-profiler och testernas separata sändningsgodkännande |
| Privat STT | Paket-/lockfilrevision, faktisk Pianissimo-modellrevision, server-/GPU-/drivrutinsuppgifter, systemd-konfiguration och varm/kall modellstart |
| Nät och villkor | Wi-Fi/mobildata/Tailscale, dator vaken/sömnläge, avstånd/brus, skärmläge/ljusstyrka, samtidiga appar och diagnostik-/mätverktyg |

Skriv inte tokens, Apple-uppgifter, privata serveradresser eller hemliga konfigurationsvärden i protokollet. Använd syntetiskt innehåll. Spela bara in personer som uttryckligen samtycker och följ lokala regler. Mio sparar inget råljud; skapa ingen ljudfil eller inspelningsfixture i repot för att utföra detta prov. Verkliga provideranrop med syntetisk text kräver separat godkännande och räknas i samma gemensamma kvot.

## Nativegränser och vardagsflöde

| Prov | Förväntan och bevis |
|---|---|
| Första start/Keychain | AI börjar avstängd. Privat STT-/gateway-/Access-konfiguration hålls åtskild. Nekad mikrofonåtkomst visas begripligt; läsning av sparat innehåll kräver ingen mikrofonstart |
| URLSession/privat nät | HTTPS och privat Tailscaleväg fungerar; redirect avvisas. Offline, avbrott, avbruten fråga och för stor/ogiltig respons avslutar rätt operation. Sen respons återstartar inte mikrofon eller sparar fel fråga |
| Filskydd/export | Kontrollera skapandets Data Protection på faktisk iOS-enhet, fil-/katalogskydd och backupundantag. Två exporter får olika namn; en fil som delas skrivs inte över. Misslyckat skydd eller exportborttagning ger synligt fel |
| Radering/återstart | Radera tre domänlager, diagnostik, interna exporter och båda anslutningarna. Prova delvis fel med kontrollerad felinjektion i verifieringsmiljö: journalen återupptar samma avsikt, visar retry/blockerat läge och öppnar inte nytt mikrofon-/AI-arbete. Förstör inte privata verkliga data för felinjektion |
| EventKit/AlarmKit/notiser | Prova Kalender Spara/Avbryt, alarm-/påminnelsebehörighet och avbokning. AI-svar kan inte utlösa dessa åtgärder; lokala förslag kräver granskning och Ja |
| Notisnavigation | Från kall och varm app öppnas rätt post eller morgon/kväll först efter laddade lager. Raderad/saknad post ger begriplig fallback. Låsskärmen visar generisk text och payload endast opaka ID:n. Trycket startar ingen inspelning, AI eller systemåtgärd |
| Dag/tidszon | Prova förgrund efter midnatt, tidszonsbyte och betydande klockändring. Följande Idag byter dag; ett valt historiskt datum bevaras. En morgon-/kvällsnotis öppnar dagens vy |
| Tillgänglighet | VoiceOver läser upp uppgiftsnamn och åtgärd. Prova minst 44 × 44 punkters träffyta, större Dynamic Type, mörkt läge, Minska rörelse och Minska genomskinlighet; särskilt iPhone 13, ark och tangentbord |

Tre native UI-smokeprov kompletterar matrisen, men ersätter inte fysisk VoiceOver eller dessa systemgränser. Filskydd/Keychain/AlarmKit på verklig telefon ska ha eget resultat även om simulatorn är grön.

Kör också reliabilityraderna R01–R15 i helhetstestplanen med de nativevariationer som är möjliga. Granska särskilt vardag–lektion–vardag, fel vid lektionsstart/finalisering, ändrat förslag under granskning med bevarade egna ändringar, uttryckligt datumval, delvis färdiga lektionsdelar efter omstart och äldre/okänd källfärskhet efter rättning. En rättning får inte skicka om text automatiskt. Ett svar stannar tillfälligt tills **Spara svaret som anteckning** följs av lokal granskning och Spara; det skapar ingen konversationshistorik, extra modellanrop eller systemåtgärd. Konfigurationsbyte kräver ny granskning/aktivering efter 409 och skickar inte om automatiskt.

## Svensk referens över chunkgränser

Förbered en skriftlig, syntetisk svensk referens som en samtyckande talare läser i minst två minuter. Inkludera vardagsspråk, namn, siffror, datum, klockslag, uppgifter och någon ämnesförklaring. Lägg kontrollerade fraser både mitt i regioner och över 20-sekundersgränserna; använd samma text, talare, avstånd och brusvillkor vid jämförelser. Spela inte in andra personer som testbakgrund.

1. Starta en session uttryckligen, läs referensen och stoppa uttryckligen. Bevara originaltranskriptionen separat från visningsrättningar.
2. Jämför referensen mot originaltexten, med samma dokumenterade normalisering av skiljetecken, gemener och tal i samtliga körningar. Räkna substitutioner, bortfall och tillägg. Om WER används: `(substitutioner + bortfall + tillägg) / antal referensord`; redovisa också tydliga namn-/datumfel och upprepningar över gränserna.
3. Kontrollera final tail efter ett kort avslut, dubbletter/överlapp, gapmarkeringar och tidsbevis. Uppskattad callbacktid får inte beskrivas som giltigt host-/sample-tidsbevis.
4. Upprepa i dokumenterade tysta/brusiga villkor. Redovisa antal körningar och individuella resultat; jämför inte kvalitet med ett annat modell-/server-/referensvillkor utan att ange skillnaden.

Detta mäter STT. AI:s detaljerade anteckningar, giltiga JSON-svar, godkända förslag och användarens rättningar bedöms var för sig. Status, grön fixture eller saknad reasoning-usage bevisar inte faktisk modellkvalitet eller internt reasoningbeteende.

## Audio, avbrott och återhämtning

Använd textfri diagnostik och separat kontrollerad felinjektion där verkliga nativehändelser inte går att framkalla säkert. Ange alltid vilken händelse som faktiskt inträffade; ett ljudvägsbyte bevisar inte ett mediaserverreset.

| Scenario | Registrera och kontrollera |
|---|---|
| Konvertering | Verkligt inputformat/sample rate, producerade PCM16/16 kHz-frames, tidsvaliditet, formatbyte och converter flush/final tail. Sätt antal frames i relation till insignalens varaktighet och mät separat konverteringstid/CPU; inga råsamples i loggen |
| Drop/continuity | En och två tappade taps, upprepade tapp och formatbyten. Verkliga saknade frames ger synliga luckor och ny relevant epoch; klockjitter får inte bli falsk förlust eller hoptryckt tidslinje |
| Retry/antal anrop | Räkna STT-försök, lyckade regioner, retries, stabil chunkidentitet/cachekonflikter och separata AI-anrop. Redovisa regionlängd/överlapp och slutbitar; jämför samma tal/nätvillkor |
| Nät borta 20 s respektive 90 s | Kontrollera mikrofon-/transkriptions-/AI-state var för sig. Mikrofonen kan fortsätta under STT-nätfel. Återhämtning använder endast fortfarande giltigt RAM-ljud; förlorat ljud får lucka och återskapas inte |
| Sampleexpiry/stop | De tidigaste retained samples utlöper högst 60 s från ursprunglig capture, inklusive assembler/pending/inflight. Stop drain är högst 15 s och kortare när originalets expiry kräver det. Kontrollera cancel och att appens ljudreferenser släpps före väntande UI-/diagnostikcallback |
| Wi-Fi/mobildata/Tailscale | Byt nät under vardag och lektion. Registrera återhämtning, textfria felkategorier och vilka regioner som gick förlorade; fast latensgaranti förväntas inte |
| PC-/tjänsteomstart | Starta om privat dator/tjänst under session, prova kall och varm modell. Återanslutning blir begriplig; ingen Apple-/CPU-/moln-STT-fallback aktiveras |
| Samtal/ljudväg/reset | Prova verkligt samtalsavbrott, tillbehör/route change och mediaserverreset där det går. Sessionens pause och manuella Fortsätt är tydliga. Ingen automatisk mikrofonstart efter avbrott, reset, tvångsavslutning eller timerpaus |
| Tvångsavslutning/omstart | Tidigare text och sparade lektionsdelar finns kvar. RAM-ljud återställs inte. Starta/Fortsätt kräver nytt användartryck |

Faktisk 60-sekundersgräns mäts från captureankaret, inte från chunkens slut eller första transportförsöket. Om nativeverktyget inte kan observera referenssläpp eller rätt tidpunkt, markera den delen som **ej verifierad** och behåll den deterministiska regressionens separata bevis.

## Långprov, latens, värme och batteri

Kör först **10 minuter med låst skärm i vardagsläge** och **10 minuter i lektion**. Gå därefter vidare till **en timmes batteriprov** och, om resultaten medger det, **3–4 timmar**. Alla pass börjar med dokumenterade villkor. Använd ingen laddare under batteriprovet, stäng av Strömsparläge, håll ljusstyrka/nät/skärmläge och kringappar lika och ange batterihälsa/start-/slutprocent. Mätverktygens egen belastning ska redovisas.

Mät och redovisa separata storheter:

| Storhet | Definition |
|---|---|
| STT-latens | Sample-/regionankare till slutlig text, samt chunkavslut till mottagen/visad final; antal observationer, median och p95 när underlaget räcker |
| Återhämtning | Nät/tjänst tillbaka till ny fungerande finaltext, med faktiskt tappad ljudtid och synliga gap |
| AI-latens/kvot | Godkänd sändning till validerat svar, task/providerprofil, deadline/felkategori och faktiskt antal anrop; separat från STT |
| Telefon | Batteriförändring och tid, observerad värme/termiskt tillstånd, processminne och eventuell avbruten/strypad capture med dokumenterad metod |
| Dator/GPU | Kall/varm modell, inferenstid, CPU/GPU-belastning, modellminne och termiskt tillstånd med faktisk mätmetod |
| Audioarbete | Input/output-frameantal, convertertid, retries/förfrågningsantal och formatbyten; textfria räknare |

Skriv ned om skärmlås, energiläge, bakgrundsbegränsning eller termiskt tillstånd förändrade flödet. Den avsedda 15–30-sekundersupplevelsen är ett designmål, inte ett uppmätt löfte. Batterivinst, precision eller transportändring kräver jämförbar baslinje och upprepade riktiga mätningar. Långhistorikens Linuxmått kan inte ersätta detta underlag.

## Resultatmall

Använd **G** (godkänt), **U** (underkänt), **B** (blockerat) eller **ej körd** per rad. Ett blockerat prov ska ange vilket villkor som saknas. Rapportera actual/expected, exakta versioner och evidensväg utan privata texter eller hemligheter.

```text
Prov-ID/scenario:
Datum och utförare:
Appcommit/diffdigest/build/IPA-hash:
Native körnings-URL, runner, Xcode/SDK/XCTest/concurrency:
Telefon och exakt iOS:
Gatewayrelease/bundeldigest/configrevision/profiler:
STT-paket-/modellrevision och server/GPU:
Villkor, mätmetod och antal repetitioner:
Förväntat:
Faktiskt observerat:
Resultat G/U/B/ej körd:
Mätvärden med enhet och tidsankare:
Textfri logg/evidens, separat privat exportplats vid behov:
Fel, begränsning och nästa prov:
```

Förvara privata exporter utanför repot. Uppdatera [status](STATUS.md) bara med faktiskt utförda kontroller för den exakta revisionen. Håll käll-/Linuxkontroller, nativebygge/XCTest, IPA, installation, fysisk acceptans och verkliga providerprov som separata resultat.
