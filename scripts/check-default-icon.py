#!/usr/bin/env python3
"""[icon-lock] The app's own icon is locked to Halo (owner 2026-11-24: "Somehow, it got changed back to the Hermes face
on the last build. Make sure that does not happen again."). Internal build 1262 was reserved on a base cut before Halo
reached main, so it went out wearing Hermes. scripts/default-app-icon.lock holds the SHA-256 of every file that draws
the default icon (the AppIcon set and its pinned -Light/-Dark sets, the picker's AppIcon-Preview, LaunchIcon); this
checks a tree against it.

  check-default-icon.py                  the working tree against its own lock and main's lock
  check-default-icon.py --rev REV        a commit (or ':' for the index) against main's lock
  check-default-icon.py --write          rewrite the lock from the working tree (a deliberate, owner-approved change)

scripts/ship.py runs the first form before it archives, exports or uploads; scripts/hooks/private-commit-msg runs the
same comparison on every "Reserve ... build" commit, from the hooks folder every worktree shares, so even a worktree
cut before this file existed can't reserve a build wearing another icon. AppIconTests.defaultIconIsLocked fails in
any tree whose icon and lock disagree."""
import hashlib, json, os, pathlib, subprocess, sys

# HQ_REPO: the hook runs main's copy of this file from stdin, inside a worktree that may not have it.
ROOT = pathlib.Path(os.environ['HQ_REPO']) if os.environ.get('HQ_REPO') else pathlib.Path(__file__).resolve().parents[1]
LOCK = 'scripts/default-app-icon.lock'
CATALOG = 'App/Resources/Assets.xcassets'
FOLDERS = ['AppIcon.appiconset', 'AppIcon-Light.appiconset', 'AppIcon-Dark.appiconset', 'AppIcon-Preview.imageset',
           'LaunchIcon.imageset']


def git(*args, check=True):
    p = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True)
    if check and p.returncode: raise SystemExit(f'git {" ".join(args)} failed: {p.stderr.decode().strip()}')
    return p


def tree_files():
    out = {}
    for folder in FOLDERS:
        for f in sorted((ROOT / CATALOG / folder).glob('*.png')):
            out[f'{CATALOG}/{folder}/{f.name}'] = hashlib.sha256(f.read_bytes()).hexdigest()
    return out


def rev_files(rev):
    """The same files in a commit (`:` = the index)."""
    if rev == ':':
        names = git('ls-files', '--', *[f'{CATALOG}/{d}' for d in FOLDERS]).stdout.decode().split('\n')
        spec = lambda n: f':{n}'
    else:
        names = git('ls-tree', '-r', '--name-only', rev, '--', *[f'{CATALOG}/{d}' for d in FOLDERS]).stdout.decode().split('\n')
        spec = lambda n: f'{rev}:{n}'
    return {n: hashlib.sha256(git('cat-file', 'blob', spec(n)).stdout).hexdigest() for n in names if n.endswith('.png')}


def main_lock():
    p = git('show', f'main:{LOCK}', check=False)
    return json.loads(p.stdout) if p.returncode == 0 else None


def compare(found, lock, where):
    want = lock['files']
    wrong = sorted(k for k in set(want) | set(found) if want.get(k) != found.get(k))
    if wrong:
        print(f'Default app icon is NOT {lock["icon"]} ({where}). Differs: ' + ', '.join(p.split('/', 3)[-1] for p in wrong[:8])
              + (f' and {len(wrong) - 8} more' if len(wrong) > 8 else ''), file=sys.stderr)
        print('This tree is probably cut from a base older than main. Merge main into it (or reserve the build on main).'
              ' To change the default icon on purpose: swap the art, run scripts/check-default-icon.py --write, merge to'
              ' main.', file=sys.stderr)
        return False
    return True


if __name__ == '__main__':
    args = sys.argv[1:]
    if args[:1] == ['--write']:
        (ROOT / LOCK).write_text(json.dumps({'icon': 'Halo', 'files': tree_files()}, indent=2, sort_keys=True) + '\n')
        print(f'Wrote {LOCK}'); sys.exit(0)
    from_main = main_lock()
    if args[:1] == ['--rev']:
        if from_main is None: print('main has no default-icon lock yet; nothing to check.'); sys.exit(0)
        ok = compare(rev_files(args[1]), from_main, f'{args[1]} against main\'s lock')
    else:
        found = tree_files()
        ok = compare(found, json.loads((ROOT / LOCK).read_text()), 'working tree against its lock')
        if from_main is not None: ok = compare(found, from_main, "working tree against main's lock") and ok
    if ok: print(f'Default app icon: {(from_main or {}).get("icon", "Halo")} (locked).')
    sys.exit(0 if ok else 1)
