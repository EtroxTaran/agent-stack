# pip install bricht ab

> **TL;DR:** Wenn Review-Stages plötzlich mit `FileNotFoundError` auf Prompt-Dateien oder `ImportError` in pip selbst crashen, ist meistens eine von zwei Ursachen im Spiel: pip erkennt die ai-review-pipeline als "bereits installiert" und skippt den Install (dann fehlen neue Prompts), oder pip selbst ist durch einen halb-abgeschlossenen Upgrade kaputt. Beide Probleme betreffen den Tool-Cache des Self-hosted-Runners und beide haben klare Fix-Pattern. Die Diagnose dauert 2 Minuten, der Fix 5.

## Symptom

Zwei unterschiedliche Fehlerbilder:

**Symptom A — Stages crashen mit `FileNotFoundError`:**
```
Stage code crashed: [Errno 2] No such file or directory:
'/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages/ai_review_pipeline/stages/prompts/code_review.md'
```

**Symptom B — pip selbst crasht mit ImportError:**
```
ImportError: cannot import name 'RequirementInformation' from 'pip._vendor.resolvelib.structs'
```

## Diagnose

### Für Symptom A

```bash
# Ist die Pipeline installiert?
PYTHONPATH=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages \
  /home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/bin/python3 \
  -c "import ai_review_pipeline; print(ai_review_pipeline.__version__)"
# Erwartet: 0.1.0

# Gibt es die Prompts?
ls /home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages/ai_review_pipeline/stages/prompts/
# Erwartet: code_review.md cursor_review.md design_review.md security_review.md
# Wenn leer oder Dir fehlt: pip hat neue Version nicht installiert
```

**Root Cause für Symptom A:** pip sieht `ai-review-pipeline==0.1.0` bereits installed im Tool-Cache und überspringt den Install bei `pip install git+…@main`, obwohl HEAD neue Files eingeführt hat (z.B. neue Prompts). Die Version (0.1.0) ändert sich nicht zwischen Commits auf main.

### Für Symptom B

```bash
# pip-Version + Integrität
PY=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/bin/python3
PYTHONPATH=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages \
  $PY -m pip --version

# Dist-Info-Dirs anschauen
ls /home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages/pip-*dist-info/
```

**Root Cause für Symptom B:** Wenn zwei `pip-*.dist-info`-Verzeichnisse existieren (z.B. `pip-25.0.1.dist-info` + `pip-26.0.1.dist-info`), ist pip in halbem Upgrade hängen geblieben — vendored `resolvelib` wurde halb ausgetauscht.

## Fix

### Symptom A: Force-Reinstall-Pattern

**Im Workflow-YAML** (dauerhafter Fix, bereits in `ai-review-v2-shadow.yml`):

```yaml
- name: Install ai-review-pipeline
  run: |
    pip install --force-reinstall --no-deps --no-cache-dir \
      git+https://github.com/EtroxTaran/ai-review-pipeline.git@main
    pip install git+https://github.com/EtroxTaran/ai-review-pipeline.git@main
```

Die zwei Calls bewirken:
1. `--force-reinstall --no-deps --no-cache-dir` — zwingt einen frischen Build + Install des Packages, ignoriert "already satisfied"
2. Zweiter `pip install` ohne Flags — stellt sicher, dass Dependencies installiert sind (werden übersprungen wenn bereits da)

**Manuell auf dem Runner:**

```bash
PY=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/bin/python3
PYTHONPATH=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages
env PYTHONPATH=$PYTHONPATH $PY -m pip install --force-reinstall --no-deps --no-cache-dir \
  git+https://github.com/EtroxTaran/ai-review-pipeline.git@main

# Verify
ls /home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages/ai_review_pipeline/stages/prompts/
```

### Symptom B: pip-Repair

**Broken pip entfernen + re-installieren:**

