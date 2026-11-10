#!/bin/zsh
# desktoplook: one screenshot of the app in a given theme state, signed in to the stand-in gateway through the DEBUG
# environment sign-in (never arguments). Usage:
#   scripts/desktoplook-shots.sh <udid> <out.png> <credentials.json> [app path] -- [launch arguments…]
# e.g. scripts/desktoplook-shots.sh $U build/shots/midnight-dark.png build/fixtures/desktoplook-a.json -- \
#        -HQDebugSkin midnight -HQDebugDesktopLook YES -HQDebugAppearance dark -HQDebugOpenBot default
# HQN_SHOT_WAIT (seconds, default 7) is how long the app gets before the picture.
set -e
cd "$(dirname "$0")/.."
U=$1; OUT=$2; CRED=$3; shift 3
APP=build/dd/Build/Products/Debug-iphonesimulator/HermesHQNative.app
if [[ $1 != -- ]]; then APP=$1; shift; fi
shift
BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl terminate $U $BID >/dev/null 2>&1 || true
xcrun simctl install $U "$APP"
eval $(python3 -c "
import json,sys,shlex
c=json.load(open(sys.argv[1]))
print('export SIMCTL_CHILD_HQN_SIGNIN_URL=%s SIMCTL_CHILD_HQN_SIGNIN_USERNAME=%s SIMCTL_CHILD_HQN_SIGNIN_PASSWORD=%s' % tuple(shlex.quote(c[k]) for k in ('url','username','password')))
" "$CRED")
xcrun simctl launch $U $BID "$@" >/dev/null
sleep ${HQN_SHOT_WAIT:-7}
mkdir -p "$(dirname "$OUT")"
xcrun simctl io $U screenshot "$OUT" >/dev/null 2>&1
echo "$OUT"
