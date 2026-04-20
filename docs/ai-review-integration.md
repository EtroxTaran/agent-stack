# ai-review-pipeline Integration

Dieses Dokument beschreibt den optionalen `--with-ai-review`-Flag von `install.sh`,
der die [ai-review-pipeline](https://github.com/EtroxTaran/ai-review-pipeline) als
pip-Paket auf dem Entwickler-Rechner installiert.

---

## Nutzung

```bash
./install.sh --with-ai-review
```

Der Flag ist optional. Ohne ihn läuft `install.sh` genau wie bisher — kein Unterschied
im Verhalten.

---

## Was passiert

Nach dem normalen gh-Extension-Schritt (Step 5) wird automatisch ein zusätzlicher
Schritt ausgeführt:

1. **pip verfügbar?** — `pip3` oder `pip` muss im PATH sein. Fehlt beides, bricht
   der Schritt mit einer klaren Fehlermeldung ab.

2. **Bereits installiert?** — Wenn `pip show ai-review-pipeline` ein Ergebnis liefert
   und `ai-review --version` erfolgreich läuft, wird der Install übersprungen (idempotent).

3. **PyPI-Install** — `pip install --user ai-review-pipeline`. Gelingt das, weiter zu
   Schritt 5.

4. **Fallback: lokales Dev-Repo** — Schlägt der PyPI-Install fehl (z.B. weil das Paket
   noch nicht veröffentlicht wurde), prüft das Script ob
   `~/projects/ai-review-pipeline` ein Git-Repo ist. Wenn ja:
   `pip install --user -e ~/projects/ai-review-pipeline` (editable/dev-mode).

5. **Smoke-test** — `ai-review --version` muss Exit 0 liefern. Schlägt das fehl,
   bricht der Schritt mit Exit 1 ab und das gesamte `install.sh` endet mit einem
   Fehler (fail-closed).

Das Helper-Script `scripts/install-ai-review-pipeline.sh` kann auch direkt aufgerufen
werden, unabhängig von `install.sh`:

```bash
bash scripts/install-ai-review-pipeline.sh
```

---

## Wann wird der Flag benoetigt

Der Flag ist fuer Projekte gedacht, die die ai-review-pipeline **konsumieren** — also
auf dem Entwickler-Rechner die CLI nutzen (z.B. ueber den `review-gate`-Skill oder
lokale Smoke-Tests gegen den Review-Endpunkt).

Typische Situationen:

- Erstes Einrichten eines neuen Entwickler-Rechners fuer ai-review-Pipeline-Projekte
- CI-Runner-Provisionierung (falls pip-basiert)
- Dev-Setup, wenn die Pipeline noch nicht auf PyPI ist und aus dem lokalen Repo
  getestet wird

**Nicht benoetigt** bei reinen agent-stack-Nutzern, die nur Symlinks + MCP-Server
wollen.

---

## PATH-Hinweis (User-Install)

`pip install --user` legt Binaries unter `$(python3 -m site --user-base)/bin` ab
(meistens `~/.local/bin`). Das Script erweitert `PATH` temporaer fuer die
aktuelle Session. Fuer dauerhafte Verfuegbarkeit in neuen Shells einfach ergaenzen:

```bash
# .bashrc oder .zshrc
export PATH="$(python3 -m site --user-base)/bin:$PATH"
```

---

## Troubleshooting

| Problem | Loesung |
|---|---|
| `pip/pip3 nicht gefunden` | `apt install python3-pip` oder `brew install python3` |
| PyPI-Install schlaegt fehl, kein lokales Repo | Repo klonen: `git clone https://github.com/EtroxTaran/ai-review-pipeline ~/projects/ai-review-pipeline` |
| `ai-review: command not found` nach Install | `export PATH="$(python3 -m site --user-base)/bin:$PATH"` in Shell-Config |
| `ai-review --version` schlaegt fehl | `pip3 install --user --force-reinstall ai-review-pipeline` |
| Install im Schritt 5b fehlgeschlagen | `bash scripts/install-ai-review-pipeline.sh` direkt ausfuehren fuer ausfuehrlichere Ausgabe |

---

## verify.sh

Nach einer Installation mit `--with-ai-review` zeigt `scripts/verify.sh` die
installierte Version:

```
ai-review-pipeline (optional)
  ✓ ai-review-pipeline installiert: ai-review 1.2.3
```

Ohne Installation erscheint ein Hinweis (kein Fehler, da optional):

```
ai-review-pipeline (optional)
  · ai-review-pipeline: nicht installiert
  · Fuer optionale Integration: ./install.sh --with-ai-review
```
