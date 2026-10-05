# Mio-transkriptionsserver: CachyOS, Pianissimo och Tailscale

Den här tjänsten kör **originalmodellen `KlangAI/pianissimo-sv` i NeMo/PyTorch på NVIDIA CUDA**, utan kvantisering eller alternativ transkriptionsmotor. iPhone skickar korta ljuddelar via privat Tailscale HTTPS. Text och ordtider kommer tillbaka över [API v1](API.md). Den separata katalogen `../server` är text-AI-gatewayen, inte ljudservern.

Guiden kontrollerades mot officiella källor 2026-09-30. GPU-laddning och tystnadsinference har provats på RTX 4060 Ti 8 GiB. Svenskt tal, systemd i drift, Tailscale-kedjan och nya iOS-bygget måste fortfarande provas. Avsätt gott om diskutrymme för Python/CUDA-beroenden och modellcache, samt ungefär 5 GiB ledigt GPU-minne som utgångspunkt; konkurrerande GPU-appar kan ge slut på minne.

## Val av driftmetod

**Rekommenderad avvägning för denna CachyOS-dator med RTX 4060 Ti 8 GiB:** en låst Python-miljö, original Pianissimo på CUDA, en FastAPI/Uvicorn-process under systemd och privat HTTPS via Tailscale Serve. Det följer [modellkortets NeMo/PyTorch-användning och ordtider](https://huggingface.co/KlangAI/pianissimo-sv). Modellen hålls laddad mellan anrop. Behåll `--workers 1`: fler serverprocesser laddar var sin modell och konkurrerar om GPU-minnet.

| Metod | Fördel och begränsning här |
|---|---|
| Python/uv + systemd, denna guide | Få driftkomponenter, låsta beroenden och automatisk start/omstart. Den dokumenterade GPU-smoken gäller denna Python-stack. CachyOS kärna, drivrutin och systembibliotek uppdateras separat och kräver nya prov. |
| Docker med låst image + NVIDIA Container Toolkit | Isolerar fler användarlandsberoenden och gör samma miljö lättare att flytta/återställa. Kräver containerdrift, GPU-integration, separat imagebygge samt rätt cache-, nät- och RAM-konfiguration. Värdens NVIDIA-drivrutin behövs fortfarande. Inget sådant Pianissimo-image har verifierats i Mio. |
| Python i en öppen terminal | Bra för korta utvecklingsprov. För daglig användning behövs även start vid boot, omstart efter fel och kontrollerad åtkomst; systemd sköter detta här. |

Detta är en bedömning för en privat server, inte en uppmätt jämförelse av snabbaste eller mest driftsäkra alternativ. [NVIDIA beskriver både uv/Python och containerinstallation](https://docs.nvidia.com/nemo/speech/3.0.0/starthere/install.html); [Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) tillför GPU-integrationen för containerdrift. NeMo-dokumentationens nuvarande standardstack är inte identisk med Mios låsta NeMo 2.7.0-stack: använd Mios `uv.lock` och uppgradera separat efter prov. Docker blir mer motiverat om värdens uppdateringar orsakar återkommande kompatibilitetsfel eller tjänsten ska flyttas mellan datorer.

Precisionen beror även på ljud och delgränser. Huvuddelen av den avsedda latensen 15–30 s kommer från att appen samlar ungefär 20 s ljud per del; byte av processhanterare tar inte bort den väntan. Varm modell undviker laddning per anrop men håller GPU-minne upptaget även i vila. Elförbrukning, svenskt tal, verklig latens och telefonens batteri är ännu inte uppmätta för driftkedjan. Tailscale ger privat transport och hanterat HTTPS utan egen publik port eller köpt domän; datorn måste vara vaken och nåbar. ONNX/MLX-varianter, kvantisering och CPU-fallback ingår inte i den beslutade originalmodellen/CUDA-lösningen.

## Sökvägar och kommandon

**Alla kommandoblock körs i Bash som din vanliga användare, från valfri katalog.** Ingen instruktion förutsätter att du redan står i `transcription-server/`. Exemplen anger arbetskopian som `$HOME/Documents/ChatGPT/Mio`; `$HOME` är din hemkatalog. Om projektet ligger någon annanstans, ändra den uttryckliga källsökvägen i de block du använder. Block med flera installationssteg använder en separat Bash-process som stannar vid första felet.

**Ljudservern behöver aldrig hela Mio-projektet.** Installationen kopierar bara `transcription-server/pyproject.toml`, `transcription-server/uv.lock` och Python-koden i `transcription-server/mio_transcription/`. systemd-filen installeras separat i steg 3. Swift-kod, Xcode-projekt, text-AI-gateway, Git-historik, tester, privata filer och arbetskopians `.venv` ingår inte i driftkopian.

## 1. CachyOS och GPU

Uppdatera CachyOS helt, starta om efter drivrutins-/kärnuppdatering och kontrollera GPU:n:

```bash
sudo pacman -Syu
```

Starta om efter kärn-/drivrutinsuppdatering **innan** följande kontroller. Om `nvidia-smi` inte kan kontakta drivrutinen, lös det först; Python, Docker eller systemd kan inte ersätta en fungerande värddrivrutin.

```bash
nvidia-smi
sudo pacman -S --needed uv ffmpeg libsndfile base-devel tailscale rsync curl
```

Följ [CachyOS CHWD](https://wiki.cachyos.org/features/chwd/chwd/) om NVIDIA-drivrutinen saknas. Installera rätt drivrutin för kärna/GPU, inte en extra parallell drivrutin från NVIDIAs `.run`-installerare. Låsta PyTorch-hjul har CUDA-runtime; en kompatibel värddrivrutin krävs. Verifierat här: driver 615.71.09, torch 2.14.0+cu130, CUDA 13.0. Systemets Python 3.14 används **inte**: miljön använder 3.12.14, NeMo 2.7.0 och det medföljande `uv.lock`. Se [NeMo-installation](https://docs.nvidia.com/nemo/speech/3.0.0/starthere/install.html), [PyTorch](https://pytorch.org/get-started/locally/) och [uv Python](https://docs.astral.sh/uv/guides/install-python/).

## 2. Installera kod och separat Python-miljö

Kör följande block från valfri katalog. Kontrollera/ändra `mio_source` först. Källan valideras innan kontot eller driftkopian skapas. Kontot skapas bara om det saknas. Vid uppdatering: stoppa tjänsten enligt steg 7 innan du kopierar kod.

```bash
bash <<'MIO_INSTALL'
set -euo pipefail
mio_source="$HOME/Documents/ChatGPT/Mio/transcription-server"
test -f "$mio_source/pyproject.toml"
test -f "$mio_source/uv.lock"
test -f "$mio_source/mio_transcription/app.py"
if ! getent passwd mio-transcription >/dev/null; then
    sudo useradd --system --user-group --home-dir /var/lib/mio-transcription --shell /usr/bin/nologin mio-transcription
fi
sudo install -d -m 755 /opt/mio-transcription/mio_transcription /opt/mio-python
sudo install -m 644 "$mio_source/pyproject.toml" "$mio_source/uv.lock" /opt/mio-transcription/
sudo rsync -a --chown=root:root --chmod=D755,F644 \
    --exclude=__pycache__ --include='*/' --include='*.py' --exclude='*' \
    "$mio_source/mio_transcription/" /opt/mio-transcription/mio_transcription/
sudo env UV_PYTHON_INSTALL_DIR=/opt/mio-python /usr/bin/uv python install 3.12.14
sudo env UV_PYTHON_INSTALL_DIR=/opt/mio-python /usr/bin/uv sync \
    --directory /opt/mio-transcription --python 3.12.14 --managed-python --no-python-downloads --locked --extra inference
sudo install -d -o mio-transcription -g mio-transcription -m 700 /var/lib/mio-transcription
MIO_INSTALL
```

`/usr/bin/uv` kommer från pacman-paketet i steg 1. Root äger kod och Python; tjänstekontot får bara skriva sin modellcache och temporära arbetsfiler. En **ny** `.venv` skapas under `/opt/mio-transcription/`. Python ligger under `/opt/mio-python`, eftersom tjänstens `ProtectHome=true` döljer hemkataloger. Detta skiljer utveckling från drift och gör tjänsten oberoende av inloggning och arbetskopians plats. `--managed-python` kräver den installerade Python-versionen under `/opt`; `--locked` bevarar låsfilen. Se [uvs kommandoreferens](https://docs.astral.sh/uv/reference/cli/) och [systemds katalogskydd](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html). Kontrollera CUDA som tjänstekontot:

```bash
sudo -u mio-transcription /opt/mio-transcription/.venv/bin/python -c 'import torch; print(torch.__version__, torch.cuda.is_available()); print(torch.cuda.get_device_name(0))'
```

Om det misslyckas: kontrollera drivrutin och rättigheter till `/dev/nvidia*` och vid behov `render`/`video` enligt systemets enhetsägarskap. Tjänsten kräver CUDA och byter aldrig tyst till CPU.

## 3. Token, modellrevision och systemd

Skapa en ny separat transkriptionstoken. Använd inte AI-gatewayens eller Hugging Faces token. Följande skriver en root-läsbar konfigurationsfil och skriver inte ut hemligheten. Det vägrar skriva över en befintlig fil:

```bash
sudo python3 - <<'PY'
import os, secrets
path = '/etc/mio-transcription.conf'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write('MIO_TRANSCRIPTION_TOKEN=' + secrets.token_urlsafe(32) + '\n')
    f.write('MIO_MODEL_ID=KlangAI/pianissimo-sv\n')
    f.write('MIO_MODEL_REVISION=95c85c9b08afff7b48b540984b1e9b693b31ddd4\n')
PY
```

Om konfigurationen redan finns: behåll token och granska modell-ID/revision med `sudoedit /etc/mio-transcription.conf`. Skapa inte en ny token vid en vanlig koduppdatering.

**Hämta modellvikterna före tjänstestarten**, som tjänstekontot till samma cache som systemd använder. Exemplet hämtar den revision som skapas ovan; vid modellbyte måste du ange exakt samma ID/revision som i konfigurationen. Detta skickar inget ljud och skriver inte ut transkriptionstoken:

```bash
sudo -u mio-transcription env HF_HOME=/var/lib/mio-transcription/models HF_HUB_DISABLE_TELEMETRY=1 \
    /opt/mio-transcription/.venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download(repo_id="KlangAI/pianissimo-sv",
                  revision="95c85c9b08afff7b48b540984b1e9b693b31ddd4",
                  allow_patterns=["*.nemo"])
PY
```

Den publika modellen kräver ingen HF-token. Förhämtningen undviker att en långsam första nedladdning förbrukar modellens 300 s laddningsgräns och orsakar omstarter. Vikterna är ungefär 2,51 GB enligt modellkortet; Python/CUDA-beroenden och installationscache kräver ytterligare diskutrymme. Förhämtningen verifierar hämtning, inte att CUDA-inference fungerar.

Installera och starta tjänsten från valfri katalog:

```bash
bash <<'MIO_SERVICE'
set -euo pipefail
mio_source="$HOME/Documents/ChatGPT/Mio/transcription-server"
test -f "$mio_source/systemd/mio-transcription.service"
sudo install -m 644 "$mio_source/systemd/mio-transcription.service" /etc/systemd/system/mio-transcription.service
sudo systemd-analyze verify /etc/systemd/system/mio-transcription.service
sudo systemctl daemon-reload
sudo systemctl enable --now mio-transcription.service
sudo systemctl status mio-transcription.service
MIO_SERVICE
```

`systemctl` visar processens tillstånd, **inte att modellen är redo**. Prova autentiserad `/health` enligt steg 6 innan du ansluter telefonen. Den svarar 503 tills modellen är varm, därefter 200 med `status: ready` och modellmetadata. Modellen laddas en gång, högst en inference körs åt gången. Laddning över 300 s eller inference över 45 s avslutar processen; systemd startar om efter 10 s även efter krasch. Boot startar tjänsten igen. En avsiktlig `systemctl stop` förblir stoppad.

Tjänsten lyssnar **endast på 127.0.0.1:8765**. Ingen routerport ska öppnas. Råljud behandlas i RAM, inga ljudfiler eller transkriptloggar skapas. Upp till åtta textsvar finns i en kort retry-cache, normalt högst 91 s. Core dumps och tjänstens swap är avstängda. Loggen visar inte ljud, token eller transkript; felkoder och `/health` används för felsökning. Tjänstens modellcache är modellvikter, inte användarljud. `StateDirectoryMode=0700` bevarar den privata katalogbehörigheten även när systemd skapar eller justerar `/var/lib/mio-transcription`.

## 4. Tailscale på datorn

Kontrollera först eventuell befintlig Serve-konfiguration. Mio behöver HTTPS på port 443 och rotvägen `/`; samma adress/rotväg kan inte samtidigt peka på en annan tjänst. Ändra bara den avsedda kopplingen.

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up
sudo tailscale serve status
sudo tailscale serve --bg http://127.0.0.1:8765
sudo tailscale serve status
```

Öppna inloggnings-/HTTPS-länken som Tailscale visar och följ den. Aktivera MagicDNS/HTTPS i tailnet om det efterfrågas. Spara exakt adress från Serve, exempelvis `https://dator.example.ts.net`. Certifikatet hanteras av Tailscale. DNS-namnet i certifikatet kan förekomma i publika certifikatloggar; välj ett diskret maskinnamn. Använd **Serve**, inte Funnel. `--bg` gör att konfigurationen återkommer efter reboot. Se [Serve](https://tailscale.com/docs/features/tailscale-serve) och [CLI](https://tailscale.com/docs/reference/tailscale-cli/serve).

Begränsa tailnet-policyn till den användare/enhet som behöver ljudservern, TCP 443 på datorn. Tailscales standardpolicy kan ge alla tailnet-medlemmar åtkomst. En grant är additiv: ta bort eller begränsa breda befintliga tillåtelseregler om en snäv grant ska ha effekt. Exempel att anpassa i adminpanelen, med datorn taggad `tag:mio-transcription` och verklig inloggningsadress:

```json
{
  "tagOwners": { "tag:mio-transcription": ["autogroup:admin"] },
  "grants": [{
    "src": ["anvandare@example.com"],
    "dst": ["tag:mio-transcription"],
    "ip": ["tcp:443"]
  }]
}
```

För exemplet måste du också tilldela datorn `tag:mio-transcription` i Tailscales adminpanel; policyn tilldelar inte taggen automatiskt. Behåll andra nödvändiga regler för ditt nät; ersätt inte en befintlig policy blint. Kontrollera med Tailscales policytester att avsedd iPhone får ansluta och en annan identitet nekas. Bearer-token behövs även när Tailscale redan har godkänt enheten. Se [grants](https://tailscale.com/docs/features/access-control/grants). Granska nyckelns utgångstid i adminpanelen för en server som ska fungera utan återkommande manuell inloggning; en taggad server hanteras som en serveridentitet.

## 5. iPhone och Mio

1. Installera Tailscale från App Store, logga in i samma tailnet och tillåt VPN-konfigurationen. Bjud in flickvännens eget konto om ni använder olika identiteter och ge det rätt grant.
2. Aktivera **VPN On Demand → Always** för både Wi-Fi och mobilnät enligt [iPhone-guiden](https://tailscale.com/docs/features/client/ios-vpn-on-demand).
3. Installera det **nya** Mio-bygget; äldre build 5 har inte ljudserverklienten.
4. Öppna kugghjulet → Transkription. Ange Serve-adressen utan sökväg, HTTPS och port 443. Hämta token lokalt med `sudo cat /etc/mio-transcription.conf`, överför den privat och klistra bara in värdet efter `MIO_TRANSCRIPTION_TOKEN=`. Lägg den aldrig i Git, exporter eller skärmbilder.
5. Tryck **Spara anslutning**. En bekräftelse visas direkt. Token sparas i iPhones Keychain. Tomt tokenfält behåller token endast vid samma serveradress; ny adress kräver token igen.
6. Tryck **Testa sparad anslutning**. Inget ljud skickas. Kontrollera modell/revision och verifieringstid. Mio visar serverns nåbarhet, inte Tailscales interna VPN-status.
7. Starta Mio eller en lektion och godkänn mikrofonen. Det är också den synliga starten av ljudöverföringen. Paus/stopp stänger mikrofonen. Ljud som redan fångats avslutas under högst 15 s; knappen Avbryt väntan avbryter det direkt.

SideStore kan använda LocalDevVPN för förnyelse. En annan VPN kan koppla bort Tailscale och dess On Demand. **Återanslut Tailscale efter förnyelsen** och testa anslutningen i Mio. Tailscale-anslutning på båda enheterna och dator som är vaken krävs; systemd kan inte köra inference när datorn sover eller är avstängd.

Ställ in datorns energihantering så att den inte automatiskt försätts i vila under avsedd användning. Undvik hibernation/vila till disk under ljudbehandling: det kan skriva RAM-innehåll till disk även när tjänstens vanliga swap är avstängd; se [Linux-kärnans beskrivning av hibernation](https://docs.kernel.org/power/swsusp.html). Inspelning av andra kräver deras samtycke och att lokala regler följs.

## 6. Testa hela kedjan

Lokalt räcker först `/health`. Använd token via stdin-konfiguration till curl så den inte läggs i kommandoradens argumentlista eller historik:

```bash
read -rs -p 'Transkriptionstoken: ' mio_test_token
curl --silent --show-error --connect-timeout 3 --max-time 10 --write-out '\nHTTP %{http_code}\n' --config - <<EOF_CURL
url = "http://127.0.0.1:8765/health"
header = "Authorization: Bearer ${mio_test_token}"
EOF_CURL
unset mio_test_token
```

Gör sedan samma test från en Tailscale-ansluten dator med Serve-HTTPS-adressen. Utan token ska svaret vara 401. Ingen anslutning ska fungera från en enhet utanför tailnet. Kontrollera `ss -ltn` (8765 endast loopback), `tailscale serve status`, `tailscale status` och tjänstens status.

| Resultat | Kontrollera |
|---|---|
| Lokal HTTP 200, `status: ready` | Rätt modell-ID och revision. Detta bevisar laddning/uppvärmning, inte svensk talprecision. |
| HTTP 401 | Transkriptionstoken; det är varken text-AI-token eller HF-token. |
| Lokal HTTP 503 | Modellen laddar. Vid upprepade omstarter: kontrollera förhämtning, CUDA som tjänstekontot, ledigt GPU-minne och `sudo journalctl -u mio-transcription -n 50 --no-pager`. |
| Lokal kontakt fungerar, privat HTTPS misslyckas | Tailscale på båda enheterna, exakt Serve-adress, HTTPS, rätt tilldelad tagg och grants. |
| Ingen lokal kontakt | Tjänststatus, konfigurationsfil, Python-sökväg och att port 8765 lyssnar på loopback. |

På iPhone: läs en känd svensk mening med namn, datum och siffror. Vänta cirka 15–30 s och kontrollera både text och ljudtider. Prova kontinuerligt tal över 20-sekundsgränser så att ord inte försvinner eller dubbleras. Precision/latens är ännu inte godkända för daglig användning.

Under aktiv lektion: stoppa/starta tjänsten, gör ett kort avbrott och ett avbrott över 60 s, byt Wi-Fi/mobilnät, lås skärmen och återgå. Sessionen ska bevaras, serverstatus uppdateras och gamla ljuddelar få synliga luckor. Starta om datorn: Tailscale Serve och tjänsten ska komma tillbaka utan terminalsession. Testa även telefonavbrott och manuell Fortsätt efter iOS-ljudreset. Kör hela [acceptansmatrisen](../docs/TESTPLAN_HELHET.md#pianissimo-återanslutning-och-bakgrund).

## 7. Uppdatering och återställning

Appen är kopplad till API v1, inte ett modellnamn. Modellbyte kräver därför ingen ny app om [kontraktet](API.md) bibehålls. Modellen måste fortfarande leverera riktiga ordtider.

1. Notera fungerande serverkällkod, `uv.lock`, modell-ID och full revision. Behåll privat backup av konfigurationen utanför Git. Lås alltid en full 40-teckens commit från [modellkortet](https://huggingface.co/KlangAI/pianissimo-sv); använd inte flytande `main`.
2. Prova nya vikter/beroenden separat med syntetiskt svenskt tal, ordtider, GPU-minne och API-tester. Byt inte PyTorch/NeMo automatiskt vid boot.
3. Avsluta aktiv Mio-session. Stoppa tjänsten: `sudo systemctl stop mio-transcription`. Vid kod-/beroendeändring, kör installationsblocket i steg 2 med den avsedda arbetskopians uttryckliga sökväg. Det kopierar bara serverdelen och synkar **driftmiljön i `/opt`**, oavsett var terminalen står. Vid enbart modellbyte räcker `sudoedit /etc/mio-transcription.conf` och förhämtning av exakt samma nya ID/revision enligt steg 3. Token ska behållas.
4. Starta tjänsten. Kontrollera `/health`, revision och ett svenskt prov från Mio. Modellvikter kan uppdateras utan att text-AI-gatewayen påverkas.
5. Vid fel: stoppa, återställ tidigare kod/lock/revision, synka den tidigare låsfilen och starta igen. Ingen användardatabas behöver migreras för ett kompatibelt modellbyte.

Rotera åtkomsttoken genom att stoppa tjänsten, skapa ett nytt slumpvärde, ändra konfigurationen och starta igen. Spara samma nya värde i Mio. En gammal token ska då nekas. Serveradress/token kan bara ändras när mikrofonen är av; klienten skickar inte gamla köade ljuddelar till en ny adress.

Om systemd-filen ändras, installera den nya filen med den uttryckliga källsökvägen och kör `systemd-analyze verify` och `systemctl daemon-reload` enligt steg 3. Vid uppdatering av en redan aktiv tjänst, starta om med `sudo systemctl restart mio-transcription`; `enable --now` laddar inte om en redan körande process. Kör alltid `/health` och det svenska provet efteråt, även efter en CachyOS-/drivrutinsuppdatering.

## Utvecklarkontroller

```bash
uv sync --directory "$HOME/Documents/ChatGPT/Mio/transcription-server" --python 3.12.14 --locked --extra test
uv run --directory "$HOME/Documents/ChatGPT/Mio/transcription-server" --python 3.12.14 --locked --extra test pytest -q tests
```

Även dessa kommandon fungerar från valfri katalog. De använder arbetskopians utvecklingsmiljö, inte driftmiljön under `/opt`. Testerna använder en falsk modell och inga personuppgifter. GPU-prov kräver `--extra inference`. Använd aldrig en verklig privat inspelning som testfixture. Kör även projektets statiska kontroller och Xcode/XCTest för appen före distribution.
