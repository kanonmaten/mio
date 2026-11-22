#!/usr/bin/env bash
# Installs or updates Mio Kontroll, the control panel for Mio on this computer.
# Run as your normal user from any directory: ./install.sh  (it uses sudo where needed).
# --utan-autostart leaves out the login entry; the panel then starts only from the menu.
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin=/usr/local/bin/mio-control
helper_dir=/usr/local/lib/mio-control
helper=$helper_dir/mio-control-helper
policy=/usr/share/polkit-1/actions/app.mio.control.policy
applications=/usr/local/share/applications
icon=/usr/local/share/icons/hicolor/scalable/apps/app.mio.control.svg
autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/app.mio.control.desktop"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'FEL: %s\n' "$1" >&2; exit 1; }

with_autostart=true
for argument in "$@"; do
    case "$argument" in
        --utan-autostart) with_autostart=false ;;
        *) fail "Okänt val: $argument. Använd inget val, eller --utan-autostart." ;;
    esac
done

[[ $EUID -ne 0 ]] || fail "Kör som din vanliga användare, inte root. Skriptet använder sudo själv."
for file in Cargo.toml Cargo.lock polkit/app.mio.control.policy desktop/app.mio.control.desktop \
    desktop/app.mio.control-autostart.desktop desktop/app.mio.control.svg; do
    [[ -f "$source_dir/$file" ]] || fail "Hittar inte $file bredvid install.sh."
done

step "Kontrollerar verktyg"
missing=()
command -v cargo >/dev/null || missing+=(rust)
command -v pkexec >/dev/null || missing+=(polkit)
if ((${#missing[@]})); then
    sudo pacman -S --needed --noconfirm "${missing[@]}"
fi
rust_version="$(cargo --version)"
[[ $rust_version =~ ^cargo\ 1\.([0-9]+) ]] && (( BASH_REMATCH[1] >= 92 )) \
    || fail "$rust_version är för gammal. Mio Kontroll kräver Rust 1.92 eller senare: sudo pacman -Syu rust"

step "Bygger Mio Kontroll (första gången cirka tio minuter)"
# Built as you, from the locked dependency versions; only the finished programs are installed.
cargo build --release --locked --manifest-path "$source_dir/Cargo.toml" --workspace
target="$source_dir/target/release"

step "Installerar program, hjälpare och polkit-regler"
sudo install -m 755 -o root -g root "$target/mio-control" "$bin"
# The helper runs as root through pkexec: root-owned, in a directory only root can write.
sudo install -d -m 755 -o root -g root "$helper_dir"
sudo install -m 755 -o root -g root "$target/mio-control-helper" "$helper"
sudo install -m 644 -o root -g root "$source_dir/polkit/app.mio.control.policy" "$policy"
sudo install -D -m 644 "$source_dir/desktop/app.mio.control.desktop" "$applications/app.mio.control.desktop"
sudo install -D -m 644 "$source_dir/desktop/app.mio.control.svg" "$icon"
command -v update-desktop-database >/dev/null && sudo update-desktop-database "$applications" || true
# KDE Plasma finds new menu entries and icons through its own cache (ksycoca, in ~/.cache), not
# GTK's icon cache, so rebuild it as the user; elsewhere the menu picks the entry up by itself.
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true

# The commit this was installed from; Mio Kontroll compares it with the repo to show updates.
if commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)"; then
    printf '%s\n' "$commit" | sudo tee "$helper_dir/commit" >/dev/null
fi

if $with_autostart; then
    step "Startar vid inloggning (bara ikonen i systemfältet)"
    install -D -m 644 "$source_dir/desktop/app.mio.control-autostart.desktop" "$autostart"
else
    rm -f "$autostart"
fi

step "Klart"
echo "Starta nu: mio-control --visa   (eller Mio Kontroll i programmenyn)."
echo "Om panelen redan kör: välj Avsluta i ikonens meny och starta den igen."
