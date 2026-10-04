# Pianissimo, återanslutning och bakgrund

Gäller nya arbetskopian efter motorbytet, inte build 5. Alla telefonprov nedan är **ej körda**. Registrera commit, IPA-hash, build, iOS, iPhone, serverversion/modellrevision och resultat. Använd ett känt syntetiskt svenskt facit och samtyckande talare; lagra inte testljud i projektet. [Installation](../transcription-server/README.md), [API](../transcription-server/API.md).

| ID | Prov | Acceptans |
|---|---|---|
| T01 | Ren installation utan server/token; Starta och Avbryt under anslutning | Begripligt fel/förberedelse; ingen mikrofon efter avbryt, manuella poster fungerar |
| T02 | Spara token, tomt för samma adress, ny adress, ogiltig token/adress, glöm anslutning | Tydlig bekräftelse/fel; Keychain, ingen hemlighet i export, ny adress kräver ny token |
| T03 | Hälsokontroll utan ljud, fel token, modell laddar, API version 2, fel ljudformat | Modell/revision/version och tid visas vid lyckat test; inkompatibilitet/åtkomstfel förståeligt |
| T04 | Svenska namn, datum, siffror, tystnad, nära/klassrumsavstånd | Mät ordprecision mot facit; inga tystnadshallucinationer. Mät textlatens, sikte 15–30 s |
| T05 | Kontinuerligt tal minst 2 min över varje 20 s-gräns, stopp mitt i mening | Inga dubbla ord/systematiska ordluckor. Verkliga ljudtider, slutdel eller explicit lucka |
| T06 | Aktiv session, stoppa servern 20 s och starta | Offline begripligt, UI svarar, samma session och mikrofon; automatisk återanslutning utan dubbel text |
| T07 | Avbrott 90 s, sedan server tillbaka | Högst 60 s ljud väntar; gammalt ljud borta, luckor i session/lektion/kopierad text. Sen text återskapar inte förlorade delar |
| T08 | Server överlastad/429, långsamt svar, tappat svar, ogiltiga ordtider, fel token mitt i session | Tidsgränser/backoff, inga UI-lås; samma chunk-ID vid retry; ogiltigt svar/åtkomstfel pausar mikrofon och bevarar lektion |
| T09 | Paus/stopp under upload och offline, avbryt väntan, starta/stoppa snabbt | Mikrofon släcks först; högst 15 s dränering, ingen sen text efter avslut; saknad sluttext blir lucka |
| T10 | Låst skärm 10 min och annan app, vardag respektive lektion | Faktisk bakgrundstext med riktiga ljudtider; session kvar. Om iOS avbryter ska lucka och Fortsätt visas |
| T11 | Telefonsamtal, Siri, alarm, ljudvägsbyte, hörlurar ur/in och foreground | Mikrofonen startar inte automatiskt. Välj själv Fortsätt när iOS tillåter; samma session/lektion bevaras och avbrott märks |
| T12 | Media services reset där det kan återskapas, tvångsavsluta app, telefonreboot | Mikrofon startas endast på nytt användartryck; gamla data kvar, ofullständighet tydlig. Markera Blockerad om reset inte kan återskapas |
| T13 | Wi-Fi → mobilnät, flygplansläge av/på, Tailscale av/på | Aktiv session återansluter, offline-/luckstatus korrekt; ingen överföring till publik eller ändrad server |
| T14 | Datorreboot, processkrasch, sömn/uppvaknande | systemd och Serve återkommer efter reboot/uppvaknande; telefonen återansluter. Sömn/avstängning ger väntad downtime |
| T15 | SideStore-förnyelse med LocalDevVPN, återanslut Tailscale | Begriplig offline-status, därefter verifierad anslutning; inga ändringar av tokens behövs |
| T16 | Aktivera text-AI medan äldre ljud inväntar transkript | Ljud före samtycket skickas inte vidare till vardags-AI; gränsöverskridande segment hoppas över. Nya förslag kräver fortfarande Ja |
| T17 | Inställningar från alla flikar, sparande, kopiering, fel, haptics av/på | Samma samlade navigation, synlig återkoppling utan döda tryck, ingen dubbelsparning |
| T18 | VoiceOver, största Dynamic Type, mörkt läge, Minska rörelse/genomskinlighet | Alla knappar/fält/status går att läsa och nå; ingen nödvändig information bara i färg/haptics |
| T19 | Batteriprov 60 min, sedan 3–4 h; iPhone 16 Pro och därefter 13 | Dokumentera faktisk batteriåtgång, temperatur, app-RAM, server-GPU och luckor. Ingen garanti om heldag före mätning |
| T20 | Modelluppdatering/rollback med samma API; negativt tailnet-grantprov | Appen behöver inte byggas om; metadata ändras, rätt identitet/token krävs, serverport endast loopback |

Kör även H01–H15 och relevanta AI-/lektions-/Access-prov i [helhetsplanen](TESTPLAN_HELHET.md). Gröna Python-/Node-tester eller en lyckad GPU-laddning ersätter inte Xcode-kompilering, XCTest, svenskt tal eller enhetsprov.

Använd [enhets- och mätprotokollet](ENHETSPROV.md) för känt svenskt facit, delgränser, sample-/requestantal, nät-/datoromstart samt jämförbara batteri-/värme-/latensvärden. Resultat är separata för iPhone 16 Pro/iPhone 13 och varje exakt iOS-/app-/modellrevision; ingen förbättring tillskrivs koden utan jämförbart mätunderlag.

Bakgrundsavbrott i äldre export visade `Session activation failed`, men exakt orsak är inte bevisad. Förbättringen separerar nät/fångst, serialiserar AVAudioSession/engine-ändringar, hanterar interruptions/routes/media reset, kontrollerar verkliga buffertar och bevarar sessionen. `UIBackgroundModes=audio` fanns redan; det räcker inte ensamt för stabilitet. Ingen tyst ljuduppspelning eller periodisk bakgrundsväckning används.
