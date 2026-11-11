#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="Penlink.app"

# Command Line Tools verwenden (unabhängig vom Zustand von Xcode)
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

# Erst in einem Zwischenordner bauen – die bisherige App bleibt erhalten, falls etwas schiefgeht
TMP=$(mktemp -d)
NEW="$TMP/$APP"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp Info.plist "$NEW/Contents/"

# Symbol aus icon.svg erzeugen
swift svg2png.swift icon.svg "$TMP/icon.png" 1024
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$NEW/Contents/Resources/AppIcon.icns"

# Für Apple Silicon und Intel, zusammengefügt zu einer App
swiftc -O -parse-as-library -target arm64-apple-macos13.0 main.swift -o "$TMP/arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 main.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$NEW/Contents/MacOS/Penlink"

# Ad-hoc signiert, aber über die Bundle-ID erkennbar, damit macOS die Rechte nach einem Neubau behält
codesign --force --sign - -r='designated => identifier "de.bildmonteure.penlink"' "$NEW"

# Erst jetzt die alte App ersetzen
rm -rf "$APP"
mv "$NEW" "$APP"
rm -rf "$TMP"
touch "$APP"

# Zum Weitergeben auf andere Rechner
rm -f Penlink.zip
ditto -c -k --keepParent "$APP" Penlink.zip
echo "Fertig: $(pwd)/$APP"
