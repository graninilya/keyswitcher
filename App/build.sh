#!/usr/bin/env bash
# Сборка keySwitcher.app из Swift Package.
# Без Xcode, только swift toolchain + ad-hoc подпись.
#
# По умолчанию собирает под нативную arch.
# Universal сборка (для дистрибуции) требует установленного Xcode.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="keySwitcher"
BUILD_DIR=".build"
OUT_DIR="dist"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "→ swift build -c ${CONFIG}…"
swift build -c "$CONFIG"

# Найдём бинарник
EXECUTABLE_PATH=$(swift build -c "$CONFIG" --show-bin-path)/"$APP_NAME"
DICTIONARIES="../dictionaries/processed"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "✗ Не найден бинарник: $EXECUTABLE_PATH" >&2
    exit 1
fi

echo "→ Бинарник: $EXECUTABLE_PATH"

echo "→ Упаковка .app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Копируем JSON-словари в Resources/ (Bundle.main их найдёт)
cp "$DICTIONARIES"/*.json "$APP_BUNDLE/Contents/Resources/"

# Иконка приложения
if [[ -f icons/AppIcon.icns ]]; then
    cp icons/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi

# Иконки menu bar (PDF + retina PNG)
for f in Sources/keySwitcher/Resources/StatusIcon*; do
    [[ -f "$f" ]] && cp "$f" "$APP_BUNDLE/Contents/Resources/"
done

echo "→ Ad-hoc подпись…"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "→ Готово: $APP_BUNDLE"
echo
echo "Запуск:    open $APP_BUNDLE"
echo "Установка: cp -R $APP_BUNDLE /Applications/"
