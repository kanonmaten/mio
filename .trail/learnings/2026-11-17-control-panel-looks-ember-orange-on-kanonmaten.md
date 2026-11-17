---
title: "Control panel looks ember orange on graphite, follows KDE light/dark, and lives in the tray"
author: Kanonmaten
date: 2026-11-17
branch: worktree-kontrollpanel-plan
cost: { minutes: 8, tokens: 87413 }
id: l-7c52c1b7
scope: repo
status: active
src: agent
touches:
  - docs/PLAN_KONTROLLPANEL.md
  - docs/ROADMAP.md
  - CHANGELOG.md
  - docs/DECISIONS.md
  - docs/STATUS.md
  - transcription-server/API.md
  - transcription-server/README.md
  - transcription-server/mio_transcription/backend.py
  - transcription-server/tests/test_precision.py
  - transcription-server/mio_transcription/app.py
---

## Decided
User's choices 2026-11-17 for the PC control panel (GPUI, KDE Plasma 6.8):
- Accent is ember orange #F0702E on graphite (#1C1B1A ground, #262423 surface). OK #6BBF59, warning #E8B93C, error #E5484D. Pure red is used only for errors. Never blue or violet in the panel.
- The theme follows KDE's light/dark setting. The light variant isn't designed yet.
- Rounded corners. Starts at login as a tray icon only; clicking opens a small window (~720x520) that can be resized, maximized and made fullscreen. Closing the window keeps the tray icon; Quit is in the tray menu.
- Tray icon is a Mio mark with a green/amber/red status dot; the tooltip lists each service.

## Tried and ruled out
- Red-orange accent (#E5533A): too close to error red, so errors would blend in with buttons.
- Orange-to-red gradient title bar: more decoration than wanted.
- Following KDE's accent color, and a dark-only theme.
- Normal app that quits when the window closes; a status popup next to the tray (placement on KDE Wayland is unverified).

## Watch out
- Rounded corners need the app's own title bar under KWin; unverified on the PC.
- Status must show an icon or text next to the color, not color alone.

In the code:
- docs/PLAN_KONTROLLPANEL.md, section "Utseende och fönster"; theme name "Mio glöd"; tray via the ksni crate.
