# 02 — Bots list, Sessions list, and robot heads

Implementation spec for the native rebuild of the Bots tab, the basic Sessions tab and the bot heads, mapped from
the web app at release-build238. Where this spec and the docs disagree, the spec follows the code the phone runs
today and says so.

## 0. Conventions

### 0.1 Citation key

| Prefix | Path |
| --- | --- |
| `S/` | `/Users/me/Projects/hermes-hq-native-ref238/src/` (Hermes HQ phone code) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref238/build/` (build-time "gates": exact-string patches applied to the vendored Hermes renderer; they show what the phone runs) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref238/vendor/hermes/apps/desktop/src/` (vendored Hermes desktop renderer, commit `02e41181`, `vendor/source.json`) |
| `HB/` | `V/plugins/hermes-bots/` (the desktop's "Bot Mode" plugin, the roster's real owner) |
| `C:` | `/Users/me/Projects/hermes-hq-native-ref238/vendor/hermes/apps/shared/src/gateway-contract.openrpc.json`, `components.schemas.<Name>` (the pinned JSON-RPC contract) |
| `AG/` | `/Users/me/.hermes/hermes-agent/` (gateway source, HEAD `d94b70f`, 2026-10-08; read only) |
| `FX/` | `/Users/me/Projects/hermes-hq-native-ref238/scripts/` (fixture gateways) |
| `GP/` | `/Users/me/Projects/hermes-hq-native-ref238/gateway-plugin/hermes-hq-performance/` (optional HQ gateway plugin) |

`file:N` is a line, `file:N-M` a range. A claim tagged **[gate]** is behaviour that exists only because a `B/` gate
rewrote vendored code; read the gate, not the vendored file alone.

### 0.2 Version skew to keep in mind

- The contract in `C:` was generated at vendored commit `02e41181`. The live gateway (`AG/`, `d94b70f`) adds fields
  the contract does not list (`install_id` on `profiles.list`, `live_message_count` on session summaries,
  `_lineage_root_id` on `session.list` rows). Decode leniently: unknown keys ignored, every documented key optional
  unless marked required.
- The `C:` schemas say `additionalProperties: false`; the gateway does not honour that. Never fail on extra keys.

### 0.3 Transport primer (only what this area needs)

- JSON-RPC 2.0 over the gateway WebSocket `/api/ws` (ticket auth and reconnect belong to the transport spec). The
  phone opens it as `ws(s)://<base>/api/ws?profile=<default profile>` (`S/bridge/shim.ts:71-76`).
- Request frame: `{"jsonrpc":"2.0","id":17,"method":"profiles.list","params":{}}`. **Ids are incrementing
  integers** (1, 2, 3… per client instance): the phone's socket client is the vendored `HermesGateway`, which passes
  `createRequestId: nextId => nextId` (`V/api/client.ts:36`; instantiated with no options at `V/store/gateway.ts:1085`
  and `V/app/gateway/hooks/use-gateway-boot.ts:962`). The string form `r<n>` is only the shared channel's fallback when
  no `createRequestId` is given (`V/../../shared/src/json-rpc-channel.ts:206`) and never reaches the wire from the
  phone. Same rule as `01-transport-auth.md` §11.2 and `04-send-stream-stop.md` §1.2.
- Success: `{"jsonrpc":"2.0","id":17,"result":{…}}`; failure:
  `{"jsonrpc":"2.0","id":17,"error":{"code":5061,"message":"…","data":…?}}` (`AG/tui_gateway/server.py:881-887`).
- Per-call client timeout: **30 s** unless a call passes its own (`V/api/client.ts:17,44`; the channel rejects with
  `request timed out after 30s: <method>` and drops the id, `V/../../shared/src/json-rpc-channel.ts:287-297`). The
  gateway is not told and keeps working (§2.1.1).
- "Method not found" is code `-32601` or a message matching `/method not found|unknown method|unsupported method/i`
  (`S/performance-contracts.ts:24`).
- REST reads go to the same base URL. The phone adds `?profile=<owner>` to every `/api/…` path that does not
  already carry `profile` (`S/bridge/shim.ts:35-44`). Non-2xx is a failure (`S/bridge/shim.ts:113`).

---

## 1. What a "bot" is

1. **A bot is a Hermes profile.** One roster row per profile returned by `profiles.list`
   (`HB/types.ts:1-10`; `V/AGENTS.md:65-68` "Each bot is a Hermes **profile**").
2. **The primary profile is named `default`** and is presented as **"Hermes"** unless given a title
   (`HB/labels.ts:52-57`, `S/ui-kit/bot-identity.ts:63-66`). Its @handle is `hermes`, never `default`
   (`HB/data.ts:1011-1017`). It cannot be deleted (`V/api/profiles.ts:52-63`).
3. **Each bot has exactly one "forever chat": the session titled exactly `Bot Chat` in that profile's state DB.**
   Identity is the *name*, not a stored id. No client may store a session-id pointer as the bot's chat
   (`V/AGENTS.md:65-99`, `HB/canonical-chat.ts:21-49`). The gateway resolves it per profile and reports it as
   `canonical_session` on every `profiles.list` row (`AG/tui_gateway/methods_profiles.py:161-195`).
4. **Bot Chats are always hidden** (`sessions.hidden = 1`): they never appear in session listings unless
   `include_hidden` is asked for, so the bot row is the only door to them (`V/AGENTS.md:84-88`,
   `AG/hermes_state_sessions.py:1369-1373`).
5. **Per-bot presentation state** (title, pin, hidden, section, colour…) lives in the profile's `profile.yaml`
   under `ui_meta['hermes-bots']`, returned on each `profiles.list` row (§5). **The head** lives beside it under
   `ui_meta['dispatch-head']` (§10).
6. **Group chats ("rooms")** also appear as rows on the Bots tab; they are desktop-plugin records synced through
   other RPCs (`groups.*`) and are out of scope here except for their row shape (§6.9).

### 1.1 Keys a native client needs

On the phone every roster row is stamped with the single connection id `ios-direct`
(`S/bridge/renderer-host.ts:115-121`), so:

| Key | Formula | Example | Use | Source |
| --- | --- | --- | --- | --- |
| roster key | `${connectionId \|\| 'legacy'}::${name \|\| 'default'}` | `ios-direct::ivy` | row identity, pin order, drag | `HB/data.ts:1286-1288` |
| meta key | `${route.connectionId}::${route.profile}` | `ios-direct::ivy` | local meta snapshot key | `HB/data.ts:1297-1307`, `HB/routing.ts:14-16` |
| identity key | profile lowercased (prefix `<conn>::` only for a remote-source row) | `ivy` | mute key `bot:ivy`, identity | `S/ui-kit/bot-identity.ts:71-73`, `S/ui-bots/bot-mute.ts:18` |
| activity owner | `JSON.stringify([connectionId \|\| 'local', name \|\| 'default'])` | `["ios-direct","ivy"]` | unread baselines | `S/bot-unread-activity.ts:16` |
| canonical ids | `{canonical_session.id, canonical_session.resolved_id}` (deduped) | `["2026…_a1","2026…_b7"]` | unread matching | `S/bot-unread-activity.ts:17` |
| canonical stored id (for state) | `resolved_id ?? id` | lineage tip | dot state / session-state lookups | `HB/row-helpers.ts:68-70` |

Native recommendation: key everything by `(gatewayAccount, profileName)`; keep both canonical ids per bot.

---

## 2. Calls this area makes

### 2.1 `profiles.list` (JSON-RPC) — the roster

**Request** (`HB/data.ts:682`; slim variant **[gate]** `B/fe-lists-gates.ts:284-297`):

```json
{"jsonrpc":"2.0","id":12,"method":"profiles.list","params":{}}
{"jsonrpc":"2.0","id":9,"method":"profiles.list","params":{"include_sessions":false}}
```

Params (`C:ProfilesListParams`): `profile` (string|null, ignored by the handler for listing), `include_sessions`
(bool|string|null, default **true**; truthy parsing via `is_truthy_value`) (`AG/tui_gateway/methods_profiles.py:281-286`).
Lists **every** profile of the gateway's Hermes root regardless of the socket's profile.

**Result** (`AG/tui_gateway/methods_profiles.py:281-302`, `C:ProfilesListResult`, `C:ProfileRow`):

| Field | Type | Notes |
| --- | --- | --- |
| `profiles` | ProfileRow[] | order = `hermes_cli.profiles.list_profiles` order (not activity) |
| `bot_mode_protocol` | bool | always `true` on current gateways (`:301`) |
| `install_id` | string | not in `C:`; same value as `/api/status` (`:300-301`) |

ProfileRow (key order is the wire order, `:288-297`):

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string (required) | profile id (`default`, `ivy`…) |
| `path` | string (required) | profile dir on the gateway host |
| `is_default` | bool | |
| `model`, `provider` | string\|null | |
| `description` | string | profile.yaml description ("role") |
| `display_name` | string | profile.yaml display name (`hermes profile rename`) |
| `skill_count` | int | lazily refreshed |
| `previous_names` | string[] | old names after renames |
| `last_session` | ProfileSessionPreview\|null | **only when include_sessions**; newest *visible, human-facing* session (hidden rows and `kanban`/`tool`/`oneshot` sources excluded) |
| `worker_session` | ProfileWorkerSession\|null | include_sessions only; newest denied-source (worker) row |
| `canonical_session` | ProfileCanonicalSession\|null | include_sessions only; the `Bot Chat` row |
| `ui_meta_revisions` | `{[key]:int}` | **always present** (maybe `{}`); per-ui_meta-key CAS revision |
| `ui_meta` | object | present only when non-empty; YAML dates coerced to ISO strings |
| `has_avatar` | bool | `assets/avatar.{png,jpg,webp}` exists |

`canonical_session` (`AG/tui_gateway/methods_profiles.py:161-195`, `C:ProfileCanonicalSession`):
`id` (registry row = durable identity), `resolved_id` (compression-lineage tip — **the id you open**), `root_title`
(`"Bot Chat"`), `title` (tip's title), `preview`, `started_at`, `last_active` (tip `last_activity_at`, else
`started_at`; **unix seconds, float**), `message_count` (tip's stored count, **includes tool-call and tool-result
rows**), `live_message_count` (newer gateways; displayable rows). `null` when the profile has no `Bot Chat`, when the
row's source is a denied worker source, or when it is deliberately archived (an accidentally archived one is
resurrected server-side, `:125-147,176-182`).

`last_session` (`:198-228`, `C:ProfileSessionPreview`): `id, title, preview, started_at, last_active, message_count,
live_message_count?`. Scans only the 20 most recent rows (`limit=20`, `:212`).
`worker_session`: `id, source, title, last_active` (workers heartbeat ≤60 s, `:200-209`).

`preview` everywhere here = whitespace-collapsed text of the **newest active user/assistant message**, cut to 80
chars + `"..."` (three ASCII dots) when longer, `""` when none (`:108-122`).

Errors: any exception → `{"code":5061,"message":<str(e)>}` (`:23-32,281`). Session fields are best-effort: a
missing/locked DB yields `null`s, not an error (`:198-209,231-253`).

**Cost:** the full call walks every profile's session store; on the owner's gateway it took 2.5–30 s
(`S/roster-cache.ts:1-8`, `S/fe-lists-r3.ts:210-215`), and a later gate comment measured **18–107 s** under load
(`B/fe-lists-gates.ts:1272-1276`; "can take a minute" `S/fe-lists-r3.ts:207-208`, `S/phone-refresh.ts:20`). The gateway
memoises per-profile session fields until the store changes (`AG/tui_gateway/methods_profiles.py:250-253`,
`AG/tui_gateway/profile_roster_cache.py:82-93`). Timeout and retry: §2.1.1.

**Example A — verbatim fixture** (`FX/action-voice-fixture-gateway.py:25-28,56-59`; note this fixture puts
`display_name` inside `ui_meta['hermes-bots']`, which real gateways never do, and puts `hidden` etc. on the canonical
row):

```json
{"active":"default","profiles":[
 {"name":"default","is_active":true,"description":"Synthetic voice QA","model":"fixture-model",
  "canonical_session":{"id":"20260929_120000_aabbcc01","title":"Bot Chat","profile":"default","profile_name":"default",
    "hidden":true,"model":"fixture-model","billing_provider":"fixture","message_count":1,
    "started_at":1790686800,"last_active":1790686800,"source":"desktop","cwd":"/fixture"},
  "sessions":[…same row…],
  "ui_meta":{"hermes-bots":{"display_name":"Hermes"}}},
 {"name":"ivy", … "ui_meta":{"hermes-bots":{"display_name":"Ivy"}}}]}
```

**Example B — real shape, constructed field-for-field from `AG/tui_gateway/methods_profiles.py:161-301`**
(values illustrative):

```json
{"jsonrpc":"2.0","id":12,"result":{
 "profiles":[
  {"name":"default","path":"/Users/me/.hermes","is_default":true,"model":"claude-opus-5-5","provider":"anthropic",
   "description":"","display_name":"","skill_count":41,"previous_names":[],
   "last_session":{"id":"20260101_090000_aa0007","title":"Standup notes","preview":"Here are today's three items: ...",
     "started_at":1791972072.1,"last_active":1791975610.4,"message_count":14,"live_message_count":9},
   "worker_session":{"id":"20261009_101500_kb77aa","source":"kanban","title":"work kanban task t_522444de","last_active":1791980100.0},
   "canonical_session":{"id":"20260101_090000_aa0005","resolved_id":"20260101_090000_aa0006","root_title":"Bot Chat",
     "title":"Bot Chat","preview":"Done. I pushed the fix and opened PR #412.","started_at":1791266130.0,
     "last_active":1791981234.9,"message_count":388,"live_message_count":171},
   "ui_meta_revisions":{"hermes-bots":12,"dispatch-head":3},
   "ui_meta":{"hermes-bots":{"pinned":true,"sectionId":"hermes-hq-pinned","sectionName":"Pinned","pinnedFrom":null,"created":1757950000000},
              "dispatch-head":{"v":6,"theme":"shape","color":"cobalt","seed":7,"form":"blob","look":"slits","specs":"none","hat":"none",
                               "mouth":"none","blush":false,"tile":"none","shape":"dome","face":"visor","visor":"band","shell":"ink",
                               "antenna":"bulb","ears":"headset","headset":true,"hair":"bob","pattern":"face","eyes":true,"glyph":"✨"}},
   "has_avatar":true},
  {"name":"ivy","path":"/Users/me/.hermes/profiles/ivy","is_default":false,"model":null,"provider":null,
   "description":"Research assistant","display_name":"","skill_count":12,"previous_names":[],
   "last_session":null,"worker_session":null,"canonical_session":null,
   "ui_meta_revisions":{},"has_avatar":false}],
 "bot_mode_protocol":true,"install_id":"c0ffee00-…"}}
```

