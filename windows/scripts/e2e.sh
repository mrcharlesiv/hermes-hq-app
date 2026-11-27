#!/bin/zsh
# End-to-end test of Hermes.Core against the performance fixture gateway from the reference web repo: password sign-in,
# ws ticket, gateway.ready, profiles.list, session.resume, REST history, prompt.submit, streamed reply, Stop.
# [questions] Also approvals, questions and password prompts against questions-gateway.py.
# Usage: windows/scripts/e2e.sh     (HQW_E2E_PORT, default 9715; HQW_E2E_QUESTIONS_PORT, default 9730;
# HQW_E2E_GW_PORT, default 9740; the stand-ins are in windows/ci/fixtures)
# Then two gateways at once (scripts/fixtures/onboarding-gateway.py on 9740 and 9741): sign-in to both, the version
# check, switch, news, rename, remove.
# The fixture's invented credentials go to windows/build/fixtures/e2e-perf.json (0600, never printed).
# Every stand-in this starts is stopped and reaped on any exit; scripts/e2e-cleanup-test.sh checks that.
set -e
cd "$(dirname "$0")/.."
PORT=${HQW_E2E_PORT:-9715}
FIXTURES=${HQW_FIXTURES:-$PWD/ci/fixtures}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
# One owner for every child this run starts. start_fixture registers a child's pid the moment it exists, and the one
# trap below, set before the first child, stops and reaps exactly those pids on any exit: success, a failed test, a
# busy port part-way through a multi-port group, set -e, or a signal. Never by name or port, so a listener this run
# didn't start (another checkout's stand-ins, a test's own) is left alone.
CHILDREN=()
stop_children() {
  local pids=($CHILDREN) last=$! pid
  # A signal can land between a child's `&` and its registration; $! is always this shell's newest child.
  (( last > 0 && ${pids[(Ie)$last]} == 0 )) && pids+=($last)
  CHILDREN=()
  (( $#pids )) || return 0
  # `|| true`: under set -e a child that already exited would end the trap early and replace the run's exit status.
  kill $pids 2>/dev/null || true
  for pid in $pids; do wait $pid 2>/dev/null || true; done
  return 0
}
trap stop_children EXIT
trap 'stop_children; exit 129' HUP
trap 'stop_children; exit 130' INT
trap 'stop_children; exit 143' TERM
# start_fixture LOG COMMAND...: COMMAND in the background, its output in LOG, registered before anything else runs.
# REPLY is its pid.
start_fixture() {
  local log=$1; shift
  "$@" > $log 2>&1 &
  CHILDREN+=($!)
  REPLY=$!
}
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is busy; set HQW_E2E_PORT"; exit 1; fi
rm -f $FIX/e2e-perf.json
start_fixture $FIX/e2e-perf.log python3 $FIXTURES/performance-fixture-gateway.py --port $PORT --credentials $FIX/e2e-perf.json
PID=$REPLY
for i in {1..50}; do
  [[ -s $FIX/e2e-perf.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-perf.json ]] || { echo "fixture did not start (see windows/$FIX/e2e-perf.log)"; exit 1; }
# Sign in with Nous: the Nous fixture and its fake Portal, 4 s access tokens so the test sees a rotation.
NPORT=$((PORT+1)); PPORT=$((PORT+2))
start_fixture $FIX/e2e-nous.log python3 $FIXTURES/nous-fixture-gateway.py --port $NPORT --portal-port $PPORT --public-url http://127.0.0.1:$NPORT \
  --access-ttl 4
NPID=$REPLY
for i in {1..50}; do lsof -nP -iTCP:$NPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
export HQW_E2E_NOUS_URL=http://127.0.0.1:$NPORT
# [questions] The questions fixture (server→client requests with Hermes' semantics), on its own port.
QPORT=${HQW_E2E_QUESTIONS_PORT:-9730}
if lsof -nP -iTCP:$QPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $QPORT is busy; set HQW_E2E_QUESTIONS_PORT"; exit 1; fi
rm -f $FIX/e2e-questions.json
start_fixture $FIX/e2e-questions.log python3 $FIXTURES/questions-gateway.py --port $QPORT --credentials $FIX/e2e-questions.json
QPID=$REPLY
for i in {1..50}; do
  [[ -s $FIX/e2e-questions.json ]] && lsof -nP -iTCP:$QPORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-questions.json ]] || { echo "questions fixture did not start (see windows/$FIX/e2e-questions.log)"; exit 1; }
