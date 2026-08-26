#!/usr/bin/env bash
set -euo pipefail

# Interactive installer for routing AmneziaWG container egress through a host WARP
# interface while keeping inbound services on the VPS IP.
#
# It supports:
# - amnezia-awg   (legacy)
# - amnezia-awg2  (current AWG 2.x/3.x)
# - amnezia-xray  (xray)
#
# If no host WARP interface exists, it can install one via wgcf with Table=off,
# so the host default route remains untouched.

SCRIPT_NAME="$(basename "$0")"
BASE_TABLE="${BASE_TABLE:-51820}"
WARP_IF="${WARP_IF:-}"
WAN_IF="${WAN_IF:-}"
WAN_SUBNET="${WAN_SUBNET:-}"
WAN_IP="${WAN_IP:-}"
WARP_PROFILE_NAME="${WARP_PROFILE_NAME:-wgcf}"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1:2408}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/amnezia-warp-host-routing}"
AUTO_YES="${AUTO_YES:-0}"
ACTION="${1:-}"
TARGET="${2:-}"

CONTAINERS_FOUND=()
CONTAINER_SRC_IP=()
CONTAINER_SRC_IPV6=()
DOCKER_IFS=()
DOCKER_SUBNETS=()
DOCKER_IPS=()
DOCKER_V6_IFS=()
DOCKER_V6_SUBNETS=()
DOCKER_V6_IPS=()
AMN_IF=""
AMN_SUBNET=""
AMN_IP=""
WAN_V6_SUBNET=""
WAN_V6_IP=""
WARP_V6_IP=""
MENU_SELECTION=""
MENU_ACTION=""
ROLLBACK_SNAPSHOT=""
COLOR=1

if [[ ! -t 1 ]] || [[ "${TERM:-}" == "dumb" ]]; then
  COLOR=0
fi

if [[ "${NO_COLOR:-}" == "1" ]]; then
  COLOR=0
fi

if [[ "${COLOR}" == "1" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[36m'
  C_RED=$'\033[31m'
  C_GRAY=$'\033[90m'
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_RED=""
  C_GRAY=""
fi

log() {
  printf '%s\n' "$*"
}

info() {
  printf '%s%s%s\n' "${C_BLUE}" "$*" "${C_RESET}"
}

ok() {
  printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"
}

warn() {
  printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"
}

state_text() {
  local value="$1"
  case "${value}" in
    found|active)
      printf '%s%s%s' "${C_GREEN}" "${value}" "${C_RESET}"
      ;;
    failed|stale)
      printf '%s%s%s' "${C_RED}" "${value}" "${C_RESET}"
      ;;
    "not installed"|installed)
      printf '%s%s%s' "${C_YELLOW}" "${value}" "${C_RESET}"
      ;;
    "not found"|inactive)
      printf '%s%s%s' "${C_GRAY}" "${value}" "${C_RESET}"
      ;;
    *)
      printf '%s' "${value}"
      ;;
  esac
}

host_warp_unit_state() {
  if systemctl is-active --quiet "wg-quick@${WARP_PROFILE_NAME}.service" 2>/dev/null; then
    if [[ -n "${WARP_IF}" ]] && have_iface "${WARP_IF}"; then
      printf 'active\n'
    else
      printf 'stale\n'
    fi
    return
  fi
  if systemctl is-enabled "wg-quick@${WARP_PROFILE_NAME}.service" >/dev/null 2>&1 || [[ -f "/etc/wireguard/${WARP_PROFILE_NAME}.conf" ]]; then
    printf 'installed\n'
    return
  fi
  printf 'inactive\n'
}

warp_trace_summary_for_iface() {
  local iface="$1"
  local trace_line ip_line loc_line warp_value ip_value loc_value
  if [[ -z "${iface}" ]] || ! have_iface "${iface}"; then
    printf 'interface-missing\n'
    return
  fi

  trace_line="$(curl -4fsSL --max-time 10 --interface "${iface}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  if [[ -z "${trace_line}" ]]; then
    printf 'unreachable\n'
    return
  fi

  warp_value="$(printf '%s\n' "${trace_line}" | awk -F= '$1=="warp" {print $2; exit}')"
  ip_value="$(printf '%s\n' "${trace_line}" | awk -F= '$1=="ip" {print $2; exit}')"
  loc_value="$(printf '%s\n' "${trace_line}" | awk -F= '$1=="loc" {print $2; exit}')"
  [[ -n "${warp_value}" ]] || warp_value="unknown"
  [[ -n "${ip_value}" ]] || ip_value="unknown"
  [[ -n "${loc_value}" ]] || loc_value="unknown"
  printf 'warp=%s ip=%s loc=%s\n' "${warp_value}" "${ip_value}" "${loc_value}"
}

warp_trace_summary() {
  local iface="${WARP_IF:-}"
  local summary
  summary="$(warp_trace_summary_for_iface "${iface}")"
  if [[ "${summary}" == warp=* ]]; then
    printf '%s\n' "${summary}" | awk -F'[ =]' '/^warp=/{print $2}'
  else
    printf '%s\n' "${summary}"
  fi
}

verify_warp_connection() {
  [[ "$(warp_trace_summary)" == "on" ]]
}

die() {
  printf '%sError:%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash deploy_amnezia_warp_host.sh
  sudo bash deploy_amnezia_warp_host.sh install [all|legacy|current|xray]
  sudo AUTO_YES=1 bash deploy_amnezia_warp_host.sh
  sudo bash deploy_amnezia_warp_host.sh uninstall [all|legacy|current|xray|warp]
  sudo bash deploy_amnezia_warp_host.sh status

Environment overrides:
  WARP_IF=wgcf
  WARP_PROFILE_NAME=wgcf
  WAN_IF=eth0
  AUTO_YES=1
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

have_iface() {
  ip link show "$1" >/dev/null 2>&1
}

first_ipv4_on_iface() {
  ip -4 -o addr show dev "$1" | awk 'NR==1 {print $4}'
}

first_ipv4_ip_on_iface() {
  ip -4 -o addr show dev "$1" | awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

first_global_ipv6_on_iface() {
  ip -6 -o addr show dev "$1" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

cidr_to_network() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

get_container_ipv4s() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

get_container_ipv4s_csv() {
  local name="$1"
  local ips
  ips="$(get_container_ipv4s "${name}" | paste -sd',' -)"
  [[ -n "${ips}" ]] || die "could not determine IPv4s for container ${name}"
  printf '%s\n' "${ips}"
}

get_container_ipv6s() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}} {{end}}' "$1" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E '^[0-9A-Fa-f:]+$' \
    | grep -v '^fe80:' || true
}

get_container_ipv6s_csv() {
  local name="$1"
  get_container_ipv6s "${name}" | sort -u | paste -sd',' -
}

awg_protocol_generation() {
  local name="$1"

  docker exec "${name}" sh -c '
    config=
    for candidate in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf; do
      if [ -f "$candidate" ]; then
        config="$candidate"
        break
      fi
    done
    [ -n "$config" ] || exit 1
    if grep -q "^[[:space:]]*HeaderProtectionKey[[:space:]]*=" "$config"; then
      printf "AWG 3.x"
    elif grep -Eq "^[[:space:]]*(S3|S4|I[1-5])[[:space:]]*=" "$config"; then
      printf "AWG 2.x"
    else
      printf "AWG 1.x"
    fi
  ' 2>/dev/null || true
}

awg_tools_version() {
  docker exec "$1" sh -c 'awg --version 2>/dev/null | head -n1' 2>/dev/null || true
}

