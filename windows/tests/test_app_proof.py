"""Check the scoped Windows walk contract, never running an app or altering the host."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

CI = Path(__file__).resolve().parents[1] / 'ci'
sys.path.insert(0, str(CI))
import app_proof as proof


class AppProofTests(unittest.TestCase):
    def test_only_exact_disposable_push_runner_is_admitted(self):
        expected = dict(GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='github-hosted', RUNNER_OS='Windows',
                        GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/feat/windows',
                        GITHUB_REPOSITORY='mrcharlesiv/hermes-hq-windows')
        proof.require_runner(expected, 'win32')
        for key in expected:
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.require_runner({**expected, key: 'other'}, 'win32')
        with self.assertRaises(ValueError):
            proof.require_runner(expected, 'darwin')

    def test_manifest_contains_only_the_named_app_walks(self):
        expected = {'composer': ('open-quickly', 'chat-find'), 'settings': ('settings-file',),
                    'groups': ('group-room',), 'sessions': ('new-chat-here',),
                    'keyboard-only': ('keyboard-only',), 'a11y-audit': ('a11y-audit',)}
        self.assertEqual(expected, {s.tag: s.walks for s in proof.SUITES})
        for s in proof.SUITES:
            self.assertTrue((CI / 'fixtures' / s.script).is_file())
            self.assertTrue(set(s.walks).issubset(s.shots))
        shots = {name for s in proof.SUITES for name in s.shots}
        self.assertTrue({'open-quickly-settings', 'open-quickly-settings-opened', 'chat-find-closed',
                         'settings-file-search-clear-models', 'new-chat-here-home'}.issubset(shots))

    def test_app_process_only_inherits_required_platform_settings(self):
        parent = dict(PATH='test-path', SystemRoot='system', OTHER_PRIVATE_SETTING='stand-in',
                      HTTPS_PROXY='test-proxy', GITHUB_ENV='ci', HQW_AUTOMATION='old', HQW_APP_PROOF='0')
        self.assertEqual({'PATH': 'test-path', 'SystemRoot': 'system', 'HQW_AUTOMATION': 'fixture.json',
                          'HQW_APP_PROOF': '1'}, proof.app_environment(parent, Path('fixture.json')))

    def test_extra_takes_identity_only_from_its_own_loopback_standin(self):
        s = proof.SUITES[0]
        root = f'http://127.0.0.1:{s.port}'
        valid = dict(url=root, username='synthetic', password='test stub', other='ignored')
        self.assertEqual({'url': root, 'username': 'synthetic', 'password': 'test stub',
                          'tag': s.tag, 'places': [], 'walks': list(s.walks)}, proof.extra(s, valid))
        for url in ('https://example.invalid', root + '/else', 'http://127.0.0.1:1', root + '@example.invalid'):
            with self.assertRaises(ValueError):
                proof.extra(s, {**valid, 'url': url})
        for key in ('username', 'password'):
            with self.assertRaises(ValueError):
                proof.extra(s, {**valid, key: ''})

    @staticmethod
    def png(width=64, height=48, flat=False, edge=255):
        # An in-memory unit-test pattern, not a capture of any app.
        def chunk(tag, data):
            return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
        row = b'\x00' + bytes((width - 1) * 3) + bytes([0 if flat else edge]) * 3
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b''))

    def test_each_host_requires_its_own_narrow_and_expanded_find_images(self):
        for tag, prefix in (('composer', 'chat-find'), ('groups', 'group-room-find')):
            suite = next(s for s in proof.SUITES if s.tag == tag)
            frames = [prefix + '-' + width for width in ('narrow', 'expanded')]
            with tempfile.TemporaryDirectory() as td:
                root = Path(td)
                events = ['extras only']
                for walk in suite.walks:
                    events.extend([f'{tag} walk {walk}', f'{tag} walk {walk} finished'])
                (root / 'automation.log').write_text('\n'.join(events + ['done']), encoding='utf-8')
                (root / 'hermes-hq.log').write_text('[automation] app-only: desktop notifications excluded\n', encoding='utf-8')
                def pixels(name): return self.png(edge=170 if name.endswith('-expanded') else 255)
                for name in {*suite.shots, *frames}:
                    (root / ('02-' + name + '.png')).write_bytes(pixels(name))
                proof.check_evidence(root, (suite,))
                for frame in frames:
                    path = root / ('02-' + frame + '.png')
                    for problem in ('missing', 'wrong prefix', 'duplicate', 'truncated', 'blank', 'tiny'):
                        with self.subTest(frame=frame, problem=problem):
                            if problem == 'missing': path.unlink()
                            elif problem == 'wrong prefix': path.rename(root / ('lookalike-' + frame + '.png'))
                            elif problem == 'duplicate': (root / ('03-' + frame + '.png')).write_bytes(self.png())
                            elif problem == 'truncated': path.write_bytes(self.png()[:-7])
                            elif problem == 'blank': path.write_bytes(self.png(flat=True))
                            else: path.write_bytes(self.png(2, 1))
                            try:
                                with self.assertRaisesRegex(ValueError, frame): proof.check_evidence(root, (suite,))
                            finally:
                                for other in ('03-', 'lookalike-'):
                                    (root / (other + frame + '.png')).unlink(missing_ok=True)
                                path.write_bytes(pixels(frame))
                (root / ('02-' + frames[1] + '.png')).write_bytes(pixels(frames[0]))
                with self.subTest(tag=tag, problem='same capture twice'), self.assertRaisesRegex(ValueError, prefix):
                    proof.check_evidence(root, (suite,))

    def test_missing_or_damaged_shots_unfinished_walk_and_page_failure_cannot_pass(self):
        s = proof.SUITES[0]
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            events = ['extras only']
            for walk in s.walks:
                events += [f'{s.tag} walk {walk}', f'{s.tag} walk {walk} finished']
            def record(lines):
                (out / 'automation.log').write_text(''.join('12:34:56.123 ' + row + '\n' for row in lines), encoding='utf-8')
            record(events + ['done'])
            app = out / 'hermes-hq.log'
            isolated = '[automation] app-only: desktop notifications excluded\n'
            app.write_text(isolated, encoding='utf-8')
            for i, name in enumerate(s.shots):
                (out / f'{i:02d}-{name}.png').write_bytes(self.png(edge=170 if name.endswith('-expanded') else 255))
            proof.check_evidence(out, (s,))
            img = out / f'00-{s.shots[0]}.png'
            img.unlink()
            with self.assertRaises(ValueError): proof.check_evidence(out, (s,))
            img.write_bytes(self.png()[:-7])
            with self.assertRaises(ValueError): proof.check_evidence(out, (s,))
            img.write_bytes(self.png())
            for bad in (events[:-1] + ['done'], events + ['done', 'groups failed: fixture error'],
                        events + ['done', 'shot chat-find failed: no window'], events[1:] + ['done']):
                record(bad)
                with self.assertRaises(ValueError): proof.check_evidence(out, (s,))
            record(events + ['done'])
            for bad in ('ordinary startup\n', isolated + "[ui] couldn't open a page\n",
                        isolated + '[unhandled] NullReferenceException: fixture error\n'):
                app.write_text(bad, encoding='utf-8')
                with self.assertRaises(ValueError): proof.check_evidence(out, (s,))

    def test_app_only_neither_registers_desktop_alerts_nor_sends_input_outside_its_window(self):
        app = CI.parent / 'src/HermesHQ.Windows'
        run = (CI / 'app_proof.py').read_text(encoding='utf-8')
        automation = (app / 'Services/Automation.cs').read_text(encoding='utf-8')
        notify = (app / 'Features/Notifications/NotificationsFeature.cs').read_text(encoding='utf-8')
        keys = (app / 'Services/ProofWalks.cs').read_text(encoding='utf-8')
        self.assertIn("env['HQW_APP_PROOF'] = '1'", run)
        self.assertIn('Enabled && Environment.GetEnvironmentVariable("HQW_APP_PROOF") == "1"', automation)
        self.assertIn('AppOnly && !extrasOnly', automation)
        self.assertNotIn('SaveScreenAsync', automation)
        self.assertIn('await SaveAsync(ShotOf ?? (UIElement)window.Content, file)', automation)
        register = notify.split('public static void Register()', 1)[1].split('ChatExtensions.OnOpen.Add', 1)[0]
        self.assertIn('if (Automation.AppOnly)', register)
        self.assertIn('return;', register)
        self.assertIn('if (InFront() || Automation.AppOnly) return;', keys)
        self.assertIn('Eligible(target) && SendInput', keys)
        self.assertIn('return GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(target)', keys)
        pointer = keys.split('public static void Click(FrameworkElement element)', 1)[1].split('Keys.Front()', 1)[0]
        self.assertIn('if (Automation.AppOnly) throw', pointer)
        state = (app / 'Services/AppState.cs').read_text(encoding='utf-8')
        self.assertIn('Automation.AppOnly ? new MemoryTokenStore() : new CredentialLockerStore()', state)

    def test_workflow_cannot_run_the_desktop_suite_or_export_login_files(self):
        workflow = (CI / 'app-proof.yml').read_text(encoding='utf-8')
        for required in ('contents: read', 'app_proof.py', 'Category!=E2E', 'dotnet publish',
                         'timeout-minutes: 25', 'windows/build/shots/*.png', 'windows/build/shots/automation.log'):
            self.assertIn(required, workflow)
        for forbidden in ('workflow_dispatch', 'pull_request', 'self-hosted', 'toast-click', 'medium-integrity',
                          'high-contrast.ps1', 'runner-dnd', 'windows/ci/windows.yml', 'windows/build/fixtures',
                          'windows/build/app\n          path:', 'secrets.', 'windows/build/**'):
            self.assertNotIn(forbidden, workflow)


if __name__ == '__main__':
    unittest.main()
