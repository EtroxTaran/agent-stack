# Token-Rotation — Discord-Bot + GitHub-PAT ohne Downtime

> **TL;DR:** Credentials haben Ablaufdaten, und manchmal muss man sie sofort tauschen — nach einem Verdacht auf Leak oder bei geplanter Rotation. Der Prozess ist für jeden Token-Typ leicht unterschiedlich, aber folgt demselben Schema: Neuen Token im Provider erzeugen, in die env-Datei eintragen, n8n-Container oder Runner-Service recreaten, verify. Während der Rotation gibt es kurz einen fensterchen (< 30 Sekunden), in dem neue Events vielleicht nicht prozessiert werden — das ist akzeptabel für Private-Use-Case.

## Symptom

Rotation ist ein **geplanter Akt**, kein Incident. Typische Trigger:

- Verdacht auf Leak (Token versehentlich in Log oder Screenshot gelandet)
- Geplante Rotation (jährlich für langlebige PATs)
- Nach Verlust eines Geräts mit lokaler Kopie des Tokens
- Nach Rauswurf eines Team-Mitglieds mit Token-Zugang (nicht relevant bei Family-Use-Case)

## Prozedur pro Token

### 1. Discord Bot-Token

**Neu generieren:**

1. [Discord Developer Portal → Nathan Ops App](https://discord.com/developers/applications/1472703891371069511)
2. Bot → "Reset Token"
3. Neuen Token kopieren (wird nur einmal angezeigt!)

**In env eintragen:**

```bash
# env editieren
$EDITOR ~/.config/ai-workflows/env
# DISCORD_BOT_TOKEN=<neuer Token>

# Permissions checken
chmod 600 ~/.config/ai-workflows/env
stat -c %a ~/.config/ai-workflows/env
# Erwartet: 600
```

**Container recreate:**

```bash
bash ~/projects/agent-stack/ops/scripts/restart-n8n-with-ai-review.sh
```

Das Skript macht:
1. `docker stop ai-portal-n8n-portal-1`
2. `docker compose --file docker-compose.yml --file n8n-ai-review.override.yml up -d --force-recreate`
3. Health-Check auf `:5678/healthz`
4. Re-Import der 3 Workflows (falls nicht persistent)

**Verify:**

```bash
# Ist der neue Token im Container?
docker exec ai-portal-n8n-portal-1 printenv DISCORD_BOT_TOKEN | head -c 20
# Erste 20 Zeichen sollten dem neuen Token matchen

# E2E-Probe: Ein Test-Dispatcher-Call sollte eine Discord-Message posten
curl -sS -X POST http://127.0.0.1:5678/webhook/ai-review-dispatch \
  -H 'Content-Type: application/json' \
  -d '{"channel_id":"'$DISCORD_CHANNEL_AGENT_STACK_SHADOW'","pr_number":1999,"pr_title":"Token-rotation test","pr_author":"rotation","consensus":"soft","scores":{"code":7,"cursor":8,"security":9,"design":7,"ac":8},"project":"agent-stack"}'
```

Wenn eine Nachricht im Shadow-Channel erscheint → neuer Token funktioniert.

### 2. Discord Public Key

**Neu generieren:**

1. Discord Dev Portal → General Information → "Reset Public Key"
2. Neuen Public Key kopieren

**In env eintragen + Container recreate:**

```bash
$EDITOR ~/.config/ai-workflows/env
# DISCORD_PUBLIC_KEY=<neuer 64-hex-char Public Key>

bash ~/projects/agent-stack/ops/scripts/restart-n8n-with-ai-review.sh
```

**Verify:**

Das erste Mal wenn Discord nach dem Reset eine Interaction schickt (z.B. PING beim nächsten Dev-Portal-Save), muss die Callback-Workflow-Verify mit dem neuen Public Key validieren. Wenn der Key nicht passt → 401 invalid_signature.

```bash
# Im Dev-Portal Save-Button erneut drücken → löst PING aus
# Dann:
docker logs --tail 20 ai-portal-n8n-portal-1 | grep -i interaction
# Erwartet: Kein invalid_signature-Fehler
```

### 3. GitHub Personal-Access-Token (PAT)

Der `GITHUB_TOKEN` im env wird genutzt für:
- n8n-Callback-Workflow: GitHub `workflow_dispatch`
- Optional: `ai-review-escalation`-Workflow für PR-Listing

**Neu generieren (classic PAT mit `repo` + `workflow` Scopes):**

1. GitHub → Settings → Developer settings → Personal access tokens → "Generate new token (classic)"
2. Scopes: `repo` (alle) + `workflow` + `admin:repo_hook`
3. Expiration: 1 Jahr
4. Generate → neuen Token kopieren

**Migration zu fine-grained PAT (nicht priorisiert, aber die Option):**

Fine-grained PATs sind pro-Repo skopierbar und haben das Prefix `github_pat_`. Für den Security-Proof reicht aktuell classic PAT (siehe `ai-review-pipeline-completion-report.md` Sektion 4).

**In env eintragen + Container recreate:**

```bash
$EDITOR ~/.config/ai-workflows/env
# GITHUB_TOKEN=<neuer Token>

bash ~/projects/agent-stack/ops/scripts/restart-n8n-with-ai-review.sh
```

**Verify:**

```bash
# Token im Container?
docker exec ai-portal-n8n-portal-1 printenv GITHUB_TOKEN | head -c 7
# Erwartet: "ghp_" oder "github_pat_"

# Testen: Button-Click triggert workflow_dispatch
# → Mache einen Test-Dispatch im Discord-Shadow-Channel und prüfe ob handle-button-action run entsteht
```

### 4. GitHub Runner OAuth-Token

Der Runner auf r2d2 hat einen eigenen OAuth-Token für die GitHub-Verbindung. Der läuft normalerweise nie ab (Long-lived), aber kann bei Repo-Transfers ungültig werden.

**Neu registrieren:**

```bash
cd ~/github-runner

# 1. Alten entfernen
systemctl --user stop github-actions-runner
./config.sh remove --token <removal-token-von-github>

# 2. Neuen Registration-Token holen
# GitHub → Repo → Settings → Actions → Runners → "New self-hosted runner" → Token kopieren

# 3. Neu registrieren
./config.sh \
  --url https://github.com/EtroxTaran/ai-review-pipeline \
  --token <registration-token> \
  --name r2d2-ai-review-pipeline \
  --labels self-hosted,Linux,X64,r2d2,ai-review \
  --work _work \
  --unattended

# 4. Service starten
systemctl --user start github-actions-runner

# 5. Verify
gh api repos/EtroxTaran/ai-review-pipeline/actions/runners --jq '.runners[] | {name, status}'
# Erwartet: status: online
```

### 5. Anthropic API-Key (für Claude in Pipeline)

Der Claude-API-Key wird als GitHub-Secret gesetzt (nicht in lokaler env), weil er in Workflow-Runs gebraucht wird:

```bash
gh secret set ANTHROPIC_API_KEY --repo EtroxTaran/ai-portal --body "$NEW_KEY"
gh secret set ANTHROPIC_API_KEY --repo EtroxTaran/ai-review-pipeline --body "$NEW_KEY"
```

Alt-Key bei Anthropic im Dashboard revoken. Keine Container-Restarts nötig — der nächste Workflow-Run nutzt den neuen.

### 6. OpenAI API-Key

Der OpenAI-API-Key treibt Codex als Stage-1 + Stage-5-AC-Primary-Reviewer. Als GitHub-Secret, nicht in lokaler env:

```bash
gh secret set OPENAI_API_KEY --repo EtroxTaran/ai-portal --body "$NEW_KEY"
gh secret set OPENAI_API_KEY --repo EtroxTaran/ai-review-pipeline --body "$NEW_KEY"
```

**Neu generieren:**

1. [platform.openai.com → API keys](https://platform.openai.com/api-keys)
2. "+ Create new secret key", descriptive Name (z.B. "agent-stack-review-2026-04")
3. Permissions: restrict to `model.request` (Minimum für Chat-Completions)
4. Key einmalig kopieren (wird danach nie wieder angezeigt)

**Alt-Key revoken** im Dashboard nachdem der neue in allen Secrets ist und ein Workflow erfolgreich durchgelaufen ist. Keine Container-Restarts nötig.

**Verify:**

```bash
gh workflow run ai-review.yml --repo EtroxTaran/ai-portal
# Warten auf ai-review/code-Status auf einem Test-PR → success
```

### 7. Gemini API-Key

Gemini treibt die Security-Stage (Stage 2). Als GitHub-Secret:

```bash
gh secret set GEMINI_API_KEY --repo EtroxTaran/ai-portal --body "$NEW_KEY"
gh secret set GEMINI_API_KEY --repo EtroxTaran/ai-review-pipeline --body "$NEW_KEY"
```

**Neu generieren:**

1. [aistudio.google.com → Get API key](https://aistudio.google.com/app/apikey)
2. "Create API key in new project" oder auf bestehendem Project
3. Key kopieren (zukünftig wieder abrufbar, aber besser behandeln wie Single-Use)

**Alt-Key revoken:** in AI-Studio Liste → "Delete".

**Verify:**

```bash
gh workflow run ai-review.yml --repo EtroxTaran/ai-portal
# Warten auf ai-review/security-Status → success (nutzt Gemini)
```

### 8. Tailscale OAuth-Credentials

Der Tailscale-Funnel + Ephemeral-Runner-OIDC brauchen OAuth-Client-ID + Secret. Zwei Secrets:

```bash
# Nur ai-portal (deploy.yml SSH-Tunnel zu r2d2 via Tailscale)
gh secret set TAILSCALE_OAUTH_CLIENT --repo EtroxTaran/ai-portal --body "$CLIENT_ID"
gh secret set TAILSCALE_OAUTH_SECRET --repo EtroxTaran/ai-portal --body "$CLIENT_SECRET"
```

**Neu generieren:**

1. [login.tailscale.com → Settings → OAuth clients](https://login.tailscale.com/admin/settings/oauth)
2. "Generate OAuth client", Scopes nach Bedarf:
   - `devices:core:read` — für Device-Listing (runner-config)
   - `auth_keys:core:write` — für Auth-Key-Erstellung im Deploy
3. Tags: `tag:ci` (für Runner-Restriction)
4. Client-ID + Secret kopieren (Secret wird nur einmal angezeigt)

**Alt-Credential revoken:** in Tailscale-Console → Delete OAuth-Client.

**Verify:**

```bash
# Trigger eines deploy.yml Test-Runs
gh workflow run deploy.yml --repo EtroxTaran/ai-portal -f dry_run=true
# Im Workflow-Log: "Tailscale up" step → success
```

## Automatisches Monitoring

Seit `agent-stack#24` läuft monatlich der [`secret-rotation-check.yml`](https://github.com/EtroxTaran/agent-stack/blob/main/.github/workflows/secret-rotation-check.yml) Workflow (1. des Monats 08:00 UTC). Er scannt alle oben genannten Secrets in agent-stack, ai-portal, ai-review-pipeline und öffnet automatisch Rotation-Issues für Secrets älter als 90 Tage.

Jedes auto-generierte Issue verweist per Anchor auf die passende Sektion dieses Runbooks (siehe `RUNBOOK_ANCHORS` in [`scripts/secret-age-check.py`](https://github.com/EtroxTaran/agent-stack/blob/main/scripts/secret-age-check.py)).

Manueller Trigger + Dry-Run:
```bash
gh workflow run secret-rotation-check.yml --repo EtroxTaran/agent-stack -f dry_run=true
```

## Downtime-Fenster

Während eines Container-Restart (via `restart-n8n-with-ai-review.sh`) ist n8n ~15–30 Sekunden unavailable. In dieser Zeit:
- Kommende Discord-Button-Klicks landen auf 502 Bad Gateway
- Dispatcher-Calls aus anderen Workflows hängen (Retry mit Backoff hilft)

Für unseren Use-Case (Familie, < 5 PRs pro Tag) ist das irrelevant. Bei Bedarf kann man zweiten n8n-Container hochfahren und traffic per haproxy umleiten — aktuell nicht implementiert.

## Prevention

- **Kalender-Erinnerungen:** Bot-Token rotieren alle 6 Monate, PAT jährlich. `gh api user/tokens` zeigt Ablaufdaten
- **Incident-Playbook:** Bei Verdacht auf Leak → sofort Rotation, auch wenn 3 Uhr nachts
- **Keine Token in Backups:** env-Datei nicht in cloud-sync (iCloud, Dropbox). Manuelles Backup nur in Passwort-Manager-Secure-Note
- **Niemals in Git:** `.gitignore` aggressiv, `gitleaks`-CI-Check auf allen Repos

## Verwandte Seiten

- [Discord-Bridge](../20-komponenten/40-discord-bridge.md) — Bot-Token-Kontext
- [Secrets & Env](../20-komponenten/80-secrets-env.md) — env-Datei-Struktur
- [Self-hosted Runner](../20-komponenten/60-self-hosted-runner.md) — Runner-OAuth
- [Discord-Webhook-Down](00-discord-webhook-down.md) — nach Rotation falls etwas hakt

## Quelle der Wahrheit (SoT)

- [`ops/scripts/restart-n8n-with-ai-review.sh`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/scripts/restart-n8n-with-ai-review.sh) — Container-Recreate
- [Discord Developer Portal](https://discord.com/developers/applications/1472703891371069511) — Bot-Token + Public-Key reset
- [GitHub PAT-Settings](https://github.com/settings/tokens) — PAT-Management
