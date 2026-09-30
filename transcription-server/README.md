# Mio-transkriptionsserver: CachyOS, Pianissimo och Tailscale

Den här tjänsten kör **originalmodellen `KlangAI/pianissimo-sv` i NeMo/PyTorch på NVIDIA CUDA**, utan kvantisering eller alternativ transkriptionsmotor. iPhone skickar korta ljuddelar via privat Tailscale HTTPS. Text och ordtider kommer tillbaka över [API v1](API.md). Den separata katalogen `../server` är text-AI-gatewayen, inte ljudservern.

Guiden kontrollerades mot officiella källor 2026-09-30. GPU-laddning och tystnadsinference har provats på RTX 4060 Ti 8 GiB. Svenskt tal, systemd i drift, Tailscale-kedjan och nya iOS-bygget måste fortfarande provas. Avsätt gott om diskutrymme för Python/CUDA-beroenden och modellcache, samt ungefär 5 GiB ledigt GPU-minne som utgångspunkt; konkurrerande GPU-appar kan ge slut på minne.

## 1. CachyOS och GPU

Uppdatera CachyOS helt, starta om efter drivrutins-/kärnuppdatering och kontrollera GPU:n:

```bash
sudo pacman -Syu
nvidia-smi
sudo pacman -S --needed uv ffmpeg libsndfile base-devel tailscale rsync
```

