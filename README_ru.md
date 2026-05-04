# Amnezia WARP Host Routing

[English](https://github.com/isultanov99/amnezia-warp-host-routing/blob/master/README.md) | [Russian](https://github.com/isultanov99/amnezia-warp-host-routing/blob/master/README_ru.md)

## О скрипте

Небольшой Bash-установщик для маршрутизации исходящего трафика контейнеров Amnezia через Cloudflare WARP на уровне хоста, при этом входящие подключения продолжают приходить на реальный IP VPS.

Установщик делает timestamp-бэкапы перед изменениями и умеет откатываться к выбранному snapshot прямо из меню.

Скрипт решает такую задачу:

- `amnezia-awg`, `amnezia-awg2` или `amnezia-xray` продолжают принимать входящие подключения на публичном IP сервера
- исходящий интернет-трафик выбранных контейнеров policy-routing'ом уходит через host-level WARP
- внешние сервисы видят Cloudflare IP вместо IP VPS
- default route самого хоста не меняется

Это удобно, когда нужно сохранить VPS как входную точку для VPN, но скрыть IP сервера для исходящего трафика клиентов.

## Как это работает под капотом

Скрипт делает четыре вещи:

1. Находит контейнеры Amnezia, их IP, WAN-интерфейс хоста, Amnezia bridge и Docker bridge’и.
2. Проверяет, есть ли host-level WARP.
   - Если интерфейс уже есть, например `wg0` от `x-ui` или `3x-ui`, он будет использован повторно.
   - Если WARP нет, скрипт может поднять его через `wgcf`, создав `/etc/wireguard/wgcf.conf` с `Table = off`.
3. Устанавливает helper-скрипт и `systemd` unit’ы для маршрутизации.
4. Добавляет policy routing и `iptables` mangle rules так, чтобы через WARP шёл только нужный исходящий трафик контейнеров.

Скрипт не подменяет default route VPS и не пытается «спрятать» входящие порты за Cloudflare.

## Основной файл

- `deploy_amnezia_warp_host.sh`
  - интерактивный установщик для:
    - `amnezia-awg` (legacy)
    - `amnezia-awg2` (v2)
    - `amnezia-xray` (xray)
  - умеет ставить WARP при его отсутствии
  - делает timestamp-бэкапы перед каждым изменяющим шагом
  - умеет откатываться к выбранному backup snapshot из меню
  - умеет удалять всё, что настроил сам
  - показывает статус сети, IP контейнеров и состояние routing service прямо в меню

## Требования

На целевом хосте должны быть:

- Linux с `systemd`
- установленный и работающий Docker
- хотя бы один контейнер:
  - `amnezia-awg`
  - `amnezia-awg2`
  - `amnezia-xray`
- root-доступ
- `iptables`
- `python3`

Для автоматической установки WARP через `wgcf`:

- Ubuntu/Debian, RHEL-family или другой дистрибутив с поддерживаемым пакетным менеджером
- исходящий доступ к GitHub и Cloudflare

## Запуск

## Быстрая установка

Запуск напрямую с GitHub через `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh | sudo bash
```

Интерактивные вопросы читаются из `/dev/tty`, поэтому меню продолжает работать и при `curl | bash`, если доступен TTY.

Или через `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh | sudo bash
```

Если хочется сначала посмотреть скрипт:

```bash
curl -fsSLO https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/refs/heads/master/deploy_amnezia_warp_host.sh
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

## Запуск

На VPS:

```bash
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

Типичный вид меню:

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
6) Rollback to a backup snapshot
7) Show status
8) Exit
```

Неинтерактивная установка всего найденного:

```bash
sudo AUTO_YES=1 ./deploy_amnezia_warp_host.sh
```

Просмотр статуса:

```bash
sudo ./deploy_amnezia_warp_host.sh status
```

Удаление:

```bash
sudo ./deploy_amnezia_warp_host.sh uninstall
```

Неинтерактивное удаление:

```bash
sudo AUTO_YES=1 ./deploy_amnezia_warp_host.sh uninstall
```

## Переменные окружения

Для нестандартной сетевой схемы можно переопределить:

```bash
WARP_IF=wg0
WAN_IF=eth0
WARP_PROFILE_NAME=wgcf
AUTO_YES=1
```

Пример:

```bash
sudo WARP_IF=wg0 WAN_IF=ens34 ./deploy_amnezia_warp_host.sh
```

## Какие файлы создаются

Скрипт пишет:

- `/usr/local/sbin/amnezia-warp-routing.sh`
- `/etc/systemd/system/amnezia-warp-routing@.service`
- `/etc/amnezia-warp/*.env`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- timestamped snapshot’ы в `/var/backups/amnezia-warp-host-routing` по умолчанию

Если WARP ставится самим скриптом, дополнительно создаются:

- `/etc/wireguard/wgcf.conf`
- `/etc/wireguard/wgcf-account.toml`
- `/usr/local/bin/wgcf`

## Откат

Перед каждым изменяющим шагом скрипт сохраняет timestamp-snapshot с управляемыми файлами и состоянием сервисов.

Откат из интерактивного меню:

- `Rollback to a backup snapshot`

По умолчанию snapshot’ы лежат в:

- `/var/backups/amnezia-warp-host-routing`

Путь можно переопределить:

```bash
BACKUP_ROOT=/custom/path
```

## Как проверять

После подключения через VPN открой любой сайт, который показывает IP и провайдера:

- [myip.com](https://www.myip.com/)
- [2ip.io](https://2ip.io/)
- [whatismyipaddress.com](https://whatismyipaddress.com/)
- [whatismyisp.com](https://www.whatismyisp.com/)
- [dnschecker.org: What's My IP Address](https://dnschecker.org/whats-my-ip-address.php)

Если всё настроено правильно, ты увидишь Cloudflare IP вместо IP VPS.

## Примечания

- Скрипт маршрутизирует только исходящий трафик.
- Он не скрывает входящие порты VPS за Cloudflare.
- Он рассчитан на типичные Docker-схемы Amnezia с `amn0` и `172.29.x.x`, но старается всё определить автоматически.
- Если на хосте уже есть WARP-интерфейс от другого инструмента, скрипт будет переиспользовать его, а не ломать текущую схему.

## Поддержка

Проект публикуется как `as-is`.

Issues и pull requests приветствуются, но поддержку я смотрю по возможности. Ревью и ответы могут быть небыстрыми, потому что это не фуллтайм-поддержка.
