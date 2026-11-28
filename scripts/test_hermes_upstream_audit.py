#!/usr/bin/env python3
"""Unit tests for scripts/hermes-upstream-audit.py."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent / "hermes-upstream-audit.py"
SPEC = importlib.util.spec_from_file_location("hermes_upstream_audit", SCRIPT_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


class HermesUpstreamAuditTests(unittest.TestCase):
    def test_latest_stable_tag_ignores_canaries_rcs_and_legacy_calver(self) -> None:
        tags = [
            "v2026.9.24",
            "v0.23.3",
            "v0.23.4",
            "canary.20261128T064458Z-v0.23.5",
            "rc.2-v0.23.6",
            "v0.23.5",
            "v0.23.3+canary.20261120",
        ]
        self.assertEqual(AUDIT.latest_stable_tag(tags), "v0.23.5")

    def test_extract_ws_events_and_routes(self) -> None:
        ts = """
export interface BackendGatewayEventMap {
  'plugin.card': PluginCardPayload
  'platforms.changed': PlatformsChangedPayload
  'message.complete': MessageCompletePayload
}
"""
        self.assertEqual(
            AUDIT.extract_ws_events(ts),
            ["message.complete", "platforms.changed", "plugin.card"],
        )

        py = """
@router.get("/api/messaging/platforms")
async def list_platforms(): pass

@router.post("/api/messaging/catalog/{name}/install")
async def install_catalog(): pass
"""
        routes = AUDIT.extract_routes_from_source(py, "hermes_cli/web_routers/messaging.py")
        self.assertEqual(
            [(r.method, r.path) for r in routes],
            [
                ("GET", "/api/messaging/platforms"),
                ("POST", "/api/messaging/catalog/{name}/install"),
            ],
        )

    def test_route_coverage_avoids_naive_prefix_false_positives(self) -> None:
        # Having /api/messaging/platforms must NOT mark /api/messaging/platforms/signature as covered.
        api_frags = {"/api/messaging/platforms", "/api/messaging/catalog/{}/install"}
        sig = AUDIT.Route("GET", "/api/messaging/platforms/signature", "messaging.py")
        cat = AUDIT.Route("POST", "/api/messaging/catalog/{name}/install", "messaging.py")
        self.assertFalse(AUDIT.route_is_covered(sig, api_frags))
        self.assertTrue(AUDIT.route_is_covered(cat, api_frags))

    def test_end_to_end_audit_between_two_synthetic_tags(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            upstream = base / "upstream"
            hq = base / "hq"
            upstream.mkdir()
            hq.mkdir()

            _git(upstream, "init")
            _git(upstream, "config", "user.email", "test@example.com")
            _git(upstream, "config", "user.name", "Test User")

            # v0.23.4 snapshot
            (upstream / "apps" / "shared" / "src").mkdir(parents=True)
            (upstream / "hermes_cli" / "web_routers").mkdir(parents=True)
            (upstream / "apps" / "shared" / "src" / "gateway-contract.openrpc.json").write_text(
                json.dumps({"methods": [{"name": "session.list", "summary": "List sessions"}]}),
                encoding="utf-8",
            )
            (upstream / "apps" / "shared" / "src" / "gateway-contract.generated.ts").write_text(
                "export interface BackendGatewayEventMap {\n  'message.start': {}\n}\n",
                encoding="utf-8",
            )
            (upstream / "hermes_cli" / "web_routers" / "messaging.py").write_text(
                '@router.get("/api/messaging/platforms")\ndef list_it(): pass\n',
                encoding="utf-8",
            )
            _git(upstream, "add", ".")
            _git(upstream, "commit", "-m", "v0.23.4 baseline")
            _git(upstream, "tag", "v0.23.4")

            # v0.23.5 snapshot adds plugin.card, bot_delivery.list, and catalog install route
            (upstream / "apps" / "shared" / "src" / "gateway-contract.openrpc.json").write_text(
                json.dumps({
                    "methods": [
                        {"name": "session.list", "summary": "List sessions"},
                        {"name": "bot_delivery.list", "summary": "Unsettled teammate deliveries"},
                    ]
                }),
                encoding="utf-8",
            )
            (upstream / "apps" / "shared" / "src" / "gateway-contract.generated.ts").write_text(
                "export interface BackendGatewayEventMap {\n  'message.start': {}\n  'plugin.card': {}\n}\n",
                encoding="utf-8",
            )
            (upstream / "hermes_cli" / "web_routers" / "messaging.py").write_text(
                '@router.get("/api/messaging/platforms")\ndef list_it(): pass\n'
                '@router.post("/api/messaging/catalog/{name}/install")\ndef install(): pass\n',
                encoding="utf-8",
            )
            _git(upstream, "add", ".")
            _git(upstream, "commit", "-m", "feat(messaging): catalog install and plugin card")
            _git(upstream, "tag", "v0.23.5")

            # Synthetic HQ repo covering plugin.card and catalog install in Swift, not bot_delivery.list
            (hq / "HermesKit").mkdir()
            (hq / "windows" / "src").mkdir(parents=True)
            (hq / "HermesKit" / "Sample.swift").write_text(
                'let ev = "plugin.card"\nlet path = "/api/messaging/catalog/\\(name)/install"\nlet a = "/api/messaging/platforms"\n',
                encoding="utf-8",
            )
            (hq / "windows" / "src" / "Sample.cs").write_text(
                'var m = "session.list";\nvar e = "message.start";\n',
                encoding="utf-8",
            )

            report = AUDIT.run_audit(hq, upstream, "v0.23.4", "v0.23.5")
            self.assertEqual([m["name"] for m in report.new_rpc_methods], ["bot_delivery.list"])
            self.assertFalse(report.new_rpc_methods[0]["swift"])
            self.assertEqual([e["name"] for e in report.new_ws_events], ["plugin.card"])
            self.assertTrue(report.new_ws_events[0]["swift"])
            self.assertEqual([r["path"] for r in report.new_rest_routes], ["/api/messaging/catalog/{name}/install"])
            self.assertTrue(report.new_rest_routes[0]["swift"])
            self.assertEqual([m["name"] for m in report.missing_rpc_methods], ["bot_delivery.list"])


if __name__ == "__main__":
    unittest.main()