awg_version_from_tools() {
  local tools_version="$1"
  if [[ "${tools_version}" =~ [Aa]mnezia[Ww][Gg]-tools[[:space:]]+v?([0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

awg_display_title() {
  local name="$1" fallback="$2" tools_version version generation
  tools_version="$(awg_tools_version "${name}")"
  version="$(awg_version_from_tools "${tools_version}")"
  if [[ -n "${version}" ]]; then
    printf 'AmneziaWG v%s\n' "${version}"
    return
  fi

  generation="$(awg_protocol_generation "${name}")"
  if [[ "${generation}" =~ ^AWG[[:space:]]+(.+)$ ]]; then
    printf 'AmneziaWG v%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "${fallback}"
  fi
}

awg_protocol_summary() {
  local name="$1"
  local generation tools_version

  generation="$(awg_protocol_generation "${name}")"
  tools_version="$(awg_tools_version "${name}")"

  if [[ -n "${generation}" && -n "${tools_version}" ]]; then
    printf '%s; %s\n' "${generation}" "${tools_version}"
  elif [[ -n "${generation}" ]]; then
    printf '%s\n' "${generation}"
  elif [[ -n "${tools_version}" ]]; then
    printf '%s\n' "${tools_version}"
  fi
}

find_best_container_ip() {
  local name="$1"
  local ip
  ip="$(get_container_ipv4s "$name" | grep '^172\.29\.' | head -n1 || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(get_container_ipv4s "$name" | head -n1 || true)"
  fi
  [[ -n "${ip}" ]] || return 1
  printf '%s\n' "${ip}"
}

find_interface_for_ip() {
  python3 - "$1" <<'PY'
import ipaddress, subprocess, sys
target = ipaddress.ip_address(sys.argv[1])
out = subprocess.check_output(["ip", "-4", "-o", "addr", "show", "scope", "global"], text=True)
for line in out.splitlines():
    parts = line.split()
    if len(parts) < 4:
        continue
    iface = parts[1]
    if iface == "lo" or iface.startswith("veth"):
        continue
    cidr = parts[3]
    net = ipaddress.ip_interface(cidr).network
    if target in net:
        print(f"{iface}|{net}|{ipaddress.ip_interface(cidr).ip}")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

backup_snapshot_paths() {
  cat <<EOF
/etc/amnezia-warp
/usr/local/sbin/amnezia-warp-routing.sh
/usr/local/sbin/amnezia-warp-reconcile.sh
/etc/systemd/system/amnezia-warp-routing@.service
/etc/systemd/system/amnezia-warp-reconcile.service
/etc/systemd/system/amnezia-warp-reconcile.timer
/etc/sysctl.d/99-amnezia-warp.conf
/etc/wireguard/${WARP_PROFILE_NAME}.conf
/etc/wireguard/wgcf-account.toml
/usr/local/bin/wgcf
EOF
}

service_enabled_bool() {
  if systemctl is-enabled "$1" >/dev/null 2>&1; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

service_active_bool() {
  if systemctl is-active --quiet "$1" 2>/dev/null; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

snapshot_copy_path() {
  local snapshot_dir="$1"
  local path="$2"
  local target="${snapshot_dir}/files${path}"
  if [[ -e "${path}" ]]; then
    mkdir -p "$(dirname "${target}")"
    cp -a "${path}" "${target}"
  fi
}

create_backup_snapshot() {
  local step="$1"
  local ts snapshot_dir suffix
  ts="$(date +%Y%m%d-%H%M%S)"
  suffix="${step//[^a-zA-Z0-9._-]/-}"
  snapshot_dir="${BACKUP_ROOT}/${ts}-${suffix}"

  mkdir -p "${snapshot_dir}/files"
  while read -r path; do
    [[ -n "${path}" ]] || continue
    snapshot_copy_path "${snapshot_dir}" "${path}"
  done < <(backup_snapshot_paths)

  cat > "${snapshot_dir}/state.env" <<EOF
SNAPSHOT_STEP='${step}'
SNAPSHOT_TIMESTAMP='${ts}'
BASE_TABLE='${BASE_TABLE}'
WARP_PROFILE_NAME='${WARP_PROFILE_NAME}'
WG_QUICK_ENABLED='$(service_enabled_bool "wg-quick@${WARP_PROFILE_NAME}.service")'
WG_QUICK_ACTIVE='$(service_active_bool "wg-quick@${WARP_PROFILE_NAME}.service")'
ROUTING_LEGACY_ENABLED='$(service_enabled_bool "amnezia-warp-routing@legacy.service")'
ROUTING_LEGACY_ACTIVE='$(service_active_bool "amnezia-warp-routing@legacy.service")'
ROUTING_V2_ENABLED='$(service_enabled_bool "amnezia-warp-routing@v2.service")'
ROUTING_V2_ACTIVE='$(service_active_bool "amnezia-warp-routing@v2.service")'
ROUTING_XRAY_ENABLED='$(service_enabled_bool "amnezia-warp-routing@xray.service")'
ROUTING_XRAY_ACTIVE='$(service_active_bool "amnezia-warp-routing@xray.service")'
RECONCILE_TIMER_ENABLED='$(service_enabled_bool "amnezia-warp-reconcile.timer")'
RECONCILE_TIMER_ACTIVE='$(service_active_bool "amnezia-warp-reconcile.timer")'
EOF

  ip rule show > "${snapshot_dir}/ip-rule.txt" 2>/dev/null || true
  ip route show table "${BASE_TABLE}" > "${snapshot_dir}/route-table.txt" 2>/dev/null || true
  iptables-save -t mangle > "${snapshot_dir}/iptables-mangle.txt" 2>/dev/null || true
  ip -6 rule show > "${snapshot_dir}/ip6-rule.txt" 2>/dev/null || true
  ip -6 route show table "${BASE_TABLE}" > "${snapshot_dir}/route6-table.txt" 2>/dev/null || true
  ip6tables-save -t mangle > "${snapshot_dir}/ip6tables-mangle.txt" 2>/dev/null || true
  ip6tables-save -t nat > "${snapshot_dir}/ip6tables-nat.txt" 2>/dev/null || true

  ok "Created backup snapshot: $(basename "${snapshot_dir}")"
}

list_backup_snapshots() {
  [[ -d "${BACKUP_ROOT}" ]] || return 0
  find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort -r
}

managed_path_remove_or_restore() {
  local snapshot_dir="$1"
  local path="$2"
  local source="${snapshot_dir}/files${path}"
  rm -rf "${path}"
  if [[ -e "${source}" ]]; then
    mkdir -p "$(dirname "${path}")"
    cp -a "${source}" "${path}"
  fi
}

restore_service_state() {
  local service_name="$1"
  local enabled="$2"
  local active="$3"

  if [[ "${enabled}" == "1" ]]; then
    systemctl enable "${service_name}" >/dev/null 2>&1 || true
  else
    systemctl disable "${service_name}" >/dev/null 2>&1 || true
  fi

  if [[ "${active}" == "1" ]]; then
    systemctl restart "${service_name}"
  else
    systemctl stop "${service_name}" >/dev/null 2>&1 || true
  fi
}

restore_backup_snapshot() {
  local snapshot_dir="$1"
  local path
  [[ -d "${snapshot_dir}" ]] || die "backup snapshot not found: ${snapshot_dir}"
  [[ -f "${snapshot_dir}/state.env" ]] || die "backup snapshot is missing state.env: ${snapshot_dir}"

  # shellcheck disable=SC1090
  . "${snapshot_dir}/state.env"

  disable_container_service legacy
  disable_container_service v2
  disable_container_service xray
  systemctl stop "wg-quick@${WARP_PROFILE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "wg-quick@${WARP_PROFILE_NAME}.service" >/dev/null 2>&1 || true

  while read -r path; do
    [[ -n "${path}" ]] || continue
    managed_path_remove_or_restore "${snapshot_dir}" "${path}"
  done < <(backup_snapshot_paths)

  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true

  restore_service_state "wg-quick@${WARP_PROFILE_NAME}.service" "${WG_QUICK_ENABLED}" "${WG_QUICK_ACTIVE}"
  restore_service_state "amnezia-warp-routing@legacy.service" "${ROUTING_LEGACY_ENABLED}" "${ROUTING_LEGACY_ACTIVE}"
  restore_service_state "amnezia-warp-routing@v2.service" "${ROUTING_V2_ENABLED}" "${ROUTING_V2_ACTIVE}"
  restore_service_state "amnezia-warp-routing@xray.service" "${ROUTING_XRAY_ENABLED}" "${ROUTING_XRAY_ACTIVE}"
  restore_service_state "amnezia-warp-reconcile.timer" "${RECONCILE_TIMER_ENABLED:-0}" "${RECONCILE_TIMER_ACTIVE:-0}"

  log
  ok "Rollback completed from snapshot: $(basename "${snapshot_dir}")"
}

choose_backup_snapshot() {
  local options=()
  local snapshots=()
  local idx

  while read -r snapshot; do
    [[ -n "${snapshot}" ]] || continue
    snapshots+=("${snapshot}")
    options+=("$(basename "${snapshot}")")
  done < <(list_backup_snapshots)

  if [[ "${#snapshots[@]}" -eq 0 ]]; then
    warn "No backup snapshots found in ${BACKUP_ROOT}"
    ROLLBACK_SNAPSHOT=""
    return 1
  fi

  prompt_menu_choice "Choose a backup snapshot to restore: " "${options[@]}"
  for ((idx=0; idx<${#options[@]}; idx++)); do
    if [[ "${options[$idx]}" == "${MENU_SELECTION}" ]]; then
      ROLLBACK_SNAPSHOT="${snapshots[$idx]}"
      return 0
    fi
  done
  die "backup selection resolution failed"
}

detect_containers() {
  local name ip ipv6s
  CONTAINERS_FOUND=()
  CONTAINER_SRC_IP=()
  CONTAINER_SRC_IPV6=()
  for name in amnezia-awg amnezia-awg2 amnezia-xray; do
    if docker inspect "$name" >/dev/null 2>&1; then
      ip="$(find_best_container_ip "$name" || true)"
      if [[ -z "${ip}" ]]; then
        warn "Container ${name} exists, but no IPv4 address was detected. Skipping it."
        continue
      fi
      ipv6s="$(get_container_ipv6s_csv "${name}")"
      CONTAINERS_FOUND+=("$name")
      CONTAINER_SRC_IP+=("${ip}")
      CONTAINER_SRC_IPV6+=("${ipv6s}")
    fi
  done
}

routing_service_state() {
  local suffix="$1"
  local service_name="amnezia-warp-routing@${suffix}.service"
  if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
    printf 'active\n'
    return
  fi
  if systemctl is-failed --quiet "${service_name}" 2>/dev/null; then
    printf 'failed\n'
    return
  fi
  if [[ -f "/etc/amnezia-warp/${suffix}.env" ]] || systemctl is-enabled "${service_name}" >/dev/null 2>&1; then
    printf 'installed\n'
    return
  fi
  printf 'not installed\n'
}

detect_warp_if() {
  local ifname summary
  local candidates=()
  local verified=()
  local options=()
  local labels=()
  if [[ -n "${WARP_IF}" ]]; then
    have_iface "${WARP_IF}" || die "WARP interface not found: ${WARP_IF}"
    return
  fi

  while read -r ifname; do
    [[ -n "${ifname}" ]] || continue
    if [[ "${ifname}" == "warp" || "${ifname}" == wg* ]]; then
      candidates+=("${ifname}")
    fi
  done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    return
  fi

  for ifname in "${candidates[@]}"; do
    summary="$(warp_trace_summary_for_iface "${ifname}")"
    if [[ "${summary}" == warp=on* ]]; then
      verified+=("${ifname}")
      labels+=("${ifname}")
      options+=("${ifname} (${summary})")
    fi
  done

  if [[ "${#verified[@]}" -eq 0 ]]; then
    return
  fi

  if [[ "${#verified[@]}" -eq 1 ]]; then
    WARP_IF="${verified[0]}"
    return
  fi

  if [[ "${AUTO_YES}" == "1" || ! -r /dev/tty ]]; then
    WARP_IF="${verified[0]}"
    warn "Multiple verified WARP interfaces found. Auto-selected ${WARP_IF}. Set WARP_IF=... to override."
    return
  fi

  warn "Multiple verified WARP interfaces found. Select the interface to use for host WARP routing:"
  prompt_menu_choice "Choose WARP interface: " "${options[@]}"
  local idx
  for ((idx=0; idx<${#options[@]}; idx++)); do
    if [[ "${options[$idx]}" == "${MENU_SELECTION}" ]]; then
      WARP_IF="${labels[$idx]}"
      return
    fi
  done
}

detect_warp_ipv6() {
  WARP_V6_IP=""
  if [[ -n "${WARP_IF:-}" ]] && have_iface "${WARP_IF}"; then
    WARP_V6_IP="$(first_global_ipv6_on_iface "${WARP_IF}")"
  fi
}

detect_wan() {
  local cidr cidr6
  if [[ -z "${WAN_IF}" ]]; then
    WAN_IF="$(ip route show default 0.0.0.0/0 | awk 'NR==1 {print $5}')"
  fi
  [[ -n "${WAN_IF}" ]] || die "could not determine WAN interface"
  have_iface "${WAN_IF}" || die "WAN interface not found: ${WAN_IF}"

  if [[ -z "${WAN_IP}" ]]; then
    WAN_IP="$(first_ipv4_ip_on_iface "${WAN_IF}")"
  fi
  [[ -n "${WAN_IP}" ]] || die "could not determine WAN IP"

  if [[ -z "${WAN_SUBNET}" ]]; then
    cidr="$(first_ipv4_on_iface "${WAN_IF}")"
    [[ -n "${cidr}" ]] || die "could not determine WAN subnet"
    WAN_SUBNET="$(cidr_to_network "${cidr}")"
  fi

  if [[ -z "${WAN_V6_IP}" ]]; then
    cidr6="$(ip -6 -o addr show dev "${WAN_IF}" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
    if [[ -n "${cidr6}" ]]; then
      WAN_V6_IP="${cidr6%/*}"
      WAN_V6_SUBNET="$(cidr_to_network "${cidr6}")"
    fi
  fi
}

detect_docker_bridges() {
  local line ifname cidr ip
  DOCKER_IFS=()
  DOCKER_SUBNETS=()
  DOCKER_IPS=()
  DOCKER_V6_IFS=()
  DOCKER_V6_SUBNETS=()
  DOCKER_V6_IPS=()

  while read -r line; do
    ifname="$(awk '{print $2}' <<<"${line}")"
    cidr="$(awk '{print $4}' <<<"${line}")"
    ip="${cidr%/*}"
    [[ "${ifname}" == "${WAN_IF}" || "${ifname}" == "${WARP_IF}" ]] && continue
    [[ "${ifname}" == "lo" ]] && continue
    [[ "${ifname}" == veth* ]] && continue
    [[ "${ifname}" == "docker0" || "${ifname}" == br-* ]] || continue
    DOCKER_IFS+=("${ifname}")
    DOCKER_SUBNETS+=("$(cidr_to_network "${cidr}")")
    DOCKER_IPS+=("${ip}")
  done < <(ip -4 -o addr show scope global)

  while read -r line; do
    ifname="$(awk '{print $2}' <<<"${line}")"
    cidr="$(awk '{print $4}' <<<"${line}")"
    ip="${cidr%/*}"
    [[ "${ifname}" == "${WAN_IF}" || "${ifname}" == "${WARP_IF}" ]] && continue
    [[ "${ifname}" == "lo" || "${ifname}" == veth* ]] && continue
    [[ "${ifname}" == "docker0" || "${ifname}" == br-* ]] || continue
    DOCKER_V6_IFS+=("${ifname}")
    DOCKER_V6_SUBNETS+=("$(cidr_to_network "${cidr}")")
    DOCKER_V6_IPS+=("${ip}")
  done < <(ip -6 -o addr show scope global 2>/dev/null)
}

ensure_amn_for_ip() {
  local ip="$1"
  local resolved

  if [[ -n "${AMN_IF}" && -n "${AMN_SUBNET}" && -n "${AMN_IP}" ]]; then
    return
  fi

  if have_iface amn0; then
    AMN_IF="amn0"
    AMN_IP="$(first_ipv4_ip_on_iface "${AMN_IF}")"
    AMN_SUBNET="$(cidr_to_network "$(first_ipv4_on_iface "${AMN_IF}")")"
    return
  fi

  resolved="$(find_interface_for_ip "${ip}")" || die "could not detect Amnezia bridge for ${ip}"
  AMN_IF="${resolved%%|*}"
  resolved="${resolved#*|}"
  AMN_SUBNET="${resolved%%|*}"
  AMN_IP="${resolved##*|}"
}

pkg_install() {
  local packages=()

  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v wget >/dev/null 2>&1 || packages+=("wget")
    command -v tar >/dev/null 2>&1 || packages+=("tar")
    command -v ip >/dev/null 2>&1 || packages+=("iproute2")
    command -v iptables >/dev/null 2>&1 || packages+=("iptables")
    command -v python3 >/dev/null 2>&1 || packages+=("python3")
    command -v docker >/dev/null 2>&1 || packages+=("docker.io")
    command -v wg >/dev/null 2>&1 || packages+=("wireguard-tools")
    if [[ "${#packages[@]}" -gt 0 ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    fi
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v wget >/dev/null 2>&1 || packages+=("wget")
    command -v tar >/dev/null 2>&1 || packages+=("tar")
    command -v ip >/dev/null 2>&1 || packages+=("iproute")
    command -v iptables >/dev/null 2>&1 || packages+=("iptables")
    command -v python3 >/dev/null 2>&1 || packages+=("python3")
    command -v docker >/dev/null 2>&1 || packages+=("docker")
    command -v wg >/dev/null 2>&1 || packages+=("wireguard-tools")
    if [[ "${#packages[@]}" -gt 0 ]]; then
      dnf install -y "${packages[@]}"
    fi
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v wget >/dev/null 2>&1 || packages+=("wget")
    command -v tar >/dev/null 2>&1 || packages+=("tar")
    command -v ip >/dev/null 2>&1 || packages+=("iproute")
    command -v iptables >/dev/null 2>&1 || packages+=("iptables")
    command -v python3 >/dev/null 2>&1 || packages+=("python3")
    command -v docker >/dev/null 2>&1 || packages+=("docker")
    command -v wg >/dev/null 2>&1 || packages+=("wireguard-tools")
    if [[ "${#packages[@]}" -gt 0 ]]; then
      yum install -y "${packages[@]}"
    fi
    return
  fi
  die "unsupported package manager for automatic WARP install"
}

install_wgcf_binary() {
  local arch release_json url tmpdir binpath
  if command -v wgcf >/dev/null 2>&1; then
    return
  fi

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv7" ;;
    *) die "unsupported architecture for wgcf: $(uname -m)" ;;
  esac

  release_json="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest)"
  url="$(RELEASE_JSON="${release_json}" python3 - "${arch}" <<'PY'
import json, os, sys
arch = sys.argv[1]
data = json.loads(os.environ["RELEASE_JSON"])
for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name.endswith(f"linux_{arch}") or f"linux_{arch}" in url:
        print(url)
        break
else:
    raise SystemExit(1)
PY
)"
  [[ -n "${url}" ]] || die "could not find wgcf release for ${arch}"

  tmpdir="$(mktemp -d)"
  binpath="${tmpdir}/wgcf"
  curl -fsSL "${url}" -o "${binpath}"
  install -m 0755 "${binpath}" /usr/local/bin/wgcf
  rm -rf "${tmpdir}"
}

normalize_warp_profile() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 0

  sed -i '/^DNS = /d' "${conf}"
  WARP_ENDPOINT_VALUE="${WARP_ENDPOINT}" python3 - "${conf}" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
endpoint = os.environ.get("WARP_ENDPOINT_VALUE", "").strip()
lines = path.read_text().splitlines()
out = []
in_interface = False
interface_has_table = False
in_peer = False
peer_has_endpoint = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_interface and not interface_has_table:
            out.append("Table = off")
        if in_peer and endpoint and not peer_has_endpoint:
            out.append(f"Endpoint = {endpoint}")
        in_interface = stripped == "[Interface]"
        interface_has_table = False
        in_peer = stripped == "[Peer]"
        peer_has_endpoint = False
        out.append(line)
        continue

    if in_interface and stripped.startswith("Table ="):
        if not interface_has_table:
            out.append("Table = off")
            interface_has_table = True
        continue

    if in_peer and stripped.startswith("Endpoint ="):
        if endpoint:
            out.append(f"Endpoint = {endpoint}")
        else:
            out.append(line)
        peer_has_endpoint = True
        continue

    out.append(line)

if in_interface and not interface_has_table:
    out.append("Table = off")
if in_peer and endpoint and not peer_has_endpoint:
    out.append(f"Endpoint = {endpoint}")

path.write_text("\n".join(out) + "\n")
PY
}

ensure_warp_profile() {
  local wgdir="/etc/wireguard"
  local conf="${wgdir}/${WARP_PROFILE_NAME}.conf"
  local account="${wgdir}/wgcf-account.toml"
  local legacy_account="${HOME}/wgcf-account.toml"
  local register_log

  mkdir -p /etc/wireguard
  chmod 700 "${wgdir}"

  if [[ ! -f "${account}" && -f "${legacy_account}" ]]; then
    mv "${legacy_account}" "${account}"
  fi

  if [[ ! -f "${account}" ]]; then
    register_log="$(
      cd "${wgdir}"
      (yes || true) | wgcf register >/dev/null 2>&1
    )"
  else
    register_log="$(
      cd "${wgdir}"
      ((yes || true) | wgcf register >/dev/null 2>&1) || true
    )"
    if [[ -n "${register_log}" ]] && ! grep -qi 'existing account detected' <<<"${register_log}"; then
      printf '%s\n' "${register_log}" >&2
      die "wgcf register failed"
    fi
  fi

  if [[ ! -f "${conf}" ]]; then
    rm -f "${wgdir}/wgcf-profile.conf"
    (
      cd "${wgdir}"
      wgcf generate >/dev/null
    )
    [[ -f "${wgdir}/wgcf-profile.conf" ]] || die "wgcf generate did not create wgcf-profile.conf"
    mv "${wgdir}/wgcf-profile.conf" "${conf}"
  fi

  normalize_warp_profile "${conf}"
}

refresh_managed_warp_profile() {
  local conf="/etc/wireguard/${WARP_PROFILE_NAME}.conf"
  [[ "${WARP_IF:-}" == "${WARP_PROFILE_NAME}" ]] || return 0
  [[ -f "${conf}" ]] || return 0
  normalize_warp_profile "${conf}"
  if systemctl is-active --quiet "wg-quick@${WARP_PROFILE_NAME}.service" 2>/dev/null; then
    systemctl restart "wg-quick@${WARP_PROFILE_NAME}.service"
  fi
}

install_host_warp() {
  local attempt
  pkg_install
  install_wgcf_binary
  ensure_warp_profile
  systemctl daemon-reload
  systemctl enable "wg-quick@${WARP_PROFILE_NAME}.service" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WARP_PROFILE_NAME}.service"
  WARP_IF="${WARP_PROFILE_NAME}"
  for attempt in 1 2 3 4 5; do
    if have_iface "${WARP_IF}"; then
      return
    fi
    sleep 1
  done
  die "WARP interface did not come up: ${WARP_IF}"
}

mark_for_container() {
  case "$1" in
    amnezia-awg) printf '0x61\n' ;;
    amnezia-awg2) printf '0x62\n' ;;
    amnezia-xray) printf '0x63\n' ;;
    *) printf '0x66\n' ;;
  esac
}

prio_for_container() {
  case "$1" in
    amnezia-awg) printf '10061\n' ;;
    amnezia-awg2) printf '10062\n' ;;
    amnezia-xray) printf '10063\n' ;;
    *) printf '10066\n' ;;
  esac
}

chain_for_container() {
  case "$1" in
    amnezia-awg) printf 'AMN_WARP_AWG\n' ;;
    amnezia-awg2) printf 'AMN_WARP_AWG2\n' ;;
    amnezia-xray) printf 'AMN_WARP_XRAY\n' ;;
    *) printf 'AMN_WARP_GENERIC\n' ;;
  esac
}

