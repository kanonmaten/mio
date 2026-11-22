---
title: "The install script's shell functions are tested under the same strict mode the script runs in"
author: Kanonmaten
date: 2026-11-22
branch: mio-38-key-whitespace
cost: { minutes: 18, tokens: 277537 }
id: l-e54df911
scope: repo
status: active
src: agent
touches:
  - server/install.sh
---

## Decided
Shell functions in the gateway's install script are tested under set -euo pipefail, the mode the script itself runs in. An optional positional argument is read as ${4-}, and a loop's last statement is an if, not a bare && test, so a false test is not the function's exit status.

## Tried and ruled out
Testing the key-check functions in a plain bash -c: every case passed while the real script stopped every Mistral install, because the Mistral call passes three arguments and prefix=$4 is an unbound variable under set -u. Code review caught it after the change was pushed.

## Watch out
- A bare [[ ... ]] && echo as the last statement of a loop or function returns 1 when the test is false, and set -e then ends the script without a message.
- In Mio Kontroll's GPUI tests, a plain div with an id is only found by window.find or try_find when it also calls test_support().

In the code: server/install.sh check_key, read_hidden_key; extract the functions with awk and run them with bash -c 'set -euo pipefail; source ...'.
