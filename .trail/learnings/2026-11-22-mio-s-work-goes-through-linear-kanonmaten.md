---
title: "Mio's work goes through Linear issues and pull requests that Claude merges, with one version number for the whole repo"
author: Kanonmaten
date: 2026-11-22
branch: kanonmaten/mio-21-installera-coderabbit-pa-github-repot
cost: { minutes: 2, tokens: 18817 }
id: l-fbf3b9c9
scope: repo
status: active
replaces: l-12a738a5
src: agent
touches:
  - ".coderabbit.yaml"
  - CLAUDE.md
  - docs/DECISIONS.md
  - ".github/workflows/build-unsigned-ipa.yml"
  - CHANGELOG.md
  - README.md
  - control/DESIGN.md
  - control/README.md
  - docs/DATAMODELL.md
  - docs/README.md
---

## Decided
User's choices 2026-11-21. Planning (features, bugs, phone and PC tests) lives in Linear, team Mio with key MIO (called KAN until 2026-11-22; old KAN-n links still work). Every change goes on a branch named after the issue, through a PR titled with the key; CI and CodeRabbit review it, and Claude squash-merges once every check for the last commit passed and no thread is open. One SemVer version in VERSION covers the whole repo; the unreleased 0.9.1 became 0.10.0. Finished plans move unchanged into docs/arkiv/.

## Tried and ruled out
- Pushing straight to main: no review before main, no CodeRabbit.
- The user pressing Merge on every PR: too many clicks for a solo project.
- Keeping 0.9.1, or date versions: 0.9.1 holds new features, and a date says nothing about size.

## Watch out
- CodeRabbit's Linear link is off by default for public repos; .coderabbit.yaml turns it on for MIO.
- The gateway's RELEASE label and the stored key mio.upgrade.0.9.1.legacyItemsRemoved are not the product version.

In the code:
- Branch `kanonmaten/mio-<n>-…`; merge with `gh pr merge --squash --delete-branch`.
- `tools/src/project.rs` checks VERSION against the Xcode project and every manifest.
- `.coderabbit.yaml`: sv-SE, knowledge_base.linear team_keys MIO, skips docs/arkiv/ and .trail/.
