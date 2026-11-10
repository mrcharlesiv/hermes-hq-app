#!/usr/bin/env python3
"""Read the HQ Native diagnostic log that the phone sends home (HermesKit/Diagnostics/LogUploader.swift).

The gateway's hermes-hq-push plugin writes it to ~/.hermes/hq-logs/HQN_<model>-<id>/<day>.jsonl (read-only here).

  python3 scripts/hqn-logs.py                 crashes from the last 3 days, then the last 80 log lines
  python3 scripts/hqn-logs.py --days 7 --lines 300
  python3 scripts/hqn-logs.py --root DIR      another hq-logs folder (e.g. a fixture's), or one device's folder
  python3 scripts/hqn-logs.py --device mac    only devices whose folder name contains this (arm64 / mac = the Mac app,
                                              iPhone, iPad, or the id after the dash, e.g. 00000001)
  python3 scripts/hqn-logs.py --perf          only the performance summary (smoothness, connections, hangs)

Following one problem (Detailed Logging, DiagnosticLog.swift `AppLog.trace`): any of these prints only the log lines
that match, oldest first, and skips the crash and performance sections.
  --chat ID          one chat: its session id (stored or runtime) is turned into the app's tag (#3fa9b2) and matched
  --tag '#3fa9b2'    lines carrying this tag (or any text: --grep)
  --cat stream,rpc   only these categories (note.<category>)
  --at 15:04         ±--window minutes (default 5) around this local time today (or 'YYYY-MM-DD HH:MM')
  --marks            ±--window minutes around each Mark a Slow Moment (the last --lines of each)

The performance summary (also printed between the crashes and the log lines) reads the `frames` / `frames.bad`
events (HermesKit/Diagnostics/FrameMeter.swift): per moment kind and screen, the count, median and p90 hitch ratio
(ms of hitch per second of motion; under 5 is smooth, over 10 is bad) and the worst frame; then connect and reconnect
timings from the log lines, `main.hang` stalls by screen and iOS's own daily numbers (`mk.day`).

Crashes are rebuilt from their events, with the message a library left for the crash report ("Fatal error: …") when
the record has one. The app's own frames (HermesHQNative on the iPhone, "Hermes HQ" on the Mac) in crash records,
iOS's hang reports and the app's sampled stalls (`main.hang.frame`) are symbolicated with atos against the build's
archive (ship.py's .build/HQOriginal[-mac]-<build>.xcarchive or HQNative[-mac]-…) in this checkout, the main checkout,
or any worktree beside them, when one is there. The system's own errors for the Mac app are `system` log lines.
"""
import argparse, datetime, glob, hashlib, json, os, pathlib, re, subprocess, time
from collections import defaultdict

REPO = pathlib.Path(__file__).resolve().parent.parent


def device_folders(root, device=None):
    """The device folders under `root` (HQN_<model>-<id>), or `root` itself when it is one; `device` filters by name."""
    root = os.path.normpath(root)
    if os.path.basename(root).startswith('HQN_') or (glob.glob(os.path.join(root, '*.jsonl')) and not glob.glob(os.path.join(root, 'HQN_*'))):
        folders = [root]
    else:
        folders = sorted(glob.glob(os.path.join(root, 'HQN_*')))
    if device:
        needle = 'arm64' if device.lower() == 'mac' else device.lower()
        folders = [f for f in folders if needle in os.path.basename(f).lower()]
    return folders


def short_device(folder):
    """'HQN_iPhone19_2-00000001' -> 'iPhone19_2-00000001'; the Mac app's 'HQN_arm64-…' -> 'Mac-…'."""
    name = os.path.basename(folder)
    name = name[4:] if name.startswith('HQN_') else name
    return 'Mac' + name[5:] if name.startswith('arm64') else name


