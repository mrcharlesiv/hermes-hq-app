#!/usr/bin/env python3
"""[m9/ipad] The performance stand-in gateway plus one control call for the iPad UI tests.

The reference script (ref238 scripts/performance-fixture-gateway.py, read only) keeps reply plans in one queue for
the whole run and POST /__fixture/plan only ADDS to it. A test that queued a plan and did not use it (it failed
early, or the runner died) therefore handed its plan to the next test's first message: a 100 second reply where a
two word one was expected, so "Return sends" / "Command-Return sends" failed in the test after it (stress round 1
and the repair run). This wrapper adds POST /__fixture/clear-plans, which empties the queue; `IPad.plan` in
UITests/ipad/IPadSupport.swift calls it before queueing its own. Same arguments as the reference script.
Binds 127.0.0.1 only; invented credentials; never talks to a real gateway.
"""
import importlib.util
import os
import pathlib
import sys

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
path = REF / 'scripts' / 'performance-fixture-gateway.py'
spec = importlib.util.spec_from_file_location('performance_fixture', path)
perf = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(path.parent))
spec.loader.exec_module(perf)
base = perf.base
inner = base.handler


def handler(gateway):
    parent = inner(gateway)

    class Handler(parent):
        def do_POST(self):
            if self.path == '/__fixture/clear-plans':
                self.rfile.read(int(self.headers.get('Content-Length') or 0))
                with base.LOCK:
                    dropped = len(base.PLANS)
                    base.PLANS.clear()
                return self.reply(200, {'ok': True, 'dropped': dropped})
            return super().do_POST()
    return Handler


base.handler = handler
if __name__ == '__main__':
    base.main()
