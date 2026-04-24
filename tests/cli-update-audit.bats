#!/usr/bin/env bats
# Smoke-Tests für scripts/versions.sh, audit-cli-settings.sh, update-clis.sh.
# Testet pure-function-Parts mit Fixtures. Keine echten Updates.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export REPO_ROOT
    TMPDIR_TEST=$(mktemp -d)
    export TMPDIR_TEST
}

teardown() {
    [[ -d "${TMPDIR_TEST}" ]] && rm -rf "${TMPDIR_TEST}"
}

# ---- versions.sh ----

@test "versions.sh meldet alle vier CLIs ok" {
    run "${REPO_ROOT}/scripts/versions.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"cursor"* ]]
    [[ "$output" == *"gemini"* ]]
    [[ "$output" == *"codex"* ]]
}

@test "versions.sh --json produziert gültiges JSON mit 4 Einträgen" {
    run "${REPO_ROOT}/scripts/versions.sh" --json
    [ "$status" -eq 0 ]
    # Validierung: jq parsed und findet alle vier Keys
    count=$(echo "$output" | jq '[.claude, .cursor, .gemini, .codex] | length')
    [ "$count" = "4" ]
}

# ---- audit-cli-settings.sh gegen echte Configs ----

@test "audit-cli-settings.sh: echte Configs matchen BASELINE" {
    run "${REPO_ROOT}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Keine Drift"* ]]
}

@test "audit-cli-settings.sh --json liefert parsbares JSON" {
    run "${REPO_ROOT}/scripts/audit-cli-settings.sh" --json
    [ "$status" -eq 0 ]
    drift=$(echo "$output" | jq -r '.drift_count')
    [ "$drift" = "0" ]
}

# ---- audit-cli-settings.sh: Drift-Detection mit Fixture ----

@test "audit erkennt fehlenden required_key in Fixture-Config" {
    # Kopiere Repo in Tempdir, verändere Config, prüfe Drift-Report.
    cp -r "${REPO_ROOT}/configs" "${TMPDIR_TEST}/configs"
    cp -r "${REPO_ROOT}/scripts" "${TMPDIR_TEST}/scripts"
    # Entferne einen Key aus claude settings
    jq 'del(.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)' \
        "${TMPDIR_TEST}/configs/claude/settings.json" \
        > "${TMPDIR_TEST}/configs/claude/settings.json.tmp"
    mv "${TMPDIR_TEST}/configs/claude/settings.json.tmp" \
        "${TMPDIR_TEST}/configs/claude/settings.json"

    run "${TMPDIR_TEST}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"* ]]
}

@test "audit erkennt Wert-Drift in Fixture-Config" {
    cp -r "${REPO_ROOT}/configs" "${TMPDIR_TEST}/configs"
    cp -r "${REPO_ROOT}/scripts" "${TMPDIR_TEST}/scripts"
    # Ändere codex model.effort auf unerwarteten Wert
    sed -i 's/effort = "medium"/effort = "high"/' \
        "${TMPDIR_TEST}/configs/codex/config.toml"

    run "${TMPDIR_TEST}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"effort"* ]]
    [[ "$output" == *"soll='medium'"* ]]
}

@test "audit erkennt fehlendes Deny-Pattern in Claude" {
    cp -r "${REPO_ROOT}/configs" "${TMPDIR_TEST}/configs"
    cp -r "${REPO_ROOT}/scripts" "${TMPDIR_TEST}/scripts"
    # Entferne Bash(rm *) aus deny-Liste
    jq '.permissions.deny |= map(select(. != "Bash(rm *)"))' \
        "${TMPDIR_TEST}/configs/claude/settings.json" \
        > "${TMPDIR_TEST}/configs/claude/settings.json.tmp"
    mv "${TMPDIR_TEST}/configs/claude/settings.json.tmp" \
        "${TMPDIR_TEST}/configs/claude/settings.json"

    run "${TMPDIR_TEST}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Bash(rm *)"* ]]
}

@test "audit erkennt Modell-Alias-Drift (gpt-5 vs Registry)" {
    cp -r "${REPO_ROOT}/configs" "${TMPDIR_TEST}/configs"
    cp -r "${REPO_ROOT}/scripts" "${TMPDIR_TEST}/scripts"
    # Codex-Config auf Alias herunterziehen
    sed -i 's/name = "gpt-5.3-codex"/name = "gpt-5"/' \
        "${TMPDIR_TEST}/configs/codex/config.toml"
    # Fake-Registry mit spezifischerem Modell
    mkdir -p "${TMPDIR_TEST}/fake-openclaw/workspace"
    cat > "${TMPDIR_TEST}/fake-openclaw/workspace/MODEL_REGISTRY.md" <<'EOF'
# MODEL_REGISTRY.md
OPENAI_CODING=gpt-5.3-codex
GEMINI_PRO=gemini-3.1-pro-preview
GEMINI_FLASH=gemini-3-flash-preview
EOF
    sed -i "s|~/.openclaw/workspace/MODEL_REGISTRY.md|${TMPDIR_TEST}/fake-openclaw/workspace/MODEL_REGISTRY.md|" \
        "${TMPDIR_TEST}/configs/BASELINE.assertions.json"

    run "${TMPDIR_TEST}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Alias"* ]]
}

@test "audit erkennt stale Registry (>14d)" {
    cp -r "${REPO_ROOT}/configs" "${TMPDIR_TEST}/configs"
    cp -r "${REPO_ROOT}/scripts" "${TMPDIR_TEST}/scripts"
    mkdir -p "${TMPDIR_TEST}/fake-openclaw/workspace"
    cat > "${TMPDIR_TEST}/fake-openclaw/workspace/MODEL_REGISTRY.md" <<'EOF'
OPENAI_CODING=gpt-5
GEMINI_PRO=gemini-3.1-pro-preview
GEMINI_FLASH=gemini-3-flash-preview
EOF
    touch -d "60 days ago" "${TMPDIR_TEST}/fake-openclaw/workspace/MODEL_REGISTRY.md"
    sed -i "s|~/.openclaw/workspace/MODEL_REGISTRY.md|${TMPDIR_TEST}/fake-openclaw/workspace/MODEL_REGISTRY.md|" \
        "${TMPDIR_TEST}/configs/BASELINE.assertions.json"

    run "${TMPDIR_TEST}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alt"* ]]
}

@test "audit exit=2 wenn Config-Datei fehlt" {
    cp -r "${REPO_ROOT}/configs" "${TMPDIR_TEST}/configs"
    cp -r "${REPO_ROOT}/scripts" "${TMPDIR_TEST}/scripts"
    rm "${TMPDIR_TEST}/configs/gemini/settings.json"

    run "${TMPDIR_TEST}/scripts/audit-cli-settings.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fehlt"* ]]
}

# ---- update-clis.sh --dry-run ----

@test "update-clis.sh --dry-run macht keine Änderungen und meldet alle vier CLIs" {
    run "${REPO_ROOT}/scripts/update-clis.sh" --dry-run --no-notify
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"claude update"* ]]
    [[ "$output" == *"cursor-agent update"* ]]
    [[ "$output" == *"@google/gemini-cli"* ]]
    [[ "$output" == *"@openai/codex"* ]]
}

@test "update-clis.sh --dry-run exit=0 auch wenn keine Änderung" {
    run "${REPO_ROOT}/scripts/update-clis.sh" --dry-run --no-notify
    [ "$status" -eq 0 ]
}