```bash
PY=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/bin/python3
TOOL_SITE=/home/clawd/github-runner/_work/_tool/Python/3.12.13/x64/lib/python3.12/site-packages

# 1. Alle pip-Reste entfernen
rm -rf $TOOL_SITE/pip $TOOL_SITE/pip-*.dist-info $TOOL_SITE/_distutils_hack

# 2. Via ensurepip re-installieren
$PY -m ensurepip --upgrade

# 3. Bytecode-Cache löschen (wichtig, sonst läuft altes pyc)
rm -rf $TOOL_SITE/pip/__pycache__
rm -rf $TOOL_SITE/pip/_internal/__pycache__
rm -rf $TOOL_SITE/pip/_vendor/__pycache__

# 4. Verify
PYTHONPATH=$TOOL_SITE $PY -m pip --version
# Erwartet: pip 25.0.1 (oder die ensurepip-default Version)
```

**Nach Repair ai-review-pipeline installieren:**

```bash
env PYTHONPATH=$TOOL_SITE $PY -m pip install \
  git+https://github.com/EtroxTaran/ai-review-pipeline.git@main
```

## Prevention

### Für Symptom A (skip-reinstall)

**Keine manuellen `pip install --upgrade pip` auf dem Tool-Cache.** actions/setup-python managed das. Wenn manuell: in ein isoliertes venv, nicht ins Tool-Cache.

**Version-Bump bei Major-Changes:** Wenn `ai-review-pipeline` neue Prompt-Files oder Config-Änderungen hat, kann man `version = "0.1.1"` in `pyproject.toml` setzen — dann erkennt pip die neue Version und installiert sauber. Aber das skaliert nicht für jeden Patch.

**Pragmatische Prevention:** `--force-reinstall --no-deps` im Workflow lassen. Cost: ~2 Sekunden pro Install.

### Für Symptom B (broken pip)

- **Niemals** pip im Tool-Cache upgraden (`pip install --upgrade pip` dort)
- setup-python verwaltet den Tool-Cache selbst — neue Python-Versionen kommen mit sauberem pip
- Wenn manuell pip gebraucht wird (für Debug), in einem venv, nicht im Tool-Cache

**Monitoring:** Bytecode-Cache-Grösse > 50MB im `site-packages/pip/__pycache__` ist Warnsignal — oft Folge von halbem Upgrade.

## Wann tritt das auf?

**Symptom A war der Kern-Grund für den Shadow-Pipeline-Crash #24689725932** (2026-04-20). Die Prompts waren in PR#8 hinzugefügt, aber der Runner hatte `ai-review-pipeline==0.1.0` ohne Prompts gecacht. Fix durch PR#43 mit `--force-reinstall`.

**Symptom B trat bei der Fix-Sequenz** (2026-04-21). Nach mehreren manuellen `pip install --upgrade pip`-Calls war das Tool-Cache-pip inkonsistent. Fix durch manuelle Re-Installation.

Beide Incidents sind dokumentiert in [Lessons Learned](../80-historie/10-lessons-learned.md).

## Verwandte Seiten

- [Self-hosted Runner](../20-komponenten/60-self-hosted-runner.md) — Tool-Cache-Struktur
- [ai-review-pipeline Repo](../20-komponenten/10-ai-review-pipeline-repo.md) — Package-Details
- [Wheel-Packaging-Regression](../60-tests/20-wheel-packaging-regression.md) — PR#9 Tests
- [Stolpersteine #11 + #12](60-stolpersteine.md) — historischer Kontext

## Quelle der Wahrheit (SoT)

- [`ai-portal/.github/workflows/ai-review-v2-shadow.yml`](https://github.com/EtroxTaran/ai-portal/blob/main/.github/workflows/ai-review-v2-shadow.yml) — `--force-reinstall`-Workflow-Template
- [`ai-review-pipeline/tests/test_wheel_packaging.py`](https://github.com/EtroxTaran/ai-review-pipeline/blob/main/tests/test_wheel_packaging.py) — Regressionstest
