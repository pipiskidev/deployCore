# max — first project

Equivalent of the original `deployCore/{backend,frontend,database}/`
configurations, restructured for the v2 platform layout.

## Services

| Container | Image | Networks | Public? |
|-----------|-------|----------|---------|
| `max-backend` | `openjdk:17-jdk-slim` | `web`, `max-internal` | Yes (via nginx → :8080) |
| `max-web` | `node:20-alpine` | `web` | Yes (via nginx → :3000) |
| `max-mongo` | `mongo:7` | `max-internal` only | No |

## First-time setup

```bash
# 1. Configure secrets
cp .env.example .env
$EDITOR .env                                    # set MAX_DOMAIN, MONGO_PASSWORD, ...

# 2. Substitute the real domain in nginx.conf
sed -i "s/max.example.com/$(grep '^MAX_DOMAIN=' .env | cut -d= -f2)/g" nginx.conf

# 3. Issue TLS certificate (core must be running first — see ../../README.md)
../../scripts/issue-cert.sh "$(grep '^MAX_DOMAIN=' .env | cut -d= -f2)"

# 4. Symlink nginx config and reload
ln -sf "$(pwd)/nginx.conf" ../../core/nginx/conf.d/max.conf
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

## Migrating from the old deployCore

The old repo had three separate compose files (`backend/`, `frontend/`,
`database/`) with `network_mode: host` and a hardcoded MongoDB password. To
migrate the live server:

1. Stop the old containers:
   ```
   docker rm -f max.backend max.web mongodb
   ```
2. Rotate the MongoDB password (see `.env.example`).
3. The mongo data volume from the old setup is named `mongo-data` (per
   `database/docker-compose.yml`) and will not be picked up by `max-mongo`
   (which uses `max-mongo-data`). To preserve data, either:
   - Dump and restore: `mongodump` against the old container, then
     `mongorestore` into the new `max-mongo`.
   - Or rename the old volume: `docker volume create max-mongo-data &&
     docker run --rm -v mongo-data:/from -v max-mongo-data:/to alpine
     sh -c "cd /from && cp -av . /to"`.
4. Bring up new stack with `docker compose --profile full up -d`.
