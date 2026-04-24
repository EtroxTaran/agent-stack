#!/usr/bin/env python3
"""Model-Registry-Drift-Check — agent-stack/scripts/model-registry-drift-check.py

Vergleicht die aktuell verfügbaren LLM-Modelle (Vendor-REST-APIs + CLI-npm-
Registries) gegen die committed Registry in `ai-review-pipeline/registry/
MODEL_REGISTRY.env`. Bei Drift wird das Registry-File aktualisiert und ein
PR in `EtroxTaran/ai-review-pipeline` eröffnet.

Läuft wöchentlich via `.github/workflows/model-registry-drift-check.yml`
(Montag 08:00 UTC).

Supported Vendors:
- Anthropic: `GET /v1/models` → sort by `created_at` DESC, extract Opus/Sonnet/Haiku
- OpenAI: `GET /v1/models` → regex-filter `codex`-Modelle
- Google Gemini: `GET /v1beta/models` → suffix-parse `gemini-<major>.<minor>-pro`
- npm Registry: `GET /@openai/codex/latest` + `GET /cursor-agent/latest` → CLI-Versionen

Usage:
  python3 model-registry-drift-check.py [--dry-run] [--output PATH]

Env-Vars (in GH-Actions via secrets):
  ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Registry-Layout (muss mit ai-review-pipeline/src/.../models.py synchron sein)
# ---------------------------------------------------------------------------

REQUIRED_KEYS: tuple[str, ...] = (
    "CLAUDE_OPUS", "CLAUDE_SONNET", "CLAUDE_HAIKU",
    "GEMINI_PRO", "GEMINI_FLASH",
    "OPENAI_CODING",
    "CODEX_CLI_VERSION", "CURSOR_AGENT_CLI_VERSION",
)


# ---------------------------------------------------------------------------
# Fetchers
# ---------------------------------------------------------------------------


def _http_json(url: str, headers: dict[str, str], timeout: int = 15) -> dict | list:
    """stdlib-only JSON GET — vermeidet Dependency auf requests."""
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read())


def fetch_anthropic_models(api_key: str) -> dict[str, str]:
    """Fetch Anthropic-Modelle via /v1/models.

    Sortiert nach `created_at` DESC (explicit — data[0] ist nicht garantiert neuestes).
    Extrahiert jeweils neuestes aus Opus/Sonnet/Haiku-Familie.
    Nicht-Production-Varianten (-beta, -preview-*) werden NICHT bevorzugt —
    nur falls nichts anderes verfügbar.
    """
    try:
        data = _http_json(
            "https://api.anthropic.com/v1/models",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
            },
        )
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as e:
        print(f"⚠️  Anthropic fetch failed: {e}", file=sys.stderr)
        return {}

    # Erwartetes Schema: { "data": [ {id, display_name, created_at, ...}, ... ] }
    items = data.get("data", []) if isinstance(data, dict) else []
    # Sort by created_at DESC (RFC-3339-Timestamps sind lex-sortierbar wenn Z)
    items.sort(key=lambda m: m.get("created_at", ""), reverse=True)

    def latest(family_prefix: str) -> str | None:
        """Erstes Modell mit passendem Prefix und ohne -beta/-experimental-Suffix."""
        preferred = None
        any_match = None
        for m in items:
            model_id = m.get("id", "")
            if not model_id.startswith(family_prefix):
                continue
            if any_match is None:
                any_match = model_id
            if not any(tag in model_id for tag in ("-beta", "-experimental", "-preview")):
                preferred = model_id
                break
        return preferred or any_match

    result: dict[str, str] = {}
    opus = latest("claude-opus-")
    sonnet = latest("claude-sonnet-")
    haiku = latest("claude-haiku-")
    if opus:
        result["CLAUDE_OPUS"] = opus
    if sonnet:
        result["CLAUDE_SONNET"] = sonnet
    if haiku:
        result["CLAUDE_HAIKU"] = haiku
    return result


def fetch_openai_models(api_key: str) -> dict[str, str]:
    """Fetch OpenAI-Modelle via /v1/models — Heuristik für Codex-Variante."""
    try:
        data = _http_json(
            "https://api.openai.com/v1/models",
            headers={"Authorization": f"Bearer {api_key}"},
        )
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as e:
        print(f"⚠️  OpenAI fetch failed: {e}", file=sys.stderr)
        return {}

    items = data.get("data", []) if isinstance(data, dict) else []
    # `created` ist Unix-Timestamp-Int — neuer → größer
    items.sort(key=lambda m: m.get("created", 0), reverse=True)

    # OPENAI_CODING: bevorzugt `gpt-*-codex` oder `codex-*`, aber nicht `-mini` / `-max`
    # / `-research` / `-preview`. Fallback auf irgendein Codex-Modell.
    preferred = None
    fallback = None
    for m in items:
        mid = m.get("id", "")
        if "codex" not in mid:
            continue
        if fallback is None:
            fallback = mid
        if not any(tag in mid for tag in ("-mini", "-max", "-research", "-preview", "-audio")):
            preferred = mid
            break

    coding = preferred or fallback
    return {"OPENAI_CODING": coding} if coding else {}


def fetch_gemini_models(api_key: str) -> dict[str, str]:
    """Fetch Gemini-Modelle via /v1beta/models (API-Key im Query oder Header)."""
    try:
        data = _http_json(
            "https://generativelanguage.googleapis.com/v1beta/models",
            headers={"x-goog-api-key": api_key},
        )
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as e:
        print(f"⚠️  Gemini fetch failed: {e}", file=sys.stderr)
        return {}

    # Schema: { "models": [{"name": "models/gemini-X.Y-pro", ...}, ...] }
    items = data.get("models", []) if isinstance(data, dict) else []

    def latest(kind: str) -> str | None:
        """`kind` ist "pro" oder "flash". Sortiert nach Semver-Suffix."""
        candidates: list[tuple[tuple[int, int], str]] = []
        pattern = re.compile(rf"^models/gemini-(\d+)(?:\.(\d+))?-{kind}(?:-preview.*)?$")
        for m in items:
            name = m.get("name", "")
            match = pattern.match(name)
            if not match:
                continue
            major = int(match.group(1))
            minor = int(match.group(2) or 0)
            # Name ohne `models/`-Prefix
            bare = name.removeprefix("models/")
            # Skip audio/image/tts-Variants (bei pro gibt's die rund um main-Pro)
            if any(tag in bare for tag in ("-tts", "-image", "-audio", "-robot", "-lite", "-native")):
                continue
            candidates.append(((major, minor), bare))

        if not candidates:
            return None
        candidates.sort(reverse=True)
        return candidates[0][1]

    result: dict[str, str] = {}
    pro = latest("pro")
    flash = latest("flash")
    if pro:
        result["GEMINI_PRO"] = pro
    if flash:
        result["GEMINI_FLASH"] = flash
    return result


def fetch_npm_cli_pins() -> dict[str, str]:
    """Fetch aktuelle Major-Version von Codex- und Cursor-Agent-CLIs via npm.

    Pin-Strategie: ^MAJOR (z.B. "^0") — erlaubt minor/patch-Updates ohne
    manuelle Intervention, blockt breaking-Major-Wechsel.
    """
    result: dict[str, str] = {}
    for reg_key, pkg in (
        ("CODEX_CLI_VERSION", "@openai/codex"),
        ("CURSOR_AGENT_CLI_VERSION", "cursor-agent"),
    ):
        try:
            data = _http_json(
                f"https://registry.npmjs.org/{pkg}/latest",
                headers={"Accept": "application/json"},
            )
            version = data.get("version", "") if isinstance(data, dict) else ""
            if version:
                result[reg_key] = f"^{version.split('.')[0]}"
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as e:
            print(f"⚠️  npm fetch failed for {pkg}: {e}", file=sys.stderr)
    return result


# ---------------------------------------------------------------------------
# Registry I/O
# ---------------------------------------------------------------------------


def parse_registry(path: Path) -> dict[str, str]:
    """Parse committed MODEL_REGISTRY.env. Akzeptiert `KEY=value`-Zeilen."""
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        result[key.strip()] = value.strip().strip('"\'')
    return result


def update_registry(path: Path, updates: dict[str, str]) -> str:
    """Writes updates to MODEL_REGISTRY.env. Returns unified diff as string."""
    before = path.read_text()
    after_lines: list[str] = []
    seen_keys: set[str] = set()
    for line in before.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            after_lines.append(line)
            continue
        key, _, _ = stripped.partition("=")
        key = key.strip()
        if key in updates:
            after_lines.append(f"{key}={updates[key]}")
            seen_keys.add(key)
        else:
            after_lines.append(line)

    # Keys, die nicht in before existieren, anhängen
    new_keys = set(updates.keys()) - seen_keys
    if new_keys:
        after_lines.append("")
        after_lines.append(f"# Added by drift-check {datetime.now(timezone.utc).date().isoformat()}")
        for key in sorted(new_keys):
            after_lines.append(f"{key}={updates[key]}")

    after = "\n".join(after_lines) + "\n"
    path.write_text(after)

    # Mini-Diff (unified) — nicht über `difflib` weil zusätzlich Dep wäre
    diff_lines: list[str] = []
    for key in sorted(set(list(updates.keys()) + list(parse_registry(path).keys()))):
        old = parse_registry_from_string(before).get(key, "<unset>")
        new = updates.get(key, parse_registry(path).get(key, "<unset>"))
        if old != new:
            diff_lines.append(f"  {key}: {old} → {new}")
    return "\n".join(diff_lines)


def parse_registry_from_string(content: str) -> dict[str, str]:
    """Wie parse_registry, aber von String statt File."""
    result: dict[str, str] = {}
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        result[key.strip()] = value.strip().strip('"\'')
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def compute_drift(
    current: dict[str, str],
    candidates: dict[str, str],
) -> dict[str, str]:
    """Returns the subset of candidates that differ from current."""
    drift: dict[str, str] = {}
    for key, new_value in candidates.items():
        if not new_value:
            continue
        if current.get(key) != new_value:
            drift[key] = new_value
    return drift


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry-path",
        type=Path,
        default=Path("registry/MODEL_REGISTRY.env"),
        help="Pfad zur MODEL_REGISTRY.env (relativ zum ai-review-pipeline-Repo-Root)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Nichts schreiben — nur Diff-Report auf stdout",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Drift-Report als JSON in dieses File schreiben (für CI-Step-Output)",
    )
    args = parser.parse_args(argv)

    # Environment
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "")
    openai_key = os.environ.get("OPENAI_API_KEY", "")
    gemini_key = os.environ.get("GEMINI_API_KEY", "")

    if not args.registry_path.is_file():
        print(
            f"❌ Registry nicht gefunden: {args.registry_path}\n"
            f"   Stelle sicher, dass der Workflow in ai-review-pipeline ausgecheckt hat.",
            file=sys.stderr,
        )
        return 2

    print(f"📖 Lese Registry: {args.registry_path}")
    current = parse_registry(args.registry_path)
    print(f"   {len(current)} Keys aktuell gepflegt")

    # Fetch candidates
    candidates: dict[str, str] = {}
    if anthropic_key:
        print("🔍 Fetch Anthropic…")
        candidates.update(fetch_anthropic_models(anthropic_key))
    else:
        print("⏭️  ANTHROPIC_API_KEY nicht gesetzt — skip Anthropic")

    if openai_key:
        print("🔍 Fetch OpenAI…")
        candidates.update(fetch_openai_models(openai_key))
    else:
        print("⏭️  OPENAI_API_KEY nicht gesetzt — skip OpenAI")

    if gemini_key:
        print("🔍 Fetch Gemini…")
        candidates.update(fetch_gemini_models(gemini_key))
    else:
        print("⏭️  GEMINI_API_KEY nicht gesetzt — skip Gemini")

    print("🔍 Fetch npm CLI Pins…")
    candidates.update(fetch_npm_cli_pins())

    drift = compute_drift(current, candidates)
    if not drift:
        print("✅ Keine Drift — Registry ist aktuell.")
        if args.output:
            args.output.write_text(json.dumps({"drift": False, "changes": {}}, indent=2))
        return 0

    print("⚠️  DRIFT entdeckt:")
    for key, new in sorted(drift.items()):
        old = current.get(key, "<unset>")
        print(f"   {key}: {old} → {new}")

    if args.output:
        args.output.write_text(json.dumps({
            "drift": True,
            "changes": {k: {"old": current.get(k, None), "new": v} for k, v in drift.items()},
        }, indent=2))

    if args.dry_run:
        print("(--dry-run: Registry wurde nicht geändert)")
        return 1

    diff_summary = update_registry(args.registry_path, drift)
    print(f"\n📝 Registry aktualisiert:\n{diff_summary}")
    return 1  # Non-zero = Drift found (so CI knows to create PR)


if __name__ == "__main__":
    sys.exit(main())
