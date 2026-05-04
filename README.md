# Amnezia WARP Host Routing

Host-level Cloudflare WARP egress routing for Amnezia Docker containers.

## What It Does

This script solves a specific server-side problem:

- `amnezia-awg`, `amnezia-awg2`, or `amnezia-xray` keeps accepting inbound VPN traffic on the VPS public IP
- selected outgoing traffic from the container is policy-routed through a host WARP interface
- external services see a Cloudflare IP instead of the VPS IP
- the host default route stays unchanged

This is useful when you want VPN clients to keep using the server as an entrypoint, but make their internet-bound egress leave through WARP.

## How It Works

Under the hood the script does four things:

1. Detects the Amnezia container IP, host WAN interface, Amnezia bridge, and Docker bridges.
2. Ensures a host-level WARP interface exists.
If one already exists, for example `wg0` from `x-ui` or `3x-ui`, it reuses it.
If one does not exist, it can bootstrap `wgcf` and create `/etc/wireguard/wgcf.conf` with `Table = off`.
3. Installs a small routing helper and `systemd` services.
4. Applies policy routing plus `iptables` mangle rules so only marked Amnezia container egress goes through WARP.

The script does not replace the VPS default route and does not attempt to hide inbound listeners behind Cloudflare.

## File

- `deploy_amnezia_warp_host.sh`
  - interactive installer for:
  - `amnezia-awg` (legacy)
  - `amnezia-awg2` (v2)
  - `amnezia-xray` (xray)
  - can install WARP if missing
  - can uninstall and return the host to the pre-routing state
  - shows network status, container IPs, routing state, and debug info in the menu

## Requirements

Target host requirements:

- Linux host with `systemd`
- Docker installed and running
- one of these containers present:
- `amnezia-awg`
- `amnezia-awg2`
- `amnezia-xray`
- root access
- `iptables` available
- `python3` available

For automatic WARP bootstrap through `wgcf`:

- Ubuntu/Debian, RHEL-family, or another distro with a supported package manager in the script
- outbound access to GitHub and Cloudflare

## Easy Install

Run directly from GitHub with `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh | sudo bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh | sudo bash
```

If you prefer to inspect the script before running it:

```bash
curl -fsSLO https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

## Recommended Usage

Run on the VPS:

```bash
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

Typical menu:

```text
Amnezia WARP Host Routing

Environment
  WAN interface: eth0
  WAN IP: 203.0.113.10
  WAN subnet: 203.0.113.0/24
  WARP interface: not found
  Amnezia bridge: auto

Containers
  AmneziaWG Legacy: found
    container IP: 172.29.172.2
    routing service: not installed
  AmneziaWG v2: found
    container IP: 172.29.172.5
    routing service: active
  Amnezia Xray: found
    container IP: 172.29.172.3
    routing service: not installed
  Host WARP: not found

1) Install WARP and route all detected containers
2) Install or refresh routing for AWG Legacy only
3) Install or refresh routing for AWG v2 only
4) Install or refresh routing for Amnezia Xray only
5) Remove everything configured by this script
6) Show status
7) Exit
```

Non-interactive install for everything found:

```bash
sudo AUTO_YES=1 ./deploy_amnezia_warp_host.sh
```

Status:

```bash
sudo ./deploy_amnezia_warp_host.sh status
```

Uninstall:

```bash
sudo ./deploy_amnezia_warp_host.sh uninstall
```

Non-interactive uninstall:

```bash
sudo AUTO_YES=1 ./deploy_amnezia_warp_host.sh uninstall
```

## Optional Overrides

The script accepts environment overrides for unusual network layouts.

Most useful ones:

```bash
WARP_IF=wg0
WAN_IF=eth0
WARP_PROFILE_NAME=wgcf
AUTO_YES=1
```

Example:

```bash
sudo WARP_IF=wg0 WAN_IF=ens34 ./deploy_amnezia_warp_host.sh
```

## What Gets Installed

The installer writes:

- `/usr/local/sbin/amnezia-warp-routing.sh`
- `/etc/systemd/system/amnezia-warp-routing@.service`
- `/etc/amnezia-warp/*.env`
- `/etc/sysctl.d/99-amnezia-warp.conf`

If WARP is bootstrapped by the script, it also writes:

- `/etc/wireguard/wgcf.conf`
- `/etc/wireguard/wgcf-account.toml`
- `/usr/local/bin/wgcf`

## Verification

After install, connect through the VPN and open any IP / ISP lookup site:

- [myip.com](https://www.myip.com/)
- [2ip.io](https://2ip.io/)
- [WhatIsMyIPAddress](https://whatismyipaddress.com/)
- [WhatIsMyISP](https://www.whatismyisp.com/)
- [DNSChecker: What's My IP Address](https://dnschecker.org/whats-my-ip-address.php)

You should see a Cloudflare-owned IP instead of the VPS IP.

## Notes

- This routes outgoing traffic only.
- It does not hide inbound VPS ports behind Cloudflare.
- It is designed around common Amnezia Docker layouts with `amn0` and `172.29.x.x`, but tries to autodetect when possible.
- If the host already uses a WARP interface from another tool, the installer reuses it rather than replacing it.

## Support

This project is shared as-is.

Issues and pull requests are welcome, but maintenance happens on a best-effort basis. Reviews may be delayed because this is not my full-time work.
