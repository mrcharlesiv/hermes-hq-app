#!/usr/bin/env python3
"""Compare NousResearch/hermes-agent releases against Hermes HQ (Swift + Windows).

Checks OpenRPC methods, WebSocket event maps, FastAPI REST routes, and client-facing
commits between two upstream tags (default: last audited tag in
docs/hermes-upstream-parity.md -> latest stable upstream tag) and cross-checks
coverage in HermesKit/, App/, and windows/src/.

Examples:
  python3 scripts/hermes-upstream-audit.py --fetch --check-latest
  python3 scripts/hermes-upstream-audit.py --repo /path/to/hermes-agent.git --from v0.23.4 --to v0.23.5
  python3 scripts/hermes-upstream-audit.py --fetch --from v0.23.0 --to v0.23.5 --json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

UPSTREAM_URL = "https://github.com/NousResearch/hermes-agent.git"
STABLE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
ROUTE_DECORATOR_RE = re.compile(
    r"""@\w+\.(get|post|put|patch|delete|websocket)\(\s*["']([^"']+)["']"""
)
TS_EVENT_INTERFACE_RE = re.compile(
    r"export interface (BackendGatewayEventMap|GatewayEvents|SessionEvents)\s*\{(.*?)\n\}",
    re.S,
)
TS_EVENT_KEY_RE = re.compile(r"'([^']+)'\s*:")
STRING_LITERAL_RE = re.compile(r'"([a-zA-Z0-9_./:{}-]+)"')
LAST_AUDITED_RE = re.compile(r"Last audited upstream tag:\s*`(v\d+\.\d+\.\d+)`")

CLIENT_FACING_PATHS = [
    "apps/desktop/src/",
    "apps/shared/",
    "web/src/",
    "hermes_cli/web_routers/",
    "hermes_cli/web_server.py",
    "tui_gateway/contracts/",
    "gateway/plugin_cards.py",
    "plugins/model-providers/",
]


@dataclass(frozen=True)
class Route:
    method: str
    path: str
    source: str


@dataclass
class AuditReport:
    from_tag: str
    to_tag: str
    total_rpc_methods: int
    total_ws_events: int
    total_rest_routes: int
    new_rpc_methods: list[dict[str, object]] = field(default_factory=list)
    new_ws_events: list[dict[str, object]] = field(default_factory=list)
    new_rest_routes: list[dict[str, object]] = field(default_factory=list)
    missing_rpc_methods: list[dict[str, str]] = field(default_factory=list)
    missing_ws_events: list[str] = field(default_factory=list)
    missing_rest_routes: list[dict[str, str]] = field(default_factory=list)
    client_commits: list[str] = field(default_factory=list)


def resolve_root() -> Path:
    if os.environ.get("HQ_REPO"):
        return Path(os.environ["HQ_REPO"]).resolve()
    return Path(__file__).resolve().parent.parent


def run_git(repo: Path, args: list[str], *, check: bool = True) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=check,
    )
    return proc.stdout


def parse_semver(tag: str) -> tuple[int, int, int] | None:
    match = STABLE_TAG_RE.match(tag.strip())
    if not match:
        return None
    major, minor, patch = int(match.group(1)), int(match.group(2)), int(match.group(3))
    # Hermes Agent switched from CalVer tags (e.g. v2026.9.24) to SemVer (v0.23.x).
    if major >= 2000:
        return None
    return (major, minor, patch)


def latest_stable_tag(tags: Iterable[str]) -> str | None:
    scored: list[tuple[tuple[int, int, int], str]] = []
    for raw in tags:
        tag = raw.strip()
        parsed = parse_semver(tag)
        if parsed is not None:
            scored.append((parsed, tag))
    if not scored:
        return None
    scored.sort()
    return scored[-1][1]


def read_last_audited_tag(ledger_path: Path) -> str | None:
    if not ledger_path.exists():
        return None
    match = LAST_AUDITED_RE.search(ledger_path.read_text(encoding="utf-8"))
    return match.group(1) if match else None


def default_cache_dir(root: Path) -> Path:
    common = run_git(root, ["rev-parse", "--git-common-dir"]).strip()
    common_path = Path(common)
    if not common_path.is_absolute():
        common_path = (root / common_path).resolve()
    return common_path / "hermes-upstream-cache.git"


def ensure_upstream_cache(cache_dir: Path, upstream_url: str = UPSTREAM_URL) -> Path:
    if not cache_dir.exists():
        cache_dir.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--bare", "--filter=blob:none", upstream_url, str(cache_dir)],
            check=True,
            capture_output=True,
            text=True,
        )
    else:
        subprocess.run(
            ["git", "-C", str(cache_dir), "fetch", "--tags", "--force", "origin"],
            check=True,
            capture_output=True,
            text=True,
        )
    return cache_dir


def extract_openrpc_methods(spec_text: str) -> dict[str, str]:
    spec = json.loads(spec_text)
    out: dict[str, str] = {}
    for item in spec.get("methods", []):
        name = item.get("name")
        if isinstance(name, str) and name:
            summary = item.get("summary") or item.get("description") or ""
            out[name] = str(summary).splitlines()[0].strip() if summary else ""
    return out


def extract_ws_events(generated_ts: str) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for match in TS_EVENT_INTERFACE_RE.finditer(generated_ts):
        for key in TS_EVENT_KEY_RE.findall(match.group(2)):
            if key not in seen:
                seen.add(key)
                found.append(key)
    return sorted(found)


def extract_routes_from_source(source_text: str, filename: str) -> list[Route]:
    routes: list[Route] = []
    for match in ROUTE_DECORATOR_RE.finditer(source_text):
        routes.append(Route(method=match.group(1).upper(), path=match.group(2), source=filename))
    return routes


def normalize_route_template(path: str) -> str:
    """Replace FastAPI `{param}` segments with `{}` so Swift/C# interpolations match structurally."""
    cleaned = re.sub(r"\{[^}]+\}", "{}", path.strip())
    return cleaned.rstrip("/") or "/"


def route_prefixes(path: str) -> list[str]:
    """Static route prefix before the first `{param}` (exact match when no params exist)."""
    if "{" not in path:
        return [path.rstrip("/") or "/"]
    prefix = path.split("{", 1)[0].rstrip("/")
    return [prefix] if prefix else []


def collect_hq_literals(root: Path, paths: tuple[str, ...] = ("HermesKit", "App", "windows/src")) -> tuple[set[str], set[str]]:
    """Collect exact quoted string literals and normalized `/api/...` route fragments from HQ sources."""
    literals: set[str] = set()
    api_fragments: set[str] = set()
    for rel in paths:
        base = root / rel
        if not base.exists():
            continue
        for file_path in base.rglob("*"):
            if not file_path.is_file() or file_path.suffix not in {".swift", ".cs"}:
                continue
            text = file_path.read_text(encoding="utf-8", errors="replace")
            for match in STRING_LITERAL_RE.finditer(text):
                token = match.group(1)
                literals.add(token)
            for match in re.finditer(r'"(/api/[^"\n]+)"', text):
                raw = match.group(1)
                # Normalize Swift `\(...)` and C# `{...}` interpolations to `{}`
                norm = re.sub(r"\\\([^)]+\)|\{[^}]+\}", "{}", raw)
                norm = norm.split("?", 1)[0].rstrip("/")
                if norm:
                    api_fragments.add(norm)
    return literals, api_fragments


def route_is_covered(route: Route, api_fragments: set[str]) -> bool:
    norm = normalize_route_template(route.path)
    if norm in api_fragments:
        return True
    if "{" in norm:
        # Match parameterized routes like `/api/messaging/catalog/{}/install` against `/api/messaging/catalog/{}/install`
        # or prefix+suffix fragments built via concatenation.
        parts = [p for p in norm.split("{}") if p and p != "/"]
        if len(parts) >= 2:
            head, tail = parts[0], parts[-1]
            for frag in api_fragments:
                if head in frag and tail in frag:
                    return True
        elif len(parts) == 1:
            prefix = parts[0].rstrip("/")
            if prefix in api_fragments or f"{prefix}/{{}}" in api_fragments:
                return True
    return False


def load_upstream_surface(upstream_repo: Path, tag: str) -> tuple[dict[str, str], list[str], list[Route]]:
    spec_text = run_git(upstream_repo, ["show", f"{tag}:apps/shared/src/gateway-contract.openrpc.json"])
    gen_ts = run_git(upstream_repo, ["show", f"{tag}:apps/shared/src/gateway-contract.generated.ts"])
    methods = extract_openrpc_methods(spec_text)
    events = extract_ws_events(gen_ts)

    files = run_git(
        upstream_repo,
        ["ls-tree", "-r", "--name-only", tag, "hermes_cli/web_routers", "hermes_cli/web_server.py"],
    ).splitlines()
    routes: list[Route] = []
    seen: set[tuple[str, str]] = set()
    for rel in sorted(files):
        if not rel.endswith(".py"):
            continue
        src = run_git(upstream_repo, ["show", f"{tag}:{rel}"])
        for route in extract_routes_from_source(src, rel):
            key = (route.method, route.path)
            if key not in seen:
                seen.add(key)
                routes.append(route)
    routes.sort(key=lambda r: (r.path, r.method))
    return methods, events, routes


def run_audit(hq_root: Path, upstream_repo: Path, from_tag: str, to_tag: str) -> AuditReport:
    from_methods, from_events, from_routes = load_upstream_surface(upstream_repo, from_tag)
    to_methods, to_events, to_routes = load_upstream_surface(upstream_repo, to_tag)

    swift_lits, swift_api = collect_hq_literals(hq_root, ("HermesKit", "App"))
    win_lits, win_api = collect_hq_literals(hq_root, ("windows/src",))
    all_lits = swift_lits | win_lits
    all_api = swift_api | win_api

    from_event_set = set(from_events)
    from_route_keys = {(r.method, r.path) for r in from_routes}

    new_rpc = []
    for name in sorted(set(to_methods) - set(from_methods)):
        new_rpc.append({
            "name": name,
            "summary": to_methods[name],
            "swift": name in swift_lits,
            "windows": name in win_lits,
        })

    new_events = []
    for ev in sorted(set(to_events) - from_event_set):
        new_events.append({
            "name": ev,
            "swift": ev in swift_lits,
            "windows": ev in win_lits,
        })

    new_routes = []
    for route in to_routes:
        if (route.method, route.path) not in from_route_keys:
            new_routes.append({
                "method": route.method,
                "path": route.path,
                "source": route.source,
                "swift": route_is_covered(route, swift_api),
                "windows": route_is_covered(route, win_api),
            })

    missing_rpc = [
        {"name": name, "summary": to_methods[name]}
        for name in sorted(to_methods)
        if name not in all_lits
    ]
    missing_events = [ev for ev in to_events if ev not in all_lits]
    missing_routes = [
        {"method": r.method, "path": r.path, "source": r.source}
        for r in to_routes
        if not route_is_covered(r, all_api)
    ]

    commits_out = run_git(
        upstream_repo,
        ["log", "--no-merges", "--oneline", f"{from_tag}..{to_tag}", "--", *CLIENT_FACING_PATHS],
    )
    client_commits = [line for line in commits_out.splitlines() if line.strip()]

    return AuditReport(
        from_tag=from_tag,
        to_tag=to_tag,
        total_rpc_methods=len(to_methods),
        total_ws_events=len(to_events),
        total_rest_routes=len(to_routes),
        new_rpc_methods=new_rpc,
        new_ws_events=new_events,
        new_rest_routes=new_routes,
        missing_rpc_methods=missing_rpc,
        missing_ws_events=missing_events,
        missing_rest_routes=missing_routes,
        client_commits=client_commits,
    )


def format_markdown(report: AuditReport) -> str:
    lines = [
        f"# Hermes Agent Upstream Audit: `{report.from_tag}` → `{report.to_tag}`",
        "",
        f"- OpenRPC methods at `{report.to_tag}`: **{report.total_rpc_methods}** ({len(report.missing_rpc_methods)} unmatched in HQ)",
        f"- WebSocket events at `{report.to_tag}`: **{report.total_ws_events}** ({len(report.missing_ws_events)} unmatched in HQ)",
        f"- REST routes at `{report.to_tag}`: **{report.total_rest_routes}** ({len(report.missing_rest_routes)} unmatched in HQ)",
        f"- Client-facing commits in window: **{len(report.client_commits)}**",
        "",
        "## Delta in This Release Window",
        "",
        f"### New OpenRPC Methods ({len(report.new_rpc_methods)})",
    ]
    if report.new_rpc_methods:
        for item in report.new_rpc_methods:
            cov = f"Swift={'yes' if item['swift'] else 'no'}, Windows={'yes' if item['windows'] else 'no'}"
            lines.append(f"- `{item['name']}` ({cov}) — {item['summary']}")
    else:
        lines.append("- None")

    lines += ["", f"### New WebSocket Events ({len(report.new_ws_events)})"]
    if report.new_ws_events:
        for item in report.new_ws_events:
            cov = f"Swift={'yes' if item['swift'] else 'no'}, Windows={'yes' if item['windows'] else 'no'}"
            lines.append(f"- `{item['name']}` ({cov})")
    else:
        lines.append("- None")

    lines += ["", f"### New REST Routes ({len(report.new_rest_routes)})"]
    if report.new_rest_routes:
        for item in report.new_rest_routes:
            cov = f"Swift={'yes' if item['swift'] else 'no'}, Windows={'yes' if item['windows'] else 'no'}"
            lines.append(f"- `{item['method']} {item['path']}` ({cov}) — `{item['source']}`")
    else:
        lines.append("- None")

    lines += ["", f"### Client-Facing Commits ({len(report.client_commits)})"]
    for commit in report.client_commits[:60]:
        lines.append(f"- `{commit}`")
    if len(report.client_commits) > 60:
        lines.append(f"- … and {len(report.client_commits) - 60} more")

    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit Hermes Agent upstream releases against Hermes HQ.")
    parser.add_argument("--repo", type=Path, help="Path to a local/bare NousResearch/hermes-agent git repository.")
    parser.add_argument("--fetch", action="store_true", help="Clone or refresh the blobless bare upstream cache.")
    parser.add_argument("--from", dest="from_tag", help="Baseline upstream tag (defaults to docs/hermes-upstream-parity.md).")
    parser.add_argument("--to", dest="to_tag", help="Target upstream tag (defaults to latest stable vX.Y.Z tag).")
    parser.add_argument("--check-latest", action="store_true", help="Exit 2 if a newer stable upstream release exists.")
    parser.add_argument("--json", action="store_true", help="Print structured JSON instead of Markdown.")
    args = parser.parse_args(argv)

    root = resolve_root()
    ledger = root / "docs" / "hermes-upstream-parity.md"

    upstream = args.repo
    if upstream is None:
        cache = default_cache_dir(root)
        if args.fetch or not cache.exists():
            upstream = ensure_upstream_cache(cache)
        else:
            upstream = cache
    elif args.fetch:
        ensure_upstream_cache(upstream)

    tags = run_git(upstream, ["tag", "--list"]).splitlines()
    latest = latest_stable_tag(tags)
    if not latest:
        print("No stable vX.Y.Z tags found in upstream repository.", file=sys.stderr)
        return 1

    from_tag = args.from_tag or read_last_audited_tag(ledger) or latest
    to_tag = args.to_tag or latest

    if args.check_latest:
        from_ver = parse_semver(from_tag)
        to_ver = parse_semver(to_tag)
        if from_ver and to_ver and to_ver > from_ver:
            print(f"UPDATE_AVAILABLE: {from_tag} -> {to_tag}")
            report = run_audit(root, upstream, from_tag, to_tag)
            print(json.dumps(report.__dict__, indent=2) if args.json else format_markdown(report))
            return 2
        print(f"UP_TO_DATE: {from_tag} (latest stable: {to_tag})")
        return 0

    report = run_audit(root, upstream, from_tag, to_tag)
    if args.json:
        print(json.dumps(report.__dict__, indent=2))
    else:
        print(format_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
