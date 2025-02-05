FROM alpine:3.16.2

RUN apk --no-cache add \
    gettext \
    nginx \
    wireguard-tools \ 
    privoxy \
    curl \
    runit

COPY app /app

ENV LOCAL_NETWORK= \
    WG_CONFIG=/config/ \
    WG_HOST=localhost \
    WG_PROXY_PORT=8080 \
    WG_TUNNEL_HOSTS=

CMD ["runsvdir", "/app"]
