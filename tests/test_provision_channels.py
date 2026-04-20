"""
Tests für provision-channels.py (Discord Channel Provisioning).

TDD — Red Phase: Tests vor der Implementierung.
Pattern: Arrange-Act-Assert (AAA).
Mocking: unittest.mock für requests-Calls.
"""

import json
import os
import sys
import unittest
from io import StringIO
from unittest.mock import MagicMock, call, patch

# Ensure the discord-bot dir is on the path so we can import the module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ops", "discord-bot"))

import provision_channels
from provision_channels import (
    DiscordClient,
    channel_name_for_project,
    provision_guild,
)


# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

def make_channel(name: str, channel_id: str = "99") -> dict:
    """Erstellt ein minimales Discord-Channel-Dict (wie von der API zurückgegeben)."""
    return {"id": channel_id, "name": name, "type": 0}


def make_category(name: str, category_id: str = "10") -> dict:
    """Erstellt ein minimales Discord-Category-Dict."""
    return {"id": category_id, "name": name, "type": 4}


# ---------------------------------------------------------------------------
# Test 1: channel_name_for_project — Name-Ableitung
# ---------------------------------------------------------------------------

class TestChannelNameForProject(unittest.TestCase):
    """Prüft die reine Namens-Ableitung (keine API-Calls)."""

    def test_project_channel_names_correct(self):
        """
        Arrange: Projektname 'ai-portal'
        Act: channel_name_for_project('ai-portal')
        Assert: gibt (review_name, shadow_name) Tupel korrekt zurück
        """
        # Arrange
        project = "ai-portal"

        # Act
        review_name, shadow_name = channel_name_for_project(project)

        # Assert
        self.assertEqual(review_name, "ai-review-ai-portal")
        self.assertEqual(shadow_name, "ai-review-shadow-ai-portal")

    def test_global_alerts_channel_name(self):
        """
        Arrange: Konstante ALERTS_CHANNEL_NAME
        Act: importieren
        Assert: exakter Name 'ai-review-alerts-global'
        """
        self.assertEqual(provision_channels.ALERTS_CHANNEL_NAME, "ai-review-alerts-global")


# ---------------------------------------------------------------------------
# Test 2: Happy Path — neue Channels werden erstellt
# ---------------------------------------------------------------------------

class TestProvisionGuildHappyPath(unittest.TestCase):
    """Neuer Guild, keine Channels vorhanden → alle werden erstellt."""

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_creates_channels_for_two_projects(self, mock_post, mock_get):
        """
        Arrange: GET /guilds/{id}/channels gibt leere Liste zurück.
        Act: provision_guild mit 2 Projekten aufrufen.
        Assert: POST wird für jeden Channel + 1 Category + 1 Alerts-Channel aufgerufen.
        """
        # Arrange
        mock_get.return_value = MagicMock(
            status_code=200,
            json=lambda: [],
            raise_for_status=lambda: None,
        )
        created_ids = iter(["10", "20", "30", "40", "50", "60"])
        def post_side_effect(url, **kwargs):
            resp = MagicMock()
            resp.status_code = 201
            name = kwargs.get("json", {}).get("name", "unknown")
            resp.json = lambda: {"id": next(created_ids), "name": name}
            resp.raise_for_status = lambda: None
            return resp
        mock_post.side_effect = post_side_effect

        client = DiscordClient(token="fake-token")
        guild_id = "123"
        projects = ["ai-portal", "nathan-cockpit"]

        # Act
        result = provision_guild(client, guild_id, projects, dry_run=False)

        # Assert
        # 1 Category + 2 Projekte x 2 Channels + 1 Alerts-Global = 6 POST-Calls
        self.assertEqual(mock_post.call_count, 6)
        # result enthält summary mit created + skipped
        self.assertEqual(result["created"], 6)
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(result["failed"], 0)

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_creates_alerts_global_exactly_once(self, mock_post, mock_get):
        """
        Arrange: Leerer Guild, ein Projekt.
        Act: provision_guild.
        Assert: 'ai-review-alerts-global' Channel wird genau einmal erstellt.
        """
        # Arrange
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: [], raise_for_status=lambda: None,
        )
        created_calls = []
        def post_side_effect(url, **kwargs):
            name = kwargs.get("json", {}).get("name", "?")
            created_calls.append(name)
            resp = MagicMock()
            resp.status_code = 201
            resp.json = lambda: {"id": "11", "name": name}
            resp.raise_for_status = lambda: None
            return resp
        mock_post.side_effect = post_side_effect

        client = DiscordClient(token="fake-token")

        # Act
        provision_guild(client, "123", ["ai-portal"], dry_run=False)

        # Assert
        alerts_creates = [n for n in created_calls if n == "ai-review-alerts-global"]
        self.assertEqual(len(alerts_creates), 1)


