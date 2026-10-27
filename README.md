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

"Office network" means three things are true: the machine's IP shares the first three octets with `WG_HOST`, this server's PAC is reachable and names the same proxy as at install time, and the proxy port answers. Checking the PAC rules out lookalike networks, such as a home router that also uses `192.168.50.x`. You can override this, and the other settings, with env vars: `OFFICE_NET`, `PROXY_HOST`, `PROXY_PORT`, `LISTEN`, `RELAY`, `GOST_VERSION`, `SYSTEM_PROXY`. The scripts live in `client/`; nginx fills in the PAC URL when serving them.

#### SSH

You can tunnel SSH configurations, but this won't use your auto-configuration script. Instead install `corkscrew` and edit your `~/.ssh/config`. If you use `brew` you can `brew install corkscrew`.

Example SSH config:

```c
Host *.corp.com
    ProxyCommand /usr/local/bin/corkscrew localhost 8080 %h %p
```

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
