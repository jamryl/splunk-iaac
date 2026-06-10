#!/usr/bin/env bash
#
# check_splunk_prerequisites.sh
#
# Validates Linux host readiness for Splunk Enterprise 10 single-instance deployment.
# Checks OS, CPU, RAM, storage, ulimits, filesystem, and common blockers.
#
# Usage:
#   ./scripts/check_splunk_prerequisites.sh
#   SPLUNK_INSTALL_DIR=/opt/splunk ./scripts/check_splunk_prerequisites.sh
#   ./scripts/check_splunk_prerequisites.sh --strict
#   ./scripts/check_splunk_prerequisites.sh --json
#
# Exit codes:
#   0 - all required checks passed (warnings may be present unless --strict)
#   1 - one or more required checks failed
#   2 - invalid usage

set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"

# Minimum thresholds (align with roles/splunk_enterprise defaults)
SPLUNK_INSTALL_DIR="${SPLUNK_INSTALL_DIR:-/opt/splunk}"
SPLUNK_MIN_RAM_MB="${SPLUNK_MIN_RAM_MB:-8192}"
SPLUNK_RECOMMENDED_RAM_MB="${SPLUNK_RECOMMENDED_RAM_MB:-12288}"
SPLUNK_MIN_DISK_GB="${SPLUNK_MIN_DISK_GB:-50}"
SPLUNK_MIN_CPU_CORES="${SPLUNK_MIN_CPU_CORES:-4}"
SPLUNK_RECOMMENDED_CPU_CORES="${SPLUNK_RECOMMENDED_CPU_CORES:-12}"
SPLUNK_MIN_NOFILE="${SPLUNK_MIN_NOFILE:-64000}"
SPLUNK_MIN_NPROC="${SPLUNK_MIN_NPROC:-16000}"
SPLUNK_WEB_PORT="${SPLUNK_WEB_PORT:-8000}"
SPLUNK_MGMT_PORT="${SPLUNK_MGMT_PORT:-8089}"

STRICT=0
JSON=0

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

declare -a RESULTS=()

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Validate Splunk Enterprise 10 single-instance prerequisites on this Linux host.

Options:
  --strict    Treat warnings as failures
  --json      Emit machine-readable JSON summary on stdout
  -h, --help  Show this help message

Environment variables:
  SPLUNK_INSTALL_DIR           Install path (default: /opt/splunk)
  SPLUNK_MIN_RAM_MB            Minimum RAM in MB (default: 8192)
  SPLUNK_RECOMMENDED_RAM_MB    Recommended RAM in MB (default: 12288)
  SPLUNK_MIN_DISK_GB           Minimum free disk in GB (default: 50)
  SPLUNK_MIN_CPU_CORES         Minimum logical CPU cores (default: 4)
  SPLUNK_RECOMMENDED_CPU_CORES Recommended cores (default: 12)
  SPLUNK_MIN_NOFILE            Minimum open files ulimit (default: 64000)
  SPLUNK_MIN_NPROC             Minimum user processes ulimit (default: 16000)
  SPLUNK_WEB_PORT              Web UI port to check (default: 8000)
  SPLUNK_MGMT_PORT             Management port to check (default: 8089)

EOF
}

log_pass() {
  local message="$1"
  PASS_COUNT=$((PASS_COUNT + 1))
  RESULTS+=("pass|${message}")
  if [[ "${JSON}" -eq 0 ]]; then
    printf '[PASS] %s\n' "${message}"
  fi
}

log_warn() {
  local message="$1"
  WARN_COUNT=$((WARN_COUNT + 1))
  RESULTS+=("warn|${message}")
  if [[ "${JSON}" -eq 0 ]]; then
    printf '[WARN] %s\n' "${message}"
  fi
}

log_fail() {
  local message="$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  RESULTS+=("fail|${message}")
  if [[ "${JSON}" -eq 0 ]]; then
    printf '[FAIL] %s\n' "${message}" >&2
  fi
}

section() {
  if [[ "${JSON}" -eq 0 ]]; then
    printf '\n== %s ==\n' "$1"
  fi
}

