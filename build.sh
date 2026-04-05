#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HEIC HDR Converter"
APP="$APP_NAME.app"

echo "==> Building heic-convert..."
swiftc -O -o heic-convert swift/heic-convert.swift \
    -framework CoreImage \
    -framework ImageIO \
    -framework CoreGraphics \
    -framework CoreServices \
    -framework Foundation

# Rebuild app bundle if it exists
if [ -d "$APP" ]; then
    echo "==> Updating $APP..."
    swiftc -O -o "$APP/Contents/MacOS/launcher" swift/launcher.swift \
        -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers
    cp heic-convert "$APP/Contents/Resources/heic-convert"
    cp server/app.py "$APP/Contents/Resources/server/app.py"
    cp -R server/public/ "$APP/Contents/Resources/server/public/"
    xattr -cr "$APP" 2>/dev/null
    echo "    Done"
fi

mkdir -p tmp

echo ""
echo "==> Starting server..."
echo "    Open http://localhost:3939"
echo ""
python3 server/app.py
