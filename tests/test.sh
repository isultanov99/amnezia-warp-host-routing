#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy_amnezia_warp_host.sh
. "${ROOT_DIR}/deploy_amnezia_warp_host.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

test_non_warp_wireguard_is_ignored() {
  WARP_IF=""
  AUTO_YES=1
  ip() {
    printf '1: lo: <LOOPBACK>\n2: wg-home: <POINTOPOINT>\n'
  }
  warp_trace_summary_for_iface() {
    printf 'warp=off ip=203.0.113.10 loc=NL\n'
  }

  detect_warp_if
  assert_eq "" "${WARP_IF}" "ordinary WireGuard interface must not be treated as WARP"
  unset -f ip warp_trace_summary_for_iface
}

test_verified_warp_is_selected() {
  WARP_IF=""
  AUTO_YES=1
  ip() {
    printf '1: lo: <LOOPBACK>\n2: wg-home: <POINTOPOINT>\n3: wg-warp: <POINTOPOINT>\n'
  }
  warp_trace_summary_for_iface() {
    if [[ "$1" == "wg-warp" ]]; then
      printf 'warp=on ip=198.51.100.2 loc=AMS\n'
    else
      printf 'warp=off ip=203.0.113.10 loc=NL\n'
    fi
  }

  detect_warp_if
  assert_eq "wg-warp" "${WARP_IF}" "verified WARP interface should be selected"
  unset -f ip warp_trace_summary_for_iface
}

test_target_aliases() {
  assert_eq "v2" "$(normalize_target current)" "current target alias"
  assert_eq "v2" "$(normalize_target awg2)" "awg2 target alias"
  assert_eq "warp-only" "$(normalize_target warp)" "warp target alias"
}

test_awg_version_detection() {
  assert_eq "3.1" "$(awg_version_from_tools 'amneziawg-tools v3.1.20260812 - https://amnezia.org')" "AWG tools version"
  assert_eq "2.0" "$(awg_version_from_tools 'amneziawg-tools v2.0.20240101')" "AWG 2 tools version"
  assert_eq "" "$(awg_version_from_tools 'wireguard-tools v1.0.20210914')" "non-AWG tools version"

  docker() {
    if [[ "$*" == *"awg --version"* ]]; then
      printf 'amneziawg-tools v3.1.20260812 - https://amnezia.org\n'
    else
      printf 'AWG 3.x\n'
    fi
  }
  assert_eq "AmneziaWG v3.1" "$(awg_display_title amnezia-awg2 fallback)" "AWG display title from tools"

  docker() {
    if [[ "$*" != *"awg --version"* ]]; then
      printf 'AWG 3.x\n'
    fi
  }
  assert_eq "AmneziaWG v3.x" "$(awg_display_title amnezia-awg2 fallback)" "AWG display title from config"

  docker() {
    return 0
  }
  assert_eq "fallback" "$(awg_display_title amnezia-awg2 fallback)" "AWG display title fallback"
  unset -f docker
}

test_piped_execution() {
  local output
  output="$(bash -s -- help < "${ROOT_DIR}/deploy_amnezia_warp_host.sh")"
  [[ "${output}" == *"Usage:"* ]] || fail "piped installer execution"
}

test_reconcile_refreshes_legacy_env() {
  local test_dir reconcile_script routing_script env_dir env_file
  test_dir="$(mktemp -d)"
  reconcile_script="${test_dir}/reconcile.sh"
  routing_script="${test_dir}/routing.sh"
  env_dir="${test_dir}/env"
  env_file="${env_dir}/legacy.env"
  mkdir -p "${env_dir}"

  awk '
    /cat > \/usr\/local\/sbin\/amnezia-warp-reconcile.sh <<.EOF./ { capture=1; next }
    capture && /^EOF$/ { exit }
    capture { print }
  ' "${ROOT_DIR}/deploy_amnezia_warp_host.sh" > "${reconcile_script}"
  awk '
    /cat > \/usr\/local\/sbin\/amnezia-warp-routing.sh <<.EOF./ { capture=1; next }
    capture && /^EOF$/ { exit }
    capture { print }
  ' "${ROOT_DIR}/deploy_amnezia_warp_host.sh" > "${routing_script}"
  bash -n "${reconcile_script}"
  bash -n "${routing_script}"

  ROUTING_HELPER=/bin/true . "${reconcile_script}" "${env_dir}"
  docker() {
    if [[ "$*" == *GlobalIPv6Address* ]]; then
      printf 'fd42:29:172::4 '
    else
      printf '172.17.0.6 172.29.172.4 '
    fi
  }
  cat > "${env_file}" <<'EOF'
TABLE=51820
MARK=0x61
PRIO=10061
CHAIN=AMN_WARP_AWG
SRC=172.29.172.6/32
SRCS=172.29.172.6,172.17.0.5
WARP_IF=wgcf
ROUTES=x
EXCLUDES=x
EOF

  CONTAINER=
  SRC=
  SRCS=
  # shellcheck disable=SC1090
  . "${env_file}"
  refresh_container_sources "${env_file}"
  grep -qx 'CONTAINER=amnezia-awg' "${env_file}" || fail "legacy env container migration"
  grep -qx 'SRC=172.29.172.4/32' "${env_file}" || fail "legacy primary source refresh"
  grep -qx 'SRCS=172.17.0.6,172.29.172.4' "${env_file}" || fail "legacy source list refresh"
  grep -qx 'SRCS6=fd42:29:172::4' "${env_file}" || fail "legacy IPv6 source list refresh"
  unset -f docker
  rm -rf "${test_dir}"
}

test_non_warp_wireguard_is_ignored
test_verified_warp_is_selected
test_target_aliases
test_awg_version_detection
test_piped_execution
test_reconcile_refreshes_legacy_env
printf 'All tests passed.\n'
