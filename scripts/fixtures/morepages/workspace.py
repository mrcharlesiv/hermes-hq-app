"""More › Files and Review (docs/spec/3x-morepages.md §11): an invented folder tree and its uncommitted changes.

Read-only, as the pages are: GET only. Shapes are the real gateway's (hermes_cli/web_routers/files.py, git.py):
  GET /api/fs/default-cwd[?profile=]      {"cwd","branch"}                       (the only NEW route: --old-gateway → 404)
  GET /api/fs/list?path=                   {"entries":[{"name","path","isDirectory"}],"error"?}   error: ENOENT / ENOTDIR / EACCES
  GET /api/fs/read-text?path=              {"path","text","binary","truncated","byteSize","language","mimeType"}; over 64 MiB → 413
  GET /api/fs/git-root?path=               {"root": "<repo>" | null}
  GET /api/git/review/list?path=&scope=    {"files":[{"path","added","removed","status","staged"}],"base":null}
                                           (a folder that is not a repository answers an empty list, as Hermes does)
  GET /api/git/review/diff?path=&file=&scope=&staged=   {"diff"}
  GET /api/fs/download?path=               the bytes, for paths inside this tree only (anything else stays with the base fixture)

The tree:  /home/hermes/projects/site   (a repository with two changed files; default-cwd)
           /home/hermes/projects/notes  (not a repository)
           /home/hermes/app             (the folder of the base fixture's chats: a clean repository)

Knobs (POST /__fixture/workspace):
  {"default_cwd": "/home/hermes/projects/notes"}   what default-cwd answers
  {"entries": 3000}                                 /home/hermes/projects/site/many holds that many files
  {"changes": 500}                                  the site repository lists that many changed files
  {"gone": ["/home/hermes/projects/notes"]}         those folders no longer exist (list → ENOENT)
state(): {"default_cwd", "reads": <count of this module's answers>}
"""

HOME = '/home/hermes'
SITE = HOME + '/projects/site'
NOTES = HOME + '/projects/notes'
APP = HOME + '/app'
PREVIEW = 512 * 1024
SOURCE_MAX = 64 * 1024 * 1024
REPOS = (SITE, APP)

NEW = True
REST_PREFIXES = ('/api/fs/default-cwd',)

knobs = {}
reads = [0]

LOG_LINE = '2026-10-09T08:00:00Z build step ok: bundled chunk and wrote the map\n'

