"""Admission and receipt checks for the evidence-only job. Never starts the app or Narrator."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from narrator_chat import CI, MAC_1245, MAX_MOVES, assess, require_push, require_runner

MAC_1240 = '784f6c222cf04b5b09e631ea3b467a48d21ad556'
BASE_FIELDS = {'mirrorSha', 'runId', 'attempt', 'macReference', 'appExit', 'runnerStop',
               'readerAliveAtAppExit', 'fixture', 'trace', 'verdict'}
CLEAN = dict(promptAttempts=0, upstreamCalls=0, uploads=0, historyRequested=True)
STREAM_FIELDS = {
    'focus': 'id name role xaml',
    'physical': 'key api inserted received receivedKey focusEvents focusState frontBefore frontAfter emptyBefore draftAfter sendEnabled',
    'speech': 'at source key inserted receivedX frontBefore frontAfter sequenceBefore sequenceAfter ownerPid text unavailable',
}
INTEGER_FIELDS = set('at inserted received focusEvents frontBefore frontAfter receivedX sequenceBefore sequenceAfter ownerPid'.split())
# The archive boundary also applies to failed observations. Free text is never an attachment channel.
PHRASE_WORDS = set(('inspector message proof hermes send toggle button edit editing text box multi line multiline blank empty '
                    'on off checked unchecked not pressed selected unselected collapsed expanded available unavailable read only q '
                    'press space enter to activate type in this field can contain multiple lines of').split())
RECORD_TEXT = set(('chat.composer chat.send InspectorToggle composer.plus chat.reply-more chat.regenerate-reply chat.transcript '
                   'Message Send Inspector Attach More Regenerate Commands Model Edit List Button Composer SendButton Messages '
                   'Shift+Tab Tab Q Shift+Q unexpected-modifiers SendInput q Keyboard Programmatic Pointer Unfocused '
                   'Narrator.CopyLastPhrase Insert+Ctrl+X no-attributable-narrator-output clipboard-not-empty-owned-or-available '
                   'shortcut-reached-app shortcut-or-clipboard-not-stable no-fresh-narrator-phrase clipboard-owner-not-launched-narrator '
                   'no-bounded-unicode-phrase unreadable-phrase no-bounded-phrase clipboard-changed unexpected-words-not-retained').split()) | {
                       '', 'Message Proof Hermes', '[unexpected name omitted]'}
NATIVE_STOPS = set(('clipboard-changed-before-shortcut draft-not-empty focus-changed-during-observation focus-outside-fixture-chat '
                    'foreground-left-app incomplete-key-batch incomplete-narrator-shortcut key-already-down key-did-not-change-focus-or-draft '
                    'key-not-received-on-intended-control lost-fixture-or-modal-open no-focused-peer no-loaded-fixture-chat '
                    'not-a-keyboard-focus-arrival not-the-seeded-chat out-of-order-or-cyclic-tab-stops unexpected-focus-transition '
                    'unexpected-start unknown-native-focus unknown-xaml-focus unrecognized-chat-stop').split())
# Offline replay of original bytes only: the original verifier's complete, bounded ASCII class token.
LEGACY_FIXTURE_EXCEPTION = re.compile(r'fixture-(?:[A-Z][a-zA-Z0-9]{0,60})?Exception')
# New receipts contain only one of the fixture's exact categories, even when the class is unknown.
NATIVE_EXCEPTIONS = {'fixture-' + name for name in ('Exception', 'ArgumentException', 'COMException', 'GatewayException',
                     'HttpRequestException', 'InvalidCastException', 'InvalidOperationException', 'IOException', 'JsonException',
                     'KeyNotFoundException', 'NullReferenceException', 'ObjectDisposedException', 'OperationCanceledException',
                     'TaskCanceledException', 'TimeoutException', 'UnauthorizedAccessException', 'Win32Exception')}
LEGACY_STARTUP = {'opt-in build receipt missing or invalid', 'wrong fixture build for this push', 'loopback fixture module unavailable',
                'checked-out mirror commit is not the admitted push', 'pre-existing Narrator; left alone',
                'no verified interactive disposable runner session', 'the launched Narrator did not remain available'}
LEGACY_STOPS = LEGACY_STARTUP | {'oversize fixture trace', 'trace does not belong to the owned app and reader',
                'fixture or Narrator exited unexpectedly', 'no trace from the owned app and reader',
                'did not observe the expected read-only synthetic chat', 'OSError', 'FileNotFoundError', 'PermissionError',
                'FileExistsError', 'NotADirectoryError', 'IsADirectoryError', 'ProcessLookupError', 'TimeoutError',
                'BlockingIOError', 'ChildProcessError', 'ConnectionError', 'BrokenPipeError', 'ConnectionAbortedError',
                'ConnectionRefusedError', 'ConnectionResetError', 'InterruptedError',
                'KeyError', 'JSONDecodeError', 'UnicodeDecodeError', 'UnicodeEncodeError', 'SubprocessError',
                'CalledProcessError', 'TimeoutExpired'}
# In acquisition order: cleanup can only release something acquired *before* the primary failure.
STARTUP = ('verify-build', 'create-temp', 'prepare-env', 'verify-head', 'probe-session', 'require-no-reader',
           'require-interactive', 'start-standin', 'launch-reader', 'check-reader', 'write-seed', 'prepare-app-env', 'launch-app')
ACQUIRED_AT = {'remove-temp': 'create-temp', 'stop-standin': 'start-standin', 'stop-reader': 'launch-reader',
               'stop-app': 'launch-app'}


def selected(head, env):
    # ci-sync already copies the source subject and adds exactly this provenance paragraph.
    # Actions string comparisons ignore case; check the entire message, not a substring or a list of walks.
    return (env.get('GITHUB_JOB') == 'narrator-chat' and env.get('RUNNER_ARCH') == 'X64'
            and not any(v for k, v in env.items() if k.startswith('HQW_'))
            and isinstance(head, dict) and head.get('id') == env['GITHUB_SHA'] and isinstance(head.get('message'), str)
            and re.fullmatch(r'Proof: narrator-chat-only\n\nFrom feat/windows at [0-9a-f]{7,40}\.\n?', head['message']) is not None)


def admit(env, win):
    require_runner(env, sys.platform)
    event = json.loads(Path(env['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    require_push(env, sys.platform, event)
    if (not selected(event.get('head_commit'), env) or win != Path(env['GITHUB_WORKSPACE']).resolve() / 'windows'
            or os.path.lexists(win / 'build')):
        raise ValueError('requires an explicitly selected, fresh chat-only job')
    git_env = {k: v for k, v in env.items() if k.upper() in {'SYSTEMROOT', 'PATH', 'SYSTEMDRIVE'}}
    head = subprocess.check_output(['git', 'rev-parse', '--verify', 'HEAD'], cwd=win, env=git_env, text=True, timeout=5)
    if head.strip() != env['GITHUB_SHA']:
        raise ValueError('checkout is not the pushed revision')


def require(ok):
    if not ok: raise ValueError('outside the reviewed receipt schema')


def check_phases(r):
    stop, cleanup, trace, fixture = r['runnerStop'], r['cleanupStop'], r['trace'], r['fixture']
    exit_code, alive = r['appExit'], r['readerAliveAtAppExit']
    require(cleanup is None or isinstance(cleanup, str) and cleanup in ACQUIRED_AT)
    if stop in STARTUP:
        require(exit_code is None and alive is None and not trace and fixture is None)
        require(cleanup is None or STARTUP.index(ACQUIRED_AT[cleanup]) < STARTUP.index(stop))
    elif stop == 'wait-app':
        require(exit_code is None and alive is None)  # partial evidence may still have been collected
    elif stop == 'check-reader-exit':
        require(exit_code is not None and alive is None)
    else:
        require(exit_code is not None and alive is not None)
        clean_exit = exit_code == 0 and alive
        if stop == 'read-trace': require(clean_exit and not trace and fixture is None)
        elif stop == 'read-fixture': require(clean_exit and fixture is None)
        elif stop == 'check-exit': require(not clean_exit)
        elif stop == 'require-trace': require(clean_exit and not trace and fixture is not None)
        elif stop == 'check-fixture': require(clean_exit and trace and fixture is not None and fixture != CLEAN)
        elif stop is None:
            # An initial stop-app failure prevents *both* reads; late cleanup cannot erase evidence.
            require(clean_exit and ((cleanup == 'stop-app' and not trace and fixture is None) or (trace and fixture == CLEAN)))
        else: raise ValueError('unreviewed runner phase')


def check_payload(r):
    stop, fixture, t = r['runnerStop'], r['fixture'], r['trace']
    require(r['appExit'] is None or type(r['appExit']) is int)
    require(r['readerAliveAtAppExit'] is None or type(r['readerAliveAtAppExit']) is bool)
    require(r['readerAliveAtAppExit'] is None or r['appExit'] is not None)
    require(fixture is None or isinstance(fixture, dict) and fixture.keys() == CLEAN.keys()
            and all(type(fixture[k]) is type(v) and fixture[k] >= 0 for k, v in CLEAN.items()))
    if 'receiptVersion' in r:
        check_phases(r)
    else:
        require(stop is None or isinstance(stop, str) and stop in LEGACY_STOPS)
        clean_exit = r['appExit'] == 0 and r['readerAliveAtAppExit'] is True
        if stop in LEGACY_STARTUP: require(not t and fixture is None and r['appExit'] is None)
        elif stop in ('oversize fixture trace', 'trace does not belong to the owned app and reader'): require(not t and fixture is None)
        elif stop == 'fixture or Narrator exited unexpectedly':
            require(r['readerAliveAtAppExit'] is not None and not clean_exit and fixture is not None)
        elif stop == 'no trace from the owned app and reader': require(clean_exit and not t and fixture is not None)
        elif stop == 'did not observe the expected read-only synthetic chat': require(clean_exit and t and fixture is not None and fixture != CLEAN)
        elif stop is None: require(clean_exit and t and fixture == CLEAN)
        # An exception class alone cannot localize a historical failure.
    if not t: return
    require(t.keys() == {'schema', 'appPid', 'narratorPid', 'hwnd', 'seededMessages', 'completed', 'stop', *STREAM_FIELDS})
    require(all(type(t[k]) is int for k in ('schema', 'appPid', 'narratorPid', 'hwnd')) and t['schema'] == 1
            and min(t['appPid'], t['narratorPid']) > 0 and t['appPid'] != t['narratorPid'] and type(t['completed']) is bool
            and (t['seededMessages'] is None or type(t['seededMessages']) is int))
    native_stop = t['stop']
    if native_stop is not None:
        require(isinstance(native_stop, str))
        if native_stop not in NATIVE_STOPS:
            if 'receiptVersion' in r:
                require(native_stop in NATIVE_EXCEPTIONS or native_stop == 'fixture-other-exception')
            else:
                require(LEGACY_FIXTURE_EXCEPTION.fullmatch(native_stop))
    for stream, fields in STREAM_FIELDS.items():
        require(isinstance(t[stream], list) and len(t[stream]) <= (4 if stream == 'speech' else 3 * MAX_MOVES + 2))
        for row in t[stream]:
            require(isinstance(row, dict) and row.keys() == set(fields.split()))
            for k, v in row.items():
                if k in INTEGER_FIELDS:
                    require(type(v) is int)
                elif k in ('emptyBefore', 'sendEnabled'):
                    require(v is None or type(v) is bool)
                elif k == 'text' and v is not None:
                    require(isinstance(v, str) and 0 < len(v) <= 240 and row['ownerPid'] == t['narratorPid']
                            and row['source'] == 'Narrator.CopyLastPhrase' and row['unavailable'] is None)
                    words = set(re.split(r'[\s.,:;!()\-]+', v.lower())) - {''}
                    require(words and words <= PHRASE_WORDS)
                else:
                    require(v is None or isinstance(v, str) and v in RECORD_TEXT)


def unique_object(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs): raise ValueError('duplicate receipt field')  # original bytes would contain both values
    return obj


def check_receipt(win, sha, run, attempt, output, *, current_job=False):
    # Only the reviewed driver writes in this previously absent directory. Never collect a directory or follow a link.
    path = win / 'build/narrator-chat/result.json'
    if (not path.is_file() or path.resolve(strict=True) != path or path.stat().st_size > 256 * 1024
            or list(path.parent.iterdir()) != [path]):
        raise ValueError('missing or unexpected receipt file')
    r = json.loads(path.read_bytes(), object_pairs_hook=unique_object)
    require(isinstance(r, dict))
    require(isinstance(sha, str) and re.fullmatch('[0-9a-f]{40}', sha)
            and all(isinstance(v, str) and re.fullmatch('[1-9][0-9]*', v) for v in (run, attempt)))
    if 'receiptVersion' in r:
        require(type(r['receiptVersion']) is int and r['receiptVersion'] == 2)
        fields, mac = BASE_FIELDS | {'receiptVersion', 'cleanupStop'}, MAC_1245
    else:
        require(not current_job)  # offline replay only; this driver never writes the historical format
        fields, mac = BASE_FIELDS, MAC_1240
    if (set(r) != fields or not isinstance(r['trace'], dict)
            or (r['mirrorSha'], r['runId'], r['attempt'], r['macReference']) != (sha, run, attempt, mac)):
        raise ValueError('unbound receipt')
    check_payload(r)
    # Replay the reviewed classifier. Neither a clean exit, a green summary nor a UIA name is a speech receipt.
    verdict = assess(r['trace'])
    verdict['pass'] = (verdict['pass'] and r['runnerStop'] is None and r.get('cleanupStop') is None
                       and type(r['appExit']) is int and r['appExit'] == 0
                       and r['readerAliveAtAppExit'] is True and r['fixture'] == CLEAN)
    if json.dumps(verdict, sort_keys=True) != json.dumps(r['verdict'], sort_keys=True):
        raise ValueError('inconsistent verdict')
    # An attributable non-pass may be collected, but must still fail the job. No data from the file enters the log/output.
    with output.open('a', encoding='utf-8') as f:
        print('bound=true', file=f)
    return 0 if verdict['pass'] else 1


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['admit']:
            admit(os.environ, CI.parent)
        elif sys.argv[1:] == ['receipt']:
            raise SystemExit(check_receipt(CI.parent, os.environ['GITHUB_SHA'], os.environ['GITHUB_RUN_ID'],
                                           os.environ['GITHUB_RUN_ATTEMPT'], Path(os.environ['GITHUB_OUTPUT']), current_job=True))
        else:
            raise ValueError('unknown check')
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        raise SystemExit('Narrator job refused the request or receipt.')
