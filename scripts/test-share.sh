#!/bin/zsh
# [share] Runs only the Share extension's unit and fixture tests (Tests/Share), in the Hermes HQ identity unless
# HQ_IDENTITY=native. Usage: scripts/test-share.sh SIM_UDID [Suite ...]
#
# The fixture suite (ShareFixtureTests) runs only while this stream's stand-in gateway is up:
#   python3 scripts/fixtures/share-gateway.py --port 9911 --redirect-port 9913 --credentials build/fixtures/share-it.json \
#       --files build/fixtures/share-it-files --log build/fixtures/share-it.jsonl
# Without it those tests are skipped, never failed. Everything else needs no gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/test-share.sh SIM_UDID [Suite ...]}
shift
SUITES=("$@")
(( ${#SUITES} )) || SUITES=(ShareRulesTests ShareStoreTests ShareKeychainTests ShareFailureTests ShareReachTests ShareMultipartTests
                           ShareMediaTests ShareItemLoaderTests ShareSheetStateTests ShareSenderTests ShareRosterRowsTests
                           ShareRosterWriterTests ShareInboxTests ShareStressTests ShareFixtureTests)
[[ ${HQ_IDENTITY:-original} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
xcodegen generate -q
mkdir -p build
ONLY=()
for suite in $SUITES; do ONLY+=("-only-testing:HermesHQNativeTests/$suite"); done
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd test $ONLY ${HQN_SHARE_IT:+TEST_RUNNER_HQN_SHARE_IT=$HQN_SHARE_IT} \
  > build/last-share-test.log 2>&1 && STATUS=0 || STATUS=$?
grep -E "error:|✘|recorded an issue|Test run with|Suite .* (passed|failed)|\*\* TEST" build/last-share-test.log | cut -c1-400 | tail -120
echo "share tests exit $STATUS"; exit $STATUS
