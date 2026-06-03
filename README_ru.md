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

## TL;DR

Если без технических деталей:

1. Запускаешь скрипт на VPS, где крутится `amnezia-awg`, `amnezia-awg2` или `amnezia-xray`.
2. Входящие VPN-подключения остаются на IP VPS.
3. Исходящий трафик выбранного контейнера уходит через Cloudflare WARP.
4. После настройки скрипт сам показывает, поднят ли WARP и какой egress IP реально используется.
5. Если у тебя уже есть другое решение на базе Cloudflare WARP, например готовый интерфейс `warp` или `wg0` от другого инструмента или панели, скрипт может переиспользовать его вместо создания второго.

## Как это работает под капотом

Скрипт делает четыре вещи:

1. Находит контейнеры Amnezia, их IP, WAN-интерфейс хоста, Amnezia bridge и Docker bridge’и.
2. Проверяет, есть ли host-level WARP.
   - Если интерфейс уже есть, например `wg0` от `x-ui` или `3x-ui`, он будет использован повторно.
   - Если WARP нет, скрипт может поднять его через `wgcf`, создав `/etc/wireguard/wgcf.conf` с `Table = off`.
3. Устанавливает system-level helper-скрипты и `systemd` unit’ы.
4. Добавляет policy routing и `iptables` mangle rules так, чтобы через WARP шёл только нужный исходящий трафик контейнеров.

Скрипт не подменяет default route VPS и не пытается «спрятать» входящие порты за Cloudflare.

Во время настройки скрипт пишет файлы в `/etc` и `/usr/local/sbin`, создаёт `systemd` unit’ы, включает timer и применяет live-правила routing/firewall.

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
  - показывает статус сети, IP контейнеров, состояние routing service, live egress IP и WARP trace check прямо в меню
  - проверяет egress активных контейнеров через `curl`/`wget` к `https://ipinfo.io` и `http://ip-api.com/json/`

## Требования

На целевом хосте должны быть:

- Linux с `systemd`
- root-доступ
- установленный и работающий Docker
- Docker CLI как `docker`
- хотя бы один контейнер: `amnezia-awg`, `amnezia-awg2` или `amnezia-xray`
- `ip` из `iproute2`
- `iptables` с доступной mangle table
- `python3`
- `curl` или `wget` для status и egress-проверок

Для автоматической установки WARP через `wgcf`:

- Ubuntu/Debian, RHEL-family или другой дистрибутив с `apt-get`, `dnf` или `yum`
- исходящий доступ к GitHub и Cloudflare
- поддержка WireGuard в ядре и `wireguard-tools`

Если рабочий WARP-интерфейс уже есть, автоматическая установка WARP не нужна. В этом случае скрипт может переиспользовать существующий интерфейс, а нужны только зависимости для routing/firewall выше.

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

Скрипт пишет системные файлы на хосте:

- `/usr/local/sbin/amnezia-warp-routing.sh`
- `/usr/local/sbin/amnezia-warp-reconcile.sh`
- `/etc/systemd/system/amnezia-warp-routing@.service`
- `/etc/systemd/system/amnezia-warp-reconcile.service`
- `/etc/systemd/system/amnezia-warp-reconcile.timer`
- `/etc/amnezia-warp/*.env`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- timestamped snapshot’ы в `/var/backups/amnezia-warp-host-routing` по умолчанию

Он также применяет runtime-состояние:

- включает и запускает `amnezia-warp-routing@*.service` для выбранных контейнеров
- включает и запускает `amnezia-warp-reconcile.timer`
- добавляет `ip rule` записи для container fwmark
- пишет маршруты в настроенную policy routing table
- создаёт и подключает управляемые `iptables` mangle chains
- выставляет bridge netfilter sysctls для Docker bridge traffic

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

После установки скрипт уже сам показывает post-check:

- статус host WARP через `cdn-cgi/trace`
- live egress IP / country / city / ISP для активного контейнера

Если хочется перепроверить вручную, после подключения через VPN открой любой сайт, который показывает IP и провайдера:

- [myip.com](https://www.myip.com/)
- [2ip.io](https://2ip.io/)
- [whatismyipaddress.com](https://whatismyipaddress.com/)
- [whatismyisp.com](https://www.whatismyisp.com/)
- [dnschecker.org: What's My IP Address](https://dnschecker.org/whats-my-ip-address.php)

Если всё настроено правильно, ты увидишь Cloudflare IP вместо IP VPS.

## Self-healing

Скрипт включает `amnezia-warp-reconcile.timer`.

Раз в минуту он проверяет runtime-состояние ядра для настроенных контейнеров:

- `ip rule` записи для container fwmark
- default route через WARP в routing table
- управляемые `iptables` mangle chains и PREROUTING hooks

Если эти runtime-правила исчезли, а systemd routing services всё ещё выглядят активными, timer заново применяет существующую конфигурацию из `/etc/amnezia-warp/*.env`.

## Примечания

- Скрипт маршрутизирует только исходящий трафик.
- Он не скрывает входящие порты VPS за Cloudflare.
- Он рассчитан на типичные Docker-схемы Amnezia с `amn0` и `172.29.x.x`, но старается всё определить автоматически.
- Если на хосте уже есть WARP-интерфейс от другого инструмента, скрипт будет переиспользовать его, а не ломать текущую схему.

## Поддержка

Проект публикуется как `as-is`.

Issues и pull requests приветствуются, но поддержку я смотрю по возможности. Ревью и ответы могут быть небыстрыми, потому что это не фуллтайм-поддержка.
