#!/usr/bin/env bash
# Создаёт DMG-образ с Q*Й.app и symlink на /Applications.
# Использует hdiutil + AppleScript для красивого layout.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_BUNDLE="App/dist/keySwitcher.app"
APP_DISPLAY_NAME="Q*Й"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")}"
DMG_NAME="QY-${VERSION}.dmg"
TMP_DIR=$(mktemp -d)
STAGING="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/temp.dmg"
OUT_DIR="App/dist"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "✗ Не найден $APP_BUNDLE — сначала запусти App/build.sh"
    exit 1
fi

echo "→ Версия: $VERSION"
echo "→ Сборка $DMG_NAME"

mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/$APP_DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"

# Создаём временный read-write DMG
hdiutil create -srcfolder "$STAGING" -volname "$APP_DISPLAY_NAME" \
    -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW \
    -size 200m "$RW_DMG" >/dev/null

# Монтируем чтобы кастомизировать
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | \
         egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT="/Volumes/$APP_DISPLAY_NAME"
sleep 2

# Применяем layout через AppleScript
osascript <<EOF
tell application "Finder"
    tell disk "$APP_DISPLAY_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 900, 540}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$APP_DISPLAY_NAME.app" of container window to {180, 180}
        set position of item "Applications" of container window to {520, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$DEVICE" >/dev/null
sleep 1

# Конвертируем в финальный сжатый readonly
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$DMG_NAME"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 \
    -o "$OUT_DIR/$DMG_NAME" >/dev/null

# Ad-hoc подпись DMG
codesign --force --sign - "$OUT_DIR/$DMG_NAME" 2>/dev/null || true

rm -rf "$TMP_DIR"

SIZE=$(du -h "$OUT_DIR/$DMG_NAME" | cut -f1)
echo "→ Готово: $OUT_DIR/$DMG_NAME ($SIZE)"
