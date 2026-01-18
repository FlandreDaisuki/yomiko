ARG ALPINE_TAG=3.23.2

FROM alpine:${ALPINE_TAG}

RUN apk add --no-cache \
    7zip \
    bash \
    busybox-extras \
    curl \
    imagemagick \
    imagemagick-jpeg \
    imagemagick-webp \
    jq \
    ripgrep \
    sqlite \
 && addgroup -g 1000 yomiko \
 && adduser -u 1000 -G yomiko -h /home/yomiko -s /bin/bash -D yomiko \
 && mkdir -p /home/yomiko/data \
 && chown -R yomiko:yomiko /home/yomiko

WORKDIR /home/yomiko

COPY --chown=yomiko:yomiko . .

USER yomiko

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost/health || exit 1

CMD [ "/home/yomiko/entrypoint.sh" ]
