"""Synthetic contract examples, never a recording from a desktop."""
import copy
from contextlib import contextmanager
import hashlib
import http.client
import importlib
import json
from pathlib import Path, PurePosixPath
import sys
import tempfile
import unittest
from typing import Any
from types import SimpleNamespace
from unittest.mock import patch

CI = Path(__file__).resolve().parents[1] / 'ci'
sys.path.insert(0, str(CI))
n = importlib.import_module('narrator_chat')


def model_run(*faults, trace=None, app_exit=0, reader_at_exit=None, probe_exit=0, prompts=0, history=True,
              error: type[Exception] = OSError):
    """Only the post-admission orchestration: no runner identity, files, sockets, processes or sleep."""
    calls, written = [], []
    trace_json = json.dumps(trace)  # the fixture's temporary file, not an already-validated receipt

    def step(name, value=None):
        calls.append(name)
        if name in faults: raise error('synthetic detail that must not enter the receipt')
        return value

    @contextmanager
    def resource(start, end, value):
        step(start)
        try: yield value
        finally: step(end)

    class ModelPath(PurePosixPath):
        def is_file(self):
            assert self.name == 'trace.json'
            return trace is not None

        def stat(self):
            assert self.name == 'trace.json'
            return SimpleNamespace(st_size=len(trace_json.encode('utf-8')))

        def read_text(self, encoding):
            assert self.name == 'trace.json'
            return step('trace', trace_json)

        def write_text(self, text, encoding):
            if self.name == 'seed.json': step('write-seed')  # never retain its contents
            else:
                assert self.name == 'result.json'
                written.append(json.loads(text))

    # Deliberately NOT an admissible environment. No change to os.environ or sys.platform.
    env: dict[str, str] = dict.fromkeys(('GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'RUNNER_OS', 'GITHUB_EVENT_NAME',
                         'GITHUB_REF', 'GITHUB_REPOSITORY', 'GITHUB_EVENT_PATH', 'RUNNER_TEMP', 'SystemRoot'), 'model')
    env.update(GITHUB_SHA='a' * 40, GITHUB_RUN_ID='42', GITHUB_RUN_ATTEMPT='1')
    if 'app-env' in faults: del env['GITHUB_REF']
    ci = ModelPath('/model/windows/ci')
    state = dict(promptAttempts=prompts, upstreamCalls=0, uploads=[],
                 rest=[dict(method='GET', path='/api/sessions/20260929_120000_aabbcc01/messages')] if history else [])
    if 'fixture-read' in faults: del state['rest']
    polls = iter((('reader-start-poll', None), ('reader-exit-poll', reader_at_exit)))
    reader = SimpleNamespace(pid=303, poll=lambda: step(*next(polls)))
    app = SimpleNamespace(pid=101, wait=lambda **kw: step('wait-app', app_exit))

    def command(argv, **kw):
        if argv[0] == 'git': return step('checkout', SimpleNamespace(stdout=env['GITHUB_SHA']))
        assert argv[0].endswith('/powershell.exe')
        status = probe_exit(argv[-1]) if callable(probe_exit) else probe_exit  # inspect the command, never execute it
        return step('session', SimpleNamespace(returncode=status))

    def launch(argv, **kw):
        if argv[0].endswith('/Narrator.exe'): return step('reader-launch', reader)
        assert argv[0].endswith('/HermesHQ.exe')
        return step('app-launch', app)

    def stop(proc):
        assert proc is reader or proc is app
        step('reader-stop' if proc is reader else 'app-stop')

    with patch.multiple(n, _fresh_output=lambda _: ci.parent / 'build/narrator-chat', CI=ci, Path=ModelPath,
            require_build=lambda *_: step('build'), app_environment=lambda *_: step('environment', {}),
            tempfile=SimpleNamespace(TemporaryDirectory=lambda **_: resource('temp', 'temp-remove', 'tmp')),
            standin=lambda: resource('standin', 'standin-stop', ({}, state)), time=SimpleNamespace(sleep=lambda _: None),
            subprocess=SimpleNamespace(run=command, Popen=launch, DEVNULL=-1), stop_owned=stop):
        passed = n.run(env)
    result, = written
    assert passed is result['verdict']['pass']
    return result, calls


