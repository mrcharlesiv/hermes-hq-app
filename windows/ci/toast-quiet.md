# Quiet-state readback for the reply-only desktop walk

This is a **read-only observer, not a command**. `AppNotificationManager.Setting` is a getter for this app. Neither it nor `SHQueryUserNotificationState` offers a per-test setter. Do not substitute a system toggle: **zero settings writes; no restoration needed**. Windows can still change state between readings. No result here grants permission to send input or proves a banner was visible.

## Full desktop walk integration

The full step uses the reviewed helper and the buttonless reply-only harness (`7f65d3cc1`, integrated as `b6ceb4ce0`), not the older questions walk. `ReplyWalkDispatch` reserves the original final extra; `check_toast_quiet.py` checks the first app’s logs before the separate cold gate. Neither supplies authority to launch or activate anything. Use normal launch, not the old DND/PowerShell scripts, a policy override, elevation/identity changes, registry edits, a real gateway or a second launch path. Nothing here belongs in app-only, contrast or cold-start mode.

### 1. Refuse before desktop setup

- Only the private `mrcharlesiv/hermes-hq-windows` mirror, `windows` workflow, `build` job, `push` of `refs/heads/feat/windows` and `runs-on: windows-latest`. Keep the step guard `runner.os == 'Windows' && runner.environment == 'github-hosted' && vars.HQW_DESKTOP_PROOF == '1'`. A skipped step is **not** a proof. Leave `HQW_APP_PROOF` unset.
- In that **full desktop step only**, keep `HQW_PRIVATE_MIRROR: ${{ toJSON(github.event.repository.private) }}` and `HQW_DESKTOP_PROOF: ${{ vars.HQW_DESKTOP_PROOF }}`. Add this non-secret event projection; never supply a default or synthesize it from the expected result:

  ```yaml
  HQW_QUIET_PUSH: ${{ format('{0}|{1}|{2}|{3}|{4}|{5}', github.event.repository.full_name, toJSON(github.event.repository.private), toJSON(github.event.repository.fork), github.event.ref, github.event.after, toJSON(github.event.deleted)) }}
  ```

- **Before normal launch or any desktop work**, specialize the full step's existing guard invocation as `ReplyProbe.exe guard toasts`. For exactly those two literal arguments call `ToastQuietProbe.RequireRunner(OperatingSystem.IsWindows(), Environment.GetEnvironmentVariable)` **and** retain `DesktopProof.ForRunner`; only return 0 if both accept. On refusal print the fixed `StopLine` and return nonzero; the step stops. This branch checks metadata only: never fall through to warm/cold, never retry with bare `guard`. Leave the ordinary guard for unrelated steps alone. No new executable or launcher.
- `RequireRunner` checks the exact repository, push, ref, workflow name **and path**, job, hosted runner and opt-ins. A non-fork, non-deletion private event's `after` must equal both `GITHUB_SHA` and `GITHUB_WORKFLOW_SHA`; positive ASCII run/attempt IDs are required. Missing evidence is `runner-not-authorized` (`non-windows` for the wrong OS). This trusts the reviewed workflow and hosted runner that inject the values, not arbitrary environment strings as remote attestation.
- In `Automation.RunAsync`, validate the **actual parsed** full-run `cfg` by calling `ReplyQuietReadback.RequirePlan(cfg)` before `window.ShowSignIn()`, the first shot, sign-in/adoption, or any place navigation. If the caller cannot read/parse the file, log `phase=plan gap=plan-unreadable` and stop without a shot. A parsed but mismatched plan (including JSON null) is `not-reply-walk`. `RequirePlan` checks the runner again and requires one final `toasts` extra, the exact reply-only URL and synthetic username, `walks=["toasts"]`, `places=[]`, and no earlier claim on that port/tag/walk. It does not create a session or authorize a launch. Normal fixture setup must be independently authorized; do not navigate, bring a window forward or dismiss anything to *obtain* a passing context.

### 2. Exactly one registered route with live context

