#!/bin/bash
# Собирает Duo для отправки другому человеку: универсальная сборка (Apple Silicon + Intel) в одном файле Duo.dmg.
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Нужны инструменты разработчика Apple. Запусти: xcode-select --install"
  exit 1
fi

echo "Собираю для Apple Silicon и Intel..."
rm -rf dist
mkdir -p dist/Duo.app/Contents/MacOS dist/Duo.app/Contents/Resources dist/tmp
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 main.swift -o dist/tmp/Duo-arm64
xcrun swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos14.0 main.swift -o dist/tmp/Duo-x86_64
lipo -create dist/tmp/Duo-arm64 dist/tmp/Duo-x86_64 -output dist/Duo.app/Contents/MacOS/Duo
cp Info.plist dist/Duo.app/Contents/Info.plist
cp AppIcon.icns IconLight.png IconDark.png dist/Duo.app/Contents/Resources/
codesign --force --sign - dist/Duo.app

echo "Упаковываю в Duo.dmg..."
mkdir -p dist/dmg
cp -R dist/Duo.app dist/dmg/
ln -s /Applications dist/dmg/Applications
cat > "dist/dmg/How to install - Як встановити.txt" <<'TXT'
ENGLISH
1. Drag Duo onto the Applications folder.
2. Open Duo. macOS will say it can't verify the developer — click "Done".
3. Open System Settings > Privacy & Security, scroll down and click "Open Anyway" next to Duo.
4. Confirm with your password. After that Duo opens normally.
Requires macOS 14 Sonoma or newer.

УКРАЇНСЬКА
1. Перетягни Duo в папку «Програми» (Applications).
2. Відкрий Duo. macOS скаже, що не може перевірити розробника — натисни «Готово».
3. Відкрий Системні параметри > Приватність і безпека, прокрути вниз і натисни «Усе одно відкрити» біля Duo.
4. Підтверди паролем. Після цього Duo відкривається як звичайно.
Потрібна macOS 14 Sonoma або новіша.
TXT
rm -f "$HOME/Downloads/Duo.dmg"
hdiutil create -volname "Duo" -srcfolder dist/dmg -ov -format UDZO "$HOME/Downloads/Duo.dmg" >/dev/null
rm -rf dist/tmp
echo "Готово: ~/Downloads/Duo.dmg"