### 2.1.1 Client timeout and retry for `profiles.list` (resolved)

**What the web phone does today**

| Read | Timeout | Source |
| --- | --- | --- |
| full `profiles.list {}` (or `profiles.summary`) | **30 s** — no per-call override anywhere on the path | call `HB/data.ts:682` (gated by `B/fe-lists-gates.ts:315,1869`, `B/data-performance-gates.ts:85`) → `requestForBot(activeBot,…)` with no `timeoutMs` (`HB/routing.ts:217-258`; `activeBot = {name}` is not source-scoped, `HB/routing.ts:37-42`, so it takes the `host.request(method, params)` branch, `HB/routing.ts:251-254`) → `host.request` with `timeoutMs` undefined (`V/sdk/index.ts:1619-1628`, `V/../../shared/src/json-rpc-gateway.ts:403-406`) → `HermesGateway` default `DEFAULT_GATEWAY_REQUEST_TIMEOUT_MS = 30_000` (`V/api/client.ts:17,44`) |
| slim `profiles.list {include_sessions:false}` | 30 s (same path) | `B/fe-lists-gates.ts:286-293` |
| REST `GET /api/profiles` (union read, §2.3) | 60 s `STARTUP_REQUEST_TIMEOUT_MS` applies to the vendored REST helper (`V/api/profiles.ts:10-15`, `V/api/client.ts:16`); the 60 s "boot" value is **not** used for the RPC | |

- No phone gate or `src/` file overrides the 30 s RPC default (no match for `requestTimeoutMs` /
  `DEFAULT_GATEWAY_REQUEST_TIMEOUT_MS` outside the probe client at `S/bridge/shim.ts:128`).
- The gate comment "The request itself keeps upstream's timeout … a 20 s cap (tried) meant the roster never loaded at
  all" (`B/fe-lists-gates.ts:1272-1276`) refers to that 30 s default.
- **Retry:** the roster query retries a failed read up to `ROSTER_QUERY_RETRY = 2` more times (`HB/data.ts:42`), only
  while the app is not hidden (**[gate]** `B/fe-lists-gates.ts:355` then `B/bot-unread-gates.ts:81`), delay
  `min(15 s, 1 s × 2^attempt)` (`HB/data.ts:738`). A retry skips the slim read (`S/roster-cache.ts:139-141`). After
  that the normal poll (§3.6) tries again.
- A timeout reads as "busy" (`gatewayBusy`, `/timed?\s*out|timeout|…/i`, `S/list-helpers.ts:73-76`): with no rows painted
  the error card says "Your gateway is busy, so your bots couldn’t load in time." (**[gate]** `B/fe-lists-gates.ts:1293-1298`);
  over a painted list it is the stale card (§3.8). The first load shows "Still loading your bots… Your gateway is taking
  longer than usual." + Retry after 15 s (`B/fe-lists-gates.ts:1279`).
- **Disagreement flagged:** 18–107 s observed vs a 30 s client timeout. The roster still loads because the gateway does
  not stop on a client timeout: `profiles.list` runs on the long-handler thread pool (`AG/tui_gateway/server.py:181-202`,
  8 workers by default), completes, and stores each profile's session fields in the memo keyed on `state.db` /
  `state.db-wal` `(mtime_ns,size)` (`AG/tui_gateway/profile_roster_cache.py:52-89`); the dropped answer warms the memo,
  so a retry or the next poll is cheaper for every profile whose store did not move. (Inference from the code; not
  measured.) Side effect: each retry after a timeout starts a **second full computation while the first may still be
  running** on the same 8-worker pool.

**Native rule (spec decision; deliberate divergence from the web, client-side only)**

1. Full read: **120 s** timeout (the shared channel's own default, `V/../../shared/src/json-rpc-channel.ts:148`; covers
   the 107 s worst case observed). Slim read: 30 s.
2. Single-flight: never send a full `profiles.list` while another full one is in flight on the same account
   (the web phone shares in-flight identical reads too, `S/rpc-flight.ts:81-88,152`).
3. On timeout: no immediate retry; keep the painted roster, show the §3.8 stale/busy state, and let the next poll
   (§3.6, `max(30 s, 10 × last successful read)`) ask again. Other errors: retry at 1 s then 2 s while the app is
   foreground (web parity), then wait for the poll.
4. Pull-to-refresh joins an in-flight full read instead of starting another (`B/fe-lists-gates.ts:350`
   `refetch({cancelRefetch:false})`).

### 2.2 `profiles.summary` (optional, HQ performance plugin)

Used instead of `profiles.list` **only** when the socket's `gateway.ready` event carried
`payload.performance.roster_summary === 1` (`S/performance-contracts.ts:18-23,27-43`; advert
`GP/adapter.py:15-16,164-179`).

```json
{"method":"profiles.summary","params":{"schema":"roster.summary.v1","include_meta":true,"if_version":"<last version>"}}
```

Result: the `profiles.list` envelope plus `"schema":"roster.summary.v1","version":"<sha256 hex>"`; or, when
`if_version` matches, `{"schema":"roster.summary.v1","version":"…","not_modified":true}` (`GP/adapter.py:136-162`).
The client validates `schema`, `version` (string ≤128) and falls back to `profiles.list {}` forever on `-32601`
(`S/performance-contracts.ts:31-41`). Cache key per owner, 16 entries.

**Discrepancy:** the plugin's `last_session` (`GP/adapter.py:107-120`) does **not** exclude hidden rows, so it can
name the hidden Bot Chat; the real `profiles.list` excludes hidden rows (`AG/hermes_state_sessions.py:1372-1373`).
Native M1 can skip this optimisation entirely.

### 2.3 `GET /api/profiles` (REST) — profile list and the phone's "agent union"

- Response `{"profiles":[ProfileInfo…]}` with `name, path, is_default, model, provider, has_env, skill_count,
  gateway_running, description, description_auto, display_name, bot_title, distribution_*, has_alias`
  (`AG/hermes_cli/web_routers/profiles.py:83-99,794-807`). **No** `ui_meta`, no sessions.
- The phone calls it for two things: (a) the renderer's `$profiles` store (owner names on Sessions rows,
  `S/audit-c-format.ts:401-407`), and (b) `host.agents()`, which the phone implements as this read reshaped to
  `{agents:[{connectionId:'ios-direct',connectionKind:'remote',connectionLabel:'Hermes gateway',profile,targetProfile:profile,handle:profile}],sources:[{connectionId:'ios-direct',label:'Hermes gateway',kind:'remote',reachable:true}]}`
  (`S/bridge/renderer-host.ts:115-120`). It throws `Invalid gateway profile roster` if any row lacks a name.
- The union read is reused for 10 min unless `profiles.list` names a profile it lacks (`S/fe-lists-r3.ts:178-203`).
- Native: (b) only stamps identity; you do not need it. Keep (a) or derive names from `profiles.list`.

### 2.4 Writes on bot meta and avatars

`profiles.configure` (`AG/tui_gateway/methods_profiles.py:385-408,593-645`, `C:ProfilesConfigureParams`):

```json
{"method":"profiles.configure","params":{"name":"ivy","ui_meta":{"hermes-bots":{ …WHOLE merged meta… }}}}
{"method":"profiles.configure","params":{"name":"ivy","ui_meta":{"dispatch-head":{…}},"ui_meta_expected_revisions":{"dispatch-head":3}}}
```

- Merge is **per top-level `ui_meta` key**: the value you send for `hermes-bots` *replaces* the whole
  `hermes-bots` object; `null` deletes the key; other keys are untouched (`:619-627`). The web client therefore
  always sends its full merged `hermes-bots` object minus `image`/`pet` (`HB/data.ts:350-372`).
- 64 KB cap on `json.dumps(ui_meta)`; over it → `applied.ui_meta=false`, nothing written (`:598-600`).
- CAS: `ui_meta_expected_revisions` per key; any mismatch writes nothing and returns
  `applied.ui_meta_conflicts = {key:{expected,actual}}` (`:602-616`).
- Result `{"ok":bool,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":13}},…}`. Errors: 4063 name
  required, 4064 profile not found (`:72-84`), 5064 other.
- Client outcome rule (`HB/data.ts:410-438`): `applied.ui_meta===true` → persisted; an `applied` object without
  it → failed (show it); no `applied` / RPC error → "older gateway", keep the local copy silently.

`profiles.set_asset` / `profiles.get_asset` (`AG/tui_gateway/methods_profiles.py:411-463`):

```json
{"method":"profiles.set_asset","params":{"name":"ivy","asset":"avatar","data":"data:image/png;base64,…"}}
{"method":"profiles.set_asset","params":{"name":"ivy","asset":"avatar","clear":true}}
{"method":"profiles.get_asset","params":{"name":"ivy","asset":"avatar"}}
→ {"found":true,"mime":"image/png","size":48213,"data":"data:image/png;base64,…"}   |   {"found":false}
```

PNG/JPEG/WebP only, sniffed by magic bytes, ≤2,000,000 bytes; errors 4066 unknown asset, 4067 no data, 4068 bad
base64, 4069 too large, 4070 bad format, 5065/5066 other.

### 2.5 Calls made when a bot is opened

See §8 for the algorithm (on the usual tap this `session.list` is sent at the same moment as the open of the roster's
known chat, not before it). Wire shapes:

```json
{"method":"session.list","params":{"profile":"ivy","title":"Bot Chat","limit":200,"include_hidden":true}}
→ {"sessions":[{"id":"20260101_090000_aa0005","resolved_id":"20260101_090000_aa0006","title":"Bot Chat",
               "preview":"…","started_at":1791266130.0,"message_count":388,"source":"desktop",
               "_lineage_root_id":null,"live_message_count":171}]}        or   {"sessions":[]}
```

Title lookup is exact and window-free; hidden rows resolve; archived rows and denied sources (`kanban`, `tool`,
`oneshot`) return `[]`; the tip is reported as `resolved_id` (`AG/tui_gateway/methods_session.py:118-130,522-554`,
`AG/hermes_state_sessions.py:236`). The DB is chosen by `params.profile` (`AG/tui_gateway/server.py:498-523`).
Error code 5006. Note the title-lookup row has **no `last_active` and no `root_title`**; the client treats
`root_title || title === "Bot Chat"` as the match (`HB/canonical-chat.ts:155-160`).

```json
{"method":"session.create","params":{"profile":"ivy","title":"Bot Chat","hidden":true,"follow_profile_config":true}}
→ {"session_id":"<runtime id>","stored_session_id":"<stored id>","message_count":0,"messages":[],"info":{…}}
{"method":"session.title","params":{"session_id":"<runtime id>","title":"Bot Chat"}}
→ {"title":"Bot Chat","session_key":…,"pending":…}
```

(`HB/canonical-chat.ts:426-474`, `C:SessionCreateParams`, `C:SessionCreateResult`, `C:SessionTitleParams`). A title
clash fails with a message matching `/already in use/i` (`HB/canonical-chat.ts:480`).

### 2.6 Sessions list reads

