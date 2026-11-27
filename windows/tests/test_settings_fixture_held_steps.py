"""[WIN-STEPS-AFTER-REPLY] A turn the settings stand-in holds on a step saves that step as Hermes does: the assistant row
calling it and its tool row, before the reply's words, so a finished reply's steps come back on the next read (the Mac's
inspector reads them from the stored turn). Synthetic only."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


path = Path(__file__).resolve().parents[1] / 'ci' / 'fixtures' / 'settings-gateway.py'
spec = importlib.util.spec_from_file_location('settings_fixture_held', path)
assert spec is not None and spec.loader is not None
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ReleasedAtOnce:
    """The release gate, already open: the held turn goes straight on."""
    def set(self):
        pass

    def wait(self, _timeout=None):
        return True


class HeldStepIsStored(unittest.TestCase):
    def setUp(self):
        self.addCleanup(patch.stopall)
        patch.object(fixture, 'S', fixture.seed()).start()
        self.events = patch.object(fixture, 'emit').start()
        patch.object(fixture.time, 'sleep', lambda _s: None).start()
        patch.object(fixture.threading, 'Event', ReleasedAtOnce).start()
        self.chat = fixture.S['profiles']['ivy']['chat']

    def test_held_turn_saves_its_step_before_the_words(self):
        before = len(self.chat['messages'])
        step = {'name': 'terminal', 'args': {'command': 'cd /Users/me/app && npm test'}}
        fixture.stream_intro('ivy', self.chat, 'Synthetic test run, please', step, 7)
        added = self.chat['messages'][before:]
        self.assertEqual([m['role'] for m in added], ['assistant', 'tool', 'assistant'])
        call = added[0]['tool_calls'][0]
        self.assertEqual(call['id'], 'call_hold_7')
        self.assertEqual(call['function']['name'], 'terminal')
        self.assertEqual(json.loads(call['function']['arguments']), step['args'])
        self.assertEqual(added[0]['content'], '')
        self.assertEqual((added[1]['tool_call_id'], added[1]['content']), ('call_hold_7', 'ok'))
        self.assertEqual(added[2]['content'], "Hi! I'm Ivy.")
        # The wire's turn: the step starts and completes, then the words; the end names the words' row.
        kinds = [c.args[1] for c in self.events.call_args_list]
        self.assertEqual(kinds, ['message.start', 'tool.start', 'tool.complete', 'message.delta', 'message.complete'])
        self.assertEqual(self.events.call_args_list[-1].args[2]['row_id'], len(self.chat['messages']))
        # The Sessions row's preview stays the reply's words.
        self.assertEqual(fixture.session_row('ivy', self.chat)['preview'], "Hi! I'm Ivy.")

    def test_a_turn_not_held_saves_the_words_alone(self):
        before = len(self.chat['messages'])
        fixture.stream_intro('ivy', self.chat, 'hello')
        self.assertEqual([m['role'] for m in self.chat['messages'][before:]], ['assistant'])


if __name__ == '__main__':
    unittest.main()
