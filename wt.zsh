# wt — git worktree management suite
# Single-file implementation (required: cd must run in the calling shell)
# Source this file from .zshrc
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_wt_assert_git_repo() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "wt: not inside a git repository" >&2
    return 1
  fi
}

# Canonical (symlink-resolved) absolute path to the repo root.
# On macOS /var/folders is a symlink to /private/var/folders; git rev-parse
# returns the resolved form, so we normalise here to avoid comparison mismatches.
_wt_repo_root() {
  (cd "$(git rev-parse --show-toplevel)" && pwd -P)
}

_wt_worktrees_root() {
  dirname "$(_wt_repo_root)"
}

# Replace / with -, strip leading/trailing -
_wt_sanitize_branch() {
  local branch="$1"
  branch="${branch//\//-}"
  branch="${branch##-}"
  branch="${branch%%-}"
  echo "$branch"
}

# Resolve origin/HEAD → strip "refs/remotes/origin/" prefix
_wt_default_branch() {
  local ref
  ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -z "$ref" ]]; then
    # fallback: try to infer from common names
    if git rev-parse --verify origin/main &>/dev/null; then
      echo "main"
    elif git rev-parse --verify origin/master &>/dev/null; then
      echo "master"
    else
      echo "main"
    fi
    return
  fi
  echo "${ref#refs/remotes/origin/}"
}

# Detect package manager from lockfile (pnpm > yarn > npm)
_wt_detect_pm() {
  local root="$1"
  if [[ -f "$root/pnpm-lock.yaml" ]]; then
    echo "pnpm"
  elif [[ -f "$root/yarn.lock" ]]; then
    echo "yarn"
  elif [[ -f "$root/package-lock.json" ]]; then
    echo "npm"
  else
    echo "pnpm"  # default
  fi
}

# Detect editor: webstorm > idea > cursor > code
_wt_detect_editor() {
  if command -v webstorm &>/dev/null; then
    echo "webstorm"
  elif command -v idea &>/dev/null; then
    echo "idea"
  elif command -v cursor &>/dev/null; then
    echo "cursor"
  elif command -v code &>/dev/null; then
    echo "code"
  else
    echo ""
  fi
}

# Returns 0 if working tree has uncommitted changes, 1 if clean.
# Uses `command git` to bypass any zsh function or alias shadowing git.
# Note: deliberately avoids `local path` — in zsh, `path` is tied to $PATH.
_wt_is_dirty() {
  local _dirty_target="${1:-.}"
  if command git -C "$_dirty_target" diff --quiet 2>/dev/null &&
     command git -C "$_dirty_target" diff --cached --quiet 2>/dev/null; then
    return 1  # clean
  fi
  return 0  # dirty
}

# Given a branch name, return its worktree path (empty if not found)
_wt_worktree_for_branch() {
  local branch="$1"
  git worktree list --porcelain | awk -v branch="$branch" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { b = substr($0, 8); sub("^refs/heads/", "", b)
                   if (b == branch) { print path; exit } }
  '
}

# Returns lines of "path|branch|sha" for all worktrees
_wt_list_worktrees() {
  git worktree list --porcelain | awk '
    /^worktree /  { path = substr($0, 10) }
    /^HEAD /      { sha = substr($0, 6, 7) }
    /^branch /    { b = substr($0, 8); sub("^refs/heads/", "", b) }
    /^detached$/  { b = "(detached)" }
    /^(bare)?$/   {
      if (path != "") print path "|" b "|" sha
      path=""; b=""; sha=""
    }
    END { if (path != "") print path "|" b "|" sha }
  '
}

# fzf picker over worktree list; prints selected path
_wt_fzf_pick() {
  local current_root
  current_root="$(_wt_repo_root)"

  local lines
  lines="$(_wt_list_worktrees)"

  if [[ -z "$lines" ]]; then
    echo "wt: no worktrees found" >&2
    return 1
  fi

  local selected
  selected="$(echo "$lines" | awk -F'|' -v cur="$current_root" '
    {
      rel = $1
      cmd = "python3 -c \"import os; print(os.path.relpath('"'"'" $1 "'"'"'))\" 2>/dev/null"
      cmd | getline rel
      close(cmd)
      marker = ($1 == cur) ? "* " : "  "
      printf "%s%-40s  %-30s  %s\n", marker, rel, $2, $3
    }
  ' | fzf --ansi --prompt="worktree> " \
       --preview="git -C \$(echo {} | awk '{print \$1}') log --oneline -15 2>/dev/null" \
       --preview-window=right:50% \
       --height=40%)"

  if [[ -z "$selected" ]]; then
    return 1
  fi

  # Extract relative path from selection, resolve back to absolute
  local rel_path
  rel_path="$(echo "$selected" | awk '{print $1}')"
  # Remove leading * marker if present
  rel_path="${rel_path#\*}"
  # The awk already outputs relative path; resolve from cwd
  python3 -c "import os; print(os.path.abspath('$rel_path'))" 2>/dev/null || \
    echo "$rel_path"
}

