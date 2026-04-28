# Project template

Source for `scripts/add-project.sh`. Don't edit unless you want to change the
defaults applied to every new project.

## Placeholders substituted at copy time

| Placeholder | Meaning | Example | Filled by |
|-------------|---------|---------|-----------|
| `${PROJECT_NAME}` | Folder name + container prefix. Lowercase, `[a-z0-9-]+`. | `blog` | argument |
| `${DOMAIN}` | Public hostname. | `blog.example.com` | argument |
| `${IMAGE}` | Docker image. | `node:20-alpine` | `.env` (operator) |
| `${APP_PORT}` | Port the app listens on inside the container. | `3000`, `8080` | `.env` (operator) |
| `${HOST_PORT}` | Loopback port host nginx proxies to. | auto-picked from 10000-19999 | `add-project.sh` |

## What you get out of the box

- Single service `<name>-app`.
- Container ports bound to `127.0.0.1:${HOST_PORT}` (loopback only — no public exposure besides nginx).
- A `<name>-internal` private docker network for any extra services you add.
- nginx server block: HTTP→HTTPS redirect, HTTPS with security headers,
  10 r/s rate limit (zone `general`), 30 concurrent connections per IP.
- Compose profiles `full` and `app`. `docker compose up -d` without a profile is a no-op.

## Common modifications after copy

- **Multiple services** — add `<name>-db`, `<name>-cache` to the same compose.
  Put them on `<name>-internal` only (don't bind ports — they're reached by
  service name from `<name>-app` over the internal network).
- **Multi-location nginx** — split `/api` (rate-limit `api`) from `/`
  (rate-limit `general`); see `projects/max/nginx.conf` for an example.
- **Volumes** — declare named volumes at the bottom of compose for state.
- **WebSockets** — in `nginx.conf`, add inside the relevant location:
  ```
  proxy_set_header Upgrade    $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  ```
  (`$connection_upgrade` is set by the global `websocket-upgrade.conf` snippet.)
