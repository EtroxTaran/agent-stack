#!/usr/bin/env python3
"""
provision_channels.py — Discord Guild Channel Provisioning für AI-Review.

Erstellt pro Projekt die Channels:
  #ai-review-<project>
  #ai-review-shadow-<project>

sowie einmalig:
  #ai-review-alerts-global  (cross-projekt Eskalationen)

Alle Channels landen in einer gemeinsamen Category "AI Review".

Idempotent: re-run erkennt existierende Channels per Name, kein Duplikat.
Fail-Open: schlägt ein Channel-Create fehl → Log + weiter, kein früher Exit.

Usage:
    python provision_channels.py --guild-id <id> --projects ai-portal,nathan-cockpit
    python provision_channels.py --guild-id <id> --projects ai-portal --dry-run
    python provision_channels.py --guild-id <id> --projects ai-portal --category "AI Review"

Environment:
    DISCORD_BOT_TOKEN  (required)
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from typing import Optional

import requests

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

DISCORD_API_BASE = "https://discord.com/api/v10"
CATEGORY_NAME = "AI Review"
ALERTS_CHANNEL_NAME = "ai-review-alerts-global"

# Discord Channel Types
CHANNEL_TYPE_TEXT = 0
CHANNEL_TYPE_CATEGORY = 4

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

def channel_name_for_project(project: str) -> tuple[str, str]:
    """
    Leitet Review- und Shadow-Channel-Namen aus Projektnamen ab.

    Returns:
        (review_channel_name, shadow_channel_name)
    """
    review_name = f"ai-review-{project}"
    shadow_name = f"ai-review-shadow-{project}"
    return review_name, shadow_name


# ---------------------------------------------------------------------------
# Discord Client
# ---------------------------------------------------------------------------

class DiscordClient:
    """Minimaler Discord REST API v10 Client (nur was für Channel-Provisioning nötig)."""

    def __init__(self, token: Optional[str] = None) -> None:
        if token is None:
            token = os.environ.get("DISCORD_BOT_TOKEN")
            if not token:
                raise EnvironmentError(
                    "DISCORD_BOT_TOKEN nicht gesetzt. "
                    "Bitte in ~/.openclaw/.env oder als env-var exportieren."
                )
        self.token = token
        self._headers = {
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
        }

    def list_guild_channels(self, guild_id: str) -> list[dict]:
        """Gibt alle Channels (inkl. Categories) des Guilds zurück."""
        url = f"{DISCORD_API_BASE}/guilds/{guild_id}/channels"
        response = requests.get(url, headers=self._headers, timeout=15)
        response.raise_for_status()
        return response.json()

    def create_channel(
        self,
        guild_id: str,
        name: str,
        channel_type: int = CHANNEL_TYPE_TEXT,
        parent_id: Optional[str] = None,
    ) -> dict:
        """Erstellt einen Channel im Guild. Gibt die erstellten Channel-Daten zurück."""
        url = f"{DISCORD_API_BASE}/guilds/{guild_id}/channels"
        payload: dict = {
            "name": name,
            "type": channel_type,
        }
        if parent_id:
            payload["parent_id"] = parent_id
        response = requests.post(url, headers=self._headers, json=payload, timeout=15)
        response.raise_for_status()
        return response.json()


# ---------------------------------------------------------------------------
# Core Provisioning Logic
# ---------------------------------------------------------------------------

def provision_guild(
    client: DiscordClient,
    guild_id: str,
    projects: list[str],
    dry_run: bool = False,
    category_name: str = CATEGORY_NAME,
) -> dict:
    """
    Legt alle benötigten Channels im Discord-Guild an.

    Idempotent: existierende Channels werden übersprungen.
    Fail-Open: Exception bei einem Channel → Log + weiter.

    Returns:
        Wenn dry_run=False: {"created": int, "skipped": int, "failed": int}
        Wenn dry_run=True:  {"would_create": int, "skipped": int}
    """
    # --- Bestandsaufnahme ---
    logger.info("Lade existierende Channels für Guild %s ...", guild_id)
    existing = client.list_guild_channels(guild_id)
    existing_names: set[str] = {ch["name"] for ch in existing}
    existing_categories: dict[str, str] = {
        ch["name"]: ch["id"] for ch in existing if ch["type"] == CHANNEL_TYPE_CATEGORY
    }

    created = 0
    skipped = 0
    failed = 0
    would_create = 0

    # --- Gewünschte Channels berechnen ---
    # 1. Category
    # 2. Pro Projekt: review + shadow
    # 3. Alerts-Global
    desired: list[dict] = []

    # Category zuerst (kein parent_id, type=4)
    desired.append({
        "name": category_name,
        "type": CHANNEL_TYPE_CATEGORY,
        "parent_id": None,
        "is_category": True,
    })

    for project in projects:
        review_name, shadow_name = channel_name_for_project(project)
        desired.append({"name": review_name, "type": CHANNEL_TYPE_TEXT, "parent_id": None})
        desired.append({"name": shadow_name, "type": CHANNEL_TYPE_TEXT, "parent_id": None})

    desired.append({
        "name": ALERTS_CHANNEL_NAME,
        "type": CHANNEL_TYPE_TEXT,
        "parent_id": None,
    })

    # --- Category-ID bestimmen / anlegen ---
    # Wird nach Category-Create bekannt; Text-Channels werden darunter gehängt.
    category_id: Optional[str] = existing_categories.get(category_name)

    for item in desired:
        name = item["name"]
        ch_type = item["type"]
        is_category = item.get("is_category", False)

        if name in existing_names:
            logger.info("  SKIP  %s (existiert bereits)", name)
            skipped += 1
            continue

        if dry_run:
            logger.info("  DRY   %s (würde erstellt werden)", name)
            would_create += 1
            continue

        # Für Text-Channels: parent_id = category_id (falls vorhanden)
        parent_id = None if is_category else category_id

        try:
            result = client.create_channel(
                guild_id=guild_id,
                name=name,
                channel_type=ch_type,
                parent_id=parent_id,
            )
            logger.info("  OK    %s (id=%s)", name, result.get("id", "?"))
            created += 1

            # Category-ID für nachfolgende Channels merken
            if is_category:
                category_id = result.get("id")

        except Exception as exc:
            logger.error("  FAIL  %s — %s", name, exc)
            failed += 1
            # Fail-Open: weitermachen mit nächstem Channel

    if dry_run:
        return {"would_create": would_create, "skipped": skipped}

    return {"created": created, "skipped": skipped, "failed": failed}


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Discord Guild Channel Provisioning für AI-Review",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Beispiele:
  python provision_channels.py --guild-id 1234567890 --projects ai-portal,nathan-cockpit
  python provision_channels.py --guild-id 1234567890 --projects ai-portal --dry-run
  python provision_channels.py --guild-id 1234567890 --projects ai-portal --category "AI Review"
""",
    )
    parser.add_argument(
        "--guild-id",
        required=True,
        help="Discord Guild (Server) ID",
    )
    parser.add_argument(
        "--projects",
        required=True,
        help="Komma-getrennte Projekt-Namen, z.B. ai-portal,nathan-cockpit",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Keine API-Calls, nur zeigen was gemacht werden würde",
    )
    parser.add_argument(
        "--category",
        default=CATEGORY_NAME,
        help=f'Name der Discord-Category (default: "{CATEGORY_NAME}")',
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Debug-Logging aktivieren",
    )

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if args.dry_run:
        logger.info("=== DRY-RUN MODE — keine API-Calls ===")

    projects = [p.strip() for p in args.projects.split(",") if p.strip()]
    if not projects:
        logger.error("Keine Projekte angegeben.")
        return 1

    try:
        client = DiscordClient()
    except EnvironmentError as exc:
        logger.error("%s", exc)
        return 1

    result = provision_guild(
        client=client,
        guild_id=args.guild_id,
        projects=projects,
        dry_run=args.dry_run,
        category_name=args.category,
    )

    if args.dry_run:
        logger.info(
            "Fertig (dry-run): %d würden erstellt, %d übersprungen.",
            result.get("would_create", 0),
            result.get("skipped", 0),
        )
    else:
        logger.info(
            "Fertig: %d erstellt, %d übersprungen, %d fehlgeschlagen.",
            result.get("created", 0),
            result.get("skipped", 0),
            result.get("failed", 0),
        )
        if result.get("failed", 0) > 0:
            logger.warning(
                "%d Channel(s) konnten nicht erstellt werden. "
                "Bitte Logs prüfen und ggf. manuell anlegen.",
                result["failed"],
            )
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
