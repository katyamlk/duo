#!/bin/bash
# Собирает Duo и кладёт в ~/Applications.
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Нужны инструменты разработчика Apple (Command Line Tools)."
  echo "Сейчас откроется установщик. Когда установка закончится, запусти этот скрипт ещё раз."
  xcode-select --install || true
  exit 1
fi

echo "Собираю..."
pkill -x Duo 2>/dev/null || true
rm -rf build
mkdir -p build/Duo.app/Contents/MacOS
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  main.swift -o build/Duo.app/Contents/MacOS/Duo
cp Info.plist build/Duo.app/Contents/Info.plist
mkdir -p build/Duo.app/Contents/Resources
cp AppIcon.icns IconLight.png IconDark.png build/Duo.app/Contents/Resources/
codesign --force --sign - build/Duo.app

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Duo.app"
cp -R build/Duo.app "$HOME/Applications/"
open "$HOME/Applications/Duo.app"
echo "Готово: Duo запущен."