def example() -> dict[str, Any]:
    def stop(id, name, role='Button'):
        return {'id': id, 'name': name, 'role': role}
    message = stop('chat.composer', 'Message', 'Edit')
    attach = stop('composer.plus', 'Attach')
    inspector = stop('InspectorToggle', 'Inspector')
    send = stop('chat.send', 'Send')
    focus = [message, attach, inspector, attach, message, message, stop('', 'Model'), send]
    keys = ['Shift+Tab', 'Shift+Tab', 'Tab', 'Tab', 'Q', 'Tab', 'Tab']
    physical: list[dict[str, Any]] = [dict(key=k, receivedKey=k, api='SendInput', inserted=4 if k == 'Shift+Tab' else 2,
                     received=1, focusEvents=0 if k == 'Q' else 1, focusState='Keyboard',
                     frontBefore=201, frontAfter=201) for k in keys]
    physical[4].update(emptyBefore=True, draftAfter='q', sendEnabled=True)
    speech = []
    for i, words in [(0, 'Message, edit, blank'), (2, 'Inspector, toggle button, not pressed'),
                     (4, 'Message, edit, blank'), (7, 'Send, button')]:
        n = 100 + len(speech)
        speech.append(dict(at=i, source='Narrator.CopyLastPhrase', key='Insert+Ctrl+X', inserted=6,
                           receivedX=0, ownerPid=303, frontBefore=201, frontAfter=201,
                           sequenceBefore=n, sequenceAfter=n + 1, text=words))
    return dict(schema=1, appPid=101, hwnd=201, narratorPid=303, seededMessages=1, completed=True, stop=None,
                focus=focus, physical=physical, speech=speech)


