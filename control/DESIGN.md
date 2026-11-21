# Mio Kontroll: utseende

Gäller kontrollpanelen på datorn (`control/`). Appens egen design står i [DESIGN.md](../DESIGN.md) i repots rot; panelen delar namnet och lugnet men inte färgerna. Valen är användarens från 2026-11-17 ([plan](../docs/arkiv/PLAN_KONTROLLPANEL.md#utseende-och-fönster-användarens-val-2026-11-17)); den här filen beskriver hur de blev ett tema och en ikon.

## Läge

Panelen är ett verktyg: man öppnar den för att se om något är fel eller ändra en inställning, och stänger den. Tydlig status och få steg går före uttryck. Varumärket syns i accenten, ikonen och rundningen, inte i dekor.

## Temat "Mio glöd"

Ett tema i gpui-kits format, [`app/themes/mio-glod.json`](app/themes/mio-glod.json), med en mörk och en ljus variant. Panelen byter variant när skrivbordet gör det (`color-scheme` via XDG-portalen, som KDE Plasma sätter). Hexvärden finns bara i temafilen och i ikonens rasterdata; gränssnittskoden läser roller ur `cx.theme()`.

| Roll | Mörk | Ljus | Används till |
|---|---|---|---|
| Grund | `#1C1B1A` grafit | `#F7F5F2` | Fönstrets yta |
| Yta | `#262423` | `#EFEBE7` | Kort, sidomeny, rutor |
| Text | `#EDE9E5` | `#1C1B1A` | All brödtext |
| Dämpad text | `#A39D97` | `#655F59` | Hjälptext, metadata |
| Linje | `#3A3735` | `#DDD7D1` | Ramar och avdelare |
| Accent | `#F0702E` glödorange | `#F0702E` | Huvudknappen, markerad rad, fokusring, reglage |
| Text på accent | `#1C1B1A` | `#1C1B1A` | Grafit på orange i båda lägena |
| Kör / redo | `#6BBF59` | `#2A7020` | Statusprick och statusikon |
| Varning | `#E8B93C` | `#E8B93C` (fyllning), `#7A5900` (text) | Laddar, nära kvotgränsen |
| Fel | `#E5484D` | `#B8242A` | Bara fel och riskabla åtgärder |

"Info" i gpui-kit är normalt blått; här är det en neutral grafitton, och alla blå standardvärden (markering, dra-och-släpp, diagram) är ersatta med accenten eller grått. Panelen har aldrig blått eller violett.

### Kontrast (WCAG, uträknad 2026-11-17)

| Par | Mörk | Ljus |
|---|---|---|
| Text på grund / yta | 14,2 / 12,8 | 15,8 / 14,5 |
| Dämpad text på grund / yta | 6,4 / 5,8 | 5,8 / 5,3 |
| Grafit på accent (knapptext) | 5,8 | 5,8 |
| Kör-färg på grund / yta | 7,6 / 6,8 | 5,6 / 5,2 |
| Varningsfärg på grund / yta | 9,4 / 8,4 | 5,9 / 5,4 (textvarianten) |
| Felröd på grund / yta | 4,4 / 4,0 | 5,8 / 5,3 |

Två saker följer av siffrorna:

- **Vit text på orange når bara 3,0**, så knappar och markeringar har grafit text i båda lägena.
- **Felrött `#E5484D` når inte 4,5 mot ytan i mörkt läge.** Det används därför till ikoner, prickar och fyllningar. En felmening skrivs i vanlig textfärg med en röd ikon framför. Statusetiketter (`Tag`) på röd fyllning har grafit text (4,4) i stället för vit (3,9).
- **Statusetiketterna** på översikten har alltid ikon och ord: bock för "Kör" och "Redo", varningstriangel för det som laddar eller närmar sig en gräns, kryss för fel, och ett neutralt i för "Inte installerad".
- Orange som text på ljus grund (2,7) används inte; länkar i ljust läge har den mörkare `#A8420F` (5,6).

### Form

- Rundning 8 px på kontroller, 12 px på dialoger, notiser och fönstrets hörn (`window.radius`). Fönstret ritar sin egen titelrad och ram (klientdekorationer), annars ritar KWin raka hörn. **Ej verifierat** på KDE Wayland med NVIDIA.
- Inga skuggor på kontroller (`shadow: false`); bara lager ovanpå (meny, dialog, notis) har skugga, enligt gpui-kits designguide.
- Grundstorlek 14 px (gpui-kit utgår från 16) så att sidorna ryms i det lilla fönstret på cirka 720 × 520. Allt annat följer rem-skalan, så hela gränssnittet växer om storleken ändras.
- Status visas alltid med ikon eller ord bredvid färgen.

## Ikonen i systemfältet

Ritas i kod ([`core/src/tray_icon.rs`](core/src/tray_icon.rs)), så den behöver ingen bildfil och följer samma färger som temat.

- **Märket:** en orange rundad kvadrat med ett grafit "M" i runda streck. M:et ligger lite upp och till vänster så att pricken bara klipper foten på högra benet.
- **Pricken:** nere till höger, grön när allt kör, bärnsten när något laddar, kvoten nästan är slut eller senaste säkerhetskopian är äldre än 48 timmar, röd när en tjänst är nere. En grafit ring skiljer pricken från det orange, så den syns på både ljus och mörk panel. Innan första statusen är läst finns ingen prick.
- **Storlekar:** 22, 32, 48 och 64 px skickas till systemfältet, som väljer själv. Varje pixel är medelvärdet av 4 × 4 punkter, så kanterna blir mjuka även i 22 px.
- **Verktygstipset** säger samma sak i ord, till exempel "Gateway kör · Pianissimo redo · Tailscale ok", så att färgen aldrig är ensam.

Förhandsvisning: `cargo run -p mio-control-core --example tray_icon_preview -- <mapp>` skriver varje läge som PAM-bild i 22 och 64 px.

**Ej verifierat:** hur ikonen ser ut i Plasmas systemfält, i ljus och mörk panel och med skalning. På den bärbara datorn (Hyprland med Waybar) registrerar sig ikonen över D-Bus.