read_int() {
  local value="$1"
  value="${value//[^0-9]/}"
  if [[ -z "${value}" ]]; then
    echo "0"
  else
    echo "${value}"
  fi
}

bytes_to_mb() {
  local kb="$1"
  echo $((kb / 1024))
}

get_mem_total_mb() {
  if [[ ! -r /proc/meminfo ]]; then
    echo 0
    return
  fi
  local mem_kb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  bytes_to_mb "$(read_int "${mem_kb}")"
}

get_cpu_cores() {
  local cores
  if command -v nproc >/dev/null 2>&1; then
    cores="$(nproc --all 2>/dev/null || nproc 2>/dev/null || echo 0)"
  elif [[ -r /proc/cpuinfo ]]; then
    cores="$(awk '/^processor[[:space:]]+:/ {count++} END {print count+0}' /proc/cpuinfo)"
  else
    cores=0
  fi
  if [[ -z "${cores}" ]]; then
    cores=0
  fi
  echo "${cores}"
}

get_cpu_model() {
  if [[ ! -r /proc/cpuinfo ]]; then
    return 0
  fi
  awk -F: '/^model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^[[:space:]]*//'
}

supports_x86_64_v2() {
  if [[ ! -r /proc/cpuinfo ]]; then
    return 1
  fi
  local flags
  flags="$(awk '/^flags/ {print; exit}' /proc/cpuinfo 2>/dev/null)"
  [[ "${flags}" == *"sse4_2"* && "${flags}" == *"popcnt"* ]]
}

get_install_path_parent() {
  local path="$1"
  if [[ "${path}" == "/" ]]; then
    echo "/"
  else
    dirname "${path}"
  fi
}

get_disk_avail_gb() {
  local target="$1"
  local parent
  parent="$(get_install_path_parent "${target}")"
  df -BG --output=avail "${parent}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1}'
}

get_filesystem_type() {
  local target="$1"
  local parent
  parent="$(get_install_path_parent "${target}")"
  df -T "${parent}" 2>/dev/null | awk 'NR==2 {print $2}'
}

is_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 {found=1} END {exit !found}'
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v port=":${port} " '$4 ~ port {found=1} END {exit !found}'
    return $?
  fi
  return 2
}

load_os_release() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
  else
    ID="unknown"
    VERSION_ID=""
    PRETTY_NAME="Unknown Linux"
  fi
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_id() {
  local id
  id="$(to_lower "${1:-unknown}")"
  case "${id}" in
    rhel|redhat|centos|rocky|almalinux|ol|oraclelinux|amzn|sles|opensuse-leap|debian|ubuntu)
      echo "${id}"
      ;;
    centos_stream)
      echo "centos"
      ;;
    *)
      echo "${id}"
      ;;
  esac
}

evaluate_os_support() {
  local id version major
  id="$(normalize_id "${ID:-unknown}")"
  version="${VERSION_ID:-}"
  major="${version%%.*}"

  case "${id}" in
    rhel|centos|rocky|almalinux|ol)
      if [[ "${major}" =~ ^(8|9|10)$ ]]; then
        log_pass "Operating system supported: ${PRETTY_NAME} (x86_64 RHEL-family ${major})"
      else
        log_warn "Operating system may be unsupported: ${PRETTY_NAME}. Splunk 10 tested RHEL-family 8, 9, and 10."
      fi
      ;;
    ubuntu)
      if [[ "${version}" == "22.04" || "${version}" == "24.04" ]]; then
        log_pass "Operating system supported: ${PRETTY_NAME}"
      elif [[ "${version}" == "20.04" ]]; then
        log_warn "Operating system deprecated for Splunk 10: ${PRETTY_NAME}. Plan migration to 22.04 or 24.04."
      else
        log_warn "Operating system may be unsupported: ${PRETTY_NAME}. Splunk 10 tested Ubuntu 22.04 and 24.04."
      fi
      ;;
    debian)
      if [[ "${major}" =~ ^(12|13)$ ]]; then
        log_pass "Operating system supported: ${PRETTY_NAME}"
      elif [[ "${major}" == "11" ]]; then
        log_warn "Operating system has partial Splunk support: ${PRETTY_NAME}. Splunk 10 tested Debian 12 and 13."
      else
        log_warn "Operating system may be unsupported: ${PRETTY_NAME}."
      fi
      ;;
    amzn)
      if [[ "${version}" == "2023" || "${PRETTY_NAME:-}" == *"2023"* ]]; then
        log_pass "Operating system supported: ${PRETTY_NAME}"
      elif [[ "${version}" == "2" || "${PRETTY_NAME:-}" == *"Amazon Linux 2"* ]]; then
        log_warn "Operating system has partial Splunk support: ${PRETTY_NAME}. Prefer Amazon Linux 2023."
      else
        log_warn "Operating system may be unsupported: ${PRETTY_NAME}."
      fi
      ;;
    sles)
      log_pass "Operating system listed as supported (verify SP level): ${PRETTY_NAME}"
      ;;
    *)
      log_warn "Operating system not in Splunk 10 tested list: ${PRETTY_NAME}. Verify compatibility before install."
      ;;
  esac
}

