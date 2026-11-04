#!/bin/sh

# Turns privoxy's per-request log lines (Common Log Format, kept by
# app/privoxy/log) into small TSV files that the /stats dashboard reads:
#
#   usage.tsv    day, device ip, host -> requests, bytes, failed, last seen
#   hourly.tsv   day, hour, device ip, host -> requests (last STATS_HOURLY_DAYS)
#   devices.tsv  device ip -> name (from STATS_DEVICES, optional)
#   meta.tsv     generated time, log timezone, retention
#
# Rotated log files never change, so each is parsed once and cached; only
# the live "current" file is re-read on every run.

umask 022

LOG_DIR="${STATS_LOG_DIR:-/logs}"
SRC="${LOG_DIR}/privoxy"
CACHE="${LOG_DIR}/stats/cache"
OUT="${LOG_DIR}/stats/data"
DAYS="${STATS_DAYS:-90}"
HOURLY_DAYS="${STATS_HOURLY_DAYS:-7}"
DEVICES="${STATS_DEVICES:-${WG_CONFIG:-/config}/devices.txt}"

mkdir -p "${CACHE}" "${OUT}"

# One CLF line looks like:
#   192.168.50.23 - - [04/Nov/2026:06:33:02 +0800] "CONNECT chatgpt.com:443 HTTP/1.1" 200 5375
parse() {
    awk '
    BEGIN {
        n = split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
        for (i = 1; i <= n; i++) mon[m[i]] = sprintf("%02d", i)
    }
    {
        p = index($0, " - - [")
        if (!p) next
        n = split(substr($0, 1, p - 1), a, " ")
        ip = a[n]
        sub(/^::ffff:/, "", ip)

        rest = substr($0, p + 6)
        e = index(rest, "]")
        ts = substr(rest, 1, e - 1)                 # 04/Nov/2026:06:33:02 +0800
        rest = substr(rest, e + 1)
        q = index(rest, "\"")
        if (!q) next
        rest = substr(rest, q + 1)
        q = index(rest, "\"")
        if (!q) next
        req = substr(rest, 1, q - 1)
        split(substr(rest, q + 1), sb, " ")
        status = sb[1] + 0
        bytes = sb[2] + 0

        split(req, r, " ")
        host = r[2]
        if (host == "" || !(substr(ts, 4, 3) in mon)) next
        sub(/^[A-Za-z]+:\/\//, "", host)
        sub(/\/.*/, "", host)
        if (substr(host, 1, 1) == "[") host = substr(host, 1, index(host, "]"))
        else sub(/:[0-9]+$/, "", host)
        host = tolower(host)

        day = substr(ts, 8, 4) "-" mon[substr(ts, 4, 3)] "-" substr(ts, 1, 2)
        t = day " " substr(ts, 13, 8)
        if (tz == "") tz = substr(ts, 22, 5)

        k = day SUBSEP ip SUBSEP host
        cnt[k]++
        byt[k] += bytes
        if (status >= 400) bad[k]++
        if (t > last[k]) last[k] = t
        hr[day SUBSEP substr(ts, 13, 2) SUBSEP ip SUBSEP host]++
    }
    END {
        for (k in cnt) {
            split(k, x, SUBSEP)
            printf "D\t%s\t%s\t%s\t%d\t%.0f\t%d\t%s\n", x[1], x[2], x[3], cnt[k], byt[k], bad[k], last[k]
        }
        for (k in hr) {
            split(k, x, SUBSEP)
            printf "H\t%s\t%s\t%s\t%s\t%d\n", x[1], x[2], x[3], x[4], hr[k]
        }
        if (tz != "") printf "Z\t%s\n", tz
    }' "$@"
}

for f in "${SRC}"/@*; do
    [ -f "${f}" ] || continue
    c="${CACHE}/${f##*/}.tsv"
    if [ ! -f "${c}" ]; then
        parse "${f}" >"${c}.tmp" && mv "${c}.tmp" "${c}"
    fi
done
# svlogd deletes the oldest rotated files; drop their caches too.
for c in "${CACHE}"/@*.tsv; do
    [ -f "${c}" ] || continue
    b="${c##*/}"
    [ -f "${SRC}/${b%.tsv}" ] || rm -f "${c}"
done

if [ -f "${SRC}/current" ]; then
    parse "${SRC}/current" >"${CACHE}/current.part"
else
    : >"${CACHE}/current.part"
fi

set -- "${CACHE}/current.part"
for c in "${CACHE}"/@*.tsv; do
    [ -f "${c}" ] && set -- "${c}" "$@"
done

NOW=$(date +%s)
CUTOFF=$(date -d "@$(( NOW - DAYS * 86400 ))" +%Y-%m-%d)
HCUTOFF=$(date -d "@$(( NOW - HOURLY_DAYS * 86400 ))" +%Y-%m-%d)

awk -F '\t' -v cutoff="${CUTOFF}" -v hcutoff="${HCUTOFF}" -v out="${OUT}" '
    $1 == "Z" { tz = $2; next }
    $2 < cutoff { next }
    $1 == "D" {
        k = $2 "\t" $3 "\t" $4
        cnt[k] += $5; byt[k] += $6; bad[k] += $7
        if ($8 > last[k]) last[k] = $8
        next
    }
    $1 == "H" && $2 >= hcutoff { hr[$2 "\t" $3 "\t" $4 "\t" $5] += $6 }
    END {
        f = out "/usage.tsv.tmp"
        print "day\tip\thost\trequests\tbytes\tfailed\tlast_seen" >f
        for (k in cnt) printf "%s\t%d\t%.0f\t%d\t%s\n", k, cnt[k], byt[k], bad[k], last[k] >f
        close(f)
        f = out "/hourly.tsv.tmp"
        print "day\thour\tip\thost\trequests" >f
        for (k in hr) printf "%s\t%d\n", k, hr[k] >f
        close(f)
        print tz >(out "/tz.tmp")
    }' "$@"

{
    printf 'ip\tname\n'
    if [ -f "${DEVICES}" ]; then
        # "<ip> <name...>" per line; blank lines and # comments ignored.
        awk '!/^[[:space:]]*(#|$)/ { ip = $1; $1 = ""; sub(/^ +/, ""); if ($0 != "") print ip "\t" $0 }' "${DEVICES}"
    fi
} >"${OUT}/devices.tsv.tmp"

TZ_OFFSET=$(cat "${OUT}/tz.tmp" 2>/dev/null)
[ -n "${TZ_OFFSET}" ] || TZ_OFFSET=$(date +%z)
printf 'key\tvalue\ngenerated\t%s\ntz\t%s\ndays\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${TZ_OFFSET}" "${DAYS}" >"${OUT}/meta.tsv.tmp"
rm -f "${OUT}/tz.tmp"

for n in usage hourly devices meta; do
    [ -f "${OUT}/${n}.tsv.tmp" ] && mv "${OUT}/${n}.tsv.tmp" "${OUT}/${n}.tsv"
done
