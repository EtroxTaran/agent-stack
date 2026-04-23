# Lessons Learned

> **TL;DR:** Eine Auswahl der wichtigsten Lehren aus dem Aufbau und Betrieb der AI-Review-Toolchain. Jeder Eintrag ist eine konkrete Erfahrung — ein Incident, ein Design-Fehler, eine Entscheidung die sich als gut oder schlecht erwiesen hat. Die Liste ist bewusst subjektiv und erzählerisch; für die trockene "Symptom → Fix"-Sammlung siehe [Stolpersteine](../50-runbooks/60-stolpersteine.md).

## Wie es funktioniert

Jede Lesson folgt dem Schema "Was-passiert → Was-wir-dachten → Was-sich-gezeigt-hat → Konsequenz". Das ist reflektive Retrospektive, nicht Reference-Doku.

## Die Lehren

### 1. pip-Skip-Reinstall-Verhalten ist nicht offensichtlich

**Was passierte:** Bei `pip install git+https://...@main` installiert pip die Pipeline nicht neu, wenn es schon Version 0.1.0 findet — obwohl der Git-HEAD neue Files hat.

**Was wir dachten:** "Git-URL heißt: fetch latest, immer." Falsch. pip denkt in Package-Versionen, nicht in Commit-SHAs.

**Was sich gezeigt hat:** Alle Stage-Runs auf dem Runner liefen gegen eine **veraltete** Pipeline-Version, weil das Tool-Cache-Site-Packages nie refreshed wurde. Die Prompts waren neu im HEAD, aber nicht im installierten Package.