Följ [CachyOS CHWD](https://wiki.cachyos.org/features/chwd/chwd/) om NVIDIA-drivrutinen saknas. Installera rätt drivrutin för kärna/GPU, inte en extra parallell drivrutin från NVIDIAs `.run`-installerare. Låsta PyTorch-hjul har CUDA-runtime; en kompatibel värddrivrutin krävs. Verifierat här: driver 615.71.09, torch 2.14.0+cu130, CUDA 13.0. Systemets Python 3.14 används **inte**: miljön använder 3.12.14, NeMo 2.7.0 och det medföljande `uv.lock`. Se [NeMo-installation](https://docs.nvidia.com/nemo/speech/3.0.0/starthere/install.html), [PyTorch](https://pytorch.org/get-started/locally/) och [uv Python](https://docs.astral.sh/uv/guides/install-python/).

## 2. Installera kod och separat Python-miljö

Kör från denna katalog i din arbetskopia. Kommandona installerar bara ljudservern. Kopiera inte hela projektets privata filer eller en befintlig `.venv`.

```bash
sudo useradd --system --user-group --home-dir /var/lib/mio-transcription --shell /usr/bin/nologin mio-transcription
sudo install -d -m 755 /opt/mio-transcription /opt/mio-python
sudo rsync -a --exclude=.venv --exclude=__pycache__ --exclude=.pytest_cache ./ /opt/mio-transcription/
sudo env UV_PYTHON_INSTALL_DIR=/opt/mio-python uv python install 3.12.14
sudo env UV_PYTHON_INSTALL_DIR=/opt/mio-python uv sync --directory /opt/mio-transcription --python 3.12.14 --locked --extra inference
sudo install -d -o mio-transcription -g mio-transcription -m 700 /var/lib/mio-transcription
```

Hoppa över `useradd` om kontot redan finns. Root äger kod och Python; tjänstekontot får bara skriva sin modellcache och temporära arbetsfiler. Python ligger under `/opt`, eftersom tjänstens `ProtectHome=true` döljer hemkataloger. Kontrollera CUDA som tjänstekontot:

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
sudo install -m 644 systemd/mio-transcription.service /etc/systemd/system/mio-transcription.service
sudo systemd-analyze verify /etc/systemd/system/mio-transcription.service
sudo systemctl daemon-reload
sudo systemctl enable --now mio-transcription.service
sudo systemctl status mio-transcription.service
```

Första starten hämtar modellen från Hugging Face. Den publika modellen kräver ingen HF-token. `/health` svarar 503 tills modellen är varm, därefter 200. Modellen laddas en gång, högst en inference körs åt gången. Laddning över 300 s eller inference över 45 s avslutar processen; systemd startar om efter 10 s även efter krasch. Boot startar tjänsten igen. En avsiktlig `systemctl stop` förblir stoppad.

Tjänsten lyssnar **endast på 127.0.0.1:8765**. Ingen routerport ska öppnas. Råljud behandlas i RAM, inga ljudfiler eller transkriptloggar skapas. Upp till åtta textsvar finns i en kort retry-cache, normalt högst 91 s. Core dumps och tjänstens swap är avstängda. Loggen visar inte ljud, token eller transkript; felkoder och `/health` används för felsökning. Tjänstens modellcache är modellvikter, inte användarljud.

## 4. Tailscale på datorn

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up
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

Behåll andra nödvändiga regler för ditt nät; ersätt inte en befintlig policy blint. Kontrollera med Tailscales policytester att avsedd iPhone får ansluta och en annan identitet nekas. Bearer-token behövs även när Tailscale redan har godkänt enheten. Se [grants](https://tailscale.com/docs/features/access-control/grants). Granska nyckelns utgångstid i adminpanelen för en server som ska fungera utan återkommande manuell inloggning; en taggad server hanteras som en serveridentitet.

## 5. iPhone och Mio

1. Installera Tailscale från App Store, logga in i samma tailnet och tillåt VPN-konfigurationen. Bjud in flickvännens eget konto om ni använder olika identiteter och ge det rätt grant.
2. Aktivera **VPN On Demand → Always** för både Wi-Fi och mobilnät enligt [iPhone-guiden](https://tailscale.com/docs/features/client/ios-vpn-on-demand).
3. Installera det **nya** Mio-bygget; äldre build 5 har inte ljudserverklienten.
4. Öppna kugghjulet → Transkription. Ange Serve-adressen utan sökväg, HTTPS och port 443. Hämta token lokalt med `sudo cat /etc/mio-transcription.conf`, överför den privat och klistra bara in värdet efter `MIO_TRANSCRIPTION_TOKEN=`. Lägg den aldrig i Git, exporter eller skärmbilder.
5. Tryck **Spara anslutning**. En bekräftelse visas direkt. Token sparas i iPhones Keychain. Tomt tokenfält behåller token endast vid samma serveradress; ny adress kräver token igen.
6. Tryck **Testa sparad anslutning**. Inget ljud skickas. Kontrollera modell/revision och verifieringstid. Mio visar serverns nåbarhet, inte Tailscales interna VPN-status.
7. Starta Mio eller en lektion och godkänn mikrofonen. Det är också den synliga starten av ljudöverföringen. Paus/stopp stänger mikrofonen. Ljud som redan fångats avslutas under högst 15 s; knappen Avbryt väntan avbryter det direkt.

SideStore kan använda LocalDevVPN för förnyelse. En annan VPN kan koppla bort Tailscale och dess On Demand. **Återanslut Tailscale efter förnyelsen** och testa anslutningen i Mio. Tailscale-anslutning på båda enheterna och dator som är vaken krävs; systemd kan inte köra inference när datorn sover eller är avstängd.

## 6. Testa hela kedjan

Lokalt räcker först `/health`. Använd token via stdin-konfiguration till curl så den inte läggs i kommandoradens argumentlista eller historik:

```bash
read -rs -p 'Transkriptionstoken: ' mio_test_token
curl --silent --show-error --config - <<EOF_CURL
url = "http://127.0.0.1:8765/health"
header = "Authorization: Bearer ${mio_test_token}"
EOF_CURL
unset mio_test_token
```

Gör sedan samma test från en Tailscale-ansluten dator med Serve-HTTPS-adressen. Utan token ska svaret vara 401. Ingen anslutning ska fungera från en enhet utanför tailnet. Kontrollera `ss -ltn` (8765 endast loopback), `tailscale serve status`, `tailscale status` och tjänstens status.

På iPhone: läs en känd svensk mening med namn, datum och siffror. Vänta cirka 15–30 s och kontrollera både text och ljudtider. Prova kontinuerligt tal över 20-sekundsgränser så att ord inte försvinner eller dubbleras. Precision/latens är ännu inte godkända för daglig användning.

Under aktiv lektion: stoppa/starta tjänsten, gör ett kort avbrott och ett avbrott över 60 s, byt Wi-Fi/mobilnät, lås skärmen och återgå. Sessionen ska bevaras, serverstatus uppdateras och gamla ljuddelar få synliga luckor. Starta om datorn: Tailscale Serve och tjänsten ska komma tillbaka utan terminalsession. Testa även telefonavbrott och manuell Fortsätt efter iOS-ljudreset. Kör hela [acceptansmatrisen](../docs/TESTPLAN_PIANISSIMO.md).

## 7. Uppdatering och återställning

Appen är kopplad till API v1, inte ett modellnamn. Modellbyte kräver därför ingen ny app om [kontraktet](API.md) bibehålls. Modellen måste fortfarande leverera riktiga ordtider.

1. Notera fungerande serverkällkod, `uv.lock`, modell-ID och full revision. Behåll privat backup av konfigurationen utanför Git. Lås alltid en full 40-teckens commit från [modellkortet](https://huggingface.co/KlangAI/pianissimo-sv); använd inte flytande `main`.
2. Prova nya vikter/beroenden separat med syntetiskt svenskt tal, ordtider, GPU-minne och API-tester. Byt inte PyTorch/NeMo automatiskt vid boot.
3. Avsluta aktiv Mio-session. Stoppa tjänsten: `sudo systemctl stop mio-transcription`. Kopiera ny serverkod om nödvändigt, kör samma `uv sync --locked --extra inference` som vid installation och redigera modellrevision med `sudoedit /etc/mio-transcription.conf`.
4. Starta tjänsten. Kontrollera `/health`, revision och ett svenskt prov från Mio. Modellvikter kan uppdateras utan att text-AI-gatewayen påverkas.
5. Vid fel: stoppa, återställ tidigare kod/lock/revision, synka den tidigare låsfilen och starta igen. Ingen användardatabas behöver migreras för ett kompatibelt modellbyte.

Rotera åtkomsttoken genom att stoppa tjänsten, skapa ett nytt slumpvärde, ändra konfigurationen och starta igen. Spara samma nya värde i Mio. En gammal token ska då nekas. Serveradress/token kan bara ändras när mikrofonen är av; klienten skickar inte gamla köade ljuddelar till en ny adress.

## Utvecklarkontroller

```bash
uv sync --locked --extra test
uv run --locked --extra test pytest -q tests
```

Testerna använder en falsk modell och inga personuppgifter. GPU-prov kräver `--extra inference`. Använd aldrig en verklig privat inspelning som testfixture. Kör även projektets statiska kontroller och Xcode/XCTest för appen före distribution.
