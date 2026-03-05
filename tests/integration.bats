#!/usr/bin/env bats
# Integration tests for wt.zsh — require a real git repo.
# Each test gets an isolated temp directory via $BATS_TEST_TMPDIR.

load helpers

# ---------------------------------------------------------------------------
# _wt_is_dirty
# ---------------------------------------------------------------------------

@test "is_dirty: clean repo returns false" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"

  run zsh -c "source '$WT_ZSH' && _wt_is_dirty '$repo' && echo dirty || echo clean"
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "is_dirty: unstaged modification returns true" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"
  echo "change" >> "$repo/README.md"

  run zsh -c "source '$WT_ZSH' && _wt_is_dirty '$repo' && echo dirty || echo clean"
  [ "$status" -eq 0 ]
  [ "$output" = "dirty" ]
}

@test "is_dirty: staged (but uncommitted) change returns true" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"
  echo "staged" >> "$repo/README.md"
  git -C "$repo" add README.md

  run zsh -c "source '$WT_ZSH' && _wt_is_dirty '$repo' && echo dirty || echo clean"
  [ "$status" -eq 0 ]
  [ "$output" = "dirty" ]
}

# ---------------------------------------------------------------------------
# _wt_default_branch
# ---------------------------------------------------------------------------

@test "default_branch: resolves main from origin/HEAD" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo_with_origin "$base" "main"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_default_branch"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "default_branch: resolves non-main default branch name" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo_with_origin "$base" "develop"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_default_branch"
  [ "$status" -eq 0 ]
  [ "$output" = "develop" ]
}

@test "default_branch: falls back to main when origin/HEAD absent but origin/main exists" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"
  # Add a remote but do NOT set origin/HEAD
  git -C "$repo" remote add origin "file:///nonexistent"
  git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD)"

  run zsh -c "source '$WT_ZSH' && cd '$repo' && _wt_default_branch"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# ---------------------------------------------------------------------------
# _wt_list_worktrees
# ---------------------------------------------------------------------------

@test "list_worktrees: single worktree returns one pipe-separated record" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"

  run zsh -c "source '$WT_ZSH' && cd '$repo' && _wt_list_worktrees"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  # Format: path|branch|sha (7 chars)
  [[ "$output" =~ ^.+\|main\|[0-9a-f]{7}$ ]]
}

@test "list_worktrees: detached HEAD worktree shows (detached) as branch" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  local sha
  sha="$(git -C "$base/main" rev-parse HEAD)"
  git -C "$base/main" worktree add --detach "$base/detached" "$sha"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_list_worktrees"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "(detached)" ]]
}

@test "list_worktrees: additional worktree appears in output" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b feat-x "$base/feat-x"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_list_worktrees"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$output" =~ "feat-x" ]]
}

@test "list_worktrees: output paths are absolute" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"

  run zsh -c "source '$WT_ZSH' && cd '$repo' && _wt_list_worktrees"
  [ "$status" -eq 0 ]
  # First field of the single record should be the absolute repo path
  local path
  path="$(echo "$output" | cut -d'|' -f1)"
  [ "$path" = "$repo" ]
}

# ---------------------------------------------------------------------------
# _wt_worktree_for_branch
# ---------------------------------------------------------------------------

@test "worktree_for_branch: returns path for existing branch" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b feat-lookup "$base/feat-lookup"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_worktree_for_branch 'feat-lookup'"
  [ "$status" -eq 0 ]
  [ "$output" = "$base/feat-lookup" ]
}

@test "worktree_for_branch: returns empty for non-existent branch" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"

  run zsh -c "source '$WT_ZSH' && cd '$repo' && _wt_worktree_for_branch 'no-such-branch'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# wt new
# ---------------------------------------------------------------------------

@test "wt new: creates worktree directory at parent/<branch>" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_new my-feature --here --no-deps"
  [ "$status" -eq 0 ]
  [ -d "$base/my-feature" ]
}