# ---------------------------------------------------------------------------
# Test 3: Already-Exists-Skip — kein Duplikat
# ---------------------------------------------------------------------------

class TestProvisionGuildAlreadyExists(unittest.TestCase):
    """Channels existieren bereits → kein POST, skipped zählt korrekt."""

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_skips_existing_channels(self, mock_post, mock_get):
        """
        Arrange: GET liefert alle Channels + Category bereits vorhanden.
        Act: provision_guild
        Assert: POST wird NICHT aufgerufen; result['skipped'] == 3
        """
        # Arrange — Category + 2 Channels bereits da, kein Alerts-Channel
        existing = [
            make_category("AI Review", "10"),
            make_channel("ai-review-ai-portal", "20"),
            make_channel("ai-review-shadow-ai-portal", "30"),
        ]
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: existing, raise_for_status=lambda: None,
        )
        client = DiscordClient(token="fake-token")

        # Act
        result = provision_guild(client, "123", ["ai-portal"], dry_run=False)

        # Assert: 3 existing skipped, 1 alerts-global created (POST once)
        self.assertEqual(mock_post.call_count, 1)  # nur alerts-global
        self.assertEqual(result["skipped"], 3)
        self.assertEqual(result["created"], 1)

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_idempotent_full_existing_guild(self, mock_post, mock_get):
        """
        Arrange: Alle Channels + Alerts + Category bereits vorhanden.
        Act: provision_guild
        Assert: KEIN POST-Call, skipped = Category + 2 Channels + Alerts = 4
        """
        # Arrange
        existing = [
            make_category("AI Review", "10"),
            make_channel("ai-review-ai-portal", "20"),
            make_channel("ai-review-shadow-ai-portal", "30"),
            make_channel("ai-review-alerts-global", "40"),
        ]
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: existing, raise_for_status=lambda: None,
        )
        client = DiscordClient(token="fake-token")

        # Act
        result = provision_guild(client, "123", ["ai-portal"], dry_run=False)

        # Assert
        self.assertEqual(mock_post.call_count, 0)
        self.assertEqual(result["skipped"], 4)
        self.assertEqual(result["failed"], 0)


# ---------------------------------------------------------------------------
# Test 4: Fail-Continue — ein Channel-Create schlägt fehl, weiter mit nächstem
# ---------------------------------------------------------------------------

class TestProvisionGuildFailContinue(unittest.TestCase):
    """Wenn ein Channel-Create fehlschlägt → Log + weiter, kein früher Abbruch."""

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_continues_after_failed_channel_create(self, mock_post, mock_get):
        """
        Arrange: Zweiter POST-Call wirft Exception.
        Act: provision_guild mit 2 Projekten.
        Assert: Drittes POST wird noch aufgerufen; result['failed'] == 1.
        """
        # Arrange
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: [], raise_for_status=lambda: None,
        )
        call_count = {"n": 0}
        def post_side_effect(url, **kwargs):
            call_count["n"] += 1
            if call_count["n"] == 2:
                # zweiter Call schlägt fehl
                raise Exception("Discord API Error: 50013 Missing Permissions")
            name = kwargs.get("json", {}).get("name", "?")
            resp = MagicMock()
            resp.status_code = 201
            resp.json = lambda: {"id": str(call_count["n"]), "name": name}
            resp.raise_for_status = lambda: None
            return resp
        mock_post.side_effect = post_side_effect

        client = DiscordClient(token="fake-token")

        # Act
        result = provision_guild(client, "123", ["ai-portal", "nathan-cockpit"], dry_run=False)

        # Assert: mehr als 2 Calls → es hat weitergemacht
        self.assertGreater(mock_post.call_count, 2)
        self.assertEqual(result["failed"], 1)


# ---------------------------------------------------------------------------
# Test 5: Category-Create — Category wird angelegt wenn nicht vorhanden
# ---------------------------------------------------------------------------

