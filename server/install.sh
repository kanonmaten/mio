#!/usr/bin/env bash
# Installs or updates Mio's private AI gateway on CachyOS/Arch, next to Pianissimo.
# Run as your normal user from any directory: ./install.sh  (it uses sudo where needed).
# It builds the Rust gateway with cargo, so the PC needs no Node or other runtime.
# A new installation uses Mistral (user decision 2026-11-20): Small 4 for questions and everyday
# text, Large 4 with medium reasoning for lessons. It asks for the Mistral key and then runs one
# synthetic trial per pair (real, paid Mistral traffic, started by you running this script);
# the pairs are approved only if the trial passes, otherwise the script stops.
# Re-running is the update path: code and the systemd unit are refreshed; keys, provider choice,
# gateway token and counters are kept, so an existing Groq installation stays on Groq with the
# same token and switches to Mistral in Mio Kontroll.
#   --ny-mistral-nyckel  sets the Mistral key (and runs the trial when Mistral is the provider)
#   --ny-groq-nyckel     sets the Groq key; on a computer without a configuration it makes a Groq one
#   --prova-mistral      runs the Mistral trial again, e.g. after a failed one
#   --nyckel-pa-stdin    reads the key from stdin instead of asking (for Mio Kontroll)
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir=/opt/mio-gateway
config_dir=/etc/mio-gateway
config=$config_dir/gateway.env
unit=/etc/systemd/system/mio-gateway.service
groq_model=qwen/qwen3.8-27b
mistral_pairs=(mistral-small-2603 mistral-large-4-0)
port=8787
https_port=8443

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'FEL: %s\n' "$1" >&2; exit 1; }

