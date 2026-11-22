---
title: "Mio's work goes through Linear issues and pull requests that GitHub auto-merges, with one version number for the whole repo"
author: Kanonmaten
date: 2026-11-22
branch: kanonmaten/mio-28-auto-merge-github-slar-ihop-en-pr-nar-alla
cost: { minutes: 3, tokens: 36188 }
id: l-2a1d9d9e
scope: repo
status: active
replaces: l-fbf3b9c9
src: agent
touches:
  - ".coderabbit.yaml"
  - CLAUDE.md
  - docs/DECISIONS.md
  - tools/src/project.rs
---

## Decided
User's choices 2026-11-21 and 22. Planning (features, bugs, phone and PC tests) lives in Linear, team Mio with key MIO (KAN until 2026-11-22; old links work). Every change goes on a branch named after the issue, through a PR titled with the key. Claude turns on auto-merge when opening it; GitHub merges once the Linux jobs, the IPA and simulator-test jobs, the CodeRabbit check and CodeRabbit's approval are in and no thread is open. One SemVer version in VERSION covers the whole repo (0.9.1 became 0.10.0).

## Tried and ruled out
- Pushing straight to main: no review before main.
- The user pressing Merge on every PR: too many clicks.
- Claude merging by hand: a PR waited when the session ended, and nothing enforced waiting for the simulator tests.
- Requiring only CodeRabbit's status check: it also passes when a review was skipped or rate limited.

## Watch out
- "Bygg Mio IPA" runs on every PR; its plan job skips IPA and tests when the app is untouched, and a skipped job counts as passed. A path filter on pull_request would leave required checks waiting forever.
- CodeRabbit's Linear link is off by default for public repos; .coderabbit.yaml turns it on.
- A Codex review thread also blocks the merge until resolved.

In the code:
- `gh pr merge <n> --auto --squash --delete-branch`; `--disable-auto` to hold one.
- .coderabbit.yaml: auto_approvals (no author approval), fail_commit_status, linear team_keys MIO.
- tools/src/project.rs allows the ipa job to need only `plan`.