service_suffix() {
  case "$1" in
    amnezia-awg) printf 'legacy\n' ;;
    amnezia-awg2) printf 'v2\n' ;;
    amnezia-xray) printf 'xray\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

install_helper_template() {
  cat > /usr/local/sbin/amnezia-warp-routing.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-up}"
ENV_FILE="${2:-}"
[[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]] || {
  echo "usage: $0 [up|down] /path/to/envfile" >&2
  exit 1
}

set -a
. "${ENV_FILE}"
set +a

up_ipv6() {
  local triplet subnet iface ip src dst snat_chain
  local -a route_entries6 excludes6 srcs6
  [[ -n "${SRCS6:-}" ]] || return 0
  [[ -n "${WARP_IPV6:-}" ]] || {
    echo "IPv6 sources are configured, but ${WARP_IF} has no global IPv6 address" >&2
    return 1
  }
  command -v ip6tables >/dev/null 2>&1 || {
    echo "IPv6 sources are configured, but ip6tables is unavailable" >&2
    return 1
  }
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

  ip -6 route flush table "${TABLE}" 2>/dev/null || true
  IFS=';' read -r -a route_entries6 <<<"${ROUTES6:-}"
  for triplet in "${route_entries6[@]}"; do
    [[ -n "${triplet}" ]] || continue
    subnet="${triplet%%|*}"
    triplet="${triplet#*|}"
    iface="${triplet%%|*}"
    ip="${triplet##*|}"
    ip -6 route replace "${subnet}" dev "${iface}" src "${ip}" table "${TABLE}"
  done
  ip -6 route replace default dev "${WARP_IF}" table "${TABLE}"
  ip -6 rule del fwmark "${MARK}" lookup "${TABLE}" priority "${PRIO}" 2>/dev/null || true
  ip -6 rule add fwmark "${MARK}" lookup "${TABLE}" priority "${PRIO}"

  ip6tables -t mangle -N "${CHAIN}" 2>/dev/null || true
  ip6tables -t mangle -F "${CHAIN}"
  ip6tables -t mangle -D PREROUTING -m mark --mark "${MARK}" -j CONNMARK --save-mark 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -j "${CHAIN}" 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true
  ip6tables -t mangle -A PREROUTING -j CONNMARK --restore-mark
  ip6tables -t mangle -A PREROUTING -j "${CHAIN}"
  ip6tables -t mangle -A PREROUTING -m mark --mark "${MARK}" -j CONNMARK --save-mark

  IFS=' ' read -r -a excludes6 <<<"${EXCLUDES6:-::1/128 fc00::/7 fe80::/10}"
  IFS=',' read -r -a srcs6 <<<"${SRCS6}"
  for src in "${srcs6[@]}"; do
    [[ -n "${src}" ]] || continue
    for dst in "${excludes6[@]}"; do
      ip6tables -t mangle -A "${CHAIN}" -s "${src}" -d "${dst}" -j RETURN
    done
    ip6tables -t mangle -A "${CHAIN}" -s "${src}" -m conntrack --ctstate NEW -j MARK --set-mark "${MARK}"
  done

  snat_chain="${CHAIN}_SNAT"
  ip6tables -t nat -N "${snat_chain}" 2>/dev/null || true
  ip6tables -t nat -F "${snat_chain}"
  ip6tables -t nat -D POSTROUTING -j "${snat_chain}" 2>/dev/null || true
  ip6tables -t nat -I POSTROUTING 1 -j "${snat_chain}"
  for src in "${srcs6[@]}"; do
    [[ -n "${src}" ]] || continue
    ip6tables -t nat -A "${snat_chain}" -s "${src}" -o "${WARP_IF}" -j SNAT --to-source "${WARP_IPV6}"
  done
}

