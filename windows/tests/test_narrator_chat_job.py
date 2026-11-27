"""Offline contracts for the mirror job. No Actions runner, desktop, or driver is started."""
import importlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any
import unittest

from test_narrator_chat import example, model_run  # synthetic operations and streams, not a runner result

WIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WIN / 'ci'))
native = importlib.import_module('narrator_chat')
job_checks = importlib.import_module('narrator_chat_job')

SHA = 'a' * 40
MAC_1240 = '784f6c222cf04b5b09e631ea3b467a48d21ad556'
MAC_1245 = '484cd6acf574259345242ef5c4e61a74a13ca8ce'
SUBJECT = 'Proof: narrator-chat-only'
MESSAGE = SUBJECT + '\n\nFrom feat/windows at abcdef012.'
UPLOAD = 'actions/upload-artifact@v4'


def wire_trace():
    # The classifier examples omit unused properties; the native JSON serializer retains the nulls.
    t = example()
    for r in t['focus']: r['xaml'] = ''
    for r in t['speech']: r['unavailable'] = None
    for r in t['physical']:
        for key in ('emptyBefore', 'draftAfter', 'sendEnabled'): r.setdefault(key, None)
    return t


def pre_focus_receipts(stop) -> tuple[dict[str, Any], dict[str, Any]]:
    # Construct both wire formats directly so that a producer cannot sanitize a verifier test's input.
    t = dict(schema=1, appPid=101, narratorPid=303, hwnd=0, seededMessages=None, completed=False,
             stop=stop, focus=[], physical=[], speech=[])
    legacy: dict[str, Any] = dict(mirrorSha=SHA, runId='42', attempt='1', macReference=MAC_1240,
        appExit=0, readerAliveAtAppExit=True, runnerStop='did not observe the expected read-only synthetic chat',
        trace=t, verdict=native.assess(t), fixture=dict(historyRequested=False, promptAttempts=0, upstreamCalls=0, uploads=0))
    return legacy, {**legacy, 'receiptVersion': 2, 'macReference': MAC_1245, 'runnerStop': 'check-fixture', 'cleanupStop': None}


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Parse the real YAML with the Mac's standard Ruby/Psych; no network dependency or workflow emulator.
        raw = (WIN / 'ci/windows.yml').read_bytes()
        cls.doc = json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
            'print JSON.generate(YAML.safe_load(STDIN.read))'], input=raw))
        cls.job = cls.doc['jobs']['narrator-chat']
        cls.steps = cls.job['steps']

    def test_only_the_existing_private_push_and_positive_selection(self):
        self.assertEqual(self.doc.get('on', self.doc.get('true')), {'push': {'branches': ['feat/windows']}})
        self.assertEqual(self.doc['permissions'], {'contents': 'read'})
        self.assertCountEqual([s.strip() for s in self.job['if'].split('&&')], [
            "github.event_name == 'push'", "github.repository == 'mrcharlesiv/hermes-hq-windows'",
            'github.event.repository.full_name == github.repository', "toJSON(github.event.repository.private) == 'true'",
            "github.ref == 'refs/heads/feat/windows'", 'github.event.ref == github.ref',
            "toJSON(github.event.deleted) == 'false'", 'github.event.after == github.sha',
            'github.event.head_commit.id == github.sha',
            '''startsWith(github.event.head_commit.message, fromJSON('"Proof: narrator-chat-only\\n\\nFrom feat/windows at "'))''',
            "(vars.HQW_DESKTOP_PROOF == '' || vars.HQW_DESKTOP_PROOF == '1')", "vars.HQW_NARRATOR_CHAT_DISABLE == ''"])

    def test_desktop_opt_in_coexists_but_never_overrides_a_stop(self):
        # Read only the variable terms of the real job condition. The test above pins every other conjunct.
        terms = [t.strip() for t in self.job['if'].split('&&')]
        switch, = [t for t in terms if 'vars.HQW_DESKTOP_PROOF' in t]
        veto, = [t for t in terms if 'vars.HQW_NARRATOR_CHAT_DISABLE' in t]
        match = re.fullmatch(r"\(vars\.HQW_DESKTOP_PROOF == '([^']*)' \|\| vars\.HQW_DESKTOP_PROOF == '([^']*)'\)", switch)
        empty = re.fullmatch(r"vars\.HQW_NARRATOR_CHAT_DISABLE == '([^']*)'", veto)
        if match is None or empty is None:
            raise self.failureException('expected two allowed desktop values and a separate Narrator veto')
        for broad in ('', '1', '0', 'false', '01', 'other', ' '):
            for disable in ('', '0', '1', 'stop', ' '):
                with self.subTest(broad=broad, disable=disable):
                    actual = broad in match.groups() and disable == empty.group(1)
                    self.assertEqual(actual, broad in ('', '1') and not disable)

    def test_one_fresh_hosted_job_with_no_product_or_other_walk(self):
        self.assertEqual(set(self.doc['jobs']), {'build', 'narrator-chat'})
        self.assertEqual(set(self.job), {'if', 'runs-on', 'timeout-minutes', 'defaults', 'steps'})
        self.assertEqual(self.job['runs-on'], 'windows-latest')
        self.assertLessEqual(self.job['timeout-minutes'], 20)
        self.assertEqual(self.job['defaults'], {'run': {'shell': 'pwsh', 'working-directory': 'windows'}})
        self.assertEqual([s.get('uses') for s in self.steps], [
            'actions/checkout@v4', 'actions/setup-dotnet@v4', 'actions/setup-python@v5', None, None, None, None, UPLOAD])
        self.assertEqual(self.steps[0]['with'], {'ref': '${{ github.sha }}', 'persist-credentials': False})
        build = self.doc['jobs']['build']
        self.assertNotIn('needs', build)
        self.assertNotIn('narrator-chat', json.dumps(build).lower())
        product = [s['with']['path'] for s in build['steps'] if s.get('with', {}).get('name') == 'HermesHQ-win-x64']
        self.assertEqual(product, ['windows/build/app'])
        gates = {s.get('name'): s.get('if') for s in build['steps']}
        broad = "runner.os == 'Windows' && runner.environment == 'github-hosted' && vars.HQW_DESKTOP_PROOF == '1'"
        for name in ('Run the app and take screenshots', 'Larger text and high contrast'): self.assertEqual(gates[name], broad)
        self.assertEqual(gates['Desktop proof not opted in'], "vars.HQW_DESKTOP_PROOF != '1'")

    def test_only_the_separate_publish_and_native_exit_status(self):
        self.assertFalse(any('continue-on-error' in s or 'env' in s or 'shell' in s or 'working-directory' in s
                             for s in self.steps))
        self.assertTrue(all('if' not in s for s in self.steps[:6]))
        self.assertEqual(self.steps[3]['run'], 'python -B ci/narrator_chat_job.py admit')
        self.assertEqual(self.steps[4]['run'].strip().splitlines(), [
            'dotnet restore src/HermesHQ.Windows -r win-x64 -p:Platform=x64 -p:Configuration=Release',
            'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
            '$targets = (Resolve-Path ci/narrator-chat/Fixture.targets).Path',
            'dotnet publish src/HermesHQ.Windows -c Release -r win-x64 -p:Platform=x64 "-p:CustomAfterMicrosoftCommonTargets=$targets" --no-restore -o build/narrator-chat-app',
            'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
            "if (Test-Path -LiteralPath build/narrator-chat) { throw 'Refusing pre-existing Narrator evidence.' }"])
        self.assertEqual(self.steps[5]['id'], 'walk')
        self.assertEqual(self.steps[5]['run'].splitlines(), ['python -B ci/narrator_chat.py --disposable-narrator-chat',
                                                           'exit $LASTEXITCODE'])

    def test_only_a_checked_receipt_can_be_collected_even_on_failure(self):
        receipt, upload = self.steps[-2:]
        self.assertEqual(receipt['id'], 'receipt')
        self.assertEqual(receipt['if'], "${{ !cancelled() && (steps.walk.outcome == 'success' || steps.walk.outcome == 'failure') }}")
        self.assertEqual(receipt['run'].splitlines(), ['python -B ci/narrator_chat_job.py receipt', 'exit $LASTEXITCODE'])
        self.assertEqual(upload, {'uses': UPLOAD, 'if': "${{ !cancelled() && steps.receipt.outputs.bound == 'true' }}",
            'with': {'name': 'narrator-chat-${{ github.run_id }}-${{ github.run_attempt }}',
                     'path': 'windows/build/narrator-chat/result.json', 'if-no-files-found': 'error', 'retention-days': 1}})


class JobChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.win = Path(temp.name).resolve()
        self.path = self.win / 'build/narrator-chat/result.json'
        self.path.parent.mkdir(parents=True)
        self.output = self.win / 'step-output'
        trace = wire_trace()
        self.result: dict[str, Any] = dict(mirrorSha=SHA, runId='42', attempt='1', macReference=MAC_1240,
            appExit=0, readerAliveAtAppExit=True, runnerStop=None, trace=trace, verdict=native.assess(trace),
            fixture=dict(historyRequested=True, promptAttempts=0, upstreamCalls=0, uploads=0))

    def check(self, **options):
        return job_checks.check_receipt(self.win, SHA, '42', '1', self.output, **options)

    def save(self, **changes):
        self.path.write_text(json.dumps({**self.result, **changes}), encoding='utf-8')

    def bound(self, result, expected_exit, **options):
        self.path.write_text(json.dumps(result), encoding='utf-8')
        self.assertEqual(self.check(**options), expected_exit)
        self.assertEqual(self.output.read_text().splitlines(), ['bound=true'])
        self.output.unlink()

    def refused(self, result, **options):
        self.path.write_text(json.dumps(result), encoding='utf-8')
        with self.assertRaises(ValueError): self.check(**options)
        self.assertFalse(self.output.exists())

    def test_each_inert_startup_fault_names_its_operation_not_a_later_resource(self):
        for fault, phase in [('build', 'verify-build'), ('temp', 'create-temp'), ('environment', 'prepare-env'),
                ('checkout', 'verify-head'), ('session', 'probe-session'), ('standin', 'start-standin'),
                ('reader-launch', 'launch-reader'), ('reader-start-poll', 'check-reader'),
                ('write-seed', 'write-seed'), ('app-launch', 'launch-app')]:
            with self.subTest(fault=fault):
                r, calls = model_run(fault)
                self.assertEqual((r['runnerStop'], r['cleanupStop']), (phase, None))
                self.assertEqual((r['trace'], r['appExit'], r['readerAliveAtAppExit'], r['fixture']), ({}, None, None, None))
                self.assertFalse(set(calls[calls.index(fault) + 1:]) - {'reader-stop', 'standin-stop', 'temp-remove'})
                self.assertNotIn('synthetic detail', json.dumps(r))
                self.bound(r, 1)
        r, calls = model_run('app-env')  # missing a required key, after seed write but before child creation
        self.assertEqual(r['runnerStop'], 'prepare-app-env')
        self.assertNotIn('app-launch', calls)
        self.bound(r, 1)
        r, _ = model_run('session', error=ValueError)
        self.assertEqual(r['runnerStop'], 'probe-session')
        self.assertNotIn('synthetic detail', json.dumps(r))
        self.bound(r, 1)

    def test_cleanup_never_replaces_the_first_failure_and_only_releases_owned_resources(self):
        cases = [(['checkout', 'temp-remove'], 'verify-head', 'remove-temp', ['temp-remove']),
                 (['reader-launch', 'standin-stop'], 'launch-reader', 'stop-standin', ['standin-stop', 'temp-remove']),
                 (['app-launch', 'reader-stop', 'standin-stop'], 'launch-app', 'stop-reader',
                  ['reader-stop', 'standin-stop', 'temp-remove']),
                 (['wait-app', 'app-stop'], 'wait-app', 'stop-app',
                  ['app-stop', 'app-stop', 'reader-stop', 'standin-stop', 'temp-remove'])]
        for faults, primary, cleanup, releases in cases:
            with self.subTest(faults=faults):
                r, calls = model_run(*faults, trace=wire_trace())
                self.assertEqual((r['runnerStop'], r['cleanupStop']), (primary, cleanup))
                self.assertEqual(calls[calls.index(faults[0]) + 1:], releases)
                self.bound(r, 1)
        r, _ = model_run('app-stop', app_exit=2)
        self.assertEqual((r['runnerStop'], r['cleanupStop']), ('check-exit', 'stop-app'))
        self.bound(r, 1)

    def test_observations_survive_wait_failure_but_never_make_it_a_pass(self):
        trace = wire_trace()
        for faults, phase, exit_code, alive in [(['wait-app'], 'wait-app', None, None),
                (['reader-exit-poll'], 'check-reader-exit', 0, None), (['trace'], 'read-trace', 0, True),
                (['fixture-read'], 'read-fixture', 0, True), (['wait-app', 'trace'], 'wait-app', None, None)]:
            with self.subTest(faults=faults):
                r, _ = model_run(*faults, trace=trace)
                self.assertEqual((r['runnerStop'], r['appExit'], r['readerAliveAtAppExit']), (phase, exit_code, alive))
                self.assertEqual(r['trace'], {} if 'trace' in faults else trace)
                self.bound(r, 1)
                self.refused({**r, 'verdict': {**r['verdict'], 'pass': True}})

    def test_session_probe_requires_an_explicit_refusal_to_name_a_reader_or_session_finding(self):
        def refusal(condition):
            # Read the status on the actual guard branch, independently of the Python mapping.
            return lambda cmd: int(cmd.split('if (' + condition + ') {exit ', 1)[1].split('}', 1)[0])

        reader = refusal("[Diagnostics.Process]::GetProcessesByName('Narrator').Length")
        interactive = refusal('-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0')
        for status, phase in [(1, 'probe-session'), (2, 'probe-session'), (3, 'probe-session'), (99, 'probe-session'),
                              (reader, 'require-no-reader'), (interactive, 'require-interactive')]:
            with self.subTest(status=status if isinstance(status, int) else phase):
                r, calls = model_run(probe_exit=status)
                self.assertEqual(calls, ['build', 'temp', 'environment', 'checkout', 'session', 'temp-remove'])
                self.assertEqual((r['runnerStop'], r['cleanupStop']), (phase, None))
                self.assertEqual((r['trace'], r['appExit'], r['readerAliveAtAppExit'], r['fixture']), ({}, None, None, None))
                self.bound(r, 1, current_job=True)

    def test_only_clean_ownership_and_complete_independent_evidence_may_pass(self):
        trace = wire_trace()
        for kwargs, phase in [(dict(app_exit=2, trace=trace), 'check-exit'),
                (dict(reader_at_exit=1, trace=trace), 'check-exit'), ({}, 'require-trace'),
                (dict(prompts=1, trace=trace), 'check-fixture')]:
            with self.subTest(phase=phase):
                r, _ = model_run(**kwargs)
                self.assertEqual(r['runnerStop'], phase)
                self.bound(r, 1)
        for fault, cleanup in [('app-stop', 'stop-app'), ('reader-stop', 'stop-reader'),
                               ('standin-stop', 'stop-standin'), ('temp-remove', 'remove-temp')]:
            r, _ = model_run(fault, trace=trace)
            self.assertEqual((r['runnerStop'], r['cleanupStop']), (None, cleanup))
            self.bound(r, 1)
            self.refused({**r, 'verdict': {**r['verdict'], 'pass': True}})
        r, _ = model_run(trace=trace)
        self.assertEqual((r['receiptVersion'], r['macReference']), (2, MAC_1245))
        self.bound(r, 0, current_job=True)  # synthetic classifier control only
        trace['speech'] = []
        r, _ = model_run(trace=trace)
        self.assertEqual((r['runnerStop'], r['cleanupStop']), (None, None))
        self.bound(r, 1)

    def test_diagnostics_are_closed_and_must_agree_with_the_evidence_and_version(self):
        early, _ = model_run('build')
        late, _ = model_run(trace=wire_trace())
        red = {**late, 'verdict': {**late['verdict'], 'pass': False}}  # not rejected just for a stale green summary
        legacy = {**self.result, 'trace': {}, 'appExit': None, 'readerAliveAtAppExit': None, 'fixture': None,
                  'runnerStop': 'OSError', 'verdict': native.assess({})}
        self.bound(legacy, 1)
        self.refused(legacy, current_job=True)  # current jobs cannot opt out of v2 checks
        for original, changes in [(legacy, dict(runnerStop='SyntheticDetailsError')), (legacy, dict(macReference=MAC_1245)),
                (legacy, dict(cleanupStop=None)), (legacy, dict(receiptVersion=1)), (early, dict(macReference=MAC_1240)),
                (early, dict(mirrorSha='b' * 40)), (early, dict(runId='41')), (early, dict(attempt='2')), (early, dict(receiptVersion=True)),
                (early, dict(receiptVersion=2.0)), (early, dict(receiptVersion=3)), (early, dict(osCode=5)),
                (early, dict(runnerStop='build failed at a path')), (early, dict(runnerStop={'phase': 'verify-build'})),
                (early, dict(runnerStop='OSError')), (early, dict(cleanupStop=['stop-reader'])),
                (early, dict(cleanupStop='remove-temp')), (early, dict(cleanupStop='could not stop reader')),
                (early, dict(fixture=job_checks.CLEAN)), (early, dict(readerAliveAtAppExit=False)),
                (early, dict(runnerStop=None)), (early, dict(runnerStop='read-trace')),
                (early, dict(verdict={**early['verdict'], 'pass': True})), (red, dict(runnerStop='verify-build')),
                (late, dict(cleanupStop='stop-reader')), (red, dict(runnerStop='check-exit')),
                (red, dict(runnerStop='require-trace')), (red, dict(runnerStop='check-fixture')),
                (red, dict(runnerStop='read-trace')), (red, dict(runnerStop='read-fixture')),
                (red, dict(appExit=None, readerAliveAtAppExit=False, runnerStop='wait-app'))]:
            with self.subTest(fields=changes.keys()): self.refused({**original, **changes})
        for missing in ('receiptVersion', 'cleanupStop', 'runnerStop'):
            self.refused({k: v for k, v in early.items() if k != missing})
        for sha, run, attempt in [('not-a-revision', '42', '1'), (SHA, 'arbitrary words', '1'), (SHA, '42', '0')]:
            self.path.write_text(json.dumps(dict(early, mirrorSha=sha, runId=run, attempt=attempt)))
            with self.assertRaises(ValueError): job_checks.check_receipt(self.win, sha, run, attempt, self.output)
            self.assertFalse(self.output.exists())

    def test_named_pre_focus_exceptions_bind_only_as_failures_in_both_formats(self):
        for name in ('Win32Exception', 'ArgumentException', 'NullReferenceException', 'ObjectDisposedException',
                     'KeyNotFoundException', 'InvalidCastException', 'GatewayException', 'InvalidOperationException',
                     'COMException', 'Exception'):
            legacy, current = pre_focus_receipts('fixture-' + name)
            written, _ = model_run(trace=legacy['trace'], history=False)
            self.assertEqual(written, current)
            for r in (legacy, current):
                v2 = 'receiptVersion' in r
                with self.subTest(name=name, v2=v2):
                    self.bound(r, 1, current_job=v2)
                    self.refused({**r, 'verdict': {**r['verdict'], 'pass': True}}, current_job=v2)

    def test_old_class_grammar_is_replay_only_and_new_unknown_types_must_be_redacted(self):
        # GetType().Name need not end in Exception or even be an ASCII identifier (e.g. a generic type).
        for name, legacy_ok in [('FormatException', True), ('OtherGatewayException', True), ('A' * 61 + 'Exception', True),
                                ('A' * 62 + 'Exception', False), ('FixtureFault', False), ('FixtureFault`1', False),
                                ('FäultException', False)]:
            with self.subTest(name=name):
                stop = 'fixture-' + name
                legacy, raw_v2 = pre_focus_receipts(stop)
                if legacy_ok: self.bound(legacy, 1)
                else: self.refused(legacy)
                self.refused(legacy, current_job=True)
                self.refused(raw_v2)  # replaying v2 offline must not switch to the old grammar either
                self.refused(raw_v2, current_job=True)
        legacy, current = pre_focus_receipts('fixture-other-exception')  # a new category is not historical evidence
        self.refused(legacy)
        self.bound(current, 1, current_job=True)

    def test_raw_receipt_never_binds_exception_messages_paths_or_malformed_class_names(self):
        for stop in ('fixture-GatewayException: detail', 'fixture-detail message Exception', r'fixture-C:\test\Win32Exception',
                     'fixture-/tmp/ArgumentException', 'fixture-System.ArgumentException', 'fixture-A|BException',
                     'fixture-A_BException', 'fixture-A;BException', 'fixture-A\x00BException', 'fixture- Win32Exception',
                     'fixture-Win32Exception\r\n', 'fixture-Win\t32Exception', 'fixture-Win３２Exception',
                     'fixture-A\u200bException', 'fixture-A\u00a0Exception', 'fixture-' + 'A' * 62 + 'Exception',
                     'fixture-win32Exception', 'fixture-2Exception', 'fixture-', 'fixture failure with details', {}, 17):
            legacy, current = pre_focus_receipts(stop)
            for r, v2 in ((legacy, False), (current, True)):
                with self.subTest(stop=stop, v2=v2): self.refused(r, current_job=v2)
            # A damaged temporary trace must not turn into an authorized failure category either.
            written, _ = model_run(trace=current['trace'], history=False)
            self.refused(written, current_job=True)

    def test_exception_category_does_not_repair_bindings_or_other_fields(self):
        legacy, current = pre_focus_receipts('fixture-Win32Exception')
        for r, wrong_mac in ((legacy, MAC_1245), (current, MAC_1240)):
            for change in (dict(mirrorSha='b' * 40), dict(runId='41'), dict(attempt='2'), dict(macReference=wrong_mac),
                           dict(trace={**r['trace'], 'detail': 'synthetic'})):
                with self.subTest(v2='receiptVersion' in r, fields=change.keys()):
                    self.refused({**r, **change}, current_job='receiptVersion' in r)
        raw = {**current['trace'], 'stop': 'fixture-other-exception'}
        r, _ = model_run('reader-stop', trace=raw, history=False)
        self.assertEqual((r['trace']['stop'], r['runnerStop'], r['cleanupStop']),
                         ('fixture-other-exception', 'check-fixture', 'stop-reader'))
        self.bound(r, 1, current_job=True)
        for change in (dict(schema=2), dict(appPid=102), dict(narratorPid=304)):
            r, _ = model_run(trace={**raw, **change}, history=False)
            self.assertEqual((r['trace'], r['runnerStop']), ({}, 'read-trace'))  # no foreign exception attributed
            self.bound(r, 1, current_job=True)
        r, _ = model_run(trace={**raw, 'detail': 'synthetic'}, history=False)
        self.refused(r, current_job=True)

    def test_native_stop_vetoes_an_otherwise_complete_trace(self):
        for v2 in (False, True):
            other = 'fixture-other-exception' if v2 else 'fixture-FormatException'
            for stop in ('fixture-Win32Exception', 'fixture-GatewayException', other):
                with self.subTest(v2=v2, stop=stop):
                    trace = {**wire_trace(), 'stop': stop}
                    if v2: r, _ = model_run(trace=trace)
                    else: r = {**self.result, 'trace': trace, 'verdict': native.assess(trace)}
                    self.assertIsNone(r['runnerStop'])
                    self.assertFalse(r['verdict']['pass'])
                    self.bound(r, 1, current_job=v2)
                    self.refused({**r, 'verdict': {**r['verdict'], 'pass': True}}, current_job=v2)

    def test_only_the_pushed_head_can_select_one_proof(self):
        # Data for the selector only; never install a runner environment or call the driver.
        scope = dict(GITHUB_SHA=SHA, GITHUB_JOB='narrator-chat', RUNNER_ARCH='X64')
        head = dict(id=SHA, message=MESSAGE)
        self.assertTrue(job_checks.selected(head, scope))
        self.assertFalse(job_checks.selected(dict(head, id='b' * 40), scope))
        for edits in (dict(GITHUB_JOB='build'), dict(RUNNER_ARCH='ARM64'), dict(HQW_DESKTOP_PROOF='0'),
                      dict(HQW_DESKTOP_PROOF='1'), dict(HQW_NARRATOR_CHAT_DISABLE='stop')):
            with self.subTest(edits=edits): self.assertFalse(job_checks.selected(head, dict(scope, **edits)))
        for msg in ('', SUBJECT, 'Do not run ' + MESSAGE, MESSAGE.upper(), MESSAGE + '\nstop',
                    MESSAGE.replace('only', 'only and screenshots'), MESSAGE.replace('only', 'disabled')):
            with self.subTest(msg=msg): self.assertFalse(job_checks.selected(dict(head, message=msg), scope))

    def test_complete_receipt_is_collectible_and_passes(self):
        self.save()
        self.assertEqual(self.check(), 0)
        self.assertEqual(self.output.read_text().splitlines(), ['bound=true'])

    def test_duplicate_json_keys_cannot_hide_extra_data_in_the_original_bytes(self):
        data = json.dumps(self.result)
        self.path.write_text('{"trace":{"unreviewed":"synthetic"},' + data[1:])
        with self.assertRaises(ValueError): self.check()
        self.assertFalse(self.output.exists())

    def test_no_partial_speech_or_wrong_input_can_turn_the_job_green(self):
        for kind in ('partial speech', 'no speech', 'wrong input'):
            trace = wire_trace()
            if kind == 'partial speech': trace['speech'].pop()
            if kind == 'no speech': trace['speech'] = []
            if kind == 'wrong input': trace['physical'][0]['receivedKey'] = 'Tab'
            with self.subTest(kind=kind):
                self.save(trace=trace, verdict=native.assess(trace))
                self.assertNotEqual(self.check(), 0)
                self.assertEqual(self.output.read_text().splitlines(), ['bound=true'])
                self.output.unlink()
                self.save(trace=trace)  # stale green summary over bad input must not be trusted
                with self.assertRaises(ValueError): self.check()
                self.assertFalse(self.output.exists())

    def test_absent_stale_or_nonfile_receipt_cannot_be_collected(self):
        with self.assertRaises((OSError, ValueError)): self.check()
        self.path.mkdir()  # uploading this as a directory would collect its children
        (self.path / 'other.txt').write_text('synthetic')
        with self.assertRaises(ValueError): self.check()
        self.assertFalse(self.output.exists())

    def test_no_sidecar_or_link_is_collectible(self):
        self.save()
        sidecar = self.path.with_suffix('.txt')
        sidecar.write_text('synthetic')
        with self.assertRaises(ValueError): self.check()
        self.assertFalse(self.output.exists())
        sidecar.unlink()
        outside = self.win / 'elsewhere.json'
        self.path.rename(outside)
        self.path.symlink_to(outside)
        with self.assertRaises(ValueError): self.check()
        self.assertFalse(self.output.exists())

    def test_a_real_early_stop_remains_collectible_but_red(self):
        self.save(trace={}, verdict=native.assess({}), fixture=None, runnerStop='pre-existing Narrator; left alone',
                  appExit=None, readerAliveAtAppExit=None)
        self.assertNotEqual(self.check(), 0)
        self.assertEqual(self.output.read_text().splitlines(), ['bound=true'])

    def test_archive_vocabulary_matches_the_reviewed_native_filter(self):
        desktop = (WIN / 'ci/narrator-chat/NarratorDesktop.cs').read_text(encoding='utf-8')
        walk = (WIN / 'ci/narrator-chat/NarratorChatWalk.cs').read_text(encoding='utf-8')
        vocab = desktop.split('const string vocabulary =', 1)[1].split(';', 1)[0]
        self.assertEqual(job_checks.PHRASE_WORDS, set(''.join(re.findall(r'"([^"]*)"', vocab)).split()))
        self.assertEqual(job_checks.NATIVE_STOPS, set(re.findall(r'new NarratorStop\("([^"]+)"\)', desktop + walk)))

    def test_catch_and_verifier_share_only_the_exact_fixture_exception_categories(self):
        fixture = (WIN / 'ci/narrator-chat/Fixture.cs').read_text(encoding='utf-8')
        helper = fixture.split('internal static class FixtureExceptionStop', 1)[1].split('\n}', 1)[0]
        named = {'fixture-' + name.rsplit('.', 1)[-1] for name in re.findall(r'typeof\(([\w.]+)\)', helper)}
        self.assertEqual(named, job_checks.NATIVE_EXCEPTIONS)
        self.assertIn('catch (Exception e) { walk.Stop = FixtureExceptionStop.From(e); }', fixture)
        self.assertIn('var type = error.GetType();', helper)
        self.assertIn('return Named.Contains(type) ? "fixture-" + type.Name : "fixture-other-exception";', helper)
        for stop in named:
            _, current = pre_focus_receipts(stop)
            self.bound(current, 1, current_job=True)

    def test_unreviewed_fields_or_unattributable_text_never_leave_in_a_nonpass(self):
        for field in ('trace', 'focus', 'physical', 'speech', 'fixture', 'unfiltered phrase', 'unowned phrase'):
            trace = wire_trace()
            fixture = self.result['fixture'].copy()
            if field == 'fixture': fixture['unexpected'] = 'synthetic'
            elif field == 'unfiltered phrase': trace['speech'][0]['text'] = 'outside the synthetic vocabulary'
            elif field == 'unowned phrase': trace['speech'][0]['ownerPid'] = trace['appPid']
            elif field == 'trace': trace['unexpected'] = 'synthetic'
            else: trace[field][0]['unexpected'] = 'synthetic'
            v = native.assess(trace)
            v['pass'] = False
            self.save(trace=trace, fixture=fixture, verdict=v, appExit=2, runnerStop='fixture or Narrator exited unexpectedly')
            with self.subTest(field=field), self.assertRaises(ValueError): self.check()
            self.assertFalse(self.output.exists())

    def test_identity_or_clean_exit_cannot_be_replaced_by_a_green_summary(self):
        for change in (dict(mirrorSha='b' * 40), dict(runId='41'), dict(attempt='2'), dict(macReference=SHA),
                       dict(appExit=1), dict(readerAliveAtAppExit=False), dict(runnerStop='stopped'),
                       dict(fixture=None), dict(extra='unexpected')):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.save(**change)
                self.check()
            self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
