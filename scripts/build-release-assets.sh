#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TAG_OR_VERSION="${1:-}"
if [[ -z "$TAG_OR_VERSION" ]]; then
  if TAG="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null)"; then
    TAG_OR_VERSION="$TAG"
  else
    echo "Usage: $0 <version-or-tag> (example: v1.0.0 or 1.0.0)" >&2
    exit 1
  fi
fi

VERSION="${TAG_OR_VERSION#v}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/notchi-release}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
PROJECT_PATH="$ROOT_DIR/notchi/notchi.xcodeproj"

echo "Building Notchi Release $VERSION"
echo "DerivedData: $DERIVED_DATA_PATH"
echo "Output dir:  $OUT_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme notchi \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Release"
APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' | head -n 1)"

if [[ -z "$APP_PATH" ]]; then
  echo "Failed to locate built app in $PRODUCTS_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

ZIP_PATH="$OUT_DIR/Notchi-$VERSION.zip"
DMG_PATH="$OUT_DIR/Notchi-$VERSION.dmg"

ditto -ck --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

DMG_STAGING="$(mktemp -d /tmp/notchi-dmg-staging.XXXXXX)"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "Notchi" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo "Created:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
