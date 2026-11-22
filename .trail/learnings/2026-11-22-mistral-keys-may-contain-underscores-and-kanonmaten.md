---
title: "Mistral keys may contain underscores, and only the install script checks a key's shape"
author: Kanonmaten
date: 2026-11-22
branch: mio-38-key-whitespace
cost: { minutes: 3, tokens: 83856 }
id: l-af633e21
scope: repo
status: active
src: agent
touches:
  - CHANGELOG.md
  - server/install.sh
  - control/helper/src/lib.rs
---

## Decided
Mistral API keys can contain _ (the user's key does), so the install script accepts letters, digits, _ and - for Mistral, and trims surrounding whitespace like Mio Kontroll's helper does. The gateway itself never checks a provider key's shape; the install script is the only gate.

## Watch out
Once _ and - are allowed, a Groq key (gsk_...) and sk- keys also fit Mistral's pattern, so those prefix checks must run before the pattern match, not in the failure branch.

In the code: check_key and trim_key in server/install.sh; control/helper/src/lib.rs provider_key trims the same way.
