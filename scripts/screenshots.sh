#!/bin/bash
#
# screenshots.sh — capture App Store screenshots from the iOS Simulator.
#
# Builds OrbitDeck for the simulator, then for each device size launches the app
# straight to each screen (via the `-odScreen <rawValue>` launch argument that
# RootView reads) with a clean 9:41 status bar, and captures a native-resolution PNG.
#
# Output: Screenshots/<device-tag>/<screen>.png
# Requires: Xcode + the iPhone 17 Pro Max and iPad Pro 13-inch simulators.
#
# The Radio / SSTV / FT4 screens are intentionally NOT captured here — they show
# "connect an interface" empty states in a bare simulator; shoot those on a device.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.prstoetzer.OrbitDeckIOS"
SCHEME="OrbitDeckIOS"
PROJ="OrbitDeckIOS.xcodeproj"
DD="build/screenshots"
OUT="Screenshots"
RENDER_WAIT="${RENDER_WAIT:-7}"     # seconds to let a screen settle before capture

SCREENS=(home track globe radar passes schedule groundtrack)
DEVICES=(
  "iPhone 17 Pro Max|iphone-6.9"
  "iPad Pro 13-inch (M5)|ipad-13"
)

echo "▸ Building $SCHEME for the simulator…"
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
  -sdk iphonesimulator -derivedDataPath "$DD" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build >/dev/null
APP="$(find "$DD/Build/Products" -maxdepth 3 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "✗ Built .app not found"; exit 1; }
echo "  app: $APP"

for entry in "${DEVICES[@]}"; do
  NAME="${entry%%|*}"; TAG="${entry##*|}"
  UDID="$(xcrun simctl list devices available | grep -F "$NAME (" | head -1 | grep -oiE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')"
  [ -n "$UDID" ] || { echo "✗ $NAME not found — skipping"; continue; }
  echo "▸ $NAME ($UDID)"
  mkdir -p "$OUT/$TAG"

  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl location "$UDID" set 39.93,-74.89 2>/dev/null || true
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true

  for S in "${SCREENS[@]}"; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -odScreen "$S" >/dev/null
    sleep "$RENDER_WAIT"
    xcrun simctl io "$UDID" screenshot "$OUT/$TAG/$S.png" >/dev/null
    echo "  ✓ $TAG/$S.png"
  done

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
done

echo "▸ Done → $OUT/"
