#!/usr/bin/env bash
# Installs or updates Mio's private Pianissimo service on CachyOS/Arch with an NVIDIA GPU.
# Run as your normal user from any directory: ./install.sh  (it uses sudo where needed).
# Re-running is the update path: code, Python environment and systemd units are refreshed;
# the token in /etc/mio-transcription.conf is kept. The model follows the newest Pianissimo
# revision; a nightly timer (update-model.sh) keeps it current with automatic rollback.
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir=/opt/mio-transcription
python_dir=/opt/mio-python
state_dir=/var/lib/mio-transcription
config=/etc/mio-transcription.conf
unit=/etc/systemd/system/mio-transcription.service
python_version=3.12.14
default_model=KlangAI/pianissimo-sv
diarization_model=nvidia/diar_streaming_sortformer_4spk-v2

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'FEL: %s\n' "$1" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail "Kör som din vanliga användare, inte root. Skriptet använder sudo själv."
for file in pyproject.toml uv.lock check.sh update-model.sh mio_transcription/app.py scripts/measure_wer.py \
    systemd/mio-transcription.service systemd/mio-pianissimo-update.service systemd/mio-pianissimo-update.timer; do
    [[ -f "$source_dir/$file" ]] || fail "Hittar inte $file bredvid install.sh."
done

step "Kontrollerar GPU och verktyg"
command -v nvidia-smi >/dev/null || fail "nvidia-smi saknas. Installera NVIDIA-drivrutinen (CachyOS: sudo chwd -a) och starta om."
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || fail "nvidia-smi når inte drivrutinen. Starta om efter kärn-/drivrutinsuppdatering."
missing=()
for tool in uv rsync curl tailscale; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if ((${#missing[@]})); then
    sudo pacman -S --needed --noconfirm "${missing[@]}"
fi
uv_bin="$(command -v uv)"

step "Tjänstekonto och kod i $app_dir"
getent passwd mio-transcription >/dev/null || sudo useradd --system --user-group \
    --home-dir "$state_dir" --shell /usr/bin/nologin mio-transcription
if systemctl is-active --quiet mio-transcription.service; then
    sudo systemctl stop mio-transcription.service
fi
sudo install -d -m 755 "$app_dir/mio_transcription" "$app_dir/scripts" "$python_dir"
sudo install -m 644 "$source_dir/pyproject.toml" "$source_dir/uv.lock" "$app_dir/"
sudo install -m 755 "$source_dir/check.sh" "$source_dir/update-model.sh" "$app_dir/"
sudo install -m 755 "$source_dir/scripts/measure_wer.py" "$app_dir/scripts/"
sudo rsync -a --delete --chown=root:root --chmod=D755,F644 \
    --exclude=__pycache__ --include='*/' --include='*.py' --exclude='*' \
    "$source_dir/mio_transcription/" "$app_dir/mio_transcription/"
sudo install -d -o mio-transcription -g mio-transcription -m 700 "$state_dir"

step "Python $python_version och låsta beroenden (första gången tar det en stund)"
sudo env UV_PYTHON_INSTALL_DIR="$python_dir" "$uv_bin" python install "$python_version"
sudo env UV_PYTHON_INSTALL_DIR="$python_dir" "$uv_bin" sync --directory "$app_dir" \
    --python "$python_version" --managed-python --no-python-downloads --locked --extra inference

step "CUDA som tjänstekontot"
(cd "$app_dir" && sudo -u mio-transcription "$app_dir/.venv/bin/python" -c \
    'import torch, sys; ok = torch.cuda.is_available(); print(torch.__version__, "CUDA:", ok, torch.cuda.get_device_name(0) if ok else ""); sys.exit(0 if ok else 1)') \
    || fail "PyTorch ser ingen CUDA-GPU som tjänstekontot. Kontrollera drivrutin och rättigheter till /dev/nvidia*."

step "Konfiguration $config"
if sudo test -f "$config"; then
    echo "Finns redan; token behålls."
else
    latest="$(cd "$app_dir" && sudo -u mio-transcription env HF_HUB_DISABLE_TELEMETRY=1 "$app_dir/.venv/bin/python" -c \
        'import sys; from huggingface_hub import HfApi; print(HfApi().model_info(sys.argv[1], revision="main").sha)' "$default_model")"
    [[ $latest =~ ^[a-f0-9]{40}$ ]] || fail "Kunde inte läsa senaste versionen av $default_model från Hugging Face."
    # The token is generated and written by root without being printed or placed in argv.
    sudo python3 - "$config" "$default_model" "$latest" <<'PY'
import os, secrets, sys
path, model, revision = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(f'MIO_TRANSCRIPTION_TOKEN={secrets.token_urlsafe(32)}\n')
    f.write(f'MIO_MODEL_ID={model}\nMIO_MODEL_REVISION={revision}\n')
PY
    echo "Skapad med ny token och senaste modellversion."
fi
model_id="$(sudo sed -n 's/^MIO_MODEL_ID=//p' "$config")"
model_revision="$(sudo sed -n 's/^MIO_MODEL_REVISION=//p' "$config")"
[[ $model_revision =~ ^[a-f0-9]{40}$ ]] || fail "MIO_MODEL_REVISION i $config måste vara en full commit (40 tecken)."
# Speaker labels are optional: the talarmodell is pinned once to a commit and
# never auto-updated. Without it the service still transcribes, just unlabeled.
diarization_revision="$(sudo sed -n 's/^MIO_DIARIZATION_REVISION=//p' "$config")"
if [[ -z $diarization_revision ]] && ! sudo grep -q '^MIO_SPEAKER_LABELS=0' "$config"; then
    diarization_revision="$(cd "$app_dir" && sudo -u mio-transcription env HF_HUB_DISABLE_TELEMETRY=1 "$app_dir/.venv/bin/python" -c \
        'import sys; from huggingface_hub import HfApi; print(HfApi().model_info(sys.argv[1], revision="main").sha)' "$diarization_model" || true)"
    if [[ $diarization_revision =~ ^[a-f0-9]{40}$ ]]; then
        printf 'MIO_DIARIZATION_REVISION=%s\n' "$diarization_revision" | sudo tee -a "$config" >/dev/null
        echo "Talarmodellen $diarization_model låst till ${diarization_revision:0:12}."
    else
        diarization_revision=""
        echo "VARNING: kunde inte läsa talarmodellens version; tjänsten kör utan talarmärkning."
    fi
fi

step "Hämtar modellen $model_id @ ${model_revision:0:12} (ca 2,5 GB första gången)"
# Prefetching keeps a slow first download from exceeding the service's 300 s load limit.
(cd "$app_dir" && sudo -u mio-transcription env HF_HOME="$state_dir/models" HF_HUB_DISABLE_TELEMETRY=1 \
    "$app_dir/.venv/bin/python" - "$model_id" "$model_revision" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], allow_patterns=["*.nemo"])
PY
)
if [[ $diarization_revision =~ ^[a-f0-9]{40}$ ]]; then
    step "Hämtar talarmodellen $diarization_model @ ${diarization_revision:0:12} (ca 0,5 GB första gången)"
    (cd "$app_dir" && sudo -u mio-transcription env HF_HOME="$state_dir/models" HF_HUB_DISABLE_TELEMETRY=1 \
        "$app_dir/.venv/bin/python" - "$diarization_model" "$diarization_revision" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], allow_patterns=["*.nemo"])
