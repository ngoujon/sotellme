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

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo ""
echo "Prochaines étapes manuelles :"
echo "  1. Ouvre l'app une première fois (clic droit > Ouvrir, car elle n'est pas notarisée)."
echo "  2. Accorde les permissions Micro et Accessibilité dans Réglages Système > Confidentialité et sécurité."
echo "  3. Va dans Réglages Système > Clavier > Raccourcis clavier > Dictée, et désactive le raccourci F5"
echo "     (sinon la dictée macOS se déclenchera en même temps que SoTellMe)."
echo "  4. Appuie sur F5 pour démarrer/arrêter la dictée."
