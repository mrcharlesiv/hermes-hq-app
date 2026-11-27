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
  {"rich": true}                                    more kinds of file and change: notes/tables.md (tables), a PNG, a
                                                    PDF, a deep folder chain under site/docs, and in the site's changes
                                                    a 2,000-line diff, a binary file and a renamed one
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
    if knobs.get('rich'): tree.update(_rich_files())
    return tree

def _png():
    import struct, zlib
    w, h = 320, 200
    raw = b''.join(b'\x00' + bytes(v for x in range(w) for v in (x * 255 // w, y * 255 // h, 180)) for y in range(h))
    chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

def _pdf():
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
               None, b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    text = b'BT /F1 24 Tf 72 700 Td (Release 2.4 guide) Tj ET'
    objects[3] = b'<< /Length %d >>\nstream\n' % len(text) + text + b'\nendstream'
    out, offsets = b'%PDF-1.4\n', []
    for index, body in enumerate(objects, 1):
        offsets.append(len(out)); out += b'%d 0 obj\n' % index + body + b'\nendobj\n'
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1) + b''.join(b'%010d 00000 n \n' % o for o in offsets)
    return out + b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)

def _rich_files():
    table = ('# Plans\n\nThe three plans side by side.\n\n| Plan | Seats | Price a month | Notes |\n|:--|--:|--:|:--|\n'
             '| Starter | 1 | $9 | For trying it out |\n| Team | 10 | $49 | Shared bots and a group chat for everyone |\n'
             '| Business | 50 | $199 | SSO, audit log and a long note that wraps over more than one line in a narrow window |\n\n'
             '## Second table\n\n| Key | Value |\n|---|---|\n| region | eu-west |\n| retries | 3 |\n')
    out = {NOTES + '/tables.md': table, SITE + '/assets/photo.png': _png(), SITE + '/docs': None,
           SITE + '/docs/guide.pdf': _pdf(),
           SITE + '/src/big.js': ''.join(f'const value{i} = {i * 2} // the new line number {i}, doubled, with some words after it\n' for i in range(1000)),
           SITE + '/src/components/header.js': "export function header(root) {\n  root.prepend(document.createElement('header'))\n}\n"}
    deep = SITE + '/docs'
    for name in ('architecture-decisions', 'networking-and-transport', 'retry-and-backoff-policies', 'incident-reviews-2026',
                 'october-gateway-timeouts', 'follow-up-actions'):
        deep += '/' + name
        out[deep] = None
    out[deep + '/summary-of-what-we-changed.md'] = '# Summary\n\nRetries now back off for up to a minute.\n'
    return out

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

BIG_DIFF = ('diff --git a/src/big.js b/src/big.js\nindex 1111111..2222222 100644\n--- a/src/big.js\n+++ b/src/big.js\n'
            '@@ -1,1000 +1,1000 @@\n' + ''.join(f'-const value{i} = {i} // the old line number {i} with some words after it\n'
                                              f'+const value{i} = {i * 2} // the new line number {i}, doubled, with some words after it\n'
                                              for i in range(1000)))
RICH_DIFFS = {
    'src/big.js': ('M', False, 1000, 1000, BIG_DIFF),
    'assets/logo.bin': ('M', False, 0, 0, 'diff --git a/assets/logo.bin b/assets/logo.bin\nindex 3333333..4444444 100644\n'
                                       'Binary files a/assets/logo.bin and b/assets/logo.bin differ\n'),
    'src/components/header.js': ('R', True, 1, 1, 'diff --git a/src/components/top.js b/src/components/header.js\nsimilarity index 92%\n'
                                 'rename from src/components/top.js\nrename to src/components/header.js\n--- a/src/components/top.js\n'
                                 '+++ b/src/components/header.js\n@@ -1,3 +1,3 @@\n-export function top(root) {\n+export function header(root) {\n'
                                 "   root.prepend(document.createElement('header'))\n }\n"),
}

def _diffs(): return {**DIFFS, **(RICH_DIFFS if knobs.get('rich') else {})}

def changes():
    rows = [{'path': name, 'added': added, 'removed': removed, 'status': status, 'staged': staged}
            for name, (status, staged, added, removed, _) in _diffs().items()]
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
        if name in _diffs(): return 200, {'diff': _diffs()[name][4]}
        if name.startswith('src/generated/'): return 200, {'diff': f'--- a/{name}\n+++ b/{name}\n@@ -1 +1 @@\n-old\n+new\n'}
        return 200, {'diff': ''}
    return None
