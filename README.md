# deployCore

A two-layer Docker platform for a single Linux server:

- **`core/`** — install once. Nginx (containerized), Certbot with auto-renewal, Portainer.
- **`projects/<name>/`** — add many. Each project ships a single `docker-compose.yml`, a project `.env`, and an `nginx.conf` that registers a domain with the core nginx.

Designed so that adding a new project to a running server is one command:

```
./scripts/add-project.sh myapp myapp.example.com
```

## Quick start (fresh Ubuntu 22.04 / Debian 12 / RHEL family server)

Only `git`, `curl`, and `sudo` need to be present beforehand. `bootstrap.sh`
detects a missing Docker and installs Docker Engine + Compose plugin via the
official `get.docker.com` script (after asking for confirmation).

```bash
git clone <this-repo> deployCore && cd deployCore

# 1. Fill in global infra vars
cp .env.example .env
$EDITOR .env                # set LETSENCRYPT_EMAIL at minimum

# 2. Bring up core (always nginx + certbot, optional portainer/mail)
./scripts/bootstrap.sh                     # interactive prompts
# or non-interactive:
./scripts/bootstrap.sh --yes               # only mandatory core, no extras
./scripts/bootstrap.sh --with-portainer    # +portainer
./scripts/bootstrap.sh --with-portainer --with-mail

# 3. Add a project (full = backend + web + db; or pick a profile)
./scripts/add-project.sh myapp myapp.example.com
./scripts/add-project.sh myapi myapi.example.com --profile backend
./scripts/add-project.sh static static.example.com --profile web --skip-cert
```

After step 2 you have a running nginx that 444s any unknown host and serves
`/.well-known/acme-challenge/` for any domain pointed at it. Step 3 issues a
TLS certificate, links the project's nginx config, and brings the project up.

If `bootstrap.sh` had to install Docker, it adds your user to the `docker`
group — log out and back in (or `newgrp docker`) before rerunning, so the
shell can reach the daemon without sudo.

## Modular install — what's optional, what's mandatory

| Component | Default | How to enable |
|-----------|---------|---------------|
| **nginx + certbot** (in `core/`) | always on | mandatory; comes up with `bootstrap.sh` |
| **portainer** (in `core/`) | off | `bootstrap.sh --with-portainer`, or interactive prompt answers `y` |
| **mail** (in `shared/mail/`) | off | `bootstrap.sh --with-mail`, or `./scripts/up-mail.sh` later |
| **a project** (in `projects/<name>/`) | off | `./scripts/add-project.sh <name> <domain>` |

For a project, you can pick which subset of its services runs via compose
profiles. The `_template` and `max` projects ship with these:

| Profile | What it runs |
|---------|--------------|
| `full`  | every service in the project |
| `backend` | backend + database (no public frontend) |
| `web`   | only the public frontend (e.g. when backend lives elsewhere) |
| `app`   | only the single `<name>-app` container (template default) |

```bash
./scripts/add-project.sh blog blog.example.com --profile backend
# Later: switch to running both backend and web:
./scripts/up-project.sh blog backend web
# Or stop everything for the project (data preserved):
./scripts/up-project.sh blog --down
```

Adding a new profile to your project: edit
`projects/<name>/docker-compose.yml` and put the relevant services under
`profiles: [your-profile-name]`. No script changes needed.

## Layout

```
deployCore/
├── .env.example, .env               # global infra vars (LETSENCRYPT_EMAIL, TZ, ACME_STAGING)
├── core/                            # platform — installed once
│   ├── docker-compose.yml
│   ├── nginx/
│   │   ├── Dockerfile               # nginx:alpine + inotify reload-on-renew
│   │   ├── nginx.conf
│   │   ├── conf.d/
│   │   │   └── _default.conf        # catch-all on :80, serves acme-challenge for any host
│   │   └── snippets/                # ssl-common, security-headers, proxy-common, rate-limits, bot-detection
│   └── certbot/
│       └── webroot/                 # bind-mount: certbot writes acme-challenge here, nginx serves from here
├── projects/                        # apps — one folder per project
│   ├── _template/                   # source for add-project.sh
│   └── max/                         # first project (the original deployCore reference app)
├── shared/
│   └── mail/                        # opt-in SMTP server (docker-mailserver)
└── scripts/
    ├── bootstrap.sh                 # one-time setup; --with-portainer / --with-mail / --yes
    ├── add-project.sh <name> <domain> [--profile p] [--skip-cert] [--skip-up]
    ├── up-project.sh <name> [profile...] [--down]   # bring an existing project up/down
    ├── remove-project.sh <name>     # take a project down + unlink nginx (data preserved)
    ├── up-mail.sh                   # bring shared/mail/ up (requires mailserver.env)
    ├── issue-cert.sh <domain>       # issue a TLS cert without adding a project
    ├── reload-nginx.sh              # nginx -t && nginx -s reload
    └── lib/common.sh                # shared bash helpers + Docker auto-installer
```

