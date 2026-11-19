---
title: "Grilling 2026-11-19: Mistral Small 4 for everyday, Large 4 with medium reasoning for lessons, plus app decisions for a non-technical high-school user"
author: Kanonmaten
date: 2026-11-19
branch: main
cost: { minutes: 1, tokens: 3860 }
id: l-8135f6ae
scope: repo
status: active
src: agent
touches:
  - CLAUDE.md
  - server/src/model_profiles.rs
---

## Decided
The user's answers in a grilling session on 2026-11-19. Mio's real end user is the user's girlfriend, a high-school student who isn't very technical.
- AI: the user has three months of Mistral Pro (about $15/month in API credits according to the pricing page). Mistral becomes the default in install.sh, and Groq qwen stays reviewed and selectable. Candidates: everyday + ask on mistral-small-2603 with reasoning_effort "none"; lesson on Mistral Large 4 with reasoning_effort "medium". Rule change approved for the lesson task only: it may reason. The thinking chunks are thrown away in the gateway and never stored or shown; strict schema and validation still apply. The user runs Prova in Mio Kontroll themselves (no real traffic from Claude).
- Kontroll: a credit meter (tokens and cost per task this month, from usage in each response), the Mistral candidates at the top ready for Prova, and an alert when a PC service stops.
- App: exam hints get their own section first in the lesson notes ("Viktigt till provet", with quotes). The homework date is set at Yes. Lesson-end suggestions are shown straight away in a sheet. A calm view during lessons. The speaker who talks most is shown as "Lärare". A corrected word is offered as a custom word (sent to the PC on Yes). Everyday transcripts are kept 30 days. Low battery pauses everyday capture but NEVER a lesson, and she can always start again. After long silence Mio asks whether to keep listening. Only a direct "Mio, kom ihåg/notera" vibrates; picked-up suggestions wait silently. A direct instruction counts as Yes (saved straight away with Undo) for Reminders and Mio notes, but a calendar event goes through Calendar's sheet. Vibration pattern: 2 short = saved, 1 long = not understood. Hem shows a countdown to tests and an "Inför provet" copy package per subject. Settings: simple at the top, technical under Avancerat. Errors are one sentence plus one action, with a report button. A "Kontrollera allt" screen. A notification the day before the SideStore signing expires, with very clear steps (Tailscale and LocalDevVPN can't be on at the same time, so the refresh is manual). Nightly backup to the PC over Tailscale. Morning notification with the day's tests and homework (opt-in), evening notification with things to review. Lesson notes ready within about 5 min. New icon: the whole word "mio" with the o as a ring with a sound wave, an Icon Composer .icon with Liquid Glass layers in blue.

## Tried and ruled out
- Mistral Medium 3.5: deprecated 2026-10-31 (replaced by Large 4); remove it from the candidates.
- Large 4 for everyday: it can't turn reasoning off (low/medium/high only) and would cost about $28/month, more than the credits.
- GLM 5.3 / GLM 5.3 Flash (no "none" level; the big one is 2x Large 4's price) and DeepSeek V4.1 Flash (Public Preview, inconsistent ID): not added.
- Timetable or reading Calendar, widgets, Study inside Mio, a better Fråga Mio (rarely used), filtering out other people's voices, a privacy page: all declined.
- Wake-on-LAN or a fallback when the PC is off: the PC is always on.

## Watch out
- Small 4 only documents reasoning_effort none/high; Large 4 refuses "none". Mistral's docs don't say whether reasoning plus json_schema strict can be combined, or whether temperature works with reasoning on. Prova has to settle that.
- With reasoning on, Mistral returns message.content as a list (a thinking chunk + a text chunk); an adapter that rejects reasoning in the answer has to take out the text chunk for the lesson profile.
- Subject per lesson is a dependency for the countdown and the exam package (she declined a timetable).
- Changes the CLAUDE.md rules on Groq as the default, "reasoning off on every call" and "Suggestions need an explicit Yes" (direct notes): record them in DECISIONS.md when they're built.

In the code:
- server/src/model_profiles.rs: CANDIDATE_MODELS, ReasoningOff::EffortNone.
- Mio/Assets.xcassets/AppIcon.appiconset: the "mi" icon on a blue gradient that will be replaced.
