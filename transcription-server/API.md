# Privat transkriptions-API v1

API:t är oberoende av modell/NeMo-version. HTTPS via Tailscale Serve, Bearer-token på **alla** endpoints. Intern HTTP endast loopback. Ingen redirect, cookie eller diskcache i appklienten. `Cache-Control: no-store` på svar. API-dokumentationsendpoint är avstängd.

## GET /health

200 om redo, 503 under laddning/fel. Samma JSON-form vid laddning; `status` är `loading`, `ready` eller `failed`. 401 vid fel token. Inget ljud används.

```json
{
  "apiVersion": 1,
  "serverVersion": "1.0.0",
  "status": "ready",
  "metadata": {"model": "KlangAI/pianissimo-sv", "revision": "full-model-commit", "backend": "nemo-pytorch-cuda"},
  "sampleRate": 16000, "channels": 1, "encoding": "pcm_s16le_wav",
  "maxSeconds": 24, "maxBytes": 1048576,
  "preprocessing": true, "speakerLabels": "ready"
}
```

Klienten kräver API 1, redo, giltig metadata, exakt ljudformat och kapacitet för sin största del: med pausstyrda delar (se nedan) minst 24 sekunder/768044 byte; den äldre klienten med fasta 20 s krävde 22 sekunder/704044 byte. Fler additiva fält accepteras.

Additiva fält (från 2026-10-11, valfria för klienten): `preprocessing` är `true` när serverns förbehandling är på. `speakerLabels` är `loading` medan talarmodellen laddas, `ready` när ord får talare och `off` när talarmärkning är avstängd eller modellen inte kunde laddas. Transkriptionen är redo oberoende av talarmodellen; `status` påverkas aldrig av den. Brytande ändringar ska få nytt API-kontrakt; behåll v1 under migrationen. Modellnamn eller revision väljs aldrig av appen.

## POST /v1/transcribe

`Content-Type: audio/wav`. Binär RIFF/WAV, okomprimerad signed PCM16 little endian, mono 16000 Hz. Inga multipart-filer, ingen content-encoding, inga filer på serverdisk. Max 24 s, 1048576 byte. Begärans body måste vara fullständig inom 10 s. Max en begäran/inference åt gången, ingen väntkö på servern.

Obligatoriska headers:

| Header | Betydelse |
|---|---|
| Authorization | `Bearer <token>`; 32–256 tecken A–Z/a–z/0–9/underscore/bindestreck |
| X-Mio-Session-ID | UUID för den användarstartade sessionen |
| X-Mio-Chunk-ID | UUID för ljuddelen, samma vid retry |
| X-Mio-Sequence | Icke-negativt sekvensnummer inom fångstomgången |
| X-Mio-Start-Sample | Icke-negativ sampleoffset inom fångstomgången; inkluderar vänsterkontext |
| X-Mio-Core-Start | Första sample i delens ägda område, relativt WAV-start |
| X-Mio-Core-End | Exklusiv sista sample i ägda området, högst antal WAV-samples |

Klienten skär ägda områden vid naturliga pauser, 8–22 s långa, med 1 s kontext på varje tillgänglig sida. Största del blir därmed 22 + 2 × 1 = 24 s (384000 samples, 768044 byte), vilket är exakt serverns gräns; ett enda sample till ger 422. Servern kräver ingen viss längd: kortare slutdelar och den äldre klientens fasta 20 s-områden fungerar som förut. Sista delen flushas vid paus/stopp/avbrott. Tidsankaret behålls från mikrofonens hostTime; saknat ljud komprimeras inte bort. Sekvens/offset kan börja om efter paus, medan chunk-ID alltid är unikt. Servern ska återge identiteterna exakt; UUID-formatets versaler saknar betydelse.

200-exempel (ordtider relativt **hela WAV-delen**, även kontextord):

```json
{
  "apiVersion": 1,
  "sessionID": "b6e59117-89a4-49eb-81be-451c12738613",
  "chunkID": "d5821461-d257-474c-be09-6599e44a66d2",
  "sequence": 0, "startSample": 0,
  "words": [{"text": "Hej", "start": 0.24, "end": 0.48, "speaker": 1}],
  "metadata": {"model": "KlangAI/pianissimo-sv", "revision": "full-model-commit", "backend": "nemo-pytorch-cuda"}
}
```

Tomt `words` är giltig tystnad. `speaker` är additivt och valfritt: heltal 1–4 eller `null`. Fältet saknas helt när talarmärkning är av (`speakerLabels` inte `ready`), så svaret är då exakt som tidigare. `null` betyder okänd talare: ordets tidsmitt ligger i kontexten utanför ägda området, ingen talare var aktiv, sessionen har avslutats eller talarmodellen misslyckades för just den delen. Talarnummer gäller inom en session och följer ordningen talarna först hördes; de är inga identiteter och kan byta nummer efter 10 minuters tystnad, serveromstart eller ett fel. Ett misslyckat talarsteg ger aldrig fel på transkriptionen. Skulle svaret med talare överstiga 262144 byte skickas orden utan `speaker`. Högst 1500 ord, 400 UTF-8-byte per ord, sorterade ändliga starttider och giltiga sluttider inom ljudets längd. Servern tillåter högst 100 ms avrundning i modellens sluttid och klipper den till ljudslutet; klientens validering har 20 ms tolerans. Slutdelar under 1 s får bara tyst högerutfyllnad inför NeMo för att inte flytta tidsankaret. Appen kräver dessutom ett JSON-svar högst 262144 byte. Appen behåller ord vars tidsmitt ligger i ägda området och sammanfogar deras text lokalt. Råtext rättas aldrig i lagringen. Varje sparat segment får modellrevision och chunk-ID. Gränsord måste provas på riktigt tal: detta är chunkad inference, inte en garanti för perfekt löpande diarisation eller ordalignment.

