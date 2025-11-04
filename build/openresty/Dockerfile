FROM openresty/openresty:1.27.1.2-4-alpine-apk

RUN apk add --no-cache supervisor curl

RUN apk add --no-cache --virtual .build-deps openssl && \
    mkdir -p /etc/ssl && \
    openssl dhparam -out /etc/ssl/dhparam.pem 2048 && \
    apk del .build-deps

COPY supervisord.conf /etc/supervisord.conf

ENTRYPOINT ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]