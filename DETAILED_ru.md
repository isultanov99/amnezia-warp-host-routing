# Подробная документация

[Вернуться к README](README_ru.md) | [English](DETAILED.md)

## Назначение

Установщик сохраняет VPS публичной точкой входа Amnezia, но направляет исходящий трафик выбранных контейнеров через интерфейс Cloudflare WARP на хосте. Default route сервера не заменяется, входящие порты не проксируются через Cloudflare.

Поддерживаемые контейнеры:

| Контейнер | Протокол | Внутренний suffix сервиса |
| --- | --- | --- |
| `amnezia-awg` | Legacy AmneziaWG | `legacy` |
| `amnezia-awg2` | AmneziaWG 2.x/3.x | `v2` |
| `amnezia-xray` | Amnezia Xray | `xray` |

AWG 3.0 и 3.1 сохраняют имя контейнера `amnezia-awg2` и suffix `v2`. Это обеспечивает совместимость с существующими `/etc/amnezia-warp/v2.env` и systemd units.

## Требования

- Linux с `systemd` и root-доступом
- Docker и хотя бы один поддерживаемый контейнер
- `iproute2`, `iptables`, `python3`, а также `curl` или `wget`
- поддержка WireGuard в ядре и доступ к GitHub/Cloudflare, если WARP создаётся через `wgcf`

Автоматическая установка зависимостей поддерживает `apt-get`, `dnf` и `yum`.

## Команды

Интерактивное меню:

```bash
sudo ./deploy_amnezia_warp_host.sh
```

Прямая установка:

```bash
sudo ./deploy_amnezia_warp_host.sh install all
sudo ./deploy_amnezia_warp_host.sh install current
sudo ./deploy_amnezia_warp_host.sh install legacy
sudo ./deploy_amnezia_warp_host.sh install xray
```

`current`, `awg`, `awg2` и `v2` являются псевдонимами цели `amnezia-awg2`.

Статус и удаление:

```bash
sudo ./deploy_amnezia_warp_host.sh status
sudo ./deploy_amnezia_warp_host.sh uninstall current
sudo ./deploy_amnezia_warp_host.sh uninstall all
```

Для обратной совместимости `AUTO_YES=1` без команды настраивает все найденные контейнеры, а вместе с `uninstall` удаляет всю управляемую маршрутизацию.

## Переопределения

```bash
WARP_IF=wg0
WAN_IF=eth0
WARP_PROFILE_NAME=wgcf
BASE_TABLE=51820
BACKUP_ROOT=/var/backups/amnezia-warp-host-routing
AUTO_YES=1
NO_COLOR=1
```

Пример:

```bash
sudo WARP_IF=wg0 WAN_IF=ens3 ./deploy_amnezia_warp_host.sh install current
```

Без `WARP_IF` установщик проверяет WireGuard-подобные интерфейсы через trace endpoint Cloudflare и использует только подтверждённый WARP. Поэтому обычный туннель наподобие `wg-home` не будет выбран автоматически. Если trace-проверка недоступна, задайте интерфейс явно.

## Модель маршрутизации

Для каждого выбранного контейнера установщик:

1. Определяет все адреса контейнера и соответствующие Docker bridge-интерфейсы.
2. Создаёт отдельные fwmark, policy rule и mangle chain.
3. Исключает loopback, приватные, Docker- и WAN-сети.
4. Направляет помеченный интернет-трафик через таблицу WARP.
5. Не изменяет обычный default route хоста.

Текущие идентификаторы:

| Цель | Mark | Priority | Chain |
| --- | --- | --- | --- |
| Legacy AWG | `0x61` | `10061` | `AMN_WARP_AWG` |
| Current AWG | `0x62` | `10062` | `AMN_WARP_AWG2` |
| Xray | `0x63` | `10063` | `AMN_WARP_XRAY` |

IPv4 и IPv6 используют раздельные таблицы маршрутизации ядра с одинаковым номером таблицы и fwmark.

## IPv6

Host-side IPv6 маршрутизация включается для контейнера автоматически только при выполнении всех условий:

- Docker возвращает хотя бы один `GlobalIPv6Address` контейнера;
- выбранный WARP-интерфейс имеет глобальный IPv6;
- доступен `ip6tables`.

В этом случае helper создаёт:

- IPv6 fwmark rule и default route через WARP;
- отдельные mangle rules `ip6tables`;
- IPv6 SNAT chain с адресом WARP-интерфейса;
- подключённые IPv6-маршруты для обратного трафика.

Установщик намеренно не придумывает VPN IPv6-prefix и не меняет peer-конфигурации Amnezia. Для end-to-end IPv6 клиента также требуются:

1. IPv6 на Docker-сетях контейнера Amnezia;
2. глобальный или ULA IPv6 на container-facing интерфейсах;
3. IPv6-prefix на `awg0` и уникальный IPv6 в каждом клиентском конфиге;
4. соответствующие IPv6 `AllowedIPs` peer'ов на сервере;
5. IPv6 forwarding и firewall/NAT внутри контейнера Amnezia.

Стандартная установка контейнера Amnezia может быть IPv4-only. Тогда статус показывает `container IPv6: not available`, а скрипт не создаёт нерабочие IPv6-правила и не меняет существующее поведение.

Одного `::/0` в клиентском `AllowedIPs` недостаточно, если интерфейсу клиента не назначен IPv6-адрес.

## Self-healing

`amnezia-warp-reconcile.timer` запускается раз в минуту и проверяет policy rules, маршруты, mangle hooks, marks и, при наличии IPv6, состояние SNAT.

После пересоздания контейнера Docker reconcile получает его текущие IPv4/IPv6, атомарно обновляет `SRC`, `SRCS` и `SRCS6` в env-файле и перезапускает нужный routing unit. Старые env без `CONTAINER` сопоставляются по историческим именам `legacy`, `v2` и `xray`.

Env-файл с исчезнувшим WARP-интерфейсом пропускается и не блокирует исправление здоровых контейнеров.

## Управляемые файлы

- `/etc/amnezia-warp/*.env`
- `/usr/local/sbin/amnezia-warp-routing.sh`
- `/usr/local/sbin/amnezia-warp-reconcile.sh`
- `/etc/systemd/system/amnezia-warp-routing@.service`
- `/etc/systemd/system/amnezia-warp-reconcile.service`
- `/etc/systemd/system/amnezia-warp-reconcile.timer`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- `/etc/wireguard/`, если WARP создавался через `wgcf`

Env-файлы содержат метаданные маршрутизации и адреса контейнеров, но не приватные ключи клиентов Amnezia.

## Бэкапы и откат

Перед изменениями установщик сохраняет управляемые файлы, состояние сервисов, IPv4/IPv6 rules, routing tables и firewall state в:

```text
/var/backups/amnezia-warp-host-routing
```

Для восстановления выберите `Rollback to a backup snapshot` в интерактивном меню. Путь можно изменить через `BACKUP_ROOT`.

## Проверка

```bash
sudo ./deploy_amnezia_warp_host.sh status
```

Отчёт включает:

- найденное поколение AWG и версию tools;
- текущие IPv4 и IPv6 контейнеров;
- состояние routing services и reconcile;
- host IPv4 WARP trace и, для dual-stack контейнеров, end-to-end проверку IPv6 egress;
- policy rules и routing tables;
- реальный IPv4 egress контейнеров.

При рабочей IPv4-настройке контейнер получает Cloudflare egress IP, а default route VPS остаётся через обычный WAN gateway. IPv6 rules и результат IPv6 egress появляются только у контейнеров, которые действительно имеют IPv6.

## Диагностика

`configured SRCS mismatch` означает, что Docker пересоздал контейнер и изменил его адреса. Текущий reconcile исправляет это автоматически. Для обновления старых установленных helper-скриптов достаточно один раз повторно запустить установщик.

Если обычный WireGuard-туннель определяется как WARP, задайте нужный интерфейс через `WARP_IF`. Автоматический выбор теперь требует успешного Cloudflare trace.

Если IPv6 отсутствует, проверяйте по порядку:

```bash
docker network inspect bridge amnezia-dns-net
docker inspect amnezia-awg2
docker exec amnezia-awg2 ip -6 address
docker exec amnezia-awg2 sysctl net.ipv6.conf.all.forwarding
sudo ./deploy_amnezia_warp_host.sh status
```

Не включайте клиентский маршрут `::/0`, пока у туннеля нет IPv6-адреса и серверный путь не проверен: результатом может стать неработающий IPv6 или обход предполагаемого туннеля.
