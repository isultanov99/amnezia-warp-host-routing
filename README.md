# Amnezia WARP Host Routing

[English](README.md) | [Русский](README_ru.md) | [Detailed documentation](DETAILED.md)

Routes outgoing traffic from Amnezia Docker containers through host-level Cloudflare WARP. Incoming VPN connections continue to use the VPS public IP, and the host default route remains unchanged.

Supported containers:

- `amnezia-awg` — legacy AmneziaWG
- `amnezia-awg2` — AmneziaWG 2.x, 3.0, and 3.1
- `amnezia-xray` — Amnezia Xray

## Install

Run on a Linux VPS with `systemd`, Docker, and root access:

```bash
curl -fsSLO https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/master/deploy_amnezia_warp_host.sh
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

The interactive menu handles installation, status, removal, and rollback. A direct installation is also available:

```bash
sudo ./deploy_amnezia_warp_host.sh install all
sudo ./deploy_amnezia_warp_host.sh install current
```

For configuration options, architecture, IPv6 requirements, verification, and troubleshooting, see [DETAILED.md](DETAILED.md).

## License

[MIT](LICENSE)

## Support

This project is shared as-is.

Issues and pull requests are welcome, but maintenance happens on a best-effort basis. Reviews may be delayed because this is not my full-time work.