`GET /api/profiles/sessions/sidebar` (the Sessions tab) — §9.1.
`GET /api/profiles/sessions?limit=7&offset=0&min_messages=1&archived=exclude&order=recent&profile=<p>` (an empty
Bot Chat's "recent activity", `S/bot-recent.ts:10-12`; handler `AG/hermes_cli/web_routers/profiles.py:456-505`).
`PATCH /api/sessions/{id}` with any of `title, archived, hidden, pinned, unread` and `profile` in the body
(`AG/hermes_cli/web_routers/sessions.py:881-920`; client `V/api/sessions.ts:413-426`).

---

## 3. Roster fetch pipeline on the phone (ordering and cadence)

The web phone paints the Bots list in up to three stages, then polls. Native should keep the stages and the cadence.

1. **Cached paint.** On first render the query's `initialData` is the last *full* roster this device saw for this
   gateway account: localStorage `dispatch.roster.v1` =
   `{"<baseUrl>|<connectionId>":{"at":<ms>,"profiles":[…non-ghost rows…]}}`, the 3 most recent accounts kept
   (`S/roster-cache.ts:15-33,88-105`; wired **[gate]** `B/fe-lists-gates.ts:268-331`). Marked `dispatchPartial:'cache'`.
2. **Slim answer.** `profiles.list {include_sessions:false}` (plus the union read), merged over the cached rows so
   each bot keeps its previous `last_session`/`worker_session`/`canonical_session` and identity fields until the full
   answer lands (`S/roster-cache.ts:106-123,139-152`). Only sent when the current data is absent or still the cache
   and this is not a retry; the full request waits for it at most `SLIM_WAIT_MS = 1500` ms. Marked
   `dispatchPartial:'slim'`.
3. **Settle.** The full read waits until the socket has been open `ROSTER_SETTLE_MS = 2000` ms, so launch's own
   reads go first (`S/roster-cache.ts:154-165`).
4. **Full answer.** `profiles.list {}` (or `profiles.summary`, §2.2). A read that falls due while a chat is opening
   waits up to 5 s for the open (`S/fe-lists-r3.ts:218-229`). Only a full answer is written to the cache, merged
   into bot meta, used for avatar pulls and for unread tracking (`S/phone-bot-unread-poll.ts:30`,
   **[gate]** `B/fe-lists-gates.ts:356-371`).
5. **Text hygiene before use.** Fields `name,title,display_name,description,connectionLabel` and meta
   `title,description,color,shape,image` that arrive as numbers/bools are converted to strings; objects dropped
   (`S/roster-cache.ts:35-72`). Do the same when decoding (YAML can give `title: 2025`).
6. **Poll cadence** **[gate]** (`B/fix160-net-gates.ts:13-14`, `S/fe-lists-r3.ts:209-229`, `S/power-state.ts:10,38-40`):
   - app in background: no polling; on return, refetch if data is older than the poll period.
   - Bots or Sessions list on screen: every `max(30 s, 10 × duration of the last full read)`.
   - anywhere else: every `max(120 s, 10 × last read)`.
   - Low Power Mode / thermal: × 3.
   - Coming back to the Bots list with data older than 30 s refreshes at once without cancelling a read in flight
     (**[gate]** `B/fe-lists-gates.ts:341-349`, `B/bot-unread-gates.ts:80-82`).
   - Failure retry: up to 2 retries, `min(15 s, 1 s × 2^attempt)` apart, while the app is not hidden
     (`HB/data.ts:42,737-738`, **[gate]** `B/bot-unread-gates.ts:81`). Timeout policy: §2.1.1.
   - Pull-to-refresh refetches (`registerPhoneRefresh('roster',…)`, `B/fe-lists-gates.ts:350`).
   - Note: the vendored desktop default of 5 s (`HB/data.ts:735`) is overridden on the phone.
7. **Merge with the union** (`HB/data.ts:815-1004`): on a single-gateway phone every union agent is the active source,
   so the union only annotates rows with `connectionId:'ios-direct'`, `connectionKind:'remote'`,
   `connectionLabel:'Hermes gateway'`, `handle`, `targetProfile`, `route`, `sourceScoped:true`, plus
   `sourceReachable:true` (`HB/data.ts:1331-1359`). No new rows are added. Rows are cloned before annotation.
8. **States** (`S/ui-bots/roster-states.tsx:28-37`): `loading` (no rows yet: 6 skeleton rows; after a long wait
   "Still loading your bots… Your gateway is taking longer than usual." + Try Again), `error` (no rows),
   `empty` (0 profiles), `hidden` (all bots hidden), `search`/`filtered`/`no-groups` (filters match nothing),
   `list`. A failed refresh over a painted list shows a card: "Can’t refresh bots. Showing the list from
   9:41 AM." or "Waiting for your gateway. …" + Try Again (`S/ui-bots/roster-states.tsx:71-77`).

---

## 4. (reserved — transport-level details live in the transport spec)

---

## 5. Bot meta: `ui_meta['hermes-bots']`

### 5.1 Fields (`HB/types.ts:60-104` plus the HQ-only `pinnedFrom`)

| Field | Type | Meaning |
| --- | --- | --- |
| `title` | string | display name override (wins over everything) |
| `description` | string | role line override |
| `pinned` | bool | pinned bot |
| `hidden` | bool | hidden from the Bots list (display only; bot keeps working) |
| `sectionId` | string\|null | user section the bot is filed under (`hermes-hq-pinned` = Pinned) |
| `sectionName` | string\|null | that section's name (lets another device rebuild it) |
| `pinnedFrom` | `{id,name}`\|null\|false | **HQ**: where a pin moved the bot from (`S/ui-bots/pinned-section-model.ts:7-10`) |
| `color`, `shape`, `custom` | string, string, bool | desktop face appearance (ignored when heads draw, §10) |
| `imageKind` | `'photo'\|'shape'` | |
| `groups`, `group` | string[], string\|null | group-chat membership |
| `screenAutoOpen` | bool | desktop only |
| `created` | number (ms) | creation time; sort fallback |
| `chat` | — | **dead legacy pointer; ignore and drop** (`HB/profile-ops.ts:263-266`) |
| `image` | data URL | **never sent to the server**; avatars travel via `profiles.set_asset` (`HB/data.ts:350-353`) |

### 5.2 Read rule (`HB/profile-ops.ts:233-300`)

Local snapshot `{metaKey: meta}` (web: localStorage `hermes.plugin.hermes-bots.bot-meta-v2`, `HB/data.ts:44-46`,
`V/contrib/plugin.ts:144`). On each **full** roster, for each row with a server `ui_meta['hermes-bots']` object:
skip it if a local write to that bot happened after the roster request was issued (write fence, held 60 s,
`HB/data.ts:278-301`); otherwise `merged = {...local, ...server}`, keep local `image`, delete `chat`, and drop a
local `group` scalar when the server has `groups` but no `group`. A row with no server meta keeps the local meta.

### 5.3 Write rule (`HB/data.ts:314-447`)

1. Apply the patch locally at once and note the write time.
2. Send `profiles.configure {name, ui_meta:{'hermes-bots': <full merged meta without image/pet>}}`.
3. If `image` changed: `profiles.set_asset` with `data` or `clear:true`.
4. Map the reply to persisted / failed / unsupported (§2.4). The phone's pin, hide and section actions show
   "Couldn’t Pin Ivy" etc. and roll back with an undo patch on failure (`S/ui-bots/bot-actions.ts:50-83`,
   `S/ui-bots/pinned-section-model.ts:80-82`).

---

## 6. Building a Bots row

The phone row is `PhoneBotRow` (`S/ui-bots/bot-row.tsx:186-261`); its inputs are derived by the vendored `BotRow`
and handed over by **[gate]** `B/ui-bots-gates.ts:13-60`.

### 6.1 Name (`HB/labels.ts:14-61`; same rule in `S/ui-kit/bot-identity.ts:56-74`)

First non-empty of:
1. `meta.title` (trimmed);
2. (remote-source `default` row only) the connection label — never on a single-gateway phone;
3. `row.display_name` (trimmed);
4. `"Hermes"` if `name == "default"` and the row has no `title` (profiles.list never sends `title`, so always);
5. Title Case of `name` with `-`/`_` → spaces (`research-buddy` → `Research Buddy`).

### 6.2 Role line (`S/ui-kit/bot-identity.ts:70`)

`meta.description || row.description || (row.title if ≠ name)`, trimmed, else none. Used as the preview fallback.

### 6.3 Which session the row previews, and its time — phone rule **[gate]**

`rosterPreview(bot)` (`S/fe-lists-r6.ts:48-81`, wired by `B/fe-lists-gates.ts:2981-2994` and `:2874-2877`):

1. If `canonical_session` **holds messages** — `message_count > 0` when it is a number, else a non-blank `preview` —
   the row previews the Bot Chat: `preview = rowPreview(canonical.preview)`, `time = canonical.last_active`.
2. Else: no preview (the role line or "No messages yet"), `time = 0` (no time shown; the bot sorts by its creation
   time). **Phone change, 2026-11-05:** the web fell back to `last_session` here, so a new bot only used through
   sessions showed each session turn on its row (tester). A side chat speaks on its Sessions row only, as
   "Working…" already did.

The row's time label = `listTime(time × 1000)` (`S/list-time.ts:29-40`, **[gate]** `B/fe-lists-gates.ts:2354-2372`):
same calendar day → `"9:05 AM"` (`en-US`, `hour:numeric, minute:2-digit`); yesterday → `"Yesterday"`; within 6 days →
short weekday `"Mon"`; else `"Aug 7"`, with year `"Aug 7, 2025"` if another year. A time slightly in the future reads
as today's clock. Empty for 0.

(The desktop instead shows `max(activity.last_active, worker.last_active)` as "52m"/"3h" — not the phone.)

### 6.4 Preview text pipeline

Input = the preview string from §6.3. Steps:

1. **Recover the raw text** if step 6.3 already reworded it (`sourcePreview`, `S/ui-bots/bot-preview.ts:65-77`):
   if `rowPreview(canonical.preview or last.preview) == shown`, use that raw preview.
2. **Sender of a bot-to-bot delivery** (`HB/row-helpers.ts:19-55`): `/^Message from (?:agent '([^']+)'|🤖\s*([^\s(@]+))/i`
   on the trimmed preview → handle (`default` → `hermes`), mapped to a display name through the roster
   (`S/ui-bots/identity.ts:24-29`).
3. **Clean** (`S/ui-bots/bot-preview.ts:24-63`):
   - strip leading delivery prefix `^\s*(?:\[\s*)?Message from (?:agent '[^']+'|🤖[^:\]]+)\]?:?\s*` (case-insensitive);
   - model-switch note `^\s*\[System: The active model for this chat has changed to <id>…` →
     `"Model changed to <model label>"` or `"Model changed"` if cut (`S/fe-lists-r6.ts:5-46`);
   - drop `\n?#{1,3}\s*Run Context[\s\S]*$`;
   - drop bracketed notes `\[\s*(?:system(?: note)?|runtime note|note to self|context|internal)\s*:[^\]]*(?:\]|$)` and
     sentinels `\[\s*(?:SILENT|CRON_FAILURE|NO_REPLY|SYSTEM)\s*\]`;
   - strip markdown (fences, inline code, images, links→text, bold/italic/strike, half-pairs left by the 80-char cut,
     headings, quotes, bullets, table rules; `|` → ` · `; collapse whitespace) (`:33-53`);
   - a preview that was only `[SILENT]` → `""` (the web: `"Nothing to report"`; native, UX study #210: the chat hides that line unless it answers your own message, so a bot row shows its role line instead, blank without one, and a Sessions row just its owner).
   - Elsewhere `rowPreview` also maps `[System note: …]`/`[Runtime note: …]`/`[SYSTEM]` to their words,
     `work kanban task t_…` → `"Kanban task"`, and strips leading machine tags `<foo>…</foo>` (`S/fe-lists-r6.ts:41-45`).
4. **Prefix** (`S/ui-bots/bot-preview.ts:79-90`): a stashed draft → `"Draft:"`; a delivery with a sender →
   `"From <Name>:"`; else none. Empty text → role line, else `"No messages yet"`.
   **Note:** the phone never passes `fromYou`, so bot rows never show `"You:"` (`S/ui-bots/bot-row.tsx:212`).
5. An unsent/failed send from this device overrides the line with its own prefix (`S/ui-lists/row-pending.ts`,
   `S/ui-bots/bot-row.tsx:209-214`) — part of the composer spec.

### 6.5 Second line: status ranking (`S/ui-bots/row-status.ts:17-29`, `S/ui-kit/bot-status.ts:41-55`)

First match wins:

| # | Condition | Text | Tone | Avatar badge |
| --- | --- | --- | --- | --- |
| 1 | gateway link not online (header only) | "Offline"/"Reconnecting…" | secondary | — |
| 2 | opening this bot for >1 s (`STATUS_GRACE_MS`, `S/status-grace.ts:7`) | "Waking up…" + spinner | secondary | — |
| 3 | source unreachable | "Can’t reach this bot" (desaturated) | secondary | — |
| 4 | standing failure for this bot (`$botAttention`, e.g. provider auth/quota); only when available and not opening | the failure hint | orange | needs-you `!` |
| 5 | chat state `needs-input` and not a clarify question | "Waiting for your approval" | orange | needs-you |
| 6 | `needs-input` and a clarify question | "Waiting for your reply" | orange | needs-you |
| 7 | bot is using its computer | "Using its computer" | tint | computer |
| 8 | chat state `working`/`background`/`stalled` | "Working…" | tint | working (3 dots) |
| 9 | idle | the cleaned preview (§6.4) with prefix | secondary | — |

Browser activity text from the browser-watch companion can replace an idle/working line
(`S/ui-bots/bot-row.tsx:216-221`). Badge mapping `S/ui-kit/bot-avatar.tsx:12-20`.
On a single-gateway phone #3 effectively never shows (sources are always `reachable:true`, §3.7).

### 6.6 Chat state and the unread dot

`chatState = useBotChatState(canonicalStoredId, canonical_session.message_count)` **[gate]**
(`B/fe-lists-gates.ts:2533-2577,2891-2893`):

```
state = sessionDotState[canonicalStoredId] ?? 'idle'      (no canonical session → 'draft')
if state == 'unread' && message_count == 0      → 'untouched'
if state == 'draft' && no stashed draft && !(chat open && composer non-empty) → 'untouched'
else state
```

`sessionDotState` priority, weakest → strongest (`V/store/session-dot-state.ts:96-178`):
`draft` < `unread` (local markers, and server `row.unread` for *listed* rows) < `background` (background processes
or live subagents) < `working` (busy turn) → `stalled` refines working < `needs-input`. These come from live session
state the device holds (sessions it has resumed/attached and their socket events), so a bot shows "Working…" only
for chats this device is attached to (`V/store/session-states.ts:1197-1214`). Native M1: derive from the chat engine
for the open chat; idle otherwise.

**Unread is a dot, never a count**: "the gateway's message_count includes every tool call and result"
(`S/ui-bots/bot-row.tsx:104-107`, `S/ui-kit/bot-avatar.tsx:32-35`). Row: 16 pt tint dot at the trailing edge of the
second line; pinned tile: 10 pt dot beside the name; grey when the bot is muted (`S/phone-ui-bots.css:32-35`).

### 6.7 How a bot becomes unread / read (phone)

The phone replaces the desktop's watermark logic for bot chats with an **activity tracker** **[gate]**
(`B/bot-unread-gates.ts:9-31`, `S/bot-unread-runtime.ts`, `S/bot-unread-activity.ts`):

- **Baselines**: localStorage `dispatch.bot-activity.v1` = `{activityOwner: lastSeenCanonicalLastActive}`
  (`S/bot-unread-activity.ts:3,23-30`); capped near 2000 entries (`:58-61`). Account-scoped by the per-account
  storage snapshot.
- **On every full roster** (`S/bot-unread-activity.ts:44-65`), for each non-ghost bot with canonical ids and a
  numeric `canonical_session.last_active` `stamp`:
  - if its chat is **visible right now** (app visible, not opening, focused stored id ∈ canonical ids, owner matches)
    → acknowledge (read);
  - else if a baseline exists and `stamp > baseline` and `message_count !== 0` → **mark unread**;
  - else → restore any persisted marker into the live set;
  - then `baseline = max(baseline ?? 0, stamp)`.
  First sight of a bot only records the baseline (no dot on a fresh install).
- **Mark** = add the canonical id (`id || resolved_id`) to the profile's marker bucket in localStorage
  `hermes.desktop.unreadFinishedSessions` = `{"<profile>":["<id>",…]}` (≤200 per profile) and to the live unread
  id set (`S/bot-unread-runtime.ts:38-44`, `V/store/session-unread.ts:78-81,149,214-233`).
- **Acknowledge** = remove both canonical ids from the markers and the live set (`S/bot-unread-runtime.ts:45-53`).
- **Read only after fresh history**: opening a bot holds its read; the dot clears only once this open actually applied
  history from the gateway (a cached paint is not enough), and not if a newer roster `last_active` arrived meanwhile
  (`S/bot-unread-runtime.ts:64-87,114-125`; hooks in `B/bot-unread-gates.ts:35-74`). Core "mark read on select"
  calls are deferred for bot chats while not visible (`S/bot-read-guard.ts:1-11`).
- **Mark as Read / Unread** (row menu, swipe) is **device-local only** — no gateway write
  (`S/ui-bots/bot-row.tsx:80-88`, `S/bot-unread-runtime.ts:128-133`). Disabled for a bot with no chat yet
  (`S/ui-bots/bot-menu.ts:21-22`).
- **Counted unread** for the Bots tab badge excludes ghosts, hidden bots and empty chats (`message_count === 0`)
  (`S/bot-unread-runtime.ts:147-161`). App icon badge = Bots count + Sessions count (`S/unread-visible.ts:10-28`); tab badges `S/phone-tab-bar.tsx:464-468`.

Native: keep (a) a per-bot `lastSeenActivity` baseline, (b) a per-profile set of unread canonical ids, both
persisted per gateway account; apply the same transitions on each full roster.

### 6.8 Row anatomy (`S/ui-bots/bot-row.tsx:186-261`, `S/phone-ui-bots.css`)

- List row: 56 pt head (`BotAvatar`, §10), name line (name, unread dot only in tiles, bell-slash if muted, eye-slash if
  hidden), time cell, second line (status/preview, pin glyph if pinned, unread dot), trailing ⋯ button
  ("Actions for <name>").
- Pinned tile: 72 pt head, name (2-line clamp, footnote medium), unread dot beside name; no preview, time or ⋯
  (`S/phone-ui-bots.css:145-153,192-195`); 3 per row, 1–2 tiles centred.
- VoiceOver label: `"<name>. <line>. <time>. Unread. Pinned. Muted. Hidden"` (present parts only)
  (`S/ui-bots/row-status.ts:51-53`).
- Swipes: leading Unread (full swipe) · Pin; trailing More · Mute (full swipe); nothing destructive
  (`S/ui-bots/row-swipes.ts:1-23`). Menu model: `S/ui-bots/bot-menu.ts:13-53`.
- Mute is device-local: localStorage `dispatch.botMutes.v1` = `{"bot:<identity key>":{"always":true}|{"until":<ms>}}`
  (`S/ui-bots/bot-mute.ts:14-20,38-45`).

### 6.9 Group chat rows (brief)

Group avatar (2–3 member heads in one frame, `S/ui-kit/bot-avatar.tsx:67-87`); line = "Waiting for your reply" /
"<A> is replying…" / "2 of 3 available" / `"<From>: <last text>"` / "3 bots" (`S/ui-bots/row-status.ts:31-49`);
unread is device-local `dispatch.roomUnread.v1` (`S/ui-bots/room-marks.ts:8-21`). Room data comes from group RPCs —
out of scope for M1.

---

## 7. List composition and ordering

### 7.1 Visible set and filters

- Hidden bots (`meta.hidden`) leave the main list; they appear under a collapsed **Hidden · N** header at the
  bottom, expanded by a session-only toggle (`HB/roster-pane-derivation.ts:58-62`, `HB/hidden-bots.ts:20-31`,
  `S/ui-bots/roster-states.tsx:79-89`).
- Filter menu (`S/ui-bots/roster-filters.ts:9-26`): Show › All · Bots · Group Chats; Activity › Any Time · Active Now
  (live within 90 s) · Recently Active (≤7 days) · Older (`HB/row-helpers.ts:57-58,154-171`); Show Hidden Bots (N);
  Clear Filters. Search matches display name, profile, handle, connection label, role and preview
  (`HB/data.ts:1464-1491`). On the phone the search field is always shown **[gate]** (`B/tabbar-gates.ts:62`).

### 7.2 Sort (`HB/roster-pane-derivation.ts:210-237`, **[gate]** `B/fe-lists-gates.ts:3012-3037`, `S/fe-lists-r6.ts:71-101`)

Stable sort: **pinned first**, then by `sortTime` descending where
`sortTime = rosterTime(bot) × 1000 || meta.created || 0` (`rosterTime` = the §6.3 time). Ties keep `profiles.list`
order. A new bot with nothing said sorts by its creation time. Group rooms interleave by their own activity, with
their manual order among rooms (`HB/group-order.ts:8-26`).

### 7.3 Pinned tiles (`S/ui-bots/pinned-model.ts:1-28`, `S/ui-bots/pinned-grid.tsx:13-37`, **[gate]** `B/ui-revision-gates.ts:170-190`)

- The first **6** pinned rows (bots or rooms) become tiles above the list, in the user's dragged order
  (localStorage `dispatch.bots.pinOrder.v1` = roster keys, ≤64; `S/ui-bots/pinned-order.ts:6-23`), never-placed pins
  following in sort order. Pins beyond 6 stay as ordinary rows (in the Pinned section).
- Which bots are pinned is server state (`meta.pinned`); tile order is device-only.

### 7.4 Sections and the Pinned section

- **Section records** (`[{id,name}]`, display order) are **device-local**: `hermes.plugin.hermes-bots.bot-sections-v1`
  (`HB/user-sections.ts:37-40,89-111`). **Membership is on the bot** (`meta.sectionId` + `meta.sectionName`), so it
  syncs through `profile.yaml` (`HB/user-sections.ts:1-21`).
- **Adoption**: on each roster, a `sectionId` this device does not know is added with the name its members agree on;
  a known section is renamed when all members carry one other name (`HB/user-sections.ts:159-191`). Members carrying
  only an id get the name stamped by the device that knows it (`:203-221`).
- **Rendering** (`HB/roster-pane-sections.tsx` `renderUserSections`, `HB/user-sections.ts:376-411`): one block per
  known section in order (header "Name · N", collapsible), then the unassigned rows with no header, last. With no
  sections at all, a plain list.
- **Pinned section** (HQ, `S/ui-bots/pinned-section-model.ts:6-82`, `S/ui-bots/pinned-section.ts:28-53`,
  **[gate]** `B/pinned-section-gates.ts:10-21`): id `hermes-hq-pinned`, name `Pinned`. Every pinned bot is filed in it
  so desktop Hermes (which has no tiles) groups them too. Reconciled on every *live* roster/meta change, one write per
  disagreeing bot, a failed write retried after 60 s:

  | meta state | write |
  | --- | --- |
  | pinned, `sectionId` ≠ Pinned | `{sectionId:'hermes-hq-pinned', sectionName:'Pinned', pinnedFrom: current? {id,name} : null}` |
  | pinned, in Pinned, name ≠ "Pinned" | `{sectionName:'Pinned'}` (+ `pinnedFrom:null` if absent) |
  | pinned, in Pinned, no `pinnedFrom` | `{pinnedFrom:null}` |
  | not pinned, in Pinned, has `pinnedFrom` | back home: `{sectionId: home if this device has it else null, sectionName, pinnedFrom:false}` |
  | not pinned, in Pinned, no `pinnedFrom` (filed by hand) | treat as a pin: `{pinned:true, sectionName:'Pinned', pinnedFrom:null}` |
  | not pinned, elsewhere, stale `pinnedFrom` | `{pinnedFrom:false}` |

  A phone Pin/Unpin writes the flag and its section in one `profiles.configure` (`pinPatch`, `:65-70`). Moving a
  pinned bot to another section only changes `pinnedFrom` (`:72-78`). On the phone the Pinned section is first in
  order and shown only when it has a non-tile row (`S/ui-bots/pinned-section.ts:42-53`). Menus never offer Pinned as
  a move target and show a pinned bot's home section as its section (`:27-35`).

- **When the web reconciler actually writes** (detail the summary above glosses):
  - It runs from the Bots pane's effect `if (live) dispatchPinnedSection(roster, allMeta)` (**[gate]**
    `B/pinned-section-gates.ts:13-14`), where `live = Array.isArray(data?.profiles) ? data.profiles : null`
    (`HB/roster-pane.tsx:291`). `data` is also set by the **cached** first paint (`dispatchPartial:'cache'`,
    `S/roster-cache.ts:28-33`) and the slim paint (`S/roster-cache.ts:111-123,139-150`), so the reconciler can write before the
    gateway's full answer arrives, using this device's persisted meta snapshot (`$botMeta`, which only full answers
    refresh, **[gate]** `B/fe-lists-gates.ts:356-367`). **Disagreement:** the gate's header says "only from a live roster (never a
    cached one shown while the gateway is away)" (`B/pinned-section-gates.ts:3-4`); the code does not check
    `dispatchPartial`.
  - Each write is `saveBotMeta(bot, patch)` → `profiles.configure {name, ui_meta:{'hermes-bots': <whole merged meta>}}`
    with **no CAS** (no `ui_meta_expected_revisions` for `hermes-bots`, `HB/data.ts:350-372`): the last writer replaces
    the whole object.
  - Only while the release flag `PINNED_SECTION` is on (default on, `S/ui-bots/pinned-section.ts:16-17`); one write in
    flight per bot; a bot whose write failed waits 60 s (`:23-41`). It also reorders the device-local section list
    so Pinned is first (`:44-45`; local only).
  - Beside it, the vendored `backfillBotSectionNames` writes `sectionName` onto members that carry only a `sectionId`
    this device knows (`HB/roster-pane.tsx:306-309`, `HB/user-sections.ts:203-221` via `moveBotsToSection`): another
    automatic `profiles.configure`.
