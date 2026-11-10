#!/bin/sh

# Pushes proxy usage metrics over OTLP/HTTP (JSON), e.g. to Prometheus'
# OTLP receiver. Runs from app/stats/run after each aggregation.
#
# Metrics (names as Prometheus shows them):
#   proxy_requests_total{device, device_name, site, status_class}
#   proxy_transfer_bytes_total{device, device_name, site, status_class}
#   proxy_vpn_up{vpn_type}
#
# "site" is "other" for sites below OTEL_SITE_MIN_BYTES of traffic so far or
# beyond OTEL_MAX_SITES; see the main awk program.
#
# Counters are cumulative since STATE was created and survive restarts and
# log rotation: each run reads only the complete lines added to each log
# file since the last run (tracked by inode + line count), adds them to the
# running totals, and pushes the totals. A failed push loses nothing; the
# next one sends the larger totals. Nothing is backfilled: the first run
# starts counting from the end of the existing logs.

ENDPOINT="${OTEL_EXPORTER_OTLP_METRICS_ENDPOINT:-}"
if [ -z "${ENDPOINT}" ] && [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
    ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT%/}/v1/metrics"
fi
[ -n "${ENDPOINT}" ] || exit 0

umask 022

LOG_DIR="${STATS_LOG_DIR:-/logs}"
SRC="${LOG_DIR}/privoxy"
DIR="${LOG_DIR}/stats/otel"
STATE="${DIR}/state.tsv"
DEVICES="${STATS_DEVICES:-${WG_CONFIG:-/config}/devices.txt}"
MAX_SITES="${OTEL_MAX_SITES:-100}"
# A site gets its own series once it has moved this many bytes (default 10 MiB).
MIN_BYTES="${OTEL_SITE_MIN_BYTES:-10485760}"
INSTANCE="${OTEL_SERVICE_INSTANCE_ID:-${WG_HOST:-$(hostname)}}"

mkdir -p "${DIR}"
NOW_S=$(date +%s)
NOW_NS="${NOW_S}000000000"

# Log files oldest first: rotated (@<tai64n>.s/.u, named in time order), then current.
files() {
    for f in "${SRC}"/@* "${SRC}/current"; do
        [ -f "${f}" ] && echo "${f}"
    done
}

# Collect the complete lines added since the last run; list "F <inode> <lines>"
# for every log file so the next run knows where to resume.
NEW="${DIR}/new.log"
POS="${DIR}/pos.tsv"
: >"${NEW}"
: >"${POS}"
FIRST=0
[ -f "${STATE}" ] || FIRST=1
for f in $(files); do
    ino=$(stat -c %i "${f}")
    lines=$(( $(wc -l <"${f}") ))
    prev=0
    if [ "${FIRST}" = 1 ]; then
        prev=${lines}
    else
        p=$(awk -F '\t' -v i="${ino}" '$1 == "F" && $2 == i { print $3; exit }' "${STATE}")
        [ -n "${p}" ] && prev=${p}
        # A file that shrank was rewritten in place (e.g. a manual clean-up):
        # never re-count its lines.
        [ "${lines}" -lt "${prev}" ] && prev=${lines}
    fi
    if [ "${lines}" -gt "${prev}" ]; then
        tail -n "+$(( prev + 1 ))" "${f}" | head -n "$(( lines - prev ))" >>"${NEW}"
    fi
    printf 'F\t%s\t%s\n' "${ino}" "${lines}" >>"${POS}"
done