PY
    ) || echo "VARNING: talarmodellen kunde inte hämtas; tjänsten kör utan talarmärkning."
fi

step "systemd-tjänst och nattlig modelluppdatering"
for name in mio-transcription.service mio-pianissimo-update.service mio-pianissimo-update.timer; do
    sudo install -m 644 "$source_dir/systemd/$name" "/etc/systemd/system/$name"
done
sudo systemd-analyze verify "$unit" /etc/systemd/system/mio-pianissimo-update.service
sudo systemctl daemon-reload
sudo systemctl enable mio-transcription.service mio-pianissimo-update.timer
sudo systemctl restart mio-transcription.service
sudo systemctl start mio-pianissimo-update.timer

step "Väntar på att modellen laddas (högst 5 min)"
"$app_dir/check.sh" --wait

step "Senaste Pianissimo-version"
sudo "$app_dir/update-model.sh"

step "Tailscale"
if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale är inte inloggat. Kör: sudo systemctl enable --now tailscaled && sudo tailscale up"
    echo "Kör sedan ./install.sh igen, eller: sudo tailscale serve --bg http://127.0.0.1:8765"
elif sudo tailscale serve status 2>/dev/null | grep -q '127.0.0.1:8765'; then
    echo "Tailscale Serve pekar redan på tjänsten."
elif sudo tailscale serve status 2>/dev/null | grep -q 'https://'; then
    echo "Tailscale Serve används redan för något annat; ändrar inget. Se README, steg 3."
else
    sudo tailscale serve --bg http://127.0.0.1:8765
fi
sudo tailscale serve status 2>/dev/null || true

printf '\nKlart. Ange https-adressen ovan och token i Mio (Inställningar → Transkription).\n'
printf 'Visa token: sudo sed -n "s/^MIO_TRANSCRIPTION_TOKEN=//p" %s\n' "$config"
