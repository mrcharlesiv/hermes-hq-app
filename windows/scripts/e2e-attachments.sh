#!/bin/zsh
# End-to-end test of Hermes.Core's photos and files against the attachments fixture (scripts/fixtures/attachments-gateway.py,
# which loads the reference performance fixture): upload-stream, image.attach / file.attach, prompt.submit, staging
# clean-up, history rows with pictures and files, /api/fs/download, generated images, upload failures and Stop.
# Usage: windows/scripts/e2e-attachments.sh     (HQW_E2E_ATTACH_PORT, default 9760)
# The fixture's invented credentials go to windows/build/fixtures/e2e-attach.json (0600, never printed).
set -e
cd "$(dirname "$0")/.."
PORT=${HQW_E2E_ATTACH_PORT:-9760}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is busy; set HQW_E2E_ATTACH_PORT"; exit 1; fi
rm -f $FIX/e2e-attach.json
python3 ${HQW_FIXTURES:-$PWD/ci/fixtures}/attachments-gateway.py --port $PORT --credentials $FIX/e2e-attach.json \
  --files $PWD/$FIX/e2e-attach-files > $FIX/e2e-attach.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-attach.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-attach.json ]] || { echo "fixture did not start (see windows/$FIX/e2e-attach.log)"; exit 1; }
DOTNET=${DOTNET:-$(command -v dotnet || echo $HOME/.dotnet/dotnet)}
HQW_E2E_ATTACH_CREDENTIALS=$PWD/$FIX/e2e-attach.json DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  $DOTNET test HermesHQ.sln --filter Category=E2E-Attachments --logger "console;verbosity=normal"
