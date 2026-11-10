#!/bin/bash
# Stops the test authority gateway started by start-authority-gateway.sh.
set -euo pipefail

HERMES_HOME_TEST="/tmp/hermes-authority-home"
PIDFILE="$HERMES_HOME_TEST/gateway.pid"

if [ -f "$PIDFILE" ]; then
  PID=$(python3 -c "import json;print(json.load(open('$PIDFILE'))['pid'])" 2>/dev/null || true)
fi

if [ -z "${PID:-}" ]; then
  PID=$(lsof -tiTCP:9321 -sTCP:LISTEN 2>/dev/null || true)
fi

if [ -z "${PID:-}" ]; then
  echo "No authority gateway found listening on 9321."
  exit 0
fi

echo "Stopping authority gateway (pid $PID)..."
kill "$PID" 2>/dev/null || true
sleep 2
if kill -0 "$PID" 2>/dev/null; then
  echo "Still alive, sending SIGKILL..."
  kill -9 "$PID" 2>/dev/null || true
fi
echo "Stopped."
