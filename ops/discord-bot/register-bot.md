# register-bot — Discord Application Setup Runbook

Schritt-für-Schritt Anleitung zum Einrichten des "Nathan Ops Bot" im Discord Developer Portal.
Am Ende dieses Runbooks:
- Bot ist im "Nathan Ops" Guild als Mitglied
- `DISCORD_BOT_TOKEN` + `DISCORD_GUILD_ID` + `DISCORD_APPLICATION_ID` + `DISCORD_PUBLIC_KEY` stehen in `~/.openclaw/.env`
- `setup.sh` kann ausgeführt werden

---

## Voraussetzungen

- Zugang zu [Discord Developer Portal](https://discord.com/developers/applications) (Nicos Account)
- Discord Desktop oder Web Client mit **Developer Mode** eingeschaltet
- r2d2 erreichbar via SSH oder Tailscale

---

## Schritt 1 — Application anlegen

1. Öffne [discord.com/developers/applications](https://discord.com/developers/applications)
2. Klick "New Application"
3. Name: **Nathan Ops Bot**
4. "Create" bestätigen
5. Auf der "General Information"-Seite:
   - **Application ID** kopieren → `DISCORD_APPLICATION_ID` in `~/.openclaw/.env`
   - **Public Key** kopieren → `DISCORD_PUBLIC_KEY` in `~/.openclaw/.env`

```bash
# ~/.openclaw/.env ergänzen:
DISCORD_APPLICATION_ID=<Application ID aus General Information>
DISCORD_PUBLIC_KEY=<Public Key aus General Information>
```

---

## Schritt 2 — Bot erstellen und Token kopieren

1. Im linken Menü: **Bot** auswählen
2. Klick "Add Bot" → "Yes, do it!"
3. Unter "TOKEN": "Reset Token" klicken → Token bestätigen
4. **Token sofort kopieren** (wird nur einmal angezeigt) → `DISCORD_BOT_TOKEN` in `~/.openclaw/.env`

```bash
# ~/.openclaw/.env ergänzen:
DISCORD_BOT_TOKEN=<Bot Token>
```

> Sicherheitshinweis: Token niemals committen. `.env`-Datei ist in `.gitignore`.

### Bot-Optionen (Pflicht)

Im Bot-Tab folgende Schalter aktivieren:
- **Message Content Intent** → ON (für Message-Parsing falls nötig)
- **Server Members Intent** → OFF (nicht benötigt)
- **Presence Intent** → OFF (nicht benötigt)

---

## Schritt 3 — OAuth2 URL generieren und Bot einladen

1. Im linken Menü: **OAuth2** → **URL Generator**
2. **Scopes** auswählen:
   - `bot`
   - `applications.commands`
3. **Bot Permissions** auswählen (Minimal-Prinzip):

   | Permission | Zweck |
   |---|---|
   | Send Messages | Nachrichten in Channels posten |
   | Embed Links | Discord Embeds rendern |
   | Use External Emojis | Custom Emojis in Messages |
   | Manage Messages | Sticky-Message-Updates (alte Nachricht löschen, neue posten) |
   | Read Message History | Channel-History für Context lesen |
   | Mention @here/@everyone | Eskalations-Alerts |

4. Generierte URL am Ende der Seite kopieren
5. URL im Browser öffnen
6. Server auswählen: **Nathan Ops** (Nicos Guild)
7. "Authorize" → CAPTCHA bestätigen

Bot erscheint jetzt als Mitglied in "Nathan Ops".

---

## Schritt 4 — Guild ID kopieren

1. In Discord: **Developer Mode** einschalten
   - User Settings → Advanced → Developer Mode = ON
2. Rechtsklick auf den **Nathan Ops** Server-Icon
3. **"Copy Server ID"** → `DISCORD_GUILD_ID` in `~/.openclaw/.env`

```bash
# ~/.openclaw/.env ergänzen:
DISCORD_GUILD_ID=<Server ID>
```

---

## Schritt 5 — Ed25519 Public Key notieren

Der Public Key wurde bereits in Schritt 1 kopiert. Er wird später in Schritt 6 für die
"Interactions Endpoint URL" Verification benötigt — Discord schickt beim Eintragen des Endpoints
einen Signed-Ping, den `ai-review-callback.json` Workflow via Ed25519 verifiziert.

Sicherstellen, dass `DISCORD_PUBLIC_KEY` korrekt in `~/.openclaw/.env` steht.

---

## Schritt 6 — Interactions Endpoint URL eintragen (NACH setup.sh)

Dieser Schritt erfolgt NACH dem Ausführen von `setup.sh` (Tailscale Funnel muss laufen).

1. Zurück im Developer Portal → General Information
2. Feld "Interactions Endpoint URL":
   ```
   https://r2d2.tail4fc6dd.ts.net/webhook/discord-interaction
   ```
3. "Save Changes" klicken
4. Discord verifiziert den Endpoint sofort — wenn `ai-review-callback.json` Workflow
   aktiv und Tailscale Funnel läuft, erscheint "URL successfully verified"

> Falls Verification fehlschlägt: prüfen ob ops-n8n läuft (`docker ps | grep ops-n8n`),
> Tailscale Funnel aktiv ist (`sudo tailscale funnel status`) und der Workflow aktiviert ist.

---

## Verify: Bot-Mitgliedschaft und API-Verbindung prüfen

```bash
# Voraussetzung: DISCORD_BOT_TOKEN in Shell exportiert (oder direkt aus env lesen)
source ~/.openclaw/.env

# Guild-Mitgliedschaft verifizieren — erwartet: Guild-Objekt mit name="Nathan Ops"
curl -s -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  "https://discord.com/api/v10/guilds/$DISCORD_GUILD_ID" \
  | python3 -m json.tool | grep '"name"'

# Bot-User verifizieren — erwartet: {"username":"Nathan Ops Bot",...}
curl -s -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  "https://discord.com/api/v10/users/@me" \
  | python3 -m json.tool | grep '"username"'
```

Erwartete Outputs:
- `"name": "Nathan Ops"` (Guild-Name)
- `"username": "Nathan Ops Bot"` (Bot-Name)

---

## Zusammenfassung: Env-Vars Checkliste

| Variable | Quelle | Status |
|---|---|---|
| `DISCORD_BOT_TOKEN` | Bot Tab → Reset Token | [ ] |
| `DISCORD_APPLICATION_ID` | General Information → Application ID | [ ] |
| `DISCORD_PUBLIC_KEY` | General Information → Public Key | [ ] |
| `DISCORD_GUILD_ID` | Discord Dev Mode → Server ID | [ ] |

Sobald alle 4 gesetzt sind: `bash ops/discord-bot/setup.sh` ausführen.
