#!/bin/zsh
# [offline] The launch screen and the offline screen follow the system's light and dark appearance, at the first frame
# and live (docs/spec/3x-offline.md §3.3, row L109). This is checked here, outside XCTest, because an app launched by a
# UI test keeps the appearance the simulator had when the test session began (see UITests/offline/OfflineEndToEndTests).
# Usage: scripts/offline-appearance-check.sh SIM_UDID
#   Needs the app already built (scripts/build.sh build SIM_UDID). Starts the offline stand-in on
#   127.0.0.1:${HQN_OFFLINE_PORT:-9980} with its control port one above (9980-9989 only; refuses a busy port), signs the
#   app in to it once, then photographs the launch screen, the offline screen and the sign-in screen while switching
#   the simulator between dark and light (and the offline screen with Appearance saved as Dark), and reads the page
#   colour from each screenshot. Screens go to build/shots/appearance-*.png. Takes about two minutes.
#   Leaves the simulator light and stops the stand-in. Use your own simulator, never one signed in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/offline-appearance-check.sh SIM_UDID}
PORT=${HQN_OFFLINE_PORT:-9980}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots}
DD=${HQN_DD:-build/dd}
BUNDLE=${HQN_BUNDLE:-com.charlesmcdowell.hermeshq.native}
APP=$DD/Build/Products/Debug-iphonesimulator/HermesHQNative.app
[[ -d $APP ]] || { echo "no built app at $APP (run scripts/build.sh build $SIM first)"; exit 1; }
mkdir -p $FIX $SHOTS && chmod 700 $FIX
if [[ -z "$HQN_ANY_PORT" ]] && (( PORT < 9980 || PORT + 1 > 9989 )); then echo "HQN_OFFLINE_PORT must leave two ports inside 9980-9989"; exit 1; fi
for p in $PORT $((PORT + 1)); do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use"; exit 1; fi
done
CRED=$FIX/appearance-check.json
CTL=http://127.0.0.1:$((PORT + 1))
rm -f $CRED
python3 scripts/fixtures/offline-gateway.py --port $PORT --control-port $((PORT + 1)) --credentials $CRED > $FIX/appearance-check.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true; xcrun simctl ui "$SIM" appearance light >/dev/null 2>&1 || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $CRED ]] && lsof -nP -iTCP:$((PORT + 1)) -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $CRED ]] || { echo "the stand-in did not start (see $FIX/appearance-check.log)"; exit 1; }

field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" $CRED $1; }
control() { curl -s -m 5 -X POST -H 'content-type: application/json' -d "$2" $CTL/__fixture/$1 >/dev/null; }
# simctl returns before the simulator has switched: on this Mac the change reached a running app one to three seconds
# later. So a launch waits for the switch to settle first, and a live check allows the screen up to ten seconds.
settle() { xcrun simctl ui "$SIM" appearance $1; sleep 6; }
FAILED=0
# The page colour of a screenshot: the pixel 10 px in from the left, a third of the way down (clear of the icon,
# the card and the buttons on these screens). Dark is under 70, light is over 200 (the mean of red, green and blue).
level() {
  xcrun simctl io "$SIM" screenshot "$1" >/dev/null 2>&1
  python3 - "$1" <<'PY'
import os, struct, subprocess, sys, tempfile
out = tempfile.mktemp(suffix='.bmp')
subprocess.run(['sips', '-s', 'format', 'bmp', sys.argv[1], '--out', out], capture_output=True, check=True)
d = open(out, 'rb').read(); os.unlink(out)
off = struct.unpack('<I', d[10:14])[0]; w, h = struct.unpack('<ii', d[18:26]); bpp = struct.unpack('<H', d[28:30])[0] // 8
stride = (w * bpp + 3) & ~3
row = (abs(h) - 1 - abs(h) // 3) if h > 0 else abs(h) // 3
i = off + row * stride + 10 * bpp
print(round((d[i] + d[i + 1] + d[i + 2]) / 3))
PY
}
check() {   # name, wanted (dark|light), what, seconds to allow (default 0: it must be so now)
  local file="$SHOTS/appearance-$1.png" started=$SECONDS value
  while true; do
    value=$(level "$file")
    if [[ ( $2 == dark && $value -lt 70 ) || ( $2 == light && $value -gt 200 ) ]]; then
      echo "ok    $3: $2 (page colour $value${4:+, $((SECONDS - started)) s after the switch})"; return
    fi
    (( SECONDS - started >= ${4:-0} )) && break
    sleep 0.5
  done
  echo "FAIL  $3: wanted $2, page colour $value (see $file)"; FAILED=1
}
live() {    # mode, name, what: switch the simulator while the screen is up; the screen follows within ten seconds
  xcrun simctl ui "$SIM" appearance $1
  check $2 $1 "$3" 10
}

xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
xcrun simctl ui "$SIM" appearance light
xcrun simctl install "$SIM" $APP
xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true
# Sign in to the stand-in once (test credentials it wrote for this run; never printed).
SIMCTL_CHILD_HQN_SIGNIN_URL=$(field url) SIMCTL_CHILD_HQN_SIGNIN_USERNAME=$(field username) SIMCTL_CHILD_HQN_SIGNIN_PASSWORD=$(field password) \
  xcrun simctl launch "$SIM" $BUNDLE -HQDebugResetAccounts YES >/dev/null
sleep 12
xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true

# 1. The launch screen: dark at the first frame, then light and dark again while it is up.
settle dark
xcrun simctl launch "$SIM" $BUNDLE -HQDebugResetCaches YES -HQDebugLaunchHold 40 >/dev/null
sleep 2
check launch-dark-first dark "launch screen, simulator dark before the launch"
live light launch-live-light "launch screen after switching to light while it is up"
live dark launch-live-dark "launch screen after switching back to dark"
xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true

# 2. The offline screen: the same three, with the gateway answering 503.
control mode '{"mode":"status","status":503}'
xcrun simctl launch "$SIM" $BUNDLE -HQDebugResetCaches YES >/dev/null
sleep 9
check offline-dark-first dark "offline screen, simulator dark before the launch"
live light offline-live-light "offline screen after switching to light while it is up"
live dark offline-live-dark "offline screen after switching back to dark"
xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true

# 3. And from light: a launch in light is light at the first frame.
settle light
xcrun simctl launch "$SIM" $BUNDLE -HQDebugResetCaches YES >/dev/null
sleep 9
check offline-light-first light "offline screen, simulator light before the launch"

xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true

# 4. A saved Dark wins over the system: the offline screen stays dark while the system is light, dark, light again.
xcrun simctl launch "$SIM" $BUNDLE -HQDebugResetCaches YES -hqn.appearance dark >/dev/null
sleep 9
check offline-saved-dark-system-light dark "offline screen with Appearance saved as Dark, system light"
settle dark
check offline-saved-dark-system-dark dark "the same with the system dark"
settle light
check offline-saved-dark-after-switches dark "the same after the system went light again"
xcrun simctl terminate "$SIM" $BUNDLE >/dev/null 2>&1 || true

# 5. The sign-in screen (no saved sign-in): light, then dark and light again while it is up.
control mode '{"mode":"up"}'
xcrun simctl launch "$SIM" $BUNDLE -HQDebugResetAccounts YES >/dev/null
sleep 6
check sign-in-light-first light "sign-in screen, simulator light before the launch"
live dark sign-in-live-dark "sign-in screen after switching to dark while it is up"
live light sign-in-live-light "sign-in screen after switching back to light"

if (( FAILED )); then echo "appearance check: FAILED"; exit 1; fi
echo "appearance check: passed (screens in $SHOTS/appearance-*.png)"
