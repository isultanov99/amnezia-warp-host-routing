# Amnezia WARP Host Routing

[English](README.md) | [Русский](README_ru.md)

Route internet-bound traffic from selected Amnezia Docker containers through host-level Cloudflare WARP while keeping inbound VPN connections on the VPS public IP. The host default route is not changed.

## Compatibility

| Container | Protocol |
| --- | --- |
| `amnezia-awg` | Legacy AmneziaWG |
| `amnezia-awg2` | Current AmneziaWG 2.x, 3.0, and 3.1 |
| `amnezia-xray` | Amnezia Xray |

AmneziaWG 3.x still uses the `amnezia-awg2` container name. The installer detects 3.x configuration parameters and displays the installed `amneziawg-tools` version in status output.

## Requirements

- Linux with `systemd` and root access
- Docker with at least one supported container running
- `iproute2`, `iptables`, `python3`, and `curl` or `wget`
- WireGuard kernel support and outbound GitHub/Cloudflare access if the installer must create WARP through `wgcf`

Supported package managers for automatic dependency installation are `apt-get`, `dnf`, and `yum`.

## Install

Download and inspect the script, then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/master/deploy_amnezia_warp_host.sh
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

The interactive menu can install or remove routing per container, show status, and restore a backup.

Direct commands are also available:

```bash
# All detected containers
sudo ./deploy_amnezia_warp_host.sh install all

# Current AmneziaWG container, including AWG 3.0/3.1
sudo ./deploy_amnezia_warp_host.sh install current

# Other individual targets
sudo ./deploy_amnezia_warp_host.sh install legacy
sudo ./deploy_amnezia_warp_host.sh install xray

# Status and removal
sudo ./deploy_amnezia_warp_host.sh status
sudo ./deploy_amnezia_warp_host.sh uninstall current
sudo ./deploy_amnezia_warp_host.sh uninstall all
```

For backwards compatibility, `AUTO_YES=1` with no command installs all detected containers; with `uninstall`, it removes all managed routing.

## Existing WARP interfaces

The installer checks WireGuard-like interfaces with Cloudflare's trace endpoint and automatically reuses only an interface confirmed as WARP. This prevents unrelated tunnels such as `wg-home` from being selected accidentally.

If trace verification is unavailable, select the interface explicitly:

```bash
sudo WARP_IF=wg0 ./deploy_amnezia_warp_host.sh install current
```

Useful overrides:

```bash
WARP_IF=wg0
WAN_IF=eth0
WARP_PROFILE_NAME=wgcf
BASE_TABLE=51820
BACKUP_ROOT=/var/backups/amnezia-warp-host-routing
NO_COLOR=1
```

## What it changes

The installer:

1. Detects container addresses, the host WAN, and Docker bridges.
2. Reuses verified WARP or creates `/etc/wireguard/wgcf.conf` with `Table = off`.
3. Adds policy-routing rules and dedicated `iptables` mangle chains for selected container source addresses.
4. Installs `systemd` routing units and a reconciliation timer that restores missing runtime rules and refreshes container IPs after Docker recreates a container.

Managed files live under:

- `/etc/amnezia-warp/`
- `/etc/systemd/system/amnezia-warp-*`
- `/usr/local/sbin/amnezia-warp-*`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- `/etc/wireguard/` when WARP is created through `wgcf`

Timestamped pre-change snapshots are stored in `/var/backups/amnezia-warp-host-routing`. Restore them from the interactive menu.

## Verify

```bash
sudo ./deploy_amnezia_warp_host.sh status
```

Status shows the detected AWG generation, routing services, WARP trace result, policy rules, and the container's live egress IP. A working setup should report WARP as active and a Cloudflare-owned egress IP while the VPS default route remains unchanged.

## Notes

- Only outgoing container traffic is routed through WARP; inbound ports remain on the VPS IP.
- Managed policy routing is currently IPv4-only; IPv6 traffic is not routed by this script.
- Private and Docker subnets are excluded from WARP routing.
- Existing `legacy.env`, `v2.env`, and `xray.env` files are migrated automatically when container IPs change; the `v2` service name remains compatible with AWG 2.x.
- The installer skips stale configurations whose recorded WARP interface no longer exists, so one obsolete container configuration cannot block reconciliation for the others.

## License

[MIT](LICENSE)

## Support

This project is shared as-is.

Issues and pull requests are welcome, but maintenance happens on a best-effort basis. Reviews may be delayed because this is not my full-time work.
