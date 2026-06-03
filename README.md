# Amnezia WARP Host Routing

[English](https://github.com/isultanov99/amnezia-warp-host-routing/blob/master/README.md) | [Russian](https://github.com/isultanov99/amnezia-warp-host-routing/blob/master/README_ru.md)

## About

Host-level Cloudflare WARP egress routing for Amnezia Docker containers.

The installer creates timestamped pre-change backups and can roll back to a chosen snapshot from the menu.

This script solves a specific server-side problem:

- `amnezia-awg`, `amnezia-awg2`, or `amnezia-xray` keeps accepting inbound VPN traffic on the VPS public IP
- selected outgoing traffic from the container is policy-routed through a host WARP interface
- external services see a Cloudflare IP instead of the VPS IP
- the host default route stays unchanged

This is useful when you want VPN clients to keep using the server as an entrypoint, but make their internet-bound egress leave through WARP.

## TL;DR

If you do not care about the implementation details:

1. Run the script on the VPS where your `amnezia-awg`, `amnezia-awg2`, or `amnezia-xray` container lives.
2. It keeps inbound VPN access on the VPS IP.
3. It routes outgoing internet traffic from the selected container through Cloudflare WARP.
4. After setup, the script itself shows whether WARP is up and what egress IP the container is using.
5. If you already use another Cloudflare WARP-based setup, for example an existing `warp` or `wg0` interface from another tool or panel, the script can reuse it instead of creating a second one.

## How It Works

Under the hood the script does four things:

1. Detects the Amnezia container IP, host WAN interface, Amnezia bridge, and Docker bridges.
2. Ensures a host-level WARP interface exists.
If one already exists, for example an existing `warp` or `wg0` interface from another Cloudflare WARP-based tool or panel, it reuses it.
If one does not exist, it can bootstrap `wgcf` and create `/etc/wireguard/wgcf.conf` with `Table = off`.
3. Installs system-level helper scripts and `systemd` units.
4. Applies policy routing plus `iptables` mangle rules so only marked Amnezia container egress goes through WARP.

The script does not replace the VPS default route and does not attempt to hide inbound listeners behind Cloudflare.

During setup, the script writes files under `/etc` and `/usr/local/sbin`, creates `systemd` units, enables a timer, and applies live routing/firewall rules.

## File

- `deploy_amnezia_warp_host.sh`
  - interactive installer for:
  - `amnezia-awg` (legacy)
  - `amnezia-awg2` (v2)
  - `amnezia-xray` (xray)
  - can install WARP if missing
  - creates timestamped backup snapshots before each mutating step
  - can roll back to a selected backup snapshot from the menu
  - can uninstall and return the host to the pre-routing state
  - shows network status, container IPs, routing state, live egress IP, WARP trace check, and debug info in the menu
  - verifies active container egress with `curl`/`wget` against `https://ipinfo.io` and `http://ip-api.com/json/`

## Requirements

Target host requirements:

- Linux host with `systemd`
- root access
- Docker installed and running
- Docker CLI available as `docker`
- one of these containers present:
- `amnezia-awg`, `amnezia-awg2`, or `amnezia-xray`
- `ip` from `iproute2`
- `iptables` with the mangle table available
- `python3`
- `curl` or `wget` for status and egress probes

For automatic WARP bootstrap through `wgcf`:

- Ubuntu/Debian, RHEL-family, or another distro with `apt-get`, `dnf`, or `yum`
- outbound access to GitHub and Cloudflare
- WireGuard kernel support and `wireguard-tools`

If you already have a working WARP interface, automatic bootstrap is not required. In that case the script can reuse the existing interface and only needs the routing/firewall dependencies above.

## Easy Install

Run directly from GitHub with `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh | sudo bash
```

Interactive prompts are read from `/dev/tty`, so the menu still works with `curl | bash` when a TTY is available.

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
    egress IP: 104.28.N.N | Gotham City | USA | Cloudflare, Inc.
  Amnezia Xray: found
    container IP: 172.29.172.3
    routing service: not installed
  Host WARP: not found

1) Install WARP and route all detected containers
2) Install or refresh routing for AWG Legacy only
3) Install or refresh routing for AWG v2 only
4) Install or refresh routing for Amnezia Xray only
5) Remove everything configured by this script
6) Rollback to a backup snapshot
7) Show status
8) Exit
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

The installer writes system files on the host:

- `/usr/local/sbin/amnezia-warp-routing.sh`
- `/usr/local/sbin/amnezia-warp-reconcile.sh`
- `/etc/systemd/system/amnezia-warp-routing@.service`
- `/etc/systemd/system/amnezia-warp-reconcile.service`
- `/etc/systemd/system/amnezia-warp-reconcile.timer`
- `/etc/amnezia-warp/*.env`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- timestamped snapshots under `/var/backups/amnezia-warp-host-routing` by default

It also applies runtime state:

- enables and starts `amnezia-warp-routing@*.service` for selected containers
- enables and starts `amnezia-warp-reconcile.timer`
- adds `ip rule` entries for container fwmarks
- writes routes into the configured policy routing table
- creates and hooks managed `iptables` mangle chains
- sets bridge netfilter sysctls for Docker bridge traffic

If WARP is bootstrapped by the script, it also writes:

- `/etc/wireguard/wgcf.conf`
- `/etc/wireguard/wgcf-account.toml`
- `/usr/local/bin/wgcf`

## Rollback

Before each mutating step, the script creates a timestamped snapshot of its managed files and service state.

You can restore one from the interactive menu with:

- `Rollback to a backup snapshot`

By default, snapshots are stored in:

- `/var/backups/amnezia-warp-host-routing`

You can override the location with:

```bash
BACKUP_ROOT=/custom/path
```

## Verification

After install, the script already prints a post-check:

- host WARP trace status
- live egress IP / country / city / ISP for the affected container

If you still want to double-check manually, connect through the VPN and open any IP / ISP lookup site:

- [myip.com](https://www.myip.com/)
- [2ip.io](https://2ip.io/)
- [WhatIsMyIPAddress](https://whatismyipaddress.com/)
- [WhatIsMyISP](https://www.whatismyisp.com/)
- [DNSChecker: What's My IP Address](https://dnschecker.org/whats-my-ip-address.php)

You should see a Cloudflare-owned IP instead of the VPS IP.

## Self-Healing

The installer enables `amnezia-warp-reconcile.timer`.

Every minute it checks the runtime kernel state for the configured containers:

- `ip rule` entries for container fwmarks
- the WARP default route in the routing table
- managed `iptables` mangle chains and PREROUTING hooks

If any of those runtime rules disappear while the systemd routing services still look active, the timer re-applies the existing `/etc/amnezia-warp/*.env` configuration.

## Notes

- This routes outgoing traffic only.
- It does not hide inbound VPS ports behind Cloudflare.
- It is designed around common Amnezia Docker layouts with `amn0` and `172.29.x.x`, but tries to autodetect when possible.
- If the host already uses a WARP interface from another tool, the installer reuses it rather than replacing it.

## Support

This project is shared as-is.

Issues and pull requests are welcome, but maintenance happens on a best-effort basis. Reviews may be delayed because this is not my full-time work.
