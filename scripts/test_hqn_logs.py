#!/usr/bin/env python3
"""Self-check of scripts/hqn-logs.py's performance summary: python3 scripts/test_hqn_logs.py"""
import importlib.util, json, os, pathlib, subprocess, sys, tempfile, time, unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('hqn_logs', HERE / 'hqn-logs.py')
hqn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hqn)

NOW = int(time.time() * 1000)


def note(category, text, dt=0):
    return {'t': NOW - 60_000 + dt, 'k': f'note.{category}', 's': 'n', 'm': text[:120], **({'m2': text[120:]} if len(text) > 120 else {})}


EVENTS = [
    {'t': NOW - 50_000, 'k': 'frames', 's': 'n', 'kd': 'scroll', 'scr': 'show ChatViewController', 'n': 4, 'dur': 4000, 'hit': 40.0,
     'wf': 120, 'mf': 6, 'hz': 120, 'b': 1, 'rs': '0,2.5,8,30'},
    {'t': NOW - 40_000, 'k': 'frames', 's': 'n', 'kd': 'scroll', 'scr': 'show ChatViewController', 'n': 2, 'dur': 1000, 'hit': 0,
     'wf': 17, 'mf': 0, 'hz': 120, 'b': 0, 'rs': '1,1'},
    {'t': NOW - 40_000, 'k': 'frames', 's': 'n', 'kd': 'keyboard', 'scr': 'tab 0', 'n': 1, 'dur': 400, 'hit': 0, 'wf': 9, 'mf': 0,
     'hz': 120, 'b': 0, 'rs': '0'},
    {'t': NOW - 30_000, 'k': 'frames.bad', 's': 'n', 'kd': 'chat.open', 'scr': 'show ChatViewController', 'dur': 600, 'wf': 180,
     'hr': 290.5, 'mf': 20, 'fr': 52, 'hz': 120},
    {'t': NOW - 20_000, 'k': 'main.hang', 's': 'n', 'ms': 400, 'screen': 'open chat', 'ongoing': False},
    {'t': NOW - 19_000, 'k': 'main.hang', 's': 'n', 'ms': 2000, 'screen': 'open chat', 'ongoing': True},
    {'t': NOW - 18_000, 'k': 'main.hang', 's': 'n', 'ms': 2600, 'screen': 'open chat', 'ongoing': False},
    {'t': NOW - 10_000, 'k': 'mk.day', 's': 'n', 'day': '2026-10-14', 'bld': '293', 'sh': 2.3, 'hc': 1, 'hs': 0.4, 'fd': '3/1/0/0/0', 'pk': 210},
    {'t': NOW - 9_000, 'k': 'mk.day', 's': 'n', 'day': '2026-10-24', 'bld': '358', 'pk': 383, 'hi': 371, 'hiOn': 'show ChatViewController'},
    {'t': NOW - 8_000, 'k': 'mem.high', 's': 'n', 'fp': 260, 'fpk': 262, 'scr': 'show ChatViewController'},
    {'t': NOW - 7_000, 'k': 'mem.trim', 's': 'n', 'why': 'warning', 'chats': 2, 'fp': 300, 'fpk': 310, 'scr': 'tab 0'},
    note('sessions', 'reconnect refresh: ok in 340 ms'),
    note('sessions', 'reconnect refresh: ok in 120 ms', 1),
    note('sessions', 'reconnect refresh: failed in 5000 ms', 2),
    note('net', 'connect: tunnel 120 ms, ticket 40 ms, handshake 80 ms, total 260 ms', 3),
    note('net', 'connect: tunnel=300ms ticket=60ms handshake=90ms total=480ms', 4),
    note('net', 'connected after a reconnect: nothing to time', 5),
]


