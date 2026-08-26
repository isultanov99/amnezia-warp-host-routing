# Amnezia WARP Host Routing

[English](README.md) | [Русский](README_ru.md) | [Подробная документация](DETAILED_ru.md)

Маршрутизирует исходящий трафик Docker-контейнеров Amnezia через Cloudflare WARP на хосте. Входящие VPN-подключения продолжают использовать публичный IP VPS, а default route хоста остаётся без изменений.

Поддерживаемые контейнеры:

- `amnezia-awg` — legacy AmneziaWG
- `amnezia-awg2` — AmneziaWG 2.x, 3.0 и 3.1
- `amnezia-xray` — Amnezia Xray

## Установка

Запустите на Linux VPS с `systemd`, Docker и root-доступом:

```bash
curl -fsSLO https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/master/deploy_amnezia_warp_host.sh
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

Интерактивное меню позволяет установить и удалить маршрутизацию, посмотреть статус или восстановить бэкап. Доступен и прямой запуск:

```bash
sudo ./deploy_amnezia_warp_host.sh install all
sudo ./deploy_amnezia_warp_host.sh install current
```

Настройки, архитектура, требования IPv6, проверка и диагностика описаны в [DETAILED_ru.md](DETAILED_ru.md).

## Лицензия

[MIT](LICENSE)

## Поддержка

Проект публикуется как `as-is`.

Issues и pull requests приветствуются, но поддержка ведётся по возможности. Ревью и ответы могут занимать время, поскольку это не основная работа автора.
