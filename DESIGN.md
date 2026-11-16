---
name: Mio
description: Svensk veckoalmanacka för en privat vardagsassistent – grafitgrå mark med mjukt ljus, kort i Liquid Glass, en blå ton för kontroller.
colors:
  blue-tint: "#0A6CF0"
  blue-tint-dark: "#2E84FF"
  graphite-ground: "#F1F2F4"
  night-graphite-ground: "#0D0E10"
  paper-surface: "#FFFFFF"
  slate-surface: "#1B1C1F"
  mist-ribbon: "#E3E5E9"
  slate-ribbon: "#2A2C31"
typography:
  display:
    fontFamily: "SF Pro Display"
    fontSize: "34pt (largeTitle, skalas med Dynamic Type)"
    fontWeight: 700
    lineHeight: "41pt"
  headline:
    fontFamily: "SF Pro Text"
    fontSize: "20pt (title3)"
    fontWeight: 600
    lineHeight: "25pt"
  title:
    fontFamily: "SF Pro Text"
    fontSize: "17pt (headline)"
    fontWeight: 600
    lineHeight: "22pt"
  body:
    fontFamily: "SF Pro Text"
    fontSize: "17pt (body)"
    fontWeight: 400
    lineHeight: "22pt"
  body-secondary:
    fontFamily: "SF Pro Text"
    fontSize: "15pt (subheadline)"
    fontWeight: 400
    lineHeight: "20pt"
  label:
    fontFamily: "SF Pro Text"
    fontSize: "12pt (caption)"
    fontWeight: 600
    lineHeight: "16pt"
  day-numeral:
    fontFamily: "SF Pro Rounded"
    fontSize: "20pt (title3)"
    fontWeight: 500
    lineHeight: "25pt"
    fontFeature: "tnum"
rounded:
  streak-cell: "4pt"
  day-cell: "14pt"
  panel: "22pt"
  chip: "18pt"
  capsule: "9999pt"
spacing:
  hairline: "3pt"
  grid: "4pt"
  ribbon: "6pt"
  stack: "12pt"
  page: "14pt"
  panel: "16pt"
  page-bottom: "24pt"
  touch: "44pt"
  content-max: "680pt"
components:
  panel:
    material: "Liquid Glass (regular)"
    fallback: "{colors.paper-surface}"
    rounded: "{rounded.panel}"
    padding: "16pt"
  reading-surface:
    backgroundColor: "{colors.paper-surface}"
    rounded: "{rounded.panel}"
    padding: "16pt"
  reading-surface-dark:
    backgroundColor: "{colors.slate-surface}"
    rounded: "{rounded.panel}"
    padding: "16pt"
  status-chip:
    material: "Liquid Glass (regular)"
    rounded: "{rounded.chip}"
    height: "44pt"
    padding: "10pt 14pt"
  section-title:
    typography: "{typography.headline}"
  day-cell:
    rounded: "{rounded.day-cell}"
    typography: "{typography.day-numeral}"
    height: "76pt"
  day-cell-today:
    textColor: "{colors.blue-tint}"
    rounded: "{rounded.day-cell}"
    height: "76pt"
  day-cell-selected:
    backgroundColor: "#0A6CF029"
    textColor: "{colors.blue-tint}"
    rounded: "{rounded.day-cell}"
    height: "76pt"
  streak-cell:
    backgroundColor: "{colors.mist-ribbon}"
    rounded: "{rounded.streak-cell}"
  button-primary:
    backgroundColor: "{colors.blue-tint}"
    textColor: "{colors.paper-surface}"
    typography: "{typography.title}"
    rounded: "{rounded.capsule}"
    padding: "6pt 0"
  button-secondary:
    textColor: "{colors.blue-tint}"
    rounded: "{rounded.capsule}"
  item-row:
    typography: "{typography.body}"
    height: "44pt"
  listening-bar:
    typography: "{typography.body-secondary}"
    padding: "0 14pt"
---

# Design System: Mio

## Overview

