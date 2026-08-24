# Beslutslogg

Den här filen fångar beslut som nya Codex-tasks annars lätt skulle behöva gissa på.

## 2026-08-20 – Privat app

Mio byggs för en enda användare och ska inte publiceras i App Store i nuläget. En gratis personlig signering är tillräcklig under prototypfasen.

## 2026-08-20 – Native SwiftUI och iOS 26

Appen byggs i SwiftUI och använder Apples iOS 26-API:er. iPhone 13 med iOS 26 är den verkliga måltelefonen och facit för tillgänglighet och prestanda.

## 2026-08-20 – Lokal taligenkänning först

Heldagsljud ska inte skickas till OpenAI. Appen provar `SpeechTranscriber` och faller tillbaka till `DictationTranscriber` för svenska när det behövs.

Första enhetstestet visade att den avancerade svenska modellen inte kunde installeras (`transcription.sv`, status `Not Installing`). `DictationTranscriber` med `sv_SE` startade och fungerade. Arkitekturen ska därför behandla reservmotorn som den verifierade huvudvägen på den här telefonen tills ett senare test visar något annat.

## 2026-08-20 – Inget sparat råljud

Rått mikrofonljud får bearbetas tillfälligt i minnet men sparas inte som ljudfil. Fas 1 sparar enbart text, tidsdata, batteriprover och diagnostik.

## 2026-08-20 – Molnbygge på grund av Monterey

Utvecklings-Macen kan inte köra Xcode 26. GitHub Actions på `macos-26` är därför den auktoritativa byggmiljön och producerar en osignerad IPA.

## 2026-08-20 – SideStore för privat installation

SideStore med iLoader och LocalDevVPN används för personlig signering, installation och sjudagarsförnyelse. AltStore-flödet övergavs efter återkommande iCloud-komponentfel på Windows.

## 2026-08-20 – OpenAI endast efter uttryckligt Ja

OpenAI läggs till först efter att den lokala grunden är bevisad. API-nyckeln ska ligga på en server, aldrig i appen. En fråga skickas endast efter att användaren sett flödet och aktivt valt **Ja**.

## 2026-08-20 – En enkel Git-rutin

`main` används direkt så länge projektet har en aktiv utvecklare och förändringarna är små. Codex ändrar lokala filer; GitHub Desktop används för granskning, commit och push. Brancher införs först när parallella eller riskfyllda ändringar gör dem motiverade.

## 2026-08-20 – Testexporter stannar utanför repot

Exporterade Mio-sessioner kan innehålla privat tal och ska aldrig checkas in, inte ens i ett privat repository. Endast avidentifierade slutsatser och mätvärden dokumenteras i `docs/TESTRESULTAT_FAS_1.md`.

## 2026-08-24 – Fas 2 startar parallellt med öppna fas 1-prov

Den lokala, manuella MVP:n i fas 2 får utvecklas innan fas 1:s långa bakgrunds-, batteri-, avbrotts- och kvalitetstest är klara. De manuella funktionerna behöver inte anta att heldagslyssningen fungerar. Fas 1 förblir därför uttryckligen kortverifierad och dess beslutspunkt för heldagslyssning kvarstår.

Implementation, Xcode-kompilering, GitHub Actions-build, installation och telefonresultat ska rapporteras som separata verifieringsnivåer. Det tidigare telefonprovet får inte användas som bevis för en ny fas 2-revision.

## 2026-08-24 – Fas 2-data lagras separat och versionsmärkt

Manuellt innehåll lagras i `MioPhaseTwo/content-v1.json` med `schemaVersion: 1`. De befintliga sessionerna ligger kvar i `MioPhaseOne/sessions.json` och migreras inte automatiskt till manuella poster. En manuell post kan ha en valfri `sessionID`-relation till en session.

De fem gemensamma typerna är tidslinjepost, anteckning, uppgift, plan och uttryckligt minne. En plan är lokal och ett uttryckligt minne skapas manuellt; inget av dem skrivs till en extern tjänst.

En okänd innehållsschemaversion ska ge ett synligt fel och får inte tyst skrivas över. Den gemensamma exporten är också versionsmärkt och innehåller manuellt innehåll och sessioner, men aldrig råljud.

## 2026-08-24 – Sessionsredigering är ett bevarande lager

Fas 2 får lägga till titel och manuell anteckning på en avslutad session samt en rättad visningstext på ett transkriptionssegment. Originaltext, originalets ljudtider, Mio-detektion, bakgrundsbevis och övrig diagnostik ska förbli oförändrade och finnas kvar i exporten. Det gör manuella rättningar möjliga utan att skriva om tekniskt testbevis.

## 2026-08-24 – Den avancerade svenska modellen kräver installerad status

`SpeechTranscriber` får väljas först när `AssetInventory` rapporterar att den svenska asseten är installerad. Appen visar assetstatus, reserverar svenska explicit, erbjuder en separat installationsåtgärd och kontrollerar slutstatus före användning. Om installationen inte är klar används den lokala `DictationTranscriber`-fallbacken.

Detta är ett arkitekturbeslut, inte ett nytt telefonresultat. Både installation och fallback ska verifieras på iPhone 13.

## 2026-08-24 – Inga externa integrationer i fas 2

Fas 2 gör inga OpenAI-anrop, använder inte EventKit och skapar inga systemalarm. Kalenderfliken visar endast lokala planer och Morgon är en lokal vy. OpenAI hör tidigast till fas 5 och kräver ett separat server-, samtyckes- och kostnadsbeslut.
