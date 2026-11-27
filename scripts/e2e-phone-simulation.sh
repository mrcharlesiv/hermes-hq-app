#!/bin/zsh
# Phone Calls (Beta) UI acceptance. Dedicated simulator only. Synthetic, loopback-only TLS fixtures; never samplehost.
#   scripts/fixtures/phone-two-logins-gateway.py  the Sessions gateway with two logins (account switching)
#   scripts/fixtures/fake-samplehost.py               a fake samplehost v2 API; the app's DEBUG build reaches it through the
#                                                 launch environment HQ_SAMPLEHOST_BASE_URL=https://127.0.0.1:<port>/v2
# The only key used is the synthetic KEYTEST.
#   zsh scripts/e2e-phone-simulation.sh <simulator udid> [gateway port, default 19978; fake samplehost uses port + 1]
#   HQ_PHONE_TEST=switch runs only the account-switch test; HQ_PHONE_ONLY='<test> …' runs those tests;
#   HQ_PHONE_DERIVED=<folder> reuses a DerivedData folder.
set -eu
cd "${0:A:h}/.."
SIM=${1:?pass a dedicated simulator UDID}
PORT=${2:-19978}
TPORT=$((PORT + 1))
OUT=${HQ_PHONE_ARTIFACTS:-$PWD/.build/phone-simulation}
DERIVED=${HQ_PHONE_DERIVED:-$OUT/DerivedData}
mkdir -p "$OUT/shots"; chmod 700 "$OUT"
for p in $PORT $TPORT; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then print -u2 "fixture port $p busy"; exit 1; fi
done
# Private test keys live in shell memory and pipes. Only the public trust certificate is written.
fixture_root_key=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
fixture_server_key=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
openssl req -new -x509 -key <(print -r -- "$fixture_root_key") -out "$OUT/root.pem" -days 2 \
  -subj '/CN=HQ Phone Simulation Root' -addext 'basicConstraints=critical,CA:TRUE'
fixture_server_request=$(openssl req -new -key <(print -r -- "$fixture_server_key") -subj '/CN=127.0.0.1')
fixture_server_cert=$(openssl x509 -req -in <(print -r -- "$fixture_server_request") -CA "$OUT/root.pem" \
  -CAkey <(print -r -- "$fixture_root_key") -set_serial 1 -days 2 \
  -extfile <(printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n'))
unset fixture_root_key fixture_server_request
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl keychain "$SIM" add-root-cert "$OUT/root.pem"
fixture_a=$(openssl rand -hex 16)
fixture_b=$(openssl rand -hex 16)
HQ_PHONE_FIXTURE_A="$fixture_a" HQ_PHONE_FIXTURE_B="$fixture_b" \
python3 scripts/fixtures/phone-two-logins-gateway.py --port "$PORT" --cert <(print -r -- "$fixture_server_cert") --key <(print -r -- "$fixture_server_key") > "$OUT/gateway.log" 2>&1 &
GPID=$!
python3 scripts/fixtures/fake-samplehost.py --port "$TPORT" --cert <(print -r -- "$fixture_server_cert") --key <(print -r -- "$fixture_server_key") > "$OUT/samplehost.log" 2>&1 &
TPID=$!
trap 'kill $GPID $TPID 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset fixture_server_key fixture_server_cert
for i in {1..100}; do
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$TPORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep .2
done
curl --fail --silent --cacert "$OUT/root.pem" "https://127.0.0.1:$TPORT/__fixture/state" > /dev/null
xcodegen generate -q
tests=(-only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsSimulatedAcceptance -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsAccountSwitch
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsVoicemailInOneSecond -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsQuestionAskedTwice
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsTellTheAssistant -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsHistorySurvivesRelaunch
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsAgentProposal
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsRingingCancel
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsHangUpTakesTwoTaps
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsDesignLight
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsDesignDark
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsLargeText
  -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsTeXMLTrapAndSetupGuide)
if [[ ${HQ_PHONE_TEST:-} == switch ]]; then tests=(-only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsAccountSwitch); fi
if [[ -n ${HQ_PHONE_ONLY:-} ]]; then tests=(); for t in ${=HQ_PHONE_ONLY}; do tests+=(-only-testing:HermesHQNativeUITests/SessionsTests/$t); done; fi
RESULT="$OUT/PhoneAcceptance-$(date +%Y%m%d-%H%M%S).xcresult"
set +e
TEST_RUNNER_HQN_PHONE_GATEWAY="https://127.0.0.1:$PORT" TEST_RUNNER_HQN_PHONE_A="$fixture_a" TEST_RUNNER_HQN_PHONE_B="$fixture_b" \
TEST_RUNNER_HQN_SAMPLEHOST_URL="https://127.0.0.1:$TPORT" TEST_RUNNER_HQN_SHOTS_DIR="$OUT/shots" \
 xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
 -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" \
 -parallel-testing-enabled NO -collect-test-diagnostics never "${tests[@]}" test > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
set -e
curl --fail --silent --cacert "$OUT/root.pem" "https://127.0.0.1:$TPORT/__fixture/state" > "$OUT/final-samplehost-state.json" || true
grep -E "Test Case .*(passed|failed)|Executed [0-9]+ test" "$OUT/xcodebuild.log" | sort -u || true
print "result bundle: $RESULT"
exit $STATUS
