Stand-in gateways, copied from the Hermes HQ web app's repo (hermes-hq-native-ref238/scripts) so the Windows build and
`windows/scripts/e2e.sh` need nothing outside this folder. Loopback only, invented credentials, never forward anything.
Refresh them by copying again; don't edit them here.

questions-gateway.py, attachments-gateway.py, onboarding-gateway.py, settings-gateway.py, settings_config_data.py, composer-gateway.py,
menus-gateway.py, botslist-gateway.py and sessions-gateway.py are copied from this repo's scripts/fixtures/, changed only to load the other stand-ins from
this folder.

jobs-gateway.py and pages-fixture-gateway.py are copied from this repo's scripts/fixtures/jobs-gateway.py and
scripts/pages-fixture-gateway.py, changed only to load each other and action-voice-fixture-gateway.py from this folder,
to take the Windows jobs ports 9800-9809, and to skip `lsof` where there is none.

workspace-gateway.py is written for Windows (Files, Changes and the Terminal): the invented tree of
scripts/fixtures/morepages/workspace.py on the performance fixture, and a stand-in shell in Python behind the
add-on's Terminal socket (no pty, so it runs on the Windows build machine too). Port 9850.

pages-fixture-gateway.py (with fixture-support/task_page.py and perf_logs.py) is copied from this repo's
scripts/pages-fixture-gateway.py and scripts/fixture-support/, changed only to load action-voice-fixture-gateway.py from
this folder. It serves Kanban (/api/plugins/kanban/*) and the add-on's Tasks for the Kanban and Tasks pages.

pages-fixture-gateway.py is copied from this repo's scripts/, changed only to load action-voice-fixture-gateway.py from
this folder (not $HQN_REF). artifacts-gateway.py is the Windows Artifacts stand-in: it loads that copy and adds the
linked notes and repeats of scripts/fixtures/morepages/artifacts.py (ports 9820-9829).

pages-fixture-gateway.py (from scripts/), morepages-gateway.py and morepages/{profiles,messaging,webhooks,foreign,actions}.py
(from scripts/fixtures/) are copied the same way: they load their siblings from this folder, and morepages-gateway.py also
takes ports 9870-9879 and runs without lsof.

[insights] morepages-gateway.py (with its morepages/ modules), pages-fixture-gateway.py and fixture-support/{perf_logs,task_page}.py
are copied from this repo's scripts/ (scripts/fixtures/morepages-gateway.py, scripts/fixtures/morepages/,
scripts/pages-fixture-gateway.py, scripts/fixture-support/), changed only to load each other and action-voice-fixture-gateway.py
from this folder. Its ports are 10050-10059 unless HQN_MOREPAGES_ANY_PORT=1 (e2e.sh and windows.yml set it; the Insights
pages use 9860-9863).

capabilities-gateway.py, connectors-gateway.py and mcp-catalog.json are copied from this repo's
scripts/fixtures/ unchanged (they already load their siblings from their own folder).

[kanban boards] pages-fixture-gateway.py has one Windows-only addition the reference copy lacks: `--many-boards N` (and
`POST /__fixture/many-boards {"count": N}`) serves N invented boards with totals after Release 2.4 and Home, for the
board picker past eight boards. Off by default, so every other use is unchanged; keep it when refreshing the copy.
e2e.sh starts it with 9 and 13 boards on HQW_E2E_BOARDS_PORT (default 9816) and the next port; windows.yml uses 9812 (9), 9813 (13) and, for the
screenshots, 9814 (8).

[groups] settings-gateway.py here also takes --group-rooms (Windows only, off by default): two invented group chats
(Launch Room, Weekend Plans) in the default profile's ui_meta["hermes-bots-groups"] mirror, their members naming them in
hermes-bots.groups, for the sidebar's group chat rows (GroupSidebarEndToEndTests, the "groups" screenshot extra on port
9831, e2e.sh's HQW_E2E_GROUPS_PORT). With it, a session.create with room_plumbing makes a member's hidden
session for a room thread (never listed), and prompt.submit on one streams "<Name> here: noted." when the prompt carries
a line of yours, else "(pass)", so a round to the two members settles (GroupRoomEndToEndTests). Startup is unchanged.

[WIN-ROWS-STEP-WALK] settings-gateway.py here also holds turns and slows one bot's open (Windows only, off until asked):
POST /__settings/hold {"steps": [{name, args}, ...]} makes each later reply's turn take the next step (message.start, its
tool.start, then running on it) until POST /__settings/release (120 s at most), when the step completes and the reply
writes; GET /__settings/state's `held` counts the turns holding. /__settings/fail's slow mode also takes "seconds" (0-60,
default 35) and "profile" (only that bot's calls take it). RowStepsEndToEndTests (e2e.sh's HQW_E2E_ROWSTEPS_PORT, default
9837; windows.yml's e2e step on 9837) and the row-steps walk (the "row-steps" screenshot extra on 9838) use them.

[WIN-36] composer-gateway.py has one Windows-only addition the reference copy lacks: the unlisted "Release review" chat
(`EXTRAS`, with a link, a wide table, a model-change note, a job delivery and two edited files in its history), its sends
(one taken and failed with a usage limit, `EXTRAS_REFUSED` refused), `GET /__extras/state`, and a synthetic link page and
icon under `GET /__extras/link/...`, answered on loopback only. It changes nothing the other walks and tests see; keep it
when refreshing the copy. e2e.sh and windows.yml already start the composer stand-in; the walk is `transcript-extras`.

[WIN-42] pages-fixture-gateway.py is unchanged for Tasks › Goals: its own --task-goals (with --task-lists) seeds the five
made-up goals of the reference copy. e2e.sh starts it so on HQW_E2E_GOALS_PORT (default 9818) for GoalsEndToEndTests,
windows.yml's e2e step on 9818, and its "tasks-goals" screenshot extra on 9818 for the tasks-goals walk.

[WIN-SCREEN-WALK] screen-gateway.py is written for Windows (Bot Screen over the real wire): the build 47 acceptance gateway
plus a synthetic display side for the demo bot otto. display.status / start / observe / lease.acquire / lease.release
answer as Hermes does (an unknown param is error 4000); `/api/display/ws?display_ticket=…` speaks RFB 3.8 in binary
WebSocket messages with one raw picture generated here (no desktop is read); `/api/plugins/hermes-hq-screen/health` is the
Mac plugin's health. The socket only decodes and records the client's KeyEvent and PointerEvent messages; nothing is ever
executed. `POST /__fixture/screen {"phase": "setup"|"mac"|"ready"}` moves it between no live screen (the setup card), a Mac
screen without control (Enable Control) and control set up (Take Control); `GET /__fixture/screen` is the record. Ports
9880-9889: e2e.sh's HQW_E2E_SCREEN_PORT (default 9880) for ScreenWireEndToEndTests, windows.yml's "screen" screenshot
extra on 9880 for the bot-screen-wire walk.
[WIN-SCREEN-SETUP-SEND-WALK] It also puts otto (Otto) in the roster with a bot chat of its own, and answers and records
`file.attach` (the data URL's decoded size and SHA-256 only, never its bytes; nothing is unpacked or run) and
`prompt.submit` in the record's "chat" list, so Set Up with Hermes can be pressed: ScreenSetupWireEndToEndTests and the
"screen" extra's bot-screen-setup-send walk.
