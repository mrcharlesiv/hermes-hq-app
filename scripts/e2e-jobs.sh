#!/bin/zsh
# End-to-end UI tests of the Jobs editor (UITests/jobs/JobEditorTests.swift, docs/spec/3x-jobs.md §8) against the
# jobs stand-in gateway (scripts/fixtures/jobs-gateway.py). Modelled on scripts/e2e-pages.sh.
# Usage: scripts/e2e-jobs.sh <SIM_UDID> [PORT]
#   PORT (default 10000) and PORT+1 must be free and inside 10000-10009; a busy port is refused, never taken.
#   1. the base fixture on PORT            → JobEditorTests (HQN_JOBS_ONLY="testJE05_Delivery,…" narrows it;
#                                            HQN_JOBS_ONLY=long runs only the long-list pass,
#                                            HQN_JOBS_ONLY=dark only the dark pass)
#   2. a --jobs 1000 fixture on PORT+1     → JobEditorLongListTests            (skipped with HQN_JOBS_SKIP_LONG=1)
#   3. the base fixture again, simulator in dark → JobEditorTests/testJE00_Screens  (skipped with HQN_JOBS_SKIP_DARK=1)
#   Credentials are invented by the fixture and written to build/fixtures/jobs*.json (0600, never printed). Screens are
#   written to build/shots/ (HQN_SHOTS_DIR) as e2e-jobs-*.png. Derived data: ${HQN_DD:-build/dd-jobs-ui}, inside the
#   worktree. Stops only the fixtures it started (by pid) and puts the simulator back in light.
#   The simulator must be your own (never the scripts' default, never one signed in to a real gateway).
set -e
cd "$(dirname "$0")/.."
SIM=$1
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-jobs.sh <SIM_UDID> [PORT]"; exit 2; }
PORT=${2:-${HQN_JOBS_PORT:-10000}}
LONG_PORT=$((PORT + 1))
# The release train runs every suite inside 9880-9899; the stream itself keeps 10000-10009.
(( (PORT >= 10000 && LONG_PORT <= 10009) || (PORT >= 9880 && LONG_PORT <= 9899) || (PORT >= 10250 && LONG_PORT <= 10299) )) || { echo "ports must be inside 10000-10009 (or the train's 9880-9899)"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots}
DD=${HQN_DD:-build/dd-jobs-ui}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

start_fixture() {   # port credentials files-dir extra-flags… → sets FIXTURE_PID
  local port=$1 creds=$2 files=$3; shift 3
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is already in use; pass another PORT inside 10000-10009"; exit 1
  fi
  rm -f $creds
  python3 scripts/fixtures/jobs-gateway.py --port $port --credentials $creds --files $files --tick-seconds 0 "$@" > $creds.log 2>&1 &
  FIXTURE_PID=$!
  for i in {1..50}; do
    [[ -s $creds ]] && lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.2
  done
  [[ -s $creds ]] || { echo "fixture did not start (see $creds.log)"; exit 1; }
}

PIDS=()
cleanup() {
  for p in $PIDS; do kill $p 2>/dev/null || true; done
  xcrun simctl ui $SIM appearance light >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath $DD build-for-testing -quiet > build/last-e2e-jobs-build.log 2>&1 \
  || { grep -E "error:" build/last-e2e-jobs-build.log | head -30; echo "jobs e2e: build failed (build/last-e2e-jobs-build.log)"; exit 1; }

FAILED=0
run_tests() {   # label credentials log only-testing…
  local label=$1 creds=$2 log=$3; shift 3
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$creds TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS TEST_RUNNER_HQN_JOBS_SHOT_SUFFIX=$SHOT_SUFFIX \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD test-without-building -quiet "$@" \
    > $log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" $log | tail -20
  echo "jobs e2e ($label): xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
}

# xcodebuild shuts down a simulator it had to boot itself, and the dark pass needs it booted between runs.
xcrun simctl bootstatus $SIM -b >/dev/null 2>&1 || true
xcrun simctl ui $SIM appearance light >/dev/null 2>&1 || true
SHOT_SUFFIX=""
if [[ "$HQN_JOBS_ONLY" != long && "$HQN_JOBS_ONLY" != dark ]]; then
  start_fixture $PORT $FIX/jobs.json $FIX/jobs-files
  PIDS+=($FIXTURE_PID)
  echo "jobs fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"
  ONLY=()
  if [[ -n "$HQN_JOBS_ONLY" ]]; then
    for t in ${(s:,:)HQN_JOBS_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/JobEditorTests/$t); done
  else
    ONLY=(-only-testing:HermesHQNativeUITests/JobEditorTests)
  fi
  run_tests base $FIX/jobs.json build/last-e2e-jobs.log $ONLY
fi

if [[ "$HQN_JOBS_SKIP_DARK" != "1" && ( -z "$HQN_JOBS_ONLY" || "$HQN_JOBS_ONLY" == dark ) ]]; then
  if [[ "$HQN_JOBS_ONLY" == dark ]]; then
    start_fixture $PORT $FIX/jobs.json $FIX/jobs-files
    PIDS+=($FIXTURE_PID)
  fi
  xcrun simctl ui $SIM appearance dark
  SHOT_SUFFIX="-dark"
  run_tests dark $FIX/jobs.json build/last-e2e-jobs-dark.log -only-testing:HermesHQNativeUITests/JobEditorTests/testJE00_Screens
  SHOT_SUFFIX=""
  xcrun simctl ui $SIM appearance light
fi

if [[ "$HQN_JOBS_SKIP_LONG" != "1" && ( -z "$HQN_JOBS_ONLY" || "$HQN_JOBS_ONLY" == long ) ]]; then
  start_fixture $LONG_PORT $FIX/jobs-long.json $FIX/jobs-long-files --jobs 1000
  PIDS+=($FIXTURE_PID)
  echo "long-list fixture on 127.0.0.1:$LONG_PORT (pid $FIXTURE_PID)"
  run_tests long $FIX/jobs-long.json build/last-e2e-jobs-long.log -only-testing:HermesHQNativeUITests/JobEditorLongListTests
fi
exit $FAILED
