# wt — Agent Coordination Guide

## What is `wt`?

`wt` is a single-file zsh worktree management tool. All logic lives in `wt.zsh`, which is
sourced into the calling shell from `.zshrc`. Functions must be defined in the calling
shell so that `wt go` and `wt new --sh` can `cd` correctly.

## Structure

```
wt.zsh          — entire implementation (sourced, not executed)
install.sh      — idempotent installer: appends/replaces source line in ~/.zshrc
tests/
  unit.bats         — unit tests (bats-core)
  integration.bats  — integration tests against a real git repo
  helpers.bash      — shared test helpers
```

## Key invariants

- **Single file.** Do not split `wt.zsh` into multiple files — it would break `cd`-based
  commands (`wt go`, `wt new --sh`) which require functions in the calling shell.
- **No external deps beyond the stated requirements.** zsh, git ≥ 2.5, python3, rsync.
  fzf and osascript are optional. Do not add new required dependencies.
- **Idempotent installer.** `install.sh` must remain safe to run multiple times.
- **macOS-first, Linux-compatible.** `python3` is used for relative paths because macOS
  `realpath` lacks `--relative-to`. Do not replace with GNU-only flags.

## Running tests

```bash
bats tests/
```

All tests must pass before any commit. Add tests for new behaviour.

## Pre-push checklist

Run in order before every `git push`:

```bash
bats tests/                  # all tests must pass
shellcheck wt.zsh            # fix all warnings, never suppress
```

## Coordination

This project uses `room` for agent coordination. See the `room` CLI docs for the
send/poll protocol. Follow the same announce-before-acting rules as any other project.

## Expected behaviour

### On starting work
1. Join the room if you don't have a token: `room join <room-id> <username>`
2. Poll for recent history: `room poll <room-id>`
3. Announce yourself and **propose your plan**: which functions in `wt.zsh` you will
   modify and why.
4. Poll again after ~30 seconds. Silence means proceed.

### During work
- **`wt.zsh` is the only shared file.** Any agent touching it must announce intent first.
- Announce before touching `wt.zsh` — even for fix commits.
- Milestone updates: after reading the file, after first draft, before opening a PR.
- Include `Closes #<issue-number>` in PR descriptions.

### On completion
1. Announce what changed and which functions were modified.
2. Confirm `bats tests/` and `shellcheck wt.zsh` both pass.