## Networking

All public-facing services join an external Docker network `web`, created by
`bootstrap.sh`. Core nginx joins `web` and is the only container that binds
host ports (80, 443).

Each project also gets a private `<project>-internal` network for things that
nginx must not reach (databases, queues). Containers needed by nginx join
`web`. Container names are globally unique and include the project prefix
(e.g. `max-backend`, `max-web`, `max-mongo`).

## TLS

`core-certbot` runs `certbot renew` every 12 hours. After a successful renewal
it touches `/var/www/certbot/.reload`; the nginx container's entrypoint
watches that file with `inotifywait` and runs `nginx -s reload` when it
changes. No host cron needed.

The `core/nginx/conf.d/_default.conf` server block serves
`/.well-known/acme-challenge/` for any unknown host, so initial issuance for a
new domain works without per-domain temp configs.

`ACME_STAGING=1` in `.env` switches issuance to Let's Encrypt staging — useful
when iterating on `add-project.sh`.

## Adding a project from scratch

```bash
./scripts/add-project.sh blog blog.example.com
```

This:
1. copies `projects/_template/` to `projects/blog/`,
2. substitutes `${PROJECT_NAME}` and `${DOMAIN}` everywhere,
3. opens `projects/blog/.env` in `$EDITOR` for any project-specific vars,
4. issues a Let's Encrypt cert for `blog.example.com`,
5. symlinks `projects/blog/nginx.conf` into `core/nginx/conf.d/blog.conf`,
6. brings the project up: `docker compose -f projects/blog/docker-compose.yml up -d`,
7. reloads nginx.

## Adding a project from an existing compose file

If you already have a `docker-compose.yml` for an OSS app:

1. Drop it into `projects/<name>/docker-compose.yml`.
2. Make sure containers have unique names (`<name>-<service>`).
3. The publicly-reachable service must join the `web` network (`external: true`).
4. Don't expose any host ports — nginx reaches it by container name.
5. Write `projects/<name>/nginx.conf` (use `_template/nginx.conf` as a base).
6. Issue a cert: `./scripts/issue-cert.sh <domain>`.
7. Symlink: `ln -sf ../../projects/<name>/nginx.conf core/nginx/conf.d/<name>.conf`.
8. Up: `docker compose -f projects/<name>/docker-compose.yml up -d && ./scripts/reload-nginx.sh`.

## Removing a project

```bash
./scripts/remove-project.sh blog
```

Brings the project down, removes its nginx-conf symlink, reloads nginx. Does
**not** delete the project folder, its `.env`, or any named volumes — that's
manual and explicit.

TLS certificates are also left intact. Revoke them yourself if needed
(`docker compose -f core/docker-compose.yml run --rm certbot revoke ...`).

## Migrating from the original deployCore

The old layout (`backend/`, `frontend/`, `database/`, `mail/`, `portainer/`,
`1-web.conf`, top-level `nginx.conf`) is **kept on disk for reference** while
v2 is being verified. Once you've confirmed the new stack works on a target
server, delete those files manually:

```bash
rm -rf backend frontend database mail portainer 1-web.conf nginx.conf
```

Important migration notes:

- **Rotate the MongoDB password.** The literal in the old `backend/docker-compose.yml`
  and `database/docker-compose.yml` is compromised (it lived in plaintext in this
  repo). On the running mongo, run:
  ```
  mongosh -u root -p <old-password> --eval 'db.adminCommand({setParameter:1,...}); db.changeUserPassword("root","<new-password>")'
  ```
  Put the new password into `projects/max/.env` as `MONGO_PASSWORD`.

- **Drop `network_mode: host`.** The old compose files used host networking; v2
  uses the `web` bridge network. Backends are no longer reachable on
  `127.0.0.1:<port>` from the host — they're reachable only via nginx. If
  anything other than nginx talked to backends through `127.0.0.1`, you need
  to either add it to the `web` network or expose ports explicitly (not
  recommended).

- **Other domains.** `1-web.conf` covered ~14 unrelated domains (`zaytsv.ru`,
  `getatom.ru`, `tfpro.ru`, etc.). v2 ships only `max`. Configurations for
  other projects belong in their own deployCore deployments or their own
  repos.

## Operational notes

- **Portainer** binds only to `127.0.0.1:9000`. Reach it via SSH tunnel:
  `ssh -L 9000:localhost:9000 <user>@<server>` then open `http://localhost:9000`.
- **Mail** (`shared/mail/`) is opt-in. Bring up with
  `docker compose -f shared/mail/docker-compose.yml up -d` after configuring
  `shared/mail/mailserver.env`.
- **Logs** for any container: `docker compose -f core/docker-compose.yml logs -f nginx`
  or via Portainer.
