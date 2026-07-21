#!/bin/bash
set -euo pipefail

APP_NAME="SoTellMe"
BUNDLE_ID="com.ngoujon.sotellme"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

echo "==> Compiling ($APP_NAME, release)..."
swift build -c release --package-path "$ROOT_DIR"

echo "==> Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/AppResources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Bundle resources produced by SwiftPM (e.g. vocab_corrections.json) so
# Bundle.module resolves correctly inside the packaged .app too.
BUNDLE_RESOURCES="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$BUNDLE_RESOURCES" ]; then
    cp -R "$BUNDLE_RESOURCES" "$APP_DIR/Contents/Resources/"
fi

echo "==> Code signing (stable local identity)..."
# Signing with a real (even self-signed) identity instead of ad-hoc (`-`)
# gives the app a stable Team/cert-based designated requirement, so TCC
# (Micro/Accessibilité/Surveillance des entrées) keeps its grants across
# rebuilds instead of invalidating them on every new binary hash.
SIGN_IDENTITY="SoTellMe Local Dev"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "!! Identité '$SIGN_IDENTITY' introuvable dans le trousseau, repli sur signature ad-hoc." >&2
    echo "!! Les permissions devront être ré-accordées à chaque build." >&2
    SIGN_IDENTITY="-"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Relance de l'app..."
killall "$APP_NAME" 2>/dev/null || true
sleep 0.5
open "$APP_DIR"

echo "==> Done: $APP_DIR"
