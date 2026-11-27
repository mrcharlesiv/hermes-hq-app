# Chat focus with Windows Narrator

This opt-in proof covers three controls in the real WinUI chat. It is not a registered screenshot walk, a replacement for the keyboard suite, or an audio recording. Windows run `45171524778` is **not** a spoken result: its app log records accessible names and “doing what it does (Send)” rather than delivery of that key.

New receipts compare with the Mac 1245 archive, `484cd6acf574259345242ef5c4e61a74a13ca8ce`. The historical comparator is Mac 1240, `784f6c222cf04b5b09e631ea3b467a48d21ad556`. The Inspector function is identical at the two revisions (1240 lines 1824–1832; 1245 lines 1835–1843); the entire composer source is unchanged. These are accessibility labels in shipping Swift, not recorded Mac or Windows speech.

| Control | Swift source | What to compare on Windows |
| --- | --- | --- |
| Inspector | `App/Chat/ChatViewController.swift`, `makeInspectorButton()` | `Inspector`, button. Tab to it; do not open it. |
| Message field | `App/Chat/ComposerView.swift:551`, `textView.accessibilityLabel = "Message"` | `Message`, edit. The `Message <name>` placeholder is **not** this label. Windows sets a placeholder and `chat.composer` ID; neither tells us what Narrator said. |
| Send | `App/Chat/ComposerView.swift:1254–1257,1494`, primary button for an ordinary typed draft, not a queued edit or voice memo | `Send`, button. A typed `q` enables it; do not activate it. |

## Supervisor: disposable runner only

The existing private `feat/windows` push workflow has a separate `narrator-chat` job. Ordinary pushes do not select it. For one authorized sync with changed mirror content, the integration commit's **exact subject** must be `Proof: narrator-chat-only`; the existing sync supplies the `From feat/windows at <sha>.` paragraph. The separate chat check can run whether `HQW_DESKTOP_PROOF` is unset or exactly `1`. Neither selects it. Any other value (including `0`), any nonempty `HQW_NARRATOR_CHAT_DISABLE`, extra instructions, or a different head veto it. Do not set or clear remote variables to get a run. The product build and its desktop opt-in are unchanged.

Use only that fresh, interactive, GitHub-hosted Windows job. No user desktop or self-hosted runner. Never fabricate Actions variables, change the user's settings, grant access, or dismiss a Narrator/Home/consent prompt.

From the mirror's `windows` directory in that job (PowerShell):

```powershell
$targets = (Resolve-Path ci/narrator-chat/Fixture.targets).Path
dotnet publish src/HermesHQ.Windows -c Release -r win-x64 -p:Platform=x64 "-p:CustomAfterMicrosoftCommonTargets=$targets" --no-restore -o build/narrator-chat-app
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python -B ci/narrator_chat.py --disposable-narrator-chat
exit $LASTEXITCODE
```

The fixture target is not imported by shipping builds. It stamps the apphost and entry assembly of this separate publish with the push SHA and their hashes. The driver checks those, the private push payload and the actual checked-out HEAD before launch. It refuses existing app data, an existing Narrator, a non-interactive session or an existing result directory. It starts the installed `System32\Narrator.exe` normally and activates the fixture window once. The same `App` resources, `MainWindow`, launch flow, chat page and controls run; only the diagnostic entry point differs. Its sign-in is in memory against an owned `127.0.0.1` stand-in with no upstream. The synthetic draft is never sent.

## Reading the result

The job collects **only** `windows/build/narrator-chat/result.json` as `narrator-chat-<run id>-<attempt>`. A bound non-pass is kept for one day and the job fails; a missing, foreign or inconsistent receipt fails without an upload. Do not collect the seed, logs, fixture build, clipboard, app data or runner temp directory. The supervisor verifies the mirror SHA, run, attempt and evidence before signoff.

`receiptVersion: 2` pins Mac 1245. `runnerStop` is the first failed operation outside cleanup; `cleanupStop` is the first failed release of an **already acquired** resource. Both are null unless observed. For example, `verify-head` is the checkout check, `probe-session` the session probe, `start-standin` fixture setup, `launch-reader` the Narrator launch and `launch-app` the fixture app launch. A `launch-app` failure followed by `stop-reader` during cleanup keeps both codes. Neither implies the app ran. A cleanup failure alone also vetoes a pass. The codes contain no exception text, class, OS code, path or command. Failures before a fresh receipt directory exists (or writing the receipt itself) cannot produce bound evidence.

