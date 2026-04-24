"""Tests für scripts/model-registry-drift-check.py.

Alle Tests mocken die HTTP-Fetchers (kein Network in Unit-Tests).
Vendor-API-Response-Shapes sind in https://docs.anthropic.com +
https://platform.openai.com/docs/api-reference/models + https://ai.google.dev/api/models
dokumentiert; wir bilden die relevanten Felder nach.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

# Script-Filename hat Hyphens (shell-Convention) → nicht direkt importable.
# Wir laden es via importlib.util.spec_from_file_location.
_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "model-registry-drift-check.py"
_SPEC = importlib.util.spec_from_file_location("model_registry_drift_check", _SCRIPT_PATH)
assert _SPEC and _SPEC.loader, f"Konnte Spec für {_SCRIPT_PATH} nicht laden"
drift_check = importlib.util.module_from_spec(_SPEC)
sys.modules["model_registry_drift_check"] = drift_check
_SPEC.loader.exec_module(drift_check)


class AnthropicFetcherTests(unittest.TestCase):
    """fetch_anthropic_models sortiert nach created_at DESC + filtert Preview-Suffix."""

    def test_picks_newest_from_each_family(self) -> None:
        fake_response = {
            "data": [
                {"id": "claude-opus-4-7", "created_at": "2026-04-20T00:00:00Z"},
                {"id": "claude-opus-4-6", "created_at": "2026-02-15T00:00:00Z"},
                {"id": "claude-sonnet-4-6", "created_at": "2026-04-10T00:00:00Z"},
                {"id": "claude-sonnet-4-5", "created_at": "2026-02-01T00:00:00Z"},
                {"id": "claude-haiku-4-5", "created_at": "2026-04-01T00:00:00Z"},
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_anthropic_models("fake-key")

        self.assertEqual(result["CLAUDE_OPUS"], "claude-opus-4-7")
        self.assertEqual(result["CLAUDE_SONNET"], "claude-sonnet-4-6")
        self.assertEqual(result["CLAUDE_HAIKU"], "claude-haiku-4-5")

    def test_sorts_by_created_at_not_list_order(self) -> None:
        # Regression: Challenge-Agent-Blindspot — API-Response-Reihenfolge
        # ist nicht garantiert chronologisch. Explicit-Sort nötig.
        fake_response = {
            "data": [
                # Reihenfolge in der Response ist alphabetisch — NICHT chronologisch
                {"id": "claude-opus-4-5", "created_at": "2025-12-01T00:00:00Z"},
                {"id": "claude-opus-4-6", "created_at": "2026-02-15T00:00:00Z"},
                {"id": "claude-opus-4-7", "created_at": "2026-04-20T00:00:00Z"},
                {"id": "claude-sonnet-4-6", "created_at": "2026-04-10T00:00:00Z"},
                {"id": "claude-haiku-4-5", "created_at": "2026-04-01T00:00:00Z"},
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_anthropic_models("fake-key")

        # Neuestes Opus muss 4-7 sein, nicht 4-5 (erstes in Liste)
        self.assertEqual(result["CLAUDE_OPUS"], "claude-opus-4-7")

    def test_prefers_non_preview_variants(self) -> None:
        fake_response = {
            "data": [
                {"id": "claude-opus-5-0-preview", "created_at": "2026-04-25T00:00:00Z"},
                {"id": "claude-opus-4-7", "created_at": "2026-04-20T00:00:00Z"},
                {"id": "claude-sonnet-4-6", "created_at": "2026-04-10T00:00:00Z"},
                {"id": "claude-haiku-4-5", "created_at": "2026-04-01T00:00:00Z"},
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_anthropic_models("fake-key")

        # Preview nicht bevorzugt, auch wenn neuer
        self.assertEqual(result["CLAUDE_OPUS"], "claude-opus-4-7")

    def test_falls_back_to_preview_if_nothing_else(self) -> None:
        fake_response = {
            "data": [
                {"id": "claude-opus-5-0-preview", "created_at": "2026-04-25T00:00:00Z"},
                {"id": "claude-sonnet-4-6", "created_at": "2026-04-10T00:00:00Z"},
                {"id": "claude-haiku-4-5", "created_at": "2026-04-01T00:00:00Z"},
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_anthropic_models("fake-key")

        # Nur Preview verfügbar → nimm's halt
        self.assertEqual(result["CLAUDE_OPUS"], "claude-opus-5-0-preview")

    def test_empty_response_returns_empty_dict(self) -> None:
        with patch.object(drift_check, "_http_json", return_value={"data": []}):
            result = drift_check.fetch_anthropic_models("fake-key")
        self.assertEqual(result, {})

    def test_http_error_returns_empty_dict_not_raise(self) -> None:
        # Regression: Challenge-Agent-Blindspot — transienter Vendor-Outage darf
        # die Pipeline nicht rot färben. Fail-safe = leere Response + Warnung.
        import urllib.error
        with patch.object(drift_check, "_http_json", side_effect=urllib.error.URLError("503")):
            result = drift_check.fetch_anthropic_models("fake-key")
        self.assertEqual(result, {})


class GeminiFetcherTests(unittest.TestCase):
    def test_picks_highest_semver_pro(self) -> None:
        fake_response = {
            "models": [
                {"name": "models/gemini-2.5-pro"},
                {"name": "models/gemini-3-pro"},
                {"name": "models/gemini-3.1-pro-preview"},
                {"name": "models/gemini-3-flash-preview"},
                {"name": "models/gemini-3-flash-tts"},  # should skip (tts)
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_gemini_models("fake-key")

        # Highest semver pro is 3.1 (preview erlaubt hier weil Suffix dokumentiert)
        self.assertEqual(result["GEMINI_PRO"], "gemini-3.1-pro-preview")
        self.assertEqual(result["GEMINI_FLASH"], "gemini-3-flash-preview")

    def test_skips_tts_image_audio_variants(self) -> None:
        fake_response = {
            "models": [
                {"name": "models/gemini-3.1-pro-audio"},
                {"name": "models/gemini-3.1-pro-tts"},
                {"name": "models/gemini-3.1-pro"},
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_gemini_models("fake-key")
        self.assertEqual(result["GEMINI_PRO"], "gemini-3.1-pro")


class OpenAIFetcherTests(unittest.TestCase):
    def test_picks_latest_gpt5_main_skipping_codex_mini_preview(self) -> None:
        # Policy-Wechsel 2026-04: OPENAI_MAIN bevorzugt generische gpt-5.X
        # (nicht mehr -codex-Varianten). Codex-CLI nutzt das generische Modell.
        fake_response = {
            "data": [
                {"id": "gpt-5.5", "created": 1715000000},           # ← neuestes Main
                {"id": "gpt-5.5-codex", "created": 1715000000},     # skip (legacy -codex)
                {"id": "gpt-5.5-mini", "created": 1715000000},      # skip
                {"id": "gpt-5.3", "created": 1714000000},
                {"id": "gpt-4o", "created": 1710000000},            # skip (not gpt-5)
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_openai_models("fake-key")
        self.assertEqual(result["OPENAI_MAIN"], "gpt-5.5")

    def test_falls_back_to_codex_variant_if_no_clean_gpt5(self) -> None:
        # Wenn OpenAI mal nur -codex/-mini-Varianten exposed, trotzdem was zurückgeben
        fake_response = {
            "data": [
                {"id": "gpt-5.3-codex", "created": 1714000000},
                {"id": "gpt-5.3-codex-mini", "created": 1714000000},
            ]
        }
        with patch.object(drift_check, "_http_json", return_value=fake_response):
            result = drift_check.fetch_openai_models("fake-key")
        self.assertEqual(result["OPENAI_MAIN"], "gpt-5.3-codex")


class NpmCliPinsFetcherTests(unittest.TestCase):
    def test_extracts_major_version_pin(self) -> None:
        def fake_json(url: str, headers: dict) -> dict:
            if "codex" in url:
                return {"version": "2.5.1"}
            if "cursor-agent" in url:
                return {"version": "0.8.2"}
            return {}

        with patch.object(drift_check, "_http_json", side_effect=fake_json):
            result = drift_check.fetch_npm_cli_pins()

        self.assertEqual(result["CODEX_CLI_VERSION"], "^2")
        self.assertEqual(result["CURSOR_AGENT_CLI_VERSION"], "^0")


class RegistryIOTests(unittest.TestCase):
    def test_parse_registry_ignores_comments_and_blanks(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "MODEL_REGISTRY.env"
            path.write_text(
                "# header comment\n"
                "\n"
                "CLAUDE_OPUS=claude-opus-4-7\n"
                "# inline comment\n"
                "GEMINI_PRO=gemini-3.1-pro-preview\n"
            )
            result = drift_check.parse_registry(path)
        self.assertEqual(result["CLAUDE_OPUS"], "claude-opus-4-7")
        self.assertEqual(result["GEMINI_PRO"], "gemini-3.1-pro-preview")

    def test_update_registry_preserves_comments_and_order(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "MODEL_REGISTRY.env"
            path.write_text(
                "# Top comment\n"
                "CLAUDE_OPUS=claude-opus-4-6\n"
                "# middle\n"
                "GEMINI_PRO=gemini-2.5-pro\n"
            )
            drift_check.update_registry(path, {"GEMINI_PRO": "gemini-3.1-pro-preview"})
            content = path.read_text()
        # Kommentare bleiben, nur Wert wurde geändert
        self.assertIn("# Top comment", content)
        self.assertIn("CLAUDE_OPUS=claude-opus-4-6", content)  # unverändert
        self.assertIn("GEMINI_PRO=gemini-3.1-pro-preview", content)
        self.assertNotIn("gemini-2.5-pro", content)

    def test_update_registry_appends_new_keys(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "MODEL_REGISTRY.env"
            path.write_text("OLD_KEY=old\n")
            drift_check.update_registry(path, {"NEW_KEY": "new_value"})
            content = path.read_text()
        self.assertIn("OLD_KEY=old", content)
        self.assertIn("NEW_KEY=new_value", content)


class DriftComputationTests(unittest.TestCase):
    def test_reports_only_changed_keys(self) -> None:
        current = {"A": "1", "B": "2", "C": "3"}
        candidates = {"A": "1", "B": "22", "D": "4"}  # B geändert, D neu, C fehlt
        drift = drift_check.compute_drift(current, candidates)
        self.assertEqual(drift, {"B": "22", "D": "4"})

    def test_skips_empty_candidate_values(self) -> None:
        # Wenn ein Fetcher leeren String returnt (API 500 vielleicht), nicht propagieren
        current = {"A": "1"}
        candidates = {"A": ""}
        drift = drift_check.compute_drift(current, candidates)
        self.assertEqual(drift, {})


if __name__ == "__main__":
    unittest.main()