down_ipv6() {
  local snat_chain="${CHAIN}_SNAT"
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -t mangle -D PREROUTING -m mark --mark "${MARK}" -j CONNMARK --save-mark 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -j "${CHAIN}" 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true
  ip6tables -t mangle -F "${CHAIN}" 2>/dev/null || true
  ip6tables -t mangle -X "${CHAIN}" 2>/dev/null || true
  ip6tables -t nat -D POSTROUTING -j "${snat_chain}" 2>/dev/null || true
  ip6tables -t nat -F "${snat_chain}" 2>/dev/null || true
  ip6tables -t nat -X "${snat_chain}" 2>/dev/null || true
  ip -6 rule del fwmark "${MARK}" lookup "${TABLE}" priority "${PRIO}" 2>/dev/null || true
}

up() {
  local route triplet subnet iface ip src
  local -a route_entries excludes srcs

  modprobe br_netfilter || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null

  ip route flush table "${TABLE}" 2>/dev/null || true
  IFS=';' read -r -a route_entries <<<"${ROUTES}"
  for triplet in "${route_entries[@]}"; do
    [[ -n "${triplet}" ]] || continue
    subnet="${triplet%%|*}"
    triplet="${triplet#*|}"
    iface="${triplet%%|*}"
    ip="${triplet##*|}"
    ip route replace "${subnet}" dev "${iface}" src "${ip}" table "${TABLE}"
  done
  ip route replace default dev "${WARP_IF}" table "${TABLE}"

  ip rule del fwmark "${MARK}" lookup "${TABLE}" priority "${PRIO}" 2>/dev/null || true
  ip rule add fwmark "${MARK}" lookup "${TABLE}" priority "${PRIO}"

  iptables -t mangle -N "${CHAIN}" 2>/dev/null || true
  iptables -t mangle -F "${CHAIN}"
  iptables -t mangle -D PREROUTING -m mark --mark "${MARK}" -j CONNMARK --save-mark 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j "${CHAIN}" 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true

  iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
  iptables -t mangle -A PREROUTING -j "${CHAIN}"
  iptables -t mangle -A PREROUTING -m mark --mark "${MARK}" -j CONNMARK --save-mark

  IFS=' ' read -r -a excludes <<<"${EXCLUDES}"
  IFS=',' read -r -a srcs <<<"${SRCS:-${SRC}}"
  for src in "${srcs[@]}"; do
    [[ -n "${src}" ]] || continue
    for dst in "${excludes[@]}"; do
      iptables -t mangle -A "${CHAIN}" -s "${src}" -d "${dst}" -j RETURN
    done
    iptables -t mangle -A "${CHAIN}" -s "${src}" -m conntrack --ctstate NEW -j MARK --set-mark "${MARK}"
  done
  up_ipv6
}

down() {
  iptables -t mangle -D PREROUTING -m mark --mark "${MARK}" -j CONNMARK --save-mark 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j "${CHAIN}" 2>/dev/null || true
  iptables -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true
  iptables -t mangle -F "${CHAIN}" 2>/dev/null || true
  iptables -t mangle -X "${CHAIN}" 2>/dev/null || true
  ip rule del fwmark "${MARK}" lookup "${TABLE}" priority "${PRIO}" 2>/dev/null || true
  down_ipv6
}

case "${ACTION}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 [up|down] /path/to/envfile" >&2; exit 1 ;;
esac
EOF
  chmod 0755 /usr/local/sbin/amnezia-warp-routing.sh

  cat > /usr/local/sbin/amnezia-warp-reconcile.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="${1:-/etc/amnezia-warp}"
ROUTING_HELPER="${ROUTING_HELPER:-/usr/local/sbin/amnezia-warp-routing.sh}"

log() {
  printf '%s\n' "$*"
}

