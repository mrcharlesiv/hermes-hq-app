#!/usr/bin/env python3
"""[shipped-work] A build carries everything the builds before it shipped (owner 2026-11-24: "There's been a lot of
things that we've shipped to an internal beta that isn't in the current build ... more stuff must be left out too that
I assumed was merged to main"). Internal builds 1248-1261 were stacked on release branches that never merged back, so
build 1262, cut from main, went out without the Hermes HQ Discord in More and the "Hermes arrives" first run.

For each of the last WINDOW build-N tags numbered below the build being reserved, every non-docs commit the tag carries
must be in the tree. A commit counts as in it when any of these hold:
  - it, or a commit with the same patch, is in the tree's history   (git cherry)
  - a commit with the same subject is in the tree's history          (landed again, then edited later)
  - its change is still in the tree                                  (its diff reverses cleanly onto the tree)
  - scripts/shipped-drops.txt names it: `<sha> <why>`, a deliberate drop the owner agreed to

  check-shipped-work.py                     HEAD, against every recent tag
  check-shipped-work.py --rev REV           another commit
  check-shipped-work.py --build N           only tags numbered below N (the hook passes the reserved number)

scripts/hooks/private-commit-msg runs main's copy of this on every "Reserve ... build" commit, so a worktree cut from
an older base can't reserve a build that quietly drops shipped work. HQ_SHIPPED_WORK_SKIP=1 skips it.
"""
import os, pathlib, re, subprocess, sys, tempfile

ROOT = pathlib.Path(os.environ['HQ_REPO']) if os.environ.get('HQ_REPO') else pathlib.Path(__file__).resolve().parents[1]
DROPS = 'scripts/shipped-drops.txt'
WINDOW = 20
IGNORED = ('docs/', 'artifacts/')


def git(*args, check=True, stdin=None, env=None):
    p = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, input=stdin,
                       env={**os.environ, **(env or {})})
    if check and p.returncode: raise SystemExit(f'git {" ".join(args)} failed: {p.stderr.decode().strip()}')
    return p


def out(*args): return git(*args).stdout.decode()


def tags(below):
    found = []
    for t in out('tag', '-l', 'build-*').split():
        m = re.fullmatch(r'build-(\d+)', t)
        if m and (below is None or int(m[1]) < below): found.append((int(m[1]), t))
    return [t for _, t in sorted(found, reverse=True)[:WINDOW]]


def drops():
    """main's list wins (a worktree's own copy may be older); the tree's copy too when it has one."""
    names = set()
    for spec in (f'main:{DROPS}', f'HEAD:{DROPS}'):
        p = git('show', spec, check=False)
        if p.returncode == 0:
            for line in p.stdout.decode().splitlines():
                line = line.split('#', 1)[0].strip()
                if line: names.add(line.split()[0])
    return names


def code_files(sha):
    files = out('diff-tree', '--no-commit-id', '--name-only', '-r', '--root', sha).split()
    return [f for f in files if not f.startswith(IGNORED)]


def still_in(sha, rev):
    """The commit's code change reverses cleanly onto rev's tree: it is there, whatever history brought it."""
    with tempfile.TemporaryDirectory() as d:
        env = {'GIT_INDEX_FILE': os.path.join(d, 'index')}
        git('read-tree', rev, env=env)
        patch = git('diff', '--binary', f'{sha}^', sha, '--', '.', *[f':!{p}' for p in IGNORED]).stdout
        return not patch or git('apply', '--cached', '--check', '-R', stdin=patch, check=False, env=env).returncode == 0


def main():
    args = sys.argv[1:]
    rev = args[args.index('--rev') + 1] if '--rev' in args else 'HEAD'
    below = int(args[args.index('--build') + 1]) if '--build' in args else None
    rev = out('rev-parse', '--verify', f'{rev}^{{commit}}').strip()
    subjects = set(out('log', '--no-merges', '--format=%s', '-n', '5000', rev).splitlines())
    allowed = drops()
    missing, seen = {}, set()
    for tag in tags(below):
        for line in out('cherry', rev, tag).splitlines():
            mark, sha = line.split()[:2]
            if mark != '+' or sha in seen: continue
            seen.add(sha)
            if any(sha.startswith(a) or a.startswith(sha) for a in allowed): continue
            if not code_files(sha): continue
            subject = out('log', '-1', '--format=%s', sha).strip()
            if subject in subjects or still_in(sha, rev): continue
            missing.setdefault(sha, (tag, subject))
    if not missing:
        print(f'Shipped work: every non-docs change in the last {WINDOW} build tags'
              + (f' below {below}' if below else '') + ' is in this tree.')
        return 0
    print('This tree is missing work that already shipped in a build:', file=sys.stderr)
    for sha, (tag, subject) in missing.items():
        print(f'  {sha[:9]} (in {tag}) {subject[:110]}', file=sys.stderr)
    print('Merge the branch that carries it into main (or this tree) first. If it was dropped on purpose, add'
          f' `<sha> <why>` to {DROPS} on main.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
