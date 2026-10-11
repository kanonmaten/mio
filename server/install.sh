#!/usr/bin/env bash
# Installs or updates Mio's private AI gateway on CachyOS/Arch, next to Pianissimo.
# Run as your normal user from any directory: ./install.sh  (it uses sudo where needed).
# Re-running is the update path: code and the systemd unit are refreshed; the Groq key,
# gateway token and daily counters are kept. ./install.sh --ny-groq-nyckel replaces the key.
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir=/opt/mio-gateway
config_dir=/etc/mio-gateway
config=$config_dir/gateway.env
unit=/etc/systemd/system/mio-gateway.service
model=qwen/qwen3.8-27b
port=8787
https_port=8443

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'FEL: %s\n' "$1" >&2; exit 1; }

replace_key=false
case "${1:-}" in
    "") ;;
    --ny-groq-nyckel) replace_key=true ;;
    *) fail "Okänt val: $1. Använd inget val, eller --ny-groq-nyckel." ;;
esac

[[ $EUID -ne 0 ]] || fail "Kör som din vanliga användare, inte root. Skriptet använder sudo själv."
for file in package.json src/server.mjs systemd/mio-gateway.service mio-pair README.md; do
    [[ -f "$source_dir/$file" ]] || fail "Hittar inte $file bredvid install.sh."
done

step "Kontrollerar verktyg"
missing=()
command -v node >/dev/null || missing+=(nodejs)
command -v qrencode >/dev/null || missing+=(qrencode)
command -v tailscale >/dev/null || missing+=(tailscale)
command -v curl >/dev/null || missing+=(curl)
command -v rsync >/dev/null || missing+=(rsync)
if ((${#missing[@]})); then
    sudo pacman -S --needed --noconfirm "${missing[@]}"
fi
node_major="$(node -p 'process.versions.node.split(".")[0]')"
node_version="$(node --version)"
(( node_major >= 26 )) || fail "Node $node_version är för gammal. Mio kräver Node 26.10 eller senare: sudo pacman -Syu nodejs"
(( node_major == 26 )) || echo "OBS: Node $node_version är nyare än den testade 26-serien. Gatewayen startar, men rapportera fel."

step "Tjänstekonto och kod i $app_dir"
getent passwd mio-gateway >/dev/null || sudo useradd --system --user-group \
    --home-dir /var/lib/mio-gateway --no-create-home --shell /usr/bin/nologin mio-gateway
sudo install -d -m 755 "$app_dir/src"
# Only the runtime is copied: no tests, Git history, exports or secrets.
sudo rsync -a --delete --chown=root:root --chmod=D755,F644 \
    --include='*.mjs' --exclude='*' "$source_dir/src/" "$app_dir/src/"
sudo install -m 644 "$source_dir/package.json" "$source_dir/README.md" "$app_dir/"
sudo install -m 755 "$source_dir/mio-pair" /usr/local/bin/mio-pair

step "Konfiguration $config"
sudo install -d -m 700 "$config_dir"
if sudo test -f "$config" && ! $replace_key; then
    echo "Finns redan; Groq-nyckel och gatewaytoken behålls."
else
    echo "Skapa en nyckel på https://console.groq.com/keys (gratisnivån räcker)."
    # Hidden prompt: the key never appears on screen, in argv, shell history or logs.
    IFS= read -rsp "Klistra in Groq-nyckeln (syns inte) och tryck Enter: " groq_key; echo
    [[ $groq_key =~ ^gsk_[A-Za-z0-9]{20,200}$ ]] || fail "Det ser inte ut som en Groq-nyckel (börjar med gsk_)."
    write_config=$(cat <<'JS'
const fs = require('node:fs'), crypto = require('node:crypto');
const [path, model, port] = process.argv.slice(1);
const key = fs.readFileSync(0, 'utf8');
let token = crypto.randomBytes(32).toString('base64url');
// Keep an existing gateway token so a key rotation does not force re-pairing the phone.
try { token = /^MIO_GATEWAY_TOKEN=([A-Za-z0-9_-]{32,256})$/mu.exec(fs.readFileSync(path, 'utf8'))?.[1] ?? token; } catch {}
const lines = [
  '# Mio gateway. Skapad av install.sh. Dela aldrig denna fil.',
  `GROQ_API_KEY=${key}`, `MIO_GATEWAY_TOKEN=${token}`,
  'MIO_AI_PROVIDER=groq', `MIO_AI_MODEL=${model}`,
  // Groq free tier for this model: 30 RPM, 8,000 TPM, 200,000 tokens/day. Three requests per
  // minute keeps lesson parts under the token-per-minute limit; the daily cap leaves a margin.
  'MIO_REQUESTS_PER_MINUTE=3', 'MIO_TOKENS_PER_DAY=190000', 'MIO_REQUESTS_PER_DAY=',
  'MIO_LESSON_INTERVAL_SECONDS=60', `PORT=${port}`, ''];
const temporary = `${path}.tmp`;
fs.writeFileSync(temporary, lines.join('\n'), { mode: 0o600 });
fs.renameSync(temporary, path);
JS
)
    # The script travels in argv, the key only on stdin.
    printf '%s' "$groq_key" | sudo node -e "$write_config" "$config" "$model" "$port"
    unset groq_key
    echo "Sparad (endast root kan läsa den)."
fi

step "systemd-tjänst"
sudo install -m 644 "$source_dir/systemd/mio-gateway.service" "$unit"
sudo systemd-analyze verify "$unit"
sudo systemctl daemon-reload
sudo systemctl enable mio-gateway.service >/dev/null
sudo systemctl restart mio-gateway.service
for _ in $(seq 1 20); do
    curl --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null && break
    sleep 0.5
done
curl --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null \
    || fail "Gatewayen svarar inte. Se: journalctl -u mio-gateway -n 50"
echo "Gatewayen svarar på 127.0.0.1:$port."

step "Tailscale (HTTPS på port $https_port, bredvid Pianissimo på 443)"
if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale är inte inloggat. Kör: sudo systemctl enable --now tailscaled && sudo tailscale up"
    echo "Kör sedan ./install.sh igen."
    exit 1
fi
sudo tailscale serve --bg --https="$https_port" "http://127.0.0.1:$port"
sudo tailscale serve status 2>/dev/null || true

step "Klart"
echo "Para telefonen: kör  mio-pair  och skanna QR-koden i Mio (Inställningar → Dator)."
