# Authority gateway test fixture (Hermes v0.23.0)

A real Hermes gateway, built from the `v0.23.0` tag, configured to host its own
dashboard/webapp listener with a **session authority** -- the exact shape the
tester's gateway-hosted Hermes was in when the app got `4001 invalid_params` on
`prompt.submit`/`session.redirect` and `-32601 unknown_method` on
`session.activate`.

## Run recipe

- Hermes checkout: `git -C ~/.hermes/hermes-agent worktree add
  /Users/me/Projects/hermes-agent-v023 v0.23.0` (already created).
- Python: the shared `~/.hermes/hermes-agent/venv` interpreter, but imports are
  forced to resolve from the v0.23.0 worktree via `PYTHONPATH`. Verified with
  `gateway.run_api.__file__` etc. pointing at
  `/Users/me/Projects/hermes-agent-v023/...`.
- **Do not** start it with `hermes gateway run` / `cli.py gateway run`: that
  command chain (`hermes_cli.gateway.run_gateway` ->
  `_attach_to_host_gateway_or_guard` / macOS launchd helpers) re-execs itself
  through the *installed* `~/.hermes/hermes-agent` checkout via an
  `osascript` detach, which silently drops `PYTHONPATH` and ends up testing
  the owner's installed commit instead of v0.23.0 -- and, worse, can race the
  owner's live gateway. Use `python -m gateway.run` directly instead: it is
  the same coroutine (`gateway.run_bootstrap.start_gateway`) without any of
  the CLI dispatch layer's supervisor/relaunch logic.
- Isolated home: `/tmp/hermes-authority-home` (`HERMES_HOME`), with its own
  `config.yaml` (see below). Never touches `~/.hermes`.
- Port: `9321` (free at the time of testing; confirmed via `lsof` that 9119
  and everything else already listening were avoided).

Start / stop:

```
./start-authority-gateway.sh
./stop-authority-gateway.sh
```

Credentials: `tester` / `testpass123`.

### config.yaml

```yaml
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
```

`webapp.enabled: true` makes the gateway bind its own listener and mount the
dashboard on it (`gateway/run_api.py::GatewayDashboardMount`), which is what
sets `app.state.session_authority` from `runner.session_authority` -- the
condition `tui_gateway/ws.py::_authority_connection` checks to route every
request through `gateway/session_controls.py::AuthorityConnection.dispatch`
instead of the legacy `server.dispatch`.

`model.provider: custom` with a bogus `base_url` is enough to pass the boot
provider-resolution check without a real provider; a submitted turn fails
later (background retry / "Transient APIConnectionError"), which is fine --
we only needed admission, not a real model reply.

### Why the Host header

A **loopback** bind (`webapp.host: 127.0.0.1`) alone leaves
`auth_required = false` (`hermes_cli/web_server_boundary.py::should_require_auth`
treats loopback as trusted), and the password-login/cookie/ws-ticket path
needs the gate engaged (`_require_session` 401s otherwise). Setting
`webapp.public_url` to a **non-loopback hostname**
(`http://authority-test.local:9321`) forces
`public_hosts_engage_gate()` to return true even though the socket still
binds `127.0.0.1`. Every HTTP request must then carry
`Host: authority-test.local:9321` (curl: `-H "Host: ..."`; the WS upgrade
needs it too) or the Host-header check in `_is_accepted_host` refuses it.
This reproduces a tester's real deployment, which is presumably reachable
through a non-loopback name/tunnel.

### Confirmed: session_authority is on

```
POST /auth/password-login {"provider":"basic","username":"tester","password":"testpass123"}
  -> 200, sets hermes_session_at_*/rt_*/provider_* cookies
POST /api/auth/ws-ticket  -> {"ticket": "...", "ttl_seconds": 30}
WS   /api/ws  Sec-WebSocket-Protocol: hermes-gateway-ticket.<ticket>, hermes-gateway-v1
  -> first frame: {"method":"event","params":{"type":"gateway.ready",
       "payload":{"session_authority": true, "skin": {...}, "heartbeat": ..., ...}}}
```

## Method probe results

Probed with a real session (`session.create` first, then every other call
against its `session_id`), params shaped like the app's own
`client.call(...)` sites in `HermesKit/`. Full raw JSON in
`/tmp/hermes-authority-home/probe_results.json` (regenerate with
`probe.py` saved alongside the gateway's own home, not committed here since
it is a scratch script).

