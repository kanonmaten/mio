#!/usr/bin/env bash
# Moves Mio's Pianissimo service to the newest model revision on Hugging Face (branch main).
# Runs nightly as root from mio-pianissimo-update.timer, or by hand: sudo ./update-model.sh
# If the new revision does not become ready within 5 minutes, the previous one is restored.
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
app_dir=/opt/mio-transcription
state_dir=/var/lib/mio-transcription
config=/etc/mio-transcription.conf
python="$app_dir/.venv/bin/python"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

as_service() {
    # The service account owns the model cache; cwd must be readable for it.
    (cd "$app_dir" && runuser -u mio-transcription -- env HF_HOME="$state_dir/models" \
        HF_HUB_DISABLE_TELEMETRY=1 "$python" "$@")
}
set_revision() { sed -i "s/^MIO_MODEL_REVISION=.*/MIO_MODEL_REVISION=$1/" "$config"; }

model_id="$(sed -n 's/^MIO_MODEL_ID=//p' "$config")"
current="$(sed -n 's/^MIO_MODEL_REVISION=//p' "$config")"
latest="$(as_service - "$model_id" <<'PY'
import sys
from huggingface_hub import HfApi
print(HfApi().model_info(sys.argv[1], revision="main").sha)
PY
)"
[[ $latest =~ ^[a-f0-9]{40}$ ]] || { echo "Kunde inte läsa senaste revisionen av $model_id." >&2; exit 1; }

if [[ $latest == "$current" ]]; then
    echo "$model_id är redan senaste version (${current:0:12})."
    exit 0
fi

echo "Ny version av $model_id: ${current:0:12} → ${latest:0:12}. Hämtar…"
as_service - "$model_id" "$latest" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], allow_patterns=["*.nemo"])
PY

set_revision "$latest"
systemctl restart mio-transcription.service
if MIO_EXPECT_REVISION="$latest" "$script_dir/check.sh" --wait; then
    # Keep only the active revision; each one is about 2.5 GB.
    as_service - "$latest" <<'PY'
import sys
from huggingface_hub import scan_cache_dir
info = scan_cache_dir()
old = [rev.commit_hash for repo in info.repos for rev in repo.revisions if rev.commit_hash != sys.argv[1]]
if old:
    info.delete_revisions(*old).execute()
PY
    echo "Uppdaterad till ${latest:0:12}."
else
    echo "Den nya versionen blev inte redo. Återgår till ${current:0:12}." >&2
    set_revision "$current"
    systemctl restart mio-transcription.service
    "$script_dir/check.sh" --wait || true
    exit 1
fi
