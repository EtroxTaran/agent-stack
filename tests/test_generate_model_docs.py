"""Tests für scripts/generate-model-docs.py."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

# Filename mit Hyphens → spec-loader
_SCRIPT_PATH = (
    Path(__file__).resolve().parent.parent / "scripts" / "generate-model-docs.py"
)
_SPEC = importlib.util.spec_from_file_location("generate_model_docs", _SCRIPT_PATH)
assert _SPEC and _SPEC.loader
gen_docs = importlib.util.module_from_spec(_SPEC)
sys.modules["generate_model_docs"] = gen_docs
_SPEC.loader.exec_module(gen_docs)


class RenderTests(unittest.TestCase):
    def test_rendered_section_contains_registry_values(self) -> None:
        registry = {
            "CLAUDE_OPUS": "claude-opus-4-7",
            "CLAUDE_SONNET": "claude-sonnet-4-6",
            "CLAUDE_HAIKU": "claude-haiku-4-5",
            "GEMINI_PRO": "gemini-3.1-pro-preview",
            "GEMINI_FLASH": "gemini-3-flash-preview",
            "OPENAI_MAIN": "gpt-5.3-codex",
            "CODEX_CLI_VERSION": "^2",
            "CURSOR_AGENT_CLI_VERSION": "^0",
        }
        output = gen_docs.render_registry_section(registry)
        # Sanity: jeder Wert muss im Output auftauchen
        for v in registry.values():
            self.assertIn(v, output, f"Wert {v!r} fehlt im gerenderten Output")

    def test_rendered_section_starts_and_ends_with_markers(self) -> None:
        output = gen_docs.render_registry_section({"GEMINI_PRO": "x"})
        self.assertTrue(output.startswith(gen_docs.SECTION_START))
        self.assertTrue(output.endswith(gen_docs.SECTION_END))

    def test_missing_keys_rendered_as_placeholder(self) -> None:
        output = gen_docs.render_registry_section({})  # keine Keys
        self.assertIn("(nicht gepinnt)", output)


class ReplaceSectionTests(unittest.TestCase):
    def test_replaces_between_markers_only(self) -> None:
        before = f"""Intro-Text

{gen_docs.SECTION_START}
ALT-CONTENT
{gen_docs.SECTION_END}