check_linux_only() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    log_fail "Splunk Enterprise Linux packages require a Linux host (detected: $(uname -s))."
    return 1
  fi
  log_pass "Host platform is Linux."
}

check_architecture() {
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" == "x86_64" || "${arch}" == "amd64" ]]; then
    log_pass "CPU architecture is 64-bit x86 (${arch})."
    if supports_x86_64_v2; then
      log_pass "CPU appears to support x86-64-v2 (sse4_2 and popcnt present)."
    else
      log_fail "CPU may not support x86-64-v2. Splunk Enterprise 9.3+ requires x86-64-v2 on Intel/AMD."
    fi
  else
    log_warn "Architecture is ${arch}. Standard Splunk Enterprise 10 linux-amd64 packages target x86_64."
  fi
}

check_kernel() {
  local kernel
  kernel="$(uname -r)"
  log_pass "Kernel version: ${kernel}"
}

check_bash() {
  if [[ -x /bin/bash ]]; then
    log_pass "bash is available at /bin/bash."
  else
    log_fail "bash is required but /bin/bash was not found."
  fi

  if [[ "${SHELL:-}" == "/bin/bash" ]] || grep -q "${USER:-root}:" /etc/passwd 2>/dev/null; then
    :
  fi

  if [[ -L /bin/sh ]] && readlink /bin/sh 2>/dev/null | grep -q dash; then
    log_warn "/bin/sh points to dash. Splunk expects bash-compatible /bin/sh on Debian-derived systems."
  fi
}

check_required_commands() {
  local cmd missing=0
  for cmd in tar gzip df awk sed; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      log_pass "Required command present: ${cmd}"
    else
      log_fail "Required command missing: ${cmd}"
      missing=1
    fi
  done
  return "${missing}"
}

check_memory() {
  local total_mb
  total_mb="$(get_mem_total_mb)"

  if [[ "${total_mb}" -lt "${SPLUNK_MIN_RAM_MB}" ]]; then
    log_fail "RAM ${total_mb} MB is below minimum ${SPLUNK_MIN_RAM_MB} MB."
  elif [[ "${total_mb}" -lt "${SPLUNK_RECOMMENDED_RAM_MB}" ]]; then
    log_warn "RAM ${total_mb} MB meets minimum but is below Splunk reference recommendation of ${SPLUNK_RECOMMENDED_RAM_MB} MB."
  else
    log_pass "RAM ${total_mb} MB meets minimum (${SPLUNK_MIN_RAM_MB} MB) and recommended (${SPLUNK_RECOMMENDED_RAM_MB} MB) thresholds."
  fi
}

check_cpu() {
  local cores model
  cores="$(get_cpu_cores)"
  model="$(get_cpu_model)"

  if [[ -n "${model}" ]]; then
    log_pass "CPU: ${model}"
  fi

  if [[ "${cores}" -lt "${SPLUNK_MIN_CPU_CORES}" ]]; then
    log_fail "Logical CPU cores (${cores}) below minimum ${SPLUNK_MIN_CPU_CORES}."
  elif [[ "${cores}" -lt "${SPLUNK_RECOMMENDED_CPU_CORES}" ]]; then
    log_warn "Logical CPU cores (${cores}) meet minimum but are below Splunk reference recommendation of ${SPLUNK_RECOMMENDED_CPU_CORES}."
  else
    log_pass "Logical CPU cores (${cores}) meet minimum and recommended thresholds."
  fi
}