**Creative North Star: "Almanackan med veckonummer"**

Mio ser ut som en svensk veckoalmanacka, inte som en widgetpanel. Veckonumret ("v. 41") är sidans största text, och de sju dagarna Mån–Sön organiserar allt under det: nästa sak, det som väntar på granskning, dagens morgon- eller kvällsöversikt och tolv veckors användning. Ingen hjältekort-över-rutnät-uppställning; ordningen är almanackans.

Världen är grafitgrå och blå (vald 2026-11-15, ersätter den violetta): en neutral mark, nästan vit i ljust läge och nästan svart i mörkt, med två mycket mjuka ljus bakom innehållet så att glaset har något att bryta. Kort för sammanfattning och status är Liquid Glass. En enda klar blå ton bär kontroller, markeringar och framsteg; i övrigt är bilden svartvit, i stil med MacroFactor. Text som läses länge – transkript, lektionsanteckningar och listor – ligger på vanliga, ogenomskinliga ytor. Typografin är Apples egen: SF Pro i textstilar som skalas med Dynamic Type, och SF Rounded för datumsiffrorna i veckoraden, så att de känns som en almanacka.

Tätheten är låg och lugn: få val per vy, korta svenska rader, framsteg som syns utan att skuldbelägga. Lyssnandet är diskret i rummet – en liten prick och ett ord, inget rött, ingen vågform. Allt som rör datorn, transkriptionen och AI ställs in på ett enda ställe, inställningsarket; övriga skärmar visar bara en liten statusbricka som öppnar det.

**Key Characteristics:**
- Veckonummer som systemets stora titel; datum och sju dagceller direkt under.
- Grafitgrå mark med mjukt ljus, glaskort med 22 pt kontinuerliga hörn, inga skuggor.
- En blå ton för allt interaktivt; tillståndsfärger bara för luckor, varningar och fel.
- Glas på kontroller, navigering och kort för sammanfattning och status; långa lästexter är alltid ogenomskinliga.
- Ett inställningsark med en kort lista; statusbrickor i stället för inställningar utspridda i appen.
- Allt skalas med Dynamic Type och byter layout vid tillgänglighetsstorlekar i stället för att klippa.

## Colors

En svartvit värld med en accent: mark, yta och band är neutrala grafittoner, och den blå tonen är den enda mättade färgen. Varje token finns i ett ljust och ett mörkt utförande (asset-katalogens `Any`/`Dark`), så paren nedan är samma roll i två lägen.

### Primary
- **Almanacksblå** (`blue-tint` / `blue-tint-dark`): appens `AccentColor` och `MioTheme.tint`. Driver flikfältets markering, knappar, ikoner i rader, dagens ring, vald dag (16 % fyllning), aktivitetsprickar, strecknätets fyllnadsgrader, statusbrickans prick och lyssningsprickens "lyssnar"-läge. Den mörka varianten är ljusare så att den håller kontrast mot nattgrafit.

### Neutral
- **Grafitmark** (`graphite-ground`) / **Nattgrafit** (`night-graphite-ground`): `MioGround`, basen i `MioBackdrop`, som ligger bakom varje skrollvy (`mioGround()`) och bakom listor och formulär (`mioListGround()`, som döljer listans egen bakgrund). Ovanpå basen ligger två stilla radiella ljus: tonen på 6 % (12 % i mörkt läge) uppe till vänster och primärfärgen på 5 % (8 %) nere till höger.
- **Papper** (`paper-surface`) / **Skiffer** (`slate-surface`): `MioSurface`, läsytan (`mioReadingSurface()`) för transkript och annan lång text, och glaskortens ersättning när Reduce Transparency är på.
- **Dimband** (`mist-ribbon`) / **Skifferband** (`slate-ribbon`): `MioRibbon`, tomma och framtida rutor i strecknätet (framtida rutor med 45 % opacitet).
- **Systemets semantiska textfärger** (`.primary`, `.secondary`, `.tertiary`): all text. Inga egna gråtoner.

