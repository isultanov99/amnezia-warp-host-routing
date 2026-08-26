# Amnezia WARP Host Routing

[English](README.md) | [Русский](README_ru.md)

Маршрутизирует исходящий интернет-трафик выбранных Docker-контейнеров Amnezia через Cloudflare WARP на хосте. Входящие VPN-подключения продолжают приходить на публичный IP VPS, а default route самого хоста не меняется.

## Совместимость

| Контейнер | Протокол |
| --- | --- |
| `amnezia-awg` | Legacy AmneziaWG |
| `amnezia-awg2` | Текущий AmneziaWG 2.x, 3.0 и 3.1 |
| `amnezia-xray` | Amnezia Xray |

AmneziaWG 3.x по-прежнему использует имя контейнера `amnezia-awg2`. Установщик распознаёт параметры конфигурации 3.x и показывает установленную версию `amneziawg-tools` в статусе.

## Требования

- Linux с `systemd` и root-доступом
- Docker и хотя бы один запущенный поддерживаемый контейнер
- `iproute2`, `iptables`, `python3`, а также `curl` или `wget`
- поддержка WireGuard в ядре и доступ к GitHub/Cloudflare, если WARP нужно создать через `wgcf`

Автоматическая установка зависимостей поддерживает `apt-get`, `dnf` и `yum`.

## Установка

Скачайте и проверьте скрипт, затем запустите его:

```bash
curl -fsSLO https://raw.githubusercontent.com/isultanov99/amnezia-warp-host-routing/master/deploy_amnezia_warp_host.sh
chmod +x deploy_amnezia_warp_host.sh
sudo ./deploy_amnezia_warp_host.sh
```

Интерактивное меню позволяет отдельно настраивать и удалять маршрутизацию контейнеров, смотреть статус и восстанавливать бэкап.

Есть и прямые команды:

```bash
# Все найденные контейнеры
sudo ./deploy_amnezia_warp_host.sh install all

# Текущий контейнер AmneziaWG, включая AWG 3.0/3.1
sudo ./deploy_amnezia_warp_host.sh install current

# Другие отдельные цели
sudo ./deploy_amnezia_warp_host.sh install legacy
sudo ./deploy_amnezia_warp_host.sh install xray

# Статус и удаление
sudo ./deploy_amnezia_warp_host.sh status
sudo ./deploy_amnezia_warp_host.sh uninstall current
sudo ./deploy_amnezia_warp_host.sh uninstall all
```

Для обратной совместимости `AUTO_YES=1` без команды устанавливает маршрутизацию для всех найденных контейнеров, а вместе с `uninstall` удаляет всю управляемую конфигурацию.

## Существующий WARP

Скрипт проверяет WireGuard-подобные интерфейсы через trace endpoint Cloudflare и автоматически использует только подтверждённый WARP. Поэтому обычный туннель наподобие `wg-home` не будет ошибочно выбран как WARP.

Если trace-проверка недоступна, задайте интерфейс явно:

```bash
sudo WARP_IF=wg0 ./deploy_amnezia_warp_host.sh install current
```

Полезные переопределения:

```bash
WARP_IF=wg0
WAN_IF=eth0
WARP_PROFILE_NAME=wgcf
BASE_TABLE=51820
BACKUP_ROOT=/var/backups/amnezia-warp-host-routing
NO_COLOR=1
```

## Что изменяется

Установщик:

1. Определяет адреса контейнеров, WAN хоста и Docker bridge-интерфейсы.
2. Использует подтверждённый WARP или создаёт `/etc/wireguard/wgcf.conf` с `Table = off`.
3. Добавляет policy routing и отдельные `iptables` mangle chains для адресов выбранных контейнеров.
4. Устанавливает routing units `systemd` и timer, который восстанавливает runtime-правила и обновляет IP после пересоздания контейнера Docker.

Управляемые файлы находятся в:

- `/etc/amnezia-warp/`
- `/etc/systemd/system/amnezia-warp-*`
- `/usr/local/sbin/amnezia-warp-*`
- `/etc/sysctl.d/99-amnezia-warp.conf`
- `/etc/wireguard/`, если WARP создавался через `wgcf`

Timestamp-бэкапы перед изменениями сохраняются в `/var/backups/amnezia-warp-host-routing`. Восстановить их можно из интерактивного меню.

## Проверка

```bash
sudo ./deploy_amnezia_warp_host.sh status
```

Статус показывает найденное поколение AWG, состояние routing services, WARP trace, policy rules и реальный egress IP контейнера. При рабочей настройке WARP должен быть активен, исходящий IP должен принадлежать Cloudflare, а default route VPS — остаться прежним.

## Примечания

- Через WARP идёт только исходящий трафик контейнеров; входящие порты остаются на IP VPS.
- Управляемая маршрутизация пока работает только для IPv4; IPv6-трафик этот скрипт не направляет.
- Приватные и Docker-подсети исключаются из WARP-маршрутизации.
- Старые `legacy.env`, `v2.env` и `xray.env` автоматически мигрируют при изменении IP контейнера; имя сервиса `v2` сохраняет совместимость с AWG 2.x.
- Конфигурации, ссылающиеся на исчезнувший WARP-интерфейс, пропускаются при reconcile, поэтому одна устаревшая запись не блокирует остальные.

## Лицензия

[MIT](LICENSE)

## Поддержка

Проект публикуется как `as-is`.

Issues и pull requests приветствуются, но поддержка ведётся по возможности. Ревью и ответы могут занимать время, поскольку это не основная работа автора.
