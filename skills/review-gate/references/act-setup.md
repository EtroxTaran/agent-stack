# act Setup Guide

`act` runs GitHub-Actions workflows locally inside Docker containers.
The `review-gate` skill uses it to execute the `code_review` job before
`git push`, saving a 10-minute round-trip through the self-hosted
runner.

## Install

### Linux (apt-free one-liner)

```bash
curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh \
  | sudo bash -s -- -b /usr/local/bin
act --version
```

### macOS

```bash
brew install act
```

### Windows

Use WSL2 plus the Linux install. Native Windows + Docker Desktop works
but has path-translation quirks that bite our workflows.

## Docker requirement

`act` shells out to Docker. Verify:

```bash
docker info > /dev/null && echo "docker ok"
```

On Linux, the user must be in the `docker` group (`sudo usermod -aG
docker $USER`; re-login). On macOS/Windows, Docker Desktop must be
running.

## First-run image choice

On first invocation `act` asks which image flavour to use. Pick
`medium` (`catthehacker/ubuntu:act-latest`). Recorded in
`~/.actrc`:

```
-P ubuntu-latest=catthehacker/ubuntu:act-latest
-P ubuntu-22.04=catthehacker/ubuntu:act-22.04
```

The `micro` flavour is too small for Node/pnpm/Python stacks. The
`large` flavour pulls gigabytes per run.

## Container architecture

On Apple Silicon, pin to amd64 to match the real runner:

```bash
act --container-architecture linux/amd64 ...
```

On native Linux x86_64, omit the flag (faster, no emulation).

## `.env.act` template

Create `.env.act` in the repo root (gitignored). Keep it minimal - only
what the workflow actually reads:

```
GITHUB_TOKEN=<dev PAT with repo + workflow scope>
GH_TOKEN=${GITHUB_TOKEN}
# Add per-workflow secrets here, one per line, KEY=value
# Do NOT commit this file. Verify .gitignore contains `.env.act`.
```

Grab values from `~/.openclaw/.env`:

```bash
grep -E '^(GITHUB_TOKEN|DISCORD_BOT_TOKEN)=' ~/.openclaw/.env > .env.act
```

Do not commit `.env.act`. The `install.sh` preflight adds it to
`.gitignore` if missing.

## Known gotchas

1. **Artifact actions** - uploads/downloads fail unless
   `--artifact-server-path` is set. `review-gate` passes
   `/tmp/act-artifacts` by default.
2. **Self-hosted runner labels** - workflows with `runs-on:
   [self-hosted, r2d2]` do not run under `act` out of the box. Use
   `--platform self-hosted=catthehacker/ubuntu:act-latest` or split the
   job with a conditional.
3. **Secrets in logs** - `act` masks secrets only when they are passed
   via `--secret-file`. Never hard-code them into the workflow file.
4. **Disk usage** - act images consume ~3 GB each. Prune periodically
   with `docker image prune --filter "label=act"`.
5. **GitHub API calls inside act** - they hit real GitHub, not a mock.
   Dry-run jobs that post comments/statuses need to be gated on
   `if: !env.ACT` or similar.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker: permission denied` | User not in docker group | `sudo usermod -aG docker $USER`, re-login |
| `Cannot connect to the Docker daemon` | Docker Desktop not running | Start Docker Desktop |
| Job passes in act, fails on runner | Different image | Align `.actrc` to runner's image |
| `rosetta` errors on M-series | Native arch mismatch | Add `--container-architecture linux/amd64` |
| Hangs on `Pulling image` | Slow network / DNS | `docker pull <image>` manually first |

## When act is not enough

`act` runs single jobs in isolation. The full AI-review pipeline needs
the runner cluster plus model-API quotas (Codex, Claude, Gemini,
Cursor). `review-gate` intentionally skips that consensus step and only
runs the deterministic `code_review` job. For the full pipeline, push
and let the runner do the work.
