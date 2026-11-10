#!/bin/zsh
# End-to-end UI tests of the More pages and navigation chrome (UITests/morepages/, docs/spec/3x-morepages.md §20)
# against the morepages stand-in gateway (scripts/fixtures/morepages-gateway.py).
# Usage: scripts/e2e-morepages.sh <SIM_UDID>
#   The simulator is required (this Mac is shared: there is no default; builders use "HQN-m9-morepages").
#   Starts four stand-ins on 127.0.0.1 and stops only what it started; a busy port is refused:
#     main          ${PORTS[1]} (default 10050)   credentials → TEST_RUNNER_HQN_UI_CREDENTIALS
#     settings      ${PORTS[2]} (default 10051)   scripts/fixtures/settings-gateway.py (roster layout writes, U5) → HQN_MORE_SETTINGS
#     old gateway   ${PORTS[3]} (default 10052)   --old-gateway (404 / -32601 for every new route) → HQN_MORE_OLD
#     webhooks off  ${PORTS[4]} (default 10053)   --webhooks-off → HQN_MORE_WH
#   HQN_MOREPAGES_PORTS="10055 10056 10057 10058" moves them (10050-10059 only).
#   HQN_MOREPAGES_GATEWAYS="main wh" starts only those (ports are then given in the same order); tests of a stand-in
#   that was not started skip.
#   HQN_MOREPAGES_ONLY="ProfilesUITests,ChromeUITests/testU1_RepeatBadge" narrows the run (class, or class/test).
#   HQN_SHOTS_DARK=1 runs the pass in the simulator's dark appearance; screenshots are written to build/shots
#   (HQN_SHOTS_DIR) as <name>-light.png / <name>-dark.png. HQN_TEXT_SIZE=UICTContentSizeCategoryAccessibilityL runs at
#   a larger text size (names get its short suffix). Credentials files are 0600 and never printed.
set -e
cd "$(dirname "$0")/.."
SIM=$1
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-morepages.sh <SIM_UDID>"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
GATEWAYS=(${=HQN_MOREPAGES_GATEWAYS:-main settings old wh})
PORTS=(${=HQN_MOREPAGES_PORTS:-10050 10051 10052 10053})
PORTS=(${PORTS[1,${#GATEWAYS}]})
typeset -A PORT_OF
for i in {1..${#GATEWAYS}}; do PORT_OF[$GATEWAYS[$i]]=$PORTS[$i]; done
for port in $PORTS; do
  (( (port >= 10050 && port <= 10059) || (port >= 9880 && port <= 9899) || (port >= 10250 && port <= 10299) )) || { echo "morepages ports are 10050-10059 or 9880-9899"; exit 1; }
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy; stop it first or set HQN_MOREPAGES_PORTS"; exit 1; fi
done
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; [[ "$HQN_SHOTS_DARK" == 1 ]] && xcrun simctl ui $SIM appearance light 2>/dev/null || true' EXIT INT TERM

start() {   # name port extra-flags…
  local name=$1 port=$2; shift 2
  rm -f $FIX/morepages-$name.json
  python3 scripts/fixtures/morepages-gateway.py --port $port --credentials $FIX/morepages-$name.json \
    --files $FIX/morepages-files-$name --tick-seconds 0 "$@" > $FIX/morepages-$name.log 2>&1 &
  PIDS+=($!)
}
for name in $GATEWAYS; do
  case $name in
    main) start main $PORT_OF[main] ;;
    old) start old $PORT_OF[old] --old-gateway ;;
    wh) start wh $PORT_OF[wh] --webhooks-off ;;
    settings)
      rm -f $FIX/morepages-settings.json
      python3 scripts/fixtures/settings-gateway.py --port $PORT_OF[settings] --hermes-cookies --credentials $FIX/morepages-settings.json \
        > $FIX/morepages-settings.log 2>&1 &
      PIDS+=($!) ;;
    *) echo "unknown stand-in $name"; exit 1 ;;
  esac
done
for i in {1..80}; do
  ready=1
  for name in $GATEWAYS; do [[ -s $FIX/morepages-$name.json ]] || ready=0; done
  [[ $ready == 1 ]] && break
  sleep 0.2
done
for name in $GATEWAYS; do
  [[ -s $FIX/morepages-$name.json ]] || { echo "the $name stand-in did not start (see $FIX/morepages-$name.log)"; exit 1; }
done
echo "morepages stand-ins on 127.0.0.1:$PORTS (pids $PIDS)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_MOREPAGES_ONLY" ]]; then
  for t in ${(s:,:)HQN_MOREPAGES_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/$t); done
else
  for class in $(grep -h -o -E '^final class [A-Za-z0-9_]+: MorePagesCase' UITests/morepages/*.swift | awk '{print $3}' | tr -d ':'); do
    ONLY+=(-only-testing:HermesHQNativeUITests/$class)
  done
fi
xcrun simctl boot $SIM 2>/dev/null || true
xcrun simctl ui $SIM appearance $([[ "$HQN_SHOTS_DARK" == 1 ]] && echo dark || echo light)
STATUS=0
creds() { [[ -n "$PORT_OF[$1]" ]] && echo $PWD/$FIX/morepages-$1.json || echo ""; }
TEST_RUNNER_HQN_UI_CREDENTIALS=$(creds main) TEST_RUNNER_HQN_MORE_SETTINGS=$(creds settings) \
TEST_RUNNER_HQN_MORE_OLD=$(creds old) TEST_RUNNER_HQN_MORE_WH=$(creds wh) \
TEST_RUNNER_HQN_MORE_FILES=$PWD/$FIX/morepages-files-main \
TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} TEST_RUNNER_HQN_TEXT_SIZE=${HQN_TEXT_SIZE:-} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-morepages.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-morepages.log | tail -30
echo "morepages e2e: xcodebuild exit $STATUS"
exit $STATUS