**Konsequenz:** `--force-reinstall --no-deps --no-cache-dir` vor jedem Install. Aktuelles Pattern in [`ai-review-v2-shadow.yml`](https://github.com/EtroxTaran/ai-portal/blob/main/.github/workflows/ai-review-v2-shadow.yml). Kostet 2s pro Install, sichert Korrektheit.

**Meta-Lesson:** Default-Verhalten von Tools überprüfen, nicht annehmen. "Bei Git-URLs pullt pip immer" war eine Annahme, keine Tatsache.

### 2. n8n-webhookId ist zwingend

**Was passierte:** Discord lehnte im Dev-Portal die Interactions-Endpoint-URL ab. Verify-Handshake kam nicht durch. Manuelle Curl-Tests ergaben 404.

**Was wir dachten:** n8n registriert Webhook-Routen aus dem Pfad-Parameter im Webhook-Node.

**Was sich gezeigt hat:** Ohne `webhookId`-Attribut registriert n8n unter einem nested Path `ai-review-callback/receive%20discord%20interaction/discord-interaction`. Die Route, die Discord anspricht (`/webhook/discord-interaction`), matcht dann nicht und gibt 404.

**Konsequenz:** `webhookId: "discord-interaction"` im Webhook-Node. Ist jetzt im Repo-JSON + wird vom E2E-Validation-Script (Check #6) geprüft.

**Meta-Lesson:** n8n hat viele implizite Verhaltens-Defaults. Bei WTF-Bugs in n8n: nicht die offizielle Doku vertrauen, die live-Settings im UI checken.

### 3. Ed25519-Verify: SPKI-Prefix ist die Lösung

**Was passierte:** `crypto.subtle.verify` in Node 18 gab mal true, mal false bei identischen Inputs. Non-reproduzierbar.

**Was wir dachten:** WebCrypto-Subtle ist der moderne Standard — sollte ja-mal funktionieren.

**Was sich gezeigt hat:** In verschiedenen Node-Minor-Versionen hat Subtle-Crypto-Ed25519-Support unterschiedliche Quirks. Die Alternative `crypto.verify(null, msg, {key, format: 'der', type: 'spki'}, sig)` mit dem ASN.1-DER-SPKI-Prefix (`302a300506032b6570032100` + 32-byte raw key) ist deterministisch über alle Node 16+ Versionen.

**Konsequenz:** SPKI-Prefix-Methode im Callback-Workflow. In Tests mit 13 Cases abgesichert.

**Meta-Lesson:** "Modern Standard" ≠ "Zuverlässig Implementiert". Bei Krypto-Problemen: näher an den Low-Level-APIs, weg von Wrapper-Layern.

### 4. Raw-Body muss wirklich raw sein

**Was passierte:** Auch mit korrektem SPKI-Verify gab's immer noch `invalid_signature`. Signatur war von Discord definitiv korrekt.

**Was wir dachten:** "Body ist Body, JSON ist JSON, egal ob geparst oder nicht."

**Was sich gezeigt hat:** n8n's default-Behavior: Webhook-Node parst JSON-Body automatisch. Das heißt: Die Bytes die zur Signatur-Prüfung genommen werden, sind `JSON.stringify(parsed_body)` — und das matcht nicht die Original-Bytes, weil Whitespace/Key-Order variiert.

**Konsequenz:** `options: { rawBody: true }` am Webhook-Node. Dann kommen die echten Original-Bytes in `$binary.data`, die zur Verify-Berechnung genommen werden.

**Meta-Lesson:** Signaturen sind Byte-sensitiv. Wenn in deiner Chain irgendwo "parse + re-serialize" passiert, bricht die Verifikation.

### 5. Phase-4-Shadow-Mode zahlt sich aus

**Was passierte:** PR#8 (Prompts-Bug) wurde während der Shadow-Phase erkannt, **ohne** Produktions-Merges zu blockieren.

**Was wir dachten:** "v2 ist fertig, wir cutover direkt."

**Was sich gezeigt hat:** Hätten wir direkt cutoverd, wäre PR#8 die Produktions-Pipeline komplett lahmgelegt — jeder ai-portal PR hätte mit `FileNotFoundError` crashen müssen, bis jemand gemerkt hätte was los ist.

**Konsequenz:** Phase-4-Shadow-Mode als obligatorischer Schritt vor Cutover. Mindestens 2 Wochen Beobachtung + Divergenz-Bericht.

**Meta-Lesson:** Risikoarme Rollouts sind teurer in der Implementierung, aber billiger im Lernprozess.

### 6. Orphan Gitlinks sind Stille Killer

**Was passierte:** `actions/checkout@v4` schlug mit `fatal: no submodule mapping found in .gitmodules for path '.temp/Uiplatformguide'` fehl.

**Was wir dachten:** Wenn kein `.gitmodules` da ist, versucht `checkout` keine Submodule-Aktionen.

**Was sich gezeigt hat:** Ein 160000-Gitlink (Submodule-Eintrag) im Tree-Objekt eines Commits führt `git submodule status` immer aus — auch wenn `submodules: false`. Ohne `.gitmodules` crasht der Call und `checkout` gibt `exit 128` zurück.

**Konsequenz:** Zwei-fache Absicherung in PR#43: `submodules: false` UND `.gitmodules`-Mapping mit fake-URL für den Orphan-Link.

**Meta-Lesson:** Git's Submodule-Metadata ist verstreut (Tree + .gitmodules). Ein Teil ohne den anderen erzeugt Inkonsistenzen, die erst bei unerwarteten Code-Pfaden knallen.

### 7. GraphQL vs. REST-Wrapper

**Was passierte:** `gh pr view --json closingIssuesReferences` schlug fehl mit `Unknown JSON field`.

**Was wir dachten:** `gh pr view --json` ist ein dünner Wrapper über die REST-API und unterstützt alle PR-Felder.

**Was sich gezeigt hat:** Das Feld `closingIssuesReferences` existiert nur in der GitHub-**GraphQL**-API. REST hat nichts Vergleichbares. `gh pr view --json` ist tatsächlich ein Mix aus REST + hand-gepflegter Feld-Liste — und diese Liste ist nicht vollständig.

**Konsequenz:** `gh api graphql -F owner -F repo -F number -f query='…closingIssuesReferences…'` direkt ans GraphQL-API. Etwas umständlicher, aber stabil.

**Meta-Lesson:** Bei `gh`-Problemen: Ausgabe "Available fields: …" ernstnehmen. Wenn dein Feld nicht dabei ist, musst du GraphQL nutzen.

### 8. Fail-Closed ist wichtiger als Performance

**Was passierte:** Wir diskutierten, ob Consensus auch bei fehlenden Stages success melden könnte.

**Was wir dachten:** "4/5 success sind auch gut genug — der 5te hat halt Timeout gehabt."

**Was sich gezeigt hat:** Wenn eine Stage aus technischen Gründen ausfällt (Rate-Limit, Crash, Runner-offline), heißt das NICHT, dass der Code gut ist. Es heißt nur: wir wissen's nicht. "Ich weiß nicht, ist also gut" ist kein tragfähiges Prinzip.

**Konsequenz:** `fail_closed_on_missing_stage: true` ist Default. Missing Stage → Consensus bleibt pending. Mensch muss manuell entscheiden oder warten.

**Meta-Lesson:** Safety-Defaults sind nicht-verhandelbar, auch wenn sie gelegentlich nerven.

### 9. pip selbst kann broken sein

**Was passierte:** Nach einem manuellen `pip install --upgrade pip` im Runner-Tool-Cache begann pip selbst mit `ImportError` zu crashen.

**Was wir dachten:** "Pip upgraden ist idempotent, sollte immer funktionieren."

**Was sich gezeigt hat:** Wenn pip im Tool-Cache zwei gleichzeitige `dist-info`-Verzeichnisse hat (`pip-25.0.1.dist-info` + `pip-26.0.1.dist-info`), ist die vendored resolvelib in inkonsistentem State — das ist ein halber Upgrade.

**Konsequenz:** Niemals manuell pip im Tool-Cache upgraden; `actions/setup-python@v5` managed das. Wenn doch passiert: `rm -rf pip/ pip-*.dist-info _distutils_hack` + `python -m ensurepip --upgrade`.

**Meta-Lesson:** Toolchain-Tools wie pip haben selbst komplexe State-Invarianten. Kaputte Tools können nicht debuggen, während sie sich selbst nutzen.

### 10. Dokumentation ist Work-in-Progress

**Was passierte:** Dieses Wiki wurde am 2026-04-23 angelegt, 3 Monate nach dem eigentlichen Aufbau der Pipeline.

**Was wir dachten:** "Dokumentation schreiben wir, wenn's Zeit gibt."

**Was sich gezeigt hat:** 3 Monate ohne Wiki heißt: Jeder Incident ist Panik-Debug, weil keiner mehr weiß, wie die Komponenten zusammenhängen. Nach 2 Wochen ist die Schritt-für-Schritt-Intuition der Entwickler weg.

**Konsequenz:** Dokumentation läuft jetzt **parallel** zur Entwicklung. Jeder PR im agent-stack, der Infrastruktur ändert, muss das Wiki mit aktualisieren.

**Meta-Lesson:** Dokumentation ist nicht "fertig, dann schreiben" — sie ist "während, oder nie".

## Verwandte Seiten

- [Stolpersteine](../50-runbooks/60-stolpersteine.md) — trockene Version
- [Changelog](00-changelog.md) — chronologisch
- [ADRs-Index](20-adrs-index.md) — Architecture-Decisions
- [Contribute](../99-meta/00-contribute.md) — wie man neue Lessons hinzufügt

## Quelle der Wahrheit (SoT)

- `~/.claude/plans/ai-review-pipeline-completion-report.md` — ursprüngliche Retro-Notizen
- [PR-Historien](https://github.com/EtroxTaran/ai-review-pipeline/pulls?q=is:pr+is:merged) — der eigentliche Lern-Korpus