def load(root, days, device=None):
    events = []
    cutoff = time.time() * 1000 - days * 86400_000
    for folder in device_folders(root, device):
        for path in sorted(glob.glob(os.path.join(folder, '*.jsonl'))):
            for line in open(path, encoding='utf-8'):
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get('t', 0) >= cutoff:
                    e['_device'] = short_device(folder)
                    events.append(e)
    events.sort(key=lambda e: e['t'])
    return events


def joined(e, key):
    parts, i = [e.get(key, '')], 2
    while f'{key}{i}' in e:
        parts.append(e[f'{key}{i}']); i += 1
    return ''.join(parts)


def tag(session_id):
    """The app's tag for an id (DiagnosticLog.swift AppLog.tag): '#' + 6 hex of its SHA-256."""
    return '#' + hashlib.sha256(session_id.encode()).hexdigest()[:6]


def at_ms(text):
    """'15:04' (today) or '2026-10-27 15:04' -> epoch ms, local time."""
    text = text.strip()
    if re.fullmatch(r'\d{1,2}:\d{2}', text):
        text = datetime.date.today().isoformat() + ' ' + text
    return int(datetime.datetime.strptime(text, '%Y-%m-%d %H:%M').timestamp() * 1000)


def follow(events, args, many):
    """The --chat / --tag / --grep / --cat / --at / --marks view: matching log lines only."""
    notes = [e for e in events if e['k'].startswith('note.') or e['k'] == 'mark']
    needles = [tag(c) for c in args.chat or []] + list(args.tag or []) + list(args.grep or [])
    cats = {c.strip() for c in (args.cat or '').split(',') if c.strip()}
    windows = []
    span = args.window * 60_000
    if args.at:
        t = at_ms(args.at); windows.append((t - span, t + span))
    if args.marks:
        windows += [(e['t'] - span, e['t'] + span // 5) for e in events if e['k'] == 'mark']
    out = []
    for e in notes:
        if windows and not any(a <= e['t'] <= b for a, b in windows):
            continue
        if e['k'] == 'mark':
            out.append(e); continue
        if cats and e['k'][5:] not in cats:
            continue
        if needles and not any(n in joined(e, 'm') for n in needles):
            continue
        out.append(e)
    if args.chat:
        print('tags: ' + ', '.join(f'{c} -> {tag(c)}' for c in args.chat))
    print(f'== {len(out)} matching log lines' + (f' (last {args.lines})' if len(out) > args.lines else ''))
    for e in out[-args.lines:]:
        who = '[' + e['_device'] + '] ' if many else ''
        if e['k'] == 'mark':
            print(f"{who}{stamp(e['t'])} ======== MARKED MOMENT {e.get('id', '')} ========")
        else:
            print(f"{who}{stamp(e['t'])} [{e['k'][5:]}] {joined(e, 'm')}")


def stamp(ms):
    return time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(ms / 1000))


APP_BINARIES = ('HermesHQNative', 'Hermes HQ')   # the iPhone's and the Mac's (project.yml PRODUCT_NAME)


def is_mac(device):
    return device.startswith('Mac') or 'x86_64' in device


def arch(device):
    return 'x86_64' if 'x86_64' in device else 'arm64'


def archive_roots(repo=None):
    """Folders that may hold ship.py's archives: this checkout's .build, the main checkout's, its worktrees' and the
    ones in ../<name>-wt/*."""
    repo = pathlib.Path(repo or REPO)
    main = repo.parent.parent.parent if repo.parent.name == 'worktrees' and repo.parent.parent.name == '.claude' else repo
    roots = [repo / '.build', main / '.build'] + sorted((main / '.claude' / 'worktrees').glob('*/.build')) \
        + sorted(main.parent.glob(main.name + '-wt/*/.build'))
    out = []
    for root in roots:
        if root.is_dir() and root not in out:
            out.append(root)
    return out


def dsym(build, mac, repo=None):
    """The app binary's DWARF file in this build's archive, or None."""
    if not build:
        return None
    for root in archive_roots(repo):
        for identity in ('HQOriginal', 'HQNative'):
            archive = root / f"{identity}{'-mac' if mac else ''}-{build}.xcarchive"
            for binary in APP_BINARIES:
                path = archive / 'dSYMs' / f'{binary}.app.dSYM' / 'Contents' / 'Resources' / 'DWARF' / binary
                if path.exists():
                    return path
    return None


def atos(build, offsets, mac=False, cpu='arm64'):
    """Offsets into the app's binary -> 'function (in binary) (file.swift:12)'; {} without the build's archive."""
    path = dsym(build, mac)
    offsets = sorted(set(offsets))
    if not path or not offsets:
        return {}
    base = 0x100000000
    out = subprocess.run(['xcrun', 'atos', '-arch', cpu, '-o', str(path), '-l', hex(base)] + [hex(base + o) for o in offsets],
                         capture_output=True, text=True).stdout.splitlines()
    return dict(zip(offsets, out))


def build_at(events, device, t):
    """The build that was running on `device` at `t`: the last launch line before it ('… 1.0 (454), …')."""
    build = ''
    for e in events:
        if e['t'] > t:
            break
        if e['_device'] == device and e['k'] == 'note.launch':
            m = re.search(r' \((\d+)\), ', joined(e, 'm'))
            if m:
                build = m.group(1)
    return build


FRAME = re.compile(r'^(\d+) (.+?) (0x[0-9a-f]+) ?(.*)$')


def frame_line(f, header, names):
    """A crash record's stack line, with the app's own frame named when its offset is in `names`."""
    m = FRAME.match(f)
    if not m or m.group(2) not in APP_BINARIES or header is None:
        return f
    where = names.get(int(m.group(3), 16) - header)
    return f'{m.group(1)} {m.group(2)} {m.group(3)} {where}' if where else f


def app_offsets(frames, header):
    out = []
    for f in frames:
        m = FRAME.match(f)
        if m and m.group(2) in APP_BINARIES and header is not None:
            out.append(int(m.group(3), 16) - header)
    return out


def quantile(values, q):
    """Nearest-rank quantile, as FrameMath.quantile on the phone."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = -(-q * len(ordered) // 1)
    return ordered[min(len(ordered) - 1, max(0, int(rank) - 1))]


def ratios(e):
    out = []
    for part in str(joined(e, 'rs')).split(','):
        try:
            out.append(float(part))
        except ValueError:
            pass
    return out


CONNECT_STEP = re.compile(r'([A-Za-z][\w-]*)\s*[:=]?\s*(\d+(?:\.\d+)?)\s*ms')
RECONNECT = re.compile(r'reconnect refresh:\s*(.*?)\s+in\s+(\d+(?:\.\d+)?)\s*ms')


def connect_steps(text):
    """'connect: tunnel 120 ms, ticket 40 ms, handshake 80 ms, total 260 ms' -> {'tunnel': 120.0, ...}, else None."""
    at = text.find('connect:')
    if at < 0 or (at > 0 and text[at - 1].isalpha()):
        return None
    steps = {name.lower(): float(ms) for name, ms in CONNECT_STEP.findall(text[at + len('connect:'):])}
    return steps or None


def perf_summary(events):
    """The performance summary's lines. With more than one device, each row says which device it is from."""
    lines = []
    devices = sorted({e.get('_device', '') for e in events} - {''})
    many = len(devices) > 1
    tag = (lambda e: f'[{e.get("_device", "?")}] ') if many else (lambda e: '')
    if devices:
        lines.append(f'== device(s): {", ".join(devices)}')
    groups = defaultdict(lambda: {'n': 0, 'rs': [], 'wf': 0, 'b': 0, 'dur': 0, 'hit': 0.0, 'mf': 0, 'hz': 0})
    bad = []
    for e in events:
        if e.get('k') == 'frames':
            g = groups[(e.get('kd', '?'), e.get('scr', ''), e.get('_device', '') if many else '')]
            g['n'] += int(e.get('n', 0))
            g['rs'] += ratios(e)
            g['wf'] = max(g['wf'], e.get('wf', 0))
            g['b'] += int(e.get('b', 0))
            g['dur'] += e.get('dur', 0)
            g['hit'] += e.get('hit', 0)
            g['mf'] += int(e.get('mf', 0))
            g['hz'] = max(g['hz'], e.get('hz', 0))
        elif e.get('k') == 'frames.bad':
            bad.append(e)
    lines.append(f'== smoothness: {sum(g["n"] for g in groups.values())} moment(s) (hitch ms per s: <5 smooth, >10 bad)')
    if groups:
        lines.append(f'   {"moment":<10} {"screen":<28}{" device".ljust(22) if many else ""} {"count":>5} {"median":>7} {"p90":>6} {"overall":>8} {"worst":>7} {">100ms":>6} {"Hz":>4}')
        for (kind, screen, device), g in sorted(groups.items(), key=lambda item: (item[0][0], -item[1]['n'])):
            overall = g['hit'] / (g['dur'] / 1000) if g['dur'] else 0
            column = f' {device[:21]:<21}' if many else ''
            lines.append(f'   {kind:<10} {(screen or "-")[:28]:<28}{column} {g["n"]:>5} {quantile(g["rs"], 0.5):>7.1f} {quantile(g["rs"], 0.9):>6.1f} '
                         f'{overall:>8.1f} {g["wf"]:>5} ms {g["b"]:>6} {g["hz"]:>4}')
    for e in bad[-10:]:
        lines.append(f'   bad {tag(e)}{stamp(e["t"])} {e.get("kd")} on {e.get("scr") or "-"}: worst frame {e.get("wf")} ms, '
                     f'{e.get("hr")} ms/s over {e.get("dur")} ms, {e.get("mf")} missed of {e.get("fr", 0) + e.get("mf", 0)}')

    connects, reconnects = defaultdict(list), defaultdict(list)
    for e in events:
        if not e.get('k', '').startswith('note.'):
            continue
        text = joined(e, 'm')
        steps = connect_steps(text) if 'reconnect refresh' not in text else None
        if steps:
            for name, ms in steps.items():
                connects[name].append(ms)
        match = RECONNECT.search(text)
        if match:
            reconnects[match.group(1) or '?'].append(float(match.group(2)))
    count = max((len(v) for v in connects.values()), default=0)
    lines.append(f'\n== connections: {count} connect(s), {sum(len(v) for v in reconnects.values())} reconnect refresh(es)')
    for name, values in connects.items():
        lines.append(f'   connect {name:<12} n={len(values):<4} median {quantile(values, 0.5):>7.0f} ms  p90 {quantile(values, 0.9):>7.0f} ms  '
                     f'max {max(values):>7.0f} ms')
    for outcome, values in sorted(reconnects.items(), key=lambda item: -len(item[1])):
        lines.append(f'   reconnect {outcome[:20]:<20} n={len(values):<4} median {quantile(values, 0.5):>7.0f} ms  '
                     f'p90 {quantile(values, 0.9):>7.0f} ms  max {max(values):>7.0f} ms')

    hangs = [e for e in events if e.get('k') == 'main.hang']
    by_screen = defaultdict(list)
    for e in hangs:
        by_screen[tag(e) + (e.get('screen') or '-')].append(e)
    stuck = sum(1 for e in hangs if e.get('ongoing'))
    lines.append(f'\n== main thread: {len(hangs) - stuck} stall(s) over 0.25 s, {stuck} unanswered past 2 s')
    for screen, items in sorted(by_screen.items(), key=lambda item: -len(item[1])):
        ms = [e.get('ms', 0) for e in items if not e.get('ongoing')]
        if ms:
            lines.append(f'   {screen[:58 if many else 36]:<{58 if many else 36}} {len(ms):>4} stall(s), median {quantile(ms, 0.5):>5.0f} ms, longest {max(ms):>6} ms')

    highs = [e for e in events if e.get('k') == 'mem.high']
    sampled = [e for e in events if e.get('k') in ('mem.trim', 'main.hang', 'frames.bad', 'mem.high') and 'fp' in e]
    if sampled:
        top = max(sampled, key=lambda e: e.get('fp', 0))
        lines.append(f'\n== memory: {len(highs)} high mark(s); highest sampled {top.get("fp")} MB '
                     f'({top.get("k")} on {top.get("scr") or top.get("screen") or "-"}, {tag(top)}{stamp(top["t"])})')
        for e in highs[-10:]:
            lines.append(f'   {tag(e)}{stamp(e["t"])} {e.get("fp")} MB on {e.get("scr") or "-"} (peak this run {e.get("fpk")} MB)')

    days = [e for e in events if e.get('k') == 'mk.day']
    if days:
        lines.append(f'\n== iOS daily summaries ({len(days)})')
        for e in days[-7:]:
            lines.append(f'   {tag(e)}{e.get("day")} build {e.get("bld")}: scroll hitches {e.get("sh", "-")} ms/s, hangs {e.get("hc", "-")} '
                         f'({e.get("hs", "-")} s), first draw {e.get("fd", "-")}, resume {e.get("rsm", "-")}, '
                         f'peak {e.get("pk", "-")} MB, CPU {e.get("cpu", "-")} s'
                         + (f', highest sampled {e.get("hi")} MB on {e.get("hiOn") or "-"}' if 'hi' in e else ''))
    return lines


def print_stack(items, hang):
    """A sampled stall's main-thread stacks (MainStack.swift), innermost first, the app's frames named by atos."""
    if not items:
        return
    names = atos(hang.get('bld'), [f['o'] for f in items if f.get('b') in APP_BINARIES and f.get('o', -1) >= 0],
                 is_mac(hang['_device']), arch(hang['_device']))
    for n in sorted({f.get('n', 1) for f in items}):
        print(f'     main thread, sample {n}:')
        for f in sorted((f for f in items if f.get('n', 1) == n), key=lambda f: f.get('i', 0)):
            where = names.get(f.get('o')) if f.get('b') in APP_BINARIES else f.get('s', '')
            print(f"     {f.get('i'):>3} {f.get('b')} +0x{max(0, f.get('o', 0)):x} {where or ''}")


def main():
    ap = argparse.ArgumentParser(description='Read the HQ Native logs the app sends home (see the top of this file).')
    ap.add_argument('--root', default=os.path.expanduser('~/.hermes/hq-logs'),
                    help='the hq-logs folder (default ~/.hermes/hq-logs), or one device folder inside it (HQN_<model>-<id>)')
    ap.add_argument('--device', help='only devices whose folder name contains this; "mac" means the Mac app (arm64)')
    ap.add_argument('--days', type=float, default=3)
    ap.add_argument('--lines', type=int, default=80)
    ap.add_argument('--perf', action='store_true', help='only the performance summary')
    ap.add_argument('--chat', action='append', help='a session id: only lines carrying its tag (repeatable)')
    ap.add_argument('--tag', action='append', help="only lines carrying this tag, e.g. '#3fa9b2' (repeatable)")
    ap.add_argument('--grep', action='append', help='only lines containing this text (repeatable)')
    ap.add_argument('--cat', help='only these categories, comma-separated (stream,rpc,http,event,chat…)')
    ap.add_argument('--at', help="around this local time: '15:04' or '2026-10-27 15:04'")
    ap.add_argument('--window', type=float, default=5, help='minutes either side for --at / --marks (default 5)')
    ap.add_argument('--marks', action='store_true', help='around each marked moment')
    args = ap.parse_args()
    events = load(args.root, args.days, args.device)
    if not events:
        which = f' for device "{args.device}"' if args.device else ''
        print(f'No HQ Native log events in {args.root}{which} for the last {args.days:g} days.'); return
    many = len({e['_device'] for e in events}) > 1
    if args.perf:
        print('\n'.join(perf_summary(events))); return
    if args.chat or args.tag or args.grep or args.cat or args.at or args.marks:
        if args.lines == 80:
            args.lines = 2000
        follow(events, args, many); return

    records = defaultdict(list)
    for e in events:
        if e['k'].startswith('crash.') or e['k'].startswith('hang.'):
            records[e.get('rec', '?')].append(e)
    print(f'== {len(records)} crash/hang record(s)')
    for rec, items in records.items():
        head = next((e for e in items if e['k'] in ('crash.exc', 'crash.sig', 'crash.mk', 'hang.mk')), items[0])
        print(f"\n-- {head['_device']} {stamp(head['t'])} [{head['k']}] record {rec}")
        if head['k'] == 'crash.exc':
            print(f"   {head.get('nm')} on {head.get('thr')} thread: {joined(head, 'why')}")
        if head['k'] == 'crash.mk':
            print(f"   app {head.get('ver')} ({head.get('bld')}), iOS {head.get('os')}: {head.get('exc')} {head.get('code', '')} "
                  f"signal {head.get('sig')} {head.get('nm', '')} {head.get('cls', '')} {joined(head, 'why')} {head.get('term', '')}")
        mac, cpu = is_mac(head['_device']), arch(head['_device'])
        build = head.get('bld') or build_at(events, head['_device'], head['t'])
        for e in items:
            if e['k'] == 'crash.why':
                print(f"   why ({e.get('lib')}): {joined(e, 'why')}")
        header = None
        for e in items:
            if e['k'] == 'crash.img':
                print('   ' + e.get('img', ''))
                m = re.search(r'header (0x[0-9a-f]+)', e.get('img', ''))
                header = int(m.group(1), 16) if m else None
        frames = [e.get('f', '') for e in sorted((e for e in items if e['k'] == 'crash.frame'), key=lambda e: e.get('i', 0))]
        names = atos(build, app_offsets(frames, header), mac, cpu)
        for f in frames:
            print(f"   {frame_line(f, header, names)}")
        if head['k'] == 'hang.mk':
            print(f"   iOS hang report: {head.get('dur')} in {head.get('ver')} ({head.get('bld')}); main thread, innermost first:")
        mk = sorted((e for e in items if e['k'] in ('crash.mk.frame', 'hang.mk.frame')), key=lambda e: e.get('i', 0))
        if mk:
            names = atos(build, [e['o'] for e in mk if e.get('b') in APP_BINARIES and e.get('o', -1) >= 0], mac, cpu)
            for e in mk:
                where = names.get(e.get('o')) if e.get('b') in APP_BINARIES else e.get('s', '')
                print(f"   {e.get('i'):>3} {e.get('b')} +0x{max(0, e.get('o', 0)):x} {where or ''}")

    print('\n' + '\n'.join(perf_summary(events)))
    # Build 292: each main-thread stall the app saw, with what it was doing (MainTrail spans, facts).
    hangs = [e for e in events if e['k'] == 'main.hang'][-20:]
    if hangs:
        print(f'\n== last {len(hangs)} main-thread stalls')
        frames = defaultdict(list)
        for e in events:
            if e['k'] == 'main.hang.frame':
                frames[e.get('rec')].append(e)
        for e in hangs:
            extra = ''.join(f" | {key}: {joined(e, key)}" for key in ('did', 'ctx') if key in e)
            print(f"{'[' + e['_device'] + '] ' if many else ''}{stamp(e['t'])} {e.get('ms')} ms{' (ongoing)' if e.get('ongoing') else ''} on {e.get('screen')}{extra}")
            print_stack(frames.get(e.get('rec')) if e.get('rec') else None, e)

    notes = [e for e in events if e['k'].startswith('note.')][-args.lines:]
    print(f'\n== last {len(notes)} log lines')
    for e in notes:
        print(f"{'[' + e['_device'] + '] ' if many else ''}{stamp(e['t'])} [{e['k'][5:]}] {joined(e, 'm')}")


if __name__ == '__main__':
    main()
