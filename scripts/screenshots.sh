#!/bin/bash
#
# screenshots.sh — capture App Store screenshots from the iOS Simulator.
#
# Builds OrbitDeck for the simulator, then for each device size launches the app
# straight to each screen (via the `-odScreen <rawValue>` launch argument that
# RootView reads) in dark appearance with a clean 9:41 status bar, and captures a
# native-resolution PNG. Home's digital-mode cards are shot by also passing
# `-odHomeScroll <sstv|ft4|cw|packet>` (DEBUG builds only, hence CONFIG=Debug), which
# scrolls Home to that card a few seconds after launch.
#
# Output: Screenshots/<device-tag>/<NN>-<name>.png — the numeric prefix is the App Store
#         order. Each run replaces the PNGs in those folders.
# Requires: Xcode + the iPhone 18 Pro Max (1320×2868, the 6.9" set) and
#           iPad Pro 13-inch (M5) (2064×2752) simulators. Override with
#           IPHONE_SIM / IPAD_SIM (simulator names) to shoot on dedicated devices.
#
# The Radio screen and the live SSTV / FT4 / CW / Packet decoders are intentionally
# NOT captured — they need a connected interface; shoot those on a device. With the
# feature flags below forced to "always", Home still shows the FT4 / CW / Packet
# (and SSTV) cards with their pass-planning content, which is what the 1.1 set uses.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.prstoetzer.OrbitDeckIOS"
SCHEME="OrbitDeckIOS"
PROJ="OrbitDeckIOS.xcodeproj"
CONFIG="${CONFIG:-Debug}"           # Debug: -odHomeScroll only exists in DEBUG builds
DD="build/screenshots"
OUT="Screenshots"
RENDER_WAIT="${RENDER_WAIT:-9}"     # seconds to let a card screen settle before capture
SCROLL_WAIT="${SCROLL_WAIT:-12}"    # Home card shots: -odHomeScroll fires ~4 s after launch
HEAVY_WAIT="${HEAVY_WAIT:-22}"      # full-bleed GPU screens (globe/radar/map) need longer to
                                    # composite their first frame, esp. on the 13" iPad
WARMUP_WAIT="${WARMUP_WAIT:-25}"    # first launch fetches the GP catalog from the network
HEAVY_SCREENS=" globe radar groundtrack skymap "   # need HEAVY_WAIT

# Show every Home digital-mode card even without an audio interface attached.
FEATURE_ARGS=(-feature.sstv always -feature.ft4 always -feature.cw always -feature.packet always)

# Selected satellite per shot (written into the stored preferences before launch, as the
# demo seed keeps any selection among its favorites). LIVE_NORAD is for the live screens:
# set it to a demo favorite that is mid-pass at 39.93,-74.89 when you run this (ISS 25544,
# SO-50 27607, AO-91 43017, RS-44 44909, AO-73 39444) — they look far livelier then
# (the Daily Schedule screen lists the coming passes). Default: RS-44, a linear transponder.
LIVE_NORAD="${LIVE_NORAD:-44909}"
LINEAR_NORAD="${LINEAR_NORAD:-44909}"   # FT4 / CW cards: a linear transponder (RS-44)
PACKET_NORAD="${PACKET_NORAD:-25544}"   # Packet card: the ISS APRS digipeater
# Auto Switching shot: a demo priority list, switching on. Written before that shot only
# and removed after it, so it can't change the selection on the other screens.
AUTOSWITCH_JSON='{"enabled":true,"priorities":[44909,27607,43017,25544,39444],"useGlobalMinElevation":true,"minElevation":10,"preemption":"atRise","preemptElevation":0,"holdManualSelection":false}'

# The 1.1 App Store lineup (10 max), in order:
# "<file name>|<odScreen>|<odHomeScroll card or empty>|<selected NORAD>".
SCREENS=(
  "01-home|home||$LIVE_NORAD"
  "02-ft4|home|ft4|$LINEAR_NORAD"
  "03-cw|home|cw|$LINEAR_NORAD"
  "04-packet|home|packet|$PACKET_NORAD"
  "05-autoswitch|autoswitch||$LIVE_NORAD"
  "06-track|track||$LIVE_NORAD"
  "07-globe|globe||$LIVE_NORAD"
  "08-radar|radar||$LIVE_NORAD"
  "09-passes|passes||$LIVE_NORAD"
  "10-satellites|satellites||$LIVE_NORAD"
)
# Optional extras, captured after the lineup when EXTRAS=1 (not part of the App Store set).
EXTRA_SCREENS=(
  "schedule|schedule||$LIVE_NORAD"
  "groundtrack|groundtrack||$LIVE_NORAD"
  "skymap|skymap||$LIVE_NORAD"
  "sstv|home|sstv|$LIVE_NORAD"
)
[ "${EXTRAS:-0}" = 1 ] && SCREENS+=("${EXTRA_SCREENS[@]}")
# Retake just some shots (space-separated file names, e.g. ONLY="01-home 08-radar"),
# keeping the rest of the folder; a full run replaces every PNG in it.
ONLY="${ONLY:+ $ONLY }"
# Screens left out of the iPad set (space-separated file names) if they read poorly there.
IPAD_SKIP=" ${IPAD_SKIP:-} "