### Named Rules
**The One Tint Rule.** Allt som går att trycka på eller som visar framsteg använder `MioTheme.tint`. Ingen andra accentfärg införs, och ingen violett.

**The State Colours Rule.** Systemets orange betyder avbrott eller varning (avbrutet lyssnande, pausgräns, en statusbricka som behöver åtgärd), rött betyder fel eller att stänga av, grönt betyder klart eller godkänt. De används bara för just de tillstånden, aldrig som dekor.

## Typography

**Display Font:** SF Pro (systemets stora navigeringstitel)
**Body Font:** SF Pro Text (systemfonten via textstilar)

**Character:** Apples egna textstilar för all läsning, med SF Rounded reserverat för veckoradens datumsiffror. Rundningen ger datumen en mjuk, tryckt-kalender-känsla utan att införa en främmande font.

### Hierarchy
- **Display** (bold, 34 pt largeTitle): navigeringens stora systemtitel, främst "v. 41" på Hem. Den skalas med Dynamic Type; en UIKit-ändring till SF Rounded prövades och togs bort, eftersom den inte slog igenom och kunde störa accentfärgen.
- **Headline** (semibold, title3): `MioSectionTitle` ovanför paneler ("Nästa", "I dag", "Tolv veckor"), markerad som rubrik för VoiceOver.
- **Title** (semibold, headline): radens huvudtext i paneler ("3 att granska", "dagar med Mio"), datumraden under titeln (i sekundär färg) och knappetiketter.
- **Body** (regular/medium, body): radtitlar (`MioItemRow`, medium), tomlägesrader (sekundär färg).
- **Body secondary** (regular, subheadline): tider, statusrader, metadata; gruppetiketter i översikten i semibold sekundär.
- **Label** (semibold, caption): veckodagsbokstaven i dagcellen (M T O T F L S) och veckoetiketterna under strecknätet (regular).
- **Day numeral** (medium, title3, rundad, tabellsiffror): datumsiffran i dagcellen; bold för i dag.

### Named Rules
**The Rounded Numerals Rule.** SF Rounded används för veckoradens datumsiffror och inte för brödtext eller rubriker.

**The Text Style Rule.** Storlekar anges som textstilar (`.title3`, `.subheadline` …), aldrig som fasta punktvärden, så att Dynamic Type når de största storlekarna.

## Layout

Hem är en enkel vertikal stapel (14 pt mellan block) inuti en skrollvy, centrerad med högst 680 pt bredd, systemets horisontella marginal och 24 pt luft i botten. Ordningen är fast: datumrad med veckopilar, veckobandet, eventuella fel, "Nästa" (bara när i dag är vald), granskningsraden, AI-status, dagens översikt och sist "Tolv veckor".

Veckobandet är sju lika breda celler med 6 pt mellanrum. Vid tillgänglighetsstorlekar blir det ett rutnät med fyra kolumner (två rader) så att alla dagar och dagens ring syns utan dold skrollning. Samma princip gäller statusrader och översiktens rubrik: vid tillgänglighetsstorlekar staplas knapp och segmentväljare under texten i stället för bredvid.

Veckobandet ligger i en egen glasremsa med 6 pt inre marginal. Paneler har 16 pt inre marginal och 12 pt mellan innehåll. Rader har minst 44 pt höjd, ikonkolumnen är 28 pt bred och varje fristående ikonknapp får en träffyta på minst 44 × 44 pt. Strecknätet är 12 kolumner × 7 rader (måndag överst) med 4 pt mellanrum och kvadratiska celler. Övriga flikar är `insetGrouped`-listor på grafitmarken. På Fånga ligger två statusbrickor (Transkription och AI) bredvid varandra, staplade vid tillgänglighetsstorlekar.

