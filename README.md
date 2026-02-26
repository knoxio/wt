# wt — git worktree management suite

A `zsh` tool for managing git worktrees without the usual pitfalls.

## Install

```bash
git clone https://github.com/joaopcmiranda/wt ~/dev/tools/wt
bash ~/dev/tools/wt/install.sh
source ~/.zshrc
```

`install.sh` is idempotent — it replaces any existing `worktree-branch.sh` source line,
or appends a new one if none is present.

## Commands

```
wt new <branch> [flags]   Create a new worktree
  --from <ref>              Source ref (default: origin/HEAD default branch)
  --here                    Branch from current HEAD instead
  --no-deps                 Skip package manager install
  --open                    Open in editor after creation
  --sh                      Open a new Terminal.app window at the worktree path
  --dir <name>              Override sanitized directory name

wt ls                     List all worktrees (path, branch, SHA, dirty flag)
wt go [query]             cd into a worktree (fzf picker or partial branch match)
wt rm <branch> [flags]    Remove a worktree and its branch
  --keep-branch             Keep the git branch after removing worktree
  --force                   Remove even if dirty

wt open [branch]          Open a worktree in the detected editor (fzf picker if no branch)
wt sync [branch]          Sync untracked + env files from current worktree to target
wt prune                  Run git worktree prune -v
wt help                   Show usage
```

## Design

- **Single file** (`wt.zsh`): all functions are defined in the calling shell so `wt go`
  and `wt new --sh` can `cd` correctly. Splitting into multiple files would require
  sourcing each one from `.zshrc`.

- **No checkout of main**: `wt new` uses `git worktree add -b <branch> <path> <ref>` — a
  single command that creates the worktree directly from the source ref without touching
  the current checkout.

- **Smart PM detection**: detects `pnpm`, `yarn`, or `npm` from lockfiles. Runs install at
  the worktree root (correct for monorepos — not per-package).

- **Branch name sanitization**: `/` → `-`, stripped leading/trailing `-`. A branch named
  `feat/my-thing` lands at `../feat-my-thing`, not a nested `feat/` directory.

- **Two-pass sync** (`wt sync`):
  1. Untracked non-ignored files via `git ls-files --others --exclude-standard`
  2. Env files (`.env`, `.env.*`, etc.) that are gitignored and invisible to the above

- **fzf integration**: interactive pickers for `wt go`, `wt open`, `wt sync` with log
  preview. Falls back to zsh `select` if fzf is not installed.

- **Editor detection**: `webstorm` → `idea` → `cursor` → `code`

## Requirements

- `git` ≥ 2.5
- `zsh`
- `python3` (for portable relative-path computation — macOS has no `realpath --relative-to`)
- `rsync` (for untracked file sync)
- `fzf` (optional, recommended — falls back to `select`)
- `osascript` (for `--sh` Terminal.app opener — macOS only)
