FROM alpine:3.21

RUN apk --no-cache add \
    curl \
    gettext \
    nginx \
    privoxy \
    runit \
    wireguard-tools

COPY app /app

ENV LOCAL_NETWORK= \
    WG_CONFIG=/config/ \
    WG_HOST=localhost \
    WG_PROXY_PORT=8080 \
    WG_TUNNEL_HOSTS=

CMD ["runsvdir", "/app"]