DEVICES=(
  "${IPHONE_SIM:-iPhone 18 Pro Max}|iphone-6.9"
  "${IPAD_SIM:-iPad Pro 13-inch (M5)}|ipad-13"
)

# Store-level settings live in the app's UserDefaults; `simctl spawn defaults` goes through
# the simulator's cfprefsd, so the app sees the change on its next launch.
prefs_domain() { echo "$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data)/Library/Preferences/$BUNDLE_ID"; }
# select_sat <udid> <norad>: set selectedNorad in the stored preferences (app not running).
select_sat() {
  local dom blob
  dom="$(prefs_domain "$1")"
  blob="$(xcrun simctl spawn "$1" defaults export "$dom" - | plutil -extract 'OrbitDeckIOS\.preferences\.v1' raw -o - -)" || return 0
  blob="$(python3 -I -c 'import sys,json,base64; p=json.loads(base64.b64decode(sys.argv[1])); p["selectedNorad"]=int(sys.argv[2]); print(json.dumps(p,separators=(",",":")).encode().hex())' "$blob" "$2")"
  xcrun simctl spawn "$1" defaults write "$dom" OrbitDeckIOS.preferences.v1 -data "$blob"
}
set_autoswitch() {   # set_autoswitch <udid> on|off
  local dom; dom="$(prefs_domain "$1")"
  if [ "$2" = on ]; then
    xcrun simctl spawn "$1" defaults write "$dom" OrbitDeckIOS.autoSwitch -data "$(printf '%s' "$AUTOSWITCH_JSON" | xxd -p | tr -d '\n')"
  else
    xcrun simctl spawn "$1" defaults delete "$dom" OrbitDeckIOS.autoSwitch 2>/dev/null || true
  fi
}

echo "▸ Building $SCHEME ($CONFIG) for the simulator…"
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration "$CONFIG" \
  -sdk iphonesimulator -derivedDataPath "$DD" \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build >/dev/null
APP="$(find "$DD/Build/Products/$CONFIG-iphonesimulator" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "✗ Built .app not found"; exit 1; }
echo "  app: $APP"

for entry in "${DEVICES[@]}"; do
  NAME="${entry%%|*}"; TAG="${entry##*|}"
  UDID="$(xcrun simctl list devices available | grep -F "    $NAME (" | head -1 | grep -oiE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')"
  [ -n "$UDID" ] || { echo "✗ $NAME not found — skipping"; continue; }
  echo "▸ $NAME ($UDID)"
  mkdir -p "$OUT/$TAG"
  [ -n "$ONLY" ] || rm -f "$OUT/$TAG"/*.png

  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcrun simctl ui "$UDID" appearance dark
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl location "$UDID" set 39.93,-74.89 2>/dev/null || true
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true

  # Warm-up launch: seed demo favorites (-odDemo) and let the GP catalog download + cache,
  # so the data screens have content and later launches load instantly from the cache.
  echo "  … warming up catalog"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -odScreen home -odDemo 1 "${FEATURE_ARGS[@]}" >/dev/null
  sleep "$WARMUP_WAIT"
  # A second throwaway launch: right after the simulated location is set, the first launches
  # show the location-in-use arrow next to the clock; it's gone by the next one.
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -odScreen track -odDemo 1 >/dev/null
  sleep "$RENDER_WAIT"

  for shot in "${SCREENS[@]}"; do
    IFS='|' read -r FILE S CARD NORAD <<< "$shot"
    if [ "$TAG" = ipad-13 ] && [[ "$IPAD_SKIP" == *" $FILE "* ]]; then continue; fi
    if [ -n "$ONLY" ] && [[ "$ONLY" != *" $FILE "* ]]; then continue; fi
    ARGS=(-odScreen "$S" -odDemo 1 "${FEATURE_ARGS[@]}")
    [ -n "$CARD" ] && ARGS+=(-odHomeScroll "$CARD")
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    [ -n "$NORAD" ] && select_sat "$UDID" "$NORAD"
    if [ "$S" = autoswitch ]; then set_autoswitch "$UDID" on; else set_autoswitch "$UDID" off; fi
    xcrun simctl launch "$UDID" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
    if [ -n "$CARD" ]; then sleep "$SCROLL_WAIT"
    elif [[ "$HEAVY_SCREENS" == *" $S "* ]]; then sleep "$HEAVY_WAIT"
    else sleep "$RENDER_WAIT"; fi
    xcrun simctl io "$UDID" screenshot "$OUT/$TAG/$FILE.png" >/dev/null 2>&1
    echo "  ✓ $TAG/$FILE.png ($(sips -g pixelWidth -g pixelHeight "$OUT/$TAG/$FILE.png" | awk '/pixel/{printf "%s ", $2}'))"
  done

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  set_autoswitch "$UDID" off
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
done

echo "▸ Done → $OUT/"