check_storage() {
  local avail_gb fs parent
  parent="$(get_install_path_parent "${SPLUNK_INSTALL_DIR}")"
  avail_gb="$(read_int "$(get_disk_avail_gb "${SPLUNK_INSTALL_DIR}")")"
  fs="$(get_filesystem_type "${SPLUNK_INSTALL_DIR}")"

  if [[ -z "${avail_gb}" || "${avail_gb}" -eq 0 ]]; then
    log_fail "Could not determine free disk space for ${parent}."
    return
  fi

  if [[ "${avail_gb}" -lt "${SPLUNK_MIN_DISK_GB}" ]]; then
    log_fail "Free disk on ${parent}: ${avail_gb} GB (need at least ${SPLUNK_MIN_DISK_GB} GB for ${SPLUNK_INSTALL_DIR})."
  else
    log_pass "Free disk on ${parent}: ${avail_gb} GB (minimum ${SPLUNK_MIN_DISK_GB} GB)."
  fi

  case "${fs}" in
    ext3|ext4|xfs|btrfs)
      log_pass "Filesystem type ${fs} on ${parent} is supported for Splunk index storage."
      ;;
    nfs|nfs4)
      log_warn "Filesystem ${fs} detected. NFS is not recommended for hot/warm buckets; use local block storage when possible."
      ;;
    tmpfs)
      log_fail "Filesystem ${fs} on ${parent} is not suitable for Splunk installation."
      ;;
    "")
      log_warn "Could not determine filesystem type for ${parent}."
      ;;
    *)
      log_warn "Filesystem ${fs} on ${parent} is not in Splunk tested list (ext3, ext4, XFS, btrfs)."
      ;;
  esac

  if [[ -e "${SPLUNK_INSTALL_DIR}" && ! -d "${SPLUNK_INSTALL_DIR}" ]]; then
    log_fail "${SPLUNK_INSTALL_DIR} exists but is not a directory."
  elif [[ -d "${SPLUNK_INSTALL_DIR}" ]]; then
    log_pass "Install directory exists: ${SPLUNK_INSTALL_DIR}"
  else
    log_pass "Install directory ${SPLUNK_INSTALL_DIR} will be created during installation."
  fi
}

check_ulimits() {
  local nofile nproc fsize

  nofile="$(ulimit -n 2>/dev/null || echo 0)"
  nproc="$(ulimit -u 2>/dev/null || echo 0)"
  fsize="$(ulimit -f 2>/dev/null || echo 0)"

  if [[ "${nofile}" == "unlimited" ]] || [[ "$(read_int "${nofile}")" -ge "${SPLUNK_MIN_NOFILE}" ]]; then
    log_pass "Open files ulimit (${nofile}) meets minimum ${SPLUNK_MIN_NOFILE}."
  else
    log_fail "Open files ulimit (${nofile}) below Splunk minimum ${SPLUNK_MIN_NOFILE}. Adjust /etc/security/limits.d."
  fi

  if [[ "${nproc}" == "unlimited" ]] || [[ "$(read_int "${nproc}")" -ge "${SPLUNK_MIN_NPROC}" ]]; then
    log_pass "User processes ulimit (${nproc}) meets minimum ${SPLUNK_MIN_NPROC}."
  else
    log_fail "User processes ulimit (${nproc}) below Splunk minimum ${SPLUNK_MIN_NPROC}."
  fi

  if [[ "${fsize}" == "unlimited" || "${fsize}" == "-1" ]]; then
    log_pass "File size ulimit is unlimited."
  else
    log_warn "File size ulimit is ${fsize}; Splunk recommends unlimited (-1)."
  fi
}

