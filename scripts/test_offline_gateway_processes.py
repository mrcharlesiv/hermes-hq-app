#!/usr/bin/env python3
"""The loopback gateway's scheduled jobs and chat processes have independent stores."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('offline_fixture', pathlib.Path(__file__).parent / 'fixtures/offline-gateway.py')
assert spec is not None and spec.loader is not None
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class OfflineProcessesTests(unittest.TestCase):
    def setUp(self):
        fixture.seed()
        self.chat = fixture.bot_chat_id('default')
        self.other = fixture.bot_chat_id('research')
        self.handler = object.__new__(fixture.handler(None, control_only=True))
        self.handler.reply = lambda status, data: status

    def post(self, route, data):
        self.handler.body_json = lambda: data
        self.assertEqual(self.handler.control('POST', '/__fixture/' + route), 200)

    def rows(self, chat):
        return fixture.rpc('process.list', {'session_id': chat})['processes']

    def test_running_work_is_scoped_to_its_chat(self):
        self.post('work', {'session_id': self.chat, 'processes': ['work-1']})
        self.assertEqual([r['session_id'] for r in self.rows(fixture.runtime(self.chat))], ['work-1'])
        self.assertEqual(self.rows(self.other), [])
        self.post('work/end', {'processes': ['work-1']})
        self.assertEqual(self.rows(self.chat), [])

    def test_job_rows_and_live_work_do_not_replace_scheduled_jobs(self):
        schedules = list(fixture.JOBS)
        self.assertTrue(schedules)
        self.post('work', {'session_id': self.chat, 'processes': ['work-1']})
        self.post('jobs', {'session_id': self.chat, 'processes': [{'session_id': 'job-1'}]})
        self.assertEqual({r['session_id'] for r in self.rows(self.chat)}, {'work-1', 'job-1'})
        self.assertEqual(self.rows(self.other), [])
        self.assertEqual(fixture.JOBS, schedules)
        fixture.seed()
        self.assertEqual(self.rows(self.chat), [])
        self.assertEqual(len(fixture.JOBS), len(schedules))


if __name__ == '__main__':
    unittest.main()
