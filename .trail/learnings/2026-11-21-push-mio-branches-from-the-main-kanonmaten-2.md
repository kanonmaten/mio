---
title: "Push Mio branches from the main checkout, never from a linked git worktree"
author: Kanonmaten
date: 2026-11-21
branch: kanonmaten/kan-25-stada-dokumentationen
cost: { minutes: 20, tokens: 74755 }
id: l-4a27a0c2
scope: repo
status: active
replaces: l-b52b0f49
src: agent
touches:
  - CHANGELOG.md
  - CLAUDE.md
  - Mio.xcodeproj/project.pbxproj
  - README.md
  - VERSION
  - control/Cargo.lock
  - control/Cargo.toml
  - docs/DECISIONS.md
  - docs/STATUS.md
  - server/Cargo.lock
---

## Decided
Push from the main checkout. In a linked worktree git sets GIT_DIR for the pre-push hook, and the full verify then runs Mio Kontroll's git tests against the real repository.

## Tried and ruled out
Pushing a branch from a second worktree so that one verify could run while editing another branch: the control test failed, made two junk commits on the branch and set core.bare=true in the repository config.

## Watch out
- If `git status` says "must be run in a work tree" or `git worktree list` shows "(bare)", recover before any push: `git config --local core.bare false`, then `git log` the branch. Junk commits are named after test files (`server/a.rs`, `control/a.rs`) and sit on top of your own. Remove only them with `git branch -f <branch> <your last real commit>` (from another branch) or `git reset --hard <your last real commit>` after checking `git status` is clean. If they were already pushed, revert them instead of force-pushing.
- The hook refuses untracked files too, so commit or move a new learning file before pushing.
- In zsh, never name a shell variable `path`: it is tied to PATH.

In the code:
- Test `updates::tests::a_part_is_behind_only_when_its_directory_changed_upstream` in control/core/src/updates.rs; fix tracked as Linear KAN-26 (strip GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR before running git).
- .githooks/pre-push runs `cargo run --locked --manifest-path tools/Cargo.toml -- verify`.
