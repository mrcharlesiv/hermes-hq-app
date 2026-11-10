"""Kanban: POST /api/plugins/kanban/tasks/<id>/attachments (docs/spec/3x-morepages.md §4), as the plugin answers it
(plugins/kanban/dashboard/plugin_api.py:471-501): multipart/form-data with the part `file`; 413 past the limit
(--attachment-max-mb, default 25); 400 for a name with nothing usable; 404 for an unknown task; a name that exists is
stored as "name (1).ext". The stored bytes are served again by GET /attachments/<id>.

State (GET /__fixture/state → "kanban_attachments"): {"uploads": [{"task","filename","size","parts":[names],"file_parts":n}]}
"""
import re

UPLOADS = []
STORED = {}     # attachment id -> (content type, bytes)
COUNTER = [0]
PREFIX = '/api/plugins/kanban'


def seed():
    UPLOADS.clear(); STORED.clear(); COUNTER[0] = 0


def state(): return {'uploads': list(UPLOADS)}


def find_task(task_id):
    for board in ctx.pages.BOARDS.values():
        task = board['tasks'].get(task_id)
        if task is not None: return task
    return None


def parts(handler):
    """[(name, filename | None, content type, bytes)] of a multipart body."""
    match = re.search(r'boundary=("?)([^";]+)\1', handler.headers.get('Content-Type') or '')
    if not match: return None
    boundary = b'--' + match.group(2).encode()
    out = []
    for chunk in handler.raw_body.split(boundary)[1:]:
        if chunk.startswith(b'--'): break
        head, _, data = chunk.partition(b'\r\n\r\n')
        if data.endswith(b'\r\n'): data = data[:-2]
        text = head.decode('utf-8', 'replace')
        name = re.search(r'name="([^"]*)"', text)
        filename = re.search(r'filename="([^"]*)"', text)
        kind = re.search(r'Content-Type:\s*([^\r\n]+)', text, re.I)
        out.append((name.group(1) if name else '', filename.group(1) if filename else None, kind.group(1).strip() if kind else '', data))
    return out


def safe_name(raw):
    name = (raw or '').replace('\\', '/').split('/')[-1].strip()
    name = ''.join(ch for ch in name if ch.isprintable()).strip().lstrip('.').strip()
    return name[:200]


def collision_free(existing, name):
    stem, dot, ext = name.partition('.')
    candidate, n = name, 1
    while candidate in existing:
        candidate = f'{stem} ({n}){dot}{ext}'; n += 1
    return candidate


def rest(method, path, query, body, handler):
    if not path.startswith(PREFIX): return None
    sub = path[len(PREFIX):]
    if method == 'GET' and sub.startswith('/attachments/'):
        found = STORED.get(sub.split('/')[2])
        return (200, found) if found else None
    match = re.fullmatch(r'/tasks/([^/]+)/attachments', sub)
    if method != 'POST' or not match: return None
    with ctx.lock:
        task = find_task(match.group(1))
        if task is None: return 404, {'detail': f'task {match.group(1)} not found'}
        found = parts(handler)
        files = [p for p in (found or []) if p[0] == 'file' and p[1] is not None]
        if not files: return 422, {'detail': [{'loc': ['body', 'file'], 'msg': 'Field required'}]}
        _, filename, kind, data = files[0]
        limit = int(ctx.attachment_max_mb * 1024 * 1024)
        if len(data) > limit: return 413, {'detail': f'attachment exceeds {int(ctx.attachment_max_mb)} MB limit'}
        name = safe_name(filename)
        if not name: return 400, {'detail': 'invalid attachment filename'}
        name = collision_free({a['filename'] for a in task['attachments']}, name)
        COUNTER[0] += 1
        attachment = {'id': f'up{COUNTER[0]}', 'task_id': task['id'], 'filename': name, 'content_type': kind or 'application/octet-stream',
                      'size': len(data), 'stored_path': f'{ctx.home}/kanban/attachments/{task["id"]}/{name}', 'uploaded_by': 'dashboard'}
        task['attachments'].append(attachment)
        STORED[attachment['id']] = (attachment['content_type'], data)
        UPLOADS.append({'task': task['id'], 'filename': name, 'sent_as': filename, 'size': len(data), 'content_type': kind,
                        'parts': [p[0] for p in found], 'file_parts': len(files)})
    return 200, {'attachment': attachment}
