#!/bin/zsh
# [mac] Build the Mac app (Mac Catalyst) and optionally open it. Usage: scripts/build-mac.sh [build|run] [Debug|Release]
# Uses ./build/dd-mac as derived data (./build/dd-mac-original for HQ_IDENTITY=original: both apps are "Hermes HQ.app").
# Signs with the team's development certificate and a Mac Catalyst development profile, which the Keychain needs
# (-allowProvisioningUpdates with the App Store Connect key in ~/.appstoreconnect/dispatch.env, as ship.py, lets Xcode
# make it). The app lands in $DD/Build/Products/<config>-maccatalyst/Hermes HQ.app (the iPhone build stays
# HermesHQNative.app).
# HQ_IDENTITY=original builds the Hermes HQ record's app, as scripts/build.sh.
# `run` in Debug passes HQN_SIGNIN_URL / HQN_SIGNIN_USERNAME / HQN_SIGNIN_PASSWORD through from this shell, so a signed-out
# app signs in to a fixture by itself (SignInService.debugSignInFromEnvironment).
set -e
cd "$(dirname "$0")/.."
# [duo] Xcode 27.2 as scripts/ship.py (the Duo's sensor column); DEVELOPER_DIR set by the caller wins.
[[ -z $DEVELOPER_DIR && -d /Applications/Xcode-27.2.app ]] && export DEVELOPER_DIR=/Applications/Xcode-27.2.app/Contents/Developer
ACTION=${1:-build}; CONFIG=${2:-Debug}
[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
DD=build/dd-mac${HQ_ORIGINAL:+-original}
xcodegen generate -q
mkdir -p build
AUTH=()
ENVFILE=~/.appstoreconnect/dispatch.env
if [[ -r $ENVFILE ]]; then
  KEYS=("${(@f)$(python3 -c '
import pathlib, shlex, sys
values = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    line = line.strip().removeprefix("export ")
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1); parts = shlex.split(v, comments=True); values[k.strip()] = parts[0] if parts else ""
print(pathlib.Path(values["ASC_KEY_PATH"]).expanduser()); print(values["ASC_KEY_ID"]); print(values["ASC_ISSUER_ID"])' $ENVFILE)}")
  AUTH=(-authenticationKeyPath $KEYS[1] -authenticationKeyID $KEYS[2] -authenticationKeyIssuerID $KEYS[3])
fi
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -configuration $CONFIG \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath $DD -allowProvisioningUpdates $AUTH \
  build -quiet > build/last-mac-build.log 2>&1 && STATUS=0 || STATUS=$?
grep -v -E '^(note:|\s*$)|appintentsmetadataprocessor' build/last-mac-build.log | tail -80
echo "xcodebuild mac build exit $STATUS"
[[ $STATUS -eq 0 ]] || exit $STATUS
APP="$DD/Build/Products/$CONFIG-maccatalyst/Hermes HQ.app"
echo "app: $APP"
if [[ $ACTION == run ]]; then
  pkill -x 'Hermes HQ' 2>/dev/null && sleep 1 || true
  # Through Launch Services (not as this shell's child), so the app runs as it would from the Finder.
  ENVS=()
  for name in HQN_SIGNIN_URL HQN_SIGNIN_USERNAME HQN_SIGNIN_PASSWORD; do [[ -n ${(P)name} ]] && ENVS+=(--env "$name=${(P)name}"); done
  open -n $ENVS "$APP"
  echo "opened"
fi