class PerfSummaryTests(unittest.TestCase):
    def test_quantile_matches_the_phone(self):
        self.assertEqual(hqn.quantile([], 0.5), 0.0)
        self.assertEqual(hqn.quantile([5, 1, 3], 0.5), 3)
        self.assertEqual(hqn.quantile(list(range(1, 11)), 0.9), 9)
        self.assertEqual(hqn.quantile([1, 2.5, 30], 0.9), 30)

    def test_connect_lines_are_read_tolerantly(self):
        self.assertEqual(hqn.connect_steps('connect: tunnel 120 ms, ticket 40 ms, handshake 80 ms, total 260 ms'),
                         {'tunnel': 120, 'ticket': 40, 'handshake': 80, 'total': 260})
        self.assertEqual(hqn.connect_steps('connect: tunnel=300ms ticket=60.5ms')['ticket'], 60.5)
        self.assertIsNone(hqn.connect_steps('reconnect: tunnel 5 ms'))
        self.assertIsNone(hqn.connect_steps('connect: failed'))

    def test_summary(self):
        text = '\n'.join(hqn.perf_summary(EVENTS))
        self.assertIn('== smoothness: 7 moment(s)', text)
        scroll = next(l for l in text.splitlines() if l.strip().startswith('scroll'))
        # Six ratios 0, 1, 1, 2.5, 8, 30: median 1, p90 30, overall 40 ms over 5 s = 8.
        self.assertRegex(scroll, r'show ChatViewController\s+6\s+1\.0\s+30\.0\s+8\.0\s+120 ms\s+1\s+120')
        self.assertIn('bad ', text)
        self.assertIn('chat.open on show ChatViewController: worst frame 180 ms', text)
        self.assertIn('== connections: 2 connect(s), 3 reconnect refresh(es)', text)
        self.assertRegex(text, r'connect total\s+n=2\s+median\s+260 ms\s+p90\s+480 ms')
        self.assertRegex(text, r'reconnect ok\s+n=2\s+median\s+120 ms')
        self.assertIn('== main thread: 2 stall(s) over 0.25 s, 1 unanswered past 2 s', text)
        self.assertIn('2026-10-14 build 293: scroll hitches 2.3 ms/s', text)
        self.assertIn('highest sampled 371 MB on show ChatViewController', text)
        self.assertIn('== memory: 1 high mark(s); highest sampled 300 MB (mem.trim on tab 0', text)
        self.assertIn('260 MB on show ChatViewController (peak this run 262 MB)', text)

    def test_empty_summary(self):
        text = '\n'.join(hqn.perf_summary([]))
        self.assertIn('== smoothness: 0 moment(s)', text)
        self.assertIn('== main thread: 0 stall(s)', text)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as root:
            folder = os.path.join(root, 'HQN_iPhone17_3-0badc0de')
            os.makedirs(folder)
            with open(os.path.join(folder, '2026-10-15.jsonl'), 'w') as f:
                for e in EVENTS:
                    f.write(json.dumps(e) + '\n')
            perf = subprocess.run([sys.executable, str(HERE / 'hqn-logs.py'), '--root', root, '--perf'], capture_output=True, text=True)
            self.assertEqual(perf.returncode, 0, perf.stderr)
            self.assertIn('== smoothness', perf.stdout)
            self.assertNotIn('log lines', perf.stdout)
            full = subprocess.run([sys.executable, str(HERE / 'hqn-logs.py'), '--root', root], capture_output=True, text=True)
            self.assertEqual(full.returncode, 0, full.stderr)
            for part in ('crash/hang record(s)', '== smoothness', '== last 6 log lines'):
                self.assertIn(part, full.stdout)


    def test_devices(self):
        with tempfile.TemporaryDirectory() as root:
            for name, events in (('HQN_iPhone19_2-00000001', EVENTS),
                                 ('HQN_arm64-00000002', [{'t': NOW - 5_000, 'k': 'main.hang', 's': 'n', 'ms': 1500, 'screen': 'Bots'}])):
                os.makedirs(os.path.join(root, name))
                with open(os.path.join(root, name, '2026-10-24.jsonl'), 'w') as f:
                    for e in events:
                        f.write(json.dumps(e) + '\n')
            run = lambda *a: subprocess.run([sys.executable, str(HERE / 'hqn-logs.py'), '--perf', *a], capture_output=True, text=True).stdout
            both = run('--root', root)
            self.assertIn('== device(s): Mac-00000002, iPhone19_2-00000001', both)
            self.assertIn('[Mac-00000002] Bots', both)
            self.assertIn('[iPhone19_2-00000001] open chat', both)
            self.assertRegex(both, r'scroll\s+show ChatViewController\s+iPhone19_2-00000001\s+6')
            mac = run('--root', root, '--device', 'mac')
            self.assertIn('== main thread: 1 stall(s)', mac)
            self.assertNotIn('[', mac.split('== main thread')[1])   # one device: no tags
            folder = run('--root', os.path.join(root, 'HQN_iPhone19_2-00000001'))
            self.assertIn('== device(s): iPhone19_2-00000001', folder)
            self.assertIn('== main thread: 2 stall(s)', folder)
            self.assertIn('for device "iPad"', run('--root', root, '--device', 'iPad'))


