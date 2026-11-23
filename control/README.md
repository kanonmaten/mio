# Mio Kontroll

Mio Kontroll är kontrollpanelen för det Mio kör på datorn: AI-gatewayen, Pianissimo och Tailscale. Den ligger som en ikon i systemfältet och öppnar ett fönster på cirka 720 × 520 när du klickar. Fönstret går att ändra storlek på, maximera och visa i helskärm (F11). Stänger du fönstret ligger ikonen kvar; Avsluta finns i ikonens meny.

Panelen är skriven i Rust med [gpui-kit](https://gpui-kit.com) 0.10.0 och byggd enligt [planen](../docs/arkiv/PLAN_KONTROLLPANEL.md). Valen och de bortvalda alternativen står i [besluten](../docs/DECISIONS.md), utseendet i [DESIGN.md](DESIGN.md).

**Ej verifierat:** panelen är inte provad på datorn med KDE Plasma och NVIDIA. Se [provet på datorn](#prov-på-datorn) nedan.

## Installera

Det krävs Rust 1.92 eller senare. Kör som din vanliga användare i Mio-repot:

```bash
./control/install.sh
```

Skriptet bygger panelen (första gången cirka tio minuter) och installerar `mio-control` i `/usr/local/bin`, rothjälparen `/usr/local/lib/mio-control/mio-control-helper`, polkit-reglerna, en post i programmenyn och en post som startar panelen vid inloggning. Med `--utan-autostart` blir den sista posten bort. Starta sedan med `mio-control --visa` eller Mio Kontroll i programmenyn.

Panelen läser repot den byggdes i (för uppdateringar och verifiering), så flytta inte repot efter installationen. Flyttar du det, kör `./control/install.sh` igen från den nya platsen.

## Sidorna

Översikt har ett kort per del: gatewayen med dagens kvot, Pianissimo med modell, precision och antal egna ord, Tailscale, GPU:n, nattuppdateringen och senaste verifieringen. Tjänsterna kan startas om härifrån. Har gatewayen säkerhetskopior visar ett kort när den senaste kopian från telefonen togs ("i natt 03:12", "för 3 dagar sedan"), hur många kopior som sparas och hur mycket de tar sammanlagt, och att de ligger i `/var/lib/mio-gateway/backups/`. Kortet blir gult när senaste kopian är äldre än 48 timmar, eftersom telefonen ska ta en varje natt. En kopia återställs i appen under Inställningar, inte här. En äldre gateway utan säkerhetskopior visar inget kort.

Kom igång är en guide för en ny dator. Den kontrollerar NVIDIA-drivrutinen, Rust och Tailscale, installerar gatewayen i din standardterminal utan att fråga efter någon nyckel (`./server/install.sh --utan-nyckel`), låter dig välja AI-leverantör, nyckel och modell i steget AI-leverantör, installerar Pianissimo, ställer in Tailscale serve och visar parningskoden. Steget AI-leverantör är samma vy som AI-sidan, så allt du väljer där går att ändra under AI; steget är klart när gatewayen säger att Frågor, Vardag och Lektioner alla har en granskad modell och en nyckel. Steg som redan är klara hoppas över, men alla går att köra igen.

Under AI står först **Leverantörer**: Mistral, Groq, Anthropic, NVIDIA, OpenAI, OpenRouter och Google Gemini, var och en med "Nyckel sparad" eller "Ingen nyckel". "Lägg till nyckel…" eller "Byt nyckel…" öppnar ett dolt fält i raden; nyckeln går till hjälparen på stdin och visas aldrig. Under **Modell per uppgift** väljer du för Frågor, Vardag och Lektioner först leverantör och sedan modell i en lista du kan söka i. När du byter leverantör väljs dess första modell som får användas för uppgiften. Listan har tre grupper: modeller som går att välja, modeller som kräver prov och, för OpenRouter, modeller som OpenRouter listar men som inte är granskade. De två sista är gråa och går inte att välja. OpenRouters lista hämtas en gång med `curl` från deras publika adress, utan nyckel; går den inte att hämta saknas bara den gruppen. Resonerar lektionsmodellen visas raden **Resonemang** under Lektioner, med de nivåer som är granskade för modellen (Låg, Medel, Hög); den sparas som `MIO_LESSON_REASONING`. Har modellen bara en granskad nivå står den som text. Byter du till en modell där nivån inte är granskad går den tillbaka till modellens egen. Frågor är gatewayens standard (`MIO_AI_PROVIDER`, `MIO_AI_MODEL`); när du byter den får Vardag och Lektioner egna profiler, så att de stannar där de var. Gränserna ligger ihopfällda under "Gränser". Varje ändring visas som före och efter innan du sparar, och ett par som inte är granskat går inte att spara. En kandidat blir valbar först när du har tryckt Prova och modellen klarat ett kort påhittat anrop per uppgift den får användas till; Prova går inte att trycka på förrän leverantören har en nyckel. Anropet går till leverantören och kostar som ett vanligt anrop. Ett godkänt prov skrivs in i `MIO_APPROVED_CANDIDATES` i `gateway.env`, och listan visar paret direkt, märkt "Godkänd efter prov". En modell som resonerar får bara användas för Lektioner, så den provas med ett enda lektionsanrop och går bara att välja där. Mistral står först i provlistan, och under varje par står vart Prova går och ungefär vad det kostar högst, med gatewayens priser eller panelens granskade priser från 2026-11-20: för Small 4 tre anrop, cirka 6 000 token och under en cent; för Large 4 ett anrop med plats för resonemang, cirka 13 500 token och upp till ungefär 2,6 cent.

Sidan visar också vilken uppgift som resonerar och på vilken nivå. Bara Lektioner får resonera, så en modell som resonerar (Large 4) går bara att välja för Lektioner. Kreditmätaren överst visar token och uppskattad kostnad den här månaden per uppgift och modell, ur gatewayens `/v2/status`, mot en kreditgräns du skriver in (standard $20). Den blir gul vid 80 % och röd vid 100 %. Gränsen sparas bara i panelen och skickas aldrig till gatewayen. En äldre gateway utan räknare visar ingen mätare.

Under Transkription ställer du in precision, förbehandling, talarmärkning och hur hårt egna ord ska väga, uppdaterar modellen och slår nattuppdateringen av eller på. Egna ord är en redigerare för ordlistan med räknare och varningar; Pianissimo startas om när du sparar. Orden lämnar aldrig datorn.

Tailscale och parning visar att `serve` skickar 443 till Pianissimo och 8443 till gatewayen, och rättar det med en knapp. Är funnel på visas en röd varning; panelen slår aldrig på funnel. Parningskoden ritas som QR-kod i fönstret och döljs efter en minut eller när fönstret tappar fokus. Där byter du också token, varefter telefonen måste paras om.

Uppdateringar visar vilka delar som ligger efter repot på GitHub och hur många systempaket som väntar. "Uppdatera allt" kör stegen i din standardterminal, där `sudo` frågar efter lösenordet, och stannar vid första fel. Varje installationsskript skriver vilken commit det installerade från, så en del som installerades före den här versionen står som okänd tills den installerats om en gång.

Verifiering kör samma kontroller som GitHub (`mio-verify verify`) och visar resultatet per kontroll. Loggarna hamnar i `~/.local/state/mio-control/verifiering`. Loggar visar journalen för gatewayen, Pianissimo och nattuppdateringen, med nivåfilter och följ-läge. Får ditt konto inte läsa systemets journal säger sidan hur du lägger till det i gruppen `systemd-journal`.

På Datorn kan panelen hålla datorn vaken så länge den kör, starta vid inloggning och klara sig utan ikon i systemfältet. Utan ikon öppnas fönstret direkt och panelen avslutas när du stänger det. Valen sparas i `~/.config/mio-control/installningar`.

Ikonens meny har Öppna, omstart av gatewayen och Pianissimo, Pausa AI på datorn (stoppar gatewayen), Visa parningskod och Avsluta. Pricken på ikonen är grön när allt kör, bärnstensfärgad när något startar, laddar eller inte är installerat eller när dagens kvot nästan är slut eller senaste säkerhetskopian är äldre än 48 timmar, och röd när en tjänst har stannat, gatewayen inte svarar eller Tailscale inte är inloggat. Stannar en tjänst, eller startar gatewayen eller Pianissimo fler än tre gånger på tio minuter, kommer också en skrivbordsnotis. Omstarterna räknas ur systemd:s rader i journalen, så de syns bara om ditt konto får läsa den (gruppen `systemd-journal`). Samma notis kommer högst en gång på tio minuter.

## Lösenord och rättigheter

Panelen kör som du. Det som skriver i `/etc`, styr tjänsterna eller läser hemligheter går genom rothjälparen via `pkexec`, med en fast lista av kommandon och inga sökvägar från panelen. KDE frågar efter lösenordet en gång och minns det några minuter. Parningskoden kräver alltid lösenord. Statusen som översikten läser var femte sekund kräver inget lösenord; hjälparen svarar då bara på `gateway` eller `pianissimo` och skickar tjänstens token bara till en port som tjänstens eget konto lyssnar på.

Nycklar och token visas aldrig i klartext, skrivs aldrig i en kommandorad eller logg och sparas inte av panelen.

## Avinstallera

```bash
sudo rm /usr/local/bin/mio-control /usr/share/polkit-1/actions/app.mio.control.policy \
    /usr/local/share/applications/app.mio.control.desktop \
    /usr/local/share/icons/hicolor/scalable/apps/app.mio.control.svg
sudo rm -r /usr/local/lib/mio-control
rm -f ~/.config/autostart/app.mio.control.desktop
rm -r ~/.config/mio-control ~/.local/state/mio-control
```

Gatewayen, Pianissimo och deras inställningar påverkas inte.

## Delar

| Mapp | Innehåll |
|---|---|
| `core/` | Allt utan grafik: env-filer, inställningarnas gränser, status, uppdateringar, journalen, guiden och hjälparens kommandolista |
| `helper/` | `mio-control-helper`, som körs som root via `pkexec` |
| `app/` | `mio-control`: fönstret, sidorna och ikonen i systemfältet |
| `polkit/`, `desktop/` | Polkit-regler, programmenyn, inloggningen och ikonen |

## Utveckla

```bash
cd control && cargo test --locked --workspace && cargo clippy --locked --workspace --all-targets -- -D warnings
cargo run -p mio-control -- --visa                      # öppna fönstret direkt
cargo run -p mio-control-core --example status_probe    # statusen utan fönster
```

Gränssnittstesterna kör de riktiga sidorna i ett fönster utan skärm med låtsade hjälpare, och ligger som moduler i ett enda testprogram (`app/tests/app/`), eftersom varje testprogram länkar hela GPUI. Grinden i `tools/` kör stegen `control-lint` och `control-tests`.

## Prov på datorn

Inget av detta är provat. Kör det på `cachyos-pc` och för in resultatet i [status](../docs/STATUS.md):

1. Fönstret ritas under KDE Plasma 6.8 Wayland med NVIDIA-drivrutinen, har rundade hörn, går att maximera och visa i helskärm och följer ljust och mörkt läge.
2. Panelen startar vid inloggning som bara en ikon. Pricken är grön när allt kör och blir röd när `mio-transcription` stoppas. Att stänga fönstret lämnar ikonen kvar.
3. KDE:s lösenordsruta kommer vid första skrivning och inte igen inom några minuter.
4. Byt modell, spara och se att telefonen fortsätter utan ny parning.
5. Lägg till ett eget ord och se antalet öka i Mio under Inställningar → Transkription.
6. Visa parningskoden och skanna den med telefonen.
7. "Uppdatera allt" på en dator där något ligger efter. Terminalen som är vald under Systeminställningar → Standardprogram öppnas (inte Konsole om du valt en annan), stannar vid ett fel och står kvar tills du trycker Enter.
8. "Håll datorn vaken" hindrar viloläge.
9. Loggar visar journalen utan lösenord, och Verifiering kör hela grinden på datorn.
10. Prova mot Mistral: lägg in Mistral-nyckeln under AI, tryck Prova på Mistral Small 4 och sedan Large 4. Kostnadsraden säger att anropen går till Mistral och kostar under en cent för Small 4 och högst cirka 2,6 cent för Large 4 (ett anrop), rapporten visar ett svar per uppgift som provades, och ett godkänt par blir valbart utan att panelen startas om (Large 4 bara för Lektioner). Kontrollera i Mistrals konsol att kostnaden blev ungefär den som stod.
11. Kreditmätaren: efter några anrop visar AI-sidan månadens token och kostnad per uppgift och modell. Skriv en gräns strax över kostnaden och se mätaren bli gul, sedan en under och se den bli röd. Starta om panelen och se att gränsen är kvar.
12. Skrivbordsnotisen: stoppa `mio-transcription` och se en notis om att Pianissimo har stannat. Starta om `mio-gateway` fyra gånger inom tio minuter (`sudo systemctl restart mio-gateway`) och se en notis om att den startar om gång på gång, och att den inte kommer igen vid en femte omstart.
13. Säkerhetskopian: låt telefonen ladda över natten med Mio installerat och parat. På morgonen visar kortet Säkerhetskopia på Översikt "i natt" med en tid, minst en kopia och en storlek, och `sudo ls -l /var/lib/mio-gateway/backups/` visar lika många filer. Att kortet och pricken blir gula efter 48 timmar utan kopia täcks av testerna.
