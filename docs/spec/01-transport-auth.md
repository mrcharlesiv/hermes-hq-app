# 01 · Transport, connection and authentication

Implementation-ready description of how Hermes HQ (web app in a Capacitor WKWebView, reference **release-build238**)
finds a gateway, signs in, keeps a session alive, talks REST and JSON-RPC over WebSocket, and recovers from drops.
Where the web client and Hermes's own code or docs disagree, **the web client's behaviour is the spec** and the
disagreement is flagged (section 20).

## 0. Sources, notation, ground rules

| Prefix | Path | What |
| --- | --- | --- |
| `W:` | `/Users/me/Projects/hermes-hq-native-ref238/` | The reference web app + its native Swift shell (read only). |
| `V:` | `W:vendor/hermes/apps/` | Vendored Hermes desktop renderer + shared transport, commit `02e4118` (`W:vendor/source.json`). **Patched at build time** by string-replacement "gates" in `W:build/*-gates.ts` and `W:build/shared-replay-performance.ts`: what runs = vendored file + gates. |
| `HA:` | `/Users/me/.hermes/hermes-agent/` | Hermes server source, local checkout `d94b70f` (2026-10-08). Read only; never run or imported. Line numbers are from this checkout; a user's gateway may run another version. |
| `NAT:` | `/Users/me/Projects/hermes-hq-native/` | The native rebuild (HQ Native): `PLAN.md`, `docs/ARCHITECTURE.md`, `project.yml`, `App/Info.plist`. |

`file:N` or `file:N-M` cite lines. "Native" = the Swift plugin `HermesNativePlugin` in `W:ios/App/App/HermesNative.swift`
(jsName `HermesNative`, `HermesNative.swift:1038-1044`). "Renderer" = the vendored React app.

Ground rules that every section below assumes:

1. **All credentials live in native code.** The renderer never sees a cookie, bearer, refresh token or ws-ticket. It
   calls `native.request({path,...})` for REST and drives a fake `WebSocket` class whose frames cross to native
   `wsOpen/wsSend/wsClose/wsPing` (`W:src/bridge/native.ts:16-58`, `W:src/bridge/shim.ts:196-206`,
   `W:src/bridge/socket.ts:195-501`). The native rebuild collapses this: one Swift layer owns everything.
2. **Gateway = `hermes serve`'s FastAPI web server** (`HA:hermes_cli/web_server.py`) with its JSON-RPC sidecar at
   `/api/ws` (`HA:hermes_cli/web_routers/chat_ws.py:701-722`, `HA:tui_gateway/ws.py`). Not the `/v1` messaging API.
3. **Every reachable gateway is "gated"** (`app.state.auth_required == true`): Hermes refuses to serve a non-loopback
   bind without an auth provider, and `--insecure` no longer bypasses it (`HA:hermes_cli/web_server.py:1186-1209`).
   A phone can only reach non-loopback binds, so the phone always speaks the gated protocol.
4. **Never retry a sign-in in a loop.** One login attempt per user action. See section 15.

### 0.1 Milestone-1 decisions (open questions resolved 2026-10-09)

Each row is settled from source. The detail and citations are in the section named. Where HQ Native deliberately
differs from the web client, the section says so.

| # | Question | M1 decision | Section |
| --- | --- | --- | --- |
| D1 | Send `client.capabilities {"server_requests":true}` after `gateway.ready`? | **No.** Never send it. Never answer a server→client request frame or an `open_requests` entry, not even with an error. When HQ Native is the only client on a session, the gateway fails every question fast and the turn continues. When the desktop or web HQ app is attached and has advertised, that app answers. | 11.6.1 |
| D2 | Token field on the sign-in screen? | **No token field.** The screen shows the address, then Sign in with Nous and/or username + password, as the probe (4.1) says. This is the recommended default and the owner may overrule it. | 3.1 |
| D3 | Keychain for `com.charlesmcdowell.hermeshq.native` | Use the app's own item: service `ai.hermes.hqnative.gateway`, account `primary`, the app's default access group, and the same `SavedAccounts` JSON. No shared access group and no migration: the owner signs in once in HQ Native. (Resolves UNKNOWN 21.5.) | 2.4.1 |
| D4 | What makes `GET /api/auth/me` "verified"? | An HTTP 2xx whose body parses as a JSON **object**. Its contents are ignored, and every field decodes as optional. | 5.1 step 4 |
| D5 | Connect links / QR | Not handled in M1. Never claim the `hermes` scheme. Register only `hermeshq-native`, and use it as the Nous web-auth callback scheme. | 2.3 |
| D6 | Nous renewal when the access TTL is ≤ 60 s | Renew once `max(lifetime − 60 s, lifetime / 2)` has passed since the pair arrived, measured on the phone's clock, instead of before every request. 401 → renew → retry once stays as the safety net. For lifetimes under 120 s this deliberately differs from the web client. Build 296: from half the lifetime the renewal runs alongside the request; only D6's point makes a request wait. | 7.1 |

---

## 1. Architecture today (what to replace)

```
SwiftUI/UIKit (native rebuild)                Today (ref238)
--------------------------------              ------------------------------------------------------------
                                              Renderer JSON-RPC client (V:shared/src/json-rpc-gateway.ts)
                                                 │ new WebSocket(wss://host/api/ws?profile=P)   (fake class)
                                                 ▼
RPCSocket (URLSessionWebSocketTask) ◀──────── W:src/bridge/socket.ts NativeWebSocket ──Capacitor──▶ wsOpen(id,path)
REST (URLSession)                   ◀──────── W:src/bridge/shim.ts api() ──────────────Capacitor──▶ request({path})
AuthSession / Keychain              ◀──────── HermesNative.swift (cookies, Nous bearer, ws-ticket, Keychain)
NousSignIn                          ◀──────── HermesNousSignIn.swift + DispatchOAuthRelay (HermesPlatformExtras.swift)
```

Public internet path when the gateway is exposed through Tailscale Funnel (`W:docs/remote-access.md:8-12`):

```
iPhone ──HTTPS──▶ Tailscale Funnel :443|:8443|:10000 ──▶ hermes-hq-edge 127.0.0.1:9139 ──▶ hermes serve (gated, nous+basic)
       └── Sign in with Nous: ASWebAuthenticationSession ──▶ <gateway>/auth/native/authorize ──▶ portal.nousresearch.com
```
Funnel port choice: `W:gateway-edge/hermes-hq-connect.mjs:47,417`; public URL `https://<dnsName>[:port]`
(`hermes-hq-connect.mjs:420`). Private path (Tailscale on the phone, LAN): the phone talks to `hermes serve` directly.

---

## 2. Describing a gateway

### 2.1 Saved account model

An account is **(gateway URL, username)**. Nothing else identifies it.

| Field | Meaning | Source |
| --- | --- | --- |
| `url` | Normalised base URL (2.2). May carry a path prefix (reverse proxy sub-path). | `HermesNative.swift:31-48` |
| `username` | Password accounts: the typed username. Nous accounts: `"nous:" + user_id` (Portal `sub`). | `HermesNousSignIn.swift:92-93` |
| `label` | Optional phone-local name, trimmed, max 60 chars; blank = show host. | `HermesNative.swift:43-44,238-247` |
| `provider` | Password provider name used at sign-in (e.g. `"basic"`), cached. | `HermesNative.swift:41-42,1956` |
| `cookies` | Password accounts only: the gateway's session cookies (2.4). | `HermesNative.swift:37-40` |
| `nous` | Nous accounts only: `{accessToken, refreshToken, expiresAt, userId}`. | `HermesNousSignIn.swift:18-28` |
| `password` | **Never persisted.** In memory for one login only; stripped on every Keychain write. | `HermesNative.swift:34-36,103-108,196-198` |

Account key (equality, lookups): `lowercase(scheme)://lowercase(host)[:port][path]` with trailing `/` removed, then
`"\n"`, then username (`HermesNative.swift:58-67`). UI shows a Nous account as "Nous account", never its id
(`W:src/connection-startup.ts:72-74`).

### 2.2 URL normalisation and validation (two layers, both required)

Renderer, before calling native (`W:src/connection-startup.ts:96-121`):
- Trim. If the text already has a `scheme://`, lowercase only the scheme (`HTTPS://` → `https://`).
- No scheme: prepend `http://` when the host is "local" (loopback, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`,
  `100.64/10`, `::1`, `fe80::/10`, `fc00::/7`, `localhost`, single-label names, `*.local`, `*.ts.net`), else `https://`.

Native `validated()` (`HermesNative.swift:1572-1582`), applied to every sign-in and probe:
- Must parse; **no userinfo, no query, no fragment**; host non-empty; scheme `http` or `https`.
  Failure → code `invalid-url`.
- `http` allowed only when `HermesTransportPolicy.cleartextAllowed(host)` (`W:ios/App/Shared/HermesTransportShared.swift:126-144`):
  loopback, RFC1918, link-local, Tailscale `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, `fe80::/10`, `fc00::/7`,
  `localhost`, single-label names, `*.local`, `*.ts.net`. Otherwise code `insecure-url`.
- Stored with lowercase scheme and leading/trailing `/` trimmed.
- ATS is opened in Info.plist (`NSAllowsArbitraryLoads = true`, `W:ios/App/App/Info.plist:35-45`) and the rule above
  is enforced in code instead. The native app must do the same (ATS cannot express `100.64.0.0/10`).

Every request URL is built by `endpoint(path)` (`HermesNative.swift:1583-1592`): `path` must start with `/`, not `//`,
no `\`, CR or LF; result = `base + path`; host and port must equal the base's; no userinfo; the standardised path
must start with `base.path + "/"` (keeps requests under a proxy prefix). Then `admitTransport` (2.5).

### 2.3 Connect link (QR from the gateway computer)

`hermes://connect?url=<percent-encoded https URL>` (`W:gateway-edge/hermes-hq-connect.mjs:421`), URL scheme `hermes`
(`Info.plist:29`). Accepted only when the inner URL is `https`, host contains a `.`, no userinfo/query/fragment,
path empty or `/`, ≤ 300 chars; stored as `https://<host lowercased>[:port]` (`W:ios/App/App/HermesPlatform.swift:1425-1442`).
It **only prefills** the sign-in form; it never signs in. With another account already saved it opens "Add Gateway"
(`W:src/main.ts:505-521`).

**HQ Native M1 (D5): no connect-link or QR handling.**
- The QR that `hermes-hq-connect.mjs` prints encodes `hermes://connect?url=…` (`hermes-hq-connect.mjs:787-791`), and the
  web app claims `hermes` (`W:ios/App/App/Info.plist:29`). When two installed apps claim one custom scheme, iOS opens
  one of them, and Apple documents no rule for which (platform behaviour, not in this repo). If HQ Native also claimed
  `hermes`, the camera's "Open in Hermes HQ" could land in either app on the owner's phone, where both are installed.
  So HQ Native registers only `hermeshq-native` (`NAT:App/Info.plist:15-19`) and never `hermes`.
- Nothing produces a `hermeshq-native://` link today, and the connect script already offers the typed path. Agent mode
  prints the address to paste (`hermes-hq-connect.mjs:782-785`). QR mode prints "type: <url>" under the code (`:791`).
  In M1, the user pastes the address into the address field, and the probe (4.1) picks the sign-in buttons.
- The Nous `ASWebAuthenticationSession` needs a callback scheme, but the callback never fires because the loopback relay
  ends the sheet (6.1 step 5). HQ Native passes `.customScheme("hermeshq-native")` there, not the web app's `"hermes"`
  (`HermesNousSignIn.swift:121`). The scheme does not need to be registered for this.
- A later milestone that adds prefill should accept `hermeshq-native://connect?url=…`, with exactly the validation above
  (`HermesPlatform.swift:1426-1432`) and the same prefill-only rule. Emitting such a link needs a change to
  `hermes-hq-connect.mjs` in the web repo, which is not part of M1.

### 2.4 Keychain

| Item | Value |
| --- | --- |
| Class / service / account | `kSecClassGenericPassword`, `kSecAttrService = "ai.hermes.ios.gateway"`, `kSecAttrAccount = "primary"` (`HermesNative.swift:119-120`) |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (2026-10-29; was `WhenUnlockedThisDeviceOnly`, `HermesNative.swift:187-188`: a Nous rotation in the background while locked was never saved, so the next launch was signed out) |
| Access group | App default group, also listed by the Share extension (`$(AppIdentifierPrefix)com.charlesmcdowell.dispatch`, `W:ios/App/ShareExtension/ShareExtension.entitlements:16-19`) |
| Encoding | JSON of `SavedAccounts {current: key?, accounts: [Credentials]}`, most-recent first; a legacy single-`Credentials` item decodes as a one-account list (`HermesNative.swift:54-115`) |
| Empty list | Item deleted (`HermesNative.swift:181-186`) |
| Serialisation | Every read-modify-write runs on one serial queue `dispatch.vault` (`HermesNative.swift:121-132`) |
| Errors | `errSecInteractionNotAllowed` → `keychain-locked` (retry, never re-sign-in); undecodable → `keychain-unreadable`; other → `keychain-unavailable` (`HermesNative.swift:158-170`) |
| Failed sign-out | `UserDefaults["dispatch.vault.signedOut"] = true` until a verified sign-in saves again; restore treats the current account as signed out and retries the delete (`W:ios/App/App/HermesNativeExtras.swift:30-36`, `HermesNative.swift:139-149`) |

Stored shape (Swift `Codable` default keys; values invented):

```json
{"current":"https://studio.tail1234.ts.net:10000\nnous:user_abc",
 "accounts":[
  {"url":"https://studio.tail1234.ts.net:10000","username":"nous:user_abc","label":"Studio",
   "nous":{"accessToken":"eyJ…","refreshToken":"nrt_…","expiresAt":1791234567,"userId":"user_abc"}},
  {"url":"https://studio.tail1234.ts.net","username":"fleet","provider":"basic",
   "cookies":[{"name":"__Host-hermes_session_at","value":"…","domain":"studio.tail1234.ts.net","path":"/",
               "expires":1791200000,"secure":true,"httpOnly":true,"sameSite":"lax"},
              {"name":"__Host-hermes_session_rt","value":"…","domain":"…","path":"/","expires":1793700000,"secure":true,"httpOnly":true,"sameSite":"lax"}]}]}
```
Cookie record fields: `name, value, domain, path, expires (epoch s, optional), secure, httpOnly?, sameSite?`
(`HermesNative.swift:12-29`). HQ Native cannot read this item and does not try (2.4.1).

#### 2.4.1 HQ Native's own item (D3)

Facts:
- The web app's query names no `kSecAttrAccessGroup` (`HermesNative.swift:119-120`). Its item therefore lives in the
  app's default group, which is its application identifier `2Y6UGK7GET.com.charlesmcdowell.dispatch`
  (`W:docs/share-extension.md:33`, `W:scripts/release_checks.py:50`).
- HQ Native is `com.charlesmcdowell.hermeshq.native` on the same team, `2Y6UGK7GET` (`NAT:project.yml:12,32`). It has no
  entitlements file, so its default group is `2Y6UGK7GET.com.charlesmcdowell.hermeshq.native`, and it cannot see the
  web item.
- Sharing is technically possible. Team provisioning profiles allow every `TEAMID.*` group, and the Share extension
  reads the item this way (`W:ios/App/ShareExtension/ShareExtension.entitlements:12-19`). It is still rejected:
  - Two apps would rotate the **same** Nous refresh-token family from two processes, and those processes share no
    `NousRenewals` single flight or successor map (7.3 rules 1–2). The web app's adopt-or-rotate rule (7.3 rule 6)
    exists only between it and its own extension. One stale send outside the gateway's 30 s coalescing window revokes
    the family. That signs out **both** apps, including the one the owner uses every day.
  - There is one `current` pointer and one list. A switch, an add or a sign-out in one app would change the other.
    The "signed out" flag lives in each app's own `UserDefaults` (`W:ios/App/App/HermesNativeExtras.swift:30-36`), so
    the two apps would disagree about it.

| Item | HQ Native value |
| --- | --- |
| Class / service / account | `kSecClassGenericPassword`, service **`ai.hermes.hqnative.gateway`**, account `primary` |
| Access group | None named, so the app default (`2Y6UGK7GET.com.charlesmcdowell.hermeshq.native`). No `keychain-access-groups` entitlement in M1. |
| Accessibility | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (same as the web app) |
| Encoding | The same `SavedAccounts` JSON as above, plus an optional `nous.obtainedAt` (D6, 7.1). Never write `password`, and ignore it when decoding. No legacy single-`Credentials` fallback is needed. |
| Serialisation / errors | Same as the table above: one serial queue; `keychain-locked` / `keychain-unreadable` / `keychain-unavailable`. |
| Signed-out flag | `UserDefaults["hqnative.vault.signedOut"]`, with the same semantics as `dispatch.vault.signedOut` |
| Migration | None. The owner signs in once in HQ Native. Each `/auth/native/token` exchange starts from a fresh authorization code, which gives a new refresh-token family (the fixture mints a new family per exchange: `nous-fixture-gateway.py:149-157,268-275`). HQ Native and the web app therefore hold independent Nous sessions and cannot revoke each other. A password sign-in adds a second stateless `basic` session, which is harmless (5.1). |

A distinct service name, and not only a distinct group, keeps a later build safe. If that build adds the web app's
group so it can offer a one-time import, a query without `kSecAttrAccessGroup` still cannot match the wrong item.
Simulator: the build must be code-signed, which Xcode's automatic signing does (`NAT:project.yml:12-13`). An unsigned
Simulator build has no Keychain identity, and every call returns `-34018` (`W:docs/stage1-report.md:85`).

### 2.5 Tailscale admission (nothing leaves the phone toward a tailnet-only address while Tailscale is off)

A gateway is "tailnet-only" when its URL is `http://` and the host is a Tailscale address (`100.64/10`,
`fd7a:115c:a1e0::/48`) or a `*.ts.net` name (`HermesTransportShared.swift:169-173`). Tailscale is "up" when some
`utun*` interface holds a tailnet address (cellular `pdp_ip*` CGNAT `100.64/10` addresses do not count,
`HermesTransportShared.swift:174-179`); interfaces come from `getifaddrs` (`HermesTransportShared.swift:185-199`).
Every request and socket asks `admitTransport` (`HermesNative.swift:1606-1610`); refusal = code `tailscale-off`
("Turn on Tailscale to reach the computer running Hermes.", `HermesNative.swift:326-328`) and, for `/api/ws`, lifecycle event
`{state:"socket-failed", reason:"tailscale-off"}` (`HermesNative.swift:2514-2519`). HTTPS gateways are never blocked.

---

## 3. Authentication modes

| Mode | Server support | Web client today | REST credential | WS credential |
| --- | --- | --- | --- | --- |
| **A. Password** (provider with `supports_password`, normally `basic`) | `POST /auth/password-login` → HttpOnly cookies (`HA:hermes_cli/dashboard_auth/routes.py:447-493`) | **Yes** | Cookie jar (`hermes_session_at` / `_rt` / `_provider`) | `?ticket=` from `POST /api/auth/ws-ticket` |
| **B. Sign in with Nous** (RFC 8252 native PKCE, provider `nous`) | `/auth/native/{authorize,token,refresh}` (`routes.py:289-335,574-617`) | **Yes** (provider pinned to `nous`) | `Authorization: Bearer <access_token>`, cookies off | `?ticket=` |
| C. Legacy session token (`X-Hermes-Session-Token`, `Authorization: Bearer <_SESSION_TOKEN>`, `?token=` on WS) | Only when **not** gated (loopback/desktop-owned backend) (`HA:hermes_cli/web_server.py:387,457-477,702-720`; `HA:hermes_cli/web_server_chat.py:369-374`) | **No.** Native WS refuses `token`/`ticket` in renderer URLs (`socket.ts:238`, `HermesNative.swift:2524`); `request` never adds the header. Gated mode explicitly rejects `_SESSION_TOKEN` (`web_server_chat.py:250-268`). | — | — |
| D. Gated `?token=<session access token>` on WS | Accepted (`web_server_chat.py:332-365`) | No (tickets only) | — | — |
| E. Ticket in `Sec-WebSocket-Protocol` (`hermes-gateway-v1` + `hermes-gateway-ticket.<t>`) | Accepted; selected protocol echoed is `hermes-gateway-v1` (`web_server_chat.py:207-222,299-317`) | No | — | — |
| F. Other session providers (e.g. `self-hosted` OIDC, `HA:plugins/dashboard_auth/self_hosted/__init__.py:83`) via native PKCE | Server's native flow is provider-agnostic (`routes.py:279-335`) | No (iOS pins `provider=nous`, `HermesNousSignIn.swift:58-66`). **HQ Native: yes** ([own-login], below) | `Authorization: Bearer` (the provider's verified ID token) | `?ticket=` |

