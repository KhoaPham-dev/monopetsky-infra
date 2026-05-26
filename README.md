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

## VPS prerequisites

Provision an Ubuntu 22.04+ LTS VPS (minimum 2 vCPU / 4GB RAM / 40GB disk) and prepare it manually before running any scripts in this repo. Do each step as `root` (or with `sudo`) unless noted.

### 1. DNS

Point A records at the VPS public IP for all hostnames you intend to use:

- `monopetsky.example.com`, `api.monopetsky.example.com`, `cms.monopetsky.example.com`
- Staging equivalents if applicable

### 2. Base packages

```sh
apt-get update
apt-get install -y ca-certificates curl gnupg ufw rsync git
```

### 3. GitHub CLI (`gh`)

`gh` is used to authenticate and pull private repos during deployment. It isn't in the standard Ubuntu repos, so add GitHub's apt source first:

```sh
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update
apt-get install -y gh
```

Authenticate once as the `deploy` user (after creating it in step 7):

```sh
gh auth login
```

### 4. Docker Engine + Compose plugin

Follow the official Docker install guide for Ubuntu: <https://docs.docker.com/engine/install/ubuntu/>. After install, confirm:

```sh
docker --version
docker compose version
systemctl enable --now docker
```

### 5. Firewall (UFW)

Allow only SSH, HTTP, and HTTPS:

```sh
ufw allow 22/tcp
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

### 6. Swap (recommended on small VPSes)

```sh
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 7. Deploy user

Create a non-root user with `sudo` and `docker` group membership:

```sh
adduser --disabled-password --gecos "" deploy
usermod -aG sudo,docker deploy
newgrp docker # activate the change run from the deploy user
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

### 8. SSH key + lock down root

From your laptop, append your public key to the deploy user's `authorized_keys` (e.g. `ssh-copy-id deploy@<vps-ip>` or paste the contents of `~/.ssh/id_ed25519.pub`). Verify `ssh deploy@<vps-ip>` works, then disable root login:

```sh
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh
```

---

## TLS cert bootstrap

Initial Let's Encrypt cert issuance uses certbot's `--standalone` mode (certbot opens its own port-80 server) writing into the same named volume nginx will later read from. After this, the running `certbot` compose service handles renewals automatically.

The compose volume is named `<project>_letsencrypt`, where `<project>` is the directory name — typically `monopetsky-infra`. The commands below assume that.

**a. Make sure the stack is down so port 80 is free:**

```sh
cd ~/monopetsky-infra
docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod down 2>/dev/null || true
```

**b. Issue prod certs.** Run once for each hostname (replace `-d` values with your real domains and `--email` with yours):

```sh
# prod frontend
docker run --rm -p 80:80 \
  -v monopetsky-infra_letsencrypt:/etc/letsencrypt \
  -v monopetsky-infra_letsencrypt_www:/var/www/certbot \
  certbot/certbot:v3.0.1 certonly --standalone \
  --email ops@example.com --agree-tos --no-eff-email \
  -d monopetsky.example.com

# prod backend
docker run --rm -p 80:80 \
  -v monopetsky-infra_letsencrypt:/etc/letsencrypt \
  -v monopetsky-infra_letsencrypt_www:/var/www/certbot \
  certbot/certbot:v3.0.1 certonly --standalone \
  --email ops@example.com --agree-tos --no-eff-email \
  -d api.monopetsky.example.com

# prod CMS
docker run --rm -p 80:80 \
  -v monopetsky-infra_letsencrypt:/etc/letsencrypt \
  -v monopetsky-infra_letsencrypt_www:/var/www/certbot \
  certbot/certbot:v3.0.1 certonly --standalone \
  --email ops@example.com --agree-tos --no-eff-email \
  -d cms.monopetsky.example.com
```

**c. Verify the certs landed in the volume:**

```sh
docker run --rm -v monopetsky-infra_letsencrypt:/etc/letsencrypt alpine \
  ls /etc/letsencrypt/live
# expect a directory per hostname, each containing fullchain.pem + privkey.pem
```

---

## Port map

| Service  | dev (host) | staging (host) | prod (host) |
|----------|------------|----------------|-------------|
| Postgres | 5432       | (internal)     | (internal)  |
| Backend  | 5050       | 5050           | 5050        |
| Frontend | 5002       | 5002           | 5002        |
| CMS      | 5001       | 5001           | 5001        |
| nginx    | (off)      | 80, 443        | 80, 443     |

In staging and prod, only nginx is reachable from the public internet — the FE/BE/CMS host ports are bound to localhost via the firewall (UFW only allows 22/80/443).

---

## Troubleshooting

- **certbot "no certificate found"** on first start: TLS certs don't exist yet. Either issue them with the standalone command in the TLS cert bootstrap section above, or temporarily comment out the `listen 443 ssl` server blocks in `nginx/conf.d/monopetsky.conf`, deploy, then run a webroot-mode certbot via the running stack and uncomment.
- **Backend health check failing**: check `./scripts/logs.sh <env> backend`. Common causes: `DATABASE_URL` wrong, `JWT_SECRET` unset, migrations failing (look for `psql:` errors).
- **`npm ci` fails during build**: the repo's `package-lock.json` is out of sync. Run `npm install` locally, commit the updated lockfile.
- **Frontend or CMS bakes wrong API URL**: `NEXT_PUBLIC_API_URL` is consumed at *build* time. After changing it, redeploying with `--no-build` will not pick it up — drop `--no-build`.
- **Disk filling up**: `docker system prune -af --volumes` (careful — won't touch named volumes in use, but will drop unused images).

### Rollback

```sh
git -C ~/monopetsky-backend  checkout <previous-good-sha>
git -C ~/monopetsky-frontend checkout <previous-good-sha>
git -C ~/monopetsky-cms      checkout <previous-good-sha>
./scripts/deploy.sh prod --no-pull
```

---

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

## Notes

- `nginx/conf.d/monopetsky.conf` and `.env`/`.env.staging`/`.env.prod` are gitignored — they're operator-local.
- Backend ports are bound to `127.0.0.1` only via the prod/staging overrides; public access goes through nginx. Without this, Docker's iptables rules bypass UFW and expose the port.
- The backend's `/uploads/*` static route has `Cross-Origin-Resource-Policy: cross-origin` so the CMS and storefront on other subdomains can render uploaded images.