HEADER = 0x10447c000
APP_FRAME = '1 Hermes HQ 0x0000000104a8c123 $s14HermesHQNative4ChatC4openyyF + 40'
MAC_CRASH = [
    {'t': NOW - 30_000, 'k': 'note.launch', 's': 'n', 'm': 'Hermes HQ 1.0 (9999), macOS 26.1, Mac16,10 arm64'},
    {'t': NOW - 20_000, 'k': 'crash.sig', 's': 'n', 'rec': '20261029-073055', 'bld': ''},
    {'t': NOW - 20_000, 'k': 'crash.img', 's': 'n', 'rec': '20261029-073055', 'img': f'App image header {hex(HEADER)}, slide 0x447c000'},
    {'t': NOW - 20_000, 'k': 'crash.why', 's': 'n', 'rec': '20261029-073055', 'lib': 'libswiftCore.dylib',
     'why': 'Swift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range'},
    {'t': NOW - 20_000, 'k': 'crash.frame', 's': 'n', 'rec': '20261029-073055', 'i': 0,
     'f': '0 libsystem_platform.dylib 0x0000000181c497a4 _sigtramp + 56'},
    {'t': NOW - 20_000, 'k': 'crash.frame', 's': 'n', 'rec': '20261029-073055', 'i': 1, 'f': APP_FRAME},
    {'t': NOW - 10_000, 'k': 'main.hang', 's': 'n', 'ms': 1500, 'screen': 'Bots', 'ongoing': False, 'rec': 'a1b2c3', 'bld': '9999',
     'did': 'nothing traced'},
    {'t': NOW - 10_000, 'k': 'main.hang.frame', 's': 'n', 'rec': 'a1b2c3', 'n': 1, 'i': 1, 'b': 'Hermes HQ', 'o': 0x610123, 's': ''},
    {'t': NOW - 10_000, 'k': 'main.hang.frame', 's': 'n', 'rec': 'a1b2c3', 'n': 1, 'i': 0, 'b': 'libsystem_kernel.dylib', 'o': 1234,
     's': 'mach_msg2_trap'},
]


class MacRecordTests(unittest.TestCase):
    def test_the_apps_frames_are_found_by_both_names(self):
        self.assertEqual(hqn.app_offsets([APP_FRAME, '0 UIKitCore 0x00000001ba4fb634 x + 4'], HEADER), [0x610123])
        self.assertEqual(hqn.app_offsets([APP_FRAME.replace('Hermes HQ', 'HermesHQNative')], HEADER), [0x610123])
        self.assertEqual(hqn.app_offsets([APP_FRAME], None), [])
        named = hqn.frame_line(APP_FRAME, HEADER, {0x610123: 'Chat.open() (in Hermes HQ) (Chat.swift:12)'})
        self.assertEqual(named, '1 Hermes HQ 0x0000000104a8c123 Chat.open() (in Hermes HQ) (Chat.swift:12)')
        self.assertEqual(hqn.frame_line(APP_FRAME, HEADER, {}), APP_FRAME)

    def test_mac_and_original_archives_are_found(self):
        with tempfile.TemporaryDirectory() as root:
            main = pathlib.Path(root) / 'hermes-hq-native'
            here = main / '.claude' / 'worktrees' / 'wt'
            here.mkdir(parents=True)
            def archive(base, name, binary):
                path = base / '.build' / name / 'dSYMs' / f'{binary}.app.dSYM' / 'Contents' / 'Resources' / 'DWARF' / binary
                path.parent.mkdir(parents=True)
                path.write_text('')
                return path
            mac = archive(main, 'HQOriginal-mac-447.xcarchive', 'Hermes HQ')
            phone = archive(pathlib.Path(root) / 'hermes-hq-native-wt' / 'ship', 'HQNative-455.xcarchive', 'HermesHQNative')
            self.assertEqual(hqn.dsym('447', True, repo=here), mac)
            self.assertIsNone(hqn.dsym('447', False, repo=here))
            self.assertEqual(hqn.dsym('455', False, repo=here), phone)
            self.assertIsNone(hqn.dsym('', True, repo=here))

    def test_the_build_comes_from_the_last_launch(self):
        events = [dict(e, _device='Mac-1') for e in MAC_CRASH]
        self.assertEqual(hqn.build_at(events, 'Mac-1', NOW), '9999')
        self.assertEqual(hqn.build_at(events, 'Mac-1', NOW - 40_000), '')
        self.assertEqual(hqn.build_at(events, 'iPhone-2', NOW), '')
        self.assertTrue(hqn.is_mac('Mac-00000002') and not hqn.is_mac('iPhone19_2-00000001'))

    def test_a_mac_crash_and_a_sampled_stall_print(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, 'HQN_arm64-00000002'))
            with open(os.path.join(root, 'HQN_arm64-00000002', '2026-10-29.jsonl'), 'w') as f:
                for e in MAC_CRASH:
                    f.write(json.dumps(e) + '\n')
            out = subprocess.run([sys.executable, str(HERE / 'hqn-logs.py'), '--root', root], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            text = out.stdout
            self.assertIn('why (libswiftCore.dylib): Swift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range', text)
            self.assertIn('   ' + APP_FRAME, text)
            stall = text.split('main-thread stalls')[1]
            self.assertIn('main thread, sample 1:', stall)
            lines = [l.strip() for l in stall.splitlines()]
            first = lines.index('0 libsystem_kernel.dylib +0x4d2 mach_msg2_trap')
            self.assertTrue(lines[first + 1].startswith('1 Hermes HQ +0x610123'), lines[first:first + 2])


if __name__ == '__main__':
    unittest.main()
