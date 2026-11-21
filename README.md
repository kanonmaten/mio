# Mio

Mio är en privat iPhone-app för iOS 27 som lyssnar när du ber den, skriver ut vad som sägs och hjälper dig att hålla ordning på lektioner, läxor, prov och vardagens små saker. Talet skrivs ut av Pianissimo på en egen dator med grafikkort, och AI-delen går via en gateway på samma dator. Inget ljud sparas, och appen finns inte i App Store; den installeras med SideStore.

Aktuell version är 0.10.0. Den är byggd och testad i simulatorn men inte släppt och inte provad på telefonen. Den hette 0.9.1 fram till 2026-11-21 ([versioner](docs/DECISIONS.md#en-version-för-hela-repot-2026-11-21)). [Status](docs/STATUS.md) visar exakt vad som är kontrollerat och på vilken commit.

## Vad Mio gör

- Fånga skriver ut tal via Tailscale till Pianissimo på datorn. Mikrofonen startar om efter ett samtal eller annat avbrott, men aldrig efter att du själv pausat eller stoppat. Nekar iOS omstarten får du notisen "Tryck för att fortsätta lyssna" eller trycker Fortsätt i Fånga ([användarguiden](docs/ANVANDNING.md)).
- Lektioner är ett eget läge. Efter lektionen skriver AI en anteckning, föreslår ämne och läxor och öppnar ett granskningsark. Pekade läraren ut något till provet finns det överst i avsnittet "Viktigt till provet" med ett citat per punkt; annars saknas avsnittet.
- Förslag samlar det AI hittat i vardagen. Inget sparas förrän du säger Ja. En att göra-post hamnar då i Påminnelser och en anteckning i Anteckningar via dela-arket; en kalenderhändelse öppnar Kalenders ruta, och den sparas först när du trycker Lägg till där. "Mio, kom ihåg …" sparas direkt i Påminnelser och "Mio, notera …" som en Mio-anteckning, och båda kan ångras i 24 timmar. Säger du både en tid och en plats blir det i stället ett kalenderförslag under Förslag, som du bekräftar i Kalenders ruta.
- Hem visar veckan, nästa sak att göra och nedräkning till prov.
- Inställningarna ligger i ett enda ark. "Kontrollera allt" visar vad som fungerar och vad du behöver göra annars.
- Säkerhetskopian: när telefonen laddar skickar Mio sin export via Tailscale till datorn, som krypterar den och sparar de 14 senaste. iOS bestämmer när det blir av, oftast på natten, och det kräver nät och en gateway som installerats om; Mio Kontroll visar den senaste kopian, och under Inställningar → Säkerhetskopia finns "Säkerhetskopiera nu".

[Användarguiden](docs/ANVANDNING.md) går igenom flödet steg för steg, och [ändringsloggen](CHANGELOG.md) beskriver varje ändring.

## Delarna

| Del | Var | Guide |
|---|---|---|
| iPhone-appen och widgetarna | `Mio/`, `MioWidgets/` | [Installation](docs/INSTALLATION.md) |
| Pianissimo, transkriptionen på datorns GPU | `transcription-server/` | [Pianissimo](transcription-server/README.md) |
| AI-gatewayen på datorn (Mistral, Groq eller Anthropic) | `server/` | [Gatewayen](server/README.md) |
| Mio Kontroll, kontrollpanelen på datorn | `control/` | [Mio Kontroll](control/README.md) |
| Verifieraren som CI och pre-push-kroken kör | `tools/` | [Utveckling](#utveckling) |

## Kom igång

Gör stegen i den här ordningen. Skripten på datorn körs som din vanliga användare, inte med `sudo`.

1. Installera Pianissimo på datorn med `transcription-server/install.sh`. Första gången tar det ungefär en halvtimme. Säger skriptet att Tailscale inte är inloggat på datorn, gör [steg 2 i Pianissimo-guiden](transcription-server/README.md#2-tailscale) (logga in och `tailscale serve`) innan du går vidare.
2. Installera AI-gatewayen med `./server/install.sh`. Skriptet frågar efter en Mistral-nyckel och provar den med ett kort påhittat anrop.
3. Installera Tailscale på telefonen, logga in med samma konto som på datorn och slå på VPN On Demand.
4. Installera Mio på telefonen enligt [installationen](docs/INSTALLATION.md).
5. Kör `mio-pair` på datorn och skanna QR-koden i Mio under Inställningar → Parning.

[Mio Kontroll](control/README.md) kan göra steg 1, 2 och 5 åt dig och sedan visa och styra allt som kör på datorn. Installera den med `./control/install.sh`. Den är inte provad på datorn än.

`mio-pair` hämtar nycklar från båda installationerna, så kör den när steg 1 och 2 är klara. Utan Pianissimo får koden bara med AI; installera då Pianissimo, kör `mio-pair` igen och para om i Mio.

## Integritet

Lyssningen startas av dig. Ljudet skickas till din egen dator och ligger högst 60 sekunder i telefonens minne, aldrig i en fil. Rättelser och talarnamn läggs ovanpå transkriptet; originaltexten och tiderna ändras aldrig. När AI är på skickas text via din dator till den leverantör du valt i Mio Kontroll, och förslag sparas först efter ditt Ja. Det du skickar till Kalender, Påminnelser och Anteckningar synkas via ditt Apple-konto. Spela bara in andra med deras samtycke.

Data ligger i SwiftData (`Mio/store/Mio.store`) under appidentiteten `app.mio.assistant`. Exporten är versionerad JSON och kan innehålla känslig text, så förvara den utanför repot. [Datamodellen](docs/DATAMODELL.md) beskriver lagring, export och återställning.

## Utveckling

Planerat arbete, fel och prov är ärenden i [Linear](https://linear.app/kanonmaten). Varje ändring görs på en egen gren och går via en pull request som CI och CodeRabbit granskar innan den slås ihop till `main`. [CLAUDE.md](CLAUDE.md) har reglerna för Claude Code, och [besluten](docs/DECISIONS.md) förklarar varför saker är som de är.

Linux kan inte bygga iOS-appen. Den gemensamma grinden körs från repots rot:

```sh
cargo run --locked --manifest-path tools/Cargo.toml -- verify
```

Slå på pre-push-kroken en gång per arbetskopia, så körs samma grind före varje push:

```sh
git config core.hooksPath .githooks
```

Kroken stoppar pushen om `verify` misslyckas eller om det finns ändringar som inte är committade, och hoppar över `verify` när bara Markdown ändrats.

På GitHub kör **Verifiera Mio på Linux** samma grind för varje pull request och push till `main`. **Bygg Mio IPA** bygger appen på macOS, kör enhetstesterna och gör en osignerad IPA när en ändring rör appen; UI-tester och strikt concurrency-diagnostik körs varje natt och på `v*`-taggar. [Installationen](docs/INSTALLATION.md#verifiera-före-bygge) beskriver vad grindarna täcker och inte täcker.

Versionen står i `VERSION` och gäller hela repot. Allt annat om projektet finns i [docs](docs/README.md).
