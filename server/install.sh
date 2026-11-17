#!/usr/bin/env bash
# Installs or updates Mio's private AI gateway on CachyOS/Arch, next to Pianissimo.
# Run as your normal user from any directory: ./install.sh  (it uses sudo where needed).
# It builds the Rust gateway with cargo, so the PC needs no Node or other runtime.
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
for file in Cargo.toml Cargo.lock src/main.rs systemd/mio-gateway.service mio-pair README.md; do
    [[ -f "$source_dir/$file" ]] || fail "Hittar inte $file bredvid install.sh."
done

step "Kontrollerar verktyg"
missing=()
command -v cargo >/dev/null || missing+=(rust)
command -v qrencode >/dev/null || missing+=(qrencode)
command -v tailscale >/dev/null || missing+=(tailscale)
command -v curl >/dev/null || missing+=(curl)
if ((${#missing[@]})); then
    sudo pacman -S --needed --noconfirm "${missing[@]}"
fi
rust_version="$(cargo --version)"
[[ $rust_version =~ ^cargo\ 1\.([0-9]+) ]] && (( BASH_REMATCH[1] >= 88 )) \
    || fail "$rust_version är för gammal. Gatewayen kräver Rust 1.88 eller senare: sudo pacman -Syu rust"

step "Bygger gatewayen (första gången några minuter)"
# Built as you, from the locked dependency versions; only the finished binary is installed.
cargo build --release --locked --manifest-path "$source_dir/Cargo.toml"
binary="$source_dir/target/release/mio-gateway"

step "Tjänstekonto och kod i $app_dir"
getent passwd mio-gateway >/dev/null || sudo useradd --system --user-group \
    --home-dir /var/lib/mio-gateway --no-create-home --shell /usr/bin/nologin mio-gateway
sudo install -d -m 755 "$app_dir"
sudo install -m 755 -o root -g root "$binary" "$app_dir/mio-gateway"
sudo install -m 644 "$source_dir/README.md" "$app_dir/"
# 2026-11-16: the gateway moved from Node to Rust. The old JavaScript runtime is removed.
sudo rm -rf "$app_dir/src" "$app_dir/package.json"
sudo install -m 755 "$source_dir/mio-pair" /usr/local/bin/mio-pair

step "Konfiguration $config"
sudo install -d -m 700 "$config_dir"
if sudo test -f "$config" && ! $replace_key; then
    # The phone refuses a token that starts like a provider key (about 1 in 32,000 older ones).
    # --ny-groq-nyckel replaces such a token; the phone is then paired again with mio-pair.
    if sudo grep -qiE '^MIO_GATEWAY_TOKEN=(sk-|sk_|gsk_|aiza)' "$config"; then
        fail "Gatewaytoken börjar som en leverantörsnyckel och godtas inte av telefonen. Kör ./install.sh --ny-groq-nyckel; då får gatewayen en ny token, och du parar telefonen igen med mio-pair."
    fi
    echo "Finns redan; Groq-nyckel och gatewaytoken behålls."
    # 2026-11-15: the old installer default of three requests per minute made asking Mio fail
    # while analysis ran. Requests are now sized to the tokens-per-minute budget instead.
    # A value you changed yourself is left alone.
    sudo sed -i 's/^MIO_REQUESTS_PER_MINUTE=3$/MIO_REQUESTS_PER_MINUTE=10/' "$config"
    sudo grep -q '^MIO_TOKENS_PER_MINUTE=' "$config" \
        || printf 'MIO_TOKENS_PER_MINUTE=8000\n' | sudo tee -a "$config" >/dev/null
else
    echo "Skapa en nyckel på https://console.groq.com/keys (gratisnivån räcker)."
    # Hidden prompt: the key never appears on screen, in argv, shell history or logs.
    IFS= read -rsp "Klistra in Groq-nyckeln (syns inte) och tryck Enter: " groq_key; echo
    [[ $groq_key =~ ^gsk_[A-Za-z0-9]{20,200}$ ]] || fail "Det ser inte ut som en Groq-nyckel (börjar med gsk_)."
    # The key travels only on stdin; the gateway binary writes the root-only file (0600). With an
    # existing file only the GROQ_API_KEY line changes: the token (no re-pairing), limits, port
    # and task profiles you set are kept.
    printf '%s' "$groq_key" | sudo "$app_dir/mio-gateway" write-config "$config" "$model" "$port"
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
echo "Para telefonen: kör  mio-pair  och skanna QR-koden i Mio (Inställningar → Parning)."
