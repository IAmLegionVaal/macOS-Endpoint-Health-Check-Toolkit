#!/bin/bash
set -u

OUTPUT_DIR=""
SKIP_SOFTWARE_UPDATE=false
HOURS=24

usage() {
  echo "Usage: macos_endpoint_health.sh [--skip-software-update] [--hours N] [--output DIR]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-software-update) SKIP_SOFTWARE_UPDATE=true; shift ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$HOURS" in
  ''|*[!0-9]*) echo "--hours must be numeric" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This toolkit must run on macOS." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./macos-health-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/macos-health.txt"
CSV="$OUTPUT_DIR/filesystems.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"
: > "$ERRORS"
echo 'filesystem,size_kib,used_kib,available_kib,capacity,mountpoint' > "$CSV"

section() {
  title="$1"
  shift
  {
    printf '\n===== %s =====\n' "$title"
    "$@"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

run_shell() {
  title="$1"
  command="$2"
  {
    printf '\n===== %s =====\n' "$title"
    /bin/bash -c "$command"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

section "Collection metadata" /bin/bash -c 'date -Is 2>/dev/null || date; hostname; id; sw_vers; uname -a; uptime'
section "Hardware overview" system_profiler SPHardwareDataType
section "Storage overview" diskutil info /
section "APFS containers" diskutil apfs list
section "Filesystem usage" df -k
section "Memory pressure" memory_pressure
section "Virtual memory" vm_stat
section "Top CPU and memory processes" /bin/bash -c 'ps -Ao pid,user,%cpu,%mem,rss,vsz,etime,comm -r | head -n 30; echo; ps -Ao pid,user,%cpu,%mem,rss,vsz,etime,comm -m | head -n 30'
section "Power and battery" /bin/bash -c 'pmset -g batt; echo; pmset -g custom; echo; system_profiler SPPowerDataType 2>/dev/null || true'
section "Update history" /usr/sbin/system_profiler SPInstallHistoryDataType

if ! $SKIP_SOFTWARE_UPDATE; then
  section "Pending software updates" /usr/sbin/softwareupdate -l
fi

section "FileVault status" /usr/bin/fdesetup status
section "System Integrity Protection" /usr/bin/csrutil status
section "Gatekeeper status" /usr/sbin/spctl --status
section "Hardware network ports" /usr/sbin/networksetup -listallhardwareports
section "Network services" /usr/sbin/networksetup -listallnetworkservices
section "Interface state" /sbin/ifconfig -a
section "Routing table" /usr/sbin/netstat -rn
section "DNS configuration" /usr/sbin/scutil --dns
section "Proxy configuration" /usr/sbin/scutil --proxy
section "Wi-Fi information" /bin/bash -c 'WIFI_TOOL="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"; if [ -x "$WIFI_TOOL" ]; then "$WIFI_TOOL" -I; else networksetup -getairportnetwork en0 2>/dev/null || true; fi'
section "Launch services summary" /bin/launchctl list

run_shell "Recent system health events" "/usr/bin/log show --last ${HOURS}h --style compact --predicate '(eventMessage CONTAINS[c] \"panic\") OR (eventMessage CONTAINS[c] \"crash\") OR (eventMessage CONTAINS[c] \"memory pressure\") OR (eventMessage CONTAINS[c] \"I/O error\") OR (eventMessage CONTAINS[c] \"disk\")' 2>/dev/null | tail -n 2000"

# Build filesystem CSV from portable df output.
df -kP | tail -n +2 | while read -r filesystem size used available capacity mountpoint; do
  escaped_mount=$(printf '%s' "$mountpoint" | sed 's/"/""/g')
  escaped_fs=$(printf '%s' "$filesystem" | sed 's/"/""/g')
  printf '"%s",%s,%s,%s,"%s","%s"\n' "$escaped_fs" "$size" "$used" "$available" "$capacity" "$escaped_mount" >> "$CSV"
done

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
BUILD_VERSION="$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
MEMORY_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
CPU_COUNT="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 0)"
ROOT_CAPACITY="$(df -kP / | awk 'NR==2 {gsub("%", "", $5); print $5}')"
FILEVAULT_STATUS="$(fdesetup status 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')"
SIP_STATUS="$(csrutil status 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')"
GATEKEEPER_STATUS="$(spctl --status 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')"
BATTERY_PRESENT=false
pmset -g batt 2>/dev/null | grep -q 'InternalBattery' && BATTERY_PRESENT=true

OVERALL="Healthy"
if [ "${ROOT_CAPACITY:-0}" -ge 90 ]; then
  OVERALL="Attention required"
fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "macos_version": "$OS_VERSION",
  "build_version": "$BUILD_VERSION",
  "hardware_model": "$MODEL",
  "logical_cpu_count": $CPU_COUNT,
  "memory_bytes": $MEMORY_BYTES,
  "root_volume_used_percent": ${ROOT_CAPACITY:-0},
  "battery_present": $BATTERY_PRESENT,
  "filevault_status": "$FILEVAULT_STATUS",
  "sip_status": "$SIP_STATUS",
  "gatekeeper_status": "$GATEKEEPER_STATUS",
  "software_update_scan_skipped": $SKIP_SOFTWARE_UPDATE,
  "overall_status": "$OVERALL"
}
EOF

printf '\nmacOS endpoint health collection completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