- **Native M1:** no automatic writes here (§12.5). Draw what the meta says: treat `sectionId == 'hermes-hq-pinned'` as
  the Pinned section, show it (first) only when it holds a pinned bot that is not a tile, and file a pinned bot whose
  meta has not been reconciled yet (pinned but `sectionId` elsewhere) under the tiles/Pinned section anyway, as the
  web would after its next write. When pinning ships (later milestone), write `pinPatch` (flag + section +
  `pinnedFrom` in one call, `S/ui-bots/pinned-section-model.ts:65-70`) as the whole merged meta.

### 7.5 Final layout, top to bottom

Bar (Filter, search, + [1x-settings §5.6]) → stale card if any → pinned tiles (≤6) → [Pinned section if it has rows] → user
sections in order → unassigned rows (bots and rooms, §7.2 order) → Hidden header (+ rows when expanded).

---

## 8. Opening a bot: which session

What the shipped phone runs is the vendored `openRosterBot` (`HB/roster-actions.ts:227-383`) after two gate sets:
r1-65 / r2-86 replace its registry open with `openKnownBotChat` (**[gate]** `B/fe-lists-gates.ts:1030-1036,1110-1170`,
applied at `:1213-1226`), and the bot-unread gates replace the already-open branch (**[gate]**
`B/bot-unread-gates.ts:16-29`). Gate order: `feListsGates` before `botUnreadGates` (`B/renderer-gates.ts:298,331`).
The vendored comment "Resolution always goes through the owner profile's 'Bot Chat' title registry" is no longer true
for the common path.

### 8.1 Steps

1. **Start** (`HB/roster-actions.ts:228-281` + gates): bump the open generation (a later tap supersedes this one);
   haptic tap; record the selection; **hold the unread read** (`holdCanonicalBotRead`, §6.7); mark the open pending
   (drives "Waking up…" after 1 s, §6.5).
2. **Chat already open as a tile** (`focusExistingBotTab`, `HB/roster-actions.ts:188-214`, called at `:281`: only a
   tile whose stored id is `canonical_session.id` or `.resolved_id`; a row with no `canonical_session` never fronts): front it, then
   **lookup-first** `openBotCanonicalChat(bot)` in the foreground (**[gate]** `B/bot-unread-gates.ts:17-28`, replacing
   the vendored background refresh): registry lookup (§8.3), then open its tip with a forced resume. Success →
   acknowledge unread, record `{registryId, openedId}`; failure → the open-failure notice (§8.4) and the read is not
   acknowledged.
3. **Source prep** (`HB/canonical-chat.ts:612-636`, called at `HB/roster-actions.ts:308`): on the single-gateway
   phone this only checks the host can route; failure → "Hermes couldn’t reach the computer this bot runs on" (§8.4, step `reach`). No RPC.
4. **Row names its Bot Chat** — `knownBotChat(row)` (`S/list-helpers.ts:62-69`) returns
   `{registryId: canonical_session.id, openId: (canonical_session.resolved_id || id), message_count?}` (strings trimmed;
   blank `resolved_id` → `id`; `message_count` only when it is a finite number). Then (`openKnownBotChat`,
   `B/fe-lists-gates.ts:1113-1170`):
   1. If this open is no longer current → stop (`null`).
   2. **Ask the registry now, without waiting**: `answer = findExistingCanonicalChat(row)` (§8.3) with errors swallowed
      to `null` (`:1131`).
   3. **Open the known chat at once**: `openStoredBotChat(row, openId, {id: registryId, resolved_id: openId,
      message_count?})` (`:1134-1138`) — forced resume, `expectHistory = message_count > 0` when known (else `true`),
      hydration budget 60 s with one internal retry (`HB/canonical-chat.ts:90-153`).
   4. **If that open throws**: wait for `answer`. Re-throw the original error when the error is "superseded by a newer
      selection" (`S/fe-lists-r2.ts:88`), or `answer` is null/failed, or `answer.id == registryId`, or
      `answer.resolved_id||answer.id == openId`, or the open is no longer current. Otherwise open the registry's tip
      `answer.resolved_id || answer.id` instead and return `{registryId: answer.id, openedId: tip}`
      (`B/fe-lists-gates.ts:1139-1158`).
   5. **If it succeeds**: return `{registryId, openedId: openId}` at once, and in the background run
      `replaceWithRegistryChat` (`S/fe-lists-r2.ts:155-178`, called at `B/fe-lists-gates.ts:1160-1167`):
      - await `answer`; give up if it is null, has no id, `answer.id == known.registryId`, or its tip `== known.openId`;
      - give up unless this open is still current **and** the focused stored id is still `known.openId`;
      - open `tip = answer.resolved_id || answer.id` (same `openStoredBotChat`, forced resume);
      - if still current and the focused id is now `tip`, move the open-chat claim to
        `{openedRegistryId: answer.id, openedSessionId: tip}`, unless another bot claimed the center meanwhile
        (`B/fe-lists-gates.ts:1218-1223`).
      Consequence: a registry answer with the **same `id` but a newer tip** (the lineage was compressed since the
      roster was read) does **not** replace the open chat; the replacement happens only when the registry names a
      different Bot Chat row.
5. **Row has no `canonical_session`** (or the host cannot open stored sessions) → the vendored **lookup-first** path
   `openBotCanonicalChat(row)` (`HB/canonical-chat.ts:569-608`): §8.3 lookup; found → open its tip; not found →
   `createCanonicalChat` (§8.2). This is the only path that can mint.
