# CommonVM — Copilot Instructions

This repo is **infrastructure-as-config**, not an application. It deploys CodiMD, n8n, and a
RustDesk relay onto a single Azure VM via Docker Compose, fronted by Caddy. There is no app
code, build step, or test suite — changes are YAML, Caddy config, shell/PowerShell scripts,
and bilingual Markdown docs.

## Working directory

All compose operations run from `src/`. Container names follow the deploy directory: README
examples use `merged-services-<service>-1` (the folder is copied to the VM as `merged-services`).
Always confirm real names with `docker compose ps` before any `exec`/restore.

## Validate changes (there is no test/lint suite)

- `docker compose -f src/docker-compose.yml config` — lint/expand the compose file after edits.
- `docker compose up -d` then `docker compose logs -f <service>` — bring up and verify a service.
- `docker compose pull && docker compose up -d` — upgrade running images.
- Caddy edits: verify routing/cert behavior via `docker compose logs caddy`; restart with
  `docker compose restart caddy`. Don't hand-run a Caddyfile linter — it's mounted into the container.

## Architecture (read these together)

- **Two Docker networks**: `web` (Caddy + the two web apps) and `backend` (apps + their Postgres
  DBs, never exposed publicly). RustDesk (`hbbs`/`hbbr`) intentionally uses `network_mode: host`
  and is NOT proxied by Caddy — it needs raw TCP 21114-21119 / UDP 21116.
- **Caddy** terminates TLS (Let's Encrypt) and reverse-proxies `CODIMD_DOMAIN→codimd:3000`,
  `N8N_DOMAIN→n8n:5678`. Each app has its own pinned Postgres (`codimd-db` 11.6, `n8n-db` 14).
- **All persistent data lives under `${DATA_ROOT}` (default `/mnt/data`)** — the Azure data disk.
  Never store data on the temporary disk; it is wiped on reboot. Host folders need specific UIDs:
  n8n = `1000:1000`, codimd = `1500:1500`.

## Conventions

- **Everything is env-driven.** Compose has no hardcoded secrets/domains — all from `src/.env`
  (copy from `src/.env.example`). `.env` is gitignored; never commit secrets. Add new settings to
  both `.env.example` and the compose `environment:` block.
- **Docs are bilingual.** Every `*.md` has a `*_zh-TW.md` twin (`README`, `RUSTDESK_CLIENT_DEPLOYMENT`).
  Update both when changing either.
- The scripts folder is literally spelled `src/srcipts/` — keep paths exact, don't "correct" it.
- `tls internal` lines in `Caddyfile` stay commented for production; only enable for local IP testing.
- RustDesk client scripts (`deploy-rustdesk-client.ps1` / `.sh`) write `RustDesk2.toml`; keep the
  Windows and macOS versions in parity.

## Don't break

- RustDesk must keep `ENCRYPTED_ONLY=1` and `network_mode: host`.
- Keep DB ports off `web`; databases stay on `backend` only.