# zsh select fallback when fzf not available
_wt_select_pick() {
  local lines
  lines="$(_wt_list_worktrees)"

  if [[ -z "$lines" ]]; then
    echo "wt: no worktrees found" >&2
    return 1
  fi

  local -a options
  local -a paths
  local i=0
  while IFS='|' read -r path branch sha; do
    options+=("$branch ($sha)")
    paths+=("$path")
    (( i++ ))
  done <<< "$lines"

  local PS3="Select worktree: "
  select opt in "${options[@]}"; do
    if [[ -n "$opt" ]]; then
      echo "${paths[$REPLY]}"
      return 0
    fi
  done
  return 1
}

# Two-pass sync: untracked files + env files
_wt_sync_files() {
  local src="$1"
  local dst="$2"

  local excludes=(
    --exclude='node_modules/'
    --exclude='.git/'
    --exclude='.next/'
    --exclude='dist/'
    --exclude='out/'
    --exclude='build/'
    --exclude='.turbo/'
    --exclude='coverage/'
    --exclude='.nyc_output/'
    --exclude='*.tsbuildinfo'
    --exclude='.idea/workspace.xml'
  )

  # Pass 1 — untracked non-ignored files
  # Filter excluded dirs from the file list: rsync --exclude doesn't reliably
  # skip explicitly listed paths when using --files-from.
  local tmpfile
  tmpfile="$(mktemp)"
  git -C "$src" ls-files --others --exclude-standard \
    | grep -Ev '^(node_modules|\.git|\.next|dist|out|build|\.turbo|coverage|\.nyc_output)/' \
    > "$tmpfile" || true
  local files_synced=false
  if [[ -s "$tmpfile" ]]; then
    files_synced=true
    echo "wt sync: copying untracked files..." >&2
    rsync -a "${excludes[@]}" --files-from="$tmpfile" "$src/" "$dst/"
  fi
  rm -f "$tmpfile"

  # Pass 2 — env files (gitignored, invisible to ls-files)
  local env_patterns=(
    -name ".env"
    -o -name ".env.*"
    -o -name ".env.local"
    -o -name ".env.*.local"
    -o -name ".env.development"
    -o -name ".env.production"
    -o -name ".env.test"
  )
  local found_any=false
  while IFS= read -r src_file; do
    found_any=true
    local rel_path="${src_file#"$src"/}"
    local dst_file="$dst/$rel_path"
    local dst_dir
    dst_dir="$(dirname "$dst_file")"
    mkdir -p "$dst_dir"
    cp "$src_file" "$dst_file"
    echo "wt sync: copied $rel_path" >&2
  done < <(find "$src" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/.next/*" \
    -not -path "*/dist/*" \
    \( "${env_patterns[@]}" \) \
    -type f 2>/dev/null)

  if ! $found_any && ! $files_synced; then
    echo "wt sync: nothing to sync" >&2
  fi
}

# Open a worktree path in detected editor
_wt_open_in_editor() {
  local _editor_target="$1"
  local editor
  editor="$(_wt_detect_editor)"
  if [[ -z "$editor" ]]; then
    echo "wt: no supported editor found (webstorm, idea, cursor, code)" >&2
    return 1
  fi
  "$editor" "$_editor_target"
}

# Open a new Terminal.app window/tab at path
_wt_open_terminal() {
  local _term_target="$1"
  local escaped="${_term_target//\'/\'\\\'\'}"
  osascript <<APPLESCRIPT 2>/dev/null
tell application "Terminal"
    activate
    do script "cd '$escaped'"
end tell
APPLESCRIPT
  if [[ $? -ne 0 ]]; then
    echo "wt: failed to open Terminal.app (check Automation permissions)" >&2
    echo "     System Settings → Privacy & Security → Automation" >&2
    echo "     path: $_term_target" >&2
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

_wt_cmd_new() {
  _wt_assert_git_repo || return 1

  if [[ $# -eq 0 ]]; then
    echo "Usage: wt new <branch> [--from <ref>] [--here] [--no-deps] [--open] [--sh] [--dir <name>]" >&2
    return 1
  fi

  local branch="$1"
  shift

  local from=""
  local here=false
  local no_deps=false
  local do_open=false
  local do_sh=false
  local dir_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)    from="$2";         shift 2 ;;
      --here)    here=true;         shift ;;
      --no-deps) no_deps=true;      shift ;;
      --open)    do_open=true;      shift ;;
      --sh)      do_sh=true;        shift ;;
      --dir)     dir_override="$2"; shift 2 ;;
      *)
        echo "wt new: unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  local sanitized
  if [[ -n "$dir_override" ]]; then
    sanitized="$dir_override"
  else
    sanitized="$(_wt_sanitize_branch "$branch")"
  fi

  local worktree_path
  worktree_path="$(_wt_worktrees_root)/$sanitized"

  if [[ -d "$worktree_path" ]]; then
    echo "wt: directory already exists: $worktree_path" >&2
    return 1
  fi

  # Determine source ref
  local source_ref
  if $here; then
    source_ref="HEAD"
  elif [[ -n "$from" ]]; then
    source_ref="$from"
  else
    source_ref="$(_wt_default_branch)"
  fi

  local current_root
  current_root="$(_wt_repo_root)"

  # Set up ERR trap for cleanup
  local _wt_new_cleanup_path="$worktree_path"
  _wt_new_cleanup() {
    echo "wt: error — cleaning up worktree..." >&2
    git worktree remove --force "$_wt_new_cleanup_path" 2>/dev/null
    git worktree prune 2>/dev/null
  }
  trap '_wt_new_cleanup' ERR

  echo "wt: creating worktree '$sanitized' from '$source_ref'..."
  git worktree add -b "$branch" "$worktree_path" "$source_ref"

  echo "wt: syncing files..."
  _wt_sync_files "$current_root" "$worktree_path"

  # Detect and run package manager install
  if ! $no_deps; then
    local pm
    pm="$(_wt_detect_pm "$current_root")"
    echo "wt: running $pm install..."
    (cd "$worktree_path" && "$pm" install)
  fi

  # Remove ERR trap
  trap - ERR

  if $do_open; then
    _wt_open_in_editor "$worktree_path"
  fi

  if $do_sh; then
    _wt_open_terminal "$worktree_path"
  fi

  echo ""
  echo "wt: done → $worktree_path"
  echo "    to switch: wt go $branch"
}

_wt_cmd_ls() {
  _wt_assert_git_repo || return 1

  local current_root
  current_root="$(_wt_repo_root)"

  local lines
  lines="$(_wt_list_worktrees)"

  if [[ -z "$lines" ]]; then
    echo "(no worktrees)"
    return 0
  fi

  printf "%-3s %-40s  %-30s  %-7s  %s\n" "" "PATH" "BRANCH" "SHA" "STATUS"
  printf "%-3s %-40s  %-30s  %-7s  %s\n" "" "----" "------" "---" "------"

  local rel_path marker dirty_marker wt_path wt_branch wt_sha
  while IFS='|' read -r wt_path wt_branch wt_sha; do
    rel_path="$(python3 -c "import os; print(os.path.relpath('$wt_path'))" 2>/dev/null || echo "$wt_path")"

    marker=""
    if [[ "$wt_path" == "$current_root" ]]; then
      marker="*"
    fi

    dirty_marker=""
    if _wt_is_dirty "$wt_path"; then
      dirty_marker="●"
    fi

    printf "%-3s %-40s  %-30s  %-7s  %s\n" "$marker" "$rel_path" "$wt_branch" "$wt_sha" "$dirty_marker"
  done <<< "$lines"
}

_wt_cmd_go() {
  _wt_assert_git_repo || return 1

  local query="$1"
  local target_path=""

  if [[ -n "$query" ]]; then
    # Partial match against branch names
    local matches=()
    while IFS='|' read -r path branch sha; do
      if [[ "$branch" == *"$query"* ]]; then
        matches+=("$path|$branch|$sha")
      fi
    done <<< "$(_wt_list_worktrees)"

    if [[ ${#matches[@]} -eq 0 ]]; then
      echo "wt: no worktree matching '$query'" >&2
      return 1
    elif [[ ${#matches[@]} -eq 1 ]]; then
      target_path="${matches[1]%%|*}"
    else
      # Multiple matches — use fzf or select
      local list
      list="$(printf '%s\n' "${matches[@]}")"
      if command -v fzf &>/dev/null; then
        local selected
        selected="$(echo "$list" | awk -F'|' '{printf "%-35s  %s\n", $2, $3}' | \
          fzf --prompt="worktree> " --height=40%)"
        if [[ -z "$selected" ]]; then return 1; fi
        local selected_branch
        selected_branch="$(echo "$selected" | awk '{print $1}')"
        target_path="$(_wt_worktree_for_branch "$selected_branch")"
      else
        # zsh select fallback
        local PS3="Select worktree: "
        local -a opts
        local -a paths
        for entry in "${matches[@]}"; do
          IFS='|' read -r p b s <<< "$entry"
          opts+=("$b ($s)")
          paths+=("$p")
        done
        select opt in "${opts[@]}"; do
          if [[ -n "$opt" ]]; then
            target_path="${paths[$REPLY]}"
            break
          fi
        done
      fi
    fi
  else
    # No query — fzf picker or select
    if command -v fzf &>/dev/null; then
      local current_root
      current_root="$(_wt_repo_root)"

      local lines
      lines="$(_wt_list_worktrees)"

      local selected
      selected="$(echo "$lines" | awk -F'|' -v cur="$current_root" '{
        rel = $1
        cmd = "python3 -c \"import os; print(os.path.relpath('"'"'" $1 "'"'"'))\" 2>/dev/null"
        cmd | getline rel
        close(cmd)
        marker = ($1 == cur) ? "* " : "  "
        printf "%s%-40s  %-30s  %s\n", marker, rel, $2, $3
      }' | fzf --prompt="worktree> " \
           --preview='branch=$(echo {} | awk "{print \$2}"); path=$(git worktree list 2>/dev/null | grep -F " [$branch]" | awk "{print \$1}" | head -1); git -C "${path:-.}" log --oneline -15 2>/dev/null' \
           --preview-window=right:50% \
           --height=40%)"

      if [[ -z "$selected" ]]; then return 1; fi

      # Parse the selected line: strip marker, get relative path
      local rel
      rel="$(echo "$selected" | sed 's/^[* ] *//' | awk '{print $1}')"
      target_path="$(python3 -c "import os; print(os.path.abspath('$rel'))" 2>/dev/null || echo "$rel")"
    else
      # Fallback select
      target_path="$(_wt_select_pick)"
    fi
  fi

  if [[ -z "$target_path" ]]; then
    echo "wt: no worktree selected" >&2
    return 1
  fi

  if [[ ! -d "$target_path" ]]; then
    echo "wt: path does not exist: $target_path" >&2
    return 1
  fi

  cd "$target_path"
}

_wt_cmd_rm() {
  _wt_assert_git_repo || return 1

  if [[ $# -eq 0 ]]; then
    echo "Usage: wt rm <branch> [--keep-branch] [--force]" >&2
    return 1
  fi

  local branch="$1"
  shift

  local keep_branch=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-branch) keep_branch=true; shift ;;
      --force)       force=true;       shift ;;
      *)
        echo "wt rm: unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  local target_path
  target_path="$(_wt_worktree_for_branch "$branch")"

  if [[ -z "$target_path" ]]; then
    echo "wt: no worktree found for branch '$branch'" >&2
    return 1
  fi

  # Guard: cannot remove current worktree
  local current_root
  current_root="$(_wt_repo_root)"
  if [[ "$target_path" == "$current_root" ]]; then
    echo "wt: cannot remove the currently active worktree" >&2
    echo "     cd to another worktree first" >&2
    return 1
  fi

  # Dirty check
  if _wt_is_dirty "$target_path" && ! $force; then
    echo "wt: worktree '$branch' has uncommitted changes" >&2
    echo "     use --force to remove anyway" >&2
    return 1
  fi

  echo "wt: removing worktree '$branch' at $target_path..."
  git worktree remove ${force:+--force} "$target_path"
  git worktree prune

  if ! $keep_branch; then
    if ! git branch -d "$branch" 2>/dev/null; then
      echo "wt: branch '$branch' has unmerged commits and was not deleted" >&2
      echo "     merge or use --keep-branch to preserve it" >&2
    fi
  fi

  echo "wt: done"
}

