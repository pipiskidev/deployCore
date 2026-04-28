# portainer/ — opt-in admin UI

Stand-alone compose for Portainer CE. Bound to `127.0.0.1:9000` on the host
so it's NOT directly exposed to the internet — host nginx is the only
ingress, via `https://${PORTAINER_DOMAIN}/` (configured in repo `.env`).

## Setup

`bootstrap.sh --with-portainer` does all of this automatically. Manual flow:

```bash
# 1. Set the public hostname
echo 'PORTAINER_DOMAIN=portainer.example.com' >> .env

# 2. Issue cert
./scripts/issue-cert.sh portainer.example.com

# 3. Generate /etc/nginx/conf.d/portainer.conf from the template
./scripts/up-portainer.sh

# 4. Reload nginx
./scripts/reload-nginx.sh
```

## Stop / remove

```bash
docker compose -f portainer/docker-compose.yml down       # stop, keep data
docker compose -f portainer/docker-compose.yml down -v    # also remove portainer_data volume

sudo rm /etc/nginx/conf.d/portainer.conf
sudo systemctl reload nginx
```

## Security note

Portainer manages every container on this host (`/var/run/docker.sock` is
mounted read-only — but its API still allows reading container envs,
including secrets). Treat the admin password like a root SSH password and
strongly consider adding the `allow`/`deny` IP allowlist in
`/etc/nginx/conf.d/portainer.conf`.
