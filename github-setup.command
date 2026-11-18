#!/bin/bash
# One-time setup: connects GitHub and creates a private "duo" repository from this folder.
set -e
cd "$(dirname "$0")"

# 1. GitHub CLI
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing GitHub CLI via Homebrew..."
    brew install gh
  else
    echo "Downloading GitHub CLI..."
    ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64
    URL=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep -o "https://[^\"]*macOS_${ARCH}\.zip" | head -1)
    [ -z "$URL" ] && URL=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep -o 'https://[^"]*macOS_universal\.zip' | head -1)
    if [ -z "$URL" ]; then echo "Could not find GitHub CLI download. Install it from https://cli.github.com and run this again."; exit 1; fi
    TMP=$(mktemp -d)
    curl -fsSL "$URL" -o "$TMP/gh.zip"
    unzip -q "$TMP/gh.zip" -d "$TMP"
    mkdir -p "$HOME/.local/bin"
    cp "$(find "$TMP" -type f -path '*/bin/gh' | head -1)" "$HOME/.local/bin/gh"
    chmod +x "$HOME/.local/bin/gh"
    export PATH="$HOME/.local/bin:$PATH"
    grep -q '.local/bin' "$HOME/.zshrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  fi
fi

# 2. Sign in (opens the browser once)
if ! gh auth status >/dev/null 2>&1; then
  echo ""
  echo "Signing in to GitHub. Press Enter, copy the code shown, and confirm in the browser."
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git

# 3. Git identity for this repo
LOGIN=$(gh api user --jq .login)
ID=$(gh api user --jq .id)
NAME=$(gh api user --jq '.name // .login')

# 4. Create the repository
if [ ! -d .git ]; then
  git init -q -b main
fi
git config user.name "$NAME"
git config user.email "${ID}+${LOGIN}@users.noreply.github.com"
git add -A
git commit -q -m "Duo: Telegram, Instagram and Slack in one window" || true

if ! git remote get-url origin >/dev/null 2>&1; then
  REPO=duo
  if gh repo view "$LOGIN/$REPO" >/dev/null 2>&1; then REPO=duo-app; fi
  gh repo create "$REPO" --private --source . --remote origin --push \
    --description "Telegram, Instagram and Slack in one macOS window"
else
  git push -u origin main
fi

echo ""
echo "Done: $(gh repo view --json url --jq .url)"
