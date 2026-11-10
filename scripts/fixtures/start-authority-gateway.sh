#!/bin/bash
# Starts a REAL Hermes v0.23.0 gateway configured as a session authority with a
# gateway-hosted dashboard listener (the "Webapp"), gated behind password sign-in,
# exactly the shape a tester's app talks to (POST /auth/password-login, then
# POST /api/auth/ws-ticket, then a WS upgrade on /api/ws with the ticket in
# Sec-WebSocket-Protocol).
#
# See authority-gateway-README.md in this folder for the full story (how this
# was built, why each config knob is there, and the probe results).
#
# Usage:
#   ./start-authority-gateway.sh        # start in the background
#   ./stop-authority-gateway.sh         # stop it
#
# Credentials: username "tester", password "testpass123"
# Listens on:  http://127.0.0.1:9321  (Host header must be authority-test.local:9321
#              for the sign-in gate to engage -- see README "Why the Host header")
set -euo pipefail

HERMES_WORKTREE="/Users/me/Projects/hermes-agent-v023"
HERMES_HOME_TEST="/tmp/hermes-authority-home"
VENV_PYTHON="$HOME/.hermes/hermes-agent/venv/bin/python"
PORT=9321

mkdir -p "$HERMES_HOME_TEST"

if [ ! -f "$HERMES_HOME_TEST/config.yaml" ]; then
  cat > "$HERMES_HOME_TEST/config.yaml" << 'EOF'
webapp:
  enabled: true
  host: 127.0.0.1
  port: 9321
  public_url: "http://authority-test.local:9321"

dashboard:
  basic_auth:
    username: tester
    password: testpass123

model:
  provider: custom
  base_url: "http://127.0.0.1:1/v1"
  api_key: "dummy-key"
  model: "dummy-model"
EOF
fi

if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use -- is the authority gateway already running?"
  exit 1
fi

export HERMES_HOME="$HERMES_HOME_TEST"
export PYTHONPATH="$HERMES_WORKTREE"
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME=tester
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=testpass123

cd "$HERMES_WORKTREE"
nohup "$VENV_PYTHON" -m gateway.run -v > "$HERMES_HOME_TEST/gateway.log" 2>&1 &
disown
echo "Started. PID (see also $HERMES_HOME_TEST/gateway.pid for the gateway's own record): $!"
echo "Logs: $HERMES_HOME_TEST/gateway.log"
sleep 3
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Listening on 127.0.0.1:$PORT"
else
  echo "WARNING: not listening yet -- check $HERMES_HOME_TEST/gateway.log"
fi
