---
title: "Mio Kontroll opens whatever terminal is set as default, never one named in the code"
author: Kanonmaten
date: 2026-11-22
branch: mio-32-default-terminal
cost: { minutes: 10, tokens: 119679 }
id: l-50a3b8ca
scope: repo
status: active
src: agent
touches:
  - CHANGELOG.md
  - control/README.md
  - control/app/src/setup.rs
  - control/app/src/updates.rs
  - control/app/tests/app/setup_computer.rs
  - control/app/tests/app/updates.rs
  - control/core/src/lib.rs
  - control/core/src/terminal.rs
  - control/core/src/updates.rs
  - docs/DECISIONS.md
---

## Decided
The user's rule (2026-11-22): everything Mio Kontroll runs in a terminal goes to the default terminal, not Konsole or any other named one. On KDE Plasma that is the entry chosen under Systeminställningar → Standardprogram; elsewhere xdg-terminal-exec decides. The script waits for Enter itself so the window stays open in any terminal.

## Tried and ruled out
- Hardcoding Ghostty (first commit of the PR): the user asked why it is tied to one terminal at all.
- xdg-terminal-exec alone on KDE: it does not read Plasma's setting, only its own xdg-terminals.list files (none exist here), and otherwise falls back to any terminal entry, possibly Konsole.
- KDE's TerminalApplication (a command line) instead of TerminalService: Ghostty's is `ghostty --gtk-single-instance=true`, and it gives no desktop entry to read the exec argument from.
- A terminal "hold" flag: named differently in each terminal (--hold, --wait-after-command), missing in some.

## Watch out
- Ghostty with --gtk-single-instance=true plus -e still runs the command (tested on the PC), but in the already-running instance's configuration.
- Launching from the panel itself is untested until `./control/install.sh` is rerun.

In the code: control/core/src/terminal.rs (`launch`, `resolve`, `entry_command`, `parse_exec`), the EXIT trap in `script` in control/core/src/updates.rs, the launcher in `UpdateBackend::system` in control/app/src/updates.rs; decision in docs/DECISIONS.md "Mio Kontroll använder standardterminalen".
