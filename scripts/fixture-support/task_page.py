"""A task's Task Page (0.9.38, owner 2026-11-05: "a page that you could bring up … a specific skill that controls how
it's designed so the user can very easily visualize everything that's going on with the task and where it all
stands"): one HTML page drawn from the task itself (its status, steps, what was made, its history) and what its bot
wrote on it with ``tasks_update(page=…)`` (where it stands, what's next, its findings). The bot writes words, never
HTML: every page is ``skills/task-page/template.html`` filled in here, so every task's page has the one look.

Served by ``GET /tasks/{id}/page`` (dashboard/plugin_api.py); the app opens it live. Pure functions, no Hermes
imports, and nothing here is logged (a task's words never go into logs)."""
from __future__ import annotations

import html
import re
from datetime import datetime
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent / "skills" / "task-page" / "template.html"
TIMELINE_SHOWN = 6

STATUS = {"open": ("To Do", "t-plain"), "working": ("Working", "t-working"), "ready": ("Ready for You", "t-ready"),
          "needs_you": ("Needs You", "t-needs"), "done": ("Done", "t-done")}

# Small line icons (SF Symbols' doc / link / note shapes), drawn in the page's tint.
_ICONS = {
    "file": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            'stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/>'
            '<path d="M14 3v5h5"/></svg>',
    "link": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            'stroke-linejoin="round"><path d="M10 14a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/>'
            '<path d="M14 10a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg>',
    "note": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            'stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg>',
}


def _e(text) -> str:
    return html.escape(str(text or ""), quote=True)


# -- the bot's Markdown, a small safe part of it --------------------------------------------------------------------

_SAFE_URL = re.compile(r"^(https?://|mailto:|tel:)", re.I)


def _inline(text: str) -> str:
    """One line of Markdown to HTML: escaped first, then `code`, [links](https://…), **bold** and *italic*."""
    out, codes = _e(text), []

    def keep(match):
        codes.append(f"<code>{match.group(1)}</code>")
        return f"\x00{len(codes) - 1}\x00"

    out = re.sub(r"`([^`]+)`", keep, out)

    def link(match):
        label, url = match.group(1), html.unescape(match.group(2))
        if not _SAFE_URL.match(url):
            return label
        return f'<a href="{_e(url)}">{label}</a>'

    out = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, out)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", out)
    out = re.sub(r"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])", r"<em>\1</em>", out)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], out)


_BULLET = re.compile(r"^\s*[-*•]\s+(.*)$")
_NUMBER = re.compile(r"^\s*\d+[.)]\s+(.*)$")
_TICK = re.compile(r"^\[( |x|X)\]\s+(.*)$")