class TestCategoryCreate(unittest.TestCase):
    """Wenn Category 'AI Review' nicht existiert → wird zuerst angelegt."""

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_category_created_first(self, mock_post, mock_get):
        """
        Arrange: Leerer Guild.
        Act: provision_guild.
        Assert: Erster POST-Call ist ein Category-Create (type=4).
        """
        # Arrange
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: [], raise_for_status=lambda: None,
        )
        post_calls_bodies = []
        def post_side_effect(url, **kwargs):
            post_calls_bodies.append(kwargs.get("json", {}))
            resp = MagicMock()
            resp.status_code = 201
            name = kwargs.get("json", {}).get("name", "?")
            resp.json = lambda: {"id": str(len(post_calls_bodies)), "name": name}
            resp.raise_for_status = lambda: None
            return resp
        mock_post.side_effect = post_side_effect

        client = DiscordClient(token="fake-token")

        # Act
        provision_guild(client, "123", ["ai-portal"], dry_run=False)

        # Assert: erstes POST ist type=4 (GUILD_CATEGORY)
        self.assertGreater(len(post_calls_bodies), 0)
        first_body = post_calls_bodies[0]
        self.assertEqual(first_body.get("type"), 4)
        self.assertEqual(first_body.get("name"), "AI Review")


# ---------------------------------------------------------------------------
# Test 6: Dry-Run — kein API-Call beim --dry-run
# ---------------------------------------------------------------------------

class TestDryRun(unittest.TestCase):
    """--dry-run führt KEINE POST-Calls aus, GET zur Prüfung ist erlaubt."""

    @patch("provision_channels.requests.get")
    @patch("provision_channels.requests.post")
    def test_dry_run_no_post_calls(self, mock_post, mock_get):
        """
        Arrange: Leerer Guild, dry_run=True.
        Act: provision_guild
        Assert: POST wird NIE aufgerufen.
        """
        # Arrange
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: [], raise_for_status=lambda: None,
        )
        client = DiscordClient(token="fake-token")

        # Act
        result = provision_guild(client, "123", ["ai-portal", "nathan-cockpit"], dry_run=True)

        # Assert
        mock_post.assert_not_called()
        # dry_run meldet would_create statt created
        self.assertIn("would_create", result)
        self.assertGreater(result["would_create"], 0)


# ---------------------------------------------------------------------------
# Test 7: DiscordClient — Token wird korrekt als Authorization-Header gesetzt
# ---------------------------------------------------------------------------

class TestDiscordClientHeaders(unittest.TestCase):
    """DiscordClient setzt Authorization + Content-Type Header korrekt."""

    @patch("provision_channels.requests.get")
    def test_authorization_header_set(self, mock_get):
        """
        Arrange: DiscordClient mit Token 'test-token-xyz'.
        Act: list_guild_channels aufrufen.
        Assert: Authorization-Header enthält 'Bot test-token-xyz'.
        """
        # Arrange
        mock_get.return_value = MagicMock(
            status_code=200, json=lambda: [], raise_for_status=lambda: None,
        )
        client = DiscordClient(token="test-token-xyz")

        # Act
        client.list_guild_channels("123")

        # Assert
        call_kwargs = mock_get.call_args
        headers = call_kwargs[1].get("headers", {}) if call_kwargs[1] else call_kwargs[0][1] if len(call_kwargs[0]) > 1 else {}
        # Flexibel: Header können als positional oder keyword übergeben sein
        if not headers:
            headers = mock_get.call_args.kwargs.get("headers", {})
        self.assertIn("Authorization", headers)
        self.assertEqual(headers["Authorization"], "Bot test-token-xyz")


# ---------------------------------------------------------------------------
# Test 8: DISCORD_BOT_TOKEN aus Environment lesen
# ---------------------------------------------------------------------------

class TestEnvironmentToken(unittest.TestCase):
    """DISCORD_BOT_TOKEN wird aus env gelesen, wenn nicht explizit übergeben."""

    def test_missing_token_raises(self):
        """
        Arrange: DISCORD_BOT_TOKEN nicht gesetzt.
        Act: DiscordClient() ohne token-Argument.
        Assert: EnvironmentError oder ValueError wird geraised.
        """
        # Arrange
        env_backup = os.environ.pop("DISCORD_BOT_TOKEN", None)

        try:
            # Act + Assert
            with self.assertRaises((EnvironmentError, ValueError, KeyError)):
                DiscordClient()
        finally:
            if env_backup is not None:
                os.environ["DISCORD_BOT_TOKEN"] = env_backup

    def test_token_from_env(self):
        """
        Arrange: DISCORD_BOT_TOKEN in env gesetzt.
        Act: DiscordClient() ohne explizites token.
        Assert: DiscordClient wird erstellt, token ist gesetzt.
        """
        # Arrange
        os.environ["DISCORD_BOT_TOKEN"] = "env-token-abc"
        try:
            # Act
            client = DiscordClient()

            # Assert
            self.assertEqual(client.token, "env-token-abc")
        finally:
            del os.environ["DISCORD_BOT_TOKEN"]


if __name__ == "__main__":
    unittest.main()
