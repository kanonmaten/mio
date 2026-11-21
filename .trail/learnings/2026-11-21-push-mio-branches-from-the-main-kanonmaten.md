---
title: "Push Mio branches from the main checkout, never from a linked git worktree"
author: Kanonmaten
date: 2026-11-21
branch: kanonmaten/kan-24-arbeta-med-grenar-och-pr-i-stallet-for
cost: { minutes: 5, tokens: 30278 }
id: l-b52b0f49
scope: repo
status: active
src: agent
touches:
  - CLAUDE.md
  - docs/DECISIONS.md
  - control/core/src/updates.rs
  - tools/Cargo.toml
---

## Decided
Push from the main checkout. In a linked worktree git sets GIT_DIR for the pre-push hook, and the full verify then runs Mio Kontroll's git tests against the real repository.

## Tried and ruled out
Pushing a branch from a second worktree so that one verify could run while editing another branch: the control test failed, made two junk commits on the branch and set core.bare=true in the repository config.

## Watch out
- If `git status` says "must be run in a work tree" or `git worktree list` shows "(bare)", run `git config --local core.bare false` and check the branch for commits named after test files.
- The hook refuses untracked files too, so commit or move a new learning file before pushing.
- In zsh, never name a shell variable `path`: it is tied to PATH.

In the code:
- Test `updates::tests::a_part_is_behind_only_when_its_directory_changed_upstream` in control/core/src/updates.rs; fix tracked as Linear KAN-26 (strip GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR before running git).
- .githooks/pre-push runs `cargo run --locked --manifest-path tools/Cargo.toml -- verify`.