Skalet är en `TabView` med tre flikar (Hem, Lektioner, Förslag; Kalender och Anteckningar togs bort i 0.9.1) och Fånga som den separata runda knappen längst ut i flikfältet (`role: .search`). Flikfältet krymper vid skroll nedåt. Inställningar öppnas som ett vanligt ark i full höjd (`MioSettingsScreen`) med en kort lista: Dator (Parning, Transkription, AI), Mio (Notiser, vibrationer, guide), Integritet och data, Om. Varje rad visar sitt läge till höger och leder till en egen sida.

## Elevation & Depth

Mio har inga skuggor. Djup skapas av marken med sitt mjuka ljus och av systemets Liquid Glass ovanpå. Glas finns på flikfältet, Fånga-knappen, lyssningsfältet (`tabViewBottomAccessory`), knappar med `.glass`/`.glassProminent`, och från 2026-11-15 på kort för sammanfattning och status: `MioPanel` på Hem, veckobandets remsa, korten på Fånga och statusbrickorna (`mioGlass()`, `glassEffect(.regular)` i en kontinuerligt rundad rektangel). Med Reduce Transparency ersätts glaset av `MioSurface`.

### Named Rules
**The Glass-for-Glances Rule.** Glas hör till kontroller, navigering och det man ser med en blick: status, nästa sak, antal, framsteg. Text som läses länge – transkript, lektionsanteckningar, tidsstämplad text, händelseloggar och listrader – ligger alltid på en ogenomskinlig läsyta (`mioReadingSurface()` eller listans grupperade rader).

**The No-Shadow Rule.** Ingen skugga, ingen kant, ingen gloria. Glas och ton räcker.

## Shapes

Formspråket är kontinuerliga rundade rektanglar (`style: .continuous`) i fyra storlekar som följer elementets skala: 4 pt för strecknätets små rutor, 14 pt för dagceller, 18 pt för statusbrickor och 22 pt för paneler (`MioTheme.panelRadius`). Knappar är kapslar (`buttonBorderShape(.capsule)`). Aktivitetsprickarna är 5 pt kapslar, tre per dag. Dagens ring är en 2 pt kontur i tonen (1,5 pt i strecknätet). Inga andra kanter eller avdelare förutom systemets `Divider` inne i en panel.

## Components

### Buttons
- **Shape:** kapsel.
- **Primär:** `.glassProminent` i tonen, `controlSize(.large)`, etikett i headline, full bredd med 6 pt extra vertikal luft ("Starta Mio", "Para"). En primär knapp per panel. På Fånga får "Stäng av Mio" samma form i rött.
- **Sekundär:** `.bordered` kapsel i tonen för små åtgärder bredvid text ("I dag", "Para", "Slå på").
- **Ikonknappar:** SF Symbols i tonen med 44 × 44 pt träffyta (veckopilar, bocka av uppgift, paus/fortsätt).

### Cards / Containers
- **Corner Style:** 22 pt kontinuerligt.
- **Material:** Liquid Glass (`mioGlass()`); `MioSurface` med Reduce Transparency.
- **Shadow Strategy:** ingen; se Elevation & Depth.
- **Border:** ingen.
- **Internal Padding:** 16 pt, 12 pt mellan innehåll.
- `MioPanel` är kortet på Hem. Granskningsraden är en hel panel som länk (ikon i tonen, "3 att granska" i headline, "sparade till senare" i sekundär färg, avslutande chevron i tertiär färg).
- På Fånga är `Card` glas för status, mätningar och hjälp, och läsyta (`reading: true`) för Live-test, Tidsstämplad text och Händelselogg.

### Statusbricka (`MioStatusChip`)
En glasbricka med 18 pt hörn och minst 44 pt höjd: en 8 pt prick (ton = fungerar, sekundär = av eller ej kontrollerad, orange = behöver åtgärd), en liten etikett ("Transkription", "AI") och läget i subheadline medium ("Ansluten", "På", "Fortsätter kl. 14.05"). Ett tryck öppnar inställningsarket. Brickorna ersätter de tidigare statuskorten på Fånga. Bredvid AI-brickan ligger en rund glasknapp (paus/spela) som pausar och slår på AI med ett tryck; det är samma sparade val som under Inställningar → AI (användarens val 2026-11-16).