# A key copied from a browser often brings a space, tab or line break along. Trim them before the
# check, as Mio Kontroll does, so the same key works whichever way it is given.
trim_key() {
    provider_key="${provider_key#"${provider_key%%[![:space:]]*}"}"
    provider_key="${provider_key%"${provider_key##*[![:space:]]}"}"
}

# Hidden prompt: the key never appears on screen, in argv, shell history or logs. A paste that
# starts with a line break ends the read at once with nothing, so an empty answer asks again
# (at most three times) instead of rejecting the key that follows.
read_hidden_key() {
    local attempt
    for attempt in 1 2 3; do
        IFS= read -rsp "$1" provider_key; echo
        [[ -n ${provider_key//[[:space:]]/} ]] && return 0
        if ((attempt < 3)); then echo "Inget kom in. Klistra in nyckeln igen."; fi
    done
    fail "Ingen nyckel kom in efter tre försök. Kör skriptet igen och klistra in nyckeln."
}

# Checks the trimmed key against `pattern` and otherwise says what is wrong with it, never the
# key itself: only its length and which kind of character does not belong.
check_key() {
    # The prefix is optional (Mistral has none); `set -u` would stop on a missing $4.
    local name=$1 pattern=$2 hint=$3 prefix=${4-}
    trim_key
    # Checked first: Groq and sk- keys also fit Mistral's pattern, since Mistral keys may hold _ and -.
    [[ $name == Mistral && $provider_key == gsk_* ]] \
        && fail "Det är en Groq-nyckel (börjar med gsk_). Kör ./install.sh --ny-groq-nyckel för den."
    [[ $provider_key == sk-* || $provider_key == sk_* ]] \
        && fail "Det ser ut som en nyckel från en annan tjänst (börjar med sk-), inte en $name-nyckel."
    [[ $provider_key =~ $pattern ]] && return 0
    # The 20–200 limit counts what follows a required prefix (gsk_ for Groq).
    local length=$((${#provider_key} - ${#prefix}))
    if ((length == 0)); then
        fail "Ingen $name-nyckel kom in. Klistra in den och tryck Enter."
    elif [[ $provider_key =~ [[:space:]] ]]; then
        fail "$name-nyckeln har mellanslag eller radbrytning mitt i. Kopiera den igen, i ett stycke."
    elif [[ $name == Groq && $provider_key != gsk_* ]]; then
        fail "Det ser inte ut som en Groq-nyckel: den börjar inte med gsk_ (${#provider_key} tecken)."
    elif ((length < 20 || length > 200)); then
        fail "$name-nyckeln är $length tecken lång${prefix:+ efter $prefix}, väntat 20–200. Kopiera hela nyckeln igen."
    else
        fail "$name-nyckeln (${#provider_key} tecken) har andra tecken än $hint. Kopiera den igen."
    fi
}

# Which key a new configuration or a key change is for: Mistral unless --ny-groq-nyckel.
key_provider=mistral
replace_key=false
key_on_stdin=false
run_trial=false
for argument in "$@"; do
    case "$argument" in
        --ny-mistral-nyckel) replace_key=true; key_provider=mistral ;;
        --ny-groq-nyckel) replace_key=true; key_provider=groq ;;
        --prova-mistral) run_trial=true ;;
        --nyckel-pa-stdin) key_on_stdin=true ;;
        *) fail "Okänt val: $argument. Använd inget val, --ny-mistral-nyckel, --ny-groq-nyckel, --prova-mistral eller --nyckel-pa-stdin." ;;
    esac
done
provider_key=""
if $key_on_stdin; then
    # Read before anything else can consume stdin. The last line may lack a line break.
    # Blank lines before the key are skipped; the first line with text is the key.
    provider_key=""
    while [[ -z ${provider_key//[[:space:]]/} ]]; do
        IFS= read -r provider_key || [[ -n $provider_key ]] || fail "Ingen nyckel på stdin."
    done
    provider_key="${provider_key%$'\r'}"
fi

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
    echo "Finns redan; nycklar, vald leverantör och gatewaytoken behålls."
    # 2026-11-15: the old installer default of three requests per minute made asking Mio fail
    # while analysis ran. Requests are now sized to the tokens-per-minute budget instead.
    # A value you changed yourself is left alone.
    sudo sed -i 's/^MIO_REQUESTS_PER_MINUTE=3$/MIO_REQUESTS_PER_MINUTE=10/' "$config"
    sudo grep -q '^MIO_TOKENS_PER_MINUTE=' "$config" \
        || printf 'MIO_TOKENS_PER_MINUTE=8000\n' | sudo tee -a "$config" >/dev/null
elif [[ $key_provider == groq ]]; then
    if ! $key_on_stdin; then
        echo "Skapa en nyckel på https://console.groq.com/keys (gratisnivån räcker)."
        read_hidden_key "Klistra in Groq-nyckeln (syns inte) och tryck Enter: "
    fi
    check_key Groq '^gsk_[A-Za-z0-9]{20,200}$' "gsk_ följt av bokstäver och siffror" gsk_
    # The key travels only on stdin; the gateway binary writes the root-only file (0600). With an
    # existing file only the GROQ_API_KEY line changes: the token (no re-pairing), limits, port
    # and task profiles you set are kept.
    printf '%s' "$provider_key" | sudo "$app_dir/mio-gateway" write-config "$config" "$groq_model" "$port"
    unset provider_key
    echo "Sparad (endast root kan läsa den)."
else
    if ! $key_on_stdin; then
        echo "Skapa en nyckel på https://console.mistral.ai/api-keys (Vibe Pro-provet ger krediter i tre månader)."
        echo "Stäng också av träning på din API-data i Mistrals admin-konsol, https://admin.mistral.ai (se server/README.md)."
        read_hidden_key "Klistra in Mistral-nyckeln (syns inte) och tryck Enter: "
    fi
    check_key Mistral '^[A-Za-z0-9_-]{20,200}$' "bokstäver, siffror, _ och -"
    # A new file gets Small 4 for questions and everyday text and Large 4 for lessons, not yet
    # approved. An existing file only gets its MISTRAL_API_KEY line: provider, token and the
    # rest stay as they are.
    printf '%s' "$provider_key" | sudo "$app_dir/mio-gateway" write-mistral-config "$config" "$port"
    unset provider_key
    echo "Sparad (endast root kan läsa den)."
    run_trial=true
fi

unset provider_key

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

if $run_trial; then
    step "Provar Mistral (ett påhittat anrop per uppgift, riktig trafik med din nyckel)"
    if ! sudo grep -q '^MIO_AI_PROVIDER=mistral$' "$config"; then
        # An existing Groq installation: the trial and the switch happen in Mio Kontroll.
        echo "Gatewayen använder inte Mistral som standard. Byt och tryck Prova i Mio Kontroll."
    else
        approved=()
        for pair_model in "${mistral_pairs[@]}"; do
            # The root-only file goes in on stdin; the answer is synthetic text and token counts.
            # Large 4 always reasons and is tried on the lesson task only.
            if result="$(sudo cat "$config" | sudo "$app_dir/mio-gateway" prova mistral "$pair_model")"; then
                echo "Godkänt: mistral $pair_model"
                approved+=("mistral=$pair_model")
            else
                printf '%s\n' "$result"
                fail "Provet av mistral $pair_model gick inte igenom, så Mistral godkändes inte och AI är av. Felkoden står ovan. Fel nyckel: kör ./install.sh --ny-mistral-nyckel. Annars: kör ./install.sh --prova-mistral senare, eller tryck Prova i Mio Kontroll."
            fi
        done
        # Written only after every pair passed, like the panel's helper does it. Any other
        # approved candidates on the line are kept.
        current="$(sudo sed -n 's/^MIO_APPROVED_CANDIDATES=//p' "$config" | tail -n 1)"
        IFS=',' read -r -a entries <<<"$current"
        for entry in "${approved[@]}"; do
            [[ ",$current," == *",$entry,"* ]] || entries+=("$entry")
        done
        line="MIO_APPROVED_CANDIDATES=$(IFS=','; printf '%s' "${entries[*]}")"
        line="${line/=,/=}"
        sudo sed -i '/^MIO_APPROVED_CANDIDATES=/d' "$config"
        printf '%s\n' "$line" | sudo tee -a "$config" >/dev/null
        sudo systemctl restart mio-gateway.service
        for _ in $(seq 1 20); do
            curl --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null && break
            sleep 0.5
        done
        curl --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null \
            || fail "Gatewayen svarar inte efter godkännandet. Se: journalctl -u mio-gateway -n 50"
        echo "Mistral är godkänt och gatewayen är omstartad."
    fi
fi

step "Tailscale (HTTPS på port $https_port, bredvid Pianissimo på 443)"
if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale är inte inloggat. Kör: sudo systemctl enable --now tailscaled && sudo tailscale up"
    echo "Kör sedan ./install.sh igen."
    exit 1
fi
sudo tailscale serve --bg --https="$https_port" "http://127.0.0.1:$port"
sudo tailscale serve status 2>/dev/null || true

# The commit this was installed from; Mio Kontroll compares it with the repo to show updates.
if commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)"; then
    printf '%s\n' "$commit" | sudo tee "$app_dir/commit" >/dev/null
fi

step "Klart"
echo "Para telefonen: kör  mio-pair  och skanna QR-koden i Mio (Inställningar → Parning)."
