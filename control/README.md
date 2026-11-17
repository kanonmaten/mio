# Mio Kontroll

Kontrollpanelen för Mio på datorn: ett program i Rust (gpui-kit) som ligger i systemfältet och visar och styr gatewayen, Pianissimo och Tailscale. Panelen byggs fas för fas enligt [planen](../docs/PLAN_KONTROLLPANEL.md); den här filen skrivs klart i sista fasen.

## Installera

Rust 1.92 eller senare. Kör som din vanliga användare:

```bash
./control/install.sh
```

Skriptet bygger panelen och installerar `mio-control`, rothjälparen `/usr/local/lib/mio-control/mio-control-helper`, polkit-reglerna och en post i programmenyn. Panelen startar vid inloggning som en ikon i systemfältet; `--utan-autostart` hoppar över det.

## Delar

| Mapp | Innehåll |
|---|---|
| `core/` | Allt utan grafik: env-filer, inställningarnas gränser, status, hjälparens kommandolista |
| `helper/` | `mio-control-helper`, som körs som root via `pkexec` med en fast kommandolista |
| `app/` | `mio-control`: fönstret och ikonen i systemfältet |
| `polkit/`, `desktop/` | Polkit-regler, programmenyn, inloggning och ikon |

Utseendet står i [DESIGN.md](DESIGN.md).

## Utveckla

```bash
cd control && cargo test --locked --workspace && cargo clippy --locked --workspace --all-targets -- -D warnings
cargo run -p mio-control -- --visa          # öppna fönstret direkt
cargo run -p mio-control-core --example status_probe   # statusen utan fönster
```

**Ej verifierat:** inget av detta är provat på datorn med KDE Plasma och NVIDIA.
