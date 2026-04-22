# CurationsVibes CRM — Self-Hosted Deployment Runbook

A production deployment guide for **CURATIONS** (curations.org) and **CurationsLA**
(curationsla.com) on a single-VM, Cloudflare-protected, Docker Compose stack.

---

## Architecture overview

```
Cloudflare DNS (Paid)
    └── Cloudflare Tunnel (Zero Trust)
            └── Docker Compose stack on your VM
                    ├── server   (Twenty API + frontend, port 3000 — internal only)
                    ├── worker   (BullMQ background jobs)
                    ├── db       (Postgres 16)
                    ├── redis    (Redis 7)
                    └── cloudflared (Cloudflare Tunnel agent)
```

All external traffic reaches the VM **only** through the Cloudflare Tunnel — no
inbound firewall ports need to be opened, and Cloudflare provides automatic HTTPS,
WAF, DDoS protection, and bot management.

---

## Service roles

| Service | Purpose | Provided by |
|---|---|---|
| **GitHub Enterprise** | Source control, CI/CD, issue tracking | GitHub for Startups |
| **Cloudflare Paid** | DNS, WAF, SSL, Tunnel, R2 storage (optional) | Cloudflare |
| **Docker Compose VM** | Runs Twenty CRM (server, worker, db, redis) | Your chosen cloud provider |
| **Resend Paid** | Transactional + notification email via SMTP | Resend |
| **Claude / Anthropic Paid** | AI summaries, drafting, enrichment, automations | Anthropic |

---

## VM sizing (one-seat, two workspaces)

| Spec | Minimum | Recommended |
|---|---|---|
| CPU | 2 vCPU | 4 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 20 GB SSD | 40 GB SSD |
| OS | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |

> A $24/month Hetzner CX22 (4 vCPU / 8 GB) or $24/month DigitalOcean Droplet
> comfortably covers this workload.

---

## Phase 1 — Prerequisites

### 1.1 Install Docker & Docker Compose

```bash
# Ubuntu 22.04
curl -fsSL https://get.docker.com | sudo bash
sudo usermod -aG docker $USER
# Log out and back in, then verify:
docker compose version  # must be >= 2.0
```

### 1.2 Clone this repository onto the VM

```bash
# With GitHub Enterprise / GitHub for Startups:
git clone git@github.com:CurationsVibes/crm.git /opt/curations-crm
cd /opt/curations-crm/deploy
```

### 1.3 Make scripts executable

```bash
chmod +x backup.sh restore.sh
```

---

## Phase 2 — Cloudflare Tunnel setup

> **Do this before starting the Docker stack.**

