---
title: "Mio's work goes through Linear issues and pull requests that Claude merges, with one version number for the whole repo"
author: Kanonmaten
date: 2026-11-21
branch: kanonmaten/kan-24-arbeta-med-grenar-och-pr-i-stallet-for
cost: { minutes: 12, tokens: 249905 }
id: l-12a738a5
scope: repo
status: active
src: agent
touches:
  - ".github/workflows/build-unsigned-ipa.yml"
  - ".github/workflows/verify-linux.yml"
  - CLAUDE.md
  - README.md
  - docs/DECISIONS.md
  - tools/src/project.rs
  - transcription-server/pyproject.toml
---

## Decided
User's choices 2026-11-21. Planning (features, bugs, phone and PC tests) lives in Linear, not in Markdown plans in the repo. Every change goes on its own branch named after the Linear issue and through a pull request; CI and CodeRabbit review it, and Claude squash-merges once both workflows are green and no review thread is open. The user does not review. One SemVer version covers the app, widgets, gateway, Mio Kontroll, verifier and Pianissimo; the unreleased 0.9.1 became 0.10.0. Finished plans move unchanged into docs/arkiv/.

## Tried and ruled out
- Pushing straight to main (the rule since 2026-10-05): no review before main, and no CodeRabbit.
- The user pressing Merge on every PR: too many clicks for a solo project.
- Keeping 0.9.1, or date versions like 2026.11.0: 0.9.1 holds new features, and a date says nothing about size.
- Deleting finished plans: git keeps them, but they are harder to look up.

## Watch out
- The gateway's RELEASE label and the stored key mio.upgrade.0.9.1.legacyItemsRemoved are not the product version; renaming the key would rerun the upgrade on phones.
- Archived files keep their old relative links on purpose.
- The Linear team is still KAN (named after the workspace); the user may rename it to MIO.

In the code:
- Linear workspace `kanonmaten`, team `KAN`, projects "Mio 0.10.0 på telefonen", "Arbetssätt och dokumentation", "Idéer och framtida funktioner"; labels group Område (multi-select), Prov, Kräver godkännande.
- Branch names: Linear's `kanonmaten/kan-<n>-…`; merge with `gh pr merge --squash --delete-branch`.
- `VERSION` file; `tools/src/project.rs` checks MARKETING_VERSION (4×) and the version in server/, control/, tools/ Cargo.toml and transcription-server/pyproject.toml.
- Both workflows trigger on `pull_request` to main; ntfy skips PRs.
