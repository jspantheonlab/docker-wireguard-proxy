FROM alpine:3.21

RUN apk --no-cache add \
    curl \
    gettext \
    iptables \
    nginx \
    openvpn \
    privoxy \
    runit \
    wireguard-tools

COPY app /app
COPY client /client
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV LOCAL_NETWORK= \
    WG_CONFIG=/config/ \
    WG_HOST=localhost \
    WG_PROXY_PORT=8080 \
    WG_PROXY_PERMIT=0.0.0.0/0 \
    WG_TUNNEL_HOSTS= \
    VPN_TYPE=wireguard

CMD ["/entrypoint.sh"]
