# Hermes Agent Upstream Parity Ledger

Baseline: `v0.23.5`
Upstream: `https://github.com/NousResearch/hermes-agent`
Last Audited: `2026-11-28`

This document tracks Hermes HQ (iOS, macOS / Mac Catalyst, and Windows) parity against `NousResearch/hermes-agent`. It is maintained together with `scripts/hermes-upstream-audit.py` and the daily T3 release-watcher task.

## Running the Upstream Audit

```bash
# Check if a newer stable SemVer release of hermes-agent is out (exits 2 if update available, 0 if up to date)
python3 scripts/hermes-upstream-audit.py --fetch --check-latest

# Audit a specific version window against Swift and Windows sources
python3 scripts/hermes-upstream-audit.py --from v0.23.4 --to v0.23.5
```

## Implemented Parity (`v0.23.0` – `v0.23.5`)

| Feature | Upstream Release | Protocol / Route / Event | Swift (iOS & Mac) | Windows (`Hermes.Core`) |
| --- | --- | --- | --- | --- |
| Permanent upstream audit + tests | HQ Tooling | `scripts/hermes-upstream-audit.py` | `scripts/hermes-upstream-audit.py`, `scripts/test_hermes_upstream_audit.py` | Cross-checks `windows/src/` |
| Profile creation timeout 300 s | `v0.23.5` | `profiles.create` | `HermesKit/Store/BotStore+Editing.swift` | `windows/src/Hermes.Core/BotPages/NewBot.cs` |
| Google / Solstice provider consolidation | `v0.23.5` | `SOLSTICE_*` under Gemini | `HermesKit/Settings/EnvKeys.swift` | N/A (config-driven) |
| Client identity & `client.activity` | `v0.23.4` | `client.capabilities {client}`, `client.activity` | `HermesKit/Net/ClientActivity.swift`, `GatewayConnection.swift`, `LiveGatewayClient.swift`, `LiveChatSession+Prompts.swift` | `windows/src/Hermes.Core/Rpc/ClientActivity.cs`, `RpcConnection.cs` (`ReportClientActivityAsync` staged in `Hermes.Core`; WinUI screen wiring pending) |
| Hermes Cloud `/api/status` Webapp move | `v0.23.5` | `GET /api/status` (`webapp_state`, `webapp_url`) | `App/Gateways/CloudDesktopWeb.swift`, `CloudGatewayFlow.swift`, `CloudGatewayPanel.swift`, `CloudAgentControls.swift`, `CloudAgentScreens.swift` | `windows/src/Hermes.Core/Gateways/GatewayCompatibility.cs` |
| Sandbox folder & website approvals + `approval.received` + Deny reason | `v0.23.4` | `approval` (`kind: access\|network`), `approval.received`, Deny `reason` | `HermesKit/Contracts+questions.swift`, `ServerRequests.swift`, `LiveChatSession+Prompts.swift`, `App/Questions/PromptRows.swift`, `ChatPromptCell.swift`, `ChatPromptsController.swift`, `NotificationHub.swift` | `windows/src/Hermes.Core/Questions/QuestionModels.cs`, `QuestionCenter.cs` |
| Plugin cards, safety-refused rows, tool output risk | `v0.23.5` | `plugin.card`, `display_kind: plugin_card\|content_refused`, `tool.output_risk` | `HermesKit/Contracts.swift`, `Hydration.swift`, `LiveChatSession.swift`, `LiveChatSession+Events.swift`, `LiveChatSession+Sync.swift`, `App/Chat/ChatRow.swift` | `windows/src/Hermes.Core/Model/Chat.cs`, `HistoryFold.cs`, `Transcript.cs` |
| Messaging live-apply, catalog installs, signature & `platforms.changed` | `v0.23.5` | `GET /api/messaging/platforms` (`available[]`), `POST /api/messaging/catalog/{name}/install`, `GET /api/messaging/platforms/signature`, `PUT` `live`, `platforms.changed` | `HermesKit/Pages/More/MessagingAPI.swift`, `App/Pages/More/Messaging/MessagingModel.swift`, `MessagingPages.swift` | `windows/src/Hermes.Core/BotPages/Messaging.cs` |
| Skills Hub updates, skill lock & `skills.changed` | `v0.23.2`–`v0.23.4` | `GET /api/skills/hub/updates`, `POST /api/skills/hub/update`, `PUT /api/skills/lock`, `skills.changed` | `HermesKit/Contracts+settings.swift`, `CapabilitiesStore.swift`, `App/Capabilities/CapabilitiesModel.swift`, `CapabilitiesViewController.swift`, `SkillPageController.swift` | `windows/src/Hermes.Core/Capabilities/CapabilityModels.cs`, `CapabilitiesApi.cs` |
| Waiting on teammates | `v0.23.3` | `bot_delivery.list` | `HermesKit/Activity/TeammateWaits.swift`, `ActivityPill.swift`, `App/Chat/Activity/TeammateWaitsBody.swift`, `ChatActivityController.swift`, `ActivityShelfView.swift` | `windows/src/Hermes.Core/Activity/TeammateWaits.cs` (staged in `Hermes.Core`; WinUI shelf wiring pending) |
| Hosted group chat controls & per-bot approval modes | `v0.23.2`–`v0.23.5` | `groups.approve`, `groups.continue`, `groups.context`, `groups.changed`, profile-scoped `config.get`/`config.set` `approvals.mode` | `HermesKit/Groups/GroupModels.swift`, `HostedRooms.swift`, `GroupStore.swift`, `Contracts+groups.swift`, `GroupRoomSession.swift`, `App/Groups/GroupRoomChrome.swift`, `GroupInfoSheet.swift` | `windows/src/Hermes.Core/Groups/HostedRoomsApi.cs` (staged in `Hermes.Core`; WinUI group-chrome wiring pending) |

## Intentionally Out of Scope (Desktop / Electron / Local-Only)

- Electron local daemon/bootstrap lifecycle (`desktop.*`, `free_tier.challenge` hidden Chromium auth window, local Python/uv installer).
- Local-machine-only filesystem / peer invite orchestration (`groups.peer.invite` / `groups.peer.register` / `groups.peer.revoke` — read-only display of peer members is already supported).
- Webapp embedded-frame preview routes (`preview.read` / `preview.act` — declined via `4404` when `declines_not_shown` is supported).