Only an explicit refusal from the session probe identifies an existing Narrator (`require-no-reader`) or a noninteractive session (`require-interactive`). A generic PowerShell failure, including exit 1, records only `probe-session`. All three stop before the stand-in or either child starts; the receipt retains no probe output or status number.

For offline replay, give `check_receipt` a byte-for-byte copy of the original file and its actual mirror SHA, run and attempt. An unversioned receipt binds only to Mac 1240. An old `OSError` with empty trace and no exit or fixture stays **bound, exit 1**: its failing operation is unknown. Do not edit or relabel it. A current job cannot downgrade to that format.

Unversioned `trace.stop` accepts the original bounded ASCII `fixture-…Exception` class token, not a message or qualified name. In new receipts explicit walk stops keep their own codes. For other exceptions the fixture records an exact known type (for example `fixture-Win32Exception` or `fixture-GatewayException`), or `fixture-other-exception` if the type is unknown. It chooses that category before writing the trace, without reading the exception message. The verifier checks the original bytes; it never repairs a string into an allowed category. Any such stop is a failure, not evidence of focus or speech.

Read the proof separately from the diagnostics:

- `trace.focus`: the initial focused control, then one sampled UIA peer (ID, XAML name, role and accessible name) per successful key effect. Opening the chat normally focuses the composer; that baseline is **not** a keyboard arrival.
- `trace.physical`: the requested chord, OS `SendInput` count, the key/modifiers received by the fixture, focus-event count/state, and foreground window checks. Shift+Tab to Inspector, retrace the same stops with Tab to Message, type one `q`, then Tab to Send. Each Tab needs one received key and one actual keyboard focus change; the draft needs no focus change. This is OS keyboard input, not a person pressing a hardware key or a call to a control handler.
- `trace.speech`: at baseline and the three arrivals, read Narrator's **own output** using its documented “copy the last phrase spoken” command (Microsoft's *Appendix B: Narrator keyboard commands and touch gestures*, `Narrator+Ctrl+X`, with Insert as the Narrator key). The probe does not ask Narrator to say the control's name. A receipt requires fresh clipboard content owned by the launched Narrator PID, the same focused control, and no `X` received by the app. Only bounded synthetic words can be retained. No UIA-label or speech-synthesis fallback.
- `verdict.keyboard` and `verdict.spoken` are separate. `macLabels` compares UIA names. `speechObserved` distinguishes a fresh, attributable phrase from no observation; `spokenMacLabels` says whether it named the right control. A wrong or mixed phrase is not missing data. For example, `Message Proof Hermes, edit` can identify the composer but does not equal the Mac's `Message` label. `pass` also requires the clean app exit, completed walk and expected fixture history without prompt attempts or uploads.

There are at most 12 Tab moves per leg, no second lap, and a 90-second app cap. Before each input batch the fixture checks its exact foreground HWND/PID, native focus, app-local focused control and modifiers. It stops on lost focus, another chat/window, an unexpected control, modal or key transition; it never tries to regain focus. `SendInput` is a foreground API, not window-addressed, hence the dedicated disposable desktop. The copy command is attempted only with an initially empty clipboard or the prior owned observation. If copying is unavailable, intercepted by the app, stale, broker-owned, or the en-US phrase isn't recognized, speech cannot pass. The runner is discarded rather than clearing a clipboard or stopping someone else's reader.

Offline wiring check: `python3 -B windows/tests/test_narrator_chat_job.py` reads the workflow with Ruby's standard YAML parser, injects faults into in-memory operations and verifies the resulting synthetic receipts. `python3 -B windows/tests/test_narrator_chat.py` exercises the classifier and loopback stand-in. Run the portable regressions with `python3 -B -m unittest discover -s windows/tests -p 'test_*.py'`. From `windows/`, `tools/compile-check/check.sh -p:CustomAfterMicrosoftCommonTargets="$PWD/ci/narrator-chat/Fixture.targets"` type-checks the opt-in code. None of these observes Windows, Narrator, audio output or Mac VoiceOver.
