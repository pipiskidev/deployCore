#!/bin/sh
# Watches /var/www/certbot/.reload (touched by certbot --deploy-hook after a
# successful renewal) and reloads nginx in-place. Falls back to a 6h poll if
# the marker dir doesn't exist yet.
set -e

RELOAD_DIR="/var/www/certbot"
RELOAD_FILE="$RELOAD_DIR/.reload"

reload_loop() {
  if [ -d "$RELOAD_DIR" ] && command -v inotifywait >/dev/null 2>&1; then
    while inotifywait -qq -e close_write,create,moved_to "$RELOAD_DIR" 2>/dev/null; do
      if [ -f "$RELOAD_FILE" ]; then
        nginx -t 2>&1 && nginx -s reload && rm -f "$RELOAD_FILE"
      fi
    done
  else
    while sleep 21600; do
      if [ -f "$RELOAD_FILE" ]; then
        nginx -t 2>&1 && nginx -s reload && rm -f "$RELOAD_FILE"
      fi
    done
  fi
}

reload_loop &

exec "$@"
