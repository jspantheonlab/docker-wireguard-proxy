#!/bin/sh

set -e

VPN_TYPE="${VPN_TYPE:-wireguard}"
WG_CONFIG="${WG_CONFIG:-/config/}"
WG_CONFIG="${WG_CONFIG%/}"
[ -n "${WG_CONFIG}" ] || WG_CONFIG="/"
export WG_CONFIG

rm -f /app/wireguard/down /app/openvpn/down

DEFAULT_LINE=$(ip route show default 2>/dev/null | head -1)
DEFAULT_DEV=$(echo "${DEFAULT_LINE}" | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
DEFAULT_GW=$(echo "${DEFAULT_LINE}" | awk '{for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}')
export DEFAULT_DEV DEFAULT_GW

case "${VPN_TYPE}" in
    wireguard)
        if ! ls "${WG_CONFIG}"/*.conf >/dev/null 2>&1; then
            echo "ERROR: VPN_TYPE=wireguard but no *.conf found in ${WG_CONFIG}" >&2
            exit 1
        fi
        touch /app/openvpn/down
        echo "VPN_TYPE=wireguard (openvpn disabled)"
        ;;
    openvpn)
        if ! ls "${WG_CONFIG}"/*.ovpn >/dev/null 2>&1; then
            echo "ERROR: VPN_TYPE=openvpn but no *.ovpn found in ${WG_CONFIG}" >&2
            exit 1
        fi
        OVPN_CFG=$(ls "${WG_CONFIG}"/*.ovpn 2>/dev/null | head -1)
        if grep -Eq '^[[:space:]]*auth-user-pass[[:space:]]*$' "${OVPN_CFG}" \
            && [ ! -f "${WG_CONFIG}/auth.txt" ]; then
            echo "ERROR: ${OVPN_CFG} uses 'auth-user-pass' but ${WG_CONFIG}/auth.txt is missing." >&2
            echo "Create ${WG_CONFIG}/auth.txt with the username on line 1 and the password on line 2." >&2
            exit 1
        fi
        touch /app/wireguard/down
        echo "VPN_TYPE=openvpn (wireguard disabled)"
        ;;
    *)
        echo "ERROR: VPN_TYPE must be 'wireguard' or 'openvpn', got '${VPN_TYPE}'" >&2
        exit 1
        ;;
esac

echo "Original default route: dev ${DEFAULT_DEV:-<none>} via ${DEFAULT_GW:-<none>}"

exec runsvdir /app