_wt_cmd_open() {
  _wt_assert_git_repo || return 1

  local branch="$1"
  local target_path=""

  if [[ -n "$branch" ]]; then
    target_path="$(_wt_worktree_for_branch "$branch")"
    if [[ -z "$target_path" ]]; then
      echo "wt: no worktree found for branch '$branch'" >&2
      return 1
    fi
  else
    if command -v fzf &>/dev/null; then
      local current_root
      current_root="$(_wt_repo_root)"

      local selected
      selected="$(_wt_list_worktrees | awk -F'|' -v cur="$current_root" '{
        rel = $1
        cmd = "python3 -c \"import os; print(os.path.relpath('"'"'" $1 "'"'"'))\" 2>/dev/null"
        cmd | getline rel
        close(cmd)
        marker = ($1 == cur) ? "* " : "  "
        printf "%s%-40s  %-30s  %s\n", marker, rel, $2, $3
      }' | fzf --prompt="open in editor> " --height=40%)"

      if [[ -z "$selected" ]]; then return 1; fi
      local rel
      rel="$(echo "$selected" | sed 's/^[* ] *//' | awk '{print $1}')"
      target_path="$(python3 -c "import os; print(os.path.abspath('$rel'))" 2>/dev/null || echo "$rel")"
    else
      target_path="$(_wt_select_pick)"
    fi
  fi

  if [[ -z "$target_path" ]]; then
    echo "wt: no worktree selected" >&2
    return 1
  fi

  _wt_open_in_editor "$target_path"
}

