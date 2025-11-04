FROM certbot/certbot:v5.1.0

RUN apk add --no-cache bash curl yq inotify-tools \
    && pip install --no-cache-dir certbot-dns-cloudflare

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

COPY posthooks/ /posthooks/
RUN chmod +x /posthooks/*.sh

ENTRYPOINT ["/scripts/certbot_agent.sh"]
