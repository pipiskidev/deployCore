FROM nginx:1.27-alpine

# inotify-tools for watching /var/www/certbot/.reload (renewal trigger).
# tini for proper signal handling.
RUN apk add --no-cache inotify-tools tini

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# conf.d/ and snippets/ are bind-mounted at runtime.

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