class Contract(unittest.TestCase):
    def assess(self, trace):
        return n.assess(copy.deepcopy(trace))

    def test_missing_actual_utterance_is_not_speech(self):
        r = example()
        r['speech'] = []
        v = self.assess(r)
        self.assertTrue(v['keyboard'])
        self.assertFalse(v['spoken'])
        self.assertFalse(v['pass'])

    def test_wrong_order_is_not_focus_navigation(self):
        r = example()
        r['focus'][2], r['focus'][-1] = r['focus'][-1], r['focus'][2]
        self.assertFalse(self.assess(r)['keyboard'])
        self.assertFalse(self.assess(r)['pass'])

    def test_route_cannot_skip_the_known_attach_button_in_both_directions(self):
        r = example()
        for i in (1, 3): r['focus'][i] = dict(id='', name='Commands', role='Button')
        self.assertFalse(self.assess(r)['keyboard'])

    def test_handler_only_is_not_a_key_action(self):
        r = example()
        r['physical'][3].update(api='FocusManager.TryMoveFocus', inserted=0, received=0)
        self.assertFalse(self.assess(r)['keyboard'])
        self.assertFalse(self.assess(r)['pass'])

    def test_three_distinct_observed_labels_after_input(self):
        v = self.assess(example())
        self.assertTrue(v['pass'], v)
        self.assertEqual(v['macLabels'], {'Inspector': True, 'Message': True, 'Send': True})

    def test_placeholder_is_not_an_exact_mac_accessibility_label(self):
        r = example()
        for s in r['focus']:
            if s['id'] == 'chat.composer': s['name'] = 'Message Proof Hermes'
        for s in r['speech']:
            if s['text'].startswith('Message'): s['text'] = 'Message Proof Hermes, edit'
        v = self.assess(r)
        self.assertTrue(v['spoken'])
        self.assertFalse(v['macLabels']['Message'])
        self.assertFalse(v['pass'])

    def test_recognized_control_identity_does_not_depend_on_its_uia_label(self):
        r = example()
        r['focus'][2]['name'] = ''
        v = self.assess(r)
        self.assertTrue(v['keyboard'])
        self.assertTrue(v['spoken'])
        self.assertFalse(v['macLabels']['Inspector'])
        self.assertFalse(v['pass'])

    def test_spoken_name_can_disagree_with_the_uia_name(self):
        r = example()
        r['speech'][2]['text'] = 'Message Proof Hermes, edit'
        v = self.assess(r)
        self.assertTrue(v['spoken'])
        self.assertTrue(v['macLabels']['Message'])
        self.assertFalse(v['spokenMacLabels']['Message'])
        self.assertFalse(v['pass'])

    def test_observed_wrong_or_mixed_speech_is_not_reported_as_missing(self):
        for words in ('Send, button', 'Message, edit; Inspector, toggle button'):
            r = example()
            r['speech'][2]['text'] = words
            v = self.assess(r)
            self.assertTrue(v['speechObserved']['Message'])
            self.assertFalse(v['spokenMacLabels']['Message'])
            self.assertFalse(v['spoken'])
            self.assertFalse(v['pass'])

    def test_missing_or_intervening_focus_event_is_not_a_keyboard_arrival(self):
        for change in (dict(focusEvents=0), dict(focusEvents=2), dict(focusState='Programmatic'), dict(receivedKey='Tab')):
            with self.subTest(change=change):
                r = example()
                r['physical'][0].update(change)
                self.assertFalse(self.assess(r)['keyboard'])

    def test_unavailable_phrase_and_intervening_clipboard_writes_do_not_count(self):
        for change in (dict(unavailable='not-readable'), dict(sequenceBefore=104, sequenceAfter=105)):
            with self.subTest(change=change):
                r = example()
                r['speech'][-1].update(change)
                self.assertFalse(self.assess(r)['spoken'])

    def test_no_inference_from_uia_current_clipboard_or_other_process(self):
        for edit in (dict(text=None), dict(source='UIA.Name'), dict(sequenceAfter=102),
                     dict(ownerPid=101), dict(ownerPid=0), dict(receivedX=1), dict(inserted=5),
                     dict(at=5), dict(frontAfter=300), dict(text='Send, button'),
                     dict(text='Press Enter to send a message'), dict(text='Message')):
            with self.subTest(edit=edit):
                r = example()
                r['speech'][2].update(edit)
                self.assertFalse(self.assess(r)['spoken'])

    def test_process_start_and_replayed_or_missing_baseline_are_not_output(self):
        for change in ('started', 'baseline', 'replay', 'copied-name'):
            with self.subTest(change=change):
                r = example()
                if change == 'started': r['speech'] = [{'source': 'Narrator.started'}]
                if change == 'baseline': del r['speech'][0]
                if change == 'replay': r['speech'][-1].update(sequenceBefore=100, sequenceAfter=101)
                if change == 'copied-name': r['speech'][0]['text'] = 'Inspector, toggle button'
                self.assertFalse(self.assess(r)['spoken'])

    def test_partial_input_foreign_focus_unobserved_draft_or_abort_never_pass(self):
        for change in ('partial', 'wrong-process', 'no-delivery', 'wrong-key', 'draft', 'role', 'unknown', 'abort'):
            with self.subTest(change=change):
                r = example()
                if change == 'partial': r['physical'][0]['inserted'] = 3
                if change == 'wrong-process': r['physical'][1]['frontBefore'] = 404
                if change == 'no-delivery': r['physical'][0]['received'] = 0
                if change == 'wrong-key': r['physical'][0]['key'] = 'Tab'
                if change == 'draft': r['physical'][4]['draftAfter'] = ''
                if change == 'role': r['focus'][2]['role'] = 'Text'
                if change == 'unknown': r['focus'][1]['id'] = 'approval.yes'
                if change == 'abort': r['stop'] = 'focus-left-app'
                self.assertFalse(self.assess(r)['pass'])

    def test_reject_duplicate_missing_and_trailing_records(self):
        for field in ('focus', 'physical', 'speech'):
            for extend in (False, True):
                with self.subTest(field=field, extend=extend):
                    r = example()
                    if extend: r[field].append(r[field][-1])
                    else: del r[field][-1]
                    self.assertFalse(self.assess(r)['pass'])


