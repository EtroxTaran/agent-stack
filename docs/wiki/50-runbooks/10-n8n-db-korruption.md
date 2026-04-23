# n8n DB-Korruption

> **TL;DR:** Wenn der n8n-Container in den Logs `SQLITE_CORRUPT: database disk image is malformed` wirft, ist seine SQLite-Datenbank beschädigt. Meistens passiert das durch direkte Datenbank-Manipulation während der Container läuft (WAL-Inkonsistenz) oder durch unerwartete Stromausfälle. Der Fix ist eine Kombination aus WAL-Checkpointing, VACUUM, und Re-Import der Workflows aus den Repo-JSONs. Die Workflows selbst sind nicht verloren — sie liegen im agent-stack-Repo und können jederzeit restauriert werden.

## Symptom

- Logs: `SQLITE_CORRUPT: database disk image is malformed`
- `docker exec … n8n list:workflow` schlägt mit SQL-Fehler fehl
- `curl :5678/healthz` liefert `{"status":"error"}`
- Workflow-Executions laufen sofort auf Fehler
- Evtl. `SQLITE_READONLY: attempt to write a readonly database` nach Reboot

## Diagnose

```bash
# 1. Container-Logs ansehen
docker logs --tail 50 ai-portal-n8n-portal-1 2>&1 | grep -iE "sqlite|corrupt|malformed"

# 2. DB-Integrität prüfen (braucht temporären Zugriff auf die DB-Datei)
docker exec ai-portal-n8n-portal-1 sqlite3 /home/node/.n8n/database.sqlite "PRAGMA integrity_check;"
# Erwartet: "ok"
# Bei Problem: Fehler-Liste mit Zeilen-Nummern

# 3. WAL-Datei-Größe prüfen (groß = gefährlich)
docker exec ai-portal-n8n-portal-1 ls -la /home/node/.n8n/database.sqlite*
```

## Fix: Standard-Prozedur

```bash
# 1. Container stoppen (verhindert weitere Writes)
docker stop ai-portal-n8n-portal-1

# 2. DB-Datei + WAL + SHM herauskopieren
docker cp ai-portal-n8n-portal-1:/home/node/.n8n/database.sqlite /tmp/n8n-backup-$(date +%Y%m%d).sqlite
docker cp ai-portal-n8n-portal-1:/home/node/.n8n/database.sqlite-wal /tmp/ 2>/dev/null || true
docker cp ai-portal-n8n-portal-1:/home/node/.n8n/database.sqlite-shm /tmp/ 2>/dev/null || true

# 3. WAL in main DB mergen
sqlite3 /tmp/n8n-backup-$(date +%Y%m%d).sqlite "PRAGMA journal_mode = DELETE;"
sqlite3 /tmp/n8n-backup-$(date +%Y%m%d).sqlite "VACUUM;"

# 4. Integrität re-checken
sqlite3 /tmp/n8n-backup-$(date +%Y%m%d).sqlite "PRAGMA integrity_check;"
# Erwartet: "ok"

# 5a. Wenn Integrität ok: DB zurückspielen
docker cp /tmp/n8n-backup-$(date +%Y%m%d).sqlite ai-portal-n8n-portal-1:/home/node/.n8n/database.sqlite
# (optional) WAL-Dateien explizit entfernen, da sie jetzt stale sind
docker exec ai-portal-n8n-portal-1 rm -f /home/node/.n8n/database.sqlite-wal /home/node/.n8n/database.sqlite-shm

docker start ai-portal-n8n-portal-1
sleep 10
curl -sf http://127.0.0.1:5678/healthz
# Erwartet: {"status":"ok"}
```

## Fix: Harte Prozedur (wenn Standard nicht hilft)

Wenn die DB nicht reparierbar ist:

```bash
# 1. Backup der kaputten DB (zur Forensik)
docker cp ai-portal-n8n-portal-1:/home/node/.n8n/database.sqlite /tmp/n8n-corrupted-$(date +%Y%m%d).sqlite

# 2. Container stoppen und DB-Volume neu initialisieren
docker stop ai-portal-n8n-portal-1
docker exec ai-portal-n8n-portal-1 rm -f /home/node/.n8n/database.sqlite*

# 3. Container starten — n8n initialisiert leere DB
docker start ai-portal-n8n-portal-1
sleep 15

# 4. Workflows aus dem agent-stack-Repo re-importieren
bash ~/projects/agent-stack/ops/scripts/restart-n8n-with-ai-review.sh
```

Das Skript importiert die drei Workflow-JSONs (`ai-review-dispatcher`, `ai-review-callback`, `ai-review-escalation`) aus `ops/n8n/workflows/` und aktiviert sie.

**Was verloren geht bei harter Prozedur:**
- Execution-History (welche PRs wann reviewt wurden) — Metriken sind in `metrics.jsonl` im Repo, nicht in n8n-DB
- Zwischenablage-Credentials, falls welche in n8n gespeichert waren (bei uns: nur ENV-Vars, also kein Verlust)
- Workflow-Editor-Layout (Positionen der Nodes) — wird aus JSON neu gesetzt

Alle kritischen Workflows leben in den JSON-Files im agent-stack-Repo. **Nichts, was wichtig wäre, ist tatsächlich verloren.**

## Häufige Ursachen

| Ursache | Symptom | Prevention |
|---|---|---|
| Direkte `sqlite3`-Writes während Container läuft | WAL-Split, plötzliche Korruption | **Niemals** direkt DB manipulieren, immer `n8n import:workflow` |
| Stromausfall während eines Workflow-Runs | Half-committed Transactions | UPS oder Stromfilter (r2d2 ist gegen Brownouts sensitiv) |
| Voll gelaufene Disk | `SQLITE_FULL` degeneriert zu `SQLITE_CORRUPT` | `df -h` regelmäßig, Alert bei >80% |
| WAL-Größe > RAM | OOM-Kill schreibt halbe Transaktion | `PRAGMA wal_autocheckpoint=1000` (default ist OK) |
| Manuelle `chmod`-Änderung | `SQLITE_READONLY` nach chmod 0444 | Chmod/chown-Befehle nicht in Ops-Skripte |

## Prevention

- **Standard-Workflow-Änderung:** Immer via `n8n import:workflow` CLI, nie direkt DB-write
- **Regelmäßige DB-Backups:** Wöchentliches Cron-Job `docker exec … sqlite3 … .backup /backup/`
- **WAL-Monitoring:** WAL-Datei > 100MB ist Warnsignal (normal < 10MB)
- **Integrity-Check vor Wartungsarbeiten:** `PRAGMA integrity_check` vor jeder DB-Operation

## Verwandte Seiten

- [n8n Workflows](../20-komponenten/30-n8n-workflows.md) — der Kontext
- [Discord-Webhook-Down](00-discord-webhook-down.md) — verwandte Symptome
- [Stolpersteine](60-stolpersteine.md) — #1 und #2 sind DB-bezogen

## Quelle der Wahrheit (SoT)

- [`ops/scripts/restart-n8n-with-ai-review.sh`](https://github.com/EtroxTaran/agent-stack/blob/main/ops/scripts/restart-n8n-with-ai-review.sh)
- [`ops/n8n/workflows/*.json`](https://github.com/EtroxTaran/agent-stack/tree/main/ops/n8n/workflows) — Wiederherstellungs-Quelle
- [SQLite PRAGMA integrity_check Docs](https://www.sqlite.org/pragma.html#pragma_integrity_check)
