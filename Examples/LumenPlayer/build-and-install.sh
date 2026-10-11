#!/bin/bash
set -euo pipefail

# Usage: LUMEN_DEVELOPMENT_TEAM=TEAM_ID LUMEN_BUNDLE_ID=BUNDLE_ID ./build-and-install.sh DEVICE_ID
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE_ID="${1:?Usage: ./build-and-install.sh DEVICE_ID}"
TEAM="${LUMEN_DEVELOPMENT_TEAM:?Set LUMEN_DEVELOPMENT_TEAM to the team that signs the app}"
BUNDLE_ID="${LUMEN_BUNDLE_ID:?Set LUMEN_BUNDLE_ID to a bundle identifier that team can sign}"
xcodegen generate --spec "$APP_DIR/project.yml"
xcodebuild -project "$APP_DIR/LumenPlayer.xcodeproj" -scheme LumenPlayer \
  -destination "generic/platform=tvOS" -derivedDataPath "$APP_DIR/DerivedData" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build > "$APP_DIR/build.log" 2>&1 \
  || { tail -n 30 "$APP_DIR/build.log"; echo "Build failed; see $APP_DIR/build.log" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE_ID" \
  "$APP_DIR/DerivedData/Build/Products/Debug-appletvos/LumenPlayer.app"