Nach-Text
"""
        new = f"{gen_docs.SECTION_START}\nNEU\n{gen_docs.SECTION_END}"
        after = gen_docs.replace_section(before, new)
        self.assertIn("Intro-Text", after)
        self.assertIn("Nach-Text", after)
        self.assertIn("NEU", after)
        self.assertNotIn("ALT-CONTENT", after)

    def test_raises_when_markers_missing(self) -> None:
        before = "keine Marker hier"
        with self.assertRaises(ValueError) as ctx:
            gen_docs.replace_section(before, "x")
        self.assertIn("Marker", str(ctx.exception))


class WikiRenderTests(unittest.TestCase):
    """Tests für die zweite Render-Funktion (Wiki-Overview)."""

    def test_wiki_section_has_registry_values(self) -> None:
        registry = {
            "OPENAI_MAIN": "gpt-5.5",
            "GEMINI_PRO": "gemini-3.1-pro-preview",
            "CLAUDE_OPUS": "claude-opus-4-7",
        }
        output = gen_docs.render_wiki_review_stages(registry)
        self.assertIn("gpt-5.5", output)
        self.assertIn("gemini-3.1-pro-preview", output)
        self.assertIn("claude-opus-4-7", output)

    def test_wiki_section_starts_and_ends_with_wiki_markers(self) -> None:
        output = gen_docs.render_wiki_review_stages({"GEMINI_PRO": "x"})
        self.assertTrue(output.startswith(gen_docs.WIKI_SECTION_START))
        self.assertTrue(output.endswith(gen_docs.WIKI_SECTION_END))

    def test_wiki_section_has_distinct_markers_from_agents_section(self) -> None:
        """Sanity: AGENTS- und Wiki-Marker sind unterschiedlich."""
        self.assertNotEqual(gen_docs.SECTION_START, gen_docs.WIKI_SECTION_START)
        self.assertNotEqual(gen_docs.SECTION_END, gen_docs.WIKI_SECTION_END)


class EndToEndTests(unittest.TestCase):
    """Simuliert den ganzen Flow: Registry → AGENTS.md-Update."""

    def test_full_update_cycle(self) -> None:
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            registry_path = tmp_path / "MODEL_REGISTRY.env"
            registry_path.write_text(
                "CLAUDE_OPUS=claude-opus-4-7\n"
                "CLAUDE_SONNET=claude-sonnet-4-6\n"
                "CLAUDE_HAIKU=claude-haiku-4-5\n"
                "GEMINI_PRO=gemini-3.1-pro-preview\n"
                "GEMINI_FLASH=gemini-3-flash-preview\n"
                "OPENAI_MAIN=gpt-5.3-codex\n"
                "CODEX_CLI_VERSION=^2\n"
                "CURSOR_AGENT_CLI_VERSION=^0\n"
            )

            agents_md = tmp_path / "AGENTS.md"
            agents_md.write_text(
                f"# Header\n\n{gen_docs.SECTION_START}\nold content\n{gen_docs.SECTION_END}\n\nFooter\n"
            )

            exit_code = gen_docs.main(
                [
                    "--agents-md",
                    str(agents_md),
                    "--registry",
                    str(registry_path),
                ]
            )
            self.assertEqual(exit_code, 0)

            after = agents_md.read_text()
            self.assertIn("gemini-3.1-pro-preview", after)
            self.assertNotIn("old content", after)
            self.assertIn("# Header", after)
            self.assertIn("Footer", after)

    def test_check_mode_exits_1_on_drift(self) -> None:
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            registry_path = tmp_path / "r.env"
            registry_path.write_text(
                "CLAUDE_OPUS=claude-opus-4-7\n"
                "CLAUDE_SONNET=s\nCLAUDE_HAIKU=h\n"
                "GEMINI_PRO=g\nGEMINI_FLASH=gf\nOPENAI_MAIN=oc\n"
                "CODEX_CLI_VERSION=c\nCURSOR_AGENT_CLI_VERSION=cc\n"
            )
            agents_md = tmp_path / "AGENTS.md"
            agents_md.write_text(
                f"{gen_docs.SECTION_START}\nstale\n{gen_docs.SECTION_END}\n"
            )

            exit_code = gen_docs.main(
                [
                    "--agents-md",
                    str(agents_md),
                    "--registry",
                    str(registry_path),
                    "--check",
                ]
            )
            self.assertEqual(exit_code, 1)
            # Im Check-Mode darf die Datei NICHT geschrieben werden
            self.assertIn("stale", agents_md.read_text())

    def test_check_mode_exits_0_when_in_sync(self) -> None:
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            registry_path = tmp_path / "r.env"
            registry_path.write_text(
                "CLAUDE_OPUS=claude-opus-4-7\nCLAUDE_SONNET=s\nCLAUDE_HAIKU=h\n"
                "GEMINI_PRO=g\nGEMINI_FLASH=gf\nOPENAI_MAIN=oc\n"
                "CODEX_CLI_VERSION=c\nCURSOR_AGENT_CLI_VERSION=cc\n"
            )
            agents_md = tmp_path / "AGENTS.md"
            # Zuerst generieren, dann check
            registry = gen_docs.parse_registry(registry_path)
            section = gen_docs.render_registry_section(registry)
            agents_md.write_text(f"Header\n\n{section}\n\nFooter\n")

            exit_code = gen_docs.main(
                [
                    "--agents-md",
                    str(agents_md),
                    "--wiki-overview",
                    str(tmp_path / "no-such-wiki.md"),
                    "--registry",
                    str(registry_path),
                    "--check",
                ]
            )
            self.assertEqual(exit_code, 0)

    def test_wiki_full_update_cycle(self) -> None:
        """Beide Targets werden in einem Lauf regeneriert."""
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            registry_path = tmp_path / "r.env"
            registry_path.write_text(
                "CLAUDE_OPUS=claude-opus-4-7\nCLAUDE_SONNET=s\nCLAUDE_HAIKU=h\n"
                "GEMINI_PRO=gemini-3.1-pro-preview\nGEMINI_FLASH=gf\n"
                "OPENAI_MAIN=gpt-5.5\n"
                "CODEX_CLI_VERSION=c\nCURSOR_AGENT_CLI_VERSION=cc\n"
            )
            agents_md = tmp_path / "AGENTS.md"
            agents_md.write_text(
                f"# A\n\n{gen_docs.SECTION_START}\nstale\n{gen_docs.SECTION_END}\n"
            )
            wiki = tmp_path / "00-ueberblick.md"
            wiki.write_text(
                f"# W\n\n{gen_docs.WIKI_SECTION_START}\nold\n{gen_docs.WIKI_SECTION_END}\n"
            )

            exit_code = gen_docs.main(
                [
                    "--agents-md",
                    str(agents_md),
                    "--wiki-overview",
                    str(wiki),
                    "--registry",
                    str(registry_path),
                ]
            )
            self.assertEqual(exit_code, 0)

            self.assertIn("gemini-3.1-pro-preview", agents_md.read_text())
            wiki_after = wiki.read_text()
            self.assertIn("gpt-5.5", wiki_after)
            self.assertIn("gemini-3.1-pro-preview", wiki_after)
            self.assertIn("claude-opus-4-7", wiki_after)

    def test_wiki_check_mode_detects_drift(self) -> None:
        """--check erkennt Wiki-Drift und meldet Exit 1 auch wenn AGENTS in-sync ist."""
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            registry_path = tmp_path / "r.env"
            registry_path.write_text(
                "CLAUDE_OPUS=claude-opus-4-7\nCLAUDE_SONNET=s\nCLAUDE_HAIKU=h\n"
                "GEMINI_PRO=gemini-3.1-pro-preview\nGEMINI_FLASH=gf\n"
                "OPENAI_MAIN=gpt-5.5\n"
                "CODEX_CLI_VERSION=c\nCURSOR_AGENT_CLI_VERSION=cc\n"
            )
            registry = gen_docs.parse_registry(registry_path)
            agents_md = tmp_path / "AGENTS.md"
            agents_md.write_text(gen_docs.render_registry_section(registry))

            wiki = tmp_path / "00-ueberblick.md"
            wiki.write_text(
                f"{gen_docs.WIKI_SECTION_START}\nstale\n{gen_docs.WIKI_SECTION_END}\n"
            )

            exit_code = gen_docs.main(
                [
                    "--agents-md",
                    str(agents_md),
                    "--wiki-overview",
                    str(wiki),
                    "--registry",
                    str(registry_path),
                    "--check",
                ]
            )
            self.assertEqual(exit_code, 1)
            self.assertIn("stale", wiki.read_text())

    def test_wiki_missing_is_skip_not_error(self) -> None:
        """--wiki-overview auf nicht-existente Datei → Skip, kein Fehler."""
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            registry_path = tmp_path / "r.env"
            registry_path.write_text(
                "CLAUDE_OPUS=x\nCLAUDE_SONNET=s\nCLAUDE_HAIKU=h\n"
                "GEMINI_PRO=g\nGEMINI_FLASH=gf\nOPENAI_MAIN=oc\n"
                "CODEX_CLI_VERSION=c\nCURSOR_AGENT_CLI_VERSION=cc\n"
            )
            agents_md = tmp_path / "AGENTS.md"
            registry = gen_docs.parse_registry(registry_path)
            agents_md.write_text(gen_docs.render_registry_section(registry))

            missing_wiki = tmp_path / "gibts-nicht.md"
            exit_code = gen_docs.main(
                [
                    "--agents-md",
                    str(agents_md),
                    "--wiki-overview",
                    str(missing_wiki),
                    "--registry",
                    str(registry_path),
                ]
            )
            self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