export HQW_E2E_QUESTIONS_CREDENTIALS=$PWD/$FIX/e2e-questions.json
# Two gateways at once (the gateways feature): the onboarding fixture twice, B an older Hermes. GPORT+2 stays free (a
# gateway that isn't there).
GPORT=${HQW_E2E_GW_PORT:-9740}
for p in $GPORT $((GPORT+1)) $((GPORT+2)); do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is busy; set HQW_E2E_GW_PORT"; exit 1; fi
done
rm -f $FIX/e2e-gw-a.json $FIX/e2e-gw-b.json
start_fixture $FIX/e2e-gw-a.log python3 $FIXTURES/onboarding-gateway.py --port $GPORT --credentials $FIX/e2e-gw-a.json
GAPID=$REPLY
start_fixture $FIX/e2e-gw-b.log python3 $FIXTURES/onboarding-gateway.py --port $((GPORT+1)) --credentials $FIX/e2e-gw-b.json --release-date 2026.9.10
GBPID=$REPLY
for i in {1..50}; do
  [[ -s $FIX/e2e-gw-a.json && -s $FIX/e2e-gw-b.json ]] && lsof -nP -iTCP:$((GPORT+1)) -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
export HQW_E2E_GW_A=$PWD/$FIX/e2e-gw-a.json HQW_E2E_GW_B=$PWD/$FIX/e2e-gw-b.json
# The composer: models, slash commands, drawers, steering and the queue (scripts/fixtures/composer-gateway.py, which
# layers on menus-gateway.py and the reference performance fixture). HQW_E2E_COMPOSER_PORT, default 9750.
CPORT=${HQW_E2E_COMPOSER_PORT:-9750}
if lsof -nP -iTCP:$CPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $CPORT is busy; set HQW_E2E_COMPOSER_PORT"; exit 1; fi
rm -f $FIX/e2e-composer.json
start_fixture $FIX/e2e-composer.log python3 $FIXTURES/composer-gateway.py --port $CPORT --credentials $FIX/e2e-composer.json
CPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-composer.json ]] && lsof -nP -iTCP:$CPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-composer.json ]] || { echo "composer fixture did not start (see windows/$FIX/e2e-composer.log)"; exit 1; }
export HQW_E2E_COMPOSER_CREDENTIALS=$PWD/$FIX/e2e-composer.json
# Jobs: the list, Run Now, Pause, the editor and its templates (scripts/fixtures/jobs-gateway.py on the pages fixture).
# HQW_E2E_JOBS_PORT, default 9800 (the jobs range is 9800-9809).
JPORT=${HQW_E2E_JOBS_PORT:-9800}
if lsof -nP -iTCP:$JPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $JPORT is busy; set HQW_E2E_JOBS_PORT"; exit 1; fi
rm -f $FIX/e2e-jobs.json
start_fixture $FIX/e2e-jobs.log python3 $FIXTURES/jobs-gateway.py --port $JPORT --credentials $FIX/e2e-jobs.json --files $FIX/jobs-files --tick-seconds 0
JPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-jobs.json ]] && lsof -nP -iTCP:$JPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-jobs.json ]] || { echo "jobs fixture did not start (see windows/$FIX/e2e-jobs.log)"; exit 1; }
export HQW_E2E_JOBS_CREDENTIALS=$PWD/$FIX/e2e-jobs.json
# Settings: the gateway card's facts and Default Project Folder's check (scripts/fixtures/settings-gateway.py).
# HQW_E2E_SETTINGS_PORT, default 9830 (the settings feature's range is 9830-9839).
SPORT=${HQW_E2E_SETTINGS_PORT:-9830}
if lsof -nP -iTCP:$SPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $SPORT is busy; set HQW_E2E_SETTINGS_PORT"; exit 1; fi
rm -f $FIX/e2e-settings.json
start_fixture $FIX/e2e-settings.log python3 $FIXTURES/settings-gateway.py --port $SPORT --credentials $FIX/e2e-settings.json
SETPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-settings.json ]] && lsof -nP -iTCP:$SPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-settings.json ]] || { echo "settings fixture did not start (see windows/$FIX/e2e-settings.log)"; exit 1; }
export HQW_E2E_SETTINGS_CREDENTIALS=$PWD/$FIX/e2e-settings.json
# [workspace] Files, Changes and the Terminal (windows/ci/fixtures/workspace-gateway.py, a stand-in shell behind the
# add-on's socket). HQW_E2E_WORKSPACE_PORT, default 9850 (the workspace feature's ports are 9850-9859).
WPORT=${HQW_E2E_WORKSPACE_PORT:-9850}
if lsof -nP -iTCP:$WPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $WPORT is busy; set HQW_E2E_WORKSPACE_PORT"; exit 1; fi
rm -f $FIX/e2e-workspace.json
start_fixture $FIX/e2e-workspace.log python3 $FIXTURES/workspace-gateway.py --port $WPORT --credentials $FIX/e2e-workspace.json
WSPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-workspace.json ]] && lsof -nP -iTCP:$WPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-workspace.json ]] || { echo "workspace fixture did not start (see windows/$FIX/e2e-workspace.log)"; exit 1; }
export HQW_E2E_WORKSPACE_CREDENTIALS=$PWD/$FIX/e2e-workspace.json
# [kanban] Kanban and Tasks: ci/fixtures/pages-fixture-gateway.py (boards, tasks, attachments; the add-on's to-do list).
# HQW_E2E_PAGES_PORT, default 9811 (9810-9819).
KPORT=${HQW_E2E_PAGES_PORT:-9811}
if lsof -nP -iTCP:$KPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $KPORT is busy; set HQW_E2E_PAGES_PORT"; exit 1; fi
rm -f $FIX/e2e-pages.json
start_fixture $FIX/e2e-pages.log python3 $FIXTURES/pages-fixture-gateway.py --port $KPORT --credentials $FIX/e2e-pages.json --files $FIX/pages-files
KPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-pages.json ]] && lsof -nP -iTCP:$KPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-pages.json ]] || { echo "pages fixture did not start (see windows/$FIX/e2e-pages.log)"; exit 1; }
export HQW_E2E_PAGES_CREDENTIALS=$PWD/$FIX/e2e-pages.json
# [walk proof] Tasks Sort By and Select: the same stand-in with its lists (--task-lists), as windows.yml's "tasks"
# screenshot extra runs it for the tasks-sort-select walk (WalkProofEndToEndTests.TasksSortByDue). HQW_E2E_TASKS_PORT,
# default 9815.
TPORT=${HQW_E2E_TASKS_PORT:-9815}
if lsof -nP -iTCP:$TPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $TPORT is busy; set HQW_E2E_TASKS_PORT"; exit 1; fi
rm -f $FIX/e2e-tasks.json
start_fixture $FIX/e2e-tasks.log python3 $FIXTURES/pages-fixture-gateway.py --port $TPORT --credentials $FIX/e2e-tasks.json --files $FIX/tasks-files --task-lists \
  --tick-seconds 0
TKPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-tasks.json ]] && lsof -nP -iTCP:$TPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-tasks.json ]] || { echo "tasks fixture did not start (see windows/$FIX/e2e-tasks.log)"; exit 1; }
export HQW_E2E_TASKS_CREDENTIALS=$PWD/$FIX/e2e-tasks.json
# [WIN-42] Tasks › Goals and Today's Goals shelf: the same stand-in with its five made-up goals and its lists
# (--task-goals --task-lists), as windows.yml's "tasks-goals" screenshot extra runs it for the tasks-goals walk
# (GoalsEndToEndTests). HQW_E2E_GOALS_PORT, default 9818.
GPORT=${HQW_E2E_GOALS_PORT:-9818}
if lsof -nP -iTCP:$GPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $GPORT is busy; set HQW_E2E_GOALS_PORT"; exit 1; fi
rm -f $FIX/e2e-goals.json
start_fixture $FIX/e2e-goals.log python3 $FIXTURES/pages-fixture-gateway.py --port $GPORT --credentials $FIX/e2e-goals.json --files $FIX/goals-files --task-goals --task-lists \
  --tick-seconds 0
GLPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-goals.json ]] && lsof -nP -iTCP:$GPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-goals.json ]] || { echo "goals fixture did not start (see windows/$FIX/e2e-goals.log)"; exit 1; }
export HQW_E2E_GOALS_CREDENTIALS=$PWD/$FIX/e2e-goals.json
# [kanban boards] The board picker past eight boards: the same stand-in with --many-boards 9 (the Boards list) on
# HQW_E2E_BOARDS_PORT (default 9816) and --many-boards 13 (the list with its search) on the next port. Eight (the menu)
# is the 9 one re-seeded.
KBPORT=${HQW_E2E_BOARDS_PORT:-9816}
KBPIDS=()
for n in 9 13; do
  p=$((KBPORT + (n == 9 ? 0 : 1)))
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is busy; set HQW_E2E_BOARDS_PORT"; exit 1; fi
  rm -f $FIX/e2e-boards$n.json
  start_fixture $FIX/e2e-boards$n.log python3 $FIXTURES/pages-fixture-gateway.py --port $p --credentials $FIX/e2e-boards$n.json --files $FIX/boards$n-files \
    --many-boards $n --tick-seconds 0
  KBPIDS+=($REPLY)