| Method | Outcome | What the app must change |
|---|---|---|
| `session.create` | accepted | matches app's usage |
| `session.resume` | accepted | matches app's usage |
| `session.activate` | **`-32601 unknown_method`** | Not reachable under authority -- explicitly excluded from legacy fallback (`tui_gateway/ws_legacy_fallback.py::_SESSION_FALLBACK_ALLOWED` omits it). Replacement: `session.resume {session_id}` (same `CanonicalSnapshot` result shape `LiveChatSession+Sync.swift` already expects from resume). |
| `session.events.since` | accepted | matches app's usage |
| `prompt.submit` *(session_id, text, profile -- no submission_id)* | **`4001 invalid_params`** | `AuthorityConnection.submission()` (`gateway/session_controls.py:819`) requires a non-empty `submission_id` **or** `input_id`. The app worktree here (`authority-submit`) already sends `submission_id: AuthorityWire.submissionId(for: localId)` in `LiveChatSession.swift:1257` -- that fix is in place. |
| `prompt.submit` *(+ submission_id)* | accepted | returns an `AdmissionStatus` receipt (see below) |
| `session.redirect` *(session_id, text, profile -- no execution_generation)* | **`4001 invalid_params`** | `CanonicalCorrectionParams` (`tui_gateway/contracts/canonical_sessions.py:269`) extends `CanonicalControlParams`, which requires `execution_generation: int`. The app's `Contracts+composer.swift:176` (`finishSteer`) sends only `{session_id, text[, profile]}` -- it needs to add `execution_generation` (from the session's last-known `CanonicalSessionHandle`/snapshot, e.g. the `execution_generation` on `session.resume`'s result or the running turn's admission). |
| `session.interrupt` *(no execution_generation)* | `4001 stale_generation` | Same missing-field family; confirms `execution_generation` is load-bearing across all of `session.interrupt` / `session.redirect` / `session.steer` under authority. |
| `approval.respond` *(session_id, prompt_id, choice)* | **`4001 invalid_params`** | `CanonicalApprovalParams` extends `CanonicalControlParams` too -- also needs `execution_generation`. |
| `clarify.lock` *(session_id only)* | `4001 invalid_params, fields:["session_id"]` | Not session-scoped at all under authority: needs `request_id` + `question_id` (+ optional `answer`), no `session_id`. Matches what `ServerRequests.swift:876` already sends (not a bug once real params are used). |
| `session.title` | **`-32601 unknown_method`** | Replacement: `session.mutate {session_id, operation: "rename", ...}` (`gateway/session_mutations.py::_METADATA` includes `rename`). |
| `session.close` | **`-32601 unknown_method`** | Replacement: `session.detach {session_id, subscription_id[, end_reason]}` (`AuthorityConnection.detach`, `session_controls.py:720`) -- needs the `subscription_id` the authority handed back on `session.create`/`session.resume`'s snapshot, which `session.close` never carried. |
| `session.list` | accepted | matches app's usage |
| `session.control` *(made-up action)* | `4001 invalid_params` | Handler exists and is authority-routed; refusal here is just an unknown action name in the test, not an authority gap. |
| `session.control.read` | accepted | matches app's usage |
| `subagent.list` | accepted | |
| `subagent.steer` | accepted (`status: "rejected"` for a made-up subagent id) | |
| `image.attach` | refused (`session not found`, bespoke message/no `data`) -- a fake path, not an authority gap | |
| `file.attach` | refused (`invalid_params`) with a fake path -- same | |
| `agents.list` | **`-32601 unknown_method`, permanently** | `agents.list` is in `tui_gateway/ws_legacy_fallback.py::_PROCESS_GLOBAL`, explicitly barred from legacy fallback under authority (it acts on process-global state: every chat's/profile's processes). No direct authority replacement found; closest session-scoped equivalent is `process.list {session_id, profile}` (accepted, see below). |
| `approval.pending` | accepted | |
| `billing.state` | accepted | |
| `config.get` *(no `key`)* | `4001 invalid_params` | Handler requires `key` (app always sends one in `ModelMenuModel.swift:287`) -- not an authority gap. |
| `delegation.status` | accepted | |
| `mcp.servers.list` | accepted | |
| `mcp.servers.status` | accepted | |
| `plugins.manage` | accepted | |
| `process.list` | accepted | |
| `profiles.list` | accepted | |
| `projects.tree` | accepted | |
| `session.active_list` | accepted | |
| `session.branch_stored` | **`-32601 unknown_method`** | Deliberately blocked (`ws_legacy_fallback.py` comment: a legacy `session.branch_stored` "built a second, legacy-owned runtime"). Replacement: `session.mutate {session_id, operation: "branch", ...}`. |
| `session.foreign.list` | legacy fallback reached (it's allow-listed); refused only because the test used an invalid `source` value -- not an authority gap | |
| `session.workspace.move` | **`-32601 unknown_method`** | Deliberately blocked (same comment: "rewrote only the row, never the frozen policy"). Replacement: `session.mutate {session_id, operation: "workspace", ...}`. |
| `setup.runtime_check` | accepted | |

### `prompt.submit` receipt shape (accepted case)

```json
{
  "admission_id": "95b3fcda500b40cc998903ad0828b13a",
  "ref": {"profile_id": "/private/tmp/hermes-authority-home",
          "session_id": "local-1c0f24a8..."},
  "sequence": 2,
  "status": "queued",
  "outcome": null,
  "authority_epoch": 4,
  "execution_generation": null
}
```

This is `AdmissionStatus` (`tui_gateway/contracts/canonical.py`). The app's
`LiveChatSession.swift::acknowledge(localId:result:epoch:)` reads
`result["status"]`, `result["user_row_id"]` from the trace log line at
`LiveChatSession.swift:1273` -- **`user_row_id` is absent from the authority's
receipt.** The legacy (non-authority) `prompt.submit` apparently returns a
`user_row_id`; the authority's `AdmissionStatus` does not carry one. If
`acknowledge` depends on `user_row_id` to key the optimistic local bubble,
that is a second thing worth checking against `LiveChatSession.swift`'s
`acknowledge` implementation -- it fell back to `nil` cleanly in this probe
but is worth a deliberate look.

### Event stream after `prompt.submit`

Frames observed, in order, after an accepted `prompt.submit` (all wrapped as
`{"jsonrpc":"2.0","method":"event","params":{...}}`):

1. `session.info` (`pending: [...]` with the admission)
2. `message.start` (`admission_id`, `execution_generation: 1`)
3. `session.info` (again, now carrying `source`, `model`, etc.)
4. `agent.step` (`iteration: 1`)
5. `thinking.delta` (text chunks -- the dummy model's own "thinking", since no
   real provider is configured)
6. `sessions.changed` / `platforms.changed` (store-wide, `session_id: ""`)

Every per-turn frame after the first carries `authority_epoch` and
`execution_generation`, which is what `session.redirect`/`session.interrupt`
need back from the client. This lines up with
`HermesKit/Chat/LiveChatSession+Events.swift` keying turns by
`execution_generation` -- worth confirming it reads `execution_generation`
off these event frames (not just off `session.resume`'s snapshot) so a
`session.redirect` sent mid-turn has a fresh value.

## Stopping

The gateway was stopped after this investigation
(`stop-authority-gateway.sh`). `/tmp/hermes-authority-home` (config, logs,
state.db) is left in place so it can be restarted for a simulator run later.

## Driving the app against it (2026-11-06 end-to-end run)

- For a simulator, set `webapp.host: 0.0.0.0` and `public_url: http://<this Mac's LAN IP>:9321` (a literal LAN IP
  as `host` is refused; RFC1918 http is allowed by `GatewayAddress.cleartextAllowed`).
- A reply needs a model: point `model.base_url` at a tiny OpenAI-compatible fake (`/v1/chat/completions`, SSE; slow
  streaming for prompts containing "slow" so Stop/Steer can be tried).
- Build with its own derived data (`-derivedDataPath build/dd-e2e`) on a fresh simulator; delete it afterwards.
- Sign in without UI: `SIMCTL_CHILD_HQN_SIGNIN_URL/USERNAME/PASSWORD` (`SignInService.debugSignInFromEnvironment`),
  then launch args `-HQDebugResetAccounts YES -HQDebugOpenBot default -HQDebugSend "<text>"`, `-HQDebugQueue "/stop"`.
- Results with the fix: new chat (session.create), send + reply, Stop (session.interrupt), Steer (session.redirect)
  and a cold relaunch (session.resume) all accepted. Still refused (not fixed): session.title, session.close,
  session.branch_stored, session.workspace.move, agents.list, and rewind/edit sends (truncate keys).