def _files():
    """path -> text | bytes | ('virtual', size) for a file; None for a folder; 'EACCES' for a folder that refuses."""
    tree = {
        '/': None, '/home': None, HOME: None, HOME + '/projects': None,
        SITE: None,
        SITE + '/README.md': '# Site\n\nThe marketing site. Run `npm run dev`, then open the address it prints.\n\n'
                             '- `src/` pages and components\n- `assets/` images and styles\n',
        SITE + '/package.json': '{\n  "name": "site",\n  "version": "2.4.0",\n  "scripts": {"dev": "vite", "build": "vite build"}\n}\n',
        SITE + '/build.log': LOG_LINE * ((3 << 20) // len(LOG_LINE) + 1),
        SITE + '/huge.sql': ('virtual', 80 << 20),
        SITE + '/Makefile': 'build:\n\tnpm run build\n',
        SITE + '/assets': None,
        SITE + '/assets/logo.bin': bytes(range(256)) * 8,
        SITE + '/assets/styles.css': 'body { font: 16px/1.5 system-ui; margin: 0 }\n.hero { padding: 48px 16px }\n',
        SITE + '/assets/reel.mov': ('virtual', 33 << 20),
        SITE + '/src': None,
        SITE + '/src/index.html': '<!doctype html>\n<html>\n  <body>\n    <main class="hero">Release 2.4</main>\n  </body>\n</html>\n',
        SITE + '/src/app.js': "import {nav} from './components/nav.js'\n\nnav(document.body)\nconsole.log('ready')\n",
        SITE + '/src/components': None,
        SITE + '/src/components/nav.js': "export function nav(root) {\n  root.prepend(document.createElement('nav'))\n}\n",
        SITE + '/src/components/footer.js': "export function footer(root) {\n  root.append(document.createElement('footer'))\n}\n",
        SITE + '/src/components/deep': None,
        SITE + '/src/components/deep/deeper': None,
        SITE + '/src/components/deep/deeper/leaf.txt': 'The last file down.\n',
        SITE + '/private': 'EACCES',
        SITE + '/empty': None,
        SITE + '/many': None,
        SITE + '/שלום 👋 notes.txt': 'A name with right-to-left text and an emoji.\n',
        NOTES: None,
        NOTES + '/ideas.md': '# Ideas\n\n- A pricing page\n- A changelog feed\n',
        NOTES + '/todo.txt': 'Call the printer\nRenew the domain\n',
        APP: None,
        APP + '/CHANGELOG.md': '# Changelog\n\n## 2.4\n- Export\n- Faster sync\n',
        APP + '/Sources': None,
        APP + '/Sources/App.swift': 'import SwiftUI\n\n@main\nstruct ReleaseApp: App {\n    var body: some Scene { WindowGroup { Text("Release 2.4") } }\n}\n',
    }
    for index in range(int(knobs.get('entries') or 0)):
        tree[f'{SITE}/many/file-{index:04d}.txt'] = f'file {index}\n'
    return tree

DIFFS = {
    'src/app.js': ('M', False, 3, 1,
                   "diff --git a/src/app.js b/src/app.js\nindex 3f1c2aa..9b0d4e1 100644\n--- a/src/app.js\n+++ b/src/app.js\n"
                   "@@ -1,4 +1,6 @@\n import {nav} from './components/nav.js'\n+import {footer} from './components/footer.js'\n \n"
                   " nav(document.body)\n-console.log('ready')\n+footer(document.body)\n+console.log('ready, with a footer')\n"),
    'src/pricing.html': ('?', False, 5, 0,
                         "diff --git a/src/pricing.html b/src/pricing.html\nnew file mode 100644\n--- /dev/null\n+++ b/src/pricing.html\n"
                         "@@ -0,0 +1,5 @@\n+<!doctype html>\n+<html>\n+  <body>Pricing</body>\n+</html>\n+<!-- draft -->\n"),
}

def seed():
    knobs.clear(); reads[0] = 0

def control(path, body):
    if path != '/__fixture/workspace': return None
    knobs.update(body or {})
    return {'ok': True, 'knobs': dict(knobs)}

def state():
    return {'default_cwd': knobs.get('default_cwd') or SITE, 'reads': reads[0]}

def clean(path):
    path = (path or '').strip()
    if len(path) > 1: path = path.rstrip('/')
    return path

def inside(path): return path == '/' or path in _files()

def git_root(path):
    for repo in REPOS:
        if path == repo or path.startswith(repo + '/'): return repo
    return None

def changes():
    rows = [{'path': name, 'added': added, 'removed': removed, 'status': status, 'staged': staged}
            for name, (status, staged, added, removed, _) in DIFFS.items()]
    for index in range(int(knobs.get('changes') or 0)):
        rows.append({'path': f'src/generated/part-{index:04d}.js', 'added': index % 40, 'removed': index % 7, 'status': 'M', 'staged': False})
    return rows

def rest(method, path, query, body, handler):
    if not (path.startswith('/api/fs/') or path.startswith('/api/git/review/')): return None
    if method != 'GET': return None
    asked = clean(ctx.one(query, 'path'))
    tree = _files()
    if path == '/api/fs/default-cwd':
        reads[0] += 1
        cwd = knobs.get('default_cwd') or SITE
        return 200, {'cwd': cwd, 'branch': 'main' if git_root(cwd) else None}
    if path == '/api/fs/list':
        reads[0] += 1
        if asked not in tree or asked in (knobs.get('gone') or []): return 200, {'entries': [], 'error': 'ENOENT'}
        if tree[asked] == 'EACCES': return 200, {'entries': [], 'error': 'EACCES'}
        if tree[asked] is not None: return 200, {'entries': [], 'error': 'ENOTDIR'}
        prefix = asked.rstrip('/') + '/'
        entries = [{'name': p[len(prefix):], 'path': p, 'isDirectory': v is None or v == 'EACCES'}
                   for p, v in tree.items() if p.startswith(prefix) and p != asked and '/' not in p[len(prefix):] and p[len(prefix):]]
        entries.sort(key=lambda item: (not item['isDirectory'], item['name'].lower(), item['name']))
        return 200, {'entries': entries}
    if path == '/api/fs/read-text':
        reads[0] += 1
        value = tree.get(asked)
        if asked not in tree or value is None or value == 'EACCES': return 404, {'detail': 'File not found'}
        if isinstance(value, tuple):
            if value[1] > SOURCE_MAX: return 413, {'detail': 'File too large'}
            data = bytes(PREVIEW)
            size = value[1]
        else:
            data = value if isinstance(value, bytes) else value.encode()
            size = len(data)
        shown = data[:PREVIEW]
        return 200, {'binary': b'\x00' in shown[:4096], 'byteSize': size, 'language': 'text', 'mimeType': 'text/plain', 'path': asked,
                     'text': shown.decode('utf-8', errors='replace'), 'truncated': size > PREVIEW}
    if path == '/api/fs/git-root':
        reads[0] += 1
        return 200, {'root': git_root(asked)}
    if path == '/api/fs/download':
        value = tree.get(asked)
        if asked not in tree or value is None or value == 'EACCES': return None      # the base fixture's files
        reads[0] += 1
        if isinstance(value, tuple): return 200, ('application/octet-stream', bytes(value[1]))
        if isinstance(value, bytes): return 200, ('application/octet-stream', value)
        return 200, ('text/plain; charset=utf-8', value.encode())
    if path == '/api/git/review/list':
        reads[0] += 1
        if git_root(asked) != SITE: return 200, {'files': [], 'base': None}
        return 200, {'files': changes(), 'base': None}
    if path == '/api/git/review/diff':
        reads[0] += 1
        name = ctx.one(query, 'file')
        if name.startswith(asked + '/'): name = name[len(asked) + 1:]
        if name in DIFFS: return 200, {'diff': DIFFS[name][4]}
        if name.startswith('src/generated/'): return 200, {'diff': f'--- a/{name}\n+++ b/{name}\n@@ -1 +1 @@\n-old\n+new\n'}
        return 200, {'diff': ''}
    return None
