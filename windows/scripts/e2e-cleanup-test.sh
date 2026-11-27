#!/bin/zsh
# Regression for e2e.sh's child lifetime: whatever way the runner ends, every stand-in it started is stopped and reaped
# before it returns, and nothing it didn't start is touched. Local only (macOS/Linux, zsh, python3, lsof); no gateway,
# no dotnet, no real ports.
# Usage: windows/scripts/e2e-cleanup-test.sh   (HQW_E2E_SCRIPT=<path> tests another copy of the runner)
#
# It copies the runner into a scratch tree and runs it with HQW_FIXTURES pointing at one invented stand-in (it binds its
# port(s), writes made-up credentials 0600, notes its pid in a ledger, then waits) and DOTNET at a stub, all on a block
# of ports it finds free. Cases: a normal run (tests pass, then fail with their status kept), a busy later port in the
# boards group and in the insights group (a listener this test starts itself, which must survive), and a TERM while the
# tests run. After each run it checks, straight away (the runner must have reaped them already), that no pid from the
# ledger is alive.
set -u
HERE=${0:A:h}
SCRIPT=${HQW_E2E_SCRIPT:-$HERE/e2e.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hqw-e2e-cleanup.XXXXXX")
FAILS=0
LISTENER=
cleanup_test() {
  [[ -n $LISTENER ]] && { kill $LISTENER 2>/dev/null; wait $LISTENER 2>/dev/null; }
  # Anything a broken runner left behind: only pids from this test's own ledgers, and only if still our stand-in.
  local pid
  local -a ledgers
  ledgers=("$WORK"/run-*/ledger(N))
  if (( $#ledgers )); then
    for pid in $(awk '{print $1}' "${ledgers[@]}"); do
      ps -o command= -p $pid 2>/dev/null | grep -q "$WORK/" && kill $pid 2>/dev/null
    done
  fi
  rm -rf $WORK
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { print -r -- "FAIL [$CASE] $*"; FAILS=$((FAILS+1)); }
pass() { print -r -- "ok   [$CASE] $*"; }

# ---- the invented stand-in and the dotnet stub ----------------------------------------------------------------------
mkdir -p $WORK/fixtures
cat > $WORK/stub-gateway.py <<'EOF'
# Invented stand-in: bind the asked port(s) on loopback, write made-up credentials (0600), note our pid, wait.
import os, socket, sys
args = sys.argv[1:]
def opt(name):
    return args[args.index(name) + 1] if name in args else None
name = os.path.basename(sys.argv[0])
ports = [int(p) for p in (opt('--port'), opt('--portal-port')) if p]
with open(os.environ['HQW_TEST_LEDGER'], 'a') as f:
    f.write(f"{os.getpid()} {name} {ports[0]} anyport={os.environ.get('HQN_MOREPAGES_ANY_PORT', '-')}\n")
socks = []
for p in ports:
    s = socket.socket()
    try:
        s.bind(('127.0.0.1', p))
    except OSError:
        sys.exit(f'port {p} is already in use')
    s.listen(5)
    socks.append(s)
creds = opt('--credentials')
if creds:
    fd = os.open(creds + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, b'{"url": "http://127.0.0.1", "password": "invented-not-a-secret"}')
    os.close(fd)
    os.replace(creds + '.tmp', creds)
while True:
    c, _ = socks[0].accept()
    c.close()
EOF
for f in ${(u)$(grep -oE '\$FIXTURES/[a-z0-9-]+\.py' $SCRIPT | sed 's#.*/##')}; do
  cp $WORK/stub-gateway.py $WORK/fixtures/$f
done
cat > $WORK/dotnet <<'EOF'
#!/bin/zsh
# dotnet stub: note our pid, check every stand-in in the ledger is up and the runner's exports point at real files, then
# exit with HQW_TEST_DOTNET_STATUS, or (HQW_TEST_DOTNET_HOLD=1) say we're running and wait to be stopped.
print "$$ dotnet - -" >> $HQW_TEST_LEDGER
[[ $1 == test && $* == *Category=E2E* ]] || { print "dotnet stub: unexpected args: $*"; exit 90; }
for pid in $(awk '$2 != "dotnet" {print $1}' $HQW_TEST_LEDGER); do
  kill -0 $pid 2>/dev/null || { print "dotnet stub: stand-in $pid is not running"; exit 91; }
done
for v in HQW_E2E_CREDENTIALS HQW_E2E_BOARDS9_CREDENTIALS HQW_E2E_BOARDS13_CREDENTIALS HQW_E2E_INSIGHTS_TILES \
    HQW_E2E_GROUPMENTIONS_CREDENTIALS HQW_E2E_SCREEN_CREDENTIALS HQW_E2E_DELIVERY_CREDENTIALS \
    HQW_E2E_ROWSTEPS_CREDENTIALS; do
  [[ -s ${(P)v} ]] || { print "dotnet stub: $v is not a file"; exit 92; }
done
if [[ ${HQW_TEST_DOTNET_HOLD:-} == 1 ]]; then
  print running > $HQW_TEST_DOTNET_READY
  exec -a "$0-hold" sleep 86400   # same pid (the ledger names what the runner must stop), still under the scratch path
fi
exit ${HQW_TEST_DOTNET_STATUS:-0}
EOF
chmod +x $WORK/dotnet

# ---- a free block of ports (none of the runner's defaults, so a real run here or elsewhere isn't disturbed) ---------
busy() { lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1; }
BASE=
for b in {41000..47950..50}; do
  ok=1
  for p in {$b..$((b+29))}; do busy $p && { ok=0; break; }; done
  (( ok )) && { BASE=$b; break; }
done
[[ -n $BASE ]] || { print "no free block of 30 ports in 41000-47999"; exit 2; }
typeset -A PORTS=(
  HQW_E2E_PORT $((BASE+0)) HQW_E2E_QUESTIONS_PORT $((BASE+3)) HQW_E2E_GW_PORT $((BASE+4))
  HQW_E2E_COMPOSER_PORT $((BASE+7)) HQW_E2E_JOBS_PORT $((BASE+8)) HQW_E2E_SETTINGS_PORT $((BASE+9))
  HQW_E2E_WORKSPACE_PORT $((BASE+10)) HQW_E2E_PAGES_PORT $((BASE+11)) HQW_E2E_TASKS_PORT $((BASE+12))
  HQW_E2E_GOALS_PORT $((BASE+13)) HQW_E2E_BOARDS_PORT $((BASE+14)) HQW_E2E_ARTIFACTS_PORT $((BASE+16))
  HQW_E2E_BOTPAGES_PORT $((BASE+17)) HQW_E2E_INSIGHTS_PORT $((BASE+18)) HQW_E2E_CAPABILITIES_PORT $((BASE+22))
  HQW_E2E_GROUPS_PORT $((BASE+23)) HQW_E2E_GROUPMANAGE_PORT $((BASE+24)) HQW_E2E_GROUPACTIVITY_PORT $((BASE+25))
  HQW_E2E_GROUPMENTIONS_PORT $((BASE+26)) HQW_E2E_SCREEN_PORT $((BASE+27))
  HQW_E2E_DELIVERY_PORT $((BASE+28)) HQW_E2E_ROWSTEPS_PORT $((BASE+29))
)
# Every port variable the runner reads must be set here, or a case would quietly use a real default port.
for v in ${(u)$(grep -oE 'HQW_E2E_[A-Z]+_?PORT' $SCRIPT)}; do
  (( ${+PORTS[$v]} )) || { print "the runner reads $v, which this test doesn't place; add it to PORTS"; exit 2; }
done
print "ports $BASE-$((BASE+29)), scratch $WORK"

# ---- one run of a copy of the runner ----------------------------------------------------------------------------------
# run_case NAME [VAR=VALUE...]: sets RUN (its dir), STATUS, OUT. The copy is the runner as it is, in its own tree.
run_case() {
  CASE=$1; shift
  RUN=$WORK/run-$CASE
  mkdir -p $RUN/windows/scripts
  cp $SCRIPT $RUN/windows/scripts/e2e.sh
  : > $RUN/ledger
  local -a envs=(HQW_FIXTURES=$WORK/fixtures DOTNET=$WORK/dotnet HQW_TEST_LEDGER=$RUN/ledger
    HQW_TEST_DOTNET_READY=$RUN/dotnet-ready "$@")
  local k; for k in ${(k)PORTS}; do envs+=($k=$PORTS[$k]); done
  if [[ ${SIGNAL_AFTER_READY:-} == 1 ]]; then
    env $envs zsh $RUN/windows/scripts/e2e.sh > $RUN/out 2>&1 &
    local rpid=$!
    local i; for i in {1..300}; do [[ -s $RUN/dotnet-ready ]] && break; kill -0 $rpid 2>/dev/null || break; sleep 0.1; done
    [[ -s $RUN/dotnet-ready ]] || fail "the tests never started"
    kill -TERM $rpid 2>/dev/null
    # A runner that only reacts once its foreground command ends would sit here for the stub's whole day.
    for i in {1..300}; do kill -0 $rpid 2>/dev/null || break; sleep 0.1; done
    if kill -0 $rpid 2>/dev/null; then fail "the runner was still running 30 s after TERM"; kill -KILL $rpid; fi
    wait $rpid; STATUS=$?
  else
    env $envs zsh $RUN/windows/scripts/e2e.sh > $RUN/out 2>&1; STATUS=$?
  fi
  OUT=$(<$RUN/out)
}
# every pid in this run's ledger is gone now (checked at once: the runner returns only after reaping them)
check_reaped() {
  local line pid name left=0 n=0
  while read -r pid name _; do
    n=$((n+1))
    if kill -0 $pid 2>/dev/null; then fail "$name (pid $pid) is still running after the runner returned"; left=1; fi
  done < $RUN/ledger
  (( left )) || pass "all $n children the run started were stopped and reaped"
  # Whatever a broken runner left must not leak into the next case: stop it (ours only, by the ledger).
  for pid in $(awk '{print $1}' $RUN/ledger); do
    ps -o command= -p $pid 2>/dev/null | grep -q "$WORK/" && { kill $pid 2>/dev/null; while kill -0 $pid 2>/dev/null; do sleep 0.05; done; }
  done
  return 0
}
started() { awk -v n="$1" -v p="$2" '$2 == n && $3 == p' $RUN/ledger | grep -q .; }
start_listener() {
  rm -f $WORK/listener-ready
  python3 -c '
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
open(sys.argv[2], "w").write("ready")
while True:
    c, _ = s.accept(); c.close()' $1 $WORK/listener-ready &
  LISTENER=$!
  local i; for i in {1..100}; do [[ -s $WORK/listener-ready ]] && return 0; sleep 0.05; done
  print "own listener on $1 didn't start"; exit 2
}
check_listener() {
  if kill -0 $LISTENER 2>/dev/null && python3 -c '
import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()' $1; then
    pass "the listener this test started on $1 is still alive and accepting"
  else
    fail "the listener on $1 was stopped or no longer accepts"
  fi
  kill $LISTENER; wait $LISTENER 2>/dev/null; LISTENER=
}

# 1. normal run, tests pass
run_case normal HQW_TEST_DOTNET_STATUS=0
(( STATUS == 0 )) && pass "exit 0" || fail "exit $STATUS, wanted 0: $OUT"
grep -q ' dotnet ' $RUN/ledger && pass "the tests ran with every stand-in up" || fail "the tests never ran: $OUT"
(( $(grep -c anyport=1 $RUN/ledger) == 4 )) && pass "the four insights stand-ins got HQN_MOREPAGES_ANY_PORT=1" \
  || fail "insights stand-ins without HQN_MOREPAGES_ANY_PORT=1: $(grep morepages $RUN/ledger)"
[[ $(stat -f %Lp $RUN/windows/build/fixtures 2>/dev/null || stat -c %a $RUN/windows/build/fixtures) == 700 ]] \
  && pass "build/fixtures is 0700" || fail "build/fixtures is not 0700"
if started screen-gateway.py $PORTS[HQW_E2E_SCREEN_PORT] &&
   started performance-fixture-gateway.py $PORTS[HQW_E2E_DELIVERY_PORT] &&
   started settings-gateway.py $PORTS[HQW_E2E_ROWSTEPS_PORT]; then
  pass "screen, delivery and row steps used their reserved ports"
else
  fail "missing fixture on its assigned port"
fi
check_reaped

# 2. normal start, tests fail: their status is the runner's, and the stand-ins still go
run_case tests-fail HQW_TEST_DOTNET_STATUS=3
(( STATUS == 3 )) && pass "exit 3 (the tests' status)" || fail "exit $STATUS, wanted 3: $OUT"
check_reaped

# 3. boards group: 9-board stand-in started, the next port is busy
p=$((PORTS[HQW_E2E_BOARDS_PORT]+1)); start_listener $p
run_case boards-busy
(( STATUS != 0 )) && pass "exit $STATUS" || fail "exit 0 with port $p busy"
[[ $OUT == *"port $p is busy; set HQW_E2E_BOARDS_PORT"* ]] && pass "says: port $p is busy; set HQW_E2E_BOARDS_PORT" \
  || fail "no port diagnostic: $OUT"
started pages-fixture-gateway.py $((p-1)) && pass "the boards loop had started its first stand-in" \
  || fail "the boards loop's first stand-in never started, so this case proves nothing"
grep -q ' dotnet ' $RUN/ledger && fail "the tests ran" || pass "the tests didn't run"
check_reaped; check_listener $p

# 4. insights group: stand-ins 0 and 1 started, +2 busy
p=$((PORTS[HQW_E2E_INSIGHTS_PORT]+2)); start_listener $p
run_case insights-busy
(( STATUS != 0 )) && pass "exit $STATUS" || fail "exit 0 with port $p busy"
[[ $OUT == *"port $p is busy; set HQW_E2E_INSIGHTS_PORT"* ]] && pass "says: port $p is busy; set HQW_E2E_INSIGHTS_PORT" \
  || fail "no port diagnostic: $OUT"
started morepages-gateway.py $((p-2)) && started morepages-gateway.py $((p-1)) \
  && pass "the insights loop had started stand-ins 0 and 1" || fail "the insights loop's first stand-ins never started"
check_reaped; check_listener $p

# 5. TERM to the runner while the tests run: it stops at once, with the tests and every stand-in
SIGNAL_AFTER_READY=1 run_case term HQW_TEST_DOTNET_HOLD=1
(( STATUS == 143 )) && pass "exit 143" || fail "exit $STATUS, wanted 143: $OUT"
check_reaped

print
(( FAILS == 0 )) && { print "e2e-cleanup-test: all passed"; exit 0; }
print "e2e-cleanup-test: $FAILS failed"; exit 1
