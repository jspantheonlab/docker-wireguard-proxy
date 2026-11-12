# Wireguard Proxy

An HTTP proxy server which (selectively) tunnels traffic over an Wireguard connection.

## Why?

If your company has a vast array of servers on different IP ranges (e.g. cloud servers/services) then it can be impractical to maintain a list of routes that Wireguard should push to clients - it's much easier just to tunnel all the traffic.
But then things that need low latency suffer - video calls etc. Besides you might not want _all_ your traffic going through the company...

Another use case is for VPN services that let you appear in a different country. You may only want some websites' traffic to appear in this country.

## Usage

The easiest way to get started is with `docker-compose` - see `docker-compose.yml` for an example.
You can also just use `docker run` or any other way to run a docker container.
Note that special capabilities are required, specifically `NET_ADMIN` .

## Tags

It's best to use `latest` if you can.
Or you can use a specific version tag - tags are based on the Wireguard version.

### Mounts

Pass mounts for `docker-compose` in `volumes` or to `docker run` with `-v "<host_path>:<container_path>"`

| What | Host path | Container path |
|---|---|---|
| VPN config file(s) | Path to your config file | `/config/` (or the value of `WG_CONFIG`) |
| Request logs and stats (optional, keeps history across restarts) | e.g. `./logs/` | `/logs/` |

The config folder holds either a WireGuard `*.conf` or an OpenVPN `*.ovpn` (plus any `ca.crt`/`ta.key` it references). Pick which one is used with `VPN_TYPE`.

### Choosing a VPN

Set `VPN_TYPE` to `wireguard` (default) or `openvpn`. Only the selected service is started; the other one is disabled.

```yaml
environment:
  - VPN_TYPE=openvpn
```

For `wireguard`, put `wg0.conf` style files in the config folder. For `openvpn`, put `client.ovpn` there - `--cd` is set to that folder, so relative `ca`/`cert`/`key`/`tls-auth` paths inside the file resolve correctly. OpenVPN always runs with `--redirect-gateway def1` so all container traffic uses the tunnel (the PAC/proxy still does the per-host split).

If the `.ovpn` contains a bare `auth-user-pass` line (username/password login), put the credentials in `<config_folder>/auth.txt` - username on the first line, password on the second. The container exits with an error if that file is missing, rather than hanging on an interactive prompt.

### Environment Variables

Pass values for `docker-compose` in `environment` or to `docker run` with `-e "<VAR_NAME>:<value>"`

