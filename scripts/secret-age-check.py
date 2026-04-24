#!/usr/bin/env python3
"""
secret-age-check.py — Cross-Repo Secret-Age-Scanner.

Scannt GitHub-Actions-Secrets in allen EtroxTaran/*-Repos und öffnet
Rotation-Issues für Secrets älter als THRESHOLD_DAYS (default: 90).

Usage:
    secret-age-check.py --repos agent-stack,ai-portal,ai-review-pipeline
    secret-age-check.py --threshold-days 180 --dry-run
    secret-age-check.py --repos ai-portal --label rotation-needed

Env:
    GH_TOKEN (or GITHUB_TOKEN)   — PAT with read:org + repo scope (secrets API).
                                   Im GitHub-Actions-Context: ${{ secrets.CROSS_REPO_PAT }}.

Exit-Codes:
    0 — Scan erfolgreich, ggf. Issues erstellt
    1 — Setup-Fehler (fehlender Token, ungültige Repos)
    2 — GitHub-API-Fehler bei einem Repo (Scan teilweise unvollständig)

Idempotent: Existierende offene Rotation-Issues werden **nicht** dupliziert.
Stattdessen wird ein Comment am bestehenden Issue angefügt ("seen again").
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

# gh CLI printet manchmal ANSI-Codes auch bei file-redirect.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[mK]")

LOGGER = logging.getLogger("secret-age-check")

# Mapping Secret-Name-Prefix → Runbook-Anker in docs/wiki/50-runbooks/50-token-rotation.md
# Nur Secrets in diesem Mapping bekommen einen gezielten Runbook-Link.
RUNBOOK_ANCHORS = {
    "DISCORD_BOT_TOKEN": "1-discord-bot-token",
    "DISCORD_PUBLIC_KEY": "2-discord-public-key",
    "GITHUB_TOKEN": "3-github-personal-access-token-pat",
    "GH_TOKEN": "3-github-personal-access-token-pat",
    "CROSS_REPO_PAT": "3-github-personal-access-token-pat",
    "AUTO_MERGE_PAT": "3-github-personal-access-token-pat",
    "ANTHROPIC_API_KEY": "5-anthropic-api-key",
    "OPENAI_API_KEY": "6-openai-api-key",
    "GEMINI_API_KEY": "7-gemini-api-key",
    "TAILSCALE_OAUTH_CLIENT": "8-tailscale-oauth-credentials",
    "TAILSCALE_OAUTH_SECRET": "8-tailscale-oauth-credentials",
}

RUNBOOK_URL = (
    "https://github.com/EtroxTaran/agent-stack/blob/main/"
    "docs/wiki/50-runbooks/50-token-rotation.md"
)

# Label für alle Rotation-Issues (einheitlich für Filter + Dashboards)
ROTATION_LABEL = "secret-rotation"


def run_gh(args: list[str], check: bool = True) -> str:
    """Wrapper um `gh` CLI. Gibt stdout als str zurück.

    NO_COLOR=1 verhindert ANSI-Codes im Output (würde JSON-Parse breaken).
    """
    env = {**os.environ, "NO_COLOR": "1", "CLICOLOR": "0"}
    proc = subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {proc.stderr.strip()}")
    # ANSI-Codes strippen (gh CLI printet manchmal farbig, auch bei file-redirect)
    return _ANSI_RE.sub("", proc.stdout)


def list_secrets(repo: str) -> list[dict[str, Any]]:
    """Listet GitHub-Action-Secrets eines Repos mit created_at + updated_at.

    Nutzt page-based pagination manuell (nicht --paginate, weil gh das als
    mehrfach-JSON stream gibt). Secrets-List ist selten > 30, ein Request reicht
    meist; loop für total_count > per_page.
    """
    all_secrets: list[dict[str, Any]] = []
    page = 1
    while True:
        out = run_gh([
            "api",
            f"/repos/{repo}/actions/secrets?per_page=100&page={page}",
        ], check=False)
        if not out.strip():
            break
        try:
            data = json.loads(out)
        except json.JSONDecodeError as exc:
            LOGGER.warning("JSON-Parse fehlgeschlagen für %s (page %d): %s", repo, page, exc)
            break
        batch = data.get("secrets", [])
        all_secrets.extend(batch)
        total = data.get("total_count", len(all_secrets))
        if len(all_secrets) >= total or not batch:
            break
        page += 1
    return all_secrets


def days_since(iso_ts: str) -> int:
    """Gibt Tage seit iso_ts (UTC) zurück."""
    dt = datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
    now = datetime.now(timezone.utc)
    return (now - dt).days


def runbook_anchor(secret_name: str) -> str:
    """Findet den passenden Runbook-Anker oder Default."""
    for prefix, anchor in RUNBOOK_ANCHORS.items():
        if secret_name.startswith(prefix) or secret_name == prefix:
            return anchor
    return ""  # Keine spezifische Sektion


def existing_rotation_issue(repo: str, secret_name: str) -> int | None:
    """Findet offenes Rotation-Issue für einen Secret-Namen. Gibt Issue-Number zurück."""
    try:
        out = run_gh(
            [
                "issue", "list",
                "--repo", repo,
                "--state", "open",
                "--label", ROTATION_LABEL,
                "--search", f"in:title Rotate {secret_name}",
                "--json", "number,title",
                "--limit", "5",
            ]
        )
        issues = json.loads(out)
        for issue in issues:
            if f"Rotate {secret_name}" in issue.get("title", ""):
                return issue["number"]
    except (RuntimeError, json.JSONDecodeError) as exc:
        LOGGER.warning("Could not check existing issues for %s/%s: %s", repo, secret_name, exc)
    return None


def open_rotation_issue(
    repo: str,
    secret_name: str,
    age_days: int,
    dry_run: bool,
) -> None:
    """Öffnet oder aktualisiert ein Rotation-Issue."""
    anchor = runbook_anchor(secret_name)
    runbook_link = RUNBOOK_URL + (f"#{anchor}" if anchor else "")

    existing = existing_rotation_issue(repo, secret_name)
    if existing:
        comment = (
            f"🔔 Re-detected on {datetime.now(timezone.utc).strftime('%Y-%m-%d')} — "
            f"secret ist jetzt {age_days} Tage alt. Bitte zeitnah rotieren.\n\n"
            f"Runbook: {runbook_link}"
        )
        LOGGER.info("  [%s] existing issue #%d, adding comment", repo, existing)
        if not dry_run:
            run_gh(
                ["issue", "comment", str(existing), "--repo", repo, "--body", comment]
            )
        return

    title = f"Rotate {secret_name} (>{age_days} days old)"
    body = (
        f"## Problem\n\n"
        f"GitHub-Actions-Secret `{secret_name}` in `{repo}` ist **{age_days} Tage alt**.\n"
        f"Verizon DBIR 2025: 70% der Cloud-Breaches via stale credentials.\n\n"
        f"## Runbook\n\n"
        f"{runbook_link}\n\n"
        f"## Abschluss\n\n"
        f"Nach erfolgreicher Rotation:\n"
        f"1. Neues Secret via `gh secret set {secret_name}` setzen\n"
        f"2. Nächster `secret-rotation-check.yml`-Run findet das frische `created_at` und meldet nichts mehr\n"
        f"3. Issue schließen\n\n"
        f"---\n"
        f"🤖 Auto-generated by [secret-rotation-check.yml]"
        f"(https://github.com/EtroxTaran/agent-stack/blob/main/.github/workflows/secret-rotation-check.yml)"
    )
    LOGGER.info("  [%s] opening issue: %s", repo, title)
    if not dry_run:
        # Erstelle Label falls nicht vorhanden (idempotent, schnell silent-fail)
        run_gh(
            ["label", "create", ROTATION_LABEL,
             "--repo", repo,
             "--color", "FFA500",
             "--description", "Secret älter als Threshold — Rotation nötig"],
            check=False,
        )
        run_gh(
            ["issue", "create",
             "--repo", repo,
             "--title", title,
             "--body", body,
             "--label", ROTATION_LABEL]
        )


def scan_repo(repo: str, threshold_days: int, dry_run: bool) -> dict[str, int]:
    """Scannt ein Repo. Gibt Statistik zurück."""
    stats = {"secrets": 0, "stale": 0, "errors": 0}
    try:
        secrets = list_secrets(repo)
    except RuntimeError as exc:
        LOGGER.error("Fehler beim Listen von Secrets in %s: %s", repo, exc)
        stats["errors"] = 1
        return stats

    stats["secrets"] = len(secrets)
    LOGGER.info("[%s] %d secrets gefunden", repo, len(secrets))

    for secret in secrets:
        name = secret.get("name", "?")
        created_at = secret.get("created_at", "")
        if not created_at:
            continue
        age = days_since(created_at)
        if age > threshold_days:
            LOGGER.info("  STALE  %s (%d days)", name, age)
            stats["stale"] += 1
            open_rotation_issue(repo, name, age, dry_run)
        else:
            LOGGER.debug("  ok     %s (%d days)", name, age)
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--repos",
        default="agent-stack,ai-portal,ai-review-pipeline",
        help="CSV von <repo>-Namen unter EtroxTaran/*. Default deckt alle aktiven Repos.",
    )
    parser.add_argument(
        "--owner",
        default="EtroxTaran",
        help="GitHub-Owner-Prefix (default: EtroxTaran)",
    )
    parser.add_argument(
        "--threshold-days",
        type=int,
        default=90,
        help="Age-Threshold in Tagen (default: 90)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Kein Issue-Create, nur Report",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Debug-Logs",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    # GH_TOKEN muss gesetzt sein für gh CLI
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        LOGGER.error("GH_TOKEN (oder GITHUB_TOKEN) nicht gesetzt.")
        return 1

    repos = [f"{args.owner}/{r.strip()}" for r in args.repos.split(",") if r.strip()]
    total = {"secrets": 0, "stale": 0, "errors": 0}
    for repo in repos:
        stats = scan_repo(repo, args.threshold_days, args.dry_run)
        for k in total:
            total[k] += stats[k]

    LOGGER.info(
        "SUMMARY: %d secrets total, %d stale (>%d days), %d errors.%s",
        total["secrets"],
        total["stale"],
        args.threshold_days,
        total["errors"],
        " [DRY-RUN]" if args.dry_run else "",
    )

    return 2 if total["errors"] > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
