# Project template

Source for `scripts/add-project.sh`. Don't edit unless you want to change the
defaults applied to every new project.

Placeholders substituted at copy time:

| Placeholder | Meaning | Example |
|-------------|---------|---------|
| `${PROJECT_NAME}` | Folder name + container prefix. Lowercase, `[a-z0-9-]+`. | `blog` |
| `${DOMAIN}` | Public hostname. | `blog.example.com` |
| `${IMAGE}` | Docker image to run. | `nginx:alpine`, `node:20-alpine` |
| `${APP_PORT}` | Internal port exposed by the app container. | `3000`, `8080` |

`${IMAGE}` and `${APP_PORT}` come from the project's `.env` after the operator
fills it in. `${PROJECT_NAME}` and `${DOMAIN}` come from the `add-project.sh`
arguments.

## What you get out of the box

- Single service `<name>-app`, joined to the public `web` network and the
  private `<name>-internal` network.
- Nginx server block: HTTP→HTTPS redirect, HTTPS with full security headers,
  10 r/s rate limit, 30 concurrent connections per IP, all standard proxy headers.
- Compose profiles: `full` and `app`. `docker compose up -d` without a profile
  is a no-op so you can extend before bringing things up.

## Common modifications after copy

- **Multiple services** — add `<name>-db`, `<name>-cache` etc. to the same compose.
  Put them on `<name>-internal` only (don't expose to nginx).
- **Multi-location nginx** — split `/api` (rate-limit `api`) from `/` (rate-limit
  `general`); see `projects/max/nginx.conf` for an example.
- **Volumes** — declare named volumes at the bottom of compose for state.
