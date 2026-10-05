# Pianissimo på din dator

Mio skickar korta ljuddelar från iPhone till din egen dator, där **Pianissimo** (`KlangAI/pianissimo-sv`) gör om dem till svensk text. Datorn kör modellen på NVIDIA-GPU:n. Telefonen når den privat via Tailscale, utan öppna portar mot internet. Kontraktet mellan app och server står i [API.md](API.md).

Du behöver:

- CachyOS (eller Arch) med en NVIDIA-GPU med minst ~5 GB ledigt grafikminne. Provat på RTX 4060 Ti 8 GB.
- Ungefär 15 GB ledigt diskutrymme (Python/CUDA-paket + modellen ~2,5 GB).
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
4. Skapar `/etc/mio-transcription.conf` med en ny hemlig token och senaste Pianissimo-versionen.
5. Laddar ner modellen, startar tjänsten och väntar tills den svarar "redo".
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
2. Visa token på datorn och för över den privat, till exempel via din lösenordshanterare:

   ```bash
   sudo sed -n 's/^MIO_TRANSCRIPTION_TOKEN=//p' /etc/mio-transcription.conf
   ```

3. I Mio: kugghjulet → **Transkription**. Ange adressen från `tailscale serve status` (bara `https://…ts.net`, ingen sökväg) och token. Tryck **Spara anslutning** och sedan **Testa sparad anslutning**. Inget ljud skickas vid testet.
4. Starta Mio och läs en mening med namn, datum och siffror. Texten kommer efter cirka 15–30 sekunder.

Efter en SideStore-förnyelse med LocalDevVPN: slå på Tailscale igen. Datorn måste vara igång och vaken; ställ in energisparläget så att den inte somnar medan du använder Mio.

## Kontrollera

```bash
~/mio/transcription-server/check.sh
```

Skriptet visar modell och version när tjänsten är redo. Inget ljud skickas.

| Problem | Gör så här |
|---|---|
| "Inte redo (HTTP 503)" | Modellen laddar fortfarande. Vänta, eller kör `check.sh --wait` |
| "Ingen kontakt med 127.0.0.1:8765" | `sudo systemctl status mio-transcription` och `sudo journalctl -u mio-transcription -n 50 --no-pager` |
| Tjänsten startar om hela tiden | GPU-minnet är slut (stäng spel och andra GPU-appar) eller CUDA fungerar inte: kör `nvidia-smi` och `install.sh` igen |
| Mio säger fel token (401) | Klistra in token igen, utan mellanslag. Det är inte text-AI:ns token |
| Fungerar lokalt men inte från telefonen | Tailscale på i telefonen? Rätt adress från `tailscale serve status`? Grants som släpper igenom ditt konto? |
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

**Byta token:** `sudo rm /etc/mio-transcription.conf` och kör `install.sh` igen. Det skapar en ny token (och tar senaste modellen). Spara sedan den nya token i Mio.

Mios app behöver ingen ny version när modellen uppdateras: appen bryr sig bara om API:t, inte om vilken modellversion som körs. Den visar dock aktuell version under **Testa sparad anslutning**.

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
- Upp till åtta textsvar sparas i högst ~90 s i minnet så att ett återförsök inte transkriberas två gånger.
- Tjänsten har ingen swap och inga core dumps. Undvik viloläge till disk (hibernation) medan Mio används, eftersom det kan skriva RAM till disk.
- Spela bara in andra med deras samtycke och enligt lokala regler.

## För utvecklare

Tester med en falsk modell, utan GPU eller ljud:

```bash
uv --directory ~/mio/transcription-server sync --locked --extra test --python 3.12
uv --directory ~/mio/transcription-server run pytest -q tests
```

Tjänsten kräver CUDA och byter aldrig till CPU. Installationen följer modellkortets [NeMo-användning](https://huggingface.co/KlangAI/pianissimo-sv) och NVIDIAs [NeMo-installation](https://docs.nvidia.com/nemo/speech/3.0.0/starthere/install.html), med Mios låsta `uv.lock` (NeMo 2.7.0). En ny Pianissimo-version som kräver nyare NeMo blir inte redo; då återgår nattuppdateringen till föregående version. Uppdatera i så fall `pyproject.toml`/`uv.lock` och kör `install.sh`.
