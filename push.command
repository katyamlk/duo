#!/bin/bash
# Commits and pushes all changes in Duo to GitHub.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"

if [ ! -d .git ]; then echo "Run github-setup.command first."; exit 1; fi

git add -A
if git diff --cached --quiet; then
  echo "Nothing new to push."
  exit 0
fi

if [ -n "$1" ]; then
  MSG="$1"
elif [ -s .next-commit-msg ]; then
  MSG=$(cat .next-commit-msg)
else
  MSG="Update $(date '+%Y-%m-%d %H:%M')"
fi

git commit -q -m "$MSG"
git push -q
: > .next-commit-msg
echo "Pushed: $(git log -1 --pretty=%s)"
