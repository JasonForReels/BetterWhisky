#!/bin/bash
#
# release.sh
#
# This file is part of Whisky.
#
# Whisky is free software: you can redistribute it and/or modify it under the terms
# of the GNU General Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with Whisky.
# If not, see https://www.gnu.org/licenses/.
#
# Releases BetterWhisky: builds, signs with Developer ID, notarizes and staples
# a DMG, signs it for the in-app updater, adds it to appcast.xml, publishes a
# GitHub release with the DMG, and pushes the updated feed.
#
# Prerequisites (one time):
#   - "Developer ID Application: Jason Smith (MZT889Z6FM)" in the Keychain
#   - Notary credentials stored as "BetterWhisky":
#       xcrun notarytool store-credentials BetterWhisky \
#           --apple-id <your Apple ID> --team-id MZT889Z6FM
#     (it asks for an app-specific password from appleid.apple.com)
#   - The updater signing key in the Keychain under the account "BetterWhisky"
#     (created with Sparkle's generate_keys --account BetterWhisky)
#   - gh signed in as JasonForReels
#
# Usage: scripts/release.sh <version> [--no-publish]
# Example: scripts/release.sh 1.0.0

set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--no-publish]}"
PUBLISH=true
[ "${2:-}" = "--no-publish" ] && PUBLISH=false

NOTARY_PROFILE="${NOTARY_PROFILE:-BetterWhisky}"
SIGNING_IDENTITY="Developer ID Application: Jason Smith (MZT889Z6FM)"
SPARKLE_ACCOUNT="BetterWhisky"
REPO="JasonForReels/BetterWhisky"
# Sparkle compares build numbers, so every release gets a larger one.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
ARCHIVE_PATH="$BUILD_DIR/BetterWhisky.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
UPDATES_DIR="$BUILD_DIR/updates"
DMG_NAME="BetterWhisky-$VERSION.dmg"
DMG_PATH="$UPDATES_DIR/$DMG_NAME"

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR" "$UPDATES_DIR"

SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "Sparkle tools not found: build the project in Xcode once"; exit 1; }

echo "==> Archiving BetterWhisky $VERSION (build $BUILD_NUMBER)"
xcodebuild \
    -project Whisky.xcodeproj \
    -scheme Whisky \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

echo "==> Exporting and signing with Developer ID"
rm -rf "$EXPORT_PATH"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist scripts/exportOptions.plist \
    -allowProvisioningUpdates

APP_PATH="$EXPORT_PATH/BetterWhisky.app"
[ -d "$APP_PATH" ] || { echo "BetterWhisky.app not found at $APP_PATH"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Building DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "BetterWhisky" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Signing DMG"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Submitting to notary service (this can take several minutes)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" || true

echo "==> Adding the release to appcast.xml"
# generate_appcast keeps the items already in the feed and adds this DMG,
# signed with the BetterWhisky key from the Keychain.
cp appcast.xml "$UPDATES_DIR/appcast.xml"
"$SPARKLE_BIN/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    "$UPDATES_DIR"
cp "$UPDATES_DIR/appcast.xml" appcast.xml

echo
echo "Build artifact: $DMG_PATH"
shasum -a 256 "$DMG_PATH"

if [ "$PUBLISH" = false ]; then
    echo "Not published (--no-publish). appcast.xml is updated locally."
    exit 0
fi

echo "==> Publishing GitHub release v$VERSION on $REPO"
gh release create "v$VERSION" "$DMG_PATH" \
    --repo "$REPO" \
    --title "BetterWhisky $VERSION" \
    --generate-notes

echo "==> Publishing the update feed"
git add appcast.xml
git commit -m "Release $VERSION"
git push

echo "Released BetterWhisky $VERSION."