_wt_cmd_sync() {
  _wt_assert_git_repo || return 1

  local branch="$1"
  local current_root
  current_root="$(_wt_repo_root)"
  local target_path=""

  if [[ -n "$branch" ]]; then
    target_path="$(_wt_worktree_for_branch "$branch")"
    if [[ -z "$target_path" ]]; then
      echo "wt: no worktree found for branch '$branch'" >&2
      return 1
    fi
  else
    if command -v fzf &>/dev/null; then
      local selected
      selected="$(_wt_list_worktrees | awk -F'|' -v cur="$current_root" '{
        if ($1 != cur) {
          rel = $1
          cmd = "python3 -c \"import os; print(os.path.relpath('"'"'" $1 "'"'"'))\" 2>/dev/null"
          cmd | getline rel
          close(cmd)
          printf "%-40s  %-30s  %s\n", rel, $2, $3
        }
      }' | fzf --prompt="sync to> " --height=40%)"

      if [[ -z "$selected" ]]; then return 1; fi
      local rel
      rel="$(echo "$selected" | awk '{print $1}')"
      target_path="$(python3 -c "import os; print(os.path.abspath('$rel'))" 2>/dev/null || echo "$rel")"
    else
      target_path="$(_wt_select_pick)"
    fi
  fi

  if [[ -z "$target_path" ]]; then
    echo "wt: no target selected" >&2
    return 1
  fi

  if [[ "$target_path" == "$current_root" ]]; then
    echo "wt: cannot sync a worktree to itself" >&2
    return 1
  fi

  echo "wt: syncing from $current_root → $target_path"
  _wt_sync_files "$current_root" "$target_path"
  echo "wt: sync complete"
}

_wt_cmd_prune() {
  _wt_assert_git_repo || return 1
  git worktree prune -v
}

_wt_usage() {
  cat <<'USAGE'
wt — git worktree management suite

Commands:
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
  wt help                   Show this message
USAGE
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

wt() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    new)   _wt_cmd_new "$@" ;;
    ls)    _wt_cmd_ls "$@" ;;
    go)    _wt_cmd_go "$@" ;;
    rm)    _wt_cmd_rm "$@" ;;
    open)  _wt_cmd_open "$@" ;;
    sync)  _wt_cmd_sync "$@" ;;
    prune) _wt_cmd_prune "$@" ;;
    help|--help|-h) _wt_usage ;;
    *)
      echo "wt: unknown command '$cmd'" >&2
      echo "    run 'wt help' for usage" >&2
      return 1
      ;;
  esac
}
