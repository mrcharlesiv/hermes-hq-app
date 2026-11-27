"""The synthetic group gateway must not deliver an already stopped member's reply."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


path = Path(__file__).resolve().parents[1] / 'ci' / 'fixtures' / 'settings-gateway.py'
spec = importlib.util.spec_from_file_location('settings_fixture', path)
assert spec is not None and spec.loader is not None
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FixtureStop(unittest.TestCase):
    def setUp(self):
        self.addCleanup(patch.stopall)
        patch.object(fixture, 'GROUP_ROOMS', True).start()
        patch.object(fixture, 'S', fixture.seed()).start()
        self.session = {'id': 'fixture-group', 'profile': 'ivy', 'title': 'Group', 'messages': [], 'running': False}
        fixture.S['group_sessions']['room'] = self.session
        self.pending = []
        self.events = patch.object(fixture, 'emit').start()
        self.client = fixture.Client(None)
        self.client.send = lambda reply: self.assertIn('result', reply)
        queue = self.pending

        class DeferredThread:
            def __init__(self, *, target, args, daemon):
                self.run = lambda: target(*args)

            def start(self):
                queue.append(self.run)

        patch.object(fixture.threading, 'Thread', DeferredThread).start()

    def submit(self, text):
        self.client.answer({'id': 1, 'method': 'prompt.submit',
                            'params': {'session_id': self.session['id'], 'text': text}})

    def stop(self):
        self.assertEqual(fixture.rpc('session.interrupt', {'session_id': self.session['id']})['status'], 'interrupted')

    def test_stop_after_submit_receipt_before_stream_starts(self):
        self.submit('first'); self.stop()
        self.pending.pop(0)()
        self.assertEqual([m['role'] for m in self.session['messages']], ['user'])
        self.assertFalse(self.session['running'])
        self.events.assert_not_called()

    def test_replacement_round_owns_its_running_flag_and_only_reply(self):
        self.submit('first'); self.stop(); self.submit('second')
        self.pending.pop(0)()
        self.assertTrue(self.session['running'])
        self.events.assert_not_called()
        self.pending.pop(0)()
        self.assertEqual([m['role'] for m in self.session['messages']], ['user', 'user', 'assistant'])
        self.assertFalse(self.session['running'])
        self.assertEqual([c.args[1] for c in self.events.call_args_list], ['message.start', 'message.delta', 'message.complete'])

    def test_stop_after_start_does_not_emit_delta_or_completion(self):
        self.submit('first')
        self.events.side_effect = lambda _id, kind, *_args: self.stop() if kind == 'message.start' else None
        self.pending.pop(0)()
        self.assertEqual([c.args[1] for c in self.events.call_args_list], ['message.start'])
        self.assertEqual([m['role'] for m in self.session['messages']], ['user'])
        self.assertFalse(self.session['running'])


if __name__ == '__main__':
    unittest.main()
