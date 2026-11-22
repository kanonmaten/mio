---
title: "Mio Kontroll's git tests no longer follow a calling git's GIT_DIR, but pushing from a linked worktree is still untested"
author: Kanonmaten
date: 2026-11-22
branch: mio-26-git-env
cost: { minutes: 22, tokens: 93657 }
id: l-4fa41231
scope: repo
status: active
replaces: l-3f5a0722
src: agent
touches:
  - control/core/src/updates.rs
  - tools/Cargo.toml
---

## Decided
Every git that Mio Kontroll's updates module runs (production and tests) clears the variables `git rev-parse --local-env-vars` lists, so a pre-push hook's GIT_DIR from a linked worktree no longer sends the test's `git init`, `commit` and `clone` into the real repo (MIO-26, 2026-11-22). A test reruns the scenario in a child process with GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE aimed at a decoy repo and checks the decoy is untouched.

## Tried and ruled out
Clearing only the four variables the issue named (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR): git's own list has 15, including GIT_OBJECT_DIRECTORY and GIT_CONFIG_PARAMETERS, and git clears that full list itself before running in a submodule.

## Watch out
- A whole `verify` pushed from a linked worktree has not been run since the fix. Until it has, push from the main checkout.
- If `git status` says "must be run in a work tree" or `git worktree list` shows "(bare)", recover before any push: `git config --local core.bare false`, then `git log` the branch. Junk commits are named after test files (`server/a.rs`, `control/a.rs`) and sit on top of your own.
- To drop only them: free the branch from the linked worktree first (`git worktree remove --force <dir>` or `git -C <dir> switch --detach`), because `git branch -f` refuses a branch checked out elsewhere. If they were already pushed, revert them instead of force-pushing.
- The hook refuses untracked files too, so commit or move a new learning file before pushing.

In the code:
- control/core/src/updates.rs: `REPO_ENV`, `git_command`, test `git_ignores_a_repo_inherited_from_a_calling_git`.
- .githooks/pre-push runs `cargo run --locked --manifest-path tools/Cargo.toml -- verify`.
