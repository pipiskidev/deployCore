# core/ — platform layer

Brought up once by `../scripts/bootstrap.sh`. Contains:

- **nginx** — containerized reverse proxy. Auto-reloads after certbot renewals.
- **certbot** — Let's Encrypt client running a 12-hour renewal loop. No host cron.
- **portainer** — Docker management UI, bound to `127.0.0.1:9000` (SSH-tunnel only).

## Files

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | Defines `core-nginx`, `core-certbot`, `core-portainer`. |
| `nginx/Dockerfile` | nginx:1.27-alpine + inotify-tools + tini. |
| `nginx/entrypoint.sh` | Runs `nginx -s reload` whenever `/var/www/certbot/.reload` appears. |
| `nginx/nginx.conf` | http-block: gzip, security defaults, includes for snippets and projects. |
| `nginx/conf.d/_default.conf` | Catch-all on :80/:443. Serves acme-challenge for any host; rejects everything else. |
| `nginx/conf.d/<project>.conf` | (Runtime) symlinks created by `add-project.sh`. |
| `nginx/snippets/ssl-common.conf` | TLS settings included in every project's HTTPS block. |
| `nginx/snippets/security-headers.conf` | HSTS / X-Frame-Options / Permissions-Policy / etc. |
| `nginx/snippets/proxy-common.conf` | Standard proxy headers + timeouts + buffers. |
| `nginx/snippets/rate-limits.conf` | `limit_req_zone` definitions in http context. |
| `nginx/snippets/bot-detection.conf` | Optional `$prerender` variable for crawler-aware projects. |
| `certbot/webroot/` | Bind-mount; certbot writes acme-challenge here, nginx serves from here. |

## Volumes

- `letsencrypt` — `/etc/letsencrypt`. Read-write in certbot, read-only in nginx. Shared with mail (when used).
- `portainer_data` — Portainer's database.

## Networks

Joins external `web` (created by `bootstrap.sh`).
