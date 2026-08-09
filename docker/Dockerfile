ARG ALPINE_TAG=3.23.2
ARG YOMIKO_BUILD_VERSION=dev

FROM alpine:${ALPINE_TAG} AS base

RUN apk add --no-cache \
    7zip \
    bash \
    busybox-extras \
    curl \
    fd \
    imagemagick \
    imagemagick-jpeg \
    imagemagick-webp \
    jq \
    python3 \
    ripgrep \
    sqlite \
 && addgroup -g 1000 yomiko \
 && adduser -u 1000 -G yomiko -h /home/yomiko -s /bin/bash -D yomiko \
 && chown -R yomiko:yomiko /home/yomiko

WORKDIR /home/yomiko

ENV PATH="/home/yomiko/bin:${PATH}"

FROM base AS test

COPY --chown=yomiko:yomiko . .

USER yomiko

CMD [ "/home/yomiko/tests/run.sh" ]

FROM base AS runtime-base

ARG YOMIKO_BUILD_VERSION

ENV YOMIKO_BUILD_VERSION="${YOMIKO_BUILD_VERSION}"

COPY --chown=yomiko:yomiko entrypoint.sh ./
COPY --chown=yomiko:yomiko bin/ ./bin/
COPY --chown=yomiko:yomiko cronjobs/ ./cronjobs/
COPY --chown=yomiko:yomiko lib/ ./lib/
COPY --chown=yomiko:yomiko migrations/ ./migrations/
COPY --chown=yomiko:yomiko server/ ./server/
COPY --chown=yomiko:yomiko web/ ./web/

USER yomiko

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD if [ "${YOMIKO_ENABLE_WEB:-true}" = "false" ]; then \
        test -f /home/yomiko/data/db.sqlite3; \
      else \
        curl -f http://localhost/health; \
      fi

CMD [ "/home/yomiko/entrypoint.sh" ]

FROM runtime-base AS debug

ENV YOMIKO_USERSCRIPT_NAME="Yomiko (Debug)"

COPY --chown=yomiko:yomiko debug/web/ ./web/

FROM runtime-base AS runtime

ENV YOMIKO_USERSCRIPT_NAME="Yomiko"

# Debug-only CGI endpoints must never be present in the production filesystem.
RUN test ! -e /home/yomiko/web/api/echo_inspector.sh