### Navigation
- Systemets `TabView` med SF Symbols och tonen som markering; Fånga som femte flik med sökrollen; systemet avgör om den visas som separat rund knapp (i simulatorn för iOS 27 hamnade den i raden). Stora navigeringstitlar i systemets stil. Verktygsfältet bär "Fråga Mio" till vänster och inställningar till höger.

### Veckoband (signaturkomponent)
Sju `MioDayCell` med måndag först. Varje cell: veckodagsbokstav (caption semibold, versal, sekundär – tonen när dagen är vald), datumsiffra (title3 rundad, tabellsiffror, sekundär för framtida dagar), och tre 5 pt prickar som fylls i tonen efter aktivitetsnivå 0–3 (ofyllda med 18 % ton). Minsta höjd 76 pt. I dag har 2 pt ring i tonen; vald dag fylls med tonen på 16 %. Hela cellen är en knapp med ett samlat VoiceOver-namn ("söndag 11 oktober, i dag, 3 saker").

### Tolv veckor (signaturkomponent)
Strecknät i en panel: rubriken "N dagar med Mio" i headline, "N i rad" i tonen när sviten är längre än en dag, 12 × 7 kvadratiska rutor (4 pt hörn) och veckonummer för första och sista kolumnen i caption. Fyllnad: band för noll, ton på 40 %, 70 % och 100 % för nivå 1–3, band på 45 % för framtida dagar; i dag ringas med 1,5 pt. Ingen skam: en tom dag är bara ljusare.

### Rad (`MioItemRow`)
Typens SF Symbol i tonen i en 28 pt kolumn, titel i body medium (genomstruken och sekundär när uppgiften är klar), tid i subheadline sekundär med svenska tidsfraser ("kl. 13.40", "i går kl. 9.00"), valfri avslutande kontroll. Minst 44 pt hög.

### Lyssningsfält
Medvetet diskret: 8 pt prick (ton när den lyssnar, orange vid avbrott, annars sekundär), ett ord i subheadline medium ("Lyssnar", "Lektion", "Pausad"), en timer i tabellsiffror när det finns plats, och paus/fortsätt som ikonknapp. Ligger i flikfältets glastillbehör; trycket öppnar Fånga.

## Do's and Don'ts

### Do:
- **Do** lägg varje ny skärm på `mioGround()` eller `mioListGround()`, sammanfattning och status i `MioPanel`/`mioGlass()` och lång lästext på `mioReadingSurface()` eller i vanliga grupperade rader.
- **Do** använd `MioTheme.tint` för allt interaktivt och för framsteg; låt systemets semantiska färger bära texten.
- **Do** använd kontinuerliga hörn i skalan 4 / 14 / 18 / 22 pt och kapslar för knappar.
- **Do** lägg nya inställningar i inställningsarket och visa på sin höjd en statusbricka på andra skärmar. Enda undantaget är snabbpausen för AI på Fånga.
- **Do** ange typografi som textstilar och testa i den största tillgänglighetsstorleken; stapla eller bryt till rutnät hellre än att klippa eller dölja i skroll.
- **Do** ge varje ikonknapp minst 44 × 44 pt träffyta och ett svenskt tillgänglighetsnamn.
- **Do** visa en enda primär åtgärd per panel.

### Don't:
- **Don't** lägg Liquid Glass eller material på transkript, lektionsanteckningar eller listrader, och inga skuggor någonstans.
- **Don't** inför en andra accentfärg, violett eller lila toner eller färgade övertoningar i AI-stil, och använd inte orange, rött eller grönt för annat än varning, fel och klart.
- **Don't** gör lyssningsfältet iögonfallande: inget rött, ingen vågform, ingen pulserande animation där.
- **Don't** använd SF Rounded för brödtext eller rubriker; den hör till veckoradens datumsiffror.
- **Don't** ange fasta punktstorlekar för text som ska skalas med Dynamic Type.
