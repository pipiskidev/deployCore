# example — example multi-service project

Three independent services with compose profiles so each can be brought up
selectively. Drop in your own backend/frontend code via the host paths below.

## Services

| Container | Image | Host port | Profile(s) | Purpose |
|-----------|-------|-----------|------------|---------|
| `example-backend` | `openjdk:17-jdk-slim` | `127.0.0.1:8066` → :8080 | `full`, `backend` | Spring Boot API |
| `example-web` | `node:20-alpine` | `127.0.0.1:3005` → :3000 | `full`, `web` | Next.js frontend |
| `example-mongo` | `mongo:7` | none (internal only) | `full`, `backend`, `mongo` | Database |

Both backend and web bind to `127.0.0.1` only. Public access is via host
nginx, which proxies `https://${EXAMPLE_DOMAIN}/` → those loopback ports per
[`nginx.conf`](nginx.conf). For internal/no-domain deployments you skip the
nginx symlink and call the loopback ports directly.

## Common deployment shapes

### Full stack with public domain

```bash
# 1. Configure secrets
cp .env.example .env
$EDITOR .env                   # EXAMPLE_DOMAIN, MONGO_PASSWORD, paths

# 2. Substitute real domain into nginx.conf
sed -i "s/example.example.com/$(grep '^EXAMPLE_DOMAIN=' .env | cut -d= -f2)/g" nginx.conf

# 3. Issue TLS cert
../../scripts/issue-cert.sh "$(grep '^EXAMPLE_DOMAIN=' .env | cut -d= -f2)"

# 4. Wire into nginx
sudo ln -sf "$(pwd)/nginx.conf" /etc/nginx/conf.d/example.conf
../../scripts/reload-nginx.sh

# 5. Bring up all three services
docker compose --profile full up -d
```

### Backend-only, no public domain

Useful when you have a worker / API that's only reachable from other
containers, SSH tunnels, or internal cron — no nginx routing, no cert.

```bash
cp .env.example .env
$EDITOR .env                   # MONGO_PASSWORD, BACKEND_JAR_DIR
                               # EXAMPLE_DOMAIN can stay empty
docker compose --profile backend up -d
# example-backend is now reachable on 127.0.0.1:8066 from the host
```

### Frontend-only (backend lives elsewhere)

```bash
cp .env.example .env
$EDITOR .env                   # EXAMPLE_DOMAIN, FRONTEND_DIR
docker compose --profile web up -d
sudo ln -sf "$(pwd)/nginx.conf" /etc/nginx/conf.d/example.conf
../../scripts/reload-nginx.sh
```

You'll likely want to edit `nginx.conf` and remove the `^/(api|hooks|...)` and
`^/(image|generate-image|files)` location blocks since there's no local
backend, OR point `proxy_pass` at the remote backend's URL there.

### Database only

```bash
docker compose --profile mongo up -d
# example-mongo reachable from other containers on example-internal network as `example-mongo:27017`
```

## Selective up after first deploy

```bash
../../scripts/up-project.sh example backend            # backend + mongo
../../scripts/up-project.sh example web                # only frontend
../../scripts/up-project.sh example full               # all three
../../scripts/up-project.sh example --down             # stop everything
```

## Renaming for your real app

`example` is a placeholder name. To rename to e.g. `myapp`:

```bash
mv projects/example projects/myapp
cd projects/myapp
sed -i 's/example-/myapp-/g; s/EXAMPLE_/MYAPP_/g; s/example\.example\.com/myapp.example.com/g' \
    docker-compose.yml nginx.conf .env.example README.md
mv .env.example .env
$EDITOR .env
```

Then proceed as above with the new name. The compose profiles still apply.