Keep the **one** `RegisterToastsWalks()` call in `ProofWalks.Register()`. Replace the body of `RegisterToastsWalks`, **removing** its `Automation.NamedWalks["toasts"]` assignment. Register `Automation.BoundWalks.Add("toasts", ToastsAsync)` instead: `BoundWalks` is an ordinal dictionary of `Func<Func<string, Task>, ToastQuietProbe, Task>`; the existing `ToastsAsync` becomes `private static async Task ToastsAsync(Func<string, Task> shot, ToastQuietProbe quiet)`. A duplicate `Add` at initialization is a terminal `route-not-unique`, not last-registration-wins. Other walks keep their existing registry and signatures. Do not keep an unbound overload.

Recheck `RequirePlan(cfg)` at the start of the final extra, before its sign-in, `ShowShell` or places loop. In the named-extra loop reserve `toasts` **before** generic lookup. Use the original `cfg`, the actual enumerated `extra` and `walkName`, and **the same `s2`** returned for that extra and passed to `AppState.Adopt`. For example, inside `Automation.RunAsync`:

```csharp
if (tag == "toasts" || walkName == "toasts")
{
    if (tag != "toasts" || walkName != "toasts" || NamedWalks.ContainsKey("toasts") ||
        !BoundWalks.TryGetValue("toasts", out var boundWalk))
    {
        Note("walk toasts: toast-quiet-stop/v1 phase=dispatch gap=route-not-unique");
        return; // exit RunAsync; its non-UI finally still flushes the log and exits
    }
    var quiet = ReplyQuietReadback.Bind(cfg, extra, walkName, s2);
    quiet.Checkpoint(QuietPoint.Entry); // throws before entering ToastsAsync, not after A/B navigation
    await boundWalk(Shot, quiet);
    Note($"{tag} walk {walkName} finished");
    continue; // never fall through to NamedWalks, including on refusal
}
```

`Entry` requires the same adopted in-memory session on the exact reply-only origin/account, no pending request, and the already open, tracked **B** composer in the app's own foreground window. Both the shell pane and loaded chat must match, with no sheet or popup. A is not required to be tracked until normal setup opens it. Entry also samples notification state: an unknown Focus Assist value stops before the first toast-walk navigation. No focus repair or retry.

**Registration test migration:** update `WalkProofTests.EveryWalkWindowsYmlAsksForIsRegisteredAndTakesItsPicture` in the integration change. For `toasts`, assert exactly one `RegisterToastsWalks()` call, one typed `BoundWalks.Add("toasts", ToastsAsync)` and zero generic registrations; still require `shot("toasts")` and every requested picture. Retain the existing generic registration and picture assertions for **all other** walks. Exercise the actual dispatcher with fake handlers: valid original node/session → bound handler once, generic zero; missing/double registration, tag/name mismatch, cloned node/plan, revoked session or denied entry → both zero and a named stop; an ordinary named walk still runs once. Do not just exempt `toasts` from the test.

### 3. Stop before the next action

`Checkpoint` logs and **throws `QuietWalkStopped`** on refusal; `RequireChat` rechecks runner, binding and actual focused composer without reading the notification settings. A stop is latched on that instance. Use one instance on the app UI thread; do not replace it after a stop. Never wrap a checkpoint in a log-and-continue catch.

| Checkpoint | Position in the existing reply walk |
|---|---|
| `Entry` | Typed dispatcher, immediately before the call into `ToastsAsync` (above). |
| `BeforeFirst` | After normal A→B setup and the baseline shot, immediately before the first `Raise("/__toast/warm", …)`. A must now be tracked and B focused. |
| `BeforeAway` | Immediately before `presenter.Minimize()`. A refusal means **no minimize** and **no warm or cold invocation**. |
| `AfterAway` | After the existing, independently authorized restore of the app's own presenter and `Showing(storedB)`, **before** the restored shot or any warm invocation. A refusal ends the walk here. |

A check does not survive an `await`. Immediately before each subsequent foreground action, call `quiet.RequireChat(QuietChat.B)` or `.A` for the **expected source**, not the destination or a chat inferred from whatever is focused. In particular: B before `Navigator.Go(A)` after the awaited fixture lookups; A before the first `GoToB()`; B before the baseline shot, posts while in front, and `InvokeWarmAsync()` after `Showing(storedB)`. After warm, expect A only on an independently verified open, otherwise B; recheck that expected source before a shot or returning to B, and B before preparing the cold reply/receipt. Do not inspect or act on another window while intentionally minimized. The quiet gate does not authorize the away interval, posting, restore or activation. If the existing harness cannot do its own bounded action safely, record a gap; never force activation to satisfy the observer.

