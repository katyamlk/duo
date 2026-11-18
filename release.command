#!/bin/bash
# Выпускает новую версию Duo на GitHub: отправляет код, собирает Duo.dmg и выкладывает его в Releases.
set -e
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

echo "1/3 Отправляю код на GitHub..."
bash ./push.command "${1:-}"

echo "2/3 Собираю Duo.dmg..."
bash ./package.command

echo "3/3 Публикую новую версию..."
TAG="v$(date '+%Y.%m.%d-%H%M')"
NOTES="${1:-$(git log -1 --pretty=%s)}"
gh release create "$TAG" "$HOME/Downloads/Duo.dmg" \
  --title "Duo $TAG" \
  --notes "$NOTES" \
  --latest

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
echo ""
echo "Готово! Новая версия: $TAG"
echo "Ссылка, по которой всегда скачивается самая свежая версия:"
echo "https://github.com/$REPO/releases/latest/download/Duo.dmg"