def _table_cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def markdown(text: str) -> str:
    """Paragraphs, - lists (and - [ ] / - [x] ticks), 1. lists, ### headings, > quotes and | tables |."""
    lines, out, i = (text or "").split("\n"), [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1]):
            head = _table_cells(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(_table_cells(lines[i]))
                i += 1
            out.append(_table(head, rows))
            continue
        if heading := re.match(r"^\s*#{1,6}\s+(.*)$", line):
            out.append(f"<h3>{_inline(heading.group(1))}</h3>")
            i += 1
            continue
        if _BULLET.match(line) or _NUMBER.match(line):
            numbered = bool(_NUMBER.match(line)) and not _BULLET.match(line)
            pattern = _NUMBER if numbered else _BULLET
            items = []
            while i < len(lines) and pattern.match(lines[i]):
                items.append(pattern.match(lines[i]).group(1))
                i += 1
            ticks = not numbered and all(_TICK.match(item) for item in items)
            if ticks:
                body = "".join(
                    f'<li class="{"done" if _TICK.match(item).group(1) != " " else ""}"><span class="check"></span>'
                    f'<span class="grow">{_inline(_TICK.match(item).group(2))}</span></li>' for item in items)
                out.append(f'<ul class="tick">{body}</ul>')
            else:
                tag = "ol" if numbered else "ul"
                out.append(f"<{tag}>" + "".join(f"<li>{_inline(item)}</li>" for item in items) + f"</{tag}>")
            continue
        if line.lstrip().startswith(">"):
            quote = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                quote.append(lines[i].lstrip()[1:].strip())
                i += 1
            out.append("<blockquote>" + "<br>".join(_inline(q) for q in quote) + "</blockquote>")
            continue
        para = []
        while i < len(lines) and lines[i].strip() and not (
                _BULLET.match(lines[i]) or _NUMBER.match(lines[i]) or lines[i].lstrip().startswith(("|", ">", "#"))):
            para.append(_inline(lines[i].strip()))
            i += 1
        if not para:   # a lone "#hashtag" line or the like: as words
            para.append(_inline(lines[i].strip()))
            i += 1
        out.append("<p>" + "<br>".join(para) + "</p>")
    return "".join(out)


def _table(head: list[str], rows: list[list[str]]) -> str:
    width = max([len(head)] + [len(r) for r in rows]) if (head or rows) else 0
    th = "".join(f"<th>{_inline(c)}</th>" for c in head + [""] * (width - len(head))) if head else ""
    body = "".join("<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in r + [""] * (width - len(r))) + "</tr>"
                   for r in rows)
    return f'<div class="scroll"><table>{"<thead><tr>" + th + "</tr></thead>" if th else ""}<tbody>{body}</tbody></table></div>'


# -- the page ---------------------------------------------------------------------------------------------------------

def _time(iso: str, lead: str = "", fallback: str = "") -> str:
    """A <time> the page's script writes in the reader's own zone; until then (or with scripts off), the date."""
    if not iso:
        return ""
    shown = fallback
    if not shown:
        try:
            shown = datetime.fromisoformat(iso.replace("Z", "+00:00")).strftime("%b %-d, %-I:%M %p")
        except ValueError:
            shown = iso
    return f'<time datetime="{_e(iso)}" data-lead="{_e(lead)}">{_e(lead + shown)}</time>'


def _due(due: str) -> str:
    if not due:
        return ""
    if "T" in due:
        return f"<span>{_time(due, 'Due ')}</span>"
    return f"<span>{_time(due, 'Due ', due)}</span>"


def _who_line(task: dict, name) -> str:
    if task["who"] == "me":
        return "Yours"
    if task["who"] == "together":
        return f"You & {name(task.get('bot'))}"
    return name(task.get("bot"))


def _steps(task: dict, name) -> str:
    steps = task.get("steps") or []
    if not steps:
        return ""
    items = []
    for step in steps:
        who = "You" if step.get("who") == "me" else name(task.get("bot"))
        items.append(f'<li class="{"done" if step.get("done") else ""}"><span class="check"></span>'
                     f'<span class="grow">{_e(step.get("title"))}</span><span class="who">{_e(who)}</span></li>')
    return f'<h2>Steps</h2><ul class="card rows">{"".join(items)}</ul>'


def _block(block: dict) -> str:
    parts = [f"<h2>{_e(block['title'])}</h2>"]
    if block.get("numbers"):
        tiles = "".join(f'<div class="card"><b>{_e(n["value"])}</b><span>{_e(n["label"])}</span>'
                        + (f'<span class="small">{_e(n["note"])}</span>' if n.get("note") else "") + "</div>"
                        for n in block["numbers"])
        parts.append(f'<div class="numbers">{tiles}</div>')
    if block.get("text"):
        parts.append(f'<div class="card prose">{markdown(block["text"])}</div>')
    if block.get("table"):
        table = block["table"]
        parts.append(f'<div class="card">{_table(table.get("columns") or [], table.get("rows") or [])}</div>')
    return "<section>" + "".join(parts) + "</section>"


def _made(task: dict) -> str:
    made = task.get("made") or []
    if not made:
        return ""
    items = []
    for item in made:
        kind = item.get("kind") if item.get("kind") in _ICONS else "note"
        title = _e(item.get("title") or (item.get("ref") or "").rsplit("/", 1)[-1] or "Untitled")
        ref = item.get("ref") or ""
        if kind == "link" and _SAFE_URL.match(ref):
            shown = re.sub(r"^https?://(www\.)?", "", ref)[:80]
            body = f'<a href="{_e(ref)}">{title}</a><span class="sub">{_e(shown)}</span>'
        elif kind == "file":
            body = f'{title}<span class="sub">{_e(ref.rsplit("/", 1)[-1])}</span>'
        else:
            body = title + (f'<div class="note prose">{markdown(ref)}</div>' if ref else "")
        items.append(f'<li><span class="icon">{_ICONS[kind]}</span><span class="grow">{body}</span></li>')
    return f'<h2>Made</h2><ul class="card rows">{"".join(items)}</ul>'


def _timeline(task: dict, name) -> str:
    log = list(reversed(task.get("log") or []))
    log.append({"at": task.get("created_at"), "by": task.get("created_by"), "text": "Added"})
    def row(entry):
        by = entry.get("by") or ""
        who = "You" if by == "you" else name(by)
        return (f'<li><span class="grow">{_e(entry.get("text"))}</span>'
                f'<span class="sub">{_e(who)} · {_time(entry.get("at") or "")}</span></li>')
    shown = "".join(row(e) for e in log[:TIMELINE_SHOWN])
    rest = log[TIMELINE_SHOWN:]
    more = (f'<details><summary>Show {len(rest)} More</summary><ul class="rows timeline">'
            + "".join(row(e) for e in rest) + "</ul></details>") if rest else ""
    return f'<h2>Timeline</h2><div class="card" style="padding:0"><ul class="rows timeline">{shown}</ul>{more}</div>'


def render(task: dict, page: dict | None, names: dict | None = None) -> str:
    """The whole page for ``task`` (a tasks.Store task) and its bot's ``page`` (tasks.clean_page's shape), with
    ``names`` the app's display names by profile ("default" → "Hermes"); a profile without one is title-cased."""
    page, names = page or {}, names or {}

    def name(profile) -> str:
        profile = profile or "default"
        return names.get(profile) or ("Hermes" if profile == "default" else profile.replace("-", " ").replace("_", " ").title())

    status = task.get("status") or "open"
    word, tone = STATUS.get(status, STATUS["open"])
    steps = task.get("steps") or []
    done = sum(1 for s in steps if s.get("done"))
    facts = [f"<span>{_e(_who_line(task, name))}</span>", _due(task.get("due") or "")]
    if task.get("page_at") or task.get("updated_at"):
        facts.append(f"<span>{_time(task.get('page_at') or task.get('updated_at'), 'Updated ')}</span>")
    body = [f'<header><span class="status {tone}">{_e(word)}</span><h1>{_e(task.get("title"))}</h1>'
            f'<div class="facts">{"".join(f for f in facts if f)}</div></header>']

    if status == "needs_you" and task.get("status_note"):
        body.append(f'<section class="card needs"><h2>Needs you</h2><p>{_inline(task["status_note"])}</p></section>')

    summary = page.get("summary") or (task.get("status_note") if status != "needs_you" else "") or {
        "open": "Not started yet.", "working": "Under way.", "ready": "Ready for you.", "needs_you": "Waiting on you.",
        "done": "Done."}.get(status, "")
    stand = [f'<h2>Where it stands</h2><p class="summary">{_inline(summary)}</p>']
    if steps:
        share = round(100 * done / len(steps))
        stand.append(f'<div class="bar{" full" if done == len(steps) else ""}"><i style="width:{share}%"></i></div>'
                     f'<div class="small muted">{done} of {len(steps)} steps done</div>')
    if task.get("watch"):
        stand.append(f'<p class="small muted" style="margin-top:.5rem">Watching for {_e(task["watch"])}</p>')
    if page.get("next") and status != "done":
        stand.append(f'<div class="next"><span class="label">Next</span><span>{_inline(page["next"])}</span></div>')
    body.append(f'<section class="card">{"".join(stand)}</section>')

    body.append(_steps(task, name))
    body.extend(_block(b) for b in page.get("blocks") or [])
    body.append(_made(task))
    if task.get("notes"):
        body.append(f'<h2>Notes</h2><div class="card prose">{markdown(task["notes"])}</div>')
    body.append(_timeline(task, name))
    bot = name(task.get("bot")) if task.get("who") != "me" else "you"
    body.append(f'<p class="foot">Task Page · kept up to date by {_e(bot)}</p>')
    body.append('<button class="ask" data-hermes-send="Bring this task\'s Task Page up to date: check where it stands, '
                'then update it with tasks_update (page, steps, made, status).">Ask for an Update</button>')

    template = TEMPLATE.read_text(encoding="utf-8")
    return (template.replace("{{TITLE}}", _e(task.get("title")))
                    .replace("{{TASK_ID}}", _e(task.get("id")))
                    .replace("{{BODY}}", "\n".join(part for part in body if part)))
