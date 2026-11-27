"""Offline readback of synthetic log lines only. No runner variables, app, desktop or activation helper."""
from pathlib import Path
import sys
import tempfile
import unittest

CI = Path(__file__).resolve().parents[1] / 'ci'
sys.path.insert(0, str(CI))
import check_toast_quiet as quiet

STAMP, SHA = '27.2', '1234567890abcdef1234567890abcdef12345678'
LOG = '2026-01-02 03:04:05.006 [automation] '
START, FINISH = LOG + 'toasts walk toasts', LOG + 'toasts walk toasts finished'
READY = LOG + 'walk toasts: cold toast left for chat key 1234cdef run ' + STAMP
NO_COLD = LOG + 'walk toasts: cold: open gap: missing synthetic reply'


def record(phase):
    return (LOG + f'walk toasts: toast-quiet/v1 run={STAMP} sha={SHA} phase={phase} '
            'quns=QUNS_ACCEPTS_NOTIFICATIONS focus=off app=Enabled writes=0 restore=not-needed '
            'banner=unverified gap=banner-not-observed')


def complete(verdict=READY):
    return [START, *(record(p) for p in quiet.PHASES), verdict, FINISH]


class QuietReadbackTests(unittest.TestCase):
    def test_one_complete_walk_in_file_order_never_attests_a_banner(self):
        lines = complete()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def save(name, rows):
                (root / name).write_bytes(('\r\n'.join(rows) + '\r\n').encode())
            save('hermes-hq.log.1', lines[:3]); save('hermes-hq.log', lines[3:])
            save('hermes-hq.log.2', ['not part of this walk']); save('automation.log', [FINISH])
            self.assertIsNone(quiet.check(quiet.current_lines(root), STAMP, SHA))
            save('hermes-hq.log.1', lines[3:]); save('hermes-hq.log', lines[:3])
            with self.assertRaises(quiet.Gap): quiet.check(quiet.current_lines(root), STAMP, SHA)
            (root / 'hermes-hq.log').unlink(); save('hermes-hq.log.1', lines)
            with self.assertRaises(FileNotFoundError): quiet.check(quiet.current_lines(root), STAMP, SHA)

    def test_all_known_suppressions_can_continue_but_do_not_require_a_cold_reply(self):
        for old, new, reason in [('focus=off', 'focus=priority-only', 'focus-quiet'),
                                 ('focus=off', 'focus=alarms-only', 'focus-quiet'),
                                 ('QUNS_ACCEPTS_NOTIFICATIONS', 'QUNS_QUIET_TIME', 'shell-not-accepting'),
                                 ('app=Enabled', 'app=DisabledForUser', 'app-not-enabled')]:
            with self.subTest(new=new):
                quiet.check([s.replace(old, new).replace('gap=banner-not-observed', 'gap=' + reason)
                             for s in complete(NO_COLD)], STAMP, SHA)

    def test_missing_duplicate_stale_malformed_out_of_order_and_foreign_records_refuse(self):
        good = complete()
        bad = ([*good, good[1]], good[1:], good[:-1], [*good[:-2], FINISH, READY],
               [START, READY, *good[1:5], FINISH], [*good[:-1], NO_COLD, FINISH],
               [*good[:2], good[3], good[2], *good[4:]], [*good, START], good + good,
               ['[http] copied ' + line for line in good])
        for rows in (*bad, *(good[:i] + good[i+1:] for i in range(1, 6))):
            with self.subTest(rows=rows), self.assertRaises(quiet.Gap): quiet.check(rows, STAMP, SHA)
        for old, new in [('run=27.2', 'run=27.1'), ('run=27.2', 'run=unbound'), (SHA, '0'*40),
                         ('quns=QUNS_ACCEPTS_NOTIFICATIONS', 'quns=not-read'), ('app=Enabled', 'app=unknown'),
                         ('focus=off', 'focus=unpublished'), ('focus=off', 'focus=discarded'),
                         ('phase=entry', 'phase=guard-b'), ('writes=0', 'writes=1'),
                         ('restore=not-needed', 'restore=restored'), ('banner=unverified', 'banner=shown'),
                         ('gap=banner-not-observed', 'gap=focus-quiet'), ('toast-quiet/v1', 'toast-quiet/v2'),
                         ('[automation]', '[another-area]'), (LOG, LOG + 'quoting: '),
                         ('gap=banner-not-observed', 'gap=banner-not-observed extra=private-canary')]:
            rows = good.copy(); rows[1] = rows[1].replace(old, new)
            with self.subTest(new=new), self.assertRaises(quiet.Gap) as stopped: quiet.check(rows, STAMP, SHA)
            self.assertNotIn('private-canary', str(stopped.exception))
        for stamp, sha in [('27.02', SHA), ('27.２', SHA), ('', SHA), (STAMP, '0'*40), (STAMP, SHA.upper())]:
            with self.subTest(stamp=stamp, sha=sha), self.assertRaises(quiet.Gap): quiet.check(good, stamp, sha)

    def test_stop_anywhere_preserves_only_a_known_phase_and_reason(self):
        for phase, gap in [('plan', 'plan-unreadable'), ('entry', 'not-reply-walk'), ('before-first', 'focus-unknown'),
                           ('before-away', 'foreground-unverified'), ('after-away', 'sample-context-lost'),
                           ('guard-a', 'not-reply-walk'), ('guard-b', 'runner-not-authorized'), ('walk', 'reply-walk-incomplete')]:
            stop = LOG + f'walk toasts: toast-quiet-stop/v1 phase={phase} gap={gap}'
            for prefix, suffix in [([], []), (complete(), []), (complete()[:2], complete()[2:])]:
                with self.subTest(phase=phase), self.assertRaisesRegex(quiet.Gap, f'^phase={phase} gap={gap}$'):
                    quiet.check([*prefix, stop, *suffix], STAMP, SHA)
        with self.assertRaisesRegex(quiet.Gap, '^malformed-stop$'):
            quiet.check([*complete(), LOG + 'walk toasts: toast-quiet-stop/v1 phase=walk gap=private-canary'], STAMP, SHA)

    def test_guard_refusal_is_not_a_measurement_even_without_the_terminal_log_write(self):
        guard = record('guard-a').replace('gap=banner-not-observed', 'gap=foreground-unverified')
        with self.assertRaisesRegex(quiet.Gap, '^phase=guard-a gap=foreground-unverified$'):
            quiet.check([*complete(), guard], STAMP, SHA)

    def test_supplementary_foreground_class_neither_changes_a_refusal_nor_substitutes_for_a_sample(self):
        for states, gap in [('not-read', 'foreground-unverified'), ('discarded', 'sample-context-lost')]:
            sample = (LOG + f'walk toasts: toast-quiet/v1 run={STAMP} sha={SHA} phase=entry '
                      f'quns={states} focus={states} app={states} writes=0 restore=not-needed banner=unverified gap={gap}')
            detail = LOG + 'walk toasts: fixture-foreground/v1 phase=entry clause=OpenPopup'
            stop = LOG + f'walk toasts: toast-quiet-stop/v1 phase=entry gap={gap}'
            for rows in ([START, sample, stop], [START, sample, detail, stop], [START, sample, detail]):
                with self.subTest(states=states), self.assertRaisesRegex(quiet.Gap, f'^phase=entry gap={gap}$'):
                    quiet.check(rows, STAMP, SHA)
            for rows in ([detail], [START, detail, *complete()[2:]]):
                with self.assertRaises(quiet.Gap): quiet.check(rows, STAMP, SHA)

    def test_ready_verdict_itself_must_be_fresh_unique_and_inside_the_walk(self):
        for verdict in [READY + ' trailing', READY.replace(STAMP, '27.1'), READY.replace('1234cdef', 'not-a-key'),
                        NO_COLD.replace('open gap: ', ''), LOG + 'copied: ' + READY]:
            with self.subTest(verdict=verdict), self.assertRaises(quiet.Gap): quiet.check(complete(verdict), STAMP, SHA)


if __name__ == '__main__':
    unittest.main()
