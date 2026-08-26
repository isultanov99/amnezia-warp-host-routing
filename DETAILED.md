# Detailed documentation

[Back to README](README.md) | [Русская версия](DETAILED_ru.md)

## Purpose

The installer keeps the VPS as the public entry point for Amnezia while policy-routing selected container egress through a host Cloudflare WARP interface. It does not replace the host default route or proxy inbound ports through Cloudflare.

Supported container names:

| Container | Protocol | Internal service suffix |
| --- | --- | --- |
| `amnezia-awg` | Legacy AmneziaWG | `legacy` |
| `amnezia-awg2` | AmneziaWG 2.x/3.x | `v2` |
| `amnezia-xray` | Amnezia Xray | `xray` |

AWG 3.0 and 3.1 retain the `amnezia-awg2` container and `v2` service names. Keeping that suffix preserves compatibility with existing `/etc/amnezia-warp/v2.env` files and systemd units.

## Requirements

- Linux with `systemd` and root access
- Docker with at least one supported container
- `iproute2`, `iptables`, `python3`, and `curl` or `wget`
- WireGuard kernel support and outbound GitHub/Cloudflare access when WARP must be created through `wgcf`

Automatic dependency installation supports `apt-get`, `dnf`, and `yum`.

## Commands

Interactive menu:

```bash
sudo ./deploy_amnezia_warp_host.sh
```

Direct installation:

```bash
sudo ./deploy_amnezia_warp_host.sh install all
sudo ./deploy_amnezia_warp_host.sh install current
sudo ./deploy_amnezia_warp_host.sh install legacy
sudo ./deploy_amnezia_warp_host.sh install xray
```

`current`, `awg`, `awg2`, and `v2` are aliases for the `amnezia-awg2` target.

Status and removal:

```bash
sudo ./deploy_amnezia_warp_host.sh status
sudo ./deploy_amnezia_warp_host.sh uninstall current
sudo ./deploy_amnezia_warp_host.sh uninstall all
```

For backwards compatibility, `AUTO_YES=1` without a command installs all detected containers. Together with `uninstall`, it removes all managed routing.

## Overrides

```bash
WARP_IF=wg0
WAN_IF=eth0
WARP_PROFILE_NAME=wgcf
BASE_TABLE=51820
BACKUP_ROOT=/var/backups/amnezia-warp-host-routing
AUTO_YES=1
NO_COLOR=1
```

Example:

```bash
sudo WARP_IF=wg0 WAN_IF=ens3 ./deploy_amnezia_warp_host.sh install current
```

Without `WARP_IF`, the installer tests WireGuard-like interfaces against Cloudflare's trace endpoint and reuses only a confirmed WARP interface. This prevents an unrelated interface such as `wg-home` from being selected. Set `WARP_IF` explicitly when trace verification is unavailable.

## Routing model

For each selected container, the installer:

1. Detects all container addresses and the corresponding Docker bridges.
2. Creates a dedicated fwmark, policy rule, and mangle chain.
3. Excludes loopback, private, Docker, and WAN destinations.
4. Routes marked internet traffic through the WARP table.
5. Keeps the ordinary host default route unchanged.

The current identifiers are:

| Target | Mark | Priority | Chain |
| --- | --- | --- | --- |
| Legacy AWG | `0x61` | `10061` | `AMN_WARP_AWG` |
| Current AWG | `0x62` | `10062` | `AMN_WARP_AWG2` |
| Xray | `0x63` | `10063` | `AMN_WARP_XRAY` |

IPv4 and IPv6 use separate kernel routing tables with the same numeric table ID and fwmark.

## IPv6

Host-side IPv6 routing is enabled automatically for a container only when all of the following are present:

- Docker reports at least one `GlobalIPv6Address` for that container;
- the selected WARP interface has a global IPv6 address;
- `ip6tables` is available.

When those conditions are met, the helper installs:

