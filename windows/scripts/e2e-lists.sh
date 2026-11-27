#!/bin/zsh
# End-to-end test of the Bots and Sessions lists (Hermes.Core.Bots, Hermes.Core.Sessions) against this repo's stand-in
# gateways: scripts/fixtures/botslist-gateway.py (pin, hide, sections, Edit Bot, New Bot, Duplicate, Delete) and
# scripts/fixtures/sessions-gateway.py (the sidebar, filters, projects, fenced edits, archive, compose).
# Usage: windows/scripts/e2e-lists.sh     (HQW_E2E_LISTS_PORT, default 9770; HQN_REF, the reference repo)
# The fixtures' invented credentials go to windows/build/fixtures/ (0600, never printed).
set -e
cd "$(dirname "$0")/.."
PORT=${HQW_E2E_LISTS_PORT:-9770}
SPORT=$((PORT+1))
export HQN_REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
for p in $PORT $SPORT; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is busy; set HQW_E2E_LISTS_PORT"; exit 1; fi
done
rm -f $FIX/e2e-botslist.json $FIX/e2e-sessions.json
python3 ${HQW_FIXTURES:-$PWD/ci/fixtures}/botslist-gateway.py --port $PORT --hermes-cookies --credentials $FIX/e2e-botslist.json > $FIX/e2e-botslist.log 2>&1 &
BPID=$!
python3 ${HQW_FIXTURES:-$PWD/ci/fixtures}/sessions-gateway.py --port $SPORT --credentials $FIX/e2e-sessions.json > $FIX/e2e-sessions.log 2>&1 &
SPID=$!
trap 'kill $BPID $SPID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-botslist.json && -s $FIX/e2e-sessions.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$SPORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-botslist.json && -s $FIX/e2e-sessions.json ]] || { echo "fixtures did not start (see windows/$FIX/e2e-*.log)"; exit 1; }
DOTNET=${DOTNET:-$(command -v dotnet || echo $HOME/.dotnet/dotnet)}
HQW_E2E_BOTSLIST=$PWD/$FIX/e2e-botslist.json HQW_E2E_SESSIONS=$PWD/$FIX/e2e-sessions.json DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  $DOTNET test HermesHQ.sln --filter "Category=E2E&FullyQualifiedName~ListsEndToEnd" --logger "console;verbosity=normal"
