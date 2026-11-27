"""Wiring contracts for the FULL desktop workflow. No desktop APIs, processes or fixtures are run."""
from pathlib import Path
import re
import unittest

WIN = Path(__file__).resolve().parents[1]
CI = WIN / 'ci'
SERVICES = WIN / 'src/HermesHQ.Windows/Services'


class DesktopProofTests(unittest.TestCase):
    def test_workflow_and_both_desktop_steps_are_scoped(self):
        workflow = (CI/'windows.yml').read_text()
        for text in ("branches: [feat/windows]", 'github.event.repository.private == true',
                     "github.repository == 'mrcharlesiv/hermes-hq-windows'", "github.event_name == 'push'",
                     "github.ref == 'refs/heads/feat/windows'", 'contents: read', 'persist-credentials: false'):
            self.assertIn(text, workflow)
        for step in ('Run the app and take screenshots', 'Larger text and high contrast'):
            block = workflow.split('- name: ' + step + '\n')[1].split('\n      - ')[0]
            self.assertIn("vars.HQW_DESKTOP_PROOF == '1'", block)
            self.assertIn("runner.environment == 'github-hosted'", block)
            first = block.split('run: |\n')[1].lstrip().splitlines()[0]
            args = 'guard toasts' if step == 'Run the app and take screenshots' else 'guard'
            self.assertTrue(first.startswith('& ./windows/build/reply-probe/ReplyProbe.exe ' + args + ';'))
            self.assertIn('$LASTEXITCODE -ne 0', first)
            self.assertIn('$app.ExitCode -ne 0', block)
        full = workflow.split('- name: Run the app and take screenshots\n')[1].split('\n      - ')[0]
        projection = "HQW_QUIET_PUSH: ${{ format('{0}|{1}|{2}|{3}|{4}|{5}', github.event.repository.full_name, toJSON(github.event.repository.private), toJSON(github.event.repository.fork), github.event.ref, github.event.after, toJSON(github.event.deleted)) }}"
        self.assertEqual(1, workflow.count('HQW_QUIET_PUSH'))
        self.assertIn(projection, full.split('run: |')[0])
        self.assertIn('HQW_PRIVATE_MIRROR: ${{ toJSON(github.event.repository.private) }}', workflow)
        self.assertIn('HQW_DESKTOP_PROOF: ${{ vars.HQW_DESKTOP_PROOF }}', workflow)
        self.assertIn('runs-on: windows-latest', workflow)
        self.assertLess(full.index('ReplyProbe.exe guard toasts;'), full.index('Refusing an existing app profile or process.'))
        self.assertLess(full.index('Refusing a pre-existing screenshot directory.'), full.index('New-Item'))
        self.assertIn('Remove-Item -Force $dmp.FullName', full)
        self.assertIn('!windows/build/shots/**/*.dmp', workflow)
        self.assertIn('dotnet publish windows/src/HermesHQ.Windows', workflow)
        self.assertIn('dotnet test windows/HermesHQ.sln', workflow)
        for forbidden in ('workflow_dispatch', 'medium-integrity', 'icacls', 'executionpolicy', 'scheduledtask',
                          'start-process -verb runas', 'hqw_toast_click', 'hqw_app_proof', 'toast-approval'):
            self.assertNotIn(forbidden, workflow.lower())
        contrast = (CI/'high-contrast.ps1').read_text()
        self.assertLess(contrast.index('ReplyProbe.exe'), contrast.index('Add-Type'))
        self.assertNotIn('[string]$Scheme', contrast)

    def test_quiet_readback_and_independent_receipt_gate_the_only_cold_invocation(self):
        workflow = (CI/'windows.yml').read_text(encoding='utf-8')
        full = workflow.split('- name: Run the app and take screenshots\n')[1].split('\n      - ')[0]
        # The quiet observer is a veto, not a second way to invoke or to produce a ready receipt.
        checks = ('& ./windows/build/reply-probe/ReplyProbe.exe guard toasts;', 'Refusing an existing app profile or process.',
                  'Refusing a pre-existing screenshot directory.', '$app = Start-Process $exe', '$app.WaitForExit(',
                  '$quietVerdict = python windows/ci/check_toast_quiet.py', '$quietOk = $LASTEXITCODE -eq 0',
                  "$quietVerdict -ceq 'quiet readback: complete; banner unverified'", 'if (!$quietOk)',
                  'elseif ($app.ExitCode -ne 0)', '$ready.Count -ne 1 -or $noCold.Count -ne 0',
                  'Test-Path -LiteralPath $receipt -PathType Leaf', '(Get-Item -LiteralPath $receipt).Length -ne $stamp.Length',
                  '[IO.File]::ReadAllText($receipt)', 'elseif (Get-Process HermesHQ', '-ArgumentList cold')
        self.assertEqual(sorted(full.index(x) for x in checks), [full.index(x) for x in checks])
        self.assertEqual(1, workflow.count('-ArgumentList cold'))
        self.assertIn('test_toast_quiet.py', workflow)
        self.assertRegex(full, r'if \(!\$quietOk\) \{[^}]+no cold invocation\.')
        probe = (WIN/'tools/reply-probe/Program.cs').read_text(encoding='utf-8')
        guard = probe.split('if (args is ["guard", "toasts"])')[1].split('if (proof == null)')[0]
        self.assertIn('ToastQuietProbe.RequireRunner(OperatingSystem.IsWindows(), Environment.GetEnvironmentVariable)', guard)
        self.assertIn('Console.Error.WriteLine(stop.StopLine); return 1;', guard)
        self.assertIn('if (proof != null) return 0;', guard)
        self.assertTrue(guard.strip().endswith('return 1;\n}'))
        self.assertNotIn('OpenReply', guard)
        walk = (SERVICES/'ProofWalks.Toasts.cs').read_text(encoding='utf-8')
        self.assertIn('NotificationsFeature.ColdReceipt, FileMode.CreateNew', walk)
        self.assertNotIn('WriteAllTextAsync(NotificationsFeature.ColdReceipt', walk)

    def test_reply_checkpoints_guard_the_existing_actions_not_a_focus_repair(self):
        walk = (SERVICES/'ProofWalks.Toasts.cs').read_text(encoding='utf-8')
        for tokens in [('quiet.RequireChat(QuietChat.B);', 'Navigator.Go(new ChatDestination(a.'),
                       ('quiet.RequireChat(source);', 'Navigator.Go(new ChatDestination(b.'),
                       ('await shot("toast-before-reply")', 'quiet.Checkpoint(QuietPoint.BeforeFirst);', 'await Raise("/__toast/warm"'),
                       ('quiet.Checkpoint(QuietPoint.BeforeAway);', 'presenter.Minimize();', 'await Raise("/__toast/away"',
                        'RequireOwnMinimizedWindow();\n        presenter.Restore();', 'quiet.Checkpoint(QuietPoint.AfterAway);',
                        'await shot("toast-reply-away")', 'await InvokeWarmAsync()'),
                       ('await GoToB(afterWarm)', 'await Raise("/__toast/cold"', 'NotificationsFeature.ColdReceipt')]:
            offsets = [walk.index(t) for t in tokens]
            self.assertEqual(sorted(offsets), offsets)
        for forbidden in ('.Activate();', '.Focus(', 'BringToFront(', 'SendInput('):
            self.assertNotIn(forbidden, walk)
        auto = (SERVICES/'Automation.cs').read_text(encoding='utf-8')
        self.assertLess(auto.index('ReplyQuietReadback.RequirePlan(cfg);'), auto.index('window.ShowSignIn();'))
        self.assertIn('dispatch.RunAsync(extra, tag, walkName, s2, ReplyQuietReadback.Bind, Shot, Capture)', auto)
        self.assertIn('if (quiet == null) await DrawOpenPopupsAsync', auto)
        self.assertLess(auto.index('catch (QuietWalkStopped) { throw; }'), auto.index('await Shot($"{tag}-failure")'))
        self.assertLess(auto.index('catch (QuietWalkStopped stop)'), auto.index('await Shot("failure")'))

    def test_no_action_dispatch_or_foreign_helper_in_toast_walk(self):
        source = (SERVICES/'ProofWalks.Toasts.cs').read_text()
        for forbidden in ('/__fixture/ask', '/__fixture/requests', 'NotificationsFeature.Respond',
                          'AnswerApproval', 'ApproveButton', 'HQW_TOAST_CLICK', '-ExecutionPolicy', 'powershell.exe'):
            self.assertNotIn(forbidden, source)
        self.assertIn('RecordedToastActions.Verify', source)
        self.assertIn('GetAllAsync()', source)
        self.assertFalse((CI/'medium-integrity.ps1').exists())
        self.assertFalse((CI/'toast-click.ps1').exists())
        probe = (WIN/'tools/reply-probe/ShellCenter.cs').read_text()
        for forbidden in ('RootElement', 'GetClickablePoint', 'SetCursorPos', 'SendInput', 'mouse_event',
                          'Shell_TrayWnd', 'ControlType.Button).Invoke', 'Condition.TrueCondition'):
            self.assertNotIn(forbidden, probe)
        self.assertEqual(1, probe.count('.Invoke();'))
        self.assertIn('AutomationElement.FromHandle', probe)
        for forbidden in ('GetParent(', 'TreeScope.Ancestors', 'EnumWindows', 'FindWindow(', 'UseShellExecute', 'Process.Start('):
            self.assertNotIn(forbidden, probe)
        self.assertIn('QueryUriSupportAsync', probe)
        self.assertIn('TargetApplicationPackageFamilyName', probe)
        self.assertIn('DisplayApplicationPicker = false', probe)
        self.assertIn('ForegroundCenter() != host', probe)
        receiver = (WIN/'src/Hermes.Core/Shell/RecordedToastActions.cs').read_text()
        for forbidden in ('HermesClient', 'QuestionCenter', 'Process.Start', 'LocalAnswerQueue', 'HttpClient', 'Invoke(', 'async ', 'System.Net'):
            self.assertNotIn(forbidden, receiver)

    def test_only_an_offline_recording_transport_exercises_the_answer_path(self):
        # The desktop proof above cannot answer. Require the managed behavior to stay tested without
        # a UI, fixture gateway, socket, or live account; all other test call sites remain excluded.
        tests = WIN/'tests/Hermes.Core.Tests'
        callers = {p.relative_to(tests).as_posix() for p in tests.rglob('*.cs')
                   if 'AnswerApprovalFromAlertAsync(' in p.read_text(encoding='utf-8-sig')}
        self.assertEqual({'NotificationAnswerRecorderTests.cs'}, callers)
        source = (tests/'NotificationAnswerRecorderTests.cs').read_text()
        self.assertIn('new FakeQuestionTransport()', source)
        self.assertIn('new QuestionCenter(transport)', source)
        for forbidden in ('HermesClient', 'RpcQuestionTransport', 'RpcConnection', 'GatewaySession', 'HttpClient',
                          'SignIn', 'System.Net', 'Credentials(', 'Process.Start', 'DllImport', '__fixture', '.Attach('):
            self.assertNotIn(forbidden, source)

    def test_input_is_rechecked_before_dispatch_and_cold_launch_latches_the_refusal(self):
        keys = (SERVICES/'ProofWalks.cs').read_text()
        for gate in ('client.Questions.Waiting().Count', 'DesktopProof.SafeControl', 'if (focus is WebView2)',
                     'FixtureAddress(client.Session.Address.ToString())', 'Eligible(target) && SendInput',
                     'GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(target)',
                     'GetAncestor(WindowFromPoint(point), RootAncestor) != under'):
            self.assertIn(gate, keys)
        app = (WIN/'src/HermesHQ.Windows/Features/Notifications/NotificationsFeature.cs').read_text()
        self.assertLess(app.index('_fixtureLaunch = true'), app.index('manager.NotificationInvoked +='))
        self.assertIn('if (_fixtureLaunch || Automation.Enabled || arguments.ContainsKey(DesktopProof.Marker))', app)
        self.assertIn('if (!Automation.Enabled && !_fixtureLaunch) Answers.Ready', app)
        self.assertIn('if (Automation.Enabled || _fixtureLaunch) return;', app)
        self.assertIn('if (_fixtureLaunch) return;', app)
        self.assertIn('DesktopProof.ReplyTarget(args.Argument', app)
        self.assertIn('return;', app.split('fixture reply activation {phase} {expected}')[1].split('var action =')[0])

    def test_cold_activation_and_screenshots_are_not_substituted(self):
        workflow = (CI/'windows.yml').read_text()
        self.assertIn('ReplyProbe.exe', workflow)
        self.assertIn('cold', workflow)
        self.assertIn('Kind AppNotification', workflow)
        self.assertIn('toast cold launch opened chat key', workflow)
        self.assertIn('open gap', workflow)
        self.assertRegex(workflow, r'if \(\$launched -and \$opened')
        self.assertIn('Missing screenshot:', workflow)
        self.assertIn('high-contrast-chat', workflow)
        for evidence in ('toast-before-reply', 'toast-warm-opened.png', 'toast-cold-opened.png', 'check_walk_pngs.py $shots',
                         'check_walk_pngs.py $dir', 'Get-FileHash', 'GITHUB_STEP_SUMMARY', 'test_reply_evidence.py'):
            self.assertIn(evidence, workflow)
        tags = re.findall(r'^\s*@\{ tag = "([^"]+)"; args = ', workflow, re.M)
        self.assertEqual('toasts', tags[-1])
        self.assertTrue({'sessions','settings','tasks','keyboard-only','screen','composer'}.issubset(tags))


if __name__ == '__main__':
    unittest.main()
