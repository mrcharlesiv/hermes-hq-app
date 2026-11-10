#!/bin/zsh
# [diagnostics] Build 292: profile the return catch-up of testO29_ALongChatCatchesUpOnReturn (UITests/offline).
# Usage: [WHOLE=1] scripts/catchup-trace.sh SIM_UDID [SHOTS_DIR]   — start it, then in another shell:
#   HQN_ANY_PORT=1 HQN_OFFLINE_PORT=9920 HQN_OFFLINE_APPEARANCE=light HQN_OFFLINE_ONLY=testO29_ALongChatCatchesUpOnReturn \
#     scripts/e2e-offline.sh SIM_UDID
# It waits for the test's "start" marker in the shots folder (the app launched), attaches Instruments' Time Profiler
# (with the app's signposts: category "Main" = MainTrail) to the app until the "done" marker (the chat's opening, the
# send, the time away and the return), writes build/catchup.trace, and then
# prints the main-thread stalls the app logged (`main.hang` lines of its performance-log outbox).
set -e
setopt null_glob
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/catchup-trace.sh SIM_UDID [SHOTS_DIR]}
SHOTS=${2:-$PWD/build/shots}
mkdir -p "$SHOTS"
rm -f "$SHOTS"/catchup-*.marker build/catchup.trace.zip
rm -rf build/catchup.trace
if [[ -n "$WHOLE" ]]; then
  # WHOLE=1: the whole run, every process on the simulator (the test relaunches the app, so no pid to attach to).
  echo "recording the whole simulator"
  xcrun xctrace record --template "Time Profiler" --device "$SIM" --all-processes --time-limit 240s \
    --output build/catchup.trace > build/catchup-xctrace.log 2>&1 &
else
  echo "waiting for the test's app launch…"
  until [[ -f "$SHOTS/catchup-start.marker" ]]; do sleep 0.5; done
  # (By pid: `--attach HermesHQNative` picks the UI-test runner.)
  PID=""
  for _ in {1..40}; do
    PID=$(xcrun simctl spawn "$SIM" launchctl list | awk '/UIKitApplication:com\.charlesmcdowell\.hermeshq\.native\[/ && $1 != "-" {print $1}' | tail -1)
    [[ -n "$PID" ]] && break; sleep 0.25
  done
  [[ -n "$PID" ]] || { echo "app not running"; exit 1; }
  echo "attaching Time Profiler to the app (pid $PID)"
  xcrun xctrace record --template "Time Profiler" --device "$SIM" --attach "$PID" --time-limit 150s \
    --output build/catchup.trace > build/catchup-xctrace.log 2>&1 &
fi
TRACE=$!
until [[ -f "$SHOTS/catchup-done.marker" ]] || ! kill -0 $TRACE 2>/dev/null; do sleep 0.5; done
kill -INT $TRACE 2>/dev/null || true
wait $TRACE 2>/dev/null || true
echo "trace: build/catchup.trace ($(tail -1 build/catchup-xctrace.log))"
DATA=$(xcrun simctl get_app_container "$SIM" com.charlesmcdowell.hermeshq.native data 2>/dev/null || true)
OUTBOX=$(find "$DATA" -name outbox.jsonl 2>/dev/null | head -1)
[[ -n "$OUTBOX" ]] && grep '"k":"main.hang"' "$OUTBOX" | tail -20 || echo "no outbox found"