1. Log in to [Cloudflare Zero Trust](https://one.dash.cloudflare.com).
2. Go to **Networks → Tunnels → Create a Tunnel**.
3. Name it `curations-crm-prod`. Click **Next**.
4. Choose **Docker**. Copy the `--token` value shown — this is your
   `CLOUDFLARE_TUNNEL_TOKEN`.
5. Under **Public Hostnames**, add two routes:

   | Subdomain | Domain | Type | URL |
   |---|---|---|---|
   | `crm` | `curations.org` | HTTP | `http://server:3000` |
   | `crm` | `curationsla.com` | HTTP | `http://server:3000` |

6. Make sure both domains are already on your Cloudflare account with DNS managed
   by Cloudflare.
7. In Cloudflare DNS for each domain, confirm the CNAME records were created
   automatically by the tunnel.

---

## Phase 3 — Resend email setup

1. Sign up at [resend.com](https://resend.com).
2. Go to **Domains → Add Domain** — add both `curations.org` and `curationsla.com`.
3. Follow the prompts to add the required DNS records in Cloudflare (MX, TXT, DKIM).
4. Create an **API Key** with _Sending Access_ and note the value — this is your
   `RESEND_API_KEY`.
5. Use `crm@curations.org` as the primary `EMAIL_FROM_ADDRESS` (or any verified
   address on your Resend domain).

---

## Phase 4 — Configure environment

```bash
cd /opt/curations-crm/deploy
cp .env.prod.example .env.prod
```

Open `.env.prod` and fill in every `REPLACE_ME` value:

| Variable | How to get it |
|---|---|
| `APP_SECRET` | `openssl rand -base64 32` |
| `PG_DATABASE_PASSWORD` | `openssl rand -hex 32` |
| `RESEND_API_KEY` | Resend dashboard → API Keys |
| `CLOUDFLARE_TUNNEL_TOKEN` | Zero Trust → Tunnels → your tunnel |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys |
| `SERVER_URL` | `https://crm.curations.org` |

> **Security note:** `.env.prod` is listed in `.gitignore` and must never be
> committed to the repository.

Add `.env.prod` to the repo `.gitignore` if not already present:

```bash
echo "deploy/.env.prod" >> /opt/curations-crm/.gitignore
```

---

## Phase 5 — Start the stack

```bash
cd /opt/curations-crm/deploy

# Pull latest images
docker compose -f docker-compose.prod.yml --env-file .env.prod pull

# Start all services
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d

# Watch logs until server is healthy (takes ~2 minutes on first boot)
docker compose -f docker-compose.prod.yml logs -f server
```

The server is ready when you see:

```
server-1  | 🚀 Server is running on: http://localhost:3000
```

Open `https://crm.curations.org` in your browser to verify.

---

## Phase 6 — Workspace setup (CURATIONS + CurationsLA)

Twenty supports multiple independent workspaces under one deployment — the
recommended approach for strict data and user isolation between brands.

### 6.1 Create the first workspace (CURATIONS)

1. Navigate to `https://crm.curations.org`.
2. Click **Create my workspace**.
3. Name it **CURATIONS**, set the display URL / logo.
4. Invite your team members with their `@curations.org` email addresses.

### 6.2 Create the second workspace (CurationsLA)

1. From the same browser, click your avatar → **Add workspace** (or navigate to
   the root and choose "Create workspace").
2. Name it **CurationsLA**.
3. Set the SERVER_URL for this workspace if you want `crm.curationsla.com` to
   open directly into it — add the hostname to the Cloudflare Tunnel and update
   your Twenty configuration or use a path-based workspace selector.
4. Invite team members with their `@curationsla.com` addresses.

> Each workspace has its own contacts, companies, activities, pipelines, and
> settings. Users can be members of both workspaces and switch between them.

### 6.3 Optionally brand each workspace

Inside each workspace: **Settings → General → Workspace** — upload logo,
set display name, configure timezone.

---

## Phase 7 — AI (Claude / Anthropic) setup

1. Log into the Twenty admin panel: `https://crm.curations.org/settings/admin`.
2. Navigate to **Config Variables**.
3. Confirm `ANTHROPIC_API_KEY` is populated (it is set via env, so it should
   already be visible as active).
4. AI features are now available in:
   - **AI Agents** — conversational queries over your CRM data
   - **Field summaries** — one-click record summaries
   - **Workflow automations** — AI steps in workflow builder

---

## Phase 8 — Backups

### 8.1 Run a manual backup to verify

```bash
cd /opt/curations-crm/deploy
./backup.sh --env-file .env.prod
```

You should see a `.tar.gz` file in `/opt/curations-crm/backups/`.

### 8.2 Schedule daily automated backups

```bash
# Edit the cron table for the current user:
crontab -e

# Add this line (runs at 02:00 UTC every day):
0 2 * * * /opt/curations-crm/deploy/backup.sh --env-file /opt/curations-crm/deploy/.env.prod >> /var/log/curations-crm-backup.log 2>&1
```

### 8.3 Off-site backup with Cloudflare R2 (recommended)

1. In the Cloudflare dashboard, open **R2 → Create bucket** → name it
   `curations-crm-backups`.
2. Create an **R2 API token** with _Object Read & Write_ on that bucket.
3. In `.env.prod`, fill in:

   ```ini
   BACKUP_S3_BUCKET=curations-crm-backups
   BACKUP_S3_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com
   BACKUP_S3_ACCESS_KEY_ID=<r2_access_key>
   BACKUP_S3_SECRET_ACCESS_KEY=<r2_secret_key>
   BACKUP_S3_REGION=auto
   ```

4. Install the AWS CLI (used for S3-compatible upload):

   ```bash
   pip install awscli
   ```

5. Run a test backup — you should see the upload step succeed.

---

## Phase 9 — Monitoring (optional)

The repo ships a Grafana stack in `packages/twenty-docker/grafana/`. For a
single-seat deployment, simple log monitoring is sufficient:

```bash
# Stream live logs
docker compose -f docker-compose.prod.yml logs -f

# Check health status
docker compose -f docker-compose.prod.yml ps
```

For production alerting, consider [Uptime Kuma](https://uptime.kuma.pet) (free,
self-hosted) pointed at `https://crm.curations.org/healthz`.

---

## Upgrading

```bash
cd /opt/curations-crm

# 1. Pull the latest code from GitHub
git pull origin main

# 2. Take a pre-upgrade backup
./deploy/backup.sh --env-file ./deploy/.env.prod

# 3. Pull new Docker images and restart
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod pull
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod up -d
```

Database migrations run automatically when the server container starts.

---

## Restoring from backup

```bash
cd /opt/curations-crm/deploy

./restore.sh /opt/curations-crm/backups/curations-crm-YYYYMMDD_HHMMSS.tar.gz \
  --env-file .env.prod
```

The script will ask for confirmation before overwriting any data.

---

## Useful commands

```bash
# View running containers
docker compose -f deploy/docker-compose.prod.yml ps

# Tail all logs
docker compose -f deploy/docker-compose.prod.yml logs -f

# Tail specific service
docker compose -f deploy/docker-compose.prod.yml logs -f server

# Restart a single service
docker compose -f deploy/docker-compose.prod.yml restart worker

# Stop the whole stack
docker compose -f deploy/docker-compose.prod.yml down

# Open a psql shell
docker compose -f deploy/docker-compose.prod.yml exec db \
  psql -U postgres default
```

---

## Security checklist

- [ ] `.env.prod` is NOT committed to git (added to `.gitignore`)
- [ ] `APP_SECRET` and `PG_DATABASE_PASSWORD` are unique random values
- [ ] No inbound firewall ports open on the VM (traffic via Cloudflare Tunnel only)
- [ ] Cloudflare WAF is enabled on both domains
- [ ] Email verification is required (`IS_EMAIL_VERIFICATION_REQUIRED=true`)
- [ ] Workspace creation is limited to server admins
- [ ] Daily backups are scheduled and tested
- [ ] Off-site backup to R2 is configured and verified
- [ ] `TAG` is pinned to a specific version for production (not `latest`)
