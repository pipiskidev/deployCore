# max — first project (host-nginx model)

## Services

| Container | Image | Host port | Purpose |
|-----------|-------|-----------|---------|
| `max-backend` | `openjdk:17-jdk-slim` | `127.0.0.1:8066` → :8080 | Spring Boot API |
| `max-web` | `node:20-alpine` | `127.0.0.1:3005` → :3000 | Next.js frontend |
| `max-mongo` | `mongo:7` | (none — internal only) | Database |

Both backend and web bind to `127.0.0.1` only. Public access is via host
nginx, which proxies `https://${MAX_DOMAIN}/` → those loopback ports per
[`nginx.conf`](nginx.conf).

## First-time setup

```bash
# 1. Configure secrets
cp .env.example .env
$EDITOR .env                   # set MAX_DOMAIN, MONGO_PASSWORD, paths

# 2. Substitute the real domain in nginx.conf
sed -i "s/max.example.com/$(grep '^MAX_DOMAIN=' .env | cut -d= -f2)/g" nginx.conf

# 3. Issue TLS certificate (host certbot — bootstrap.sh must already have run)
../../scripts/issue-cert.sh "$(grep '^MAX_DOMAIN=' .env | cut -d= -f2)"

# 4. Symlink nginx config into /etc/nginx/conf.d/, reload
sudo ln -sf "$(pwd)/nginx.conf" /etc/nginx/conf.d/max.conf
../../scripts/reload-nginx.sh

# 5. Bring up all three services
docker compose --profile full up -d
```

## Selective up

```bash
docker compose --profile backend up -d   # max-backend + max-mongo
docker compose --profile web     up -d   # max-web only (e.g. backend deployed elsewhere)
docker compose --profile full    up -d   # all three
```

## Migrating from the original deployCore

Old setup ran with `network_mode: host`, so backends listened directly on the
host network. New setup uses bridged docker with explicit loopback bindings.

1. Stop old containers: `docker rm -f max.backend max.web mongodb`.
2. **Rotate the MongoDB password** — the literal in the old repo is
   compromised. In the running mongo:
   ```
   mongosh -u root -p <old-password> \
     --eval 'db.changeUserPassword("root","<new-password>")'
   ```
   Update `MONGO_PASSWORD` in `.env`.
3. The old volume was named `mongo-data` (per `database/docker-compose.yml`);
   new compose creates `max-mongo-data`. Migrate data:
   ```
   docker run --rm -v mongo-data:/from -v max-mongo-data:/to alpine \
     sh -c "cd /from && cp -av . /to"
   ```
4. Bring up new stack: `docker compose --profile full up -d`.
