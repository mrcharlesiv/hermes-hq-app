"""Exercise the disposable chat fixture and screenshot evidence, without an app, desktop or external gateway."""
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from typing import Any
import importlib.util
import json
import os
import struct
import sys
import tempfile
import threading
import unittest
import zlib

CI = Path(__file__).resolve().parents[1] / 'ci'
sys.path.insert(0, str(CI))


def load(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None: raise ImportError(name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


images = load('walk_images', CI / 'check_walk_pngs.py')


def fixture() -> Any:
    module = load('reply_fixture', CI / 'fixtures/reply-toast-gateway.py')
    module.configure()
    return module


class ReplyFixtureTests(unittest.TestCase):
    def test_each_fixed_event_has_only_one_fixture_destination_and_no_caller_words(self):
        f = fixture()
        class Sink:
            def __init__(self): self.frames = []
            def send(self, frame): self.frames.append(frame['params'])
        sink = Sink()
        f.base.CLIENTS.add(sink)  # in-memory receiver of the actual wire envelopes emitted by the HTTP fixture
        gateway = f.base.voice.auth.Gateway('fixture-reader', 'synthetic-test-only', True, None)
        handler = f.handler(gateway)
        handler.log_message = lambda *args: None
        with patch.dict(os.environ, GITHUB_RUN_ID='35', GITHUB_RUN_ATTEMPT='2'), ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02}, daemon=True)
            thread.start()
            def call(method, path, data=None):
                c = HTTPConnection('127.0.0.1', server.server_port, timeout=5)
                try:
                    c.request(method, path, data)
                    r = c.getresponse()
                    return r.status, json.loads(r.read())
                finally: c.close()
            try:
                for phase in ('warm', 'away', 'failure', 'cold'):
                    self.assertEqual((200, {'ok': True}), call('POST', '/__toast/' + phase))
                self.assertEqual(['message.complete', 'message.complete', 'error', 'message.complete'], [v['type'] for v in sink.frames])
                runtime = f.rpc('session.resume', {'profile': 'sam'})['session_id']
                self.assertTrue(all(v['session_id'] == runtime for v in sink.frames))
                warm, away, error, cold = [v['payload'] for v in sink.frames]
                self.assertEqual('The draft is ready for review. HQ test 35.2', warm['text'])
                self.assertEqual('The summary is ready too.', away['text'])
                self.assertEqual('timeout', error['error_surface']['code'])
                self.assertEqual('Cold launch check: the notes are ready. HQ test 35.2', cold['text'])
                status, rows = call('GET', '/api/sessions/20260929_120000_aabbcc02/messages')
                self.assertEqual(200, status)
                self.assertEqual([v['text'] for v in (warm, away, cold)], [r['content'] for r in rows['messages'][-3:]])
                count = len(rows['messages'])
                for method, path, data, expected in [('POST', '/__toast/warm?text=other', None, 400),
                        ('POST', '/__toast/warm', b'{}', 400), ('POST', '/__toast/missing', None, 400),
                        ('POST', '/__fixture/unlisted', None, 400), ('GET', '/__toast/warm', None, 404),
                        ('PATCH', '/__toast/warm', b'{}', 405), ('DELETE', '/__toast/warm', None, 405)]:
                    self.assertEqual(expected, call(method, path, data)[0])
                self.assertEqual(4, len(sink.frames))
                self.assertEqual(count, call('GET', '/api/sessions/20260929_120000_aabbcc02/messages')[1]['total'])
                with self.assertRaisesRegex(ValueError, 'read-only'): f.rpc('unknown.write', {})
                self.assertEqual([], f.base.LEDGER)
            finally:
                server.shutdown(); thread.join(timeout=5)
                f.base.CLIENTS.discard(sink)
                self.assertFalse(thread.is_alive())

    def test_stamp_refuses_partial_or_malformed_values_before_constructing_an_event(self):
        f = fixture()
        for bad in (None, '', '0', '02', ' 1', '1\n', '٣', '2' * 21):
            with self.subTest(bad=bad), self.assertRaises(ValueError): f.event('/__toast/warm', '1', bad)
        self.assertIsNone(f.event('/__toast/warm/extra', '1', '2'))


class ScreenshotTests(unittest.TestCase):
    @staticmethod
    def png(filter_type, varied=False, width=100, height=64, corrupt=False, transparent=False):
        # Generate filtered RGB rows in a temporary test directory only, never the runner's evidence output.
        def chunk(tag, data):
            return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
        def paeth(a, b, c):
            p = a + b - c
            return min((a, b, c), key=lambda v: abs(p - v))
        rows = bytearray()
        channels = 4 if transparent else 3
        prev = bytes(channels * width)
        for y in range(height):
            row = bytearray((b'\xa1\x73\xff' + (b'\x00' if transparent else b'')) * width)
            if varied and y == height - 1: row[-channels] = 0
            rows.append(filter_type)
            for x, val in enumerate(row):
                a, b, c = row[x - channels] if x >= channels else 0, prev[x], prev[x - channels] if x >= channels else 0
                predicted = (0, a, b, (a + b)//2, paeth(a, b, c))[filter_type]
                rows.append((val - predicted) & 255)
            prev = row
        compressed = zlib.compress(rows)
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6 if transparent else 2, 0, 0, 0))
                + chunk(b'IDAT', compressed[:-2] if corrupt else compressed) + chunk(b'IEND', b''))

    def test_all_five_filters_refuse_blank_accept_content_and_reject_damaged_or_tiny_shots(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            img = directory / 'fixture.png'
            with self.assertRaisesRegex(ValueError, 'no screenshots'): images.check(directory)
            for filter_type in range(5):
                for varied in (False, True):
                    img.write_bytes(self.png(filter_type, varied))
                    self.assertEqual(varied, images.app_image(img), (filter_type, varied))
            self.assertEqual(1, images.check(directory))
            for data in (self.png(4, True, transparent=True), self.png(0, True, corrupt=True), self.png(1, True, width=4, height=3), self.png(2, True)[:-3], b'not an image'):
                img.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'invalid or blank'): images.check(directory)


if __name__ == '__main__':
    unittest.main()