env_files() {
  local found=0 f
  [[ -d "${ENV_DIR}" ]] || return 0
  for f in "${ENV_DIR}"/*.env; do
    [[ -f "${f}" ]] || continue
    found=1
    printf '%s\n' "${f}"
  done
  [[ "${found}" == "1" ]]
}

rule_exists() {
  ip rule show 2>/dev/null | grep -F "fwmark ${MARK} " | grep -Fq " lookup ${TABLE}"
}

default_route_exists() {
  ip route show table "${TABLE}" 2>/dev/null | grep -Fq "default dev ${WARP_IF}"
}

chain_exists() {
  iptables -t mangle -S "${CHAIN}" >/dev/null 2>&1
}

prerouting_jump_exists() {
  iptables -t mangle -S PREROUTING 2>/dev/null | grep -Fq -- "-j ${CHAIN}"
}

mark_rule_exists() {
  iptables -t mangle -S "${CHAIN}" 2>/dev/null | grep -Fq -- "--set-xmark ${MARK}/"
}

ipv6_state_exists() {
  [[ -n "${SRCS6:-}" ]] || return 0
  ip -6 rule show 2>/dev/null | grep -F "fwmark ${MARK} " | grep -Fq " lookup ${TABLE}" || return 1
  ip -6 route show table "${TABLE}" 2>/dev/null | grep -Fq "default dev ${WARP_IF}" || return 1
  ip6tables -t mangle -S "${CHAIN}" >/dev/null 2>&1 || return 1
  ip6tables -t mangle -S PREROUTING 2>/dev/null | grep -Fq -- "-j ${CHAIN}" || return 1
  ip6tables -t mangle -S "${CHAIN}" 2>/dev/null | grep -Fq -- "--set-xmark ${MARK}/" || return 1
  ip6tables -t nat -S "${CHAIN}_SNAT" >/dev/null 2>&1 || return 1
}

container_for_env() {
  local env_file="$1"
  if [[ -n "${CONTAINER:-}" ]]; then
    printf '%s\n' "${CONTAINER}"
    return
  fi
  case "$(basename "${env_file}" .env)" in
    legacy) printf 'amnezia-awg\n' ;;
    v2) printf 'amnezia-awg2\n' ;;
    xray) printf 'amnezia-xray\n' ;;
    *) return 1 ;;
  esac
}

container_ipv4s() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -u || true
}

container_ipv6s() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}} {{end}}' "$1" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E '^[0-9A-Fa-f:]+$' \
    | grep -v '^fe80:' \
    | sort -u || true
}

update_env_sources() {
  local env_file="$1" container="$2" primary="$3" srcs="$4" srcs6="$5" tmp
  tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
  awk -v container="${container}" -v src="${primary}/32" -v srcs="${srcs}" -v srcs6="${srcs6}" '
    BEGIN { seen_container=0; seen_src=0; seen_srcs=0; seen_srcs6=0 }
    /^CONTAINER=/ { print "CONTAINER=" container; seen_container=1; next }
    /^SRC=/ { print "SRC=" src; seen_src=1; next }
    /^SRCS=/ { print "SRCS=" srcs; seen_srcs=1; next }
    /^SRCS6=/ { print "SRCS6=" srcs6; seen_srcs6=1; next }
    { print }
    END {
      if (!seen_container) print "CONTAINER=" container
      if (!seen_src) print "SRC=" src
      if (!seen_srcs) print "SRCS=" srcs
      if (!seen_srcs6) print "SRCS6=" srcs6
    }
  ' "${env_file}" > "${tmp}"
  chmod 0644 "${tmp}"
  mv "${tmp}" "${env_file}"
}

refresh_container_sources() {
  local env_file="$1" container current_list current_csv current_primary configured_csv current6_csv configured6_csv
  SOURCES_CHANGED=0
  container="$(container_for_env "${env_file}" || true)"
  [[ -n "${container}" ]] || return 0
  current_list="$(container_ipv4s "${container}")"
  [[ -n "${current_list}" ]] || return 0
  current_csv="$(printf '%s\n' "${current_list}" | paste -sd',' -)"
  current_primary="$(printf '%s\n' "${current_list}" | grep '^172\.29\.' | head -n1 || true)"
  [[ -n "${current_primary}" ]] || current_primary="$(printf '%s\n' "${current_list}" | head -n1)"
  configured_csv="$(printf '%s\n' "${SRCS:-${SRC%/32}}" | tr ',' '\n' | sed 's#/32$##' | sort -u | paste -sd',' -)"
  current6_csv="$(container_ipv6s "${container}" | paste -sd',' -)"
  configured6_csv="$(printf '%s\n' "${SRCS6:-}" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd',' -)"

  CONTAINER="${container}"
  if [[ "${configured_csv}" != "${current_csv}" || "${SRC:-}" != "${current_primary}/32" || "${configured6_csv}" != "${current6_csv}" ]]; then
    update_env_sources "${env_file}" "${container}" "${current_primary}" "${current_csv}" "${current6_csv}" || return 1
    SRC="${current_primary}/32"
    SRCS="${current_csv}"
    SRCS6="${current6_csv}"
    SOURCES_CHANGED=1
    log "Updated $(basename "${env_file}") for ${container}: IPv4=${current_csv} IPv6=${current6_csv:-none}"
  fi
}

needs_reconcile() {
  [[ "${SOURCES_CHANGED:-0}" == "1" ]] && return 0
  [[ -n "${TABLE:-}" && -n "${MARK:-}" && -n "${CHAIN:-}" && -n "${WARP_IF:-}" ]] || return 0
  ip link show "${WARP_IF}" >/dev/null 2>&1 || return 0
  rule_exists || return 0
  default_route_exists || return 0
  chain_exists || return 0
  prerouting_jump_exists || return 0
  mark_rule_exists || return 0
  ipv6_state_exists || return 0
  return 1
}

reconcile_env() {
  local env_file="$1"

  TABLE=
  MARK=
  PRIO=
  CHAIN=
  SRC=
  SRCS=
  SRCS6=
  CONTAINER=
  WARP_IF=
  WARP_IPV6=
  ROUTES=
  ROUTES6=
  EXCLUDES=
  EXCLUDES6=
  SOURCES_CHANGED=0

  set -a
  # shellcheck disable=SC1090
  . "${env_file}" || {
    set +a
    log "Could not read $(basename "${env_file}")"
    return 1
  }
  set +a

  refresh_container_sources "${env_file}" || return 1

  if [[ -z "${WARP_IF:-}" ]] || ! ip link show "${WARP_IF}" >/dev/null 2>&1; then
    log "Skipping $(basename "${env_file}"): WARP interface ${WARP_IF:-<unset>} is missing"
    return 0
  fi

  if needs_reconcile; then
    local suffix service_name
    suffix="$(basename "${env_file}" .env)"
    service_name="amnezia-warp-routing@${suffix}.service"
    log "Re-applying Amnezia WARP routing for $(basename "${env_file}")"
    if systemctl cat "${service_name}" >/dev/null 2>&1; then
      systemctl restart "${service_name}"
    else
      "${ROUTING_HELPER}" up "${env_file}"
    fi
  fi
}

main() {
  local env_file failed=0
  [[ -x "${ROUTING_HELPER}" ]] || exit 0
  while IFS= read -r env_file; do
    [[ -n "${env_file}" ]] || continue
    reconcile_env "${env_file}" || failed=1
  done < <(env_files || true)
  return "${failed}"
}

main "$@"
EOF
  chmod 0755 /usr/local/sbin/amnezia-warp-reconcile.sh

  cat > /etc/systemd/system/amnezia-warp-routing@.service <<'EOF'
[Unit]
Description=Route Amnezia container %i egress through host WARP
After=network-online.target docker.service wg-quick@WGCF_PROFILE.service
Wants=network-online.target docker.service wg-quick@WGCF_PROFILE.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/amnezia-warp/%i.env
ExecStart=/usr/local/sbin/amnezia-warp-routing.sh up /etc/amnezia-warp/%i.env
ExecStop=/usr/local/sbin/amnezia-warp-routing.sh down /etc/amnezia-warp/%i.env

[Install]
WantedBy=multi-user.target
EOF
  sed -i "s/WGCF_PROFILE/${WARP_PROFILE_NAME}/g" /etc/systemd/system/amnezia-warp-routing@.service

  cat > /etc/systemd/system/amnezia-warp-reconcile.service <<'EOF'
[Unit]
Description=Reconcile Amnezia WARP host routing runtime state
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/amnezia-warp-reconcile.sh /etc/amnezia-warp
EOF

  cat > /etc/systemd/system/amnezia-warp-reconcile.timer <<'EOF'
[Unit]
Description=Periodically reconcile Amnezia WARP host routing

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=15s
Unit=amnezia-warp-reconcile.service

[Install]
WantedBy=timers.target
EOF

  cat > /etc/sysctl.d/99-amnezia-warp.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
}

build_routes_string() {
  local routes=()
  local i
  routes+=("${WAN_SUBNET}|${WAN_IF}|${WAN_IP}")
  for ((i=0; i<${#DOCKER_IFS[@]}; i++)); do
    routes+=("${DOCKER_SUBNETS[$i]}|${DOCKER_IFS[$i]}|${DOCKER_IPS[$i]}")
  done
  routes+=("${AMN_SUBNET}|${AMN_IF}|${AMN_IP}")
  local IFS=';'
  printf '%s\n' "${routes[*]}"
}

build_routes6_string() {
  local routes=()
  local i cidr6 amn_v6_ip amn_v6_subnet
  if [[ -n "${WAN_V6_SUBNET}" && -n "${WAN_V6_IP}" ]]; then
    routes+=("${WAN_V6_SUBNET}|${WAN_IF}|${WAN_V6_IP}")
  fi
  for ((i=0; i<${#DOCKER_V6_IFS[@]}; i++)); do
    routes+=("${DOCKER_V6_SUBNETS[$i]}|${DOCKER_V6_IFS[$i]}|${DOCKER_V6_IPS[$i]}")
  done
  cidr6="$(ip -6 -o addr show dev "${AMN_IF}" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
  if [[ -n "${cidr6}" ]]; then
    amn_v6_ip="${cidr6%/*}"
    amn_v6_subnet="$(cidr_to_network "${cidr6}")"
    routes+=("${amn_v6_subnet}|${AMN_IF}|${amn_v6_ip}")
  fi
  local IFS=';'
  printf '%s\n' "${routes[*]}"
}

configure_container() {
  local name="$1"
  local src_ip="$2"
  local suffix mark prio chain env_file service_name routes routes6 excludes excludes6 srcs_csv srcs6_csv

  ensure_amn_for_ip "${src_ip}"
  suffix="$(service_suffix "${name}")"
  mark="$(mark_for_container "${name}")"
  prio="$(prio_for_container "${name}")"
  chain="$(chain_for_container "${name}")"
  routes="$(build_routes_string)"
  routes6="$(build_routes6_string)"
  srcs_csv="$(get_container_ipv4s_csv "${name}")"
  srcs6_csv="$(get_container_ipv6s_csv "${name}")"
  excludes="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ${WAN_SUBNET} 100.64.0.0/10"
  excludes6="::1/128 fc00::/7 fe80::/10"
  [[ -z "${WAN_V6_SUBNET}" ]] || excludes6+=" ${WAN_V6_SUBNET}"

  mkdir -p /etc/amnezia-warp
  env_file="/etc/amnezia-warp/${suffix}.env"
  service_name="amnezia-warp-routing@${suffix}.service"

  cat > "${env_file}" <<EOF
CONTAINER=${name}
TABLE=${BASE_TABLE}
MARK=${mark}
PRIO=${prio}
CHAIN=${chain}
SRC=${src_ip}/32
SRCS=${srcs_csv}
SRCS6=${srcs6_csv}
WARP_IF=${WARP_IF}
WARP_IPV6=${WARP_V6_IP}
ROUTES='${routes}'
ROUTES6='${routes6}'
EXCLUDES='${excludes}'
EXCLUDES6='${excludes6}'
EOF

  systemctl daemon-reload
  systemctl enable "${service_name}" >/dev/null 2>&1 || true
  systemctl restart "${service_name}"
  log "Configured ${name} via ${service_name}"
}

enable_reconcile_timer() {
  systemctl daemon-reload
  systemctl enable --now amnezia-warp-reconcile.timer >/dev/null 2>&1 || true
  systemctl start amnezia-warp-reconcile.service >/dev/null 2>&1 || true
}

container_ip_by_name() {
  local i
  for ((i=0; i<${#CONTAINERS_FOUND[@]}; i++)); do
    if [[ "${CONTAINERS_FOUND[$i]}" == "$1" ]]; then
      printf '%s\n' "${CONTAINER_SRC_IP[$i]}"
      return
    fi
  done
  return 1
}

container_ipv6s_by_name() {
  local i
  for ((i=0; i<${#CONTAINERS_FOUND[@]}; i++)); do
    if [[ "${CONTAINERS_FOUND[$i]}" == "$1" ]]; then
      printf '%s\n' "${CONTAINER_SRC_IPV6[$i]}"
      return
    fi
  done
  return 1
}

json_field_from_text() {
  local json_text="$1" key="$2"
  JSON_INPUT="${json_text}" python3 - "$key" <<'PY'
import json, os, sys
key = sys.argv[1]
raw = os.environ.get("JSON_INPUT", "")
if not raw:
    raise SystemExit(1)
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(1)
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

resolve_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}'
}

resolve_ipv6() {
  local host="$1"
  getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1 {print $1}'
}

container_http_probe_raw() {
  local name="$1" kind="$2"
  docker exec "$name" sh -lc "
if command -v curl >/dev/null 2>&1; then
  if [ '${kind}' = 'ipinfo' ]; then
    curl -fsSL --max-time 8 https://ipinfo.io
  else
    curl -fsSL --max-time 8 http://ip-api.com/json/
  fi
elif command -v wget >/dev/null 2>&1; then
  if [ '${kind}' = 'ipinfo' ]; then
    wget -qO- --timeout=8 https://ipinfo.io
  else
    wget -qO- --timeout=8 http://ip-api.com/json/
  fi
else
  exit 127
fi
" 2>/dev/null || true
}

container_http_probe() {
  local name="$1" kind="$2" pid ipinfo_ip ipapi_ip
  pid="$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || true)"
  ipinfo_ip="$(resolve_ipv4 ipinfo.io)"
  ipapi_ip="$(resolve_ipv4 ip-api.com)"

  if [[ "${kind}" == "ipinfo" ]]; then
    if [[ -n "${pid}" && "${pid}" != "0" && -n "${ipinfo_ip}" ]]; then
      if command -v nsenter >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        nsenter -t "${pid}" -n curl -4fsSL --max-time 8 --resolve "ipinfo.io:443:${ipinfo_ip}" https://ipinfo.io 2>/dev/null || true
        return
      fi
    fi
    container_http_probe_raw "${name}" "ipinfo"
    return
  fi

  if [[ "${kind}" == "ipapi" ]]; then
    if [[ -n "${pid}" && "${pid}" != "0" && -n "${ipapi_ip}" ]]; then
      if command -v nsenter >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        nsenter -t "${pid}" -n curl -4fsSL --max-time 8 -H "Host: ip-api.com" "http://${ipapi_ip}/json/" 2>/dev/null || true
        return
      fi
    fi
    container_http_probe_raw "${name}" "ipapi"
    return
  fi
}

container_egress_summary() {
  local name="$1" ipinfo_json ipapi_json egress_ip country city isp
  ipinfo_json="$(container_http_probe "${name}" 'ipinfo')"
  ipapi_json="$(container_http_probe "${name}" 'ipapi')"

  egress_ip="$(json_field_from_text "${ipinfo_json}" ip 2>/dev/null || true)"
  if [[ -z "${egress_ip}" ]]; then
    egress_ip="$(json_field_from_text "${ipapi_json}" query 2>/dev/null || true)"
  fi

  country="$(json_field_from_text "${ipapi_json}" country 2>/dev/null || true)"
  city="$(json_field_from_text "${ipapi_json}" city 2>/dev/null || true)"
  isp="$(json_field_from_text "${ipapi_json}" isp 2>/dev/null || true)"

  if [[ -z "${egress_ip}${country}${city}${isp}" ]]; then
    printf 'unavailable\n'
    return
  fi

  [[ -n "${egress_ip}" ]] || egress_ip="unknown"
  [[ -n "${country}" ]] || country="unknown"
  [[ -n "${city}" ]] || city="unknown"
  [[ -n "${isp}" ]] || isp="unknown"
  printf '%s | %s | %s | %s\n' "${egress_ip}" "${country}" "${city}" "${isp}"
}

container_ipv6_egress_summary() {
  local name="$1" pid target trace warp_value ip_value loc_value
  pid="$(docker inspect -f '{{.State.Pid}}' "${name}" 2>/dev/null || true)"
  target="$(resolve_ipv6 www.cloudflare.com)"
  if [[ -n "${pid}" && "${pid}" != "0" && -n "${target}" ]] \
    && command -v nsenter >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    trace="$(nsenter -t "${pid}" -n curl -6fsSL --max-time 8 \
      --resolve "www.cloudflare.com:443:${target}" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  else
    trace="$(docker exec "${name}" sh -lc 'curl -6fsSL --max-time 8 https://www.cloudflare.com/cdn-cgi/trace' 2>/dev/null || true)"
  fi
  [[ -n "${trace}" ]] || { printf 'unavailable\n'; return; }
  warp_value="$(printf '%s\n' "${trace}" | awk -F= '$1=="warp" {print $2; exit}')"
  ip_value="$(printf '%s\n' "${trace}" | awk -F= '$1=="ip" {print $2; exit}')"
  loc_value="$(printf '%s\n' "${trace}" | awk -F= '$1=="loc" {print $2; exit}')"
  printf 'warp=%s | %s | %s\n' "${warp_value:-unknown}" "${ip_value:-unknown}" "${loc_value:-unknown}"
}

show_container_block() {
  local title="$1" container_name="$2" suffix="$3" found_state service_state egress_summary ipv6_egress_summary current_ip current_ipv6s configured_src configured_srcs current_ips_csv protocol_summary
  found_state="not found"
  if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx "${container_name}"; then
    found_state="found"
  fi

  log "  ${title}: $(state_text "${found_state}")"
  if [[ "${found_state}" == "found" ]]; then
    service_state="$(routing_service_state "${suffix}")"
    current_ip="$(container_ip_by_name "${container_name}")"
    current_ips_csv="$(get_container_ipv4s_csv "${container_name}")"
    current_ipv6s="$(get_container_ipv6s_csv "${container_name}")"
    log "    container IP: ${current_ip}"
    if [[ -n "${current_ipv6s}" ]]; then
      log "    container IPv6: ${current_ipv6s}"
    else
      log "    container IPv6: not available"
    fi
    if [[ "${container_name}" == amnezia-awg* ]]; then
      protocol_summary="$(awg_protocol_summary "${container_name}")"
      [[ -n "${protocol_summary}" ]] && log "    protocol: ${protocol_summary}"
    fi
    log "    routing service: $(state_text "${service_state}")"
    configured_src="$(service_src_from_env "${suffix}" || true)"
    configured_srcs="$(service_srcs_from_env "${suffix}" || true)"
    if [[ -n "${configured_srcs}" ]]; then
      if [[ ",${configured_srcs}," != *",${current_ip},"* ]]; then
        warn "    configured SRCS mismatch: env uses ${configured_srcs}, container now has ${current_ips_csv}"
      fi
    elif [[ -n "${configured_src}" && -n "${current_ip}" && "${configured_src}" != "${current_ip}" ]]; then
      warn "    configured SRC mismatch: env uses ${configured_src}, container is ${current_ip}"
    fi
    if [[ "${service_state}" == "active" ]]; then
      egress_summary="$(container_egress_summary "${container_name}")"
      if [[ "${egress_summary}" == "unavailable" ]]; then
        log "    egress probe: unavailable (checked with curl/wget to ipinfo.io and ip-api.com)"
      else
        log "    egress IP: ${egress_summary}"
      fi
      if [[ -n "${current_ipv6s}" ]]; then
        ipv6_egress_summary="$(container_ipv6_egress_summary "${container_name}")"
        log "    egress IPv6: ${ipv6_egress_summary}"
      fi
    fi
  fi
}

menu_header() {
  local warp_status legacy_status v2_status xray_status current_awg_title
  legacy_status="not found"
  v2_status="not found"
  xray_status="not found"
  WARP_IF="${WARP_IF:-}"
  detect_warp_if || true
  detect_warp_ipv6
  detect_wan || true

  if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg'; then
    legacy_status="found"
  fi
  if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg2'; then
    v2_status="found"
  fi
  if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-xray'; then
    xray_status="found"
  fi
  if [[ -n "${WARP_IF}" ]]; then
    warp_status="found (${WARP_IF})"
  else
    warp_status="not found"
  fi

  printf '%s%sAmnezia WARP Host Routing%s\n' "${C_BOLD}" "${C_BLUE}" "${C_RESET}"
  log
  printf '%sEnvironment%s\n' "${C_BOLD}" "${C_RESET}"
  log "  WAN interface: ${WAN_IF:-unknown}"
  log "  WAN IP: ${WAN_IP:-unknown}"
  log "  WAN subnet: ${WAN_SUBNET:-unknown}"
  log "  WARP interface: ${WARP_IF:-not found}"
  log "  WARP IPv6: ${WARP_V6_IP:-not available}"
  log "  Amnezia bridge: ${AMN_IF:-auto}"
  log
  printf '%sContainers%s\n' "${C_BOLD}" "${C_RESET}"
  show_container_block "AmneziaWG Legacy" "amnezia-awg" "legacy"
  current_awg_title="$(awg_display_title "amnezia-awg2" "AmneziaWG Current (2.x/3.x)")"
  show_container_block "${current_awg_title}" "amnezia-awg2" "v2"
  show_container_block "Amnezia Xray" "amnezia-xray" "xray"
  log "  Host WARP: $(state_text "${warp_status}")"
  printf '\n'
}

service_exists() {
  local suffix="${1#amnezia-warp-routing@}"
  suffix="${suffix%.service}"
  [[ -f "/etc/amnezia-warp/${suffix}.env" ]] || systemctl is-enabled "$1" >/dev/null 2>&1
}

service_src_from_env() {
  local suffix="$1"
  local env_file="/etc/amnezia-warp/${suffix}.env"
  [[ -f "${env_file}" ]] || return 1
  awk -F= '$1=="SRC" {print $2}' "${env_file}" 2>/dev/null | sed 's#/32$##' | head -n1
}

service_srcs_from_env() {
  local suffix="$1"
  local env_file="/etc/amnezia-warp/${suffix}.env"
  [[ -f "${env_file}" ]] || return 1
  awk -F= '$1=="SRCS" {print $2}' "${env_file}" 2>/dev/null | head -n1
}

configured_service_names() {
  local names=()
  if [[ -f /etc/amnezia-warp/legacy.env ]] || service_exists "amnezia-warp-routing@legacy.service"; then
    names+=("legacy")
  fi
  if [[ -f /etc/amnezia-warp/v2.env ]] || service_exists "amnezia-warp-routing@v2.service"; then
    names+=("v2")
  fi
  if [[ -f /etc/amnezia-warp/xray.env ]] || service_exists "amnezia-warp-routing@xray.service"; then
    names+=("xray")
  fi
  printf '%s\n' "${names[@]}"
}

disable_container_service() {
  local suffix="$1"
  local service_name="amnezia-warp-routing@${suffix}.service"
  systemctl disable --now "${service_name}" >/dev/null 2>&1 || true
  systemctl stop "${service_name}" >/dev/null 2>&1 || true
  rm -f "/etc/amnezia-warp/${suffix}.env"
}

cleanup_shared_files() {
  local remaining
  remaining="$(find /etc/amnezia-warp -maxdepth 1 -type f -name '*.env' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${remaining}" == "0" ]]; then
    systemctl disable --now amnezia-warp-reconcile.timer >/dev/null 2>&1 || true
    systemctl stop amnezia-warp-reconcile.service >/dev/null 2>&1 || true
    rm -rf /etc/amnezia-warp
    rm -f /usr/local/sbin/amnezia-warp-routing.sh
    rm -f /usr/local/sbin/amnezia-warp-reconcile.sh
    rm -f /etc/systemd/system/amnezia-warp-routing@.service
    rm -f /etc/systemd/system/amnezia-warp-reconcile.service
    rm -f /etc/systemd/system/amnezia-warp-reconcile.timer
    rm -f /etc/sysctl.d/99-amnezia-warp.conf
    systemctl daemon-reload
  fi
}

uninstall_host_warp() {
  local other_suffixes
  other_suffixes="$(configured_service_names | tr '\n' ' ' | xargs 2>/dev/null || true)"
  if [[ -n "${other_suffixes}" ]]; then
    warn "Host-level WARP was left in place because other routed containers still exist."
    return
  fi

  if systemctl list-unit-files "wg-quick@${WARP_PROFILE_NAME}.service" --no-legend 2>/dev/null | grep -q "^wg-quick@${WARP_PROFILE_NAME}\.service"; then
    systemctl stop "wg-quick@${WARP_PROFILE_NAME}.service" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@${WARP_PROFILE_NAME}.service" >/dev/null 2>&1 || true
  fi
  have_iface "${WARP_PROFILE_NAME}" && ip link delete "${WARP_PROFILE_NAME}" >/dev/null 2>&1 || true
  rm -f "/etc/wireguard/${WARP_PROFILE_NAME}.conf"
  rm -f "/etc/wireguard/wgcf-account.toml"
  rm -f /usr/local/bin/wgcf
}

uninstall_selection() {
  local selection="$1"

  case "${selection}" in
    all)
      disable_container_service legacy
      disable_container_service v2
      disable_container_service xray
      cleanup_shared_files
      uninstall_host_warp
      ;;
    legacy)
      disable_container_service legacy
      cleanup_shared_files
      uninstall_host_warp
      ;;
    v2)
      disable_container_service v2
      cleanup_shared_files
      uninstall_host_warp
      ;;
    xray)
      disable_container_service xray
      cleanup_shared_files
      uninstall_host_warp
      ;;
    *)
      die "unknown uninstall selection: ${selection}"
      ;;
  esac

  log
  ok "Removal completed."
}

run_uninstall() {
  local selection="$1"
  case "${selection}" in
    all|legacy|v2|xray)
      uninstall_selection "${selection}"
      ;;
    warp-only)
      cleanup_shared_files
      uninstall_host_warp
      log
      ok "Removal completed."
      ;;
    exit)
      log "No changes made."
      ;;
    *)
      die "unknown uninstall selection: ${selection}"
      ;;
  esac
}

cleanup_stale_container_routing() {
  local name suffix found
  for name in amnezia-awg amnezia-awg2 amnezia-xray; do
    found="0"
    if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx "${name}"; then
      found="1"
    fi
    [[ "${found}" == "0" ]] || continue

    suffix="$(service_suffix "${name}")"
    if [[ -f "/etc/amnezia-warp/${suffix}.env" ]] || service_exists "amnezia-warp-routing@${suffix}.service"; then
      warn "Removing stale routing for ${name}; container is missing or has no IPv4 address."
      disable_container_service "${suffix}"
    fi
  done
  cleanup_shared_files
}

show_status() {
  local suffix backup_count latest_backup warp_verify
  menu_header
  if systemctl is-active --quiet "wg-quick@${WARP_PROFILE_NAME}.service" 2>/dev/null; then
    if [[ -n "${WARP_IF}" ]] && have_iface "${WARP_IF}"; then
      log "Host WARP service: $(state_text "active") (wg-quick@${WARP_PROFILE_NAME}.service)"
    else
      log "Host WARP service: $(state_text "installed") but link is missing (wg-quick@${WARP_PROFILE_NAME}.service)"
      warn "  Hint: run uninstall once to clean the stale WARP unit, then install again."
    fi
  else
    log "Host WARP service: $(state_text "$(host_warp_unit_state)")"
  fi
  for suffix in legacy v2 xray; do
    if systemctl is-active --quiet "amnezia-warp-routing@${suffix}.service" 2>/dev/null; then
      log "Routing service ${suffix}: $(state_text "active")"
    elif systemctl is-failed --quiet "amnezia-warp-routing@${suffix}.service" 2>/dev/null; then
      log "Routing service ${suffix}: $(state_text "failed")"
    elif systemctl list-unit-files "amnezia-warp-routing@${suffix}.service" --no-legend 2>/dev/null | grep -q "^amnezia-warp-routing@${suffix}\.service"; then
      log "Routing service ${suffix}: $(state_text "installed") but inactive"
    fi
  done
  if systemctl is-active --quiet amnezia-warp-reconcile.timer 2>/dev/null; then
    log "Reconcile timer: $(state_text "active")"
  elif systemctl list-unit-files amnezia-warp-reconcile.timer --no-legend 2>/dev/null | grep -q '^amnezia-warp-reconcile\.timer'; then
    log "Reconcile timer: $(state_text "installed") but inactive"
  fi
  log
  printf '%sDebug%s\n' "${C_BOLD}" "${C_RESET}"
  log "  Kernel: $(uname -r)"
  log "  Hostname: $(hostname)"
  log "  Docker version: $(docker --version 2>/dev/null || echo unknown)"
  log "  Default route: $(ip route show default 2>/dev/null | head -n1 || echo unknown)"
  if [[ -n "${WARP_IF}" ]] && have_iface "${WARP_IF}"; then
    log "  WARP link: $(ip -brief link show "${WARP_IF}" 2>/dev/null | tr -s ' ' || echo unknown)"
  else
    log "  WARP link: not present"
  fi
  log "  WARP unit state: $(state_text "$(host_warp_unit_state)")"
  warp_verify="$(warp_trace_summary)"
  log "  WARP trace check: ${warp_verify}"
  if [[ -d /etc/amnezia-warp ]]; then
    log "  Env files:"
    find /etc/amnezia-warp -maxdepth 1 -type f -name '*.env' -printf '    %f\n' 2>/dev/null || true
  fi
  backup_count="$(list_backup_snapshots | wc -l | tr -d ' ')"
  latest_backup="$(list_backup_snapshots | head -n1 | xargs -r basename)"
  log "  Backup snapshots: ${backup_count:-0}"
  if [[ -n "${latest_backup}" ]]; then
    log "  Latest backup: ${latest_backup}"
  fi
  log "  Policy rules:"
  ip rule show 2>/dev/null | grep -E '10061|10062|10063|10066' | sed 's/^/    /' || log "    none"
  log "  IPv6 policy rules:"
  ip -6 rule show 2>/dev/null | grep -E '10061|10062|10063|10066' | sed 's/^/    /' || log "    none"
  log "  Routing table ${BASE_TABLE}:"
  ip route show table "${BASE_TABLE}" 2>/dev/null | sed 's/^/    /' || log "    empty"
  log "  IPv6 routing table ${BASE_TABLE}:"
  ip -6 route show table "${BASE_TABLE}" 2>/dev/null | sed 's/^/    /' || log "    empty"
}

prompt_menu_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local idx choice

  for ((idx=0; idx<${#options[@]}; idx++)); do
    printf '%s%d)%s %s\n' "${C_BOLD}" "$((idx + 1))" "${C_RESET}" "${options[$idx]}"
  done

  while true; do
    printf '%s' "${prompt}"
    if [[ -r /dev/tty ]]; then
      IFS= read -r choice </dev/tty
    else
      IFS= read -r choice
    fi
    [[ "${choice}" =~ ^[0-9]+$ ]] || {
      warn "Please enter a number from the menu."
      continue
    }
    if (( choice >= 1 && choice <= ${#options[@]} )); then
      MENU_SELECTION="${options[$((choice - 1))]}"
      return
    fi
    warn "Please choose one of the listed actions."
  done
}

choose_main_action() {
  local options=()
  local labels=()
  local configured=()
  local suffix current_awg_title

  current_awg_title="$(awg_display_title "amnezia-awg2" "current AWG (2.x/3.x)")"

  while read -r suffix; do
    [[ -n "${suffix}" ]] && configured+=("${suffix}")
  done < <(configured_service_names)

  if [[ "${#CONTAINERS_FOUND[@]}" -gt 0 ]]; then
    labels+=("install:all")
    options+=("Install WARP and route all detected containers")
    if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg'; then
      labels+=("install:legacy")
      options+=("Install or refresh routing for AWG Legacy only")
    fi
    if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg2'; then
      labels+=("install:v2")
      options+=("Install or refresh routing for ${current_awg_title} only")
    fi
    if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-xray'; then
      labels+=("install:xray")
      options+=("Install or refresh routing for Amnezia Xray only")
    fi
  fi
  if [[ "${#configured[@]}" -gt 0 ]]; then
    labels+=("remove:all")
    options+=("Remove everything configured by this script")
    if printf '%s\n' "${configured[@]}" | grep -qx 'legacy'; then
      labels+=("remove:legacy")
      options+=("Remove AWG Legacy routing")
    fi
    if printf '%s\n' "${configured[@]}" | grep -qx 'v2'; then
      labels+=("remove:v2")
      options+=("Remove ${current_awg_title} routing")
    fi
    if printf '%s\n' "${configured[@]}" | grep -qx 'xray'; then
      labels+=("remove:xray")
      options+=("Remove Amnezia Xray routing")
    fi
  elif [[ -n "${WARP_IF}" ]]; then
    labels+=("remove:warp-only")
    options+=("Remove host-level WARP only")
  fi
  if list_backup_snapshots | grep -q .; then
    labels+=("rollback")
    options+=("Rollback to a backup snapshot")
  fi
  labels+=("status")
  options+=("Show status")
  labels+=("exit")
  options+=("Exit")

  local idx
  prompt_menu_choice "Choose an action: " "${options[@]}"
  for ((idx=0; idx<${#options[@]}; idx++)); do
    if [[ "${options[$idx]}" == "${MENU_SELECTION}" ]]; then
      MENU_ACTION="${labels[$idx]}"
      return
    fi
  done
  die "menu selection resolution failed"
}

run_selection() {
  local selection="$1" current_awg_title
  current_awg_title="$(awg_display_title "amnezia-awg2" "AmneziaWG Current (2.x/3.x)")"
  detect_wan
  detect_docker_bridges
  create_backup_snapshot "pre-install-helper-template"
  install_helper_template

  if [[ -z "${WARP_IF}" ]]; then
    warn "Host-level WARP was not found. Bootstrapping it with wgcf."
    create_backup_snapshot "pre-install-host-warp"
    install_host_warp
    detect_warp_if || true
  fi
  detect_warp_ipv6
  refresh_managed_warp_profile

  case "${selection}" in
    all)
      cleanup_stale_container_routing
      if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg'; then
        create_backup_snapshot "pre-configure-amnezia-awg"
        configure_container "amnezia-awg" "$(container_ip_by_name amnezia-awg)"
      fi
      if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg2'; then
        create_backup_snapshot "pre-configure-amnezia-awg2"
        configure_container "amnezia-awg2" "$(container_ip_by_name amnezia-awg2)"
      fi
      if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-xray'; then
        create_backup_snapshot "pre-configure-amnezia-xray"
        configure_container "amnezia-xray" "$(container_ip_by_name amnezia-xray)"
      fi
      ;;
    legacy)
      create_backup_snapshot "pre-configure-amnezia-awg"
      configure_container "amnezia-awg" "$(container_ip_by_name amnezia-awg)"
      ;;
    v2)
      create_backup_snapshot "pre-configure-amnezia-awg2"
      configure_container "amnezia-awg2" "$(container_ip_by_name amnezia-awg2)"
      ;;
    xray)
      create_backup_snapshot "pre-configure-amnezia-xray"
      configure_container "amnezia-xray" "$(container_ip_by_name amnezia-xray)"
      ;;
    exit)
      log "No changes made."
      return
      ;;
    *)
      die "unknown selection: ${selection}"
      ;;
  esac

  enable_reconcile_timer

  log
  ok "Routing is configured."
  log "Post-check:"
  log "  Host WARP trace check: $(warp_trace_summary)"
  case "${selection}" in
    all)
      if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg'; then
        show_container_block "AmneziaWG Legacy" "amnezia-awg" "legacy"
      fi
      if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-awg2'; then
        show_container_block "${current_awg_title}" "amnezia-awg2" "v2"
      fi
      if printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx 'amnezia-xray'; then
        show_container_block "Amnezia Xray" "amnezia-xray" "xray"
      fi
      ;;
    legacy)
      show_container_block "AmneziaWG Legacy" "amnezia-awg" "legacy"
      ;;
    v2)
      show_container_block "${current_awg_title}" "amnezia-awg2" "v2"
      ;;
    xray)
      show_container_block "Amnezia Xray" "amnezia-xray" "xray"
      ;;
  esac
}

normalize_target() {
  local target="${1:-all}"
  case "${target}" in
    all) printf 'all\n' ;;
    legacy|awg-legacy) printf 'legacy\n' ;;
    current|awg|awg2|v2) printf 'v2\n' ;;
    xray) printf 'xray\n' ;;
    warp|warp-only) printf 'warp-only\n' ;;
    *) return 1 ;;
  esac
}

require_container_for_selection() {
  local selection="$1"
  local name
  case "${selection}" in
    all) return 0 ;;
    legacy) name="amnezia-awg" ;;
    v2) name="amnezia-awg2" ;;
    xray) name="amnezia-xray" ;;
    *) return 0 ;;
  esac
  printf '%s\n' "${CONTAINERS_FOUND[@]}" | grep -qx "${name}" \
    || die "container ${name} was not found or has no IPv4 address"
}

main() {
  case "${ACTION}" in
    -h|--help|help)
      usage
      return
      ;;
  esac

  require_root
  require_cmd ip
  require_cmd iptables
  require_cmd docker
  require_cmd python3
  require_cmd systemctl

  detect_containers
  if [[ "${ACTION}" == "install" ]]; then
    local selection
    selection="$(normalize_target "${TARGET:-all}")" || die "unknown install target: ${TARGET}"
    [[ "${selection}" != "warp-only" ]] || die "warp is not a valid install target"
    require_container_for_selection "${selection}"
    detect_warp_if || true
    run_selection "${selection}"
    return
  fi

  if [[ "${ACTION}" == "status" ]]; then
    [[ -z "${TARGET}" ]] || die "status does not accept a target"
    show_status
    return
  fi

  if [[ "${ACTION}" == "uninstall" ]]; then
    if [[ -n "${TARGET}" ]]; then
      local selection
      selection="$(normalize_target "${TARGET}")" || die "unknown uninstall target: ${TARGET}"
      detect_warp_if || true
      create_backup_snapshot "pre-uninstall-${selection}"
      run_uninstall "${selection}"
      return
    fi
    menu_header
    if [[ "${AUTO_YES}" == "1" ]]; then
      create_backup_snapshot "pre-uninstall-all"
      run_uninstall "all"
    else
      choose_main_action
      case "${MENU_ACTION}" in
        remove:*)
          create_backup_snapshot "pre-uninstall-${MENU_ACTION#remove:}"
          run_uninstall "${MENU_ACTION#remove:}"
          ;;
        status)
          show_status
          ;;
        exit)
          log "No changes made."
          ;;
        *)
          die "please choose a removal action when using uninstall mode"
          ;;
      esac
    fi
    return
  fi

  [[ -z "${ACTION}" ]] || die "unknown action: ${ACTION}"

  while true; do
    menu_header

    if [[ "${AUTO_YES}" == "1" ]]; then
      run_selection "all"
      return
    fi

    choose_main_action
    case "${MENU_ACTION}" in
      install:all) run_selection "all"; return ;;
      install:legacy) run_selection "legacy"; return ;;
      install:v2) run_selection "v2"; return ;;
      install:xray) run_selection "xray"; return ;;
      remove:all) create_backup_snapshot "pre-uninstall-all"; run_uninstall "all"; return ;;
      remove:legacy) create_backup_snapshot "pre-uninstall-legacy"; run_uninstall "legacy"; return ;;
      remove:v2) create_backup_snapshot "pre-uninstall-v2"; run_uninstall "v2"; return ;;
      remove:xray) create_backup_snapshot "pre-uninstall-xray"; run_uninstall "xray"; return ;;
      remove:warp-only) create_backup_snapshot "pre-uninstall-warp-only"; run_uninstall "warp-only"; return ;;
      rollback)
        if choose_backup_snapshot; then
          restore_backup_snapshot "${ROLLBACK_SNAPSHOT}"
        fi
        return
        ;;
      status) show_status ;;
      exit) log "No changes made."; return ;;
      *) die "unknown selection" ;;
    esac
  done
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