| Variable | Required? | Default | Example | Description |
|---|---|---|---|---|
| `LOCAL_NETWORK` | Yes | _none_ | `10.0.8.0/24` | Your local network's address. Required so return packets can reach you. |
| `WG_CONFIG` | Yes | `/config/` | `/my/wireguard/config/` | Path to config folder inside container |
| `WG_TUNNEL_HOSTS` | No | _none_ | `*.corp.com,*.corp.io` | Patterns of which hosts to tunnel, comma separated. Unset means nothing is tunneled (everything goes direct). See [Split Tunneling](#split-tunneling) |
| `WG_HOST` | No | `localhost` | `10.0.8.1` | Set this if this container runs on a different host to where you'll use it. |
| `WG_PROXY_PORT` | No | `8080` | `1234` | Change proxy listening port. This must match the host port so that the auto-config file is correct. |
| `VPN_TYPE` | No | `wireguard` | `openvpn` | Which VPN to connect with. See [Choosing a VPN](#choosing-a-vpn). |
| `TZ` | No | `UTC` | `Asia/Shanghai` | Timezone for log times, so the dashboard's days and hours match yours. |
| `STATS_PASSWORD` | No | _none_ | `change-me` | Password for the [usage dashboard](#usage-dashboard). User is `STATS_USER` (default `admin`). |
| `STATS_ALLOW` | No | _none_ | `192.168.50.10,10.0.0.0/8` | Only these IPs/CIDRs may open the dashboard. |
| `STATS_DAYS` | No | `90` | `30` | How many days of history the dashboard keeps. |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | No | _none_ | `http://192.168.50.200:9090/api/v1/otlp/v1/metrics` | Push usage metrics over OTLP/HTTP to this URL. See [Metrics](#metrics-prometheus--grafana). |

### Ports

Pass ports for `docker-compose` in `ports` or to `docker run` with `-p <host_port>:<container_port>`.

| Container Port | Description |
|---|---|
| 80 | Serves the proxy auto-configuration script. See [Split Tunneling](#split-tunneling). |
| 8080 | Exposes HTTP proxy |

### Configure your apps

For apps that support it, use the auto-configuration script. Usually this is called "Automatic proxy configuration" - for example macOS calls it "Automatic Proxy Configuration", Firefox calls it "Automatic proxy configuration URL". Set the value to your container's proxy auto-configuration port, e.g. `http://localhost:8081` or whatever you mapped the container's port 80 to.

For apps that don't support auto-configuration scripts you can set the HTTP proxy directly (e.g. to `localhost:8080`) but be aware that you lose the split-tunneling so everything will go over the proxy.

#### Apps without PAC support (client installer)

For CLI tools and apps that can't use a PAC, the server also hands out an installer for a small local split proxy ([gost](https://github.com/go-gost/gost)). It listens on `127.0.0.1:1080` (HTTP and SOCKS5) and is always running, so apps can keep it as their proxy permanently. On the office network, hosts from the PAC go through this proxy and everything else connects directly. Elsewhere, everything connects directly and this proxy is never contacted. The host list re-syncs from the PAC automatically. Run on the office network, replacing `<server>:<port>` with where the PAC is served (e.g. `192.168.50.200:44081`):

| OS | Install / update | Uninstall |
|---|---|---|
| macOS / Linux | `curl -fsSL http://<server>:<port>/install.sh \| bash` | `curl -fsSL http://<server>:<port>/install.sh \| bash -s uninstall` |
| Windows (PowerShell) | `& ([scriptblock]::Create((irm http://<server>:<port>/install.ps1)))` | same, followed by ` -Uninstall` |

The installer also points the system proxy settings at gost, so browsers and most apps are split without further setup. On macOS this asks for your password once. Elsewhere no admin rights are needed. For apps that ignore the system proxy, use `http://127.0.0.1:1080` or `socks5h://127.0.0.1:1080`. Use `socks5h`, so hostnames reach the proxy.

- **macOS**: a launchd agent reacts to network changes (and re-checks every 5 minutes) and switches modes. It also switches to an "office local" network location if one exists.
- **macOS with endpoint security (e.g. ESET)**: ESET's network extension blocks *unsigned* processes that launchd starts — gost included — from dialing LAN addresses (`connect: no route to host`), while allowing Apple-signed binaries. So the office hop runs through a small loopback relay (`127.0.0.1:18080` → the office proxy) that is executed by Apple's signed `/usr/bin/python3` under its own launchd agent, and gost dials the relay instead of the office proxy directly. This needs the Command Line Tools python3 (`xcode-select --install`); if it's missing, the installer logs a warning and gost dials the office proxy directly. The long-term alternative is an exclusion for the gost binary in the endpoint security product, after which the relay is unnecessary. Without it, symptoms are PAC-hosted sites (e.g. `chatgpt.com`, `claude.ai`) failing with `000`/"Failed to fetch" while non-PAC sites keep working — see `gost.log` for the `no route to host` errors.
- **Linux**: a systemd user service checks every 15s and switches modes. On headless machines, run `sudo loginctl enable-linger $USER` first.
- **Windows**: a logon task (or a Startup-folder shortcut) checks every 15s, switches modes, and keeps gost running.
- System proxy: on macOS, HTTP and HTTPS proxy on every network service in every network location. On Linux, GNOME's proxy settings, if available; otherwise set your browser's proxy manually. On Windows, the per-user internet settings used by Edge and Chrome. Local and private addresses are left direct. Uninstall turns the proxy off wherever it still points at gost. Set `SYSTEM_PROXY=0` to skip this.
- If `~/.claude/settings.json` exists, Claude Code's proxy env is set on the office network and removed elsewhere. This needs `jq` on macOS/Linux.

"Office network" means three things are true: the machine's IP shares the first three octets with `WG_HOST`, this server's PAC is reachable and names the same proxy as at install time, and the proxy port answers. Checking the PAC rules out lookalike networks, such as a home router that also uses `192.168.50.x`. If the check fails while the machine is still behind the same router (by MAC) as the last good check, or the router doesn't answer at all (a USB Ethernet adapter just after waking from sleep can take minutes to pass traffic), the mode is left alone instead of flipping to direct and back. On macOS, checks are skipped during Power Nap wakes. You can override this, and the other settings, with env vars: `OFFICE_NET`, `PROXY_HOST`, `PROXY_PORT`, `LISTEN`, `RELAY`, `GOST_VERSION`, `SYSTEM_PROXY`. The scripts live in `client/`; nginx fills in the PAC URL when serving them.

#### SSH

You can tunnel SSH configurations, but this won't use your auto-configuration script. Instead install `corkscrew` and edit your `~/.ssh/config`. If you use `brew` you can `brew install corkscrew`.

Example SSH config:

```c
Host *.corp.com
    ProxyCommand /usr/local/bin/corkscrew localhost 8080 %h %p
```

## Usage dashboard

The proxy logs one line per request (device IP, domain, status, bytes) and turns them into a dashboard at `http://<server>:<port>/stats/`. That is the same port as the PAC, e.g. `http://192.168.50.200:44081/stats/`. It shows:

- requests, active devices, domains, failed requests and data volume;
- requests per day, or per hour for today;
- top devices and top domains (click one to filter everything by it);
- a device × domain heatmap;
- sortable device and domain tables.

Filter by time range (today, 7, 30 or 90 days), device and domain. Domains can be shown per hostname or grouped by site (`api.openai.com` → `openai.com`). The data refreshes every minute.

- **Device names**: devices are shown by IP unless you add `devices.txt` to the config folder, one `<ip> <name>` per line (`#` comments allowed). Changes show up within a minute; no restart needed. Give devices fixed DHCP leases so their IPs stay put.
- **Real device IPs**: the proxy must see each device's own address. That works on a Linux Docker host with published ports. Docker Desktop (macOS/Windows) rewrites the source to its gateway, so all traffic looks like one device; the dashboard warns when this happens. On a Synology NAS, see [below](#synology-nas).
- **What is logged**: for HTTPS only the hostname is visible, never the URL or content. Only traffic sent to the proxy is logged, which with the PAC is just the `WG_TUNNEL_HOSTS` domains. Devices that use the proxy directly (no PAC) send it everything, so all their browsing appears.
- **Access**: the dashboard shows who uses what, so set `STATS_PASSWORD` and/or `STATS_ALLOW`. Without either it is open to anyone who can reach the port, and the container prints a warning.
- **Storage**: logs are in `/logs/privoxy` (rotated at `STATS_LOG_SIZE` bytes, default 10 MB, keeping `STATS_LOG_FILES` files, default 100). Dashboard data is in `/logs/stats`. Mount `/logs` to keep history across container restarts. "Data" for HTTPS is the bytes passed through the tunnel and is approximate.

### Synology NAS

On Synology (Container Manager), every device shows up as the container network's gateway (e.g. `192.168.144.1`). DSM renames the built-in NAT chains, so Docker's port-forwarding rule is never reached and `docker-proxy` relays every connection instead, hiding the client's address. You can confirm it: `sudo iptables -t nat -L DOCKER -n -v | grep dpt:8080` shows 0 packets, and `sudo netstat -tlnp | grep :8080` shows `docker-proxy`.

Fix it by sending the proxy port to Docker's rules yourself (replace `192.168.50.200` with the NAS's IP):

```sh
sudo iptables -t nat -I DEFAULT_PREROUTING 1 -d 192.168.50.200/32 -p tcp --dport 8080 -j DOCKER
```

New connections then show their real IP. Connections already open keep the gateway address until they close. DSM resets the rule on reboot and firewall changes, so reapply it from **Control Panel → Task Scheduler**: a user-defined script run as `root`, triggered at boot-up and also scheduled every 5 minutes. The script only adds the rule when it's missing:

```sh
R="-d 192.168.50.200/32 -p tcp --dport 8080 -j DOCKER"
iptables -t nat -C DEFAULT_PREROUTING $R 2>/dev/null || iptables -t nat -I DEFAULT_PREROUTING 1 $R
```

To undo it, run the same command with `-D` instead of `-I 1`. Setting `"userland-proxy": false` in Container Manager's `dockerd.json` does not help on DSM.

## Metrics (Prometheus / Grafana)

The proxy can also push its usage counts as OpenTelemetry metrics (OTLP/HTTP, JSON) every minute, for example to Prometheus' OTLP receiver. It's push-based, so Prometheus needs no scrape config, only `--web.enable-otlp-receiver`:

```yaml
environment:
  - OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://192.168.50.200:9090/api/v1/otlp/v1/metrics
```

`OTEL_EXPORTER_OTLP_ENDPOINT` also works (`/v1/metrics` is appended), and `OTEL_EXPORTER_OTLP_HEADERS=key=value,...` adds headers such as `Authorization=Bearer …`. Push failures are logged to the container log as `otel: push … failed`.

| Metric (as shown in Prometheus) | Labels | Meaning |
|---|---|---|
| `proxy_requests_total` | `device`, `device_name`, `site`, `status_class` | Requests through the proxy |
| `proxy_transfer_bytes_total` | same | Bytes through the proxy (approximate for HTTPS) |
| `proxy_vpn_up` | `vpn_type` | 1 if the WireGuard/OpenVPN interface is up |

All series carry `job="wireguard-proxy"`, and `instance` comes from `WG_HOST`.

- `device` is the IP. `device_name` comes from `devices.txt`, and falls back to the IP. Renaming a device starts a new series.
- `site` groups subdomains (`api.openai.com` → `openai.com`). To keep the number of series bounded, a site only gets its own series once it has moved `OTEL_SITE_MIN_BYTES` bytes (default 10485760, 10 MiB), and at most `OTEL_MAX_SITES` sites get one (default 100). Until then its traffic is counted as `other`, and stays there afterwards, so `other` shrinks over time rather than disappearing.
- `status_class` is `2xx`/`3xx`/`4xx`/`5xx`. A 4xx or 5xx comes from the proxy itself, e.g. when the site is unreachable.

The counters are cumulative and survive restarts and log rotation; their state is kept in `/logs/stats/otel`. Counting starts when export is first enabled, with no backfill. A long-lived HTTPS connection is counted when it closes, because that's when Privoxy logs it.

**Grafana dashboard:** import [`grafana/proxy-usage.json`](grafana/proxy-usage.json) (Dashboards → New → Import) and pick your Prometheus data source. It shows:

- requests, active devices, sites, failure rate, data volume and VPN status;
- requests over time by device and by site;
- failure rate, data per device and a VPN status timeline;
- top devices and top sites by requests;
- data usage by device and by site;
- a device × site table.

Filter by device and site. Note that per-device data in Prometheus is visible to anyone who can query it; `STATS_PASSWORD` only protects `/stats`.

## Split Tunneling

An HTTP proxy server operates at the application layer and not on IP addresses so proxy configuration can be used to send traffic based on hostname patterns instead of IP address ranges.

The way this works is with a [Proxy auto-configuration script](https://developer.mozilla.org/en-US/docs/Web/HTTP/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_(PAC)_file). The built-in script will split traffic based on the value of the `WG_TUNNEL_HOSTS` variable. The patterns used are [glob](https://en.wikipedia.org/wiki/Glob_(programming)) however you should stick with just `*` and `?` for maximum compatibility. A pattern of `*.example.com` also matches the apex domain `example.com`, so one entry is enough to cover both.

When your browser or other application wants to make a request to a given host, it will first check this script to decide whether to send the request through the proxy. Most apps/operating systems support this, see [Configure your apps](#configure-your-apps).

If you would like a completely custom configuration with more esoteric switching rules you can create your own auto-configuration script and mount this to `/app/nginx/proxy.pac`. Environment variables will be interpolated at runtime (e.g. anything like `${WG_HOST}`).

## Acknowledgements

This project started as a fork of <https://github.com/andyn922/docker-openvpn-proxy> and <https://github.com/jonohill/docker-openvpn-proxy> . Thanks andyn922 and jonohill!

Here are the differences from the original:

- Generic, not focussed on PIA.
- Split tunneling (i.e. proxy auto-configuration script).
- Username/password auto-configuration.
- New configuration
- New docs
- Automatic builds

And other minor changes.