The native rebuild needs **A and B**.

**[own-login] Mode F in HQ Native** (tester Papy, 2026-11-12: "not working with a self-hosted OIDC"). When `/api/status`
lists `native_pkce` but no `nous` provider, the probe reads `GET /api/auth/providers` and takes the first provider that
is neither `nous` nor a password one (`NousGatewayProtocol.ownLogin`). The form's browser button then reads "Sign in
with Single Sign-On" (or "Sign in with <display_name>" for a provider the gateway named itself), and the sign-in is
mode B with that provider's name in `/auth/native/authorize?provider=` and in `/auth/native/refresh`. The pair is saved
as a `.nous`-kind account whose tokens carry `provider` (nil = Nous; `GatewayAccount.usesOwnLogin`); an answer for any
other provider is refused. A login that hands out no refresh token (no `offline_access` scope) is accepted for these
providers only: nothing renews, and the session ends with its access token (`NousTokens.canRenew`). With Nous also on
offer, Nous stays the browser way in. Not run against a real IdP here (unit tests only).

**[own-vpn]** Plain `http://` is also allowed for names under `.home.arpa`, `.internal` and `.lan`
(`GatewayAddress.privateNameSuffixes`): a WireGuard or home network's own DNS. Its 10.x / 172.16–31.x / 192.168.x /
`fd…` addresses were always allowed; only Tailscale addresses wait for Tailscale to be on (2.5).

Server-side gate order for HTTP (`HA:hermes_cli/web_server.py:629-731`): Host check (400) → gated middleware (cookie or
bearer; `HA:hermes_cli/dashboard_auth/middleware.py:160-217`) → legacy token middleware (no-op when gated) → token-route
seam. Public without credentials when gated: `/api/health`, `/api/status`, `/api/config/defaults`, `/api/config/schema`,
`/api/model/info`, `/api/dashboard/themes`, `/api/dashboard/plugins`, `/api/cron/fire` (exact match,
`HA:hermes_cli/dashboard_auth/public_paths.py:9-27`) plus prefixes `/auth/login`, `/auth/callback`,
`/auth/native/authorize`, `/auth/native/token`, `/auth/native/refresh`, `/auth/password-login`, `/auth/logout`,
`/login`, `/api/auth/providers`, `/api/mcp/oauth/callback/`, static assets (`middleware.py:39-51`).
**Behind the edge only `/api/health` and `/api/status` are public** (section 16).

### 3.1 Token sign-in (D2): not offered in M1

`NAT:PLAN.md:13` ("address + password/token second") and `NAT:docs/ARCHITECTURE.md:12,26` (AuthSession
"bearer/token/session"; sign-in "password or token secondary") both mention a token. M1 shows **no token field**, for
these reasons:
- **What "token" means in Hermes.** The desktop app's remote **token mode** uses the legacy static dashboard token:
  `X-Hermes-Session-Token` on REST and `?token=` on WS. The desktop picks it only when `/api/status.auth_required` is
  false (`V:desktop/electron/connection-config.ts:12-19,1116-1117`). That token is per process unless
  `HERMES_DASHBOARD_SESSION_TOKEN` is set (`HA:hermes_cli/web_server.py:380-386`). Every gated gateway refuses it
  (`HA:hermes_cli/web_server_chat.py:264-265`), and every gateway a phone can reach is gated (section 0, ground rule 3). In loopback
  mode `/api/auth/me` accepts it and answers
  `{"user_id":"local","email":"","display_name":"Local","org_id":"","provider":"loopback","expires_at":0}`
  (`HA:hermes_cli/dashboard_auth/routes.py:536-550`), but a phone never reaches loopback mode.
- **What a gated gateway accepts as a "token".** It accepts a provider-verified **session access token**:
  `Authorization: Bearer` on REST (`middleware.py:169-182`) or `?token=` on WS (`web_server_chat.py:322-365`, mode D).
  That is mode B's bearer without its refresh token. Nothing could renew a pasted token: a `basic` access token lasts
  12 h by default (`HA:plugins/dashboard_auth/basic/__init__.py:30-32`), and a Nous one is short-lived (21.1). Users
  also have no supported way to obtain one.
- The web client never offered a token field, and no fixture serves one (19.7).

This is the recommended default, and the owner may overrule it. If a token field is ever added, choose the mode from
`/api/status.auth_required` as the desktop does. When it is false, send `X-Hermes-Session-Token: <token>` on REST and
`?token=<token>` on `/api/ws` (no ticket). When it is true, refuse with "This gateway signs in with Nous or a password."
The PLAN/ARCHITECTURE wording is drift (20.8).

---

## 4. Public probe `GET /api/status` and the adaptive sign-in form

### 4.1 Probe request (before any sign-in)

`HermesNative.probe({url})` (`HermesNative.swift:2042-2056`):
- `url` must pass `validated()` and `admitTransport`; otherwise answer `{known:false}` (no request sent).
- `GET <url>/api/status` — **no query string** (the edge treats any query as non-public, section 16), header
  `Accept: application/json`, cookies disabled, timeout 5 s, body ceiling 1 MiB, fresh ephemeral session.
- Answer `{known:false}` on any transport error, non-200, non-JSON, or missing `auth_providers` array.
- Else `{known:true, nous: providers∋"nous" && auth_flows∋"native_pkce", password: providers∋"basic"}`
  (`HermesNousSignIn.swift:67-72`). Note `password` tests the provider **name** `basic`, not `supports_password`.

Renderer side (`W:src/connection-ways.ts:16-73`, `W:src/main.ts:212-223`):
- Ask 600 ms after typing stops, and immediately on `change`/blur; skip text that doesn't look like `host.tld`
  (`/^(https?:\/\/)?[^\s/]+\.[^\s/]+/i`). Apply an answer only if the field still holds exactly the asked text.
- Mapping: unknown → `both`; nous && !password → `nous`; password && !nous → `password`; else `both`.
- `nous`: hide username/password, show only "Sign in with Nous" as primary; Return in the address field signs in.
  `password`: hide the Nous button. `both`: show everything.
- A saved Nous account whose gateway doesn't answer stays on `nous` (`main.ts:212,220`).

### 4.2 `/api/status` shape

Real Hermes (`HA:hermes_cli/web_routers/status.py:466-566`, auth part `status.py:367-389`): public, read-only. Fields
the app uses: `auth_required` (bool), `auth_providers` (all registered providers incl. token-only ones such as
`drain-secret`), `auth_flows` (`["cookie"]` when gated, plus `"native_pkce"` when any interactive session provider
exists), `version`, `release_date` (`"YYYY.M.D"`), `can_update_hermes`. Others present: `config_version`,
`latest_config_version`, `gateway_running`, `gateway_state`, `gateway_platforms`, `active_agents`, `gateway_busy`,
`gateway_drainable`, `restart_drain_timeout`, `active_sessions`, `nous_session_valid`, `install_id` (optional),
`shared_profile_warning`, `components`, `overall`, `profiles`, `parked_profiles`, `gateway_mode`,
`multiplex_standalone_reason`; host paths only when not gated.

Fixture example (`W:scripts/nous-fixture-gateway.py:193-195`):
```json
{"version":"1.0.0","release_date":"2026.10.01","desktop_contract":8,"auth_required":true,
 "auth_providers":["basic","nous"],"auth_flows":["cookie","native_pkce"]}
```
Same gateway seen through the edge (rewritten, `W:gateway-edge/hermes-hq-edge.mjs:355-366`):
```json
{"version":"1.0.0","release_date":"2026.10.01","auth_required":true,"auth_providers":["nous"],"auth_flows":["native_pkce"], "…":"…"}
```

### 4.3 Post-sign-in compatibility check (typed sign-ins only, never on launch restore)

After a successful typed sign-in the renderer reads `GET /api/status` through the authenticated `request`
(`timeoutMs:4000`, `W:src/main.ts:462`) and waits at most 4 s (`W:src/connection-startup.ts:24-25,271-278`).
Outdated iff `release_date` parses as `YYYY.M.D` and is **earlier** than `CONTRACT_RELEASES[8] = "2026.9.21"`
(`W:src/gateway-compat.ts:11-42`). `version` strings are not ordered and must not be compared. Outdated → "Update Hermes
on Your Gateway" screen with Check Again / Continue Anyway; the sign-in is already saved (`W:src/main.ts:389-412`).
Unreadable / slow status never blocks sign-in.

---

## 5. Mode A: password sign-in (cookie session)

### 5.1 Typed sign-in sequence (`HermesNative.swift:2005-2030,1900-2004`)

Per-request timeout 15 s for a typed sign-in (`HermesNative.swift:1910-1921`). Steps:

1. Reset the transport (new ephemeral `URLSession`, empty cookie jar, cancel everything) (`HermesNative.swift:1474-1497`).
2. `GET /api/auth/providers` (no auto-refresh on 401) → choose the **first** provider with `supports_password: true`
   (`HermesNative.swift:1672-1685`).
   - 404 → `GET /api/status`; if it has a string `version` → `gateway-outdated`, else `not-hermes`.
   - None with a password → `no-password`.
   ```json
   {"providers":[{"name":"basic","display_name":"Username & Password","supports_password":true},
                 {"name":"nous","display_name":"Nous Research","supports_password":false}]}
   ```
   (`HA:hermes_cli/dashboard_auth/routes.py:203-212`; 503 `{"detail":"no auth providers registered"}` when none.)
3. `POST /auth/password-login`, `Content-Type: application/json`:
   ```json
   {"provider":"basic","username":"fleet","password":"…"}
   ```
   200 → `{"ok":true,"next":"/"}` plus `Set-Cookie` for `hermes_session_at` (Max-Age = access-token TTL),
   `hermes_session_rt` (Max-Age 30 days) and `hermes_session_provider`; names are `__Host-<name>` over HTTPS at `/`,
   `__Secure-<name>` under a proxy prefix, bare over HTTP; all HttpOnly, SameSite=Lax, `Secure` on HTTPS
   (`HA:hermes_cli/dashboard_auth/cookies.py:1-13,47-107`, `routes.py:486-493`).
   Errors: 401 `{"detail":"Invalid credentials"}`, 404 `{"detail":"Unknown provider"}`, 429
   `{"detail":"Too many login attempts. Try again shortly."}`, 503 provider unreachable, 400 provider mismatch
   (`routes.py:447-485`).
4. `GET /api/auth/me` to verify the session (`HermesNative.swift:1954-1955`). **Verified (D4) means HTTP 2xx and a
   body that parses as a JSON object. Nothing inside the object is read.**
   - The web client discards the answer (`_ = try await json(…)`, `HermesNative.swift:1931,1938,1955`). Its `json()`
     requires only a JSON object (`:1891-1896`), and the renderer cannot call `/api/auth/*` at all (8.1).
   - Decode every field as optional. Never require `user_id`, and never compare it with the typed username; the web
     client does neither. For `basic`, `user_id` is the configured username anyway
     (`HA:plugins/dashboard_auth/basic/__init__.py:139-147`). A Nous account takes its identity from the token
     answer's `user_id` (6.1 step 10), not from this call.
   - A non-JSON 2xx gives `not-hermes` (`:1877-1882`). A 2xx that is JSON but not an object (array, scalar, or empty
     body: `http()` maps empty to `NSNull`, `:1854`) fails "Invalid gateway response", which counts as `gateway-error`
     and not as a refusal. 401/403 is a refusal (5.3). A 3xx is not followed, so it becomes `Gateway HTTP 3xx`.
   - The only consumer that needs the fields is the edge, on the server side. It reads `provider`, `user_id` and
     `expires_at` (`hermes-hq-edge.mjs:303-310`).

   | Server | 200 body |
   | --- | --- |
   | Real Hermes, gated | `{"user_id":"fleet","email":"","display_name":"fleet","org_id":"","provider":"basic","expires_at":1791234567}` (`HA:hermes_cli/dashboard_auth/routes.py:551-553`) |
   | Real Hermes, loopback (unreachable from a phone) | `{"user_id":"local","email":"","display_name":"Local","org_id":"","provider":"loopback","expires_at":0}` (`routes.py:543-550`) |
   | `W:scripts/native-startup/fake-gateway.py`, and build47 / action-voice / the Nous fixture's cookie path, which reuse it | `{"username":"fleet"}` (`fake-gateway.py:188-189`) |
   | `W:scripts/gateway-replay.py` | `{"authenticated":true,"user":{"username":"…","provider":"replay"}}` (`gateway-replay.py:883-886`) |
   | `W:scripts/nous-fixture-gateway.py`, bearer | `{"user_id":"user_owner_fixture","email":"","display_name":"","org_id":"","provider":"nous","expires_at":1791234567}` (`nous-fixture-gateway.py:231-233`) |

   Treat the other auth answers just as leniently, because the fixtures shorten them too. A `/api/auth/providers` entry
   may lack `display_name` (`fake-gateway.py:187`); only `name` and `supports_password` are read
   (`HermesNative.swift:1672-1685`). The password-login 200 body is `{"ok":true,"next":"/"}` from Hermes and
   `{"ok":true}` from the fake (`fake-gateway.py:257`). It is ignored, but it must be a JSON object (`:1951`, `json()`).
   For `ws-ticket`, see 9.1.
5. Save `{url, username, provider, cookies = jar cookies for url}`; password dropped (`HermesNative.swift:1958-1968`).
   Then push/shortcut registration and an **early ws-ticket** (9.3).

The `basic` provider: access token default TTL 12 h (`HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS`), refresh token
30 days, both stateless HMAC-signed, no server revocation and **no reuse detection**
(`HA:plugins/dashboard_auth/basic/__init__.py:30-33,159-185`). Without `HERMES_DASHBOARD_BASIC_AUTH_SECRET` the signing
key is per process, so a gateway restart ends every password session (`basic/__init__.py:193-213`).

### 5.2 Launch restore (`HermesNative.swift:2104-2172,1922-1940`)

- Keychain read off the main thread; no item → signed out (sign-in form).
- Whole restore budget **7 s** from plugin load, however many requests (`HermesNative.swift:1910-1921`); out of time →
  timeout → offline screen.
- Install saved cookies into the fresh jar, then exactly one `GET /api/auth/me` (no auto-refresh). The gateway
  renews an expired access token from the refresh cookie on that same request and answers with new `Set-Cookie`
  (`HA:hermes_cli/dashboard_auth/middleware.py:184-209`).
- Refused (401/403) → clear the jar; there is no password, so throw `session-ended`; Keychain keeps only
  `{url, username, provider}` (prefilled form) (`HermesNative.swift:1939-1944,1987-1995`).
- Network failure / 5xx → `{connected:false, restoreFailed:true, reason:<code>}` → offline screen with auto-retry
  (section 13.6). Credentials stay.

### 5.3 Keeping the cookie session alive

- The **server** refreshes: any request whose access cookie expired but whose refresh cookie is valid is served
  and answered with rotated cookies (`middleware.py:184-209,135-147`); the iOS cookie jar accepts them
  (`httpCookieAcceptPolicy = .always`, `HermesNative.swift:1467-1473`).
- Persist on every response that carries `Set-Cookie` (REST, downloads, WS upgrade, ws-ticket), only for a verified,
  not-rejected sign-in and only when the cookie set changed by name+value; written on the vault queue
  (`HermesNative.swift:1695-1707,1836-1842,3082-3092`). Also persist on background and WebContent reset.
- A 401 mid-session runs `refreshCookies()` (single flight per sign-in, `HermesNative.swift:1721-1763`):
  1. `GET /api/auth/me` (no auto-refresh). 200 → session fine (only that route refused); persist; retry the request once.
  2. Network error → rethrow (session may be fine; nothing forgotten).
  3. Refused → if the Keychain copy of the cookies differs from the jar, install it and ask `/api/auth/me` once more.
  4. Still refused → **session ended**: mark the sign-in rejected (every later refresh fails fast), remove cookies (and
     Nous tokens) from Keychain keeping url+username, emit lifecycle `auth-rejected`.
- A refused 401 is retried **at most once** per request (`HermesNative.swift:1630-1636`); `/api/auth/providers` and the
  restore's `/api/auth/me` are never retried.

---

## 6. Mode B: Sign in with Nous (RFC 8252 native app flow)

Server design (`HA:hermes_cli/dashboard_auth/native_flow.py:1-13`): the gateway is the authorization server to the
app and the OAuth client to Nous Portal. The app never talks to Portal's token endpoint.

### 6.1 Sequence (`HermesNative.swift:2060-2097`, `HermesNousSignIn.swift:99-145`)

1. `admitTransport(url)`; fresh cookieless ephemeral client; per-request timeout 15 s.
2. `GET <url>/api/status`. Must be 200 JSON containing an `auth_required` key, else `not-hermes`. Must satisfy
   `offersNous` (4.1), else `nous-unavailable`.
3. PKCE: verifier = base64url(64 random bytes) = 86 chars; challenge = base64url(SHA-256(ASCII verifier)), no padding;
   `state` = base64url(32 random bytes) (`HermesNousSignIn.swift:30-45`). New pair per attempt.
4. Start the loopback relay (6.3) → `redirect_uri = "http://127.0.0.1:<port>/callback"`; begin waiting **before**
   opening the browser (`HermesNousSignIn.swift:112-116`).
