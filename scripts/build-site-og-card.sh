#!/bin/bash
#
# Renders site/og-card.html to site/public/images/og-card.png: the image shown
# when someone shares a link to the website. 1200x630 at 2x (2400x1260).
#
# Usage: scripts/build-site-og-card.sh

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUTPUT="$PROJECT_DIR/site/public/images/og-card.png"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$PROFILE" \
    --window-size=1200,630 --force-device-scale-factor=2 \
    --screenshot="$OUTPUT" "file://$PROJECT_DIR/site/og-card.html" 2>/dev/null
echo "OK: $OUTPUT ($(sips -g pixelWidth -g pixelHeight "$OUTPUT" | awk '/pixel/ {print $2}' | xargs | tr ' ' x))"
