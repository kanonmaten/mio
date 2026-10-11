---
version: 1
slug: "mio-contentview-swift"
primary_target: "Mio/ContentView.swift"
related_targets: []
---

# Hem and app shell

## Direction contract

THESIS: Mio's home is a Swedish week planner, not a widget dashboard. The week number and the seven days organise everything; the category default of a hero card over a 2x2 tile grid is refused as the page's organisation.

OWN-WORLD: Violet tinted ground (deep violet in dark, pale lilac in light) with plain reading surfaces. One saturated violet tint drives controls. Liquid Glass only on tab bar, mic button, listening bar and settings panel. SF Pro text styles; the week number set large in SF Rounded semibold. Day cells as rounded squares; today ringed in the tint. State colours only for gaps and quota.

STORY: The user glances, sees which week and day it is, the one next thing, and how many items wait for review, then acts once and leaves.

FIRST VIEWPORT: Large title "v. 41" with weekday and date beneath. A seven-day ribbon (Mån–Sön) under it, each day showing fill from captured and reviewed items, today ringed. Below: one "Nästa" row with its single action, then "3 att granska". The 12-week streak grid closes the screen. The mic button floats bottom-right above the tab bar.

FORM: Almanackan med veckonummer, candidate 5 of 7; seed key 24ef0953 (degraded roll, no challengers).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
