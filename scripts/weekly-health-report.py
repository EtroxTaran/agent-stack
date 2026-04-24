#!/usr/bin/env python3
"""
weekly-health-report.py — rendert JSON-Report aus weekly-health-report.sh
als Discord-Embed via Webhook.

Usage:
    weekly-health-report.sh | python3 weekly-health-report.py

Env:
    DISCORD_WEBHOOK_AGENT_STACK_HEALTH   Discord-Webhook-URL für Post.
    DRY_RUN=1                            Preview, kein API-Write.

Exit-Codes:
    0 — erfolgreich gepostet (oder dry-run)
    1 — Webhook-URL fehlt / ungültig
    2 — JSON-Parsing fehlgeschlagen
    3 — HTTP-Post fehlgeschlagen
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any


def build_embed(report: dict[str, Any]) -> dict[str, Any]:
    """Rendert JSON-Report als Discord-Embed."""
    status = report.get("status", "unknown")
    findings = report.get("findings", [])

    # Farben nach Status
    color_map = {
        "green": 0x43A047,  # grün
        "findings": 0xFB8C00,  # orange
        "fail": 0xE53935,  # rot
        "unknown": 0x757575,
    }
    color = color_map.get(status, 0x757575)

    # Titel + Emoji nach Status
    if status == "green":
        title = "🟢 Agent-Stack Health — All systems green"
        description = "Alle Checks grün: preflight, verify, drift-guard, MCP-Servers, Skills."
    elif status == "findings":
        title = f"🟡 Agent-Stack Health — {len(findings)} finding(s)"
        description = "Einige Checks zeigen Findings. Details unten."
    else:
        title = f"🔴 Agent-Stack Health — {status}"
        description = "Bericht-Generator hatte Probleme."

    # Felder aus den RESULTS extrahieren (ausser findings + metadata)
    exclude = {"findings", "status", "timestamp_utc", "repo"}
    fields = []
    for key, value in sorted(report.items()):
        if key in exclude:
            continue
        fields.append(
            {
                "name": key.replace("_", " ").title(),
                "value": f"`{value}`",
                "inline": True,
            }
        )

    # Findings als eigenes Feld (multiline)
    if findings:
        fields.append(
            {
                "name": f"Findings ({len(findings)})",
                "value": "\n".join(f"• {f}" for f in findings[:10]),
                "inline": False,
            }
        )

    return {
        "title": title,
        "description": description,
        "color": color,
        "timestamp": report.get("timestamp_utc"),
        "fields": fields,
        "footer": {
            "text": f"agent-stack · git {report.get('git_head', '?')} · branch {report.get('git_branch', '?')}",
        },
    }


def main() -> int:
    # JSON vom stdin lesen
    try:
        raw = sys.stdin.read()
        report = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"FEHLER: JSON-Parse — {exc}", file=sys.stderr)
        return 2

    # Embed bauen
    embed = build_embed(report)
    payload = {
        "username": "Agent-Stack Health",
        "embeds": [embed],
    }

    # Dry-Run: nur ausgeben, nicht posten
    if os.environ.get("DRY_RUN") == "1":
        print(json.dumps(payload, indent=2))
        return 0

    webhook_url = os.environ.get("DISCORD_WEBHOOK_AGENT_STACK_HEALTH")
    if not webhook_url:
        print(
            "FEHLER: DISCORD_WEBHOOK_AGENT_STACK_HEALTH nicht gesetzt",
            file=sys.stderr,
        )
        return 1

    # Lazy import: requests nur wenn wir wirklich posten
    try:
        import requests
    except ImportError:
        print(
            "FEHLER: python-requests fehlt — 'pip install --user requests'",
            file=sys.stderr,
        )
        return 3

    try:
        response = requests.post(webhook_url, json=payload, timeout=15)
        response.raise_for_status()
    except requests.RequestException as exc:
        print(f"FEHLER: Discord-Post — {exc}", file=sys.stderr)
        return 3

    print(f"OK: Health-Report gepostet (Status {report.get('status')}, {len(report.get('findings', []))} findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
