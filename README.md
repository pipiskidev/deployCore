# deployCore

Modular Docker platform for a single Linux server. **Host nginx + host certbot**
front the public internet; backends run as Docker containers bound to
`127.0.0.1:<port>`.

- **`nginx/`** — config files copied to `/etc/nginx/` by `scripts/bootstrap.sh`.
- **`portainer/`** — opt-in admin UI (Docker container, loopback bind).
- **`shared/mail/`** — opt-in SMTP server (Docker container).
- **`projects/<name>/`** — apps. Each project has one `docker-compose.yml`,
  one `.env`, and one `nginx.conf` symlinked into `/etc/nginx/conf.d/`.

Adding a new project to a running server is one command:

```
./scripts/add-project.sh myapp myapp.example.com
```

## Quick start (fresh Ubuntu 22.04 / Debian 12 / RHEL family server)

Only `git`, `curl`, and `sudo` need to be present beforehand.
`scripts/bootstrap.sh` installs everything else: Docker (via `get.docker.com`),
nginx (apt/dnf), certbot (apt/dnf), and enables `certbot.timer` for renewals.

```bash
git clone https://github.com/pipiskidev/deployCore.git
cd deployCore
./scripts/bootstrap.sh
```

That's it. After Docker is installed, bootstrap launches a temporary web UI
on port **8888**. Open `http://<your-server-ip>:8888` in a browser, fill out
the form (Let's Encrypt email, what to install — Portainer? mail? configure
the `example` project — backend? frontend? db? — domains, tokens), click **Save and continue**. The UI
writes the right `.env` files, exits, and bootstrap continues with apt
installs, syncing `/etc/nginx/`, and bringing up whichever optional services
you ticked.

If you'd rather skip the browser UI:

```bash
./scripts/bootstrap.sh --no-ui --yes               # nginx + certbot only (.env must exist)
./scripts/bootstrap.sh --no-ui --with-portainer    # +portainer
./scripts/bootstrap.sh --no-ui --with-portainer --with-mail
INSTALL_UI_PORT=9090 ./scripts/bootstrap.sh        # use a different port for the UI
```

After bootstrap, add a project:

```bash
./scripts/add-project.sh myapp myapp.example.com
./scripts/add-project.sh myapi myapi.example.com --profile backend
./scripts/add-project.sh static static.example.com --profile web --skip-cert
```

If `bootstrap.sh` had to install Docker, it adds your user to the `docker`
group — log out and back in (or `newgrp docker`) before rerunning.

The temporary UI runs in a `node:20-alpine` Docker container with the repo
bind-mounted; nothing about Node is installed on the host. Files it writes
are owned by your user (it runs `--user $(id -u):$(id -g)`).

## Layout

```
deployCore/
├── .env.example, .env                  # LETSENCRYPT_EMAIL, TZ, ACME_STAGING, PORTAINER_DOMAIN
├── nginx/                              # source of truth → copied to /etc/nginx/
│   ├── nginx.conf
│   ├── conf.d/
│   │   ├── _default.conf               # catch-all on :80, serves acme-challenge
│   │   └── portainer.conf.template     # rendered to /etc/nginx/conf.d/portainer.conf
│   └── snippets/                       # ssl-common, security-headers, proxy-common,
│                                       # rate-limits, bot-detection, websocket-upgrade
├── portainer/                          # opt-in admin UI
│   └── docker-compose.yml              # container bound to 127.0.0.1:9000
├── projects/                           # apps
│   ├── _template/                      # copy source for add-project.sh
│   └── example/                        # example project (Spring Boot + Next.js + Mongo)
├── shared/
│   └── mail/                           # opt-in SMTP (docker-mailserver)
└── scripts/
    ├── bootstrap.sh                    # one-time setup: launches install UI then provisions
    ├── preflight.sh                    # READ-ONLY: print inventory of installed/configured state
    ├── install-ui.js                   # browser configuration UI (Node, run via docker)
    ├── sync-nginx.sh                   # copy nginx/ → /etc/nginx/, validate, reload
    ├── add-project.sh                  # add-project.sh <name> <domain> [--profile p] [--port n] [--no-domain]
    ├── up-project.sh                   # bring an existing project up/down with profiles
    ├── remove-project.sh               # take a project down + unlink nginx (data preserved)
    ├── up-portainer.sh                 # render portainer.conf, issue cert, start container
    ├── up-mail.sh                      # bring shared/mail/ up
    ├── issue-cert.sh                   # certbot certonly --webroot -d <domain>
    ├── reload-nginx.sh                 # nginx -t && systemctl reload nginx
    └── lib/common.sh                   # bash helpers (validators, find_free_port, status_*)
```

## Idempotency and preflight

Everything in `scripts/` is safe to rerun. `bootstrap.sh` checks each
component before installing or starting it:

- **Docker**: skipped if `docker info` and `docker compose version` work.
- **nginx + certbot**: skipped if `nginx`/`certbot` are already on PATH (no
  `apt-get update`, no package install).
- **`web` Docker network**: skipped if it already exists.
- **install UI**: skipped automatically if `.env` already has a real
  `LETSENCRYPT_EMAIL` (re-run scenario). Use `--force-ui` to re-open it.
