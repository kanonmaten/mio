# Pianissimo på din dator

Mio skickar korta ljuddelar från iPhone till din egen dator, där **Pianissimo** (`KlangAI/pianissimo-sv`) gör om dem till svensk text. Datorn kör modellen på NVIDIA-GPU:n. Telefonen når den privat via Tailscale, utan öppna portar mot internet. Kontraktet mellan app och server står i [API.md](API.md).

Du behöver:

- CachyOS (eller Arch) med en NVIDIA-GPU med minst ~5 GB ledigt grafikminne, uppskattningsvis ~1 GB till med talarmärkning (ej uppmätt). Provat på RTX 4060 Ti 8 GB.
- Ungefär 16 GB ledigt diskutrymme (Python/CUDA-paket + modellen ~2,5 GB + talarmodellen ~0,5 GB).
- Ett Tailscale-konto (gratis), samma på datorn och telefonen.

## 1. Installera

Uppdatera systemet och starta om om kärnan eller drivrutinen uppdaterades. Kontrollera sedan att GPU:n syns:

```bash
sudo pacman -Syu
nvidia-smi
```

Saknas drivrutinen: `sudo chwd -a`, starta om ([CachyOS CHWD](https://wiki.cachyos.org/features/chwd/chwd/)).

Hämta Mio och kör installationen som din vanliga användare (inte `sudo`):

```bash
git clone https://github.com/kanonmaten/mio.git ~/mio
~/mio/transcription-server/install.sh
```

Skriptet frågar efter ditt lösenord för `sudo` och gör sedan allt detta. Första gången tar det en stund.

1. Installerar `uv`, `rsync`, `curl` och `tailscale` om de saknas.
2. Skapar tjänstekontot `mio-transcription` och kopierar bara serverkoden till `/opt/mio-transcription`.
3. Installerar Python 3.12 och exakt låsta paket (NeMo, PyTorch med CUDA).
4. Skapar `/etc/mio-transcription.conf` med en ny hemlig token och senaste Pianissimo-versionen. Saknas talarmodellens version läggs den till (låst commit).
5. Laddar ner modellerna, startar tjänsten och väntar tills den svarar "redo".
6. Slår på en nattlig uppdatering av Pianissimo (se [Uppdateringar](#uppdateringar)).
7. Kopplar tjänsten till Tailscale om Tailscale redan är inloggat.

Tjänsten startar automatiskt vid boot och startas om om den kraschar. Den lyssnar bara på `127.0.0.1:8765`.

## 2. Tailscale

Om installationen sa att Tailscale inte är inloggat:

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up
sudo tailscale serve --bg http://127.0.0.1:8765
sudo tailscale serve status
```

Öppna länken som visas och logga in. Slå på HTTPS för ditt tailnet om Tailscale ber om det. `serve status` visar din adress, till exempel `https://dator.tail1234.ts.net`. Använd **serve**, aldrig **funnel** (funnel gör tjänsten publik). Inställningen finns kvar efter omstart.

Om `serve` redan används för något annat på samma dator skriver installationen inte över det. Då behöver du själv välja vilken tjänst som ska ligga på `https://…/`.

Valfritt men rekommenderat: begränsa i Tailscales adminpanel (Access controls) så att bara ditt konto når datorn på port 443. Tagga datorn `tag:mio-transcription` och lägg till:

```json
{
  "tagOwners": { "tag:mio-transcription": ["autogroup:admin"] },
  "grants": [{ "src": ["din-epost@example.com"], "dst": ["tag:mio-transcription"], "ip": ["tcp:443"] }]
}
```

Granskar du en befintlig policy: en grant lägger bara till åtkomst, så breda regler måste tas bort för att detta ska begränsa något. Se [grants](https://tailscale.com/docs/features/access-control/grants) och [Serve](https://tailscale.com/docs/reference/tailscale-cli/serve).

## 3. Telefonen

1. Installera Tailscale från App Store och logga in med samma konto. Slå på **VPN On Demand** för Wi-Fi och mobilnät ([guide](https://tailscale.com/docs/features/client/ios-vpn-on-demand)).
2. Installera [AI-gatewayen](../server/README.md) om du inte redan gjort det. Kör sedan `mio-pair` på datorn och skanna QR-koden i Mio under **Inställningar → Dator**. Koden innehåller adresser och tokens för både Pianissimo och AI, så du behöver inte skriva av något.
3. Tryck **Kontrollera anslutningen**. Inget ljud skickas. Starta sedan Mio och läs en mening med namn, datum och siffror; texten kommer efter 15 till 30 sekunder.

Efter en SideStore-förnyelse med LocalDevVPN: slå på Tailscale igen. Datorn måste vara igång och vaken; ställ in energisparläget så att den inte somnar medan du använder Mio.

## Kontrollera

```bash
~/mio/transcription-server/check.sh
```

Skriptet visar modell och version när tjänsten är redo. Inget ljud skickas. I svaret visar `"preprocessing"` om förbehandlingen är på och `"speakerLabels"` om talarmärkningen är `ready`, `loading` eller `off`.

| Problem | Gör så här |
|---|---|
| "Inte redo (HTTP 503)" | Modellen laddar fortfarande. Vänta, eller kör `check.sh --wait` |
| "Ingen kontakt med 127.0.0.1:8765" | `sudo systemctl status mio-transcription` och `sudo journalctl -u mio-transcription -n 50 --no-pager` |
| Tjänsten startar om hela tiden | GPU-minnet är slut (stäng spel och andra GPU-appar) eller CUDA fungerar inte: kör `nvidia-smi` och `install.sh` igen |
| Mio säger fel token (401) | Kör `mio-pair` igen och välj **Para om med QR-kod** i Mio |
| Fungerar lokalt men inte från telefonen | Tailscale på i telefonen? Rätt adress från `tailscale serve status`? Grants som släpper igenom ditt konto? |
| `"speakerLabels":"off"` fast du vill ha talare | `sudo journalctl -u mio-transcription -n 50 --no-pager` visar orsaken. Saknas `MIO_DIARIZATION_REVISION`: kör `install.sh` igen. Transkriptionen fungerar ändå |
| "A server with the specified hostname could not be found" på telefonen | Namnet når inte Tailscales DNS. Slå på **Use Tailscale DNS** i Tailscale-appen och stäng av andra DNS-profiler (t.ex. Quad9, NextDNS, AdGuard under Inställningar → Allmänt → VPN och enhetshantering). |

## Uppdateringar

**Pianissimo uppdateras automatiskt.** Varje natt runt 04:00 kollar datorn om KlangAI har publicerat en ny version. Finns det en:

1. Den nya versionen laddas ner.
2. Tjänsten startas om med den.
3. Blir den redo inom 5 minuter tas den gamla bort från disken.
4. Annars återgår tjänsten direkt till den förra versionen.

Om du använder Mio just när bytet sker blir det en kort lucka i texten.

| Vill du | Kör |
|---|---|
| Uppdatera Pianissimo nu | `sudo /opt/mio-transcription/update-model.sh` |
| Se senaste nattkörning | `journalctl -u mio-pianissimo-update -n 20 --no-pager` |
| Stänga av automatisk uppdatering | `sudo systemctl disable --now mio-pianissimo-update.timer` |
| Uppdatera Mios serverkod (efter `git pull`) | `cd ~/mio && git pull && transcription-server/install.sh` |

**Talarmodellen** (`nvidia/diar_streaming_sortformer_4spk-v2`) är låst till den commit som `install.sh` valde och uppdateras inte på natten. Nattuppdateringen rör bara Pianissimos cache. Byta till senaste: ta bort raden `MIO_DIARIZATION_REVISION=` ur `/etc/mio-transcription.conf` (`sudo nano /etc/mio-transcription.conf`) och kör `install.sh` igen.

**Byta token:** `sudo rm /etc/mio-transcription.conf` och kör `install.sh` igen. Det skapar en ny token (och tar senaste modellen). Para sedan om telefonen med `mio-pair`.

Appen behöver ingen ny version när modellen uppdateras, eftersom API:t är detsamma. Modellversionen syns under Inställningar → Dator → Transkription och Tailscale.

## Förbehandling och talarmärkning

Båda är på som standard och styrs med rader i `/etc/mio-transcription.conf`. Starta om efter ändring: `sudo systemctl restart mio-transcription`.

| Rad | Betydelse |
|---|---|
| `MIO_PREPROCESS=0` | Stäng av förbehandlingen (DC-offset bort, 80 Hz högpass, nivåutjämning med högst +20 dB och mjuk toppbegränsning). Ingen brusreducering används |
| `MIO_SPEAKER_LABELS=0` | Stäng av talarmärkningen; orden får då inget `speaker`-fält |
| `MIO_DIARIZATION_REVISION=<commit>` | Talarmodellens låsta version; sätts av `install.sh` |

Talarmärkningen numrerar upp till fyra talare per session (1, 2, …) i den ordning de hörs först. Den laddas efter att transkriptionen redan är redo, och om den fallerar skrivs en rad i journalen och texten kommer ändå, bara utan talare. Detaljer finns i [API.md](API.md#talarmärkning).

När både förbehandling och talarmärkning är avstängda skickas rå PCM direkt till modellen utan extra PCM→float-konvertering.

**Ej verifierat:** den riktiga talarmodellen och förbehandlingen är bara provade med syntetiska signaler och falska modeller, inte på GPU eller med riktigt tal. Talarmodellen är främst tränad på engelska. Mät gärna med skriptet nedan innan du litar på resultatet.

## Mäta ordfelfrekvens

`scripts/measure_wer.py` mäter Pianissimos ordfelfrekvens (WER) på **publikt** svenskt tal, med och utan förbehandling, i tre villkor: `ren`, `dämpad` (lågpass ~3 kHz, −15 till −25 dB, syntetiskt rum och lågt brus) och `dämpad_två_talare` (två dämpade talare som överlappar 0,5–1 s). Allt byggs i RAM; skriptet skriver ingen ljudfil och skriver bara ut sammanräknade siffror. Använd det aldrig på privata inspelningar.

1. Hämta FLEURS svenska testdel (~440 MB, CC-BY-4.0) till en tillfällig mapp:

   ```bash
   mkdir -p /var/tmp/mio-wer
   /opt/mio-transcription/.venv/bin/hf download google/fleurs data/sv_se/test.tsv data/sv_se/audio/test.tar.gz \
       --repo-type dataset --local-dir /var/tmp/mio-wer/fleurs
   tar -xzf /var/tmp/mio-wer/fleurs/data/sv_se/audio/test.tar.gz -C /var/tmp/mio-wer/fleurs/data/sv_se/audio
   ```

   Andra källor (till exempel Common Voice) går också: lägg 16 kHz mono 16-bit `.wav` med en `.txt` med samma namn bredvid, till exempel `ffmpeg -i klipp.mp3 -ar 16000 -ac 1 -sample_fmt s16 klipp.wav`.

2. Stoppa tjänsten (GPU-minnet räcker inte till två kopior av modellen) och kör mätningen som tjänstekontot:

   ```bash
   sudo systemctl stop mio-pianissimo-update.timer mio-transcription.service
   cd /opt/mio-transcription && sudo -u mio-transcription env $(sudo grep '^MIO_MODEL_' /etc/mio-transcription.conf | xargs) \
       HF_HOME=/var/lib/mio-transcription/models HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 \
       .venv/bin/python scripts/measure_wer.py --data /var/tmp/mio-wer/fleurs/data/sv_se --limit 100
   sudo systemctl start mio-transcription.service mio-pianissimo-update.timer
   ```

   `--json` ger maskinläsbart resultat, `--seed` ändrar de syntetiska villkoren och `--conditions dämpad` kör ett enskilt villkor. Samma frö ger samma syntetiska ljud med och utan förbehandling.

3. Ta bort testdatat: `rm -rf /var/tmp/mio-wer`.

WER räknas på ordnivå efter gemener och borttagen interpunktion; siffror skrivs inte ut som ord. Syntetiska villkor är en grov modell av verkliga rum: bekräfta alltid med ett kort prov med personer som samtycker.

## Avinstallera

```bash
sudo systemctl disable --now mio-transcription.service mio-pianissimo-update.timer
sudo tailscale serve reset
sudo rm -rf /opt/mio-transcription /opt/mio-python /var/lib/mio-transcription /etc/mio-transcription.conf \
    /etc/systemd/system/mio-transcription.service /etc/systemd/system/mio-pianissimo-update.*
sudo systemctl daemon-reload
sudo userdel mio-transcription
```

`tailscale serve reset` tar bort **all** Serve-konfiguration på datorn; hoppa över den om du använder Serve till annat.

## Integritet

- Ljudet behandlas bara i RAM. Inga ljudfiler, transkript eller tokens skrivs till disk eller logg.
- Prestandaloggar (debug-nivå) innehåller bara latenser per steg och sampleantal, aldrig användartext, ljudpayload eller tokens.
- Upp till åtta textsvar sparas i högst ~90 s i minnet så att ett återförsök inte transkriberas två gånger.
- Talarmärkningen analyserar rösterna. Dess talarcache (röstkännetecken, inte ljud) finns bara i RAM, per session, och raderas när appen avslutar sessionen, efter 10 minuter utan nytt ljud eller vid omstart. Högst fyra sessioner hålls samtidigt.
- Tjänsten har ingen swap och inga core dumps. Undvik viloläge till disk (hibernation) medan Mio används, eftersom det kan skriva RAM till disk.
- Spela bara in andra med deras samtycke och enligt lokala regler. Berätta att talarmärkningen skiljer röster åt, eller stäng av den med `MIO_SPEAKER_LABELS=0`.

## För utvecklare

Tester med falska modeller och syntetiska signaler, utan GPU eller inspelat tal:

```bash
uv --directory ~/mio/transcription-server sync --locked --extra test --python 3.12
uv --directory ~/mio/transcription-server run pytest -q tests
```

Tjänsten kräver CUDA och byter aldrig till CPU. Installationen följer modellkortets [NeMo-användning](https://huggingface.co/KlangAI/pianissimo-sv) och NVIDIAs [NeMo-installation](https://docs.nvidia.com/nemo/speech/3.0.0/starthere/install.html), med Mios låsta `uv.lock` (NeMo 2.7.0). En ny Pianissimo-version som kräver nyare NeMo blir inte redo; då återgår nattuppdateringen till föregående version. Uppdatera i så fall `pyproject.toml`/`uv.lock` och kör `install.sh`.