check_transparent_hugepages() {
  local enabled
  if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    enabled="$(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    if [[ "${enabled}" == *"[always]"* ]]; then
      log_warn "Transparent Huge Pages (THP) is set to always. Consider disabling for Splunk performance."
    else
      log_pass "Transparent Huge Pages (THP) is not set to always (${enabled})."
    fi
  else
    log_pass "THP status not available (check skipped)."
  fi
}

check_ports() {
  local port rc
  for port in "${SPLUNK_WEB_PORT}" "${SPLUNK_MGMT_PORT}"; do
    is_port_in_use "${port}"
    rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      log_warn "Port ${port}/tcp is already in use."
    elif [[ "${rc}" -eq 2 ]]; then
      log_warn "Could not check whether port ${port}/tcp is in use (ss/netstat unavailable)."
    else
      log_pass "Port ${port}/tcp appears available."
    fi
  done
}

check_existing_splunk() {
  local splunk_bin="${SPLUNK_INSTALL_DIR}/bin/splunk"
  if [[ -x "${splunk_bin}" ]]; then
    local version
    version="$("${splunk_bin}" version 2>/dev/null | head -n 1 || true)"
    log_warn "Existing Splunk installation detected: ${version:-unknown version} at ${SPLUNK_INSTALL_DIR}"
  else
    log_pass "No existing Splunk binary at ${splunk_bin}."
  fi
}

check_selinux() {
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce 2>/dev/null || echo Unknown)"
    case "${mode}" in
      Disabled|Permissive)
        log_pass "SELinux mode: ${mode}."
        ;;
      Enforcing)
        log_warn "SELinux is Enforcing. Ensure Splunk paths and ports are permitted."
        ;;
      *)
        log_warn "SELinux status: ${mode}."
        ;;
    esac
  fi
}

print_summary() {
  if [[ "${JSON}" -eq 1 ]]; then
    printf '{'
    printf '"pass":%d,"warn":%d,"fail":%d,' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
    printf '"install_dir":"%s",' "${SPLUNK_INSTALL_DIR}"
    printf '"results":['
    local first=1 entry status message
    for entry in "${RESULTS[@]}"; do
      status="${entry%%|*}"
      message="${entry#*|}"
      if [[ "${first}" -eq 0 ]]; then
        printf ','
      fi
      first=0
      printf '{"status":"%s","message":"%s"}' "${status}" "${message//\"/\\\"}"
    done
    printf ']}'
    printf '\n'
    return
  fi

  printf '\n== Summary ==\n'
  printf 'Passed:   %d\n' "${PASS_COUNT}"
  printf 'Warnings: %d\n' "${WARN_COUNT}"
  printf 'Failed:   %d\n' "${FAIL_COUNT}"
  printf 'Install path: %s\n' "${SPLUNK_INSTALL_DIR}"

  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    printf '\nResult: NOT READY - resolve failed checks before installing Splunk Enterprise.\n'
  elif [[ "${STRICT}" -eq 1 && "${WARN_COUNT}" -gt 0 ]]; then
    printf '\nResult: NOT READY (--strict) - resolve warnings before installing Splunk Enterprise.\n'
  elif [[ "${WARN_COUNT}" -gt 0 ]]; then
    printf '\nResult: READY WITH WARNINGS - review warnings before production use.\n'
  else
    printf '\nResult: READY - host meets Splunk Enterprise 10 single-instance prerequisites.\n'
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        STRICT=1
        shift
        ;;
      --json)
        JSON=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ "${JSON}" -eq 0 ]]; then
    section "Splunk Enterprise 10 prerequisite check"
    printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  load_os_release

  section "Platform"
  check_linux_only
  if [[ "$(uname -s)" != "Linux" ]]; then
    print_summary
    exit 1
  fi
  check_architecture
  check_kernel
  evaluate_os_support

  section "Software"
  check_bash
  check_required_commands

  section "Compute"
  check_memory
  check_cpu

  section "Storage"
  check_storage

  section "System limits and tuning"
  check_ulimits
  check_transparent_hugepages
  check_selinux

  section "Network"
  check_ports

  section "Existing installation"
  check_existing_splunk

  print_summary

  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
  fi
  if [[ "${STRICT}" -eq 1 && "${WARN_COUNT}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
