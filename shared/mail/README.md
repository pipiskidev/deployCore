# shared/mail — opt-in SMTP server

Wraps [docker-mailserver](https://docker-mailserver.github.io/docker-mailserver/)
and reuses the core `letsencrypt` volume so certs issued by core-certbot are
visible to postfix/dovecot.

## Setup

```bash
cp mailserver.env.example mailserver.env
$EDITOR mailserver.env

# Issue a cert for the mail hostname through core-certbot:
../../scripts/issue-cert.sh smtp.example.com

# Bring up:
docker compose -f shared/mail/docker-compose.yml up -d
```

## Adding a mailbox / alias

```bash
docker exec -ti mailserver setup email add user@example.com
docker exec -ti mailserver setup alias add postmaster@example.com user@example.com
docker exec -ti mailserver setup config dkim
```

See the upstream docs for the full list of `setup` subcommands.

## Notes

- DNS records (MX, SPF, DKIM, DMARC, PTR) are NOT configured by this stack —
  set them up in your DNS provider.
- Port 25 must be unblocked at your hosting provider; many block it by default.
- `ENABLE_CLAMAV=1` adds ~600 MB RAM. Disable in `mailserver.env` if tight on memory.
