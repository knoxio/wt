#!/usr/bin/env bash
# wt installer — supports both local and remote (curl-pipe) installation.
#
# Local install (from a cloned repo):
#   bash install.sh
#
# Remote install (curl-pipe):
#   curl -fsSL https://raw.githubusercontent.com/knoxio/wt/main/install.sh | bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO_RAW="https://raw.githubusercontent.com/knoxio/wt/main"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/wt"
ZSHRC="$HOME/.zshrc"

# Patterns to replace (old tool name, any existing wt.zsh path)
OLD_PATTERN='source[[:space:]].*worktree-branch\.sh'
WT_PATTERN='source[[:space:]].*wt\.zsh'

# ---------------------------------------------------------------------------
# Detect local vs remote mode
# ---------------------------------------------------------------------------

_wt_script_dir() {
  # Works in bash (BASH_SOURCE) and when sourced in zsh ($0)
  local src="${BASH_SOURCE[0]:-$0}"
  # If running from stdin (curl pipe), $src is something like 'bash', 'zsh',
  # or '/dev/stdin' — none of which have a sibling wt.zsh.
  cd "$(dirname "$src")" 2>/dev/null && pwd -P || echo ""
}

SCRIPT_DIR="$(_wt_script_dir)"

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/wt.zsh" ]]; then
  # -----------------------------------------------------------------------
  # Local install: source from the repo directory
  # -----------------------------------------------------------------------
  WT_ZSH="$SCRIPT_DIR/wt.zsh"
  echo "wt: local install from $WT_ZSH"
else
  # -----------------------------------------------------------------------
  # Remote install: download wt.zsh to $INSTALL_DIR
  # -----------------------------------------------------------------------
  echo "wt: remote install — downloading to $INSTALL_DIR/wt.zsh"
  mkdir -p "$INSTALL_DIR"
  WT_ZSH="$INSTALL_DIR/wt.zsh"

  if command -v curl &>/dev/null; then
    curl -fsSL "$REPO_RAW/wt.zsh" -o "$WT_ZSH"
  elif command -v wget &>/dev/null; then
    wget -qO "$WT_ZSH" "$REPO_RAW/wt.zsh"
  else
    echo "wt: error — curl or wget is required for remote install" >&2
    exit 1
  fi
  echo "wt: downloaded to $WT_ZSH"
fi

# ---------------------------------------------------------------------------
# Update ~/.zshrc
# ---------------------------------------------------------------------------

SOURCE_LINE="source $WT_ZSH"

if [[ ! -f "$ZSHRC" ]]; then
  touch "$ZSHRC"
fi

if grep -qE "$OLD_PATTERN" "$ZSHRC"; then
  perl -i -pe "s|.*$OLD_PATTERN.*|$SOURCE_LINE|" "$ZSHRC"
  echo "wt: replaced old worktree-branch.sh source line in $ZSHRC"
elif grep -qE "$WT_PATTERN" "$ZSHRC"; then
  perl -i -pe "s|.*$WT_PATTERN.*|$SOURCE_LINE|" "$ZSHRC"
  echo "wt: updated existing wt.zsh source line in $ZSHRC"
else
  printf '\n# wt worktree tool\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "wt: appended source line to $ZSHRC"
fi

echo ""
echo "wt: installed. Run: source ~/.zshrc"