# Fold the new lines into the totals and write the next state in one step.
[ -f "${STATE}" ] || printf 'S\t%s\n' "${NOW_NS}" >"${STATE}"
awk -F '\t' -v max_sites="${MAX_SITES}" -v min_bytes="${MIN_BYTES}" -v max_pending=5000 -v pos="${POS}" -v statef="${STATE}" '
    function site(h,    n, p, last2) {
        if (h ~ /^\[/ || h ~ /^[0-9.]+$/) return h
        n = split(h, p, ".")
        if (n <= 2) return h
        last2 = p[n - 1] "." p[n]
        if (last2 ~ /^(co|com|net|org|gov|edu|ac)\.[a-z][a-z]$/) return p[n - 2] "." last2
        return last2
    }
    FILENAME == statef && $1 == "S" { start = $2; next }
    FILENAME == statef && $1 == "C" {
        k = $2 "\t" $3 "\t" $4
        req[k] = $5; byt[k] = $6
        if ($3 != "other" && !($3 in known)) { known[$3] = 1; nsites++ }
        next
    }
    FILENAME == statef && $1 == "P" { pend[$2] = $3; next }
    FILENAME == statef { next }
    {
        # CLF: ip - - [ts] "METHOD target HTTP/x" status bytes
        p = index($0, " - - [")
        if (!p) next
        n = split(substr($0, 1, p - 1), a, " ")
        ip = a[n]
        sub(/^::ffff:/, "", ip)
        rest = substr($0, p + 6)
        q = index(rest, "\"")
        if (!q) next
        rest = substr(rest, q + 1)
        q = index(rest, "\"")
        if (!q) next
        split(substr(rest, 1, q - 1), r, " ")
        split(substr(rest, q + 1), sb, " ")
        host = r[2]
        if (host == "") next
        sub(/^[A-Za-z]+:\/\//, "", host)
        sub(/\/.*/, "", host)
        if (substr(host, 1, 1) == "[") host = substr(host, 1, index(host, "]"))
        else sub(/:[0-9]+$/, "", host)
        b = sb[2] + 0
        s = site(tolower(host))
        # A site gets its own series once its traffic reaches min_bytes (and
        # a slot is free); until then it is counted as "other". Bytes already
        # in "other" stay there, so every counter only ever goes up.
        if (s != "other" && !(s in known)) {
            pend[s] += b
            if (pend[s] >= min_bytes && nsites < max_sites) {
                known[s] = 1; nsites++
                delete pend[s]
            } else s = "other"
        }
        st = sb[1] + 0
        cls = (st >= 100 && st < 600) ? int(st / 100) "xx" : "other"
        k = ip "\t" s "\t" cls
        if (!(k in req)) fresh[k] = 1
        req[k] += 1
        byt[k] += b
    }
    END {
        printf "S\t%s\n", start
        while ((getline line < pos) > 0) print line
        # Traffic so far of sites still counted as "other". Keep the list
        # bounded: past max_pending entries, forget the smallest ones.
        np = 0
        for (s in pend) np++
        floor = 0
        while (np > max_pending) {
            floor = floor ? floor * 4 : 1024
            np = 0
            for (s in pend) if (pend[s] >= floor) np++
        }
        for (s in pend) if (pend[s] >= floor) printf "P\t%s\t%.0f\n", s, pend[s]
        # Column 7 marks series first seen in this run (see "fresh" below).
        for (k in req) printf "C\t%s\t%d\t%.0f\t%d\n", k, req[k], byt[k], (k in fresh)
    }' "${STATE}" "${NEW}" >"${STATE}.tmp" && mv "${STATE}.tmp" "${STATE}"
rm -f "${NEW}" "${POS}"

# VPN up = a WireGuard/OpenVPN interface exists and is administratively up.
VPN_UP=0
ip -o link show 2>/dev/null | grep -Eq '^[0-9]+: (wg|tun|tap)[^:]*:.*[<,]UP[,>]' && VPN_UP=1

# Build the OTLP/JSON request.
BODY="${DIR}/request.json"
awk -F '\t' -v now="${NOW_NS}" -v before="$(( NOW_S - 1 ))000000000" -v vpn="${VPN_UP}" -v vpn_type="${VPN_TYPE:-wireguard}" \
    -v instance="${INSTANCE}" -v devices="${DEVICES}" '
    function js(s) {
        gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s)
        return "\"" s "\""
    }
    function attr(k, v) { return "{\"key\":" js(k) ",\"value\":{\"stringValue\":" js(v) "}}" }
    function points(which,    k, x, out, sep, name, v, a) {
        out = ""; sep = ""
        for (k in req) {
            split(k, x, "\t")
            name = (x[1] in names) ? names[x[1]] : x[1]
            v = (which == "req") ? req[k] : byt[k]
            a = "{\"attributes\":[" attr("device", x[1]) "," attr("device.name", name) "," \
                attr("site", x[2]) "," attr("status_class", x[3]) "]," \
                "\"startTimeUnixNano\":\"" start "\",\"timeUnixNano\":\""
            # A new series also gets a 0 one second earlier, so PromQL
            # increase()/rate() count its first requests instead of
            # treating them as the starting value.
            if (fresh[k]) { out = out sep a before "\",\"asInt\":\"0\"}"; sep = "," }
            out = out sep a now "\",\"asInt\":\"" v "\"}"
            sep = ","
        }
        return out
    }
    BEGIN {
        while ((getline line < devices) > 0) {
            if (line ~ /^[ \t]*(#|$)/) continue
            n = split(line, f, /[ \t]+/)
            if (f[1] == "") { ip = f[2]; i0 = 3 } else { ip = f[1]; i0 = 2 }
            nm = ""
            for (i = i0; i <= n; i++) if (f[i] != "") nm = nm (nm == "" ? "" : " ") f[i]
            if (nm != "") names[ip] = nm
        }
    }
    $1 == "S" { start = $2 }
    $1 == "C" { k = $2 "\t" $3 "\t" $4; req[k] = $5; byt[k] = $6; fresh[k] = ($7 == 1) }
    END {
        printf "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[%s,%s]},", \
            attr("service.name", "wireguard-proxy"), attr("service.instance.id", instance)
        printf "\"scopeMetrics\":[{\"scope\":{\"name\":\"wireguard-proxy\"},\"metrics\":["
        printf "{\"name\":\"proxy.requests\",\"unit\":\"{request}\",\"description\":\"Requests through the proxy\","
        printf "\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[%s]}},", points("req")
        printf "{\"name\":\"proxy.transfer\",\"unit\":\"By\",\"description\":\"Bytes through the proxy (approximate for HTTPS tunnels)\","
        printf "\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[%s]}},", points("bytes")
        printf "{\"name\":\"proxy.vpn.up\",\"description\":\"1 if the VPN interface is up\","
        printf "\"gauge\":{\"dataPoints\":[{\"attributes\":[%s],\"timeUnixNano\":\"%s\",\"asInt\":\"%d\"}]}}", \
            attr("vpn_type", vpn_type), now, vpn
        printf "]}]}]}\n"
    }' "${STATE}" >"${BODY}"

# Optional auth headers: OTEL_EXPORTER_OTLP_HEADERS="k1=v1,k2=v2"
set -- -s -m 10 -o "${DIR}/response.txt" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary "@${BODY}"
OLDIFS=$IFS
IFS=','
for h in ${OTEL_EXPORTER_OTLP_METRICS_HEADERS:-${OTEL_EXPORTER_OTLP_HEADERS:-}}; do
    [ -n "${h}" ] && set -- "$@" -H "${h%%=*}: ${h#*=}"
done
IFS=$OLDIFS

# --noproxy: never send the push itself through a proxy or the VPN.
code=$(curl --noproxy '*' "$@" "${ENDPOINT}")
case "${code}" in
    2??) : ;;
    *) echo "otel: push to ${ENDPOINT} failed (HTTP ${code}): $(head -c 300 "${DIR}/response.txt" 2>/dev/null)" ;;
esac