done
for i in {1..50}; do
  [[ -s $FIX/e2e-boards9.json && -s $FIX/e2e-boards13.json ]] && lsof -nP -iTCP:$((KBPORT+1)) -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
for n in 9 13; do [[ -s $FIX/e2e-boards$n.json ]] || { echo "boards fixture $n did not start (see windows/$FIX/e2e-boards$n.log)"; exit 1; }; done
export HQW_E2E_BOARDS9_CREDENTIALS=$PWD/$FIX/e2e-boards9.json HQW_E2E_BOARDS13_CREDENTIALS=$PWD/$FIX/e2e-boards13.json
# Artifacts: the pages fixture's chats plus linked notes (windows/ci/fixtures/artifacts-gateway.py). HQW_E2E_ARTIFACTS_PORT,
# default 9820 (its range is 9820-9829).
APORT=${HQW_E2E_ARTIFACTS_PORT:-9820}
if lsof -nP -iTCP:$APORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $APORT is busy; set HQW_E2E_ARTIFACTS_PORT"; exit 1; fi
rm -f $FIX/e2e-artifacts.json
start_fixture $FIX/e2e-artifacts.log python3 $FIXTURES/artifacts-gateway.py --port $APORT --credentials $FIX/e2e-artifacts.json --files $FIX/artifacts-files \
  --tick-seconds 0
ARPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-artifacts.json ]] && lsof -nP -iTCP:$APORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-artifacts.json ]] || { echo "artifacts fixture did not start (see windows/$FIX/e2e-artifacts.log)"; exit 1; }
export HQW_E2E_ARTIFACTS_CREDENTIALS=$PWD/$FIX/e2e-artifacts.json
# [bot-pages] Bot Profiles, Messaging, Webhooks, Import Sessions and Restart Gateway: the More pages stand-in
# (ci/fixtures/morepages-gateway.py, which layers on pages-fixture-gateway.py). HQW_E2E_BOTPAGES_PORT, default 9870.
BPORT=${HQW_E2E_BOTPAGES_PORT:-9870}
if lsof -nP -iTCP:$BPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $BPORT is busy; set HQW_E2E_BOTPAGES_PORT"; exit 1; fi
rm -rf $FIX/e2e-botpages.json $FIX/e2e-botpages-files
start_fixture $FIX/e2e-botpages.log python3 $FIXTURES/morepages-gateway.py --port $BPORT --credentials $FIX/e2e-botpages.json --files $FIX/e2e-botpages-files \
  --tick-seconds 0
BPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-botpages.json ]] && lsof -nP -iTCP:$BPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-botpages.json ]] || { echo "bot pages fixture did not start (see windows/$FIX/e2e-botpages.log)"; exit 1; }
export HQW_E2E_BOTPAGES_CREDENTIALS=$PWD/$FIX/e2e-botpages.json
# [insights] Status & Maintenance, Usage, Spawn Tree, Star Map and Tiles: the More pages' stand-in
# (ci/fixtures/morepages-gateway.py over pages-fixture-gateway.py), four of them so each page's knobs stay its own:
# status/usage on IPORT, spawn tree +1, star map +2, tiles +3. HQW_E2E_INSIGHTS_PORT, default 9860.
IPORT=${HQW_E2E_INSIGHTS_PORT:-9860}
IPIDS=()
for n in 0 1 2 3; do
  p=$((IPORT+n))
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is busy; set HQW_E2E_INSIGHTS_PORT"; exit 1; fi
  rm -f $FIX/e2e-insights-$n.json; rm -rf $FIX/e2e-insights-files-$n
  start_fixture $FIX/e2e-insights-$n.log env HQN_MOREPAGES_ANY_PORT=1 python3 $FIXTURES/morepages-gateway.py --port $p --credentials $FIX/e2e-insights-$n.json \
    --files $FIX/e2e-insights-files-$n --tick-seconds 0
  IPIDS+=($REPLY)
done
for i in {1..75}; do
  [[ -s $FIX/e2e-insights-0.json && -s $FIX/e2e-insights-1.json && -s $FIX/e2e-insights-2.json && -s $FIX/e2e-insights-3.json ]] \
    && lsof -nP -iTCP:$((IPORT+3)) -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
for n in 0 1 2 3; do [[ -s $FIX/e2e-insights-$n.json ]] || { echo "insights fixture $n did not start (see windows/$FIX/e2e-insights-$n.log)"; exit 1; }; done
export HQW_E2E_INSIGHTS_STATUS=$PWD/$FIX/e2e-insights-0.json HQW_E2E_INSIGHTS_SPAWN=$PWD/$FIX/e2e-insights-1.json \
  HQW_E2E_INSIGHTS_STARMAP=$PWD/$FIX/e2e-insights-2.json HQW_E2E_INSIGHTS_TILES=$PWD/$FIX/e2e-insights-3.json