6. **Finish** (`HB/roster-actions.ts:330-383` + `B/bot-unread-gates.ts:29`): if the generation moved on, drop the
   result silently. On success: acknowledge unread once fresh history applied (§6.7), record
   `$openBotChat = {key, openedRegistryId, openedSessionId}`, close the Bots list and push the chat
   (`S/ui-bots/list-close.ts:27-34`). On error: clear the claim and show §8.4. (A `null` result with the open still
   current falls back to `host.newChat` — a vendored path for old desktops, `HB/roster-actions.ts:363-382`; native can
   treat it as an error.)

### 8.2 Minting (`createCanonicalChat`, `HB/canonical-chat.ts:367-563`) — only from step 5

1. de-duplicate concurrent creations per bot;
2. re-run the lookup (adopt before mint); found → open it;
3. `session.create {profile, title:"Bot Chat", hidden:true, follow_profile_config:true}`;
4. `session.title {session_id: runtimeId, title:"Bot Chat"}` to materialise the row now; on `/already in use/`
   re-run the lookup and open the winner;
5. open `stored_session_id`;
6. only if the eager title failed (old gateway), wait 400 ms and `prompt.submit {session_id, text:"Hey, tell me
   about yourself!"}` (localised kickoff) so the lazy row persists. A tap never sends the intro on a modern
   gateway; New Bot creation does (`kickoff:true`).

A background refresh never mints (`HB/canonical-chat.ts:593-598`).

### 8.3 The registry lookup and when it fails closed (`findExistingCanonicalChat`, `HB/canonical-chat.ts:239-301`)

- `session.list {profile, title:"Bot Chat", limit:200, include_hidden:true}` on the bot's profile, foreground priority
  (wire shape §2.5). Match = first row whose `root_title`, else `title`, is exactly `Bot Chat` (`:158-163`).
- RPC error → throws "Could not check <name>'s Bot Chat registry (<rpc message>) — not starting a new chat".
- Empty / no match **while the row has `canonical_session.id`** → throws "Could not confirm <name>'s Bot Chat registry —
  not starting a new chat" (`:288-298`).
- Empty / no match and the row has **no** `canonical_session` → `null` = confirmed absence → step 5 may mint.

So **fail-closed matters only on paths that wait for the lookup**: step 5 (no `canonical_session`) and step 2 (already
open). On step 4 (the usual tap) a failed or doubtful lookup is swallowed and the known chat simply stays; it can only
surface as the reason a failed known open is not replaced (step 4.4 re-throws the open's own error).

### 8.4 Failure notices (`HB/canonical-chat.ts:191-234` + **[gate]** `B/fe-lists-gates.ts:1037-1078`, `:1523-1526`)

| Condition | Notice |
| --- | --- |
| error is "superseded by a newer selection" or the chat pane already shows its own error (`paneShowsError`) | none (`S/fe-lists-r2.ts:88,97`) |
| `gatewayBusy(error)` (timeout / 429 / 503 / pool full / "busy", `S/list-helpers.ts:73-76`) | title "Your gateway is busy", body "Couldn’t open <Name>’s chat in time. Try again in a moment.", action **Retry** (re-runs the whole open) (`B/fe-lists-gates.ts:1045-1058`, `S/list-helpers.ts:93-96`) |
| `gatewayNotConnected(error)` (message matches gateway unavailable / not connected / connection closed / connection reset / ECONNRESET, `S/list-helpers.ts:79-82`), first time for this bot in 30 s | no toast: wait up to 20 s for the socket to open, then re-run the open; if it does not open, show the generic notice (`B/fe-lists-gates.ts:1061-1077,1081`, `S/list-helpers.ts:83-92`) |
| gateway too old for Bot Mode | "This bot lives on an older Hermes" / "Update <connection>, then try again." + Open Gateways |
| step `reach` failed | "Hermes couldn’t reach the computer this bot runs on" / "Check it is online and try again." + Open Gateways |
| anything else | "Could not open <Name>’s chat" / "Try again." + Open Gateways; raw error in `detail` (`HB/i18n.ts:660-666`) |

### 8.5 Native rule

Implement §8.1 as written: open `canonical_session.resolved_id || id` immediately (render the cached transcript on
the first frame, then the forced resume), ask the registry in parallel, and replace the chat only when the registry
names a **different `id`** and the user is still looking at the known chat. Fail closed (refuse to mint, show the
error) only when the open had to wait for the lookup, i.e. no `canonical_session` on the row, or the chat was
already open. Never mint from anything but an explicit tap on a row with no `canonical_session`.

### 8.6 Other chats of a bot

Not the bot's chat: "New Chat" on a bot starts a *lazy new session* in that profile (a side chat, visible in
Sessions) — `S/phone-new-chat.ts:48-64`. An empty Bot Chat lists ≤5 recent sessions of the bot
(`GET /api/profiles/sessions?…&profile=<p>`, background runs excluded, the roster's `last_session` merged in;
`S/bot-recent.ts:7-31`); those open as side chats (`S/bot-recent.ts:52-92`).

---

## 9. Sessions tab (basic list)

### 9.1 The request

`GET /api/profiles/sessions/sidebar` with (`V/app/session/hooks/use-session-list-actions.ts:66-78,372-380`,
`V/api/sessions.ts:309-336`, phone source changes **[gate]** `B/stress-c-gates.ts:84-95`):

| Param | Phone value |
| --- | --- |
| `recents_profile` | `all` when "All Bots" is on (the phone turns it on at launch once ≥2 profiles exist, `S/sessions-everything.ts:166-174`), else the active profile |
| `recents_limit` | `$sessionsLimit`, default `SIDEBAR_SESSIONS_PAGE_SIZE = 50` (`V/store/layout.ts:41,448`); grows by 50 on "load more"; `SIDEBAR_FILTERED_PAGE_SIZE = 300` is the reach once a filter is on (`V/store/layout.ts:42-45`) |
| `recents_exclude` | `acp,cron,kanban,oneshot,subagent,telegram,discord,slack,mattermost,matrix,signal,whatsapp,bluebubbles,photon,homeassistant,email,sms,webhook,api_server,weixin,wecom,qqbot,yuanbao,dingtalk,feishu` (phone keeps `tool` rows; desktop excludes them) |
| `cron_limit` | `50` (`V/store/session.ts:953`) |
| `messaging_limit` | `100` (`V/store/session.ts:960`) |
| `messaging_exclude` | `cron,acp,cli,codex,desktop,gateway,kanban,local,tui` (phone lets `oneshot` through → "One-off Runs" folder) |

