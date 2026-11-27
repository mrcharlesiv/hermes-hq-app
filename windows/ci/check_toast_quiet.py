"""Read the first app's own two logs before the separate cold verdict. Never launch, restore or write."""
from pathlib import Path
import os
import re

PHASES = ('entry', 'before-first', 'before-away', 'after-away')
SHELL = {'QUNS_NOT_PRESENT', 'QUNS_BUSY', 'QUNS_RUNNING_D3D_FULL_SCREEN', 'QUNS_PRESENTATION_MODE',
         'QUNS_ACCEPTS_NOTIFICATIONS', 'QUNS_QUIET_TIME', 'QUNS_APP'}
APP = {'Enabled', 'DisabledByManifest', 'DisabledByGroupPolicy', 'DisabledForUser', 'DisabledForApplication',
       'Unsupported', 'Unregistered'}
STOP_PHASES = {*PHASES, 'runner', 'plan', 'dispatch', 'walk', 'guard-a', 'guard-b', 'invalid'}
STOP_REASONS = {'runner-not-authorized', 'non-windows', 'plan-unreadable', 'not-reply-walk', 'route-not-unique',
                'reply-walk-incomplete', 'foreground-unverified', 'focus-unknown', 'shell-state-unknown',
                'app-setting-unknown', 'sample-context-lost', 'readback-unrecorded', 'entry-required',
                'checkpoint-out-of-order', 'invalid-phase'}
LOG = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} \[automation\] (.*)')
PREFIX = 'walk toasts: '
SAMPLE = re.compile(r'toast-quiet/v1 run=(\S+) sha=(\S+) phase=(\S+) quns=(\S+) focus=(\S+) app=(\S+) '
                    r'writes=0 restore=not-needed banner=unverified gap=(\S+)')
STOP = re.compile(r'toast-quiet-stop/v1 phase=(\S+) gap=(\S+)')


class Gap(ValueError):
    """Only fixed reason/phase vocabulary may reach the supervisor, never input or exception text."""


def check(lines, stamp, sha):
    if (not re.fullmatch(r'[1-9][0-9]{0,19}\.[1-9][0-9]{0,19}', stamp)
            or not re.fullmatch(r'[a-f0-9]{40}', sha) or sha == '0' * 40):
        raise Gap('unbound-run')
    events = []
    refused_reading = None
    for raw in lines:
        line = LOG.fullmatch(raw.rstrip('\r\n'))
        if not line:
            continue  # a quotation/substring in another log area isn't an automation record
        msg = line[1]
        if msg.startswith(PREFIX + 'toast-quiet'):
            record = msg[len(PREFIX):]
            if record.startswith('toast-quiet-stop'):
                stop = STOP.fullmatch(record)
                if stop and stop[1] in STOP_PHASES and stop[2] in STOP_REASONS:
                    raise Gap(f'phase={stop[1]} gap={stop[2]}')
                raise Gap('malformed-stop')
            sample = SAMPLE.fullmatch(record)
            if sample and sample[3] in STOP_PHASES and sample[7] in STOP_REASONS:
                refused_reading = f'phase={sample[3]} gap={sample[7]}'
            events.append(record)
        elif msg.startswith(PREFIX + 'cold'):
            events.append(msg[len(PREFIX):])
        elif msg in ('toasts walk toasts', 'toasts walk toasts finished'):
            events.append(msg)
    if refused_reading:
        raise Gap(refused_reading)
    if len(events) != len(PHASES) + 3 or events[0] != 'toasts walk toasts' or events[-1] != 'toasts walk toasts finished':
        raise Gap('incomplete-or-duplicate-walk')
    # The ready/gap belongs after the readings and before this walk finished. The workflow still
    # needs its own unique verdict, the exact one-use receipt, clean exit and no live app before cold.
    verdict = events[-2]
    if not (re.fullmatch(r'cold toast left for chat key [0-9a-f]{8} run ' + re.escape(stamp), verdict)
            or re.fullmatch(r'cold: open gap: .+', verdict)):
        raise Gap('missing-or-stale-cold-verdict')
    for phase, event in zip(PHASES, events[1:-2]):
        sample = SAMPLE.fullmatch(event)
        if not sample or sample.group(1, 2, 3) != (stamp, sha, phase):
            raise Gap('malformed-stale-or-unordered-reading')
        shell, focus, app, gap = sample.group(4, 5, 6, 7)
        if shell not in SHELL or focus not in ('off', 'priority-only', 'alarms-only') or app not in APP:
            raise Gap('unknown-measurement')
        expected = ('focus-quiet' if focus != 'off' else 'shell-not-accepting' if shell != 'QUNS_ACCEPTS_NOTIFICATIONS'
                    else 'app-not-enabled' if app != 'Enabled' else 'banner-not-observed')
        if gap != expected:
            raise Gap('inconsistent-reading')


def current_lines(log_dir):
    # Fresh LOCALAPPDATA was required before the normal launch. Never glob, use automation.log as a
    # substitute, or search another run. The current file is required even when an older segment exists.
    rotated = log_dir / 'hermes-hq.log.1'
    if rotated.exists():
        with rotated.open(encoding='utf-8-sig') as f:
            yield from f
    with (log_dir / 'hermes-hq.log').open(encoding='utf-8-sig') as f:
        yield from f


def main():
    try:
        logs = Path(os.environ['LOCALAPPDATA']) / 'HermesHQ' / 'logs'
        check(current_lines(logs), os.environ['GITHUB_RUN_ID'] + '.' + os.environ['GITHUB_RUN_ATTEMPT'], os.environ['GITHUB_SHA'])
    except Gap as gap:
        print(f'quiet readback: {gap}; remaining proof not attempted')
        return 1
    except (OSError, UnicodeError, KeyError):
        print('quiet readback: missing or unreadable evidence; remaining proof not attempted')
        return 1
    print('quiet readback: complete; banner unverified')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
