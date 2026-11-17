# Plan: kontrollpanelen för datorn

Användarens önskemål 2026-11-16 och 2026-11-17. Planen är skriven för att köras som ett mål i Claude Code, fas för fas. Den ersätter avsnittet "Planerat: kontrollpanel för datorn" i [ROADMAP](ROADMAP.md) som arbetsbeskrivning; ROADMAP länkar hit.

Kontrollpanelen är ett skrivbordsprogram i Rust med GPUI som visar och styr allt Mio kör på datorn: AI-gatewayen, Pianissimo, egna ord, Tailscale, parningen, uppdateringar och verifieringen. Datorn kör CachyOS med KDE Plasma 6.8 (Wayland) och en NVIDIA-GPU. Utvecklingen sker på en MacBook Air med Omarchy (Hyprland), så allt som bara går att se på datorn märks **ej verifierat** tills det är provat där.

## Beslut som planen utgår från

Användaren kan ändra vilket som helst av dessa. Fas 0 skriver in dem i [DECISIONS.md](DECISIONS.md) med de bortvalda alternativen.

| Fråga | Planens val | Bortvalt |
|---|---|---|
| Var koden ligger | Ny mapp `control/` i Mio-repot, paketet `mio-control`, programmet `mio-control`, visningsnamn "Mio Kontroll" | Eget repo: panelen läser samma konfigurationsfiler och skript som `server/` och `transcription-server/`, så de hör ihop |
| Gränssnitt | [`gpui-kit`](https://crates.io/crates/gpui-kit) 0.10.0, låst exakt (`=0.10.0`) | `gpui` 0.2.2 från crates.io (släppt okt 2025, långt efter Zeds egen GPUI); `gpui-component` direkt (gpui-kit låser rätt GPUI-version åt oss); Qt/QML |
| Behörighet | Panelen kör som användaren. Allt som skriver i `/etc`, styr systemtjänster eller läser hemligheter går genom en liten hjälpare, `mio-control-helper`, som körs som root via `pkexec` med en egen polkit-policy | Panelen som root; `sudo` i en terminal; systemd:s egen polkit-åtgärd för varje start/stopp (frågar lösenord varje gång och täcker inte filerna) |
| Lösenordsfrågor | `auth_admin_keep`: KDE frågar en gång och minns det några minuter. Visa parningskoden kräver alltid lösenord | Inga frågor alls (en polkit-regel som släpper igenom gruppen `wheel`) |
| Utseende | Glödorange accent `#F0702E` på grafit, följer KDE:s ljusa/mörka läge, rundade hörn; bor i systemfältet med ett litet fönster (cirka 720 × 520) som kan maximeras och visas i helskärm (användarens val 2026-11-17) | Mios blå accent; röd-orange accent (krockar med felrött); bara mörkt tema; vanligt program som avslutas när fönstret stängs; statusruta vid ikonen (osäker placering på KDE Wayland) |
| Hemligheter | Panelen sparar aldrig nycklar eller tokens. De går via stdin till hjälparen, visas maskerade och skrivs aldrig i logg eller argv | Lagra i KWallet/Secret Service |
| Leverantörer | Groq, Mistral, NVIDIA NIM, Cloudflare Workers AI och Anthropic, se [Leverantörer](#leverantörer-och-modeller) | |

## Leverantörer och modeller

Användaren vill kunna välja mellan Groq, Mistral, NVIDIA, Cloudflare och Anthropic (2026-11-17). Panelen ritar rullistor, men gatewayen kör bara par av leverantör och modell som finns granskade i `server/src/model_profiles.rs`. Varje ny leverantör är därför i första hand gatewayarbete (fas 3), och panelen visar det som gatewayen godkänner.

Fyra av Mios regler påverkas, och användaren behöver godkänna ändringen innan fas 3 slås ihop:

1. **"Groq `qwen/qwen3.8-27b` only"** i `CLAUDE.md` blir: granskade par i `model_profiles.rs`, ett aktivt par per uppgift (`ask`, `everyday`, `lesson`), valt på datorn. Ingen automatisk reserv och ingen failover; det står kvar under "Not in 0.9.0".
2. **"No model picker"** gäller appen. Väljaren finns bara i panelen på datorn; appen visar som i dag vilken modell som svarar.
3. **"Temperature 0"** kan inte uppfyllas av Anthropics nuvarande modeller: de avvisar `temperature` med 400 (alla modeller från API-versionen 2026-10-21). Förslag: en granskad modell får markeras "temperatur stöds inte av leverantören" och skickas då utan parametern. Det loggas i granskningen och syns i `/v2/status`, så det är aldrig tyst.
4. **"Reasoning off"**: Claude Opus 5.5 kan inte stänga av tänkandet och Sonnet 5.5 bara med `between_tools`. **Claude Haiku 5.5** (`claude-haiku-5-5`) kan stänga av det vid effort `high` eller lägre och stöder strikt strukturerad utdata (`output_config.format`). Planen granskar därför bara Haiku 5.5 hos Anthropic. Den kostar $0.10 per miljon token in och $0.50 ut (upp till 100 000 token prompt), och Anthropic har ingen gratisnivå.

| Leverantör | Ansluts som | Att granska i officiell dokumentation (fas 3) | Kända hinder |
|---|---|---|---|
| Groq | Finns (`chat`) | Inget nytt | |
| Mistral | Chat completions, egen adapter om formatet skiljer | `response_format` med `json_schema` och om `strict` finns; svensk kvalitet | Gratisplanen Experiment kan träna på anropen; användaren har sagt att det är godtagbart ([lärdom 2026-11-17](../.trail/learnings/2026-11-17-free-ai-providers-checked-as-groq-kanonmaten.md)). Modellerna har inget resonemang att stänga av (`plain: true`) |
| NVIDIA NIM | OpenAI-kompatibel chat | Strikt JSON-schema per modell, hur resonemang stängs av, vilka Qwen-modeller som finns | Användes 2026-10-05 och byttes mot Groq 2026-10-11 ([beslut](DECISIONS.md#ai-gatewayen-på-datorn-med-groq-2026-10-11)); läs varför innan adaptern skrivs. Den gamla koden finns i Git-historiken |
| Cloudflare Workers AI | OpenAI-kompatibel adress med konto-ID | JSON-schema-läget, gränser i gratisnivån, konto-ID i adressen | Allt på Cloudflare kräver användarens godkännande (CLAUDE.md). Användaren skapar själv API-token med bara Workers AI-behörighet |
| Anthropic | Egen adapter för Messages API (`/v1/messages`), rå HTTP från Rust | Haiku 5.5: `thinking: {type: "disabled"}`, `output_config.format`, stop reasons (`refusal`, `max_tokens`) | Temperatur, se punkt 3. Ingen gratisnivå. En `refusal` hanteras som en innehållsberoende avvisning ([lärdom](../.trail/learnings/2026-11-17-ai-batch-failures-caused-by-the-kanonmaten.md)): delen hoppas över eller delas, AI stängs inte av |

Varje leverantör följer gatewayens egen checklista (`server/README.md`, "Lägga till en leverantör senare"): en post i `PROVIDERS`, en granskad modell i `reviewed_model` med källor, en adapter om formatet skiljer, en nyckel i `gateway.env`, syntetiska tester utan nätet, och `live_tested: false` tills ett riktigt prov är godkänt. Tokenbudgeten per minut (`MIO_TOKENS_PER_MINUTE`) gäller i dag Groq; den blir en gräns per leverantör.

Panelens modellista bygger på två källor:

- **Granskade modeller**, från ett nytt kommando i gatewayen (`mio-gateway granskade-modeller`, JSON). Bara de kan väljas.
- **Leverantörens egen modellista** (till exempel Groqs `GET /openai/v1/models`) visas gråmarkerad med "inte granskad", så användaren ser vad som finns. Anropet genererar ingenting men använder nyckeln, så panelen frågar första gången.

## Det som redan finns att bygga på

| Del | Var | Vad panelen gör med det |
|---|---|---|
| Gatewayens inställningar | `/etc/mio-gateway/gateway.env` (root, 0600): `MIO_AI_PROVIDER`, `MIO_AI_MODEL`, `MIO_AI_TASK_PROFILES`, `MIO_REQUESTS_PER_MINUTE` (1–60), `MIO_TOKENS_PER_MINUTE`, `MIO_TOKENS_PER_DAY` (högst 1 000 000), `MIO_REQUESTS_PER_DAY`, `MIO_LESSON_INTERVAL_SECONDS` (60–3600), `PORT`, nycklar och `MIO_GATEWAY_TOKEN` | Läser och skriver via hjälparen; validerar med gatewayens egen kod före skrivning |
| Gatewayens status | `GET /health` (utan token), `GET /v2/status` (token): konfiguration, revision, dagens kvot | Översikten och AI-sidan. Hjälparen gör anropet med token; panelen får JSON utan hemligheter |
| Pianissimos inställningar | `/etc/mio-transcription.conf`: `MIO_PRECISION` (`fp32`/`fp16`), `MIO_PREPROCESS`, `MIO_SPEAKER_LABELS`, `MIO_VOCABULARY_BOOST` (0–2), `MIO_MODEL_REVISION`, `MIO_DIARIZATION_REVISION`, `MIO_TRANSCRIPTION_TOKEN` | Transkriptionssidan |
| Egna ord | `/etc/mio-transcription-vocabulary.txt`: högst 500 rader, 100 byte per rad, `#` är kommentar | Redigerare med samma gränser; antal aktiva ord från `/health` |
| Pianissimos hälsa | `GET 127.0.0.1:8765/health`: redo, modellversion, precision, talarmärkning, ordlista | Översikten |
| Systemd | `mio-gateway.service`, `mio-transcription.service`, `mio-pianissimo-update.timer` och `.service` | Status via D-Bus utan lösenord; start, stopp och omstart via hjälparen |
| Skript | `server/install.sh` (`--ny-groq-nyckel`), `transcription-server/install.sh`, `check.sh`, `update-model.sh`, `server/mio-pair` | Uppdateringar och guiden; skripten får ett läge utan frågor (fas 1) |
| Parning | `mio-gateway pairing-payload <värd>` läser konfigurationen på stdin; `mio-gateway tailscale-host` | QR-koden ritas i panelen, bara i minnet |
| Verifiering | `mio-verify verify` i `tools/` skriver kvittot `verification.json` med resultat per grind | Verifieringssidan läser kvittot |

## Verktyg och bibliotek

| Verktyg | Version (kontrollerad 2026-11-17) | Användning |
|---|---|---|
| [`gpui-kit`](https://gpui-kit.com) | 0.10.0, släppt 2026-11-16, Apache-2.0 | Enda GPUI-beroendet. Låser `gpui-pre` 0.3.12 och tar med `gpui-component` 0.10. Har de komponenter panelen behöver: `sidebar`, `setting`, `form`, `select`, `combobox`, `switch`, `slider`, `input` (maskerad), `stepper`, `table`, `chart`, `notification`, `dialog`, `sheet`, `status_bar`, `title_bar`, `tag`, `progress`, `spinner`, `kbd` |
| gpui-kits skills för Claude Code | `skills/gpui-kit` och `skills/gpui-kit-design-guides` i [longbridge/gpui-kit](https://github.com/longbridge/gpui-kit), taggen `v0.10.0` | Kopieras in i `.claude/skills/` i fas 0, med licensen i `THIRD_PARTY_NOTICES.md`. Skillen kräver att kod- och designguiden läses före arkitektur- och gränssnittsbeslut och förbjuder påhittade API:er |
| Inställningsreceptet | `examples/ai_recipes` i samma repo | Testat mönster för inställningar med `on_change` på Checkbox/Switch/RadioGroup, Form, dialoger och notiser. Utgångspunkt för AI- och transkriptionssidorna |
| [`zbus`](https://crates.io/crates/zbus) 6.3 och [`zbus_systemd`](https://crates.io/crates/zbus_systemd) | 2026-11 | Tjänststatus och timerstatus från systemd utan att starta processer |
| [`ksni`](https://crates.io/crates/ksni) 0.3.7 | 2026-10 | Ikon i KDE:s systemfält (StatusNotifierItem) med status och snabbval |
| [`notify-rust`](https://crates.io/crates/notify-rust) 4.19 | 2026-11 | Skrivbordsnotis när en tjänst går ner, en uppdatering misslyckas eller kvoten tar slut |
| `journalctl -o json`, `tailscale status --json`, `tailscale serve status --json`, `nvidia-smi --query-gpu=… --format=csv`, `checkupdates` | Systemets | Loggar, Tailscale, GPU-minne och temperatur, väntande paketuppdateringar. Inga nya beroenden |
| Context7 och gpui-kit.com | | Aktuell dokumentation före varje GPUI-beslut |

Bortvalt: tredjepartsskills för GPUI (`aprilnea/gpui-skills`, `majiayu000/claude-skill-registry`, `geoffjay/gpui-patterns`, `cnwzhu/gpui-skills`) är inte granskade och skrivna för andra GPUI-versioner; gpui-kits egna skills följer biblioteket. `create-gpui-app` behövs inte eftersom gpui-kit ger startpunkten. `tray-icon` drar in GTK; `ksni` talar KDE:s protokoll direkt.

Krav: gpui-kit kräver Rust 1.92 eller senare (repot anger 1.88 för `server/` och `tools/`; datorn och CI kör 1.100) och en fungerande Vulkan-drivrutin. `control/Cargo.toml` får `rust-version = "1.92"`.

## Skärmar

### Utseende och fönster (användarens val 2026-11-17)

Panelen liknar Mio lite men är varmare, åt Omarchys röd-orange håll. Eget gpui-kit-tema "Mio glöd":

| Roll | Mörk | Kommentar |
|---|---|---|
| Grund | `#1C1B1A` grafit | Ljus variant tas fram i fas 0 med samma accent |
| Yta (kort, sidomeny) | `#262423` | |
| Accent | `#F0702E` glödorange | Knappar, markering, valda rader. Aldrig blått eller violett |
| Kör / redo | `#6BBF59` grön | |
| Varning | `#E8B93C` bärnsten | |
| Fel | `#E5484D` röd | Ren röd används bara för fel, så ett fel skiljer sig från accenten |

- Temat följer KDE:s ljusa eller mörka läge och byter när KDE gör det.
- Rundade hörn på fönster, kort, knappar och fält. Fönstret ritar sin egen titelrad (`title_bar`, `window_border`) så hörnen blir rundade även under KWin; **ej verifierat** på KDE Wayland.
- Status visas alltid med ikon eller text bredvid färgen, inte bara med färg.

**Fönster och systemfält.** Panelen startar vid inloggning som en ikon i systemfältet, utan fönster. Ett klick på ikonen öppnar ett litet fönster, cirka 720 × 520, som går att ändra storlek på, maximera och visa i helskärm. När fönstret stängs fortsätter ikonen att köra; Avsluta finns i ikonens meny. Ikonen är ett enkelt Mio-tecken med en liten prick i hörnet: grön när allt kör, bärnsten när något laddar eller närmar sig kvotgränsen, röd när en tjänst är nere. Verktygstipset listar varje del, till exempel "Gateway kör · Pianissimo redo · Tailscale ok".

### Sidorna

Sidomeny till vänster, en sida per del, svensk text. I det lilla fönstret fälls sidomenyn ihop till ikoner. Varje ändring visas som en lista "före → efter" innan den sparas, och sparas sedan med en knapp.

**Översikt.** Ett kort per del: gatewayen (kör, `/health`, revision, dagens kvot och när den nollställs), Pianissimo (redo eller laddar, modellversion, precision, talarmärkning, antal egna ord), Tailscale (inloggad, adress, `serve` rätt uppsatt), GPU (minne, temperatur, användning), nattuppdateringen (senaste körning och resultat) och senaste verifieringen. Omstartsknapp per tjänst.

**AI.** Rullista för leverantör och för modell (sökbar). Under "Per uppgift" kan `ask`, `everyday` och `lesson` få egna val, som skrivs till `MIO_AI_TASK_PROFILES`. Gränser som siffror med gatewayens tillåtna intervall. Byt nyckel för vald leverantör (maskerat fält). "Spara och starta om" visar vad som ändras och att telefonen får en ny konfigurationsrevision: appen läser om statusen efter svaret 409 `configuration_changed`, så den behöver inte paras om. En spärr hindrar att ett par som inte är granskat sparas.

**Transkription.** Precision (`fp32`/`fp16`) med länk till mätningen; förbehandling och talarmärkning som brytare; ordlistans styrka som reglage 0–2 i steg om 0,1 med varning över 1,0; modellversion med "Uppdatera nu"; nattlig uppdatering på eller av; talarmodellens låsta commit med "Byt till senaste".

**Egna ord.** Redigerare för ordlistan med radräknare, varning vid över 100 byte eller över 500 rader, och sortering. Spara skriver filen och startar om Pianissimo. Orden visas bara i panelen och går aldrig någon annanstans.

**Tailscale och parning.** Inloggning, datorns namn, och kontroll att `serve` pekar 443 → 8765 och 8443 → 8787. Är `funnel` på visas en röd varning; panelen slår aldrig på funnel. Knappen "Ställ in serve" kör samma kommandon som installationen. "Visa parningskod" frågar lösenord, ritar QR-koden i fönstret och döljer den efter 60 sekunder eller när fönstret tappar fokus. "Byt token" för gatewayen eller Pianissimo påminner om att telefonen måste paras om.

**Uppdateringar.** "Uppdatera allt" plus en rad per del med nuvarande och tillgänglig version: Mio-repot (`git pull --ff-only`, vägrar om arbetskopian har ändringar), gatewayen, Pianissimos serverkod, Pianissimo-modellen (`update-model.sh`), panelen själv, och systempaketen. Systempaketen uppdateras aldrig i bakgrunden: panelen visar antalet från `checkupdates` och öppnar Konsole med `sudo pacman -Syu`. Stegen körs i ordning och stannar vid första fel med utskriften synlig.

**Verifiering.** Kör `mio-verify verify` och visar varje grind med resultat och tid, från `verification.json`. Utskriften visas löpande.

**Loggar.** Journalen per tjänst med följ-läge och filter på nivå. Gatewayen och Pianissimo loggar aldrig text, nycklar eller ord; panelen lägger inte till något.

**Datorn.** "Håll datorn vaken medan Mio används" (inhibering via `org.freedesktop.PowerManagement.Inhibit`, som KDE:s energihantering respekterar), starta panelen vid inloggning, systemfältsikon på eller av.

**Kom igång.** Guide med `stepper` för en ny dator: kontrollera NVIDIA-drivrutinen, Rust och Tailscale; välj leverantör och klistra in nyckel; installera gatewayen; installera Pianissimo och vänta på "redo"; ställ in Tailscale `serve`; visa parningskoden. Varje steg går att köra om och hoppar över det som redan är klart.

**Systemfältets meny.** Öppna panelen, starta om gatewayen, starta om Pianissimo, pausa AI på datorn (stoppa gatewayen), visa parningskod, avsluta. När en tjänst går från kör till nere kommer också en skrivbordsnotis.

## Uppbyggnad

**Ändrat vid bygget (2026-11-17, fas 0):** koden är en Cargo-arbetsyta med tre crates i stället för ett paket med två program: `control/core` (ingen GPUI), `control/helper` (`mio-control-helper`, länkar aldrig GPUI eftersom den körs som root) och `control/app` (`mio-control`). Temat ligger i `control/app/themes/mio-glod.json`. Strukturen nedan var planens utgångspunkt.

```text
control/
├── Cargo.toml          paketet mio-control, två program
├── src/core/           ingen GPUI: läsa och skriva env-filer, validering, status, kommandon
├── src/ui/             GPUI-vyerna, en modul per sida
├── src/bin/mio-control.rs
├── src/bin/mio-control-helper.rs
├── polkit/app.mio.control.policy
├── desktop/app.mio.control.desktop
├── install.sh
└── README.md
```

- **Kärnan** är vanlig Rust utan grafik, så den testas med `cargo test` på Linux och i CI. Env-filer läses och skrivs med kommentarer, ordning och okända rader bevarade. Skrivning sker atomärt (tillfällig fil, fsync, rename) och den förra versionen sparas som `.bak` bredvid.
- **Validering** görs av samma kod som tjänsterna använder. Gatewayen får kommandot `mio-gateway kontrollera-konfiguration` som läser en env-fil på stdin och kör `load_config` och `validate_config`; panelen skriver aldrig en fil som gatewayen skulle vägra starta med. Pianissimos värden kontrolleras mot gränserna i dess README.
- **Hjälparen** har en fast lista med kommandon och inga sökvägar eller skal från panelen: läs konfiguration (hemligheter ersatta), skriv godkända nycklar, sätt hemlighet (stdin), byt token, skriv ordlista, starta/stoppa/starta om en tjänst ur en tillåten lista, timer på/av, uppdatera modellen, ställ in `serve`, hämta parningsdata, hämta `/v2/status`. Allt annat avvisas. Varje kommando är en egen polkit-åtgärd (`app.mio.control.read`, `.write`, `.service`, `.pair`).
- **Asynkront arbete** (statusfrågor var 5:e sekund, journalen, långa skript) körs i bakgrundsuppgifter enligt gpui-kits kodguide; vyn uppdateras när svaret kommer och fryser aldrig.

## Faser

Varje fas slutar med att fasens tester och `mio-verify verify` är gröna, ändringen är committad och pushad till `main` (projektets regel), och GitHub-körningen "Verifiera Mio på Linux" är kontrollerad för exakt den commiten. [STATUS](STATUS.md) får bara kontroller som faktiskt körts.

### Fas 0. Förberedelser

- Skriv besluten ovan i `DECISIONS.md`, med bortvalda alternativ.
- Kopiera gpui-kits två skills från taggen `v0.10.0` till `.claude/skills/` och lägg till licensen i `THIRD_PARTY_NOTICES.md`.
- Skapa `control/` med `.gitignore` (`target/`), ett fönster med gpui-kits knapp, temat "Mio glöd" i mörk och ljus variant, och systemfältsikonen. Kör `impeccable`-skillen för temat och ikonen; spara resultatet i `control/DESIGN.md`.
- Lägg till steget `control` i `mio-verify` (`cargo test --locked` och `cargo clippy --locked --all-targets -- -D warnings`) och i CI med de Linux-paket gpui-kit anger (Ubuntu: `libfontconfig-dev libwayland-dev libxkbcommon-x11-dev libx11-xcb-dev libssl-dev libzstd-dev libvulkan1`). Verifierarens befintliga svenska meddelanden ändras inte.
- Klart när: fönstret öppnas på bärbara datorn (Hyprland), testerna går i CI.

### Fas 1. Kärnan och hjälparen

- Env-läsare och -skrivare med test för att kommentarer och okända rader överlever.
- `mio-gateway kontrollera-konfiguration` och `mio-gateway granskade-modeller`, som kommandon bredvid `pairing-payload`. HTTP-beteendet och paritetstesterna rörs inte.
- `mio-control-helper` med kommandolistan, polkit-policyn och tester mot en tillfällig rotmapp (bara i testerna).
- Läge utan frågor i `server/install.sh` och `transcription-server/install.sh` (nyckel på stdin), med samma beteende som i dag när flaggan saknas. *Vid bygget:* `transcription-server/install.sh` frågar ingenting utom `sudo`, så bara gatewayens skript fick ett läge (`--nyckel-pa-stdin`). Hjälparen fick också en femte polkit-grupp, `status`, utan lösenord för den återkommande statusfrågan (se [besluten](DECISIONS.md)).
- Statusläsare: systemd via D-Bus, `/health`, `/v2/status` via hjälparen, Tailscale, `nvidia-smi`.
- `control/install.sh`: bygger, installerar program, policy och `.desktop`-fil.

### Fas 2. Skal, översikt, systemfält och notiser

Sidomenyn, Översikt, systemfältsikonen och notiserna. GPUI-tester (`#[gpui_kit::test]`) för att korten visar rätt läge från falsk status.

### Fas 3. Leverantörer i gatewayen

Granska varje leverantör i officiell dokumentation (Context7 eller leverantörens sida) och skriv källorna i `reviewed_model`. Ordning: Mistral, NVIDIA NIM, Cloudflare Workers AI, Anthropic (Haiku 5.5). Ny adapter för Anthropics Messages API. Syntetiska tester per leverantör, inklusive avvisning, avkortning och för stort anrop. Uppdatera `server/README.md`, `CLAUDE.md` (reglerna i [Leverantörer](#leverantörer-och-modeller), först efter användarens OK) och `DECISIONS.md`.

**Stannar för godkännande:** ändringen av reglerna i `CLAUDE.md`, varje första riktiga anrop mot en leverantör (syntetisk svensk text) och allt som rör Cloudflare-kontot.

*Vid bygget (2026-11-17):* användaren godkände regeländringarna. Anthropic Haiku 5.5 är granskad, Mistral och NVIDIA NIM har adaptrar men är inte valbara förrän ett syntetiskt anrop är godkänt, och Cloudflare Workers AI ströks eftersom dess dokumentation säger att JSON-schemat inte kan garanteras (se [besluten](DECISIONS.md)).

### Fas 4. AI-sidan

Rullistor, uppgiftsprofiler, gränser, nyckelbyte, förhandsvisning av ändringen och omstart. Interaktionstest: välj modell, se ändringen, spara mot en falsk hjälpare.

### Fas 5. Transkription och egna ord

Sidorna med reglage, brytare och ordlisteredigeraren. Test för ordlistans gränser.

### Fas 6. Tailscale och parning

Kontroll av `serve`, varning för `funnel`, QR-koden i fönstret, tokenbyte.

### Fas 7. Uppdateringar

Raderna per del, "Uppdatera allt", Konsole för systempaketen, och stopp vid första fel.

### Fas 8. Verifiering och loggar

Kvittot från `mio-verify`, journalen med följ-läge.

### Fas 9. Kom igång och Datorn

Guiden och sidan Datorn (håll vaken, autostart).

### Fas 10. Dokumentation och överlämning

`control/README.md` (svenska, genom humanizer), länk från README och ROADMAP, `CHANGELOG.md`, `STATUS.md` med körda kontroller. Lista för provet på datorn, nedan.

## Prov på datorn (användaren)

Inget av detta kan provas från bärbara datorn. Allt står som **ej verifierat** i STATUS tills det är gjort på `cachyos-pc`:

1. Fönstret ritas under KDE Plasma 6.8 Wayland med NVIDIA-drivrutinen, har rundade hörn, går att maximera och visa i helskärm, och följer ljust/mörkt läge.
2. Panelen startar vid inloggning som bara en ikon. Pricken är grön när allt kör och blir röd när `mio-transcription` stoppas. Att stänga fönstret lämnar ikonen kvar.
3. KDE:s lösenordsruta kommer vid första skrivning och inte igen inom några minuter.
4. Byt modell, spara, och se att telefonen fortsätter utan ny parning.
5. Lägg till ett eget ord och se antalet öka i Mio under Inställningar → Transkription.
6. Visa parningskoden och skanna den med telefonen.
7. "Uppdatera allt" på en dator där något ligger efter.
8. "Håll datorn vaken" hindrar viloläge.

## Risker

- **gpui-kit släpps varje vecka och bryter API.** Versionen låses exakt och uppgraderas som en egen ändring med skillsen från samma tagg.
- **Vulkan på bärbara datorn** (Intel HD 6000, Broadwell) är inte provat med GPUI. Fungerar fönstret inte där körs gränssnittstesterna huvudlöst och utseendet provas på datorn.
- **Hjälparen kör som root.** Den har ingen skalkörning, inga sökvägar från panelen och en fast kommandolista, och varje kommando har ett test för att otillåten indata avvisas.
- **Nya leverantörer ger andra svar än Qwen.** Prompterna är skrivna för Qwen; varje ny modell kräver ett godkänt syntetiskt prov innan den kan väljas för `everyday` eller `lesson`.

## Utanför planen

Ändringar i iOS-appen (konfigurationsrevisionen räcker), automatisk failover mellan leverantörer, fjärrstyrning från telefonen, Windows och macOS, och allt på Cloudflare utöver Workers AI-anrop som användaren godkänt.