class Isolation(unittest.TestCase):
    def test_private_push_gate_refuses_every_other_context(self):
        require_push, MIRROR, REF = n.require_push, n.MIRROR, n.REF
        env = dict(GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='github-hosted', RUNNER_OS='Windows',
                   GITHUB_EVENT_NAME='push', GITHUB_REF=REF, GITHUB_REPOSITORY=MIRROR, GITHUB_SHA='a' * 40,
                   GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1')
        event = dict(repository=dict(private=True, full_name=MIRROR), ref=REF, deleted=False, after='a' * 40)
        require_push(env, 'win32', event)  # pure admission function only; never emulate the runner in run()
        for k, v in dict(GITHUB_ACTIONS='false', RUNNER_ENVIRONMENT='self-hosted', RUNNER_OS='macOS',
                         GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/test',
                         GITHUB_REPOSITORY='example/fork', GITHUB_SHA='123', GITHUB_RUN_ID='unknown',
                         GITHUB_RUN_ATTEMPT='0').items():
            with self.subTest(field=k), self.assertRaises(ValueError): require_push({**env, k: v}, 'win32', event)
        for wrong in [dict(repository=dict(private=False, full_name=MIRROR)), dict(repository={}),
                      dict(repository=dict(private=True, full_name='example/fork')), dict(ref='refs/heads/test'),
                      dict(deleted=True), dict(after='b' * 40)]:
            with self.subTest(payload=list(wrong)), self.assertRaises(ValueError): require_push(env, 'win32', {**event, **wrong})
        with self.assertRaises(ValueError): require_push(env, 'darwin', event)

    def test_off_runner_refuses_before_any_desktop_process_or_seed(self):
        with patch.object(n, 'Path') as path, patch.object(n.subprocess, 'Popen') as child, \
                patch.object(n, 'standin') as seed, self.assertRaises(ValueError):
            n.run({})
        path.assert_not_called()
        child.assert_not_called()
        seed.assert_not_called()

    def test_only_the_opt_in_build_for_this_sha_is_eligible(self):
        require_build = n.require_build
        sha = 'a' * 40
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp)
            (d / 'HermesHQ.exe').write_bytes(b'synthetic apphost')
            (d / 'HermesHQ.dll').write_bytes(b'synthetic entry assembly')
            with self.assertRaises(ValueError): require_build(d, sha)
            stamp = [sha] + [hashlib.sha256((d / f).read_bytes()).hexdigest().upper() for f in ('HermesHQ.exe', 'HermesHQ.dll')]
            (d / 'narrator-chat.build').write_text('\n'.join(stamp) + '\n', encoding='utf-8-sig')
            require_build(d, sha)
            with self.assertRaises(ValueError): require_build(d, 'b' * 40)
            (d / 'HermesHQ.dll').write_bytes(b'other synthetic bytes')
            with self.assertRaises(ValueError): require_build(d, sha)

    def test_unowned_or_malformed_trace_is_never_archived(self):
        read_owned_trace = n.read_owned_trace
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'trace.json'
            for bad in ([], {'appPid': 9, 'narratorPid': 303}, {'appPid': 101, 'narratorPid': 7}):
                path.write_text(json.dumps(bad))
                with self.subTest(bad=bad), self.assertRaises(ValueError): read_owned_trace(path, 101, 303)
            path.write_text(json.dumps(example()))
            self.assertEqual(read_owned_trace(path, 101, 303), example())

    def test_local_standin_serves_the_named_chat_without_any_upstream(self):
        with n.standin() as (seed, state):
            conn = http.client.HTTPConnection('127.0.0.1', seed['port'], timeout=2)
            try:
                conn.request('GET', '/api/profiles')
                missing_session = conn.getresponse()
                self.assertEqual(missing_session.status, 401)
                missing_session.read()
                conn.request('POST', '/auth/password-login', json.dumps(dict(provider='fake', username='fixture', password=seed['phrase'])),
                             {'Content-Type': 'application/json'})
                login = conn.getresponse()
                self.assertEqual(login.status, 200)
                cookies = '; '.join(v.split(';')[0] for v in login.headers.get_all('Set-Cookie', []))
                login.read()
                def get(path):
                    conn.request('GET', path, headers={'Cookie': cookies})
                    response = conn.getresponse()
                    self.assertEqual(response.status, 200)
                    return json.load(response)
                bot = next(p for p in get('/api/profiles')['profiles'] if p['name'] == 'default')
                self.assertEqual(bot['ui_meta']['hermes-bots']['display_name'], 'Proof Hermes')
                sid = bot['canonical_session']['id']
                self.assertEqual(sid, '20260929_120000_aabbcc01')
                self.assertEqual(len(get('/api/sessions/' + sid + '/messages')['messages']), 1)
                self.assertEqual(state['upstreamCalls'], 0)
                self.assertEqual(state['promptAttempts'], 0)
            finally:
                conn.close()


if __name__ == '__main__':
    unittest.main()
