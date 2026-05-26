# monopetsky-infra

Docker-based deployment for the four-service MonoPetSky stack (backend, storefront, CMS, Postgres) plus nginx + certbot + automated DB backups. Single VPS, all services in containers, manual deploy via SSH.

## Repo layout (deploy host expectation)

The deploy scripts assume the four repos are checked out side-by-side under the same parent directory:

```
~/monopetsky-infra/        (this repo — contains compose files, nginx config, scripts)
~/monopetsky-backend/      (Express + Postgres + Drizzle)
~/monopetsky-frontend/     (Next.js storefront)
~/monopetsky-cms/          (Next.js admin panel)
```

## Stack

| Service     | Image / build context        | Public via nginx?      | Notes |
|-------------|------------------------------|------------------------|-------|
| `postgres`  | `postgres:16-alpine`         | No (internal only)     | Volume-backed; init SQL in `postgres/init/` |
| `backend`   | `../monopetsky-backend/`     | Yes — `api.<host>`     | Reads `DATABASE_URL`, `JWT_SECRET`, `VAPID_*`; mounts `backend_uploads` + `backend_backups` volumes |
| `frontend`  | `../monopetsky-frontend/`    | Yes — `<host>`         | Next.js standalone build; `NEXT_PUBLIC_API_URL` baked in at build time |
| `cms`       | `../monopetsky-cms/`         | Yes — `cms.<host>`     | Same pattern as frontend; verifies JWT via shared `JWT_SECRET` |
| `nginx`     | `nginx:1.27-alpine`          | This IS the public ingress on :80 / :443 | Config rendered from `nginx/conf.d/monopetsky.conf.template` |
| `certbot`   | `certbot/certbot:v3.0.1`     | -                      | Renews Let's Encrypt certs every 12h |
| `db-backup` | `postgres:16-alpine`         | No                     | Nightly `pg_dump` at 02:00 UTC, retention from `BACKUP_RETENTION_DAYS` |
| `cloudflared` | `cloudflare/cloudflared:latest` | Tunnel mode only — replaces nginx+certbot | Started automatically with `--tunnel`; requires `CLOUDFLARE_TUNNEL_TOKEN` |

## First-time setup on a fresh VPS

1. Install Docker Engine + Docker Compose plugin + `git`.
2. Clone the four repos side-by-side under your deploy user's home:
   ```
   git clone https://github.com/.../monopetsky-infra.git
   git clone https://github.com/.../monopetsky-backend.git
   git clone https://github.com/.../monopetsky-frontend.git
   git clone https://github.com/.../monopetsky-cms.git
   ```
3. `cd monopetsky-infra`
4. Generate env file (creates strong secrets, prompts for hostnames + email):
   ```
   ./scripts/configure-env.sh prod
   ```
5. Render nginx config (prompts for the six hostnames):
   ```
   ./scripts/configure-nginx.sh
   ```
6. Generate VAPID keys and paste them into `.env.prod`:
   ```
   npx web-push generate-vapid-keys
   $EDITOR .env.prod   # paste VAPID_PUBLIC_KEY + VAPID_PRIVATE_KEY
   ```
7. Initial Let's Encrypt cert issuance:
   ```
   docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d nginx
   docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod run --rm certbot \
       certonly --webroot -w /var/www/certbot \
       -d <storefront-host> -d <cms-host> -d <api-host> \
       --email <ops-email> --agree-tos --no-eff-email
   docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod restart nginx
   ```
8. Bring the rest up:
   ```
   ./scripts/deploy.sh prod
   ```

## Subsequent deploys

```
./scripts/deploy.sh prod              # pull + build + up + health check
./scripts/deploy.sh prod --no-pull    # just rebuild + restart current commits
./scripts/deploy.sh prod --no-build   # just bring up (e.g. after edit to compose)
./scripts/deploy.sh staging           # same flow against the staging env file
```

Migrations apply automatically on backend boot (`RUN_MIGRATIONS_ON_BOOT=true`). To re-run without restarting:

```
./scripts/migrate.sh prod
```

## DB backups

A `pg_dump` runs every night at 02:00 UTC into the `db_backups` volume. Retention is `BACKUP_RETENTION_DAYS` (30 in prod, 7 in staging). On-demand:

```
./scripts/backup-db.sh prod                                  # writes manual-YYYYMMDD-HHMMSS.sql.gz
./scripts/restore-db.sh prod backup-20260601-020000.sql.gz   # DESTRUCTIVE — requires typing DB name to confirm
```

## Logs

```
./scripts/logs.sh prod              # follow all services
./scripts/logs.sh prod backend      # follow one service
./scripts/logs.sh prod cms
./scripts/logs.sh prod nginx
```

## Files in this repo

```
docker-compose.yml              # Base — services, volumes, networks
docker-compose.prod.yml         # Prod overrides — restart=always, large log retention
docker-compose.staging.yml      # Staging overrides
docker-compose.dev.yml          # Local dev (nginx/certbot/db-backup disabled)
docker-compose.tunnel.yml       # Cloudflare Tunnel mode (disables nginx + certbot)
.env.example                    # Template (commit), copy to .env / .env.staging / .env.prod
.env.prod.example
.env.staging.example
nginx/nginx.conf
nginx/conf.d/monopetsky.conf.template
postgres/init/01-extensions.sql
scripts/configure-env.sh        # Generate .env.<env> with strong secrets
scripts/configure-nginx.sh      # Render nginx.conf.template
scripts/deploy.sh               # Pull + build + up + health check
scripts/migrate.sh              # Manual migration re-run
scripts/backup-db.sh            # On-demand pg_dump
scripts/restore-db.sh           # Restore from backup (destructive)
scripts/logs.sh                 # Tail compose logs
```

## Cloudflare Tunnel mode

An alternative to nginx + Let's Encrypt: terminate TLS at Cloudflare and run `cloudflared` as a Docker container alongside the other services.

**Setup:**

1. Create a tunnel in the Cloudflare dashboard and copy the tunnel token.
2. Add `CLOUDFLARE_TUNNEL_TOKEN=<token>` to your `.env.prod` (or `.env.staging`).
3. In the Cloudflare dashboard, configure ingress rules for the tunnel:
   - `https://example.com` → `http://frontend:${FRONTEND_PORT}`
   - `https://cms.example.com` → `http://cms:${CMS_PORT}`
   - `https://api.example.com` → `http://backend:${BACKEND_PORT}`
4. Deploy with the `--tunnel` flag:
   ```
   ./scripts/deploy.sh prod --tunnel
   ```

This activates `docker-compose.tunnel.yml`, which disables `nginx` and `certbot` and starts the `cloudflared` container on the `web_net` network. No separate host-side `cloudflared` process is needed.

## Notes

- `nginx/conf.d/monopetsky.conf` and `.env`/`.env.staging`/`.env.prod` are gitignored — they're operator-local.
- Backend ports are bound to `127.0.0.1` only via the prod/staging overrides; public access goes through nginx (or cloudflared in tunnel mode). Without this, Docker's iptables rules bypass UFW and expose the port.
- The backend's `/uploads/*` static route has `Cross-Origin-Resource-Policy: cross-origin` so the CMS and storefront on other subdomains can render uploaded images.