- **Portainer / mail**: containers checked first — skipped if already
  running. Nginx config not re-rendered if already correct.
- **TLS certs**: `certbot --keep-until-expiring` flag — never re-issues a
  cert that's still valid.

To inspect state without changing anything:

```bash
./scripts/preflight.sh           # human-readable
./scripts/preflight.sh --json    # for CI / monitoring
```

Sample output:
```
deployCore preflight
  os:        debian (Ubuntu 22.04.3 LTS)
  docker:    installed (engine 24.0.7, compose v2.21.0)
  nginx:     installed (1.18.0), active
  certbot:   installed (1.21.0), timer active
  portainer: running (Up 3 hours)
  mail:      not deployed
  projects:  example blog (2)
  network:   web (exists)

project:example  .env=yes  nginx=yes  running=yes (example-backend,example-mongo)
project:blog     .env=yes  nginx=yes  running=yes (blog-app)

certs (Let's Encrypt):
  example.example.com   expires: Jul 28 11:42:00 2026 GMT
  blog.example.com      expires: Jul 28 11:43:00 2026 GMT
```

## Modular install — what's optional, what's mandatory

| Component | Default | How to enable | Where it runs |
|-----------|---------|---------------|---------------|
| **nginx** | always on | apt installed by `bootstrap.sh` | host (`systemctl`) |
| **certbot** | always on | apt installed by `bootstrap.sh`; `certbot.timer` auto-renews | host (`systemctl`) |
| **portainer** | off | `bootstrap.sh --with-portainer` or `./scripts/up-portainer.sh` | docker, `127.0.0.1:9000` |
| **mail** | off | `bootstrap.sh --with-mail` or `./scripts/up-mail.sh` | docker, ports 25/465/587/143/993 |
| **a project** | off | `./scripts/add-project.sh <name> <domain>` | docker, `127.0.0.1:<auto-port>` |

For a project, you can pick which subset of its services runs via compose
profiles. `_template` and `example` ship with these:

| Profile | What runs |
|---------|-----------|
| `full` | every service in the project |
| `backend` | backend + database (no public frontend) |
| `web` | only the public frontend |
| `app` | only the single `<name>-app` container (template default) |

```bash
./scripts/add-project.sh blog blog.example.com --profile backend
./scripts/up-project.sh blog backend web        # union of profiles
./scripts/up-project.sh blog --down             # stop everything (data preserved)
```

## Networking model

- nginx runs on the host and binds `:80` and `:443` directly.
- Each project's containers bind to `127.0.0.1:<HOST_PORT>` only — never public.
- nginx proxies `https://<domain>/` → `http://127.0.0.1:<HOST_PORT>`.
- Inside a project, services that talk to each other but NOT to nginx (like
  databases) join a private `<name>-internal` docker network and don't bind
  any ports.
- HOST_PORT for new projects is auto-assigned by `add-project.sh` from the
  range 10000-19999 (avoiding ports already in use OR claimed by other
  projects' `.env` files).

## TLS

- `certbot.timer` (systemd, enabled by `bootstrap.sh`) runs `certbot renew`
  twice a day. No host cron needed.
- `bootstrap.sh` installs a deploy-hook (`/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`)
  so renewals trigger `systemctl reload nginx` automatically.
- The catch-all `/etc/nginx/conf.d/_default.conf` serves
  `/.well-known/acme-challenge/` for any unknown host on :80, so initial
  issuance for a new domain works without per-domain temp configs.
- `ACME_STAGING=1` in `.env` switches issuance to staging — useful when
  iterating on `add-project.sh`.

## Editing nginx files

- **Global stuff** (snippets, the main `nginx.conf`, `_default.conf`): edit in
  the repo `nginx/`, then `./scripts/sync-nginx.sh` to copy + reload.
- **Per-project nginx**: `/etc/nginx/conf.d/<name>.conf` is a SYMLINK into
  `projects/<name>/nginx.conf`, so edits apply on
  `./scripts/reload-nginx.sh` — no sync needed.
- **Portainer config** (`/etc/nginx/conf.d/portainer.conf`): generated from
  `nginx/conf.d/portainer.conf.template`. Re-run `./scripts/up-portainer.sh`
  to regenerate.

## Removing a project

```bash
./scripts/remove-project.sh blog
```

Stops the project's containers, removes its `/etc/nginx/conf.d/` symlink,
reloads nginx. Does **not** delete `projects/blog/`, its `.env`, named
volumes, or TLS certificates — those require explicit operator action.

## Operational notes

- **Portainer security**: set a strong admin password on first login. To
  restrict by IP, edit `/etc/nginx/conf.d/portainer.conf` and uncomment the
  `allow`/`deny` block, then `./scripts/reload-nginx.sh`.
- **Mail** (`shared/mail/`) needs port 25 open at your hosting provider; many
  block it by default. DNS records (MX, SPF, DKIM, DMARC, PTR) are NOT
  configured by this stack — set them up at your DNS provider.
- **Logs**: `sudo journalctl -u nginx -f` for nginx, `docker compose -f
  projects/example/docker-compose.yml logs -f` for a project.
