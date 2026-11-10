#!/bin/zsh
# Runs only the diagnostics-stream unit suites (Tests/Diagnostics) on the given simulator. Usage: scripts/diagnostics-unit.sh <SIM_UDID> [Suite…]
# With no suite names it runs every suite of Tests/Diagnostics. Derived data stays in ./build/dd (as scripts/build.sh).
set -e
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID}; shift || true
[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
SUITES=("$@")
if (( ${#SUITES} == 0 )); then
  SUITES=($(grep -h -o -E '^(@Suite(\([^)]*\))? )?(struct|final class|class) [A-Za-z0-9_]+Tests' Tests/Diagnostics/*.swift | awk '{print $NF}' | sort -u))
fi
ONLY=()
for suite in $SUITES; do ONLY+=("-only-testing:HermesHQNativeTests/$suite"); done
xcodegen generate -q
mkdir -p build
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd -parallel-testing-enabled NO -collect-test-diagnostics never test $ONLY -quiet > build/last-diagnostics-unit.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td build/dd/Logs/Test/Test-HermesHQNative-*.xcresult 2>/dev/null | grep -v 'HermesHQNativeUI' | head -1)
python3 scripts/e2e-summary.py "$RESULT" > build/last-diagnostics-unit.txt 2>/dev/null || true
grep -v -E ': Passed \(' build/last-diagnostics-unit.txt | head -80
echo "$(grep -c ': Passed (' build/last-diagnostics-unit.txt) passed, $(grep -c -E ': (Failed|Expected Failure) \(' build/last-diagnostics-unit.txt) failed (every case: build/last-diagnostics-unit.txt)"
grep -E 'error:' build/last-diagnostics-unit.log | grep -v appintentsmetadataprocessor | head -20
echo "diagnostics unit tests exit $STATUS"; exit $STATUS