- an IPv6 fwmark rule and WARP default route;
- dedicated `ip6tables` mangle rules;
- an IPv6 SNAT chain using the WARP interface address;
- connected IPv6 routes needed for return traffic.

The installer deliberately does not invent an IPv6 VPN prefix or modify Amnezia peer configurations. End-to-end client IPv6 therefore also requires:

1. IPv6 enabled on the Docker networks used by the Amnezia container;
2. a global or ULA IPv6 address on the container-facing interfaces;
3. an IPv6 prefix on `awg0` and a unique IPv6 address in each client config;
4. corresponding IPv6 peer `AllowedIPs` on the server;
5. IPv6 forwarding and firewall/NAT rules inside the Amnezia container.

The default Amnezia container setup may be IPv4-only. In that case status reports `container IPv6: not available`, and the installer leaves IPv6 rules absent rather than creating a broken or leaking route.

Merely adding `::/0` to client `AllowedIPs` is not sufficient when the client interface itself has no IPv6 address.

## Self-healing

`amnezia-warp-reconcile.timer` runs every minute. It verifies policy rules, routes, mangle hooks, marks, and—when configured—IPv6 SNAT state.

After Docker recreates a container, reconcile reads its current IPv4 and IPv6 addresses, atomically updates `SRC`, `SRCS`, and `SRCS6` in the env file, and restarts the corresponding routing unit. Old env files without `CONTAINER` are mapped by their historical `legacy`, `v2`, or `xray` filename.

An env file pointing to a missing WARP interface is skipped, so it cannot prevent healthy containers from being reconciled.

## Managed files

- `/etc/amnezia-warp/*.env`
- `/usr/local/sbin/amnezia-warp-routing.sh`
- `/usr/local/sbin/amnezia-warp-reconcile.sh`
- `/etc/systemd/system/amnezia-warp-routing@.service`
- `/etc/systemd/system/amnezia-warp-reconcile.service`
- `/etc/systemd/system/amnezia-warp-reconcile.timer`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- `/etc/wireguard/` when WARP is created through `wgcf`

The env files contain routing metadata and container addresses, not Amnezia client private keys.

## Backups and rollback

Before mutating steps, the installer saves managed files, service state, IPv4/IPv6 rules, routing tables, and firewall state under:

```text
/var/backups/amnezia-warp-host-routing
```

Choose `Rollback to a backup snapshot` in the interactive menu to restore one. Override the location with `BACKUP_ROOT` when required.

## Verification

```bash
sudo ./deploy_amnezia_warp_host.sh status
```

The report includes:

- detected AWG generation and tools version;
- current IPv4 and IPv6 container addresses;
- routing and reconcile service states;
- host IPv4 WARP trace and, for dual-stack containers, an end-to-end IPv6 egress check;
- policy rules and routing tables;
- live IPv4 container egress.

A working IPv4 setup shows a Cloudflare egress IP while the VPS default route still points to its ordinary WAN gateway. IPv6 rules and the IPv6 egress result appear only for containers that actually have IPv6.

## Troubleshooting

`configured SRCS mismatch` means Docker recreated a container and changed its addresses. The current reconcile helper repairs this automatically. Run the installer once to upgrade older installed helper scripts.

If a normal WireGuard tunnel is selected as WARP, specify the intended interface explicitly with `WARP_IF`. Automatic selection now requires a successful Cloudflare trace.

If IPv6 is absent, check these in order:

```bash
docker network inspect bridge amnezia-dns-net
docker inspect amnezia-awg2
docker exec amnezia-awg2 ip -6 address
docker exec amnezia-awg2 sysctl net.ipv6.conf.all.forwarding
sudo ./deploy_amnezia_warp_host.sh status
```

Do not enable a client `::/0` route until the tunnel has an IPv6 address and the server path has been verified; otherwise the result may be failed IPv6 connectivity or traffic bypassing the intended tunnel.
