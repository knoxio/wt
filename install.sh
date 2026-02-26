#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LINE="source $TOOL_DIR/wt.zsh"
OLD_PATTERN='source.*worktree-branch\.sh'
ZSHRC="$HOME/.zshrc"

if grep -qE "$OLD_PATTERN" "$ZSHRC"; then
  perl -i -pe "s|.*$OLD_PATTERN.*|$SOURCE_LINE|" "$ZSHRC"
  echo "Replaced old worktree-branch.sh source line"
elif grep -qF "$SOURCE_LINE" "$ZSHRC"; then
  echo "Already installed — no changes needed"
else
  printf '\n# wt worktree tool\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "Appended source line to .zshrc"
fi

echo "Run: source ~/.zshrc"