Example: `GET /api/profiles/sessions/sidebar?recents_profile=all&recents_limit=50&cron_limit=50&messaging_limit=100&recents_exclude=acp%2Ccron%2C…&messaging_exclude=cron%2Cacp%2C…&profile=default`
(the trailing `profile` is the shim's routing param, `S/bridge/shim.ts:42`).

Server semantics (`AG/hermes_cli/web_routers/profiles.py:513-653`): every slice uses `min_message_count=1`,
archived excluded, recency order, `include_pinned` (pinned rows back-filled past the limit), **hidden rows excluded**
(`AG/hermes_state_sessions.py:1372-1373`) — so **Bot Chats never appear**. Response cached server-side briefly and
single-flighted (`:384-445`). An older gateway 404s this route; then fall back to three
`GET /api/profiles/sessions?…` calls (`V/api/sessions.ts:247-293,337-347`).

Response:

```json
{"recents":{"sessions":[SessionRow…],"profiles_truncated":{"default":true,"ivy":false},
            "profiles_usage":{"default":{"cost_usd":12.4,"tokens":8812331}}},
 "cron":{"sessions":[…]},
 "messaging":{"sessions":[…],"total":7},
 "errors":[{"profile":"ivy","error":"…"}],
 "storage":{"ivy":"corrupt"},
 "profiles_failed":{"ivy":{"failed":true,"retry":true,"error":"…"}}}
```

A failed whole-scope scan returns slices **without** `sessions` (`{"failed":true,"retry":true,…}`) — treat as
"Retry", not "No sessions" (`AG/hermes_cli/web_routers/profiles.py:619-637`). Verbatim empty fixture:
`{"recents":{"sessions":[]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}`
(`FX/action-voice-fixture-gateway.py:162`).

SessionRow fields the client reads (`V/types/hermes.ts:546-640`; tagging `AG/hermes_cli/web_routers/profiles.py:230-241`):
`id, title|null, preview|null, source|null, started_at, last_active, ended_at|null, message_count, tool_call_count,
input_tokens, output_tokens, model|null, cwd, profile, is_default_profile, is_active (ended_at null and active <300 s),
archived, pinned, unread (server read watermark), hidden?, _lineage_root_id?, _lineage_ids?, parent_session_id?,
estimated_cost_usd?, actual_cost_usd?`. Times are unix seconds.

### 9.2 Client-side filtering

1. Bot Chats: absent (hidden on the gateway). The phone briefly merged them back as synthetic rows; the owner
   reversed that on 2026-10-04 — the merge hook is **not registered** (`S/sessions-everything.ts:1-9,154-165`).
2. **Background runs hidden by default**: rows with `source ∈ {tool, oneshot, subagent, kanban}` are dropped from the
   dated list and from the messaging folders unless Filter › Show › Background Runs is on (localStorage
   `dispatch.sessions.showRuns` = `'1'`) (`S/session-runs.ts:6-22`, **[gate]** `B/session-runs-gates.ts:8-20`).
   Pinned resolves from unfiltered rows; Search still finds runs.
3. Profile chips (All Bots mode): `$sidebarProfileFilter` (one profile or none) narrows rows
   (`S/sessions-everything.ts:50-66`).
4. Status filter (Needs Input, Working, Unread, Draft, Idle), Project filter, Archived (Show › Archived)
   (`S/ui-lists/filter-menu.ts:65-100`).

### 9.3 Grouping, order, rows

- Defaults: group by **date**, sort by **updated** (`last_active`), row detail **preview + time**
  (`V/store/layout.ts:308-330`). Pinned chats in a Pinned group first (pins: server `pinned` flag + device list).
- Cron runs: a "Cron jobs" folder; messaging threads: one folder per platform; one-off runs: "One-off Runs" folder
  (`B/stress-c-gates.ts:84-95`).
- Row (`S/ui-lists/session-row.tsx:50-92`, `S/ui-lists/row-model.ts:43-74`):
  - title = `title.trim() || preview.trim() || "Untitled session"` (`V/lib/chat-runtime.ts:64-66`), with a
    model-switch note reworded (**[gate]** `B/fe-lists-gates.ts:3043-3053`);
  - avatar = the owner bot's head (§10), badge needs-you/working;
  - second line = `"<Owner>"` + `" · <preview>"` (preview via `rowPreview`), or `"<Owner> · Needs your input"` /
    `"… · Working…"` for live states; owner name = `$profiles` `display_name`, `default` → "Hermes", else readable
    profile name (`S/audit-c-format.ts:401-407`);
  - time = `listTime(last_active)` (§6.3 rules); pin glyph; unread dot.
- **Unread on Sessions rows** (`V/store/session-dot-state.ts:96-133`, `V/store/session-unread.ts:19-58,457-521`):
  unread if any of: server `row.unread` (and not overridden by a pending local write for ≤10 s); explicit local
  marker; `message_count` above the per-row "seen" watermark (localStorage `hermes.desktop.sessionSeenCounts`,
  seeded on first sight so a fresh install shows nothing). Messaging rows use markers only. Opening a row clears the
  local state; Mark as Unread sends `"unread":true` (optimistic, rolled back on failure;
  `S/session-unread-write.ts:60-86`).
- **The open-time server write, exactly** (resolved):
  - Selecting a session calls `markSessionRead(id)` (local) and `clearUnreadOnOpen(id)` (`V/store/session.ts:1542-1557`).
    `clearUnreadOnOpen` (re-exported from the HQ file, **[gate]** `B/fix161-data-gates.ts:12-13`) finds the row in the
    listed `$sessions` by id and **returns without writing unless that row's server `unread === true`**
    (`S/session-unread-write.ts:90-98`). Only then: optimistic `unread:false`, write guard (10 s), and
    `PATCH /api/sessions/{id}` with body `{"unread":false,"profile":"<row.profile>"}` (profile also as the `?profile=`
    routing param) (`S/session-unread-write.ts:62-86`, `V/api/sessions.ts:409-426`). A failure rolls the dot back and
    is otherwise ignored ("healed by the next honest refresh", `:88-97`).
  - Server: `unread:false` → `set_session_read(id, read=True)` stamps `last_read_at = now` across the compression
    lineage; `unread:true` stamps `0` (`AG/hermes_cli/web_routers/sessions.py:883-920`,
    `AG/hermes_state_sessions.py:1064-1068`). Response `{"ok":true,"title":"…","unread":false}`; 404 unknown id, 400 empty
    body. `last_read_at` is in the change watcher's column list, so other clients get a `sessions.changed`
    (`AG/tui_gateway/change_watcher.py:129`).
  - Server `unread` = `last_active > last_read_at`, and **`last_read_at = NULL` (never touched) reads as read**
    (`AG/hermes_state_sessions.py:1070-1076`). So a session only ever reports `unread:true` after some client wrote its
    watermark (a Mark as Read/Unread, or an earlier open-clear); for every other row the open-time PATCH never fires.
  - Bot Chats are hidden, never in `$sessions`, so opening a bot never sends it (and bot unread is device-local, §6.7).
- **Native M1 (spec decision):** send it, under exactly the web condition — a user opens a listed Sessions row whose
  server `unread` is `true` → `PATCH /api/sessions/{id} {"unread":false,"profile":p}`, optimistic, 10 s guard against
  older list pages, roll back on failure. Reasons: it is user-initiated and identical to what the owner's web app
  already sends for the same tap; skipping it would leave the dot lit on the web app and desktop for a chat read on
  native (a visible regression in a side-by-side comparison); the write touches only `last_read_at`. The read-only
  rule in `PLAN.md` ("then read-only on the owner's real gateway") is a **testing** rule: automated runs against the
  owner's gateway set a client-wide `readOnlyGateway` switch that suppresses this PATCH (and every other write) and
  clears the dot locally instead. Mark as Read/Unread from the row menu is a later milestone.
- Sessions tab badge = rows the list would show under Status › Unread (bots' chats excluded, hidden runs excluded)
  (`S/unread-visible.ts:13-28`).
- Reconnect probe: on return, the same request with all three limits `=1` is compared to the last full answer;
  identical → skip the full read (≤10 min old) (`S/sidebar-probe.ts:1-60`). Optional for native. Native (build 291)
  reads a short top page instead of the full list when the probe differs, the full read owed until the list is on
  screen (`docs/spec/3x-sessions.md` §11.5).

---

## 10. Robot heads

### 10.1 What decides the picture (`S/ui-kit/bot-avatar.tsx:51-65`, `S/ui-heads/renderer-hooks.tsx:25-46`, **[gate]** `B/ui-heads-gates.ts:8-25`)

```
photo = meta.image (pulled via profiles.get_asset when has_avatar), ignoring
        • a PNG whose IHDR is exactly 160×160 (desktop's backfilled face, HB/avatar-image.ts:136-157)
        • a PNG whose IHDR is exactly 288×288 (this app's own head mirror, S/ui-heads/mirror.ts:9-28)
if photo:  draw it in the rounded-square frame (corner radius 22.37 % of the side), object-fit cover
else:      draw the head = parseHead(row.ui_meta['dispatch-head']) ?? defaultHead(profile)
```

PNG size check: base64-decode the first 32 chars after `data:image/png;base64,`; width = big-endian uint32 at byte
16, height at byte 20. Avatar pull: only when `has_avatar` and no local image; one in flight per bot
(`HB/profile-ops.ts:167-217`).

**Head storage**: `ui_meta['dispatch-head']` on the profile row, revision in `ui_meta_revisions['dispatch-head']`
(0 when absent). A head this device saved but the roster has not caught up with (higher revision) wins until the
roster reaches that revision (`S/ui-heads/sync.ts:1-50`). Matching by profile name, lowercased.

### 10.2 Head record and validation (`S/ui-heads/head.ts:8-160`)

Version `v: 6`. Fields and vocabularies: `theme ∈ {robot, persona, dots, orb, pixel, glyph, shape}`,
`color ∈ {ink, mint, teal, sky, lilac, pink, coral, peach, butter, lime, paper, red, grass, forest, cobalt, denim,
grape, plum, magenta, rose, wine, caramel, cocoa, slate}`, `seed` int clamped `[1, 2^31-1]`, robot fields
(`shape, face, visor, shell, antenna, ears, mouth, blush`), `hair`, `pattern, tile, eyes, glyph`, Shapes fields
`form ∈ {round, blob, square, pill, triangle, hex, cloud, drop, star, heart}`,
`look ∈ {slits, dots, ovals, googly, happy, sleepy, stars, hearts}`, `specs ∈ {none, shades, aviators, round, monocle}`,
`hat ∈ {none, crown, halo, sprout, party, bow, beanie}`, `tile ∈ {dark, light, color, none}`.

`parseHead(raw)`: not an object, or none of `theme/shape/face` is a known value → `null` (use the default). Every
unknown field value falls back (theme→robot, color→mint, shape→blob, face→pill, visor→band, shell→ink,
antenna→none, ears→(`headset===true` ? headset : none), mouth→none, hair→bob, pattern→face, tile→dark, form→round,
look→slits, specs→none, hat→none; `blush = raw.blush === true`; `eyes = raw.eyes !== false`; glyph cleaned to one
emoji or ≤2 letters). Legacy fix-ups: `shape` theme with `v < 5` → mouth none, blush false; `v < 6` → tile none;
`dots`+`face` with `v < 4` → face/mouth from the seed table.

### 10.3 Default head (what most bots wear) (`S/ui-heads/head.ts:184-259`)

```
key   = profile.trim().toLowerCase() || "default"
hash  = FNV-1a 32-bit over code points: h=2166136261; for each code point c: h ^= c; h = imul(h,16777619); >>>0
hash  = hash || 1
rand  = mulberry32-style(seed=hash):  state=(state+0x6D2B79F5)|0; t=imul(state^state>>>15, 1|state);
        t = t + imul(t^t>>>7, 61|t) ^ t; return ((t^t>>>14)>>>0)/4294967296
colours = SHAPE_COLORS minus {ink, slate, paper}
        = [red,coral,peach,butter,lime,grass,mint,teal,sky,cobalt,lilac,grape,rose,pink,magenta,plum,denim,forest,wine,cocoa,caramel]  (21)
head  = ICON_HEAD with theme:'shape', color: colours[hash % 21], seed: hash % (2^31-1) || 1,
        form: ['round','blob','square','pill','hex','cloud'][floor(rand()*6)]   (first rand() call),
        look:'slits', specs:'none', hat:'none', mouth:'none', blush:false, tile:'none'
```

Test vectors (computed by running the code above):

| profile | hash | color | form | seed |
| --- | --- | --- | --- | --- |
| `default` | 2470140894 | wine | round | 322657247 |
| `ivy` | 3709640156 | grass | round | 1562156509 |
| `hermes` | 3348504771 | butter | round | 1201021124 |
| `inbox` | 3797079355 | pink | round | 1649595708 |
| `otto` | 4014266781 | red | cloud | 1866783134 |

Note the doc comment in `head.ts:244-245` and the memory note say "plain Shapes + slit eyes" — confirmed; the
desktop's violet "squircle" for `default` (`HB/avatar.tsx:1134-1157`) is **not** what the phone draws.

### 10.4 Drawing a Shapes head (`S/ui-heads/shapes.ts`, `S/ui-heads/parts.ts`, `S/ui-heads/render.ts:251-264`)

Coordinate space: a 1024×1024 square, `UNIT = 300` (`shapes.ts:13`). Draw into the avatar's square (56 pt row,
72 pt tile, any size) scaling 1024 → side. Every value below was checked by running the ref238 renderer
(`headSvg`) unchanged; the vectors in §10.4.9 are its output.

**Rounding** (matters for byte-exact test vectors, not for looks): outline spline coordinates are rounded to integers
(`parts.ts:22,49-63`); eye/part coordinates and placement offsets to 0.1 (`shapes.ts:52`); `place()` and placement
scales to 0.001 (`shapes.ts:58-59,175`).

1. **Outline points** (unit space, centred on 0,0; `shapes.ts:16-41`, helpers `parts.ts:24-48`):
   - Helpers:
     - `around(count, f)` = `f(i/count·2π − π/2)` for `i in 0..<count` (starts at the top) (`parts.ts:24-25`).
     - `sampled(count, f)` = `f(i/count·2π)` — **no** −π/2 offset (`shapes.ts:23`).
     - `ring(count, reach, dy=0)`: `a = −π/2 + i·2π/count`, point `(cos a·reach(i), sin a·reach(i) + dy)` (`shapes.ts:21-22`).
     - `rounded(corners, cut)`: each corner `p` (previous `a`, next `b`) becomes two points, `p + (a−p)·cut` then
       `p + (b−p)·cut` (`shapes.ts:17-20`).
   - Forms, as `outline` and face `(fx, fy, size)`:

     | form | outline | face |
     | --- | --- | --- |
     | round | `around(40, t → (cos t, sin t))` | `(0, −0.04, 1)` |
     | blob | `wobble(around(40, t → (1.05 cos t, 0.9 sin t + 0.03)), seed, 0.08)`; `wobble`: `a = (seed % 997)/997·2π`, `b = (seed % 613)/613·2π`, each point × `1 + 0.08·(0.6 sin(3θ+a) + 0.4 sin(5θ+b))`, `θ = atan2(y,x)` (`parts.ts:45-48`) | `(0, −0.04, 1)` |
     | square | `superellipse(0.93, 0.93, 0.3, 48)` = `around(48, t → (sgn(c)·abs(c)^0.3·0.93, sgn(s)·abs(s)^0.3·0.93))`, `c = cos t`, `s = sin t` (`parts.ts:40-43`) | `(0, −0.04, 1)` |
     | pill | for `side` in (−1, +1), `i in 0...12`: `a = side·π/2 + i·π/12`, point `(−side·0.42 + 0.66 cos a, 0.66 sin a)` (26 points: right half first, from the top) | `(0, −0.02, 0.92)` |
     | triangle | `rounded([(0,−1.04), (1.06,0.78), (−1.06,0.78)], 0.24)` | `(0, 0.3, 0.86)` |
     | hex | `rounded(ring(6, 1), 0.2)` | `(0, −0.02, 1)` |
     | cloud | `cloud()` (`parts.ts:27-39`, 72 points) mapped `(x·1.04 − 0.06, y·1.04 + 0.14)` | `(−0.02, 0.1, 0.92)` |
     | drop | `sampled(48, t → (1.04·sin t·sin(t/2)^0.8, −1.06·cos t − 0.08))` | `(0, 0.34, 0.9)` |
     | star | `rounded(ring(10, i → i odd ? 0.58 : 1.08, dy 0.08), 0.18)` | `(0, 0.12, 0.78)` |
     | heart | `sampled(48, t → (1.02·sin³t, −(13 cos t − 5 cos 2t − 2 cos 3t − cos 4t)/16 − 0.12))` | `(−0.04, 0.08, 0.9)` |

     `cloud()`: `around(72, t → origin + d·reach)` with `origin = (0, 0.12)`, `d = (cos t, sin t)`, `reach` = the larger
     of the ellipse `1/√((dx/0.98)² + (dy/0.4)²)` and, for each puff `(cx, cy, r)` in
     `[(−.58,−.02,.44), (−.14,−.36,.5), (.4,−.26,.44), (.72,.08,.36)]` with `x = cx − 0`, `y = cy − 0.12`,
     `b = d·(x,y)`, `q = b² − (x² + y² − r²)`: `b + √q` when `q ≥ 0`.
2. **Path**: map points to `512 + x·300, 512 + y·300`, then a **closed Catmull-Rom spline** through them as cubic
   Béziers: for each `i`, `c1 = p1 + (p2 − p0)/6`, `c2 = p2 − (p3 − p1)/6`, coordinates rounded to integers; the path
   starts `M p[0]` (`parts.ts:49-63`). The same routine returns a dense outline (6 samples per segment) used for
   placement.
3. **Fill** (`shapes.ts:113-120`): `TONES[color].accent` (`S/ui-heads/robot.ts:12-37`), except:

   | colour | bare (`tile:none`) | `tile:dark` | `tile:light` | `tile:color` |
   | --- | --- | --- | --- | --- |
   | ink | `#0A0A0A`; `#F4F4F2` on a dark page | `#F4F4F2` | `#0A0A0A` | `#0A0A0A` |
   | paper | `#EFE9DB` | `#EFE9DB` | `#D9D0BD` | `#FFFDF8` |

   Accents: red `#EF3B36`, coral `#FF7057`, peach `#FFA043`, butter `#FFCE2E`, lime `#96DB3C`, grass `#2DBE60`,
   mint `#1FCFA5`, teal `#22BCD8`, sky `#4A93FF`, cobalt `#2E5BFF`, lilac `#9479FF`, grape `#7C3AED`, rose `#FFAFC8`,
   pink `#FF66AD`, magenta `#E0218A`, plum `#8A3F96`, denim `#3A5BA8`, forest `#23784E`, wine `#B03055`,
   cocoa `#8A5638`, caramel `#C98A55`, slate `#6B7688`, ink `#2EC4B6` (accent unused for fill), paper `#EFE9DB`.
   **Rim** (`shapes.ts:120`): a bare `paper` head always, and a bare `ink` head drawn with the page mode unknown
   (`dark` option omitted: desktop mirror PNG, notifications), get `stroke` `#B8AD95` / `#636366`, width 14. The
   phone always passes the page mode for Shapes heads (`S/ui-heads/icon-render.ts:5-7`, `S/ui-heads/bot-head.tsx:109`), so on
   the phone only paper has a rim.
4. **Eye colour** (`shapes.ts:133`): `#1A1A1A` if the page is dark, or the colour is `paper`, or the fill came out
   `#F4F4F2`; else `#FFFFFF`. This holds on boards too (a dark page gives dark eyes even on a dark board; an ink head on
   a light board on a dark page draws `#1A1A1A` eyes on `#0A0A0A` — faithful quirk). `DEEP_COLORS` (`head.ts:33`) is
   declared but **unused**.
5. **Eyes**, `shapes.ts:125-147`. Inputs: face `(fx, fy, size)`, `s = 300·size`, `bold = 1.2` when the avatar side
   < 64 pt (compact, `S/ui-heads/bot-head.tsx:108`) else 1, `narrow = 0.86` for `thinking`/`speaking` else 1; `flat` = state
   `offline`, which also forces `look = slits`. Pose (`shapes.ts:44-50`): idle `at (0.3, −0.28)`, lean `(−20°, −20°)`;
   thinking/speaking `(0, 0.02)`, `(0, 0)`; done `(0, −0.08)`, `(+24°, −24°)`; offline `(0, 0.1)`, `(90°, 90°)`.
   ```
   gap = 0.26·s if specs ≠ none, else 0.24·s if look == googly, else 0.2·s
   cx  = 512 + (fx + at.x·size)·300 ;  cy = 512 + (fy + at.y·size)·300
   for side in (−1, +1):  x = n(cx + side·gap), y = n(cy), lean = side < 0 ? lean.0 : lean.1
       w = 0.15·s·bold ; h = (flat ? 0.28 : 0.38·narrow)·s
   ```
   `place(x, y, k, body, turn?)` = `<g transform="translate(x y) scale(k) [rotate(turn)]">body</g>` (turn omitted when 0)
   (`shapes.ts:58-59`). Per `look`, each eye is (filled with the eye colour unless stated):

   | look | markup per eye |
   | --- | --- |
   | slits (default) | `<rect x=x−w/2 y=y−h/2 width=w height=h rx=w/2 transform="rotate(lean x y)">` |
   | dots | `<circle cx=x cy=y r=0.11·s·bold>` |
   | ovals | `<ellipse cx=x cy=y rx=0.11·s·bold ry=0.19·s·narrow transform="rotate(lean/2 x y)">` |
   | googly | `place(x, y, size, <circle r="51" fill="#FFF" stroke=<eye colour> stroke-width=9·bold/><circle cx=at.x·60 cy=at.y·60 r=25.5·bold fill="#1A1A1A"/>)` — the ring stroke is the eye colour, so on a light page it is white on white (faithful quirk) |
   | happy | `place(x, y, size·bold, <path d="M-39 15Q0-48 39 15" fill="none" stroke=<eye colour> stroke-width="24" stroke-linecap="round"/>)` |
   | sleepy | `place(x, y, size·bold, <path d="M-42-9A42 33 0 0 0 42-9Z"/>)` |
   | stars | `place(x, y, size·bold, <path d=STAR/>, turn: lean/2)` |
   | hearts | `place(x, y, size·bold, <path d=HEART fill="#FF4D8D"/>)` |

   `STAR` (`shapes.ts:55`, 10 points, radius 54/24, from the top) =
   `M0 -54L14.1 -19.4L51.4 -16.7L22.8 7.4L31.7 43.7L0 24L-31.7 43.7L-22.8 7.4L-51.4 -16.7L-14.1 -19.4Z`.
   `HEART` (`shapes.ts:56`, `sampled(28, t → (51 sin³t, 3 − 51·(13 cos t − 5 cos 2t − 2 cos 3t − cos 4t)/16))`) =
   `M0 -12.9L0.6 -16.1L4.2 -23.7L12.4 -31.5L24.4 -35L37.3 -31.8L47.3 -22.6L51 -9.8L47.3 3.8L37.3 16.5L24.4 28.2L12.4 38.8L4.2 48.1L0.6 54.8L0 57.2L-0.6 54.8L-4.2 48.1L-12.4 38.8L-24.4 28.2L-37.3 16.5L-47.3 3.8L-51 -9.7L-47.3 -22.6L-37.3 -31.8L-24.4 -35L-12.4 -31.5L-4.2 -23.7L-0.6 -16.1Z`.
6. **Glasses** (`shapes.ts:148-159`), all `place(cx, cy, size, …)` about the point between the eyes.
   `bridge(c)` = `<path d="M-18-30Q0-48 18-30" fill="none" stroke=c stroke-width="16.5" stroke-linecap="round"/>`;
   `GOLD = #F5C542`, `GOLD_DEEP = #C9971A` (`shapes.ts:14`).
   - **shades** (dark: they *replace* the eyes and move with them):
     `<path d="M-144-45H-12V6Q-12 51-63 51H-93Q-144 51-144 6ZM12-45H144V6Q144 51 93 51H63Q12 51 12 6Z" fill="#111318"/><path d="M-117-18l24-16.5M39-18l24-16.5" stroke="#FFF" stroke-opacity=".6" stroke-width="12" stroke-linecap="round"/>` + `bridge(#111318)`.
   - **aviators** (dark, replace the eyes):
     `<path d="M18-42H138Q147 36 87 57Q21 51 18-42ZM-18-42H-138Q-147 36-87 57Q-21 51-18-42Z" fill="#26323F" stroke="#F5C542" stroke-width="10.5" stroke-linejoin="round"/><path d="M-48-21l-18-12M48-21l18-12" stroke="#FFF" stroke-opacity=".5" stroke-width="10.5" stroke-linecap="round"/>` + `bridge(#F5C542)`.
   - **round** (clear: drawn outside the moving eyes; the eyes still draw, wider apart):
     `ring(−78, eye colour) + ring(78, eye colour) + <path d="M-15-30Q0-48 15-30" fill="none" stroke=<eye colour> stroke-width="15" stroke-linecap="round"/>`,
     `ring(x, c)` = `<circle cx=x r="66" fill="#FFF" fill-opacity=".18" stroke=c stroke-width="15"/>`.
   - **monocle** (clear): `ring(78, GOLD) + <path d="M123 48q42 78 6 144" fill="none" stroke="#F5C542" stroke-width="7.5"/>`.
7. **Mouth** (`shapes.ts:160-162`): `place(cx, cy + (googly or glasses ? 0.36 : 0.32)·s, size, …)`; stroke set
   `fill="none" stroke=<eye colour> stroke-width=19.5·bold stroke-linecap="round" stroke-linejoin="round"`:
   smile `<path d="M-48 0Q0 48 48 0" …/>`; open `<ellipse cy="9" rx="22.5" ry="27" fill=<eye colour>/>`;
   cat `<path d="M-48 0Q-24 30 0 0Q24 30 48 0" …/>`; grille `<path d="M-30 6h60" …/>`.
8. **Blush** (`shapes.ts:163-164`): `cheek = n(gap/size + 42)`;
   `place(cx, cy, size, <g fill="#FF7FA8" opacity=".8"><ellipse cx=−cheek cy="66" rx="30" ry="18"/><ellipse cx=cheek cy="66" rx="30" ry="18"/></g>)`.
9. **Hats** (still offered in ref238: the editor's "Top" strip, `S/ui-heads/edit-head-sheet.tsx:231`; shuffle may roll
   one, `head.ts:232`). Seat (`hatSeat`, `shapes.ts:78-83`), in unit space on the raw outline points:
   ```
   near  = points with |x − fx| < 0.35 ;  top = the point with the smallest y in near (all points if near is empty)
   below = points with |y − (top.y + 0.3)| < 0.12
   half  = below non-empty ? max |x − top.x| over below × 300 : 160
   seat  = (512 + top.x·300 + (hat == bow ? half·0.45 − 74 : 0),  512 + top.y·300)
   stretch = round(clamp(half, 130, 190) / 1.6) / 100            (beanie only)
   ```
   Drawn: beanie → `<g transform="translate(seat) scale(stretch 1)">BEANIE</g>`; others →
   `place(seat.x, seat.y, 1.6, HAT_MARKUP[hat])` (`shapes.ts:166-170`). Markup, verbatim (`shapes.ts:102-110`):
   - crown: `<g transform="rotate(-8)"><path d="M-78 8L-86-72L-42-34L0-92L42-34L86-72L78 8Z" fill="#F5C542" stroke="#C9971A" stroke-width="8" stroke-linejoin="round"/><g fill="#FF5A5F"><circle cx="-86" cy="-74" r="12"/><circle cy="-94" r="12"/><circle cx="86" cy="-74" r="12"/></g><circle cy="-12" r="11" fill="#4A93FF"/></g>`
   - halo: `<ellipse cy="-64" rx="104" ry="24" fill="none" stroke="#F5C542" stroke-width="16"/><ellipse cy="-64" rx="104" ry="24" fill="none" stroke="#FFF6CC" stroke-width="5" opacity=".7"/>`
   - sprout: `<path d="M0 10C8-20-6-44 2-66" fill="none" stroke="#3E9E4C" stroke-width="13" stroke-linecap="round"/><path d="M2-62C-18-104-72-98-82-72C-52-54-16-52 2-62Z" fill="#5BC26B"/><path d="M2-64C26-116 84-116 96-88C62-64 24-56 2-64Z" fill="#7BDB89"/>`
   - party: `<g transform="rotate(14)"><path d="M-66 12L0-150L66 12Z" fill="#FF6FA3" stroke="#E2558A" stroke-width="8" stroke-linejoin="round"/><g fill="#FFF"><circle cx="-22" cy="-24" r="10"/><circle cx="20" cy="-62" r="10"/><circle cx="-6" cy="-100" r="10"/><circle cx="30" cy="-10" r="10"/></g><circle cy="-156" r="21" fill="#FFD54A"/></g>`
   - bow: `<g transform="translate(46 22) rotate(18)" fill="#FF5C8A" stroke="#E0457A" stroke-width="7" stroke-linejoin="round"><path d="M0 0L-64-38Q-78 0-64 38Z"/><path d="M0 0L64-38Q78 0 64 38Z"/><circle r="19" fill="#E0457A"/></g>`
   - beanie: `<path d="M-160 78C-160-112 160-112 160 78Z" fill="#E85D4A"/><path d="M-72-58L-80 50M0-70V50M72-58L80 50" stroke="#C94A39" stroke-width="10" stroke-linecap="round"/><rect x="-170" y="46" width="340" height="58" rx="29" fill="#C94A39"/><circle cy="-104" r="32" fill="#FFF"/>`
10. **Placement** (`placing`, `shapes.ts:86-99`; applied `:172-176`):
    - On a board (`tile ≠ none`): none without a hat; with a hat `matrix(0.8 0 0 0.8 102.4 160)`.
    - Bare: bounds of the dense spline (in 1024 space) plus, with a hat, two extra points
      `(seat.x + left, seat.y + top)` and `(seat.x + right, seat.y)` where `[left, top, right]` =
      crown `[−186, −197, 163]`, halo `[−179, −154, 179]`, sprout `[−131, −178, 154]`, party `[−114, −307, 178]`,
      bow `[−59, −64, 206]`, beanie `[−170·stretch, −136, 170·stretch]` (`shapes.ts:73-75,91`);
      `k = min(984/width, 984/height)`; matrix `(k, 0, 0, k, 512 − k·(left+right)/2, 512 − k·(top+bottom)/2)`.
11. **Layer order** inside the placement group (`shapes.ts:171`): outline (fill, rim) → blush → mouth → clear glasses →
    `<g class="dh-gaze"><g class="dh-face" fill=<eye colour>>` eyes **or** dark glasses `</g></g>` → hat. Only the
    `dh-face` group moves (blink, glance, working sweep): the phone splits each picture into "everything but
    `.dh-face`" and "only `.dh-face`" layers (`S/ui-heads/bot-head.tsx:66-85`). Mouth, blush, clear glasses and hat
    stay put.
12. **Boards** (`tile ≠ none`, `render.ts:251-264`, `parts.ts:8-9`): draw `FRAME` (fill `#000` for `tile:dark`, else
    `#0A0A0A`), then `PANEL` (dark `#1C1C1E`, light `#F7F5F0`, color `TONES[color].panel`), then the head clipped to
    `PANEL`. Bare heads draw no frame or panel; the background is transparent.
13. **Motion parameters** per head (`shapeMotion`, `shapes.ts:65-70`): `specs ∈ {round, monocle}` → blinks, glance 0;
    else blinks unless dark glasses or `look ∈ {happy, sleepy}`; glance `0.4` with dark glasses or any mouth, else 1;
    `scale` = the placement `k` (1 when none). §10.5 uses these.

#### 10.4.9 Test vectors (ref238 renderer output; `compact`, light page, idle, colour grass unless noted)

Placement matrix and left/right eye per form (`look: slits`; blob uses seed 416723):

| form | matrix | eye rects (x, y, w, h, rx; rotate about centre) |
| --- | --- | --- |
| round | `1.64 0 0 1.64 -327.7 -327.7` | `515,359,54,114,27 r(-20 542 416)` · `635,359 … r(-20 662 416)` |
| blob | `1.528 0 0 1.528 -257.8 -270.2` | same as round |
| square | `1.763 0 0 1.763 -390.9 -390.9` | same as round |
| pill | `1.519 0 0 1.519 -265.5 -265.5` | `514.8,376.3,49.7,104.9,24.8 r(-20 539.6 428.7)` · `625.2,376.3 … r(-20 650 428.7)` |
| triangle | `2.001 0 0 2.001 -512.5 -546.4` | `514.6,480.8,46.4,98,23.2 r(-20 537.8 529.8)` · `617.8,480.8 … r(-20 641 529.8)` |
| hex | `1.749 0 0 1.749 -383.7 -383.7` | `515,365,54,114,27 r(-20 542 422)` · `635,365 … r(-20 662 422)` |
| cloud | `1.502 0 0 1.502 -244 -240.4` | `508.8,412.3,49.7,104.9,24.8 r(-20 533.6 464.7)` · `619.2,412.3 … r(-20 644 464.7)` |
| drop | `1.547 0 0 1.547 -280.2 -243` | `514.7,487.1,48.6,102.6,24.3 r(-20 539 538.4)` · `622.7,487.1 … r(-20 647 538.4)` |
| star | `1.692 0 0 1.692 -354.4 -347.1` | `514.3,438,42.1,88.9,21.1 r(-20 535.4 482.5)` · `607.9,438 … r(-20 629 482.5)` |
| heart | `1.608 0 0 1.608 -311.2 -329.9` | `502.7,409.1,48.6,102.6,24.3 r(-20 527 460.4)` · `610.7,409.1 … r(-20 635 460.4)` |

Round outline path starts `M512 212C528 212 543 213 559 216C574 218…`. Non-compact (72 pt) slits are `w 45, rx 22.5`
(`x 519.5 / 639.5`). States on round: thinking/speaking `425/545, 457, 54×98, rotate 0` (about `452/572, 506`);
done `425/545, 419, 54×114`, rotate `+24` / `−24` (about `452/572, 476`); offline `425/545, 488, 54×84`, rotate 90
(about `452/572, 530`).

Other parts on bare round (same matrix `1.64 … -327.7 -327.7` unless a hat):

| part | output |
| --- | --- |
| look dots | `circle 542,416 r39.6` · `662,416 r39.6` (non-compact r33) |
| look ovals | `ellipse 542,416 rx39.6 ry57 rotate(-10 542 416)` · `662,416 …` (non-compact rx33) |
| look googly | `place(530 416, 1)` · `place(674 416, 1)`; ring `r51 stroke-width 10.8`; pupil `cx18 cy-16.8 r30.6` |
| look happy / sleepy / stars / hearts | `place(542 416, 1.2)` · `place(662 416, 1.2)`; stars add `rotate(-10)` |
| specs shades / aviators | one `place(602 416, 1)`, no separate eyes |
| specs round / monocle | `place(602 416, 1)` glasses; eyes at `497/653, 359` (gap 78) about `524/680, 416` |
| mouth (any) | `place(602 512, 1)`, stroke-width 23.4 |
| blush | `place(602 416, 1)`, cheeks at `±102` |
| hat crown | matrix `1.235 0 0 1.235 -120.1 1.5`, hat `translate(512 212) scale(1.6)` |
| hat halo | `1.305 0 0 1.305 -156.2 -55.7` |
| hat sprout | `1.265 0 0 1.265 -135.6 -23` |
| hat party | `1.085 0 0 1.085 -43.5 123.1` |
| hat bow | `1.482 0 0 1.482 -246.7 -199.3`, hat `translate(547.2 212) scale(1.6)` |
| hat beanie | `1.337 0 0 1.337 -172.5 -81.6`, hat `translate(512 212) scale(1.19 1)` |
| any board + hat | `0.8 0 0 0.8 102.4 160` |

Fills/eyes (round): paper bare → `#EFE9DB` + rim `#B8AD95`, eyes `#1A1A1A`; paper light board `#D9D0BD`; paper colour
board `#FFFDF8`; ink bare light page `#0A0A0A` eyes `#FFFFFF`; ink bare dark page `#F4F4F2` eyes `#1A1A1A`; ink bare
mode unknown `#0A0A0A` + rim `#636366`; ink dark board `#F4F4F2` eyes `#1A1A1A`; grass dark board on a dark page:
eyes `#1A1A1A`.

#### 10.4.10 Heads on a real install (read-only, 2026-10-09, names changed)

Read from the `dispatch-head` and `hermes-bots` keys of `~/.hermes/profile.yaml` and
`~/.hermes/profiles/*/profile.yaml` on this Mac (the gateway Hermes home), and the size of each
`assets/avatar.png`; nothing was written, `hermes` was not run.

- **Every saved head is theme `shape`; no hats, glasses, mouths, blush or boards are in use.** Forms in use: round,
  hex, square, cloud, triangle, blob. Looks in use: slits, dots, ovals. Four profiles with a `profile.yaml` have no saved head and draw the
  §10.3 default (`finance`; `maple-revenue-operator`, `bike-shop` and `ivy` are also `hidden`). Three more
  directories under `profiles/` (`ios-build`, `dispatch-qa-e2e-fg-b-926`, `dispatch-qa-e2e-fg-c-926`) hold no
  `profile.yaml` or `config.yaml`; whether `profiles.list` lists them is UNKNOWN (§13).
- **Every avatar asset is a 288×288 HQ mirror or a 160×160 desktop backfill**, so all are ignored by the §10.1 rule and
  every bot draws its head. Native must implement that PNG-size rule, or it would show the mirrors.

| profile | stored `v` | parsed head (after §10.2 fix-ups) | matrix (compact) | eyes (light page) |
| --- | --- | --- | --- | --- |
| `default` ("Hermes", pinned) | 4 | ink, round, **ovals**; stored `mouth: open`, `tile: color` become none (v < 5 / v < 6) | `1.64 0 0 1.64 -327.7 -327.7` | ovals `542/662, 416, rx39.6 ry57, rotate(-10)`; fill `#0A0A0A` (`#F4F4F2` dark page) |
| `app` | 6 | lilac, hex, slits | `1.749 0 0 1.749 -383.7 -383.7` | hex row above |
| `otto` | 6 | coral, square, **dots** | `1.763 0 0 1.763 -390.9 -390.9` | `circle 542/662, 416, r39.6` |
| `book-club` | 6 | lilac, cloud, **ovals** | `1.502 0 0 1.502 -244 -240.4` | `ellipse 533.6/644, 464.7, rx36.4 ry52.4, rotate(-10)` |
| `home` | 6 | peach, triangle, slits | `2.001 0 0 2.001 -512.5 -546.4` | triangle row above |
| `inbox` (pinned) | 6 | sky, blob (seed 416723), **ovals** | `1.528 0 0 1.528 -257.8 -270.2` | `ellipse 542/662, 416, rx39.6 ry57, rotate(-10)` |
| `wren` | 6 | butter, round, slits | round row above | round row above |
| `northwind` | 6 | butter, triangle, slits | triangle row above | triangle row above |
| `finance`, `maple-revenue-operator`, `bike-shop`, `ivy` | — | default: butter square / mint cloud / lime hex / grass round | §10.3 | slits |

M1 therefore needs: the Shapes theme with all ten forms (triangle is in use), the slits/dots/ovals looks, both page
modes, and the default head. The other looks, glasses, mouths, blush, hats and boards are transcribed above so
another user's heads (or a later edit) still draw correctly; the other six themes (§10.6) are not in use here.

### 10.5 Motion (lists and headers)

- At rest: blink (scaleY to 0.08 at 42 % over 0.19 s) every 4.2–9.4 s (first after 1.2–6 s); glance the eye layer to
  one of `GLANCES = [(0,0),(−0.146,0.025),(−0.078,0.078),(−0.02,−0.012),(−0.11,−0.02)]` × head width every 3.4–8 s;
  no blink for `happy`/`sleepy` looks or dark glasses; glance ×0.4 with a mouth or dark glasses, 0 behind clear
  glasses (`S/ui-heads/motion.ts:19-24,80-150`, `S/ui-heads/shapes.ts:65-74`, `S/ui-heads/bot-head.css:17-19`).
  Per-head phase offset `(name.length·0.7) % 5` s (`renderer-hooks.tsx:45`).
- Working (badge working/computer): the shape "breathes" `scale(1.05,0.95)` at 50 % of 1.7 s about (50 %, 94 %) and
  the eyes sweep `translateX −7 % → −2.3 % → 2.3 % → 7 %` over 2.4 s (short variant ±3.1 %)
  (`S/ui-heads/bot-head.css:42-73`).
- Hold still under Reduce Motion, Low Power Mode, when hidden or covered. Unavailable bots: desaturate 45 %
  (`S/ui-kit/bot-avatar.css:3`).

### 10.6 Other themes

`robot` (the app icon's head; `S/ui-heads/robot.ts`), `persona` (`persona.ts`), `dots` (9×9 / 5×5 lamp matrix,
`render.ts:39-135`), `orb` (`:137-166`), `pixel` (`:168-227`), `glyph` (emoji/letters, `:229-240`). All are framed
(`FRAME` + `PANEL`) and are not mode-dependent. None of the owner's bots uses them (§10.4.10), so native M1 may
draw a non-`shape` head as that bot's §10.3 default and port these themes later (other users' gateways may use them).

