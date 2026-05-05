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
SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "✗ Не найден бинарник: $EXECUTABLE_PATH" >&2
    exit 1
fi

echo "→ Бинарник: $EXECUTABLE_PATH"

echo "→ Упаковка .app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
else
    echo "✗ Sparkle.framework не найден ($SPARKLE_FRAMEWORK). Запустите 'swift package resolve'." >&2
    exit 1
fi

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

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-keySwitcher Open Source}"
if security find-certificate -c "$CODESIGN_IDENTITY" >/dev/null 2>&1; then
    echo "→ Sign with self-signed cert: ${CODESIGN_IDENTITY}"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "→ Cert not found: ${CODESIGN_IDENTITY} — ad-hoc fallback (AX permission will reset on update)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "→ Готово: $APP_BUNDLE"
echo
echo "Запуск:    open $APP_BUNDLE"
echo "Установка: cp -R $APP_BUNDLE /Applications/"