# [capabilities] Skills, tools, connectors (probe, tool rules, logs, OAuth through the loopback relay, the app catalog),
# plugins and managed apps: scripts/fixtures/connectors-gateway.py, which layers on capabilities-gateway.py.
# HQW_E2E_CAPABILITIES_PORT, default 9840 (the stream's range is 9840-9849).
CAPPORT=${HQW_E2E_CAPABILITIES_PORT:-9840}
if lsof -nP -iTCP:$CAPPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $CAPPORT is busy; set HQW_E2E_CAPABILITIES_PORT"; exit 1; fi
rm -f $FIX/e2e-capabilities.json
start_fixture $FIX/e2e-capabilities.log python3 $FIXTURES/connectors-gateway.py --port $CAPPORT --credentials $FIX/e2e-capabilities.json
CAPPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-capabilities.json ]] && lsof -nP -iTCP:$CAPPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-capabilities.json ]] || { echo "capabilities fixture did not start (see windows/$FIX/e2e-capabilities.log)"; exit 1; }
export HQW_E2E_CAPABILITIES_CREDENTIALS=$PWD/$FIX/e2e-capabilities.json
# [groups] The sidebar's group chat rows: the settings stand-in with two rooms in its mirror (--group-rooms).
# HQW_E2E_GROUPS_PORT, default 9831 (the settings feature's range is 9830-9839).
GRPORT=${HQW_E2E_GROUPS_PORT:-9831}
if lsof -nP -iTCP:$GRPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $GRPORT is busy; set HQW_E2E_GROUPS_PORT"; exit 1; fi
rm -f $FIX/e2e-groups.json
start_fixture $FIX/e2e-groups.log python3 $FIXTURES/settings-gateway.py --port $GRPORT --group-rooms --credentials $FIX/e2e-groups.json
GRPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-groups.json ]] && lsof -nP -iTCP:$GRPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-groups.json ]] || { echo "groups fixture did not start (see windows/$FIX/e2e-groups.log)"; exit 1; }
export HQW_E2E_GROUPS_CREDENTIALS=$PWD/$FIX/e2e-groups.json
# [groups] A room's management (GroupManageEndToEndTests): its own --group-rooms stand-in, as it writes the bots and the
# mirror. HQW_E2E_GROUPMANAGE_PORT, default 9832.
GMPORT=${HQW_E2E_GROUPMANAGE_PORT:-9832}
if lsof -nP -iTCP:$GMPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $GMPORT is busy; set HQW_E2E_GROUPMANAGE_PORT"; exit 1; fi
rm -f $FIX/e2e-groupmanage.json
start_fixture $FIX/e2e-groupmanage.log python3 $FIXTURES/settings-gateway.py --port $GMPORT --group-rooms --credentials $FIX/e2e-groupmanage.json
GMPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-groupmanage.json ]] && lsof -nP -iTCP:$GMPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-groupmanage.json ]] || { echo "group manage fixture did not start (see windows/$FIX/e2e-groupmanage.log)"; exit 1; }
export HQW_E2E_GROUPMANAGE_CREDENTIALS=$PWD/$FIX/e2e-groupmanage.json
# [WIN-57] A room's Activity and its empty view (GroupActivityEndToEndTests): its own --group-rooms --quiet-room
# stand-in, as its round adds to Launch Room. HQW_E2E_GROUPACTIVITY_PORT, default 9834.
GAPORT=${HQW_E2E_GROUPACTIVITY_PORT:-9834}
if lsof -nP -iTCP:$GAPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $GAPORT is busy; set HQW_E2E_GROUPACTIVITY_PORT"; exit 1; fi
rm -f $FIX/e2e-groupactivity.json
start_fixture $FIX/e2e-groupactivity.log python3 $FIXTURES/settings-gateway.py --port $GAPORT --group-rooms --quiet-room --credentials $FIX/e2e-groupactivity.json
GACTPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-groupactivity.json ]] && lsof -nP -iTCP:$GAPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-groupactivity.json ]] || { echo "group activity fixture did not start (see windows/$FIX/e2e-groupactivity.log)"; exit 1; }
export HQW_E2E_GROUPACTIVITY_CREDENTIALS=$PWD/$FIX/e2e-groupactivity.json
# [WIN-59] A room's @ list and a line for one member (GroupMentionsEndToEndTests): its own --group-rooms stand-in, as
# its round adds to Launch Room. HQW_E2E_GROUPMENTIONS_PORT, default 9836.
GMNPORT=${HQW_E2E_GROUPMENTIONS_PORT:-9836}
if lsof -nP -iTCP:$GMNPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $GMNPORT is busy; set HQW_E2E_GROUPMENTIONS_PORT"; exit 1; fi
rm -f $FIX/e2e-groupmentions.json
start_fixture $FIX/e2e-groupmentions.log python3 $FIXTURES/settings-gateway.py --port $GMNPORT --group-rooms --credentials $FIX/e2e-groupmentions.json
GMNPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-groupmentions.json ]] && lsof -nP -iTCP:$GMNPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-groupmentions.json ]] || { echo "group mentions fixture did not start (see windows/$FIX/e2e-groupmentions.log)"; exit 1; }
export HQW_E2E_GROUPMENTIONS_CREDENTIALS=$PWD/$FIX/e2e-groupmentions.json
# [WIN-SCREEN-WALK] Bot Screen over the real wire (ScreenWireEndToEndTests, the bot-screen-wire walk's checks):
# ci/fixtures/screen-gateway.py, display.* and a display socket with a generated picture that only records input.
# HQW_E2E_SCREEN_PORT, default 9880 (the screen range is 9880-9889).
SCRPORT=${HQW_E2E_SCREEN_PORT:-9880}
if lsof -nP -iTCP:$SCRPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $SCRPORT is busy; set HQW_E2E_SCREEN_PORT"; exit 1; fi
rm -f $FIX/e2e-screen.json
start_fixture $FIX/e2e-screen.log python3 $FIXTURES/screen-gateway.py --port $SCRPORT --credentials $FIX/e2e-screen.json
SCRPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-screen.json ]] && lsof -nP -iTCP:$SCRPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-screen.json ]] || { echo "screen fixture did not start (see windows/$FIX/e2e-screen.log)"; exit 1; }
export HQW_E2E_SCREEN_CREDENTIALS=$PWD/$FIX/e2e-screen.json
# [WIN-DELIVERY-WALK] The delivery cards over the real wire (DeliveryWireEndToEndTests, the chat-delivery walk's checks):
# its own performance stand-in, so no other test takes its plans (refusals with error data, the working ledger).
# HQW_E2E_DELIVERY_PORT, default 9890.
DLVPORT=${HQW_E2E_DELIVERY_PORT:-9890}
if lsof -nP -iTCP:$DLVPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $DLVPORT is busy; set HQW_E2E_DELIVERY_PORT"; exit 1; fi
rm -f $FIX/e2e-delivery.json
start_fixture $FIX/e2e-delivery.log python3 $FIXTURES/performance-fixture-gateway.py --port $DLVPORT --credentials $FIX/e2e-delivery.json
DLVPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-delivery.json ]] && lsof -nP -iTCP:$DLVPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-delivery.json ]] || { echo "delivery fixture did not start (see windows/$FIX/e2e-delivery.log)"; exit 1; }
export HQW_E2E_DELIVERY_CREDENTIALS=$PWD/$FIX/e2e-delivery.json
# [WIN-ROWS-STEP-WALK] Held turns on one step each and one bot's slow open (RowStepsEndToEndTests, the row-steps walk's
# stand-in): its own settings stand-in, as it holds turns and arms a slow resume. HQW_E2E_ROWSTEPS_PORT, default 9837.
RSPORT=${HQW_E2E_ROWSTEPS_PORT:-9837}
if lsof -nP -iTCP:$RSPORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $RSPORT is busy; set HQW_E2E_ROWSTEPS_PORT"; exit 1; fi
rm -f $FIX/e2e-rowsteps.json
start_fixture $FIX/e2e-rowsteps.log python3 $FIXTURES/settings-gateway.py --port $RSPORT --credentials $FIX/e2e-rowsteps.json
RSPID=$REPLY
for i in {1..50}; do [[ -s $FIX/e2e-rowsteps.json ]] && lsof -nP -iTCP:$RSPORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $FIX/e2e-rowsteps.json ]] || { echo "row steps fixture did not start (see windows/$FIX/e2e-rowsteps.log)"; exit 1; }
export HQW_E2E_ROWSTEPS_CREDENTIALS=$PWD/$FIX/e2e-rowsteps.json
DOTNET=${DOTNET:-$(command -v dotnet || echo $HOME/.dotnet/dotnet)}
# The tests run as a registered child too, so a signal to this script reaches its trap at once (zsh holds a trap until a
# foreground command ends) and stops them along with the fixtures. Their exit status is the script's.
HQW_E2E_CREDENTIALS=$PWD/$FIX/e2e-perf.json DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  $DOTNET test HermesHQ.sln --filter Category=E2E --logger "console;verbosity=normal" &
CHILDREN+=($!)
wait $!