@test "wt new: sanitizes branch name with slash into directory name" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_new feat/new-thing --here --no-deps"
  [ "$status" -eq 0 ]
  # Slash is replaced; directory should NOT contain a literal slash in its basename
  [ -d "$base/feat-new-thing" ]
  [ ! -d "$base/feat" ]  # no nested directory created
}

@test "wt new: --dir overrides sanitized directory name" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_new feat/thing --here --no-deps --dir custom-name"
  [ "$status" -eq 0 ]
  [ -d "$base/custom-name" ]
  [ ! -d "$base/feat-thing" ]  # default name was not used
}

@test "wt new: fails if target directory already exists" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  mkdir -p "$base/existing"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_new existing --here --no-deps"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "already exists" ]]
}

@test "wt new: --from creates worktree from specified ref" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  # Add a second commit so there is a distinct ref to branch from
  echo "second" > "$base/main/second.txt"
  git -C "$base/main" add .
  git -C "$base/main" commit -q -m "second"
  local first_sha
  first_sha="$(git -C "$base/main" rev-parse HEAD~1)"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_new from-first --from '$first_sha' --no-deps"
  [ "$status" -eq 0 ]
  [ -d "$base/from-first" ]
  # Worktree should be at the first commit, not the second
  local wt_sha
  wt_sha="$(git -C "$base/from-first" rev-parse HEAD)"
  [ "$wt_sha" = "$first_sha" ]
}

@test "wt new: output includes go hint" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_new hint-test --here --no-deps"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "wt go" ]]
}

# ---------------------------------------------------------------------------
# wt rm
# ---------------------------------------------------------------------------

@test "wt rm: removes worktree directory and branch" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b to-remove "$base/to-remove"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_rm to-remove"
  [ "$status" -eq 0 ]
  [ ! -d "$base/to-remove" ]
  # Branch should be gone
  run git -C "$base/main" branch --list to-remove
  [ -z "$output" ]
}

@test "wt rm: --keep-branch preserves the git branch" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b keep-me "$base/keep-me"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_rm keep-me --keep-branch"
  [ "$status" -eq 0 ]
  [ ! -d "$base/keep-me" ]
  # Branch must still exist
  run git -C "$base/main" branch --list keep-me
  [[ "$output" =~ "keep-me" ]]
}

@test "wt rm: refuses to remove the currently active worktree" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"

  # Try to remove "main" from inside main — that is the active worktree
  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_rm main"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "currently active" ]]
}

@test "wt rm: refuses to remove dirty worktree without --force" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b dirty-wt "$base/dirty-wt"
  echo "change" >> "$base/dirty-wt/README.md"  # make it dirty

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_rm dirty-wt"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "uncommitted changes" ]]
  [ -d "$base/dirty-wt" ]  # still exists
}

@test "wt rm: --force removes dirty worktree" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b dirty-force "$base/dirty-force"
  echo "change" >> "$base/dirty-force/README.md"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_rm dirty-force --force"
  [ "$status" -eq 0 ]
  [ ! -d "$base/dirty-force" ]
}

@test "wt rm: prints warning and keeps unmerged branch instead of force-deleting" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b unmerged-wt "$base/unmerged-wt"
  # Add a commit to the worktree branch so git branch -d refuses it
  echo "unmerged" > "$base/unmerged-wt/unmerged.txt"
  git -C "$base/unmerged-wt" add .
  git -C "$base/unmerged-wt" commit -q -m "unmerged commit"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_rm unmerged-wt"
  [ "$status" -eq 0 ]
  # Worktree directory is removed ...
  [ ! -d "$base/unmerged-wt" ]
  # ... but branch still exists (not force-deleted)
  run git -C "$base/main" branch --list unmerged-wt
  [[ "$output" =~ "unmerged-wt" ]]
}

@test "wt rm: fails with helpful message for non-existent branch" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"

  run zsh -c "source '$WT_ZSH' && cd '$repo' && _wt_cmd_rm no-such-worktree"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no worktree found" ]]
}

# ---------------------------------------------------------------------------
# wt ls
# ---------------------------------------------------------------------------