### 10.7 Saving a head (later milestone) (`S/ui-heads/sync.ts:66-98`, `S/ui-heads/mirror.ts:55-70`)

`profiles.configure {name, ui_meta:{"dispatch-head": {...head, headset: ears=='headset'} | null},
ui_meta_expected_revisions:{"dispatch-head": <rev read>}}`; conflict → "This bot’s head was changed on another
device. Save again to replace it with yours."; then mirror a 288×288 PNG of the head to `profiles.set_asset` so
desktop Hermes shows it (or clear only our own mirror on reset).

### 10.8 Group avatar

2 members: two heads at 64 % at (0,0) and (36 %,36 %); 3: 54 % at (23 %,0), 46 % at (0,50 %), 42 % at (56 %,54 %);
background `fill-4` grey; member heads ringed 1.5 pt in the page background (`S/ui-kit/bot-avatar.tsx:67-87`,
`S/ui-kit/bot-avatar.css:8-9`).

---

## 11. Device-local state inventory (per gateway account)

| Web key | Holds | Native equivalent |
| --- | --- | --- |
| `dispatch.roster.v1` | last full roster per account (3) | on-disk roster cache |
| `dispatch.bot-activity.v1` | canonical `last_active` baselines | unread baselines |
| `hermes.desktop.unreadFinishedSessions` | `{profile:[unread ids]}` | unread markers |
| `hermes.desktop.sessionSeenCounts` | `{profile:{durableId:count}}` | Sessions watermarks |
| `hermes.plugin.hermes-bots.bot-meta-v2` | local bot meta snapshot | meta overlay |
| `hermes.plugin.hermes-bots.bot-sections-v1` | section records `[{id,name}]` | sections list |
| `dispatch.bots.pinOrder.v1` | tile order (roster keys) | tile order |
| `dispatch.botMutes.v1` | mutes | mutes |
| `dispatch.roomUnread.v1` | room unread marks | — (M1) |
| `dispatch.sessions.showRuns` | Background Runs toggle | setting |
| `hermes.desktop.sidebar*` | Sessions grouping/sort/filters | settings |
| `dispatch.hideSweep.v1`, `dispatch.hideSweepSeats.v1` | hide-sweep bookkeeping | not needed (see §12) |