Samma session/chunk-ID och identisk metadata/body ger samma cachesvar under cirka 90 s; olika innehåll med samma ID ger 409. Upp till åtta textsvar/fingerprints lagras i RAM, aldrig ljud i cache. Efter TTL eller processrestart kan samma ljud behöva infereras igen. Klienten använder chunk-ID och sin aktiva sessionsgeneration för att undvika dubbel eller sen lagring.

Servern loggar vid debug-nivå bara textfri prestandadata per anrop (total latenstid, delsteg och sampleantal). Ingen användartext, ljudpayload eller token loggas.

## Förbehandling före modellen

Modelloberoende och bara i RAM, på som standard (`MIO_PREPROCESS=0` stänger av): DC-offset tas bort, 80 Hz högpass (amplitudsvar som andra ordningens Butterworth, nollfas via FFT så ordtider inte flyttas), nivå mot cirka −23 dBFS RMS mätt på talliknande ramar, högst +20 dB förstärkning och ingen förstärkning av delar som bara innehåller tystnad eller jämnt brus, samt mjuk toppbegränsning under −0,5 dBFS i stället för klippning. Ingen brusreducering: sådan försämrar ofta modern taligenkänning ([arXiv 2512.17562](https://arxiv.org/abs/2512.17562)). WAV-längd, sampletakt, ordtider och cache-fingerprint (beräknat på det mottagna ljudet) är oförändrade. Talarmodellen får samma förbehandlade ljud.

Om både förbehandling och talarmärkning är avstängda gör servern ingen PCM→float-konvertering före ASR.

## Talarmärkning

Valfri, på som standard när modellen kan laddas (`MIO_SPEAKER_LABELS=0` stänger av). NVIDIA Streaming Sortformer `nvidia/diar_streaming_sortformer_4spk-v2` (NeMo, CUDA, högst fyra talare, låst commit i `MIO_DIARIZATION_REVISION`). Bara varje dels ägda område matas in i modellens strömmande talarcache, så kontextsekunder räknas inte två gånger. Cachen hålls per `X-Mio-Session-ID` enbart i processens RAM: aldrig disk, logg eller svar. Den raderas när klienten avslutar sessionen, efter 10 minuter utan ny del, när fler än fyra sessioner är aktiva (äldsta först) och vid omstart. Modellen är främst tränad på engelska; svensk kvalitet och den faktiska NeMo-körningen är **ej verifierade** på GPU.

## DELETE /v1/sessions/{sessionID}

Valfri för klienten och additiv. Bearer-token krävs. Raderar sessionens talarcache och cachade textsvar direkt. 204 utan kropp, även för okänd session; 400 `invalid_session` om ID:t inte är ett UUID. En sen del för samma session får därefter `speaker: null` i stället för ny numrering. Utan anropet raderas cachen ändå efter 10 minuter.

## Fel och återhämtning

Felkropp: `{"error":"machine_readable_code"}` utan ljud, text, token eller traceback. 400 fel metadata/header; 422 ogiltig WAV/längd; 401 token; 409 krock; 413 storlek; 415 format; 429 upptagen; 503 modell inte redo; 502 ogiltigt modellsvar. 408 vid långsam upload. 429/503 anger `Retry-After: 5`. Uvicorns yttre samtidighetsgräns kan ge ett generiskt 503 utan JSON; klienten tolkar HTTP-status före kroppen.

Aktiv appsession försöker igen vid nätfel och 408/429/500/502/503/504 med jitter och fördröjning upp till 30 s. Nätbyte/foreground väcker återförsök. Fel token, inkompatibelt kontrakt eller ogiltigt svar kräver åtgärd och pausar mikrofonen. Kö/inflight förfaller när äldsta medföljande ljudsample är 60 s gammalt; förlust markeras som lucka och sen text ignoreras. Slutdränering får högst 15 s och kan avbrytas. Ingen diskbaserad offlinekö.

Modellprocessen avslutas vid fastnad inference (45 s, förbehandling och talarsteg inräknade) och laddning (300 s), därefter hanterar systemd omstart. Talarmodellen laddas i bakgrunden efter att transkriptionen blivit redo; misslyckas den stängs bara talarmärkningen av. Klientens anrop är tidsbegränsade. Tjänsten är för en privat användare, utan publik port, distribuerad kö, autoskalning eller HA.
