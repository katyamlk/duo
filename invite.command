#!/bin/bash
# Даёт человеку доступ к приватному репозиторию Duo (только чтение и скачивание).
set -e
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

USERNAME="$1"
if [ -z "$USERNAME" ]; then
  read -r -p "Логин человека на GitHub: " USERNAME
fi
USERNAME="${USERNAME#@}"

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh api -X PUT "repos/$REPO/collaborators/$USERNAME" -f permission=pull >/dev/null
echo ""
echo "Приглашение отправлено пользователю $USERNAME."
echo "Ему придёт письмо от GitHub — нужно нажать «Accept invitation»."
echo "После этого он сможет скачивать свежую версию по ссылке:"
echo "https://github.com/$REPO/releases/latest/download/Duo.dmg"