5. Open `ASWebAuthenticationSession` at
   ```
   <url>/auth/native/authorize?provider=nous&code_challenge=<C>&code_challenge_method=S256
                               &redirect_uri=http://127.0.0.1:53124/callback&state=<S>
   ```
   Query built with `URLComponents`; any literal `+` re-encoded as `%2B` (`HermesNousSignIn.swift:58-66`).
   `prefersEphemeralWebBrowserSession = false` (share Safari's Portal cookies); callback `.customScheme("hermes")`
   which never fires — the relay closes the sheet (`HermesNousSignIn.swift:121-132`). HQ Native uses
   `.customScheme("hermeshq-native")` instead (D5, 2.3).
6. Gateway validates (`HA:hermes_cli/dashboard_auth/routes.py:242-335`): method must be `S256`, challenge non-empty,
   `redirect_uri` must be `http://127.0.0.1[:port]/…` or `http://[::1][:port]/…` in canonical form (no `localhost`,
   userinfo, fragment, backslash, control chars). Registers a pending entry (TTL 600 s, max 8 pending per client IP,
   256 global, `native_flow.py:28-33,101-119`; over cap → 503), sets PKCE cookie `hermes_session_pkce` (10 min,
   SameSite=None on HTTPS), 302 to Portal. With `provider` omitted and several providers, the gateway renders a
   chooser — always send `provider=nous`.
7. Portal sign-in → Portal 302 to `<gateway>/auth/callback?code&state` → gateway verifies its PKCE cookie/state,
   mints a one-time code (TTL 120 s) bound to the app's challenge, 302 to
   `http://127.0.0.1:<port>/callback?code=<gw_code>&state=<S>` (`routes.py:119-133,338-379`). No session cookie on
   this path.
8. Relay receives the GET, answers an HTML "Signed in" page, settles with `{code, error, iss, state}` and closes the
   sheet. Compare `state` in **constant time**; missing/mismatched → `nous-failed` (`HermesNousSignIn.swift:46-52,133-143`).
   User closed the sheet → `nous-cancelled` (empty message in the UI). Relay timeout → `timeout`.
9. `POST <url>/auth/native/token`, JSON `{"code":"<gw_code>","code_verifier":"<V>"}` (`HermesNative.swift:2083`).
   200 (`routes.py:111-116,574-586`):
   ```json
   {"access_token":"eyJ…","refresh_token":"…","token_type":"Bearer","expires_at":1791234567,
    "provider":"nous","user_id":"user_abc"}
   ```
   The code is consumed on every path (no oracle); any failure is 400 `{"detail":"Invalid or expired authorization code."}`
   (`HA:hermes_cli/dashboard_auth/native_flow.py:145-158`).
10. Parse with `NousGatewayProtocol.answer` (`HermesNousSignIn.swift:73-90`):
    - 200 with non-empty `access_token`, `refresh_token`, `user_id` (string or number) and `provider == "nous"` →
      tokens (`expires_at` epoch seconds, default 0). 200 with anything else → treated as unavailable(502).
    - 400/401 → refused(`error` field or `session_expired`); 403 → refused(`error` or `not_authorized`).
    - other → unavailable(status).
    Mapping to UI codes: refused `not_authorized` → `not-owner` ("This Nous account isn't allowed…"); other refusal →
    `nous-failed`; unavailable 429 → `rate-limited`, else `gateway-error` (`HermesNative.swift:2084-2096`).
11. Account = `{url, username:"nous:"+user_id, nous: tokens, label}` → `authenticate()`: renew if within 60 s of expiry,
    then `GET /api/auth/me` with the bearer; save; early ws-ticket (`HermesNative.swift:1925-1932,1958-1976`).

### 6.2 Request decoration for Nous accounts

Every gateway request (REST, uploads, downloads, media ranges, push registration, ws-ticket) gets
`Authorization: Bearer <accessToken>` and `httpShouldHandleCookies = false`, applied at send time so a retry after a
refresh carries the new token (`HermesNative.swift:1611-1619`). WebSocket upgrades carry **no** bearer: the ticket is
the only WS credential (`HermesNative.swift:2577`). The gated middleware verifies the bearer against the provider stack
with no cookie read/write (`HA:hermes_cli/dashboard_auth/middleware.py:169-182`); an invalid bearer gets 401
`{"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session","login_url":"/login"}`
(`middleware.py:72-87`); an IdP outage gets 503 `{"detail":"Auth provider 'nous' unreachable"}`
(`HA:hermes_cli/dashboard_auth/request_utils.py:52-54`).

### 6.3 `DispatchOAuthRelay` (loopback listener) — exact behaviour (`W:ios/App/App/HermesPlatformExtras.swift:950-1085`)

- `listen(closeBrowser:lifetime:)`: `NWListener` over TCP with `requiredLocalEndpoint = 127.0.0.1:any` (IPv4 loopback
  only, OS-chosen port). Waits for `.ready`, returns `(id, "http://127.0.0.1:<port>/callback")`. At most **8**
  listeners alive at once ("Too many sign-ins are already waiting"). Each listener self-closes after `lifetime`
  (Nous: 900 s; MCP default 1200 s) with error `timeout waiting for OAuth callback`.
- `wait(id, timeout)`: resolves with the result (immediately if already settled); timeout clamped to 1…900 s
  (Nous uses 600 s). Unknown id → `{error:"listener not found"}`.
- Connections: at most **4** accepted per sign-in; each must deliver its request head (`\r\n\r\n`, ≤ 8 KiB) within
  **10 s** or is cancelled. Every connection (including `/favicon.ico` or a preconnect) is answered
  `HTTP/1.1 200 OK`, `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store`, `Connection: close`, body
  a small "✓ Signed in — Return to Hermes HQ to finish connecting." page.
- Only a request whose path is exactly `/callback` and whose query contains `code` or `error` settles:
  `{code, error, iss, state}` from the query. Settling cancels the listener and all its connections, wakes waiters,
  and (only when `code` or `state` present) calls `closeBrowser`.
- `cancel(id)` settles with `{error:"cancelled"}`; `cancelAll` on WebContent reset (renderer-specific; native app: on
  scene teardown).
- Same relay serves **MCP server OAuth** for the renderer via `oauthListen` → `{id, redirectUri}`, `oauthWait({id,
  timeoutMs=300000})` → `{code, error, iss, state}` (nulls for absent), `oauthCancel({id})` → `{ok:true}`
  (`HermesPlatformExtras.swift:182-200`, `W:src/bridge/fe-platform.ts:24-26,199-201`); the browser there is
  `SFSafariViewController`, dismissed by the relay (`HermesPlatformExtras.swift:241-246`). The redirect is then
  relayed to the gateway's `mcp.servers.oauth.callback` RPC (out of scope here).

### 6.4 Nous session facts

- Access token: Portal RS256 JWT, verified by Hermes against Portal JWKS with `aud` = `agent:{instance_id}`
  (`HA:plugins/dashboard_auth/nous/__init__.py:1-8,45-53,100-107`). Lifetime: **UNKNOWN** (21.1).
- Refresh token: 24 h, **rotates on every use, with reuse detection**: presenting a spent refresh token revokes the
  whole session (`nous/__init__.py:6-8`, `W:docs/remote-access.md:23-24`).
- No revocation endpoint: sign-out is local; an issued refresh token dies within 24 h
  (`nous/__init__.py:67-70`, `HermesNative.swift:2200-2201`).
- Hermes does not restrict **which** Nous account signs in; only the edge's `owners` list does
  (`W:docs/remote-access.md:27-34`).

---

## 7. Nous token renewal and refresh-token rules

### 7.1 When

Web client (ref238):
- Before sending any request: if `expiresAt − now < 60 s` (`NousTokens.needsRenewal`, `HermesNousSignIn.swift:25-27`),
  renew first (`HermesNative.swift:1624-1625`). Only first attempts check this (`retry == true`), and
  `/api/auth/providers` never does (`:1853`). The same check gates reads of other saved accounts (`:2417`) and the
  Share extension (`W:ios/App/Shared/DispatchShareKit.swift:241-242,468`).
- After a 401 on an `/api/` request: renew, then retry the request **once** (`HermesNative.swift:1630-1636`).
- On restore: renew first if near expiry, inside the 7 s restore budget (`HermesNative.swift:1708-1720,1929`).

**What the web rule does with short tokens.** The 60 s margin ignores the token's lifetime, so a token that lives
≤ 60 s already "needs renewal" the moment it arrives. The Nous fixture defaults to `--access-ttl 30`
(`W:scripts/nous-fixture-gateway.py:30,335,338`), and the edge e2e test uses 3 s
(`W:gateway-edge/test/protocol_e2e.py:83`). Under such a TTL, **every request that does not join an in-flight renewal
first runs a refresh rotation**. The single flight (`refreshing`, `HermesNative.swift:1727,1749-1750`) only merges
concurrent askers and clears once it completes. A missing `expires_at` decodes as 0 and has the same effect
(`HermesNousSignIn.swift:84`). Nothing says this was intended. The code comment gives the margin's purpose as making
sure "a request never goes out with one about to expire" (`HermesNousSignIn.swift:25`).

The costs are one Portal rotation and one Keychain write per request. Behind the edge it gets worse: more than 20
renewals a minute from one address get 429 (`hermes-hq-edge.mjs:91,154-157,390-394`), and the request that wanted the
renewal then fails with `Gateway HTTP 429` without ever being sent (`HermesNative.swift:1625,1793`). Real Portal's
lifetime is UNKNOWN (21.1). At 120 s or more, none of this happens.

**HQ Native (D6).** It uses the same three triggers, with a margin that takes the lifetime into account:
```
obtainedAt = phone clock (s since 1970) when this pair arrived (sign-in or renewal); saved in Keychain with the pair
lifetime   = expiresAt − obtainedAt
renewAt    = obtainedAt + max(lifetime − 60, lifetime / 2)
proactive  = lifetime > 0 && now ≥ renewAt
```
- A lifetime of 120 s or more behaves exactly like the web client: renew in the last 60 s.
- A lifetime under 120 s renews after half of it. A 30 s TTL then costs at most one rotation per 15 s of activity
  (≤ 4 a minute), well under the edge's 20.
- If `expires_at` is missing or 0, or the lifetime is ≤ 0 (the phone clock runs ahead of Portal's by more than the
  TTL), there is no proactive renewal. The 401 → renew → retry-once path does the work, once per expiry rather than
  once per request.
- If `obtainedAt` is missing (a pair not minted by this app), fall back to the web rule `expiresAt − now < 60`.
- Restore uses the same `proactive` test inside its 7 s budget.
- Hermes accepts an access token up to 60 s past `exp` (JWT leeway `DEFAULT_TOKEN_LEEWAY_SECONDS = 60`,
  `HA:plugins/dashboard_auth/_shared.py:28-34`, passed to Nous verification at
  `HA:plugins/dashboard_auth/nous/__init__.py:48-57,101`). A request sent just before `renewAt` with a token that
  lapses in flight still passes, and the retry path covers anything else.
- After each sign-in and renewal, log the measured `lifetime` (a number, never a token) so a device run can settle
  UNKNOWN 21.1.
- Rules 7.3 (single flight, successor map, persist before use, compare-and-swap) are unchanged.

**Renewal alongside (HQ Native, build 296).** `proactive` above is the point where a request *waits* for the renewal.
Earlier, from half the lifetime, the renewal runs *alongside* the request instead (`NousTokens.renewsAlongside`,
`GatewayAuth.renewIfDue`):
```
alongside  = obtainedAt known && expiresAt > 0 && lifetime > 0 && now ≥ obtainedAt + lifetime / 2 && !proactive
```
- The request goes out at once with the current token (it has more than 60 s left by the phone's clock, plus Hermes's
  60 s leeway past `exp`, so ~120 s against clock skew and time in flight); the single-flight renewal starts unawaited,
  and later requests carry the rotated pair. Phone log evidence (builds 291–294): a renewal before the ws-ticket
  cost 1.6–3.2 s on returns through the edge.
- The margin stays D6's (last 60 s, half the lifetime under 120 s). It is a speed choice, not a safety one: a token
  that lapses anyway gets a 401, which renews and retries once as before. Under a 240 s lifetime the two points meet
  (or, under 120 s, coincide), so short-TTL fixtures behave exactly as before.
- Race: a renewal alongside rotates the refresh token while a request is in flight with the old access token. Portal
  rotates only the refresh token; Hermes verifies an access token statelessly (signature, `aud`, `exp` + 60 s leeway,
  `HA:plugins/dashboard_auth/_shared.py:320-327`, `nous/__init__.py:97-101`), and the edge only asks Hermes's
  `/api/auth/me` about it, so the old access token stays valid until it expires. A 401 that still comes back joins the renewal in flight (rule 1) rather than start
  another; one whose bearer was already replaced just retries with the new one.
- Outcomes are rule 7's: a refusal ends the session (even though the request it rode beside succeeded); unavailable,
  429 or a network failure keep the session and the current token, and no renewal alongside starts again for 30 s
  (a failing renewal is not retried on every request; the edge allows 20 a minute).
- The Share extension, other saved accounts (7.4) and restore keep the blocking rule only: an extension can be killed
  mid-rotation (rule 9).
- Not done: renewing in the background grace on the way out. A rotation cut off by suspension is rule 9's replay hazard,
  and a token renewed at half its lifetime already leaves the app with at least half of it.
- The phone log notes each renewal alongside (`auth renewed alongside: <ms> ms, lifetime <s> s`, or `… failed (<code>)`);
  the connect line's "(auth refreshed)" now means the ticket waited for a refresh.

### 7.2 Request

`POST <url>/auth/native/refresh`, `Content-Type: application/json`, cookies off, timeout min(15 s, restore budget left)
(`HermesNative.swift:1798-1811`):
```json
{"refresh_token":"<current refresh token>","provider":"nous"}
```
Answers (`HA:hermes_cli/dashboard_auth/routes.py:589-617`): 200 = same payload as 6.1 step 9 (both tokens new);
401 `{"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}`;
503 `{"detail":"Auth provider 'nous' unreachable"}`; 400 `refresh_token required`. Through the edge: 403
`{"error":"not_authorized",…}` for a non-owner; 429 `{"error":"rate_limited"}` + `Retry-After`.
Outcome mapping: 200 with a **different** `user_id` → refused (never adopt another account's session).

### 7.3 Rules the client must obey (replay = session revoked)

1. **Single flight per account.** One renewal in flight per account key; concurrent askers await it
   (`NousRenewals`, `HermesNative.swift:999-1036`). Shared by the signed-in connection and reads of other saved accounts.
2. **Successor map.** Remember `spent refresh token → rotated pair` for the app's lifetime; any caller holding an older
   pair is handed the newest (chain up to 16) instead of sending the spent token (`HermesNative.swift:1010-1014,1019-1020`).
3. **Persist before use.** The rotated pair replaces the old one in memory and Keychain the moment it lands, before the
   retried request goes out (`HermesNative.swift:1022-1026,1812-1817`).
4. **Compare-and-swap in Keychain.** Write the rotated pair only into an account that still holds the exact pair the
   renewal started from (`SavedAccounts.renewNous`, `HermesNative.swift:88-95,230-236`); an account that meanwhile got a
   newer sign-in keeps it.
5. **Keychain locked?** Keep the rotation in an `unsaved` map and retry the write on the next background transition
   (`HermesNative.swift:1008-1009,1025,1033-1035,1402`).
6. **Another process may have rotated.** Before renewing, re-read Keychain: if it holds a different, non-spent pair for
   the same `userId`, adopt it (it was rotated by the Share extension) and skip the renewal unless it is also near
   expiry (`HermesNative.swift:1771-1780`; the extension does the same, `W:ios/App/Shared/DispatchShareKit.swift:297-301,600-630`).
7. **Outcomes.** tokens → continue. refused (400/401/403) → session ends: Keychain keeps url+username only, lifecycle
   `auth-rejected`, every later refresh fails fast (`HermesNative.swift:1752-1762,1785-1795`). unavailable (503, 5xx,
   429) or network failure → keep the session, fail this request with `Gateway HTTP <status>` or the transport error.
8. **Server-side coalescing** (defence in depth, not a licence to replay): the gateway single-flights refreshes per
   provider and SHA-256(refresh token), caching a successful rotation for **30 s** and a rejection for **5 s**
   (`HA:hermes_cli/dashboard_auth/refresh_singleflight.py:25-30,54-83`). A duplicate within 30 s gets the same rotated
   pair; after that a replay reaches Portal and revokes the family.
9. **Known hazard:** killed after Portal rotated but before the answer arrived → next launch replays the old token →
   revoked → sign in again (`W:docs/remote-access.md:239-241`). Unavoidable; do not try to "repair" by retrying.

### 7.4 Other saved accounts (not current)

Reads for the gateway switcher (`accountSessions`) or removals use a throwaway ephemeral session with that account's own
cookies or bearer, 8 s timeouts, never the current account's jar or sockets. A Nous account renews through the same
single flight and writes back via rule 4 (`HermesNative.swift:2297-2359,2387-2426`). `accountSessions` reads only
`GET /api/sessions/<id>[?profile=<p>]` for ≤ 40 ids matching `^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$` and returns
`{signedIn, reachable?, expired?, sessions:[{id,last_active?,message_count?,unread?}]}`; 401/403 → `expired:true`.

---

## 8. Authenticated REST

### 8.1 What the renderer may ask for (`HermesNative.swift:2427-2487`, `W:src/bridge/shim.ts:35-44,84-123`)

- Path must start with `/api/`, must not start with `/api/auth/` (native owns those), no `.`/`..` segments after
  percent-decoding, no `\`. Native-only calls: `/api/auth/*`, `/auth/*`.
- Profile scoping: when the caller names a profile and the path has no `profile` query, append `?profile=<p>`
  (`shim.ts:40-43`). The renderer's "All profiles" reads send `?profile=all` themselves.
- Bodies: JSON (`body`, `.fragmentsAllowed`), raw base64 (`bodyBase64` + `contentType`), or a single-file multipart
  `upload {filename, contentType, base64}` → field `file` (`HermesNative.swift:2446-2465`).

### 8.2 Wire conventions (`HermesNative.swift:1843-1874,1467-1473,1456-1461`)

| Aspect | Value |
| --- | --- |
| Session | `URLSessionConfiguration.ephemeral`, `timeoutIntervalForRequest = 30`, `urlCache = nil`, cookies accepted always (password accounts). Main-queue delegate. |
| Pools | **Control** pool for `/auth/*` and `/api/auth/*` (sign-in, `/api/auth/me`, refresh, ws-ticket, logout): copy of the session config with `waitsForConnectivity = true`, `timeoutIntervalForResource = 15 s`. **Bulk** pool for everything else (fails fast). Same cookie jar. (`HermesTransportShared.swift:92-102`) |
| Headers | `Content-Type: <contentType>` (default `application/json`, sent even on GET); Nous: `Authorization: Bearer …`. No `Origin`, no browser headers. `Accept: application/json` only on probe/sign-in calls. |
| Timeout | Caller `timeoutMs` (default 30000) clamped to 1…120 s. |
| Redirects | **Never followed** (delegate returns nil) — no credentials to a redirected host (`HermesNative.swift:500-502,3109-3111`). A 302 is delivered as the response. |
| Body ceilings | 1 MiB for `/api/auth/*` and ws-ticket, 32 MiB otherwise; error bodies (4xx/5xx) capped at 1 MiB; over the cap → `response-too-large` (`HermesTransportShared.swift:32-37`, `HermesNative.swift:476-490,1554-1556`). |
| JSON | Body must be JSON (UTF-8, BOM refused for the text path); otherwise `not-hermes` (`HermesNative.swift:1877-1882`). |
| Generation fence | Every await re-checks the sign-in generation; an answer that arrives after a switch/sign-out is dropped ("Connection changed"). |

### 8.3 Status handling (`HermesNative.swift:1621-1671`)

| Status | Behaviour |
| --- | --- |
| 2xx | Return data. |
| 401 (path contains `/api/`, first attempt) | Refresh (5.3 / 7) then retry once. |
| 401/403 after that, or on non-retryable paths | Throw `auth-rejected` ("Authentication expired or rejected. Sign in again."). The UI shows "Sign in again"; the Keychain is cleaned on the reload's restore (5.2). |
| 400 with body containing `Invalid Host header` | `host-rejected`: Hermes only answers its bound host or `HERMES_DASHBOARD_PUBLIC_URL`'s host (`HA:hermes_cli/web_server.py:602-646`). |
| 429 | `rate-limited`. **Never auto-retry** a sign-in on it. |
| other 4xx/5xx | Generic JSON API calls get `{status, body}` back for the caller's own handling (`allowHTTPError`); native control calls throw `Gateway HTTP <n>`. |
| `/api/audio/voice-live/session` 502/503 | Specific copy (not this spec). |

Renderer-side error text for non-2xx (`W:src/bridge/gateway-error.ts:5-58`): edge bodies `{"error":"gateway_unavailable"}`
→ "Hermes isn't answering right now…" (code `unavailable`), `{"error":"rate_limited"}` → "Your gateway is busy…";
502/503/504/52x with no useful detail → plain words; otherwise `Gateway HTTP <n>: <detail>` with secrets redacted and
≤ 240 chars. A 2xx whose body isn't JSON → "This address answered, but not as Hermes. If you're on public Wi-Fi…"
(`W:src/bridge/gateway-body.ts:3-24`).

Transport error codes (`HermesTransportShared.swift:233-262`): `NSURLErrorDomain` −1001 → `timeout`; −1022 →
`insecure-url`; −1200…−1206 → `tls`; −1000/−1002 → `invalid-url`; −1003/−1004/−1005/−1006/−1009/−1018/−1020 →
`unreachable`; anything else → `gateway-error`.

### 8.4 Reachability tracker (renderer, applies to GET/HEAD only) (`W:src/connection-reachability.ts:1-148`)

- Down statuses: 502, 503, 504, 520–526, 530. Down transport code: `unreachable`.
- Gateway counts as **down** when a read meets a down status/`unreachable` while the socket is closed, or a read times
  out while the socket is closed, or **2** gateway-socket dials in a row fail before opening.
- Counts as **stalled** after **3** consecutive read timeouts while the socket is open.
- While down/stalled, reads fail immediately (offline/stalled error) except one probe read per window: 2 s doubling to
  30 s. Any answered read or the socket opening ends it; returning to the app makes the next read a probe at once.
- Writes are never held.

---

## 9. WebSocket tickets

### 9.1 Endpoint

`POST /api/auth/ws-ticket`, body `{}` (`Content-Type: application/json`), authenticated like any request (cookie jar or
bearer) (`HermesNative.swift:2550`). 200:
```json
{"ticket":"q3V0b0x…43 base64url chars…","ttl_seconds":30}
```
(`HA:hermes_cli/dashboard_auth/routes.py:556-564`). 401 when there is no session. The client reads only `ticket`, which
must be a string (`HermesNative.swift:2566`), and decodes the TTL as optional. Fixtures differ:
`{"ticket":"…","ttl_seconds":30}` (`nous-fixture-gateway.py:304`), `{"ticket":"…"}` (`fake-gateway.py:268`),
`{"ticket":"…","expires_in":30}` (`gateway-replay.py:895`). The ticket is 32 random bytes,
single use, bound to `{user_id, provider}`, expires 30 s after minting counted in whole seconds
(`HA:hermes_cli/dashboard_auth/ws_tickets.py:20-61`). Consumed (popped) on the first upgrade that presents it, whether
or not the upgrade later succeeds.

### 9.2 Rules

- **One ticket per socket.** Mint immediately before dialing; never cache, never reuse after a failed dial.
- **One `/api/ws` ticket request in flight** at a time; later dials wait their turn in FIFO order
  (`HermesNative.swift:1071-1084,2530-2531`). A dial abandoned while waiting (renderer closed it, socket epoch changed,
  account changed) creates no socket even if its ticket arrives (`HermesNative.swift:2532-2533,2567-2569,3061-3063`).
- Ticket timeout grows only after timeouts in a row: 8 s, then 15 s, then 20 s; reset on any success or non-timeout
  failure (`HermesTransportShared.swift:271-275`, `HermesNative.swift:2552-2556`).
- On a ticket failure for `/api/ws`, tell the UI why: lifecycle `{state:"socket-failed", reason}` with `timeout`, the
  native coded reason (`tailscale-off`, `auth-rejected`, `rate-limited`, …) or a transport code
  (`HermesNative.swift:2553-2565`). A 401/403 on the ticket (after one refresh) is `auth-rejected` → the app shows
  "Sign in again" instead of reconnecting forever (`W:src/bridge/socket.ts:86-91`).
- While backgrounded past the grace period (13.7) no socket may open: fail with code `paused` and lifecycle
  `{state:"socket-failed", reason:"paused"}` (no "unreachable" notice) (`HermesNative.swift:2501-2505`).

### 9.3 Early ticket (latency optimisation, build 205)

Right after a verified sign-in and on every foreground that closed the sockets, request one `/api/ws` ticket in the
background (`HermesNative.swift:1085-1119,1975,1433`). The next `/api/ws` dial may use it only if it belongs to the same
sign-in generation and socket epoch and was **asked < 20 s ago** (`HermesTransportShared.swift:103-105`); otherwise it is
discarded and a fresh one minted. An unused ticket simply expires server-side.

### 9.4 Other sockets

| Path | Credential |
| --- | --- |
| `/api/ws` | `ticket` (serialised, early ticket allowed) |
| `/api/audio/*` (e.g. `/api/audio/speak-stream?profile=…`) | its own fresh `ticket` (not serialised) |
| `/api/plugins/(hermes-hq\|dispatch)-browser/activity`, `…/sessions/<24 hex>/watch` (query keys only `profile`, `owner`, `session`, unique, ≤ 2048 bytes) | its own fresh `ticket` (`HermesTransportShared.swift:10-20`) |
| `/api/display/ws?[profile=…&]display_ticket=<t>` | **only** the single-use display ticket minted by the `display.observe` RPC; never a gateway ticket (`HermesNative.swift:2525-2528,2591-2598`). Hermes refuses a display ticket on `/api/ws` (`HA:hermes_cli/web_server_chat.py:303-312`). |

---

## 10. `/api/ws` URL and handshake

### 10.1 URL

```
<ws|wss>://<host>[:port][<base path>]/api/ws?profile=<urlencoded profile>&ticket=<ticket>
```
- `wss` iff the saved base URL is `https` (`HermesNative.swift:2521-2522`).
- The renderer builds `…/api/ws?profile=<owner>` where owner = the requested profile or the launch's default profile
  (`W:src/bridge/shim.ts:71-76`); native appends `ticket` last (`HermesNative.swift:2571-2573`).
- Renderer URLs carrying `ticket`, `token` or userinfo are refused ("Native authentication only",
  `socket.ts:233-238`). A renderer URL must be on the base host, same scheme family, under `base path + /api/`.
- `profile` is **ignored by the server** on `/api/ws` (`HA:hermes_cli/web_routers/chat_ws.py:701-722`,
  `HA:tui_gateway/ws.py:295`): one socket serves every profile; RPCs name their profile in params. The client still
  reads it as the default profile for attachment staging (`HermesNative.swift:2810-2814`). Keep sending it for parity.
- **One `/api/ws` socket per signed-in account** (the renderer's registry reuses the primary socket for all profiles:
  `shim.ts:73-75`, `sharedRemote/sharedPrimary`).

### 10.2 Handshake

- `URLSessionWebSocketTask` from the account's session (so a password account's handshake also carries its cookies;
  a renewal on the upgrade response is persisted, `HermesNative.swift:3082-3092`). No `Authorization`, no `Origin`, no
  subprotocol. `maximumMessageSize = 64 MiB` (`HermesTransportShared.swift:44-46`); server accepts up to 384 MiB per
  frame (`HA:hermes_cli/web_server.py:447-449,1268`).
- Server pre-accept gates, in order (`HA:hermes_cli/web_routers/chat_ws.py:161-172`): embedded chat disabled → close
  4403; credential invalid (missing/expired/used ticket, display ticket) → close 4401; Host/Origin mismatch → close 4403.
  These are `ws.close()` **before accept**, which ASGI servers turn into an **HTTP 403** handshake response — the client
  never sees 4401/4403 as close codes. Host must match the bound host or a declared public host
  (`HA:hermes_cli/web_server_chat.py:166-194`); an absent `Origin` is fine; a non-http(s) Origin is trusted.
- Edge pre-relay refusals are plain HTTP responses: 503 (gate off, `Retry-After: 5`), 404 (path not allowed), 401
  (`token`/`internal` present, or no ticket) (`W:gateway-edge/hermes-hq-edge.mjs:434-449`).
- After `101`: the **first frame** is `gateway.ready` (11.4). Nothing else should be sent before the socket is open;
  requests may be sent immediately after open (the server reads ahead up to 256 frames, `HA:tui_gateway/ws.py:70-75`).

### 10.3 Close codes seen by the client

| Code | Origin | Meaning / client action |
| --- | --- | --- |
| 1000 | client `wsClose` without code on `/api/ws` | normal close (`HermesNative.swift:3076`) |
| 1001 | native closing for background/path change/page reset/terminate | sent as `goingAway`; reconnect later (`HermesNative.swift:1347-1360`) |
| 1006 | synthesised | link died, ping failure, handshake failed (`socket.ts:390-395`, `HermesNative.swift:1319-1330`) |
| 1009 | native | inbound frame > 64 MiB (`POSIX 40`); notify once "Message too large", do not loop (`HermesTransportShared.swift:47-50`, `HermesNative.swift:2661-2668`, `W:src/native-runtime.ts:74`) |
| 1011 | server | send deadline exceeded (peer not draining 30 s) or fanout overflow → reconnect + replay (`HA:tui_gateway/ws.py:197-247`) |
| 4000 | display bridge | Bot Screen control taken (not `/api/ws`) |
| server code + reason | server close frame | reason truncated to 123 chars (`HermesNative.swift:2599-2607`) |

---

## 11. JSON-RPC 2.0 over the socket

### 11.1 Framing

- Each WebSocket **text** frame carries exactly one JSON object, no trailing newline, UTF-8
  (`HA:tui_gateway/ws.py:195-216`, `HA:tui_gateway/transport.py:83-95`). Coalesced deltas still arrive as separate frames.
- Empty/whitespace frames are ignored by the server; unparseable text → `{"jsonrpc":"2.0","error":{"code":-32700,"message":"parse error"},"id":null}`
  (`ws.py:410-418`).
- Lone UTF-16 surrogates are replaced with U+FFFD server-side (`ws.py:48-59`).
- Binary frames are not used on `/api/ws` (they are on `/api/audio/speak-stream` and `/api/display/ws`).

### 11.2 Client → server requests

```json
{"jsonrpc":"2.0","id":17,"method":"session.list","params":{"limit":1}}
```
- `params` is always an object (server: non-object → -32602, `HA:tui_gateway/server.py:903-914`).
- Ids: the renderer's main client uses **incrementing integers** starting at 1 per client instance
  (`createRequestId: nextId => nextId`, `V:desktop/src/api/client.ts:31-46`); heartbeats use strings
  `"heartbeat-<n>"` (`V:shared/src/json-rpc-channel.ts:547`). Server→client request ids are `"srq-<12 hex>"`, so
  integer client ids never collide (`HA:tui_gateway/server_requests.py:9-10,67`).
- Notifications from client → server are not used.
- Per-call timeouts (client-side; server keeps working after a client timeout): default **30 s**
  (`V:desktop/src/api/client.ts:18`); boot burst reads 60 s (`client.ts:16`); `prompt.submit` **1,800 s** (its ack can
  be slow; completion arrives as events, `client.ts:19-26`); `approval.respond` 300 s
  (`V:shared/src/json-rpc-gateway.ts:41-49`); replay `session.events.since` 10 s (`json-rpc-gateway.ts:52-54`);
  liveness `ping` 5 s (`V:desktop/src/lib/gateway-liveness-policy.ts:38`). Timeout error text:
  `request timed out after <s>s: <method>` (`json-rpc-channel.ts:287-297`).
- Abort drops the pending entry immediately; cancellation on the server is a separate RPC where it matters
  (`json-rpc-channel.ts:304-314`).

### 11.3 Responses and errors

```json
{"jsonrpc":"2.0","id":17,"result":{"sessions":[…]}}
{"jsonrpc":"2.0","id":17,"error":{"code":-32601,"message":"…","data":{…}}}
```
A frame with `id` (not null) and no `method` is a response; match it to the pending map; unknown ids are ignored
(`json-rpc-channel.ts:459-487`). Error codes seen: -32700 parse, -32600 invalid request, -32602 invalid params,
-32601 method not found, -32603 internal/serialization (`HA:tui_gateway/server.py:881-914`, `ws.py:326-334`),
5032 agent still starting / build timed out (`server.py:943-947,985-987`), 4404 "session not shown" (client decline,
11.6), plus method-specific codes. Map `error.message` (fallback "Hermes RPC failed"), keep `code`/`data`
(`json-rpc-channel.ts:86-94`). Results of `session.resume`, `session.activate` and `session.events.since` may carry
`open_requests` — deliver those (11.6) **before** resolving the caller (`json-rpc-channel.ts:475-483`).

### 11.4 Server → client notifications (events)

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"<sid>","payload":{"text":"Hel"},"seq":42}}
```
- Shape: `method == "event"`, `params = {type, session_id, payload?, seq?}` (`HA:tui_gateway/server.py:700-711`).
  `seq` is a per-session monotonic counter stamped on every event (`HA:tui_gateway/event_replay.py:67-129`); absent on
  session-less frames. Session-less global broadcasts (`sessions.changed`, `skin.changed`, …) carry `session_id: ""`
  (`server.py:741-760`). `gateway.ready` is written directly and has no `session_id`.
- Dispatch by `type`; ignore unknown types. `message.delta`, `reasoning.delta`, `thinking.delta` are coalesced on a
  33 ms timer but order relative to other frames is preserved (`ws.py:76-82,123-170`).
- First frame after accept (`ws.py:362-370`):
  ```json
  {"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{
     "skin":{…},"change_events":true,"heartbeat":true,"replay_epoch":"<opaque per server process>"}}}
  ```
  Fixtures add `"desktop_contract":8` here (`W:scripts/build47-fixture-gateway.py:144`); real Hermes reports
  `desktop_contract` on session create/resume results instead (`HA:tui_gateway/methods_session.py:115,380,488,745`).
  On `gateway.ready` the web client (1) sends `client.capabilities` (11.6), (2) starts the heartbeat iff
  `payload.heartbeat === true` (12.2), and (3) adopts `replay_epoch` (13.3). **HQ Native M1 does (2) and (3) and
  skips (1)** (D1, 11.6.1). The milestone that adds approval/clarify UI adds (1).

### 11.5 "Subscribe" semantics

There is **no subscribe RPC**. An event for session S is written to the transport attached to S's live record
(`HA:tui_gateway/server.py:681-698`). A socket becomes attached by `session.create`, `session.resume` or
`session.activate` (`HA:tui_gateway/methods_session.py:492,1058,1166`); several clients can mirror one session
(fanout transport). Global broadcasts go to every live transport registered after a successful `gateway.ready`
(`HA:tui_gateway/ws.py:371-376`, `server.py:720-760`). On disconnect the server detaches/reaps the socket's sessions
(grace-windowed orphan reaper; a quick resume cancels it) (`ws.py:448-466`). Therefore after **every** reconnect the
client must re-attach each session it shows (resume/activate) and replay missed events (13.3).

### 11.6 Server → client requests (questions the agent asks the user)

```json
{"jsonrpc":"2.0","id":"srq-1a2b3c4d5e6f","method":"clarify","params":{"session_id":"<sid>", "…":"…"}}
```
Frame rule: `id` is a string, `method` is a string and not `"event"` (`json-rpc-channel.ts:61-62`;
`HA:tui_gateway/server_requests.py:82-84`). Methods: `clarify`, `setup_choose`, `approval`, `sudo`, `secret`,
`vault.unlock_prompt`, `vault.save_login`, `vault.code`, `terminal.read`, `preview.read`, `window.read`, `preview.act`,
`tour`, `display.install.sudo` (`HA:tui_gateway/contracts/server_requests.py:55-245`, `contracts/display.py:167`).
Rules the web client follows (they apply to HQ Native only from the milestone that answers requests; M1 follows 11.6.1):
- Answer exactly once with `{"jsonrpc":"2.0","id":"srq-…","result":{…}}` or `{"…","error":{"code":…,"message":…}}`.
  The client guards against a second send (`json-rpc-channel.ts:352-367`), and the server drops answers for requests
  no longer open (`HA:tui_gateway/server_requests.py:265-280`).
- No handler → answer `-32601` "no handler for server request: <method>" immediately (else the agent waits out its
  deadline, e.g. clarify 300 s). Handler crash → `-32603`. Window-owned requests not shown here → `4404` only if the
  server advertised `declines_not_shown` (`json-rpc-channel.ts:376-411`).
- Capability handshake, once per connection, right after `gateway.ready` (`json-rpc-channel.ts:489-518`; the web app
  sends it on every open, `W:src/rpc-flight.ts:174-176`):
  `{"jsonrpc":"2.0","id":2,"method":"client.capabilities","params":{"server_requests":true}}` →
  `{"server_requests":[…sorted contract names…],"declines_not_shown":true}` (`HA:tui_gateway/methods_voice.py:442-450`).
  The mark belongs to the connection and is forgotten on disconnect (`HA:tui_gateway/server.py:739-743`,
  `server_requests.py:129-141`). Its effect is decided per **session**, not per socket (11.6.1).
- Withdrawals: event `request.cancel` with payload `{id, method, reason}` (`HA:tui_gateway/server_requests.py:11-13,158`).
- Reconnect: still-open requests come back as `open_requests: [{id, method, params}]` on resume/activate/events.since
  results; deliver them as if new, tagged `replayed` (`json-rpc-channel.ts:413-426`).

Result shapes, for the later milestone (`HA:tui_gateway/contracts/server_requests.py:24-245`): `clarify` →
`{"answers":{"<qid>":"<text>"|null}}` (without `answers` it means cancel-all); `approval` →
`{"choice":"once"|"session"|"always"|"deny","all":bool?}`; `setup_choose` → `{"picked","label","said"}`; every other
method → `{"value":"<string>"}`, where `""` means skipped.

#### 11.6.1 Unanswerable requests, and the M1 rule (D1)

Gateway behaviour:
- Before writing a request for session S, the gateway asks whether S is answerable. **It is not answerable only when
  every live WebSocket client attached to S never advertised.** A session with no attached client counts as answerable;
  the request waits for a resume (`HA:tui_gateway/session_transports.py:38-47`, `server_requests.py:149-154,184-185,218-220`).
- **Not answerable:** the frame is never written, and the request settles at once as unanswered
  (`HA:tests/tui_gateway/test_protocol.py:340-356`).
- **Answerable:** the frame goes to S's transport, which fans out to **every** attached client, advertised or not
  (`HA:tui_gateway/server.py:690-697`). A phone that never advertised still receives requests when the desktop or web
  HQ app is attached to the same session.
- **The first answer settles the request for everyone.** Any `error` answer other than 4404 counts as "unanswered"
  (`server_requests.py:265-305`; client frames are routed at `HA:tui_gateway/rpc_dispatch.py:54-56`). A 4404 decline
  is only one client's vote. Once every advertising client has declined, the request resolves with a
  `{"value":"{\"success\":false,\"error\":\"No Hermes Desktop window is showing this chat…\"}"}` result
  (`server_requests.py:110-114,238-262`).

What "unanswered" gives the agent:

| Method | What the tool gets |
| --- | --- |
| `approval` | Withdrawn, not denied: "the attached client cannot answer approval requests (update the Hermes app)" (`HA:tui_gateway/server.py:833-842`, `HA:tools/approval.py:176-190`) |
| `clarify` | `{"answers":{},"outcome":"undelivered"}` (`server.py:1418-1427`) |
| `sudo`, `secret`, `vault.unlock_prompt`, `vault.save_login`, `vault.code`, `terminal.read`, `preview.read`, `window.read`, `preview.act` | `""` (skipped) (`server.py:1398-1404`) |
| `setup_choose` | `None` (`HA:tui_gateway/agent_callbacks.py:141-143`) |
| `tour` | "No Hermes Desktop window answered the tour request…", and tour is marked unavailable for the session (`server.py:1436-1467`) |

A 4404 sent for `approval` would resolve as **deny**, because `server.py:844` reads `choice` from a result that has
none. 4404 belongs only to the five window-owned methods
(`V:desktop/src/app/session/hooks/use-message-stream/gateway-event/server-requests.ts:79`).

**M1 rule. HQ Native M1 has no approval or clarify UI (`NAT:PLAN.md:9-10`).**
1. **Do not send `client.capabilities`.** The gateway then treats HQ Native as a client that cannot answer. When it is
   the only client on a session, every question fails fast as the table shows and the turn keeps going. Nothing waits
   out a deadline.
2. **Never answer** a server→client request frame (string `id`, string `method` ≠ `"event"`, `json-rpc-channel.ts:61-62`)
   or an `open_requests` entry, not even with an error. Such a frame reaches HQ Native only when another attached
   client has advertised. An `-32601` from HQ Native would settle that question before the owner can answer it in the
   other app.
3. `request.cancel` events need no reply. While a request it has seen is open, the UI may show a passive "Answer this
   on your computer or in Hermes HQ" line. A `request.cancel` with the same `id` clears it, and so does the next event
   for that session. The second trigger matters because an answer given in another app emits no event
   (`resolve_response` settles silently, `server_requests.py:265-305`). That line is UI, not transport.
4. Rejected alternatives:
   - Advertise and answer `-32601`: the same result when HQ Native is alone, but it cancels questions the desktop or
     web app is showing.
   - Advertise and stay silent: the agent waits the full deadline (clarify defaults to 300 s, `server.py:1408-1415`)
     with nothing on screen.
   - Advertise and send 4404: approvals become denials.
5. The milestone that adds approval/clarify UI sends `client.capabilities {"server_requests":true}` after every
   `gateway.ready` and answers each request exactly once, following the rules above.

Edge case: a sessionless request (`display.install.sudo`) always counts as answerable, so it is written to the calling
socket (`session_transports.py:44-47` with no session). Only Bot Screen's Install button triggers it, and M1 has no Bot
Screen.

---

## 12. Keepalive and liveness (four independent layers)

### 12.1 Server WebSocket ping

Non-loopback binds: uvicorn pings every **20 s** and drops the socket if no pong in **20 s** (configurable
`dashboard.ws_ping_interval/_timeout`) (`HA:hermes_cli/web_server.py:1222-1251`). `URLSessionWebSocketTask` answers
pings automatically (assumed, UNKNOWN 21.7). The server's ping runs on the agent's event loop and can stall; native
comments observe a half-open socket held 40–60 s by the server keepalive (`HermesNative.swift:1325-1328`).

### 12.2 App-level heartbeat `gateway.ping` (always on once ready)

Started only when `gateway.ready.payload.heartbeat === true` (`json-rpc-gateway.ts:422-427`):
every **15 s** send `{"jsonrpc":"2.0","id":"heartbeat-<n>","method":"gateway.ping","params":{}}`; the server answers on
its read loop even while handlers block: `{"jsonrpc":"2.0","result":{"ok":true},"id":"heartbeat-<n>"}`
(`HA:tui_gateway/ws.py:420-424`). Liveness = **any inbound frame** (`heartbeatLiveness: 'any-inbound'`,
`json-rpc-gateway.ts:177-180`). If nothing arrived for **45 s**, invalidate the socket
("WebSocket heartbeat acknowledgement timed out") and let reconnect run. Keep at most 8 outstanding ping ids
(`json-rpc-channel.ts:148-156,526-567`).

### 12.3 Streaming-turn liveness ping (native WebSocket ping frames)

While at least one turn is streaming on the socket (`W:src/bridge/socket.ts:146-193,352-389`):
- A turn starts/refreshes on events `message.start|delta|interim`, `thinking.delta`, `reasoning.delta`,
  `reasoning.available`, `tool.*`; ends on `message.complete`, `session.reclaimed`, `error` (session from the first
  non-empty `session_id` in the frame head, `session.reclaimed` names it in the payload). `subagent.*` only refreshes a
  turn already watched. A turn silent for **180 s** is dropped from the watch.
- Every 1 s: if no inbound frame for **5 s**, send a WebSocket ping (`sendPing`) with **7 s** pong timeout. A frame that
  arrives meanwhile counts as an answer. **3** unanswered pings in a row → fail the socket (close 1006) → reconnect.
  Only the last allowed miss drops the native task (`wsPing({id,timeoutMs,drop})` → `{answered}` or error
  `socket-dead`, `HermesNative.swift:1302-1318`).

### 12.4 Wake probe RPC `ping`

On returning to the app / network back (13.2), if the socket still reports open, send
`{"jsonrpc":"2.0","id":<n>,"method":"ping","params":{}}` with a 5 s timeout → `{"pong":true}`
(`HA:tui_gateway/methods_voice.py:453-457`, `V:desktop/src/app/gateway/hooks/use-gateway-boot.ts:613-682`).
- `-32601` = old backend, healthy.
- Failure while any session is working: defer and re-probe after **3 s**; close only after **2** consecutive failures.
  Failure with nothing working: close now (`V:desktop/src/lib/gateway-liveness-policy.ts:36-90`).

---

## 13. Reconnect, replay, back-off

### 13.1 Reconnect loop (renderer as patched by gates)

- Trigger: socket state `closed`/`error` after a completed boot (`use-gateway-boot.ts:1050-1090`).
- Delay: full-jitter exponential, `random() * min(15 s, 300 ms × 2^attempt)` (`V:shared/src/reconnect-backoff.ts:27-58`,
  `use-gateway-boot.ts:589-611`). The ladder resets only when the previous socket stayed open **≥ 5 s**
  (`reconnect-backoff.ts:28-38`, `use-gateway-boot.ts:1073-1075`) — an accept-then-die socket keeps backing off.
- Attempt: (the desktop's "revalidate" second-socket probe is **removed** on iOS, `W:build/startup-reconnect-gates.ts:1-14`)
  get descriptor → mint fresh ticket + dial (connect timeout **15 s**, `json-rpc-gateway.ts:55-58,316-340`) → after open:
  keep session bindings if `replay_epoch` unchanged, else drop them (`W:build/plaid-resync-gates.ts:20-58`) → reconcile
  busy flags → refresh config → one shared sessions-list refresh per reconnect (`W:build/reconnect-burst-gates.ts:21-26`,
  `W:src/reconnect-refresh.ts`). Each awaited step bounded by **20 s** (`V:desktop/src/lib/with-timeout.ts:20`).
- A socket that closes during the handshake rejects at once with `WebSocket closed during handshake: code <n>`
  (`json-rpc-gateway.ts:285-310`); 'open' settles the connect before state handlers run (`W:build/fix161-data-gates.ts:49-75`).
- After **300 s** of failing: one non-blocking warning with "Reconnect now" (`use-gateway-boot.ts:122,562-585`).
- An auth refusal (`auth-rejected`) stops the loop and shows "Sign in again" (`socket.ts:86-91`, `W:src/native-runtime.ts:61-72`).

### 13.2 Wake signals

- App becomes visible → `reconnectNow()`: reset back-off; if closed, attempt now; if open, run the wake probe (12.4)
  (`use-gateway-boot.ts:613-682,1290-1301`).
- Network back (`online` / native `network reachable`) → forced reconnect, at most one forced per **15 s**
  (`use-gateway-boot.ts:136,1125-1162`).
- Focus events that are momentary (tab switches) are ignored (`W:build/r2-network-gates.ts:86-124`).
- Before the first successful boot, dial failures retry forever on iOS (base 2 s, cap 15 s, full jitter), and wake
  signals dial immediately (`W:build/startup-reconnect-gates.ts:39-94`, `use-gateway-boot.ts:146-149,1569-1593`).

### 13.3 Lossless replay (`V:shared/src/json-rpc-gateway.ts:119-702` + `W:build/shared-replay-performance.ts`)

- Keep `lastSeenSeq[session_id]` = highest `seq` seen. Phone keeps at most **8** cursors (least recently active dropped;
  32 on larger layouts) (`W:src/replay-budget.ts:1-19`, `shared-replay-performance.ts:34`).
- On every open, before publishing history reads: for each cursor (most recent first, **2 at a time**), send
  `session.events.since {"session_id":"<sid>","last_seen":41}` (10 s timeout). Result
  (`HA:tui_gateway/methods_session.py:2334-2348`):
  ```json
  {"events":[{"type":"message.delta","session_id":"<sid>","payload":{"text":"lo"},"seq":42}],
   "latest_seq":57,"truncated":false,"count":16,"epoch":"<replay_epoch>","open_requests":[]}
  ```
- While a session's replay is in flight, **park** its live seq'd frames; after the replay, flush the parked frames.
  Dispatch both replayed and parked frames only if `seq > lastSeenSeq` (dedupe), tagged `replayed`. Sessions without a
  cursor are not held. A history read for a held session waits on that session's barrier.
- Hold budget: more than **2048** parked frames or **4 MiB** parked → invalidate the socket and replay again from the
  untouched watermark (`W:src/replay-budget.ts:3-4`, `shared-replay-performance.ts:30`).
- `truncated: true` → after flushing, delete that session's cursor and raise a local
  `session.replay.truncated` so the open chat re-reads its stored transcript (REST) (`shared-replay-performance.ts:100-114`,
  `W:build/replay-truncated-gates.ts`).
- Epoch: adopt `gateway.ready.replay_epoch`; if a later `gateway.ready` or `events.since.epoch` differs from the adopted
  one, the server restarted: clear all cursors, release parked frames, and treat REST as authoritative
  (`json-rpc-gateway.ts:142-149,611-644`). Server ring: 512 events / 4 MiB per session, 64 sessions, 64 MiB per process
  (`HA:tui_gateway/event_replay.py:8-35`).
- Replay failures are swallowed (best effort).

### 13.4 Native dial discipline (`W:src/bridge/socket.ts:58-144,254-273`)

- After a gateway dial fails before opening, the next dial waits until **1 s** has passed since that failure
  (`MIN_REDIAL_MS`), whoever triggers it.
- **[net-ready] Native exception (build 295): one quick redial while the network settles.** A dial that began within
  **3 s** of the app becoming active, the connection starting or a network path change, and failed `unreachable`
  (URLError -1003/-1004/-1005/-1006/-1009/-1018/-1020) within **1 s**, is dialed again after **200 ms** instead of the
  1 s floor, without climbing the back-off or changing the state. Once per such moment: a second failure, and every
  other failure (timeout, 5xx, 429 `Retry-After`, refusals, a slow failure), keeps the 1 s floor and the ladder. Why:
  opened from a notification, the first ticket request fails "unreachable" in 45–90 ms (the path already reads
  satisfied; the radio is not carrying yet) and the floor cost ~0.9 s before the dial that works. Waiting for the path
  instead does not help: it reads satisfied already, and its changes are acted on only after they settle for 2 s
  (§13.7). (`HermesKit/Net/ConnectionSupport.swift` `NetSettle`, tests `Tests/ConnectFastTests.swift` "net-ready".)
- Never start a second `/api/ws` open while one is in flight. (The web shim also lets a newer dial adopt an open the
  renderer abandoned, for up to 10 s; a native rebuild that owns both sides simply never abandons an in-flight dial.)

### 13.5 Banner / UI states (`W:src/connection-startup.ts:123-207`)

A drop shows nothing for **4 s** (header says "Reconnecting…"); then a banner that only names a cause once an attempt
has actually failed: `tailscale-off`, `timeout` ("slow to answer"), `rate-limited` ("busy"), `unreachable`/none
("Gateway unreachable. Check your network or VPN…"), network down. `paused` (background) says nothing.

### 13.6 Offline screen (restore failed before the app booted) (`W:src/main.ts:285-388`)

Automatic retries after **3, 6, 12, 24, 30, 30, …** seconds (countdown shown), plus immediately on foreground, network
reachable, or `online`; "Try Again" retries now. Reason-specific copy for `tailscale-off`, `timeout`, `tls`,
`gateway-outdated`, `rate-limited`, `host-rejected`, `not-hermes`, `keychain-*`. Refusals (`auth-rejected`,
`no-password`, `signed-out`, `session-ended`) go to the prefilled sign-in form instead (`connection-startup.ts:84-95,302-318`).
While not ready, cached reads trigger at most one restore per **1.5 s**; writes fail immediately
(`W:src/startup-gateway.ts:42-55`).

### 13.7 App lifecycle and network path (native) (`HermesNative.swift:1198-1271,1395-1437`, `HermesTransportShared.swift:51-91`)

- **Background:** persist session; retry unsaved Nous rotations; begin a background task; after **20 s** grace close all
  sockets with 1001 and end the task once their close frames are written or after **1 s** (strict timer). No grace
  granted → close now. While closed in the background, no socket may open (`paused`).
- **Foreground:** back within the grace with sockets open → keep them (liveness ping proves them). Otherwise close any
  leftovers, ask an early ticket, emit `{state:"foreground", reconnect:true}`.
- **willTerminate:** close sockets (1001).
- **Path changes** (`NWPathMonitor`): signature = satisfied + set of used interface types; act after it stays put
  **2 s**. `lost` (now down) → close all sockets, emit `network reachable:false`. `replaced` (no interface in common, e.g.
  Wi-Fi→cellular without VPN) → close all, emit `reachable:true` (redial now). `verify` (some interface kept, e.g. a
  VPN `utun`) → ping every socket with **10 s** timeout, drop the dead ones (sending 1001), emit
  `{reachable:true, verified:<all answered>}`. `restored` → emit `reachable:true`.

---

## 14. 401 / 403 / session-end matrix

| Where | 401 | 403 | Result |
| --- | --- | --- | --- |
| REST `/api/*` (first time) | refresh (5.3/7) then retry once | `auth-rejected` thrown | caller error; UI "Sign in again" |
| REST after retry | `auth-rejected` | `auth-rejected` | same |
| `/api/auth/me` during restore | session refused → `session-ended` (password) / `auth-rejected` (Nous) | same | prefilled sign-in form; Keychain keeps url+username only |
| `refreshCookies` / Nous refresh refused | — | — | **session ended**: Keychain tokens/cookies removed, lifecycle `auth-rejected`, all later refreshes fail fast |
| `POST /api/auth/ws-ticket` | refresh, retry once, then `auth-rejected` | `auth-rejected` | socket open fails with code `auth-rejected` → UI "Sign in again", reconnect loop stops |
| WS upgrade refused (HTTP 403 from Hermes, 401 from edge) | — | — | handshake error → close 1006 → normal back-off (each retry mints a new ticket); not treated as sign-out |
| Edge 403 `not_authorized` on token/refresh | — | refused → `not-owner` / session ended | sign in with an owner account |
| 503 / network | — | — | **keep** the session; offline/reconnect handling |

Sources: `HermesNative.swift:1621-1671,1726-1796,1977-2003,2536-2566`; `W:src/bridge/socket.ts:86-91`;
`W:src/main.ts:474-490`; `W:src/native-runtime.ts:60-72`.

---

## 15. Rate limits and the login-burst rule

| Limit | Value | Source |
| --- | --- | --- |
| Hermes password login | 10 attempts / 60 s sliding window per **peer IP** (all clients behind one proxy/edge share it) → 429 | `HA:hermes_cli/dashboard_auth/routes.py:383-430,457-459` |
| Hermes native authorize | ≤ 8 pending per client IP, ≤ 256 entries total, pending TTL 600 s → 503 | `HA:hermes_cli/dashboard_auth/native_flow.py:28-33,101-119` |
| Edge `/auth/native/authorize` | 12 per IP per 10 min → 429 + `Retry-After` | `hermes-hq-edge.mjs:88,377-383` |
| Edge token routes | 20 per IP per route per min (own bucket, never blocked by others) | `hermes-hq-edge.mjs:91,154-157,390-394` |
| Edge requests without bearer / with an expired JWT bearer | 60 per IP per min → 429 `Retry-After: 30` | `hermes-hq-edge.mjs:66-69,90,398-413` |
| Edge bad/stranger bearers | 30 per IP per min → 429 `Retry-After: 30`; a bearer already verified as an owner's is never throttled | `hermes-hq-edge.mjs:89,150-162,412-425` |

Client rules:
- **Never retry a login (password or Nous) automatically**, never in a loop, never per concurrent request. One user
  tap = at most one `/auth/password-login`. The 2026-09-28 incident: a tool re-logging in per concurrent request made
  10 logins + 369 rate-limited attempts in 36 s from one IP (`~/.claude/…/memory/replay-gateway.md`, recorded lesson).
- Share **one** session per account across all requests; refresh in a single flight (section 7).
- Treat 429 as "busy, try later" (`rate-limited` copy); honour `Retry-After` where the app retries on its own (socket
  back-off, offline screen).

---

## 16. `hermes-hq-edge` (public Funnel door) — exact rules (`W:gateway-edge/hermes-hq-edge.mjs`)

Listens on loopback only (default `127.0.0.1:9139`), forwards to Hermes's local `http://` address
(`hermes-hq-edge.mjs:71-93,539-549`). Config: `{"listen":{"host","port"},"upstream":"http://…","owners":["<nous user_id>",…]}`
(`W:gateway-edge/config.example.json`). Decisions in order (`hermes-hq-edge.mjs:368-432`):

1. Upstream gate check: `GET /api/status` must be 200 with `auth_required: true` (re-checked every 60 s and whenever
   not yet true) else every request → 503 `{"error":"gateway_auth_gate_off"}` `Retry-After: 5` (`:138-149,373,464-466`).
2. `GET /api/status` with **no query** → Hermes's status rewritten to `auth_providers: ["nous"]` (if registered) and
   `auth_flows: ["native_pkce"]` (or both empty) (`:353-366,374`).
3. `GET /api/health|/api/status` with no query → proxied (`:375`).
4. `GET /auth/native/authorize`: `provider` other than `nous` → 403 `{"error":"provider_not_allowed"}`; rate limit; forces
   `provider=nous`; only the PKCE cookie is passed back (`:377-383`).
5. `GET /auth/callback`: only the PKCE cookie forwarded in, only PKCE cookies out (`:385-388`).
6. `POST /auth/native/token|refresh`: own rate bucket; body ≤ 16 KiB JSON; refresh body forced to `provider:"nous"`;
   non-200 from Hermes → same status with `{error, detail?}` reduced (`session_expired` default for 401, else `refused`);
   200 whose `provider` isn't `nous` or `user_id` isn't an owner → **403** `{"error":"not_authorized","detail":"This Nous
   account isn't allowed on this gateway."}` and tokens dropped; else tokens pass and the new access token is
   pre-verified (`:324-351,390-394`).
7. Anything else needs `Authorization: Bearer <token>`: none → 401 `{"error":"unauthenticated"}` (or 429). Paths under
   `/auth/` or `/login` with a bearer → 401. Bearer checked via Hermes `GET /api/auth/me` (cached 60 s, never past the
   token's `exp`); `provider` must be `nous` and `user_id` an owner → else 403 `{"error":"not_authorized"}`; Hermes
   502/503 → 503 `{"error":"auth_unavailable"}` `Retry-After: 5`; invalid → 401 `{"error":"unauthenticated"}`
   (`:296-313,396-427`). Then proxied with the bearer, `Host` rewritten to the upstream host, client cookies /
   `Authorization` / `Forwarded` / `X-Forwarded-*` / `X-Real-IP` / hop-by-hop dropped; **`Set-Cookie` stripped** from
   answers (`:31-35,184-205`).
8. WebSocket upgrades: path must match `/api/ws`, `/api/display/ws`, `/api/audio/<[A-Za-z0-9_\-/]+>`, or the browser
   plugin's `activity` / `sessions/<24 hex>/watch` → else 404; `token` or `internal` in the query → 401; needs `ticket`,
   `display_ticket`, or `ticket` in `Sec-WebSocket-Protocol` → else 401; then raw TCP relay; Hermes consumes or refuses
   the ticket (`:29-30,434-462`).
- Upstream errors: refused/reset → 503 `{"error":"gateway_unavailable"}` `Retry-After: 5`; other → 502
  `{"error":"upstream_unreachable"}`; no answer start within **60 s** for reads (GET/HEAD/OPTIONS without
  `Accept: text/event-stream`) or **300 s** otherwise → 504 `{"error":"upstream_timeout"}`; a read hitting a stale
  keep-alive connection is retried once (`:38-42,55-65,225-273`).
- gzip for JSON/text ≥ 1 KiB when `Accept-Encoding` allows (URLSession decodes transparently) (`:47-54,474-497`).
- Logs never contain query strings, headers, bodies or tokens.

---

## 17. Sign-out, switch, add, remove

- **Sign out** (`HermesNative.swift:2182-2223`, renderer `W:src/bridge/platform.ts:205-222`): bump generation (cancels
  in-flight work), then within **6 s** total (`HermesTransportShared.swift:106-108`): push unregister, and for password
  accounts `POST /auth/logout` body `{}` (5 s). Nous accounts send no logout (no revocation; the edge refuses
  `/auth/logout`). Then wipe: reset transport, delete current Keychain account (next most-recent becomes current),
  local caches. Answer `{revoked, next?:{url,username}}`; with `next` the app signs in to that account.
  Quirk: Hermes answers `/auth/logout` with **302** to `/login` (`HA:hermes_cli/dashboard_auth/routes.py:496-512`) and
  redirects are not followed, so `revoked` is false against real Hermes (fixtures answer 200). The cookies are cleared
  locally regardless; for `basic` revocation is a no-op anyway.
- **Switch** (`HermesNative.swift:2240-2265`): persist the current session, push unregister (≤ 6 s), reset transport,
  clear notifications/shortcuts, make the other account current; the app reloads and restores it. The old account's
  session stays in Keychain.
- **Remove another account** (`HermesNative.swift:2269-2283`): push removal with that account's own credentials, password
  accounts also `POST /auth/logout` (status 200 counts as revoked), then delete from Keychain. The current account
  cannot be removed this way (`account-current`).
- **Add gateway**: the sign-in form with Cancel back to the current account; a successful sign-in saves the new account
  beside the others and makes it current (`W:src/connection-startup.ts:369-379`).

---

## 18. Error code vocabulary (stable codes the UI maps to copy)

`auth-rejected`, `no-password`, `signed-out`, `session-ended`, `insecure-url`, `tailscale-ip`, `invalid-url`,
`missing-fields`, `unreachable`, `timeout`, `tls`, `not-hermes`, `rate-limited`, `keychain-locked`,
`keychain-unreadable`, `keychain-unavailable`, `gateway-error`, `tailscale-off`, `gateway-outdated`, `host-rejected`,
Nous: `nous-unavailable`, `nous-cancelled`, `nous-failed`, `not-owner`; socket-only: `paused`, `socket-dead`,
`response-too-large`, `account-missing`, `account-current`, `keychain-clear-failed`.
Copy: `W:src/connection-startup.ts:35-71`, `W:src/connection-ways.ts:5-13`, `W:src/main.ts:330-343`.
Rejections (go to sign-in, never retried offline): `auth-rejected`, `no-password`, `signed-out`, `session-ended`
(`HermesNative.swift:338-342`, `connection-startup.ts:84`). `tailscale-ip` is renderer-derived from `insecure-url` on a
raw `100.x` http address (`connection-startup.ts:400-402`); with today's ATS settings it should not occur.

---

## 19. Native implementation notes (Swift)

Maps onto `HermesKit/Net/*` in `docs/ARCHITECTURE.md`. Swift 6, main-actor default isolation, iOS 26+.

### 19.1 URLSession setup (REST.swift / AuthSession.swift)
- One `URLSessionConfiguration.ephemeral` per signed-in account: `urlCache = nil`, `requestCachePolicy` default,
  `httpCookieAcceptPolicy = .always`, `httpCookieStorage` = the session's own jar (never `HTTPCookieStorage.shared`),
  `timeoutIntervalForRequest = 30`. A delegate that returns `nil` from `willPerformHTTPRedirection` on every session.
- A second configuration for control calls (`/auth/*`, `/api/auth/*`): copy + `waitsForConnectivity = true`,
  `timeoutIntervalForResource = 15`. Share the same `HTTPCookieStorage` instance.
- Invalidate both sessions (`invalidateAndCancel`) on sign-out/switch; guard against creating tasks on an invalidated
  session (that raises) with a lock + flag (`HermesNative.swift:448-475`).
- Stream large bodies with a byte ceiling enforced on `didReceive data` and on `expectedContentLength`.
- Per-request "generation" token: drop any answer that completes after the account changed.
- Nous: set `Authorization` and `httpShouldHandleCookies = false` at send time on every request (and retries).
- Restore cookies from Keychain into the jar with `HTTPCookie(properties:)` incl. `HttpOnly` and `sameSitePolicy`
  (`HermesNative.swift:21-28`); persist `jar.cookies(for: baseURL)` whenever a response has `Set-Cookie` and the set
  (name+value) changed. Do not persist from an unverified or rejected session.

### 19.2 RPCSocket.swift (URLSessionWebSocketTask)
- Create with `session.webSocketTask(with: URLRequest(url: wssURL))`; set `maximumMessageSize = 64 << 20`; `resume()`.
  Open is signalled by `urlSession(_:webSocketTask:didOpenWithProtocol:)`.
- Receive loop: call `receive` again after each message. For large text frames (≥ 16 KiB), keep receiving unless the
  parse/apply backlog exceeds ~4 MiB of pending text (`HermesTransportShared.swift:86-91`); parse JSON off the main actor.
- Failure: if `closeCode != .invalid` report that code and `closeReason` (≤ 123 chars); if the error is POSIX 40
  (message too big) report 1009 and cancel with `.messageTooBig`; otherwise report 1006 and
  `cancel(with: .goingAway)`.
- Handshake rejection: inspect `task.response as? HTTPURLResponse` (`statusCode` 401/403/404/503) to tell "ticket/auth
  refused" from "network" (the web shim does not; recommended, verify on device — UNKNOWN 21.4).
- Ping: `sendPing { error in }` with your own timeout (`HermesNative.swift:1291-1301`).
- Close: `cancel(with: .normalClosure)` for a user-driven close of `/api/ws`; `.goingAway` (1001) for background/path
  changes; Bot Screen sockets: plain `cancel()` (no code) unless handing the lease back with 1000/1001.
- Ticket: `POST /api/auth/ws-ticket` immediately before each dial, serialised for `/api/ws` (an `actor` or async
  queue), timeout ladder 8/15/20 s; early ticket ≤ 20 s old; append `URLQueryItem(name:"ticket")` last.
- JSON-RPC: integer ids; pending map keyed by id with per-call timeout and cancellation; heartbeat task (15 s / 45 s,
  any-inbound); replay engine (13.3) with per-session barriers; events out as an `AsyncStream`.
  **M1:** no `client.capabilities`. Server→client request frames and `open_requests` are recognised (string `id` +
  string `method` ≠ `"event"`) but never answered; at most they surface as a passive signal to the UI (11.6.1). Later
  milestones add the capability call and server-request dispatch with exactly-once answers and the -32601/-32603
  fallbacks.
- Background: `UIApplication.beginBackgroundTask`, a strict `DispatchSourceTimer` for the 20 s grace (main-queue
  `asyncAfter` was coalesced late in the background, `HermesNative.swift:1363-1365`), then close and end the task after
  the close frames flush (watch `didCompleteWithError` / `didCloseWith`, ≤ 1 s).
- `NWPathMonitor` on a private queue; coalesce updates 2 s; implement `pathChange` exactly as 13.7.

### 19.3 NousSignIn.swift (ASWebAuthenticationSession + loopback)
- PKCE: `SecRandomCopyBytes` 64 bytes → base64url (no `=`); challenge `SHA256` (CryptoKit) → base64url; state 32 bytes.
- Loopback listener: `NWListener(using: .tcp)` with `parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)`;
  start on a serial queue; read `listener.port` at `.ready`. Accept ≤ 4 connections, 10 s head deadline, 8 KiB head max;
  answer every connection with the 200 HTML page and `Connection: close`; settle only on `GET /callback?…code|error…`.
  Start waiting before presenting the browser. Redirect URI `http://127.0.0.1:<port>/callback` (IPv4 literal; never
  `localhost`, which Hermes rejects).
- `ASWebAuthenticationSession(url: authorizeURL, callback: .customScheme("hermeshq-native")) { … }` (the web app passes
  `"hermes"`; HQ Native must not use or claim that scheme, D5) with
  `prefersEphemeralWebBrowserSession = false` and a `presentationContextProvider`. The callback never fires; when the
  listener settles with a code, call `session.cancel()` yourself and ignore the resulting `.canceledLogin`. A
  `.canceledLogin` **before** the listener settled = user cancelled → cancel the listener → `nous-cancelled`.
- The loopback listener works only while the app is foreground (the auth sheet keeps it foreground).
- Token exchange and every later Nous call on a cookieless ephemeral session.

### 19.4 Keychain.swift / GatewayAccount.swift
- Keep the single-item, list-of-accounts design with `current`, compare-and-swap Nous rotation, never-persisted
  password, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Serialise all Keychain read-modify-writes.
- Names and group per 2.4.1 (D3): service `ai.hermes.hqnative.gateway`, account `primary`, default access group, no
  migration from the web app. `NousTokens` gains an optional `obtainedAt` (D6, 7.1).
- `GET /api/auth/me` and the other auth answers: lenient decoding, all fields optional (D4, 5.1 step 4).
- If the Share extension is rebuilt, it must follow 7.3 rules 1–6 too (adopt-or-rotate, compare-and-swap).

### 19.5 Probe.swift
- Exactly 4.1: unauthenticated `GET /api/status` (no query), 5 s, cookieless; `{known, nous, password}`; never send
  credentials before the user commits.

### 19.6 Things the native app does NOT need from the web shim
Capacitor bridging, base64 frame transport, the orphan-adoption dance (13.4), `asText` body hand-off, renderer
`window.WebSocket` replacement, `NativePageWork` page generations, Capacitor delivery queues, Stage2Evidence debug
hooks. Keep the behaviours, not the mechanisms.

### 19.7 Test fixtures to reuse (Python, loopback only)
- `W:scripts/native-startup/fake-gateway.py`: password sign-in, `--hermes-cookies` (AT/RT cookies with server-side
  refresh), ws-ticket, a `/api/ws` answering every RPC with -32601, Range downloads; `/__fixture/expire-access`,
  `/__fixture/revoke`.
- `W:scripts/nous-fixture-gateway.py` (+ fake Portal on another port): full native PKCE flow, rotating refresh with
  family revocation on replay, ticket-only `/api/ws`, display tickets + RFB; `/__fixture/nous/ttl {"access":s}`,
  `/__fixture/nous/revoke`. Run behind `hermes-hq-edge.mjs` to test owner refusal.
- `W:scripts/build47-fixture-gateway.py`: streamed replies over `/api/ws` (`gateway.ready`, `message.start/delta/complete`).
- `W:scripts/gateway-replay.py`: record/replay of a real gateway (`docs/replay-gateway.md`); shows the canonical
  upstream sequence: `POST /api/auth/ws-ticket` → `ws://…/api/ws?profile=<p>&ticket=<t>` (`gateway-replay.py:772-789`).

---

## 20. Disagreements and drift found

1. `W:docs/remote-access.md:49` lists edge WebSocket paths `/api/ws`, `/api/audio/*`, `/api/display/ws`; the edge also
   allows the browser plugin's `activity` and `sessions/<24 hex>/watch` sockets (`hermes-hq-edge.mjs:29-30`). Code wins.
2. `W:docs/remote-access.md:236-238` says Share sends only with cookies; `W:ios/App/Shared/DispatchShareKit.swift:7-9,215-301,406-468`
   supports Nous bearer + rotation, but the app's roster gate `DispatchSignedInAccount` still requires cookies
   (`HermesNative.swift:309-313`), so Nous accounts still can't share. Partial drift.
3. `W:docs/architecture-map.md:50` describes desktop token mode (`X-Hermes-Session-Token` / `?token=`); the iOS client
   never uses it and refuses `token` in socket URLs (section 3). Gated servers reject it anyway.
4. Fixture `gateway.ready` payloads carry `desktop_contract`; real Hermes does not (11.4). Do not rely on it there.
5. `/auth/logout` returns 302 on real Hermes but 200 in fixtures; `revoked` therefore differs between fixture runs and
   reality (section 17).
6. Vendored desktop source is not what runs: e.g. `use-gateway-boot.ts:454-458` revalidation is deleted by
   `W:build/startup-reconnect-gates.ts:5-14`; boot retry is unbounded on iOS; replay is budgeted/truncation-aware. Always
   read the gates.
7. `W:docs/architecture-map.md:389` says the server also supports a stable ticket subprotocol; true
   (`web_server_chat.py:207-222`), but neither the web client nor the iOS native layer uses it.
8. `NAT:PLAN.md:13,26-27` and `NAT:docs/ARCHITECTURE.md:12,26` describe a "token" sign-in. No reachable gateway accepts
   the legacy token, and the web client never offered one, so M1 has no token field (3.1, D2). Those two documents
   should be reworded to "Nous bearer / password session" (outside this spec's folder).
9. The auth answers differ between real Hermes and the fixtures. `/api/auth/me` comes in four shapes (5.1 step 4).
   `/api/auth/providers` entries may lack `display_name`. `ws-ticket` carries `ttl_seconds` (Hermes, Nous fixture),
   `expires_in` (replay) or nothing (fake) (9.1). Strict `Codable` models that require fields would fail against
   fixtures that the web client handles fine.
10. The web client's fixed 60 s Nous renewal margin makes every request rotate when the TTL is ≤ 60 s, which is the Nous
    fixture's default (7.1). HQ Native deliberately deviates (D6).
11. The Nous fixture's `/auth/native/refresh` lacks Hermes's server-side single flight
    (`nous-fixture-gateway.py:276-295` vs `HA:hermes_cli/dashboard_auth/refresh_singleflight.py:25-30,54-83`). Against
    the fixture, a duplicate concurrent refresh revokes the family. Against real Hermes, a duplicate within 30 s gets
    the same rotated pair. So the fixture is the stricter test, which is useful, but behaviour differs.
12. 11.4 previously said the client "must" send `client.capabilities`. That is true of the web client and of any client
    that answers requests, but HQ Native M1 deliberately does not send it (D1, 11.6.1).

---

## 21. UNKNOWNs

1. Nous Portal access-token lifetime (only "short-lived"); and whether Portal accepts non-443 Funnel ports in the
   gateway's registered callback (`W:docs/remote-access.md:225`). D6 (7.1) works for any lifetime. HQ Native logs the
   measured lifetime after each sign-in and renewal, so the first device run against the owner's gateway answers the
   first half.
2. Real-device behaviour of cookie names behind Tailscale Serve/proxies (`__Host-` vs bare depends on the scheme Hermes
   sees via `X-Forwarded-Proto`/`forwarded_allow_ips`, `HA:hermes_cli/web_server.py:1255-1261`); the jar handles both, but
   untested end to end.
3. Whether the server-side `profile` query on `/api/ws` gains meaning in other Hermes versions (ignored at `d94b70f`).
4. Exact `URLSessionWebSocketTask` error/`response` when the upgrade is refused with HTTP 403/401 (expected
   `NSURLErrorBadServerResponse` with `task.response.statusCode`), unverified.
5. ~~Keychain migration from the Capacitor app~~ **Resolved (D3, 2.4.1):** no migration and no shared group. HQ Native
   keeps its own item (`ai.hermes.hqnative.gateway` / `primary`) and the owner signs in once. Sharing would let two apps
   rotate one Nous refresh-token family and risk signing out both.
6. Self-hosted OIDC (or any non-`nous` session provider) through `/auth/native/authorize`: server-supported; HQ
   Native now uses it ([own-login], section 3), unit-tested only, not yet run against a real IdP.
7. That `URLSessionWebSocketTask` auto-answers server pings (uvicorn 20 s/20 s) while the app's run loop is busy;
   assumed from platform behaviour, not measured here.
8. Behaviour of a second Nous account against the real Portal + edge (only tested with the fixture,
   `W:docs/remote-access.md:226-227`).
9. Hermes versions older than `d94b70f` / the vendored `02e4118`: field presence in `/api/status`, `ping`,
   `client.capabilities`, `session.events.since` may differ; the client already treats `-32601` on `ping` and
   `client.capabilities` as benign.
10. Whether real Nous Portal caps concurrent sessions per account. D3 has HQ Native and the web app each hold their own
    Nous session for the same account on the same gateway. The fixture mints an independent family per exchange
    (`nous-fixture-gateway.py:149-157`), but no source here states whether Portal has a limit.
11. Owner sign-off on D2 (no token field in M1). The recommendation rests on source (3.1), but `NAT:PLAN.md` still
    says "password/token".
12. Gateways older than the server-request protocol (contract < 7, `HA:tui_gateway/server.py:2288-2290`) still emit
    `<kind>.request` notifications instead of `srq-` frames. HQ Native M1 ignores both. On a typed sign-in, the
    `CONTRACT_RELEASES[8]` check (4.3) already shows such gateways as outdated.

## 22. n20 B1: signed out after updating, finished (2026-10-31)

The access-class change (table, 2.4.1) and the auto-retried unsaved rotation (`NousRenewals.retryUnsaved()`, fired on
unlock/foreground) already closed most of this. Two gaps from the original n20 brief remained open on `main` and are
closed here:

- DECISION n20-A1 (remaining half): `AccountVault.isLocked` reads the sign-in item once; `errSecInteractionNotAllowed`
  means the phone is between a restart and its first unlock (the only window `AfterFirstUnlockThisDeviceOnly` can't
  read). `GatewayAuth.refreshNous()` throws `.keychainLocked` there before sending anything — Portal's reuse
  detection would end the whole session if a spent refresh token's successor can't be written anywhere. The existing
  expiry-aware fallback in `renewIfDue()` (§7, rule unchanged) already swallows a non-rejection failure while the
  current access token is still good, so a locked phone with time left on its token is never interrupted; one with
  an expired token fails as `keychain-locked`, which is not a rejection and not a sign-out.
- DECISION n20-A2: a renewal holds iOS background time (`BackgroundTime`, via `NousRenewals.Hold`) from just before
  the post until the rotated pair is written or the attempt has failed, so a suspension can't land between Portal's
  answer and the Keychain write. `performRefresh()` also runs `retryUnsaved()` at the very top of every attempt (not
  only on an unlock/foreground notification), so a launch's first refresh never reads a pair a still-pending retry
  was about to replace.
- DECISION n20-A3: logging only, no tokens. `AppDelegate.restore()` logs the saved pair's age and what it needs
  (`NousTokens.ageNote()`, e.g. "47 s old of 900 s, fresh" / "14 min old of 900 s, renewal due"); a rotation
  `AccountVault.renewNous` could not write (another pair already saved, or none) logs why
  (`AccountVault.skippedRenewalNote`). Checks: `Tests/SignOutAfterUpdateTests.swift`.