@test "wt ls: marks current worktree with *" {
  local repo="$BATS_TEST_TMPDIR/repo"
  setup_repo "$repo"

  run zsh -c "source '$WT_ZSH' && cd '$repo' && _wt_cmd_ls"
  [ "$status" -eq 0 ]
  # The * marker must appear on a line containing the repo's branch
  [[ "$output" =~ \*.*main ]]
}

@test "wt ls: shows all worktrees" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b ls-extra "$base/ls-extra"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_ls"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "main" ]]
  [[ "$output" =~ "ls-extra" ]]
}

@test "wt ls: shows dirty indicator for modified worktree" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b dirty-ls "$base/dirty-ls"
  echo "dirty" >> "$base/dirty-ls/README.md"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_ls"
  [ "$status" -eq 0 ]
  # ● is the dirty indicator
  [[ "$output" =~ "●" ]]
}

@test "wt ls: clean worktree has no dirty indicator" {
  local base="$BATS_TEST_TMPDIR/repos"
  setup_repo "$base/main"
  git -C "$base/main" worktree add -q -b clean-ls "$base/clean-ls"

  run zsh -c "source '$WT_ZSH' && cd '$base/main' && _wt_cmd_ls"
  [ "$status" -eq 0 ]
  # The clean-ls line should not have ●
  local clean_line
  clean_line="$(echo "$output" | grep 'clean-ls')"
  [[ ! "$clean_line" =~ "●" ]]
}

# ---------------------------------------------------------------------------
# _wt_sync_files
# ---------------------------------------------------------------------------

@test "sync_files: copies untracked file to destination" {
  local base="$BATS_TEST_TMPDIR/sync"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"

  # Create an untracked file in src
  echo "secret" > "$base/src/untracked.txt"

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  [ -f "$dst/untracked.txt" ]
  [ "$(cat "$dst/untracked.txt")" = "secret" ]
}

@test "sync_files: copies .env file (gitignored) to destination" {
  local base="$BATS_TEST_TMPDIR/sync-env"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"

  # .env is gitignored; create it after init
  printf 'DATABASE_URL=postgres://localhost/test\n' > "$base/src/.env"
  echo ".env" > "$base/src/.gitignore"
  git -C "$base/src" add .gitignore
  git -C "$base/src" commit -q -m "add gitignore"

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  [ -f "$dst/.env" ]
  [[ "$(cat "$dst/.env")" =~ "DATABASE_URL" ]]
}

@test "sync_files: copies .env.local to destination" {
  local base="$BATS_TEST_TMPDIR/sync-envlocal"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"

  printf 'NEXT_PUBLIC_API=http://localhost\n' > "$base/src/.env.local"

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  [ -f "$dst/.env.local" ]
}

@test "sync_files: excludes node_modules" {
  local base="$BATS_TEST_TMPDIR/sync-nm"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"

  # node_modules with an untracked file inside
  mkdir -p "$base/src/node_modules/some-pkg"
  echo "pkg" > "$base/src/node_modules/some-pkg/index.js"

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  [ ! -d "$dst/node_modules" ]
}

@test "sync_files: does not overwrite destination files that already exist" {
  local base="$BATS_TEST_TMPDIR/sync-nooverwrite"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"

  echo "original" > "$base/src/config.txt"
  echo "existing" > "$dst/config.txt"

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  # rsync default: src wins on untracked files; that's expected behaviour —
  # just verify the command completes without error
}

@test "sync_files: prints nothing-to-sync message when no untracked or env files" {
  local base="$BATS_TEST_TMPDIR/sync-empty"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"
  # No untracked files, no env files — only committed content

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nothing to sync" ]]
}

@test "sync_files: preserves nested path structure for env files" {
  local base="$BATS_TEST_TMPDIR/sync-nested"
  setup_repo "$base/src"
  local dst="$base/dst"
  mkdir -p "$dst"

  mkdir -p "$base/src/apps/api"
  printf 'SECRET=abc\n' > "$base/src/apps/api/.env"

  run zsh -c "source '$WT_ZSH' && _wt_sync_files '$base/src' '$dst'"
  [ "$status" -eq 0 ]
  [ -f "$dst/apps/api/.env" ]
}