The web app isolates the whole localStorage per gateway account (`S/bot-unread-runtime.ts:23-24`).

---

## 12. Discrepancies and notes for the native build

1. **Phone ≠ desktop roster rules**: preview session, time and sort use the §6.3 rule (Bot Chat first, else
   `last_session`), not the desktop's `max(canonical,last)` + worker age. Implement the phone rule.
2. **Name precedence**: `profiles.list` has no `title`; REST `/api/profiles` has `bot_title` (= meta title). The
   fixture's `ui_meta['hermes-bots'].display_name` is not a real field — the app ignores it.
3. **`message_count` counts tool rows**; never show it as an unread count. `live_message_count` exists on newer
   gateways but the web app does not use it for display.
4. **Unread for bot chats is device-local**; the gateway's per-session `unread` watermark is used only for listed
   (visible) sessions, which Bot Chats are not.
5. **Gateway writes this area makes, and what M1 does** (resolved; spec decision). The web phone writes to the gateway
   without a user action in four places, and on user actions in others:

   | Write | Web trigger | Wire | Source | M1 |
   | --- | --- | --- | --- | --- |
   | Pinned-section reconcile | every roster/meta change while the Bots pane holds roster data — cache, slim or full (§7.4) | `profiles.configure {name, ui_meta:{'hermes-bots': <whole merged meta>}}`, no CAS | `S/ui-bots/pinned-section.ts:28-46`, **[gate]** `B/pinned-section-gates.ts:13-14` | **no** |
   | Section-name backfill | same effect, members with a known `sectionId` but no `sectionName` | same call | `HB/roster-pane.tsx:306-309`, `HB/user-sections.ts:203-221` | **no** |
   | Hide sweep | 15 s after load and on reconnect (≤ once per 10 min): lists each changed bot's 200 newest sessions and `PATCH`es `{"hidden":true}` on rows titled `Bot Chat`, `Agent Inbox` or `Group: …` older than 5 min | `PATCH /api/sessions/{id}` | **[gate]** `B/lt-sweep-gates.ts:33-35`, `S/hide-sweep.ts:1-87`, `HB/session-sweep.ts:247-276` | **no** (redundant with `session.create {hidden:true}`) |
   | SOUL protocol backfill | full roster, only when `profiles.list` says `bot_mode_protocol: false` | `profiles.describe` then `profiles.configure {name, soul}` | `HB/soul.ts:101-146`; full-answer only, **[gate]** `B/fe-lists-gates.ts:356-367` | **no** (current gateways always send `true`, `AG/tui_gateway/methods_profiles.py:298-302`, so the web never runs it either) |
   | Bot unread / read / Mark as Read·Unread | roster activity, opening a bot, row menu | **none** — localStorage only | `S/bot-unread-runtime.ts:38-53,128-133`, `V/store/session-unread.ts:214-296` | implement, device-local (§6.7) |
   | Pin / Unpin, move section | user (row menu, swipe, drag) | `profiles.configure` with `pinPatch` / `sectionMovePatch` | `S/ui-bots/pinned-section-model.ts:65-78`, `S/ui-bots/bot-actions.ts:50-83` | not in M1 (no pin UI); later: one combined write as §7.4 |
   | Sessions row open-clear | user opens a listed row whose server `unread` is `true` | `PATCH /api/sessions/{id} {"unread":false,"profile":p}` | §9.3 | **yes** |
   | Bot Chat mint | user taps a bot with no `canonical_session` and the registry confirms there is none | `session.create`, `session.title` | §8.2 | **yes**, only on that path |

   Reasons for "no" on the automatic ones: (a) they are not user actions, and `PLAN.md` keeps testing on the owner's
   gateway read-only; (b) the owner runs the web app side by side, and it keeps doing all of them, so nothing is lost;
   (c) `hermes-bots` writes replace the whole object with no revision check (§2.4, `HB/data.ts:350-372`), so a second
   automatic writer working from a stale copy could revert a change the owner just made elsewhere. Native M1 still
   **reads** and draws everything these writes produce (Pinned section, section names, hidden flags).
   Testing switch: a client-wide `readOnlyGateway` flag (on for automated runs against the owner's gateway) refuses
   every write locally — the two "yes" rows above included — and clears the Sessions dot locally instead.
6. **`DEEP_COLORS`** comment vs code: unused; eyes are white on light pages for every colour except paper and an
   ink head drawn white (§10.4 item 4).
7. **Contract vs gateway**: `install_id`, `live_message_count`, `_lineage_root_id` are beyond `C:`; `root_title` is
   absent from the title-lookup row.
8. **Sidebar comment vs code**: `S/sidebar-probe.ts:1-3` says "30 recents"; the code default is 50
   (`V/store/layout.ts:41`). No phone gate changes it.
9. **The "Can’t reach this bot" state** depends on per-source reachability that a single-gateway phone always
   reports as reachable; native should instead grey rows only when the gateway itself is down (design call).
10. **Bot open, comment vs code**: the vendored `openRosterBot` comment says resolution "always goes through the …
    title registry" (`HB/roster-actions.ts:216-219`); on the phone the r1-65/r2-86 gates open the roster's known chat
    first and ask the registry behind it (§8).
11. **Pinned-section gate comment vs code**: "only from a live roster (never a cached one)" (`B/pinned-section-gates.ts:3-4`)
    vs `live = Array.isArray(data?.profiles)`, which a cached paint satisfies (§7.4).
12. **Roster timeout comment vs measurement**: the gate keeps the 30 s default while saying the call takes 18–107 s
    (`B/fe-lists-gates.ts:1272-1276`); native uses 120 s for the full read (§2.1.1).
13. **Sessions open-clear is conditional**: the web PATCHes `unread:false` only for a listed row whose server
    `unread` is `true`, which needs a watermark some client set earlier (`last_read_at` NULL reads as read) (§9.3).

## 13. UNKNOWNs

- The exact `host.state.profile` the web phone uses for the roster's `requestForBot(activeBot …)` owner when the user
  has switched profiles (assumed: the socket's default profile; `profiles.list` ignores it anyway).
- ~~Which head themes the owner's real bots use~~ — resolved in §10.4.10 (all `shape`; slits/dots/ovals; no extras),
  read from `~/.hermes` on this Mac on 2026-10-09. Assumed to be the gateway the owner's phone signs in to; heads saved
  later will differ.
- Whether `profiles.list` lists the three `profiles/` directories that have no `profile.yaml`/`config.yaml`
  (`ios-build`, `dispatch-qa-e2e-fg-b-926`, `dispatch-qa-e2e-fg-c-926`); if listed they draw default heads.
- Why the roster loads at all when `profiles.list` takes 18–107 s against a 30 s client timeout: §2.1.1 explains it by
  the gateway finishing the dropped call and warming its per-profile memo — read from code, not measured.
- Whether `recentRunTitle`/`humanJobTitle` cron title wording (`S/fe-lists-r5.ts`, `S/audit-c-format.ts`) must be
  matched exactly for the "Cron · …" preview — not traced here.
- Group-room data (`groups.*` RPCs, `$groupChats`) and their unread/turn state — not covered.
- `session.resume` / open wire details behind `openStoredBotChat` (§8.1 step 4.3) — chat spec.