In the **per-extra** catch, put `catch (QuietWalkStopped) { throw; }` **before** the general exception/screenshot handler. For any other exception in the reserved final extra (e.g. `Showing(storedB)` times out before the next checkpoint), note `toast-quiet-stop/v1 phase=walk gap=reply-walk-incomplete` with the same `walk toasts: ` prefix and return; never take the general failure shot. In the **outer** catch, before its general handler, use `catch (QuietWalkStopped stop) { Note("walk toasts: " + stop.StopLine); return; }`. Plan/dispatch failures must reach the same terminal path. No failure screenshot, `finished`/`done`, subsequent navigation, shell helper, cold receipt or fallback on this path. Leave the non-UI `finally` (flush log, normal exit) intact. A clean process exit alone is not a pass.

### 4. Readback before the separate cold step

Read only the current full walk's `hermes-hq.log.1` then `hermes-hq.log` (not prior runs or the contrast/cold app); `automation.log` also records the terminal stop through `RunAsync.Note`. Match complete `[automation] walk toasts: …` messages, not substring hits. For a walk that continued require exactly **one `entry` followed by `before-first`, `before-away`, `after-away`**, in order, all for the exact mirror SHA and `<GITHUB_RUN_ID>.<GITHUB_RUN_ATTEMPT>`:

```
toast-quiet/v1 run=<run.attempt> sha=<mirror-sha> phase=<phase> quns=<state> focus=<profile> app=<setting> writes=0 restore=not-needed banner=unverified gap=<reason>
```

- **Before** the workflow's cold invocation, reject any `toast-quiet-stop/v1 phase=<phase> gap=<reason>` in this walk, any `guard-a`/`guard-b` refusal line, any refused/unknown measurement, and missing, malformed, duplicate, stale, `unbound` or out-of-order records. Successful `RequireChat` checks are silent. Also require the finished walk and the existing cold gate's own fresh, unique ready verdict/receipt; four quiet records cannot replace them. A refusal can leave just the prefix of the four readings, or none; keep its reason and mark the rest **not attempted**. Never fill missing phases, use an old receipt, or invoke the helper to complete the evidence. A log sink can drop a write; missing evidence is still a non-pass.
- Only `focus-quiet`, `shell-not-accepting`, `app-not-enabled` or `banner-not-observed` with **known** measurements let the independently guarded walk continue. `not-read` means refused before the getters; `discarded` / `sample-context-lost` means the runner, foreground or session changed during them. `focus-unknown` includes unreadable, unpublished, wrong-size or unknown legacy WNF data. Only a successful four-byte, stamped zero means `off`. Unknown measurements take precedence over another signal's known suppression.
- When the foreground check itself refuses, the app follows that same bound sample with `fixture-foreground/v1 phase=<phase> clause=<class>`. For example, `OpenPopup`, `ComposerNotFocused` and `ForegroundNotOwned` name different first failed checks. `Unreadable` means the getter did not supply a recognized result, not that a mismatch was observed. Nothing is inspected again. No new record is emitted for a success, a lost runner or an invalid session/plan. Read this line only alongside its original non-pass sample: it contains no identities, is not a permit, and does not change what the checker accepts. Older samples have no clause; it cannot be reconstructed from their gap.
- Even `QUNS_ACCEPTS_NOTIFICATIONS` + `off` + `Enabled` yields `banner=unverified gap=banner-not-observed`. `Shown`, history, a Notification Center row, an app screenshot or a successful activation does not show that Windows drew a banner. A separate authorized witness must see the expected banner **while displayed**. Keep fresh warm `NotificationInvoked` / cold `AppNotification` **and** the loaded target chat as separate results; never substitute simulated activation.

Local tests link the foreground guard to inert controls, handles and notification getters; they count the reads in order and the actions after refusal. The real WinUI/OS calls are type-checked, not run on the Mac. Actual runner binding, focused chat, shell/legacy/app values, visible banner and warm/cold activation require a separately authorized Windows run.