#!/bin/bash
set -u

OUTPUT_DIR=""
SKIP_SOFTWARE_UPDATE=false
HOURS=24
REPAIR=false
DRY_RUN=false
ASSUME_YES=false
REPAIR_VOLUME=false
INSTALL_UPDATES=false

usage() {
  cat <<'EOF'
Usage: macos_endpoint_health.sh [options]

Options:
  --skip-software-update  Skip the online update scan
  --hours N               Log lookback in hours (default: 24)
  --output DIR            Report directory
  --repair                Run guarded endpoint maintenance repairs
  --repair-volume         Also run diskutil repairVolume / (explicit opt-in)
  --install-updates       Also install all recommended updates (explicit opt-in)
  --dry-run               Show repair commands without executing them
  --yes                   Skip the repair confirmation prompt
  -h, --help              Show help

Exit codes: 0 healthy/success, 10 attention required, 20 repair failed,
            2 invalid arguments, 3 platform/privilege error.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-software-update) SKIP_SOFTWARE_UPDATE=true; shift ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --repair) REPAIR=true; shift ;;
    --repair-volume) REPAIR=true; REPAIR_VOLUME=true; shift ;;
    --install-updates) REPAIR=true; INSTALL_UPDATES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
case "$HOURS" in ''|*[!0-9]*) echo "--hours must be numeric" >&2; exit 2 ;; esac
[ "$(uname -s)" = "Darwin" ] || { echo "This toolkit must run on macOS." >&2; exit 3; }
if $REPAIR && [ "$(id -u)" -ne 0 ]; then echo "Repair mode requires sudo." >&2; exit 3; fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./macos-health-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/macos-health.txt"
CSV="$OUTPUT_DIR/filesystems.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
ACTION_LOG="$OUTPUT_DIR/repair-actions.log"
BACKUP_DIR="$OUTPUT_DIR/pre-repair-backup"
: > "$REPORT"; : > "$ERRORS"; : > "$ACTION_LOG"
echo 'filesystem,size_kib,used_kib,available_kib,capacity,mountpoint' > "$CSV"

section() {
  title="$1"; shift
  { printf '\n===== %s =====\n' "$title"; "$@"; } >> "$REPORT" 2>> "$ERRORS" || true
}
run_shell() {
  title="$1"; command="$2"
  { printf '\n===== %s =====\n' "$title"; /bin/bash -c "$command"; } >> "$REPORT" 2>> "$ERRORS" || true
}
log_action() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$ACTION_LOG"; }
run_action() {
  description="$1"; shift
  if $DRY_RUN; then log_action "DRY-RUN: $description :: $*"; return 0; fi
  log_action "RUN: $description :: $*"
  if "$@" >> "$ACTION_LOG" 2>&1; then log_action "OK: $description"; return 0; fi
  log_action "FAILED: $description"; return 1
}
confirm_repair() {
  $ASSUME_YES && return 0
  printf 'Apply guarded endpoint repairs? [y/N] '
  read answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) echo "Repair cancelled."; exit 10 ;; esac
}

collect() {
  section "Collection metadata" /bin/bash -c 'date -u +%Y-%m-%dT%H:%M:%SZ; hostname; id; sw_vers; uname -a; uptime'
  section "Hardware overview" system_profiler SPHardwareDataType
  section "Storage overview" diskutil info /
  section "APFS containers" diskutil apfs list
  section "Filesystem usage" df -k
  section "Filesystem verification" diskutil verifyVolume /
  section "Memory pressure" memory_pressure
  section "Virtual memory" vm_stat
  section "Top CPU and memory processes" /bin/bash -c 'ps -Ao pid,user,%cpu,%mem,rss,vsz,etime,comm -r | head -n 30; echo; ps -Ao pid,user,%cpu,%mem,rss,vsz,etime,comm -m | head -n 30'
  section "Power and battery" /bin/bash -c 'pmset -g batt; echo; pmset -g custom; echo; system_profiler SPPowerDataType 2>/dev/null || true'
  section "Update history" /usr/sbin/system_profiler SPInstallHistoryDataType
  if ! $SKIP_SOFTWARE_UPDATE; then section "Pending software updates" /usr/sbin/softwareupdate -l; fi
  section "FileVault status" /usr/bin/fdesetup status
  section "System Integrity Protection" /usr/bin/csrutil status
  section "Gatekeeper status" /usr/sbin/spctl --status
  section "Hardware network ports" /usr/sbin/networksetup -listallhardwareports
  section "Network services" /usr/sbin/networksetup -listallnetworkservices
  section "Interface state" /sbin/ifconfig -a
  section "Routing table" /usr/sbin/netstat -rn
  section "DNS configuration" /usr/sbin/scutil --dns
  section "Proxy configuration" /usr/sbin/scutil --proxy
  section "Launch services summary" /bin/launchctl list
  run_shell "Recent system health events" "/usr/bin/log show --last ${HOURS}h --style compact --predicate '(eventMessage CONTAINS[c] \"panic\") OR (eventMessage CONTAINS[c] \"crash\") OR (eventMessage CONTAINS[c] \"memory pressure\") OR (eventMessage CONTAINS[c] \"I/O error\") OR (eventMessage CONTAINS[c] \"disk\")' 2>/dev/null | tail -n 2000"
}

collect

df -kP | tail -n +2 | while read -r filesystem size used available capacity mountpoint; do
  escaped_mount=$(printf '%s' "$mountpoint" | sed 's/"/""/g')
  escaped_fs=$(printf '%s' "$filesystem" | sed 's/"/""/g')
  printf '"%s",%s,%s,%s,"%s","%s"\n' "$escaped_fs" "$size" "$used" "$available" "$capacity" "$escaped_mount" >> "$CSV"
done

REPAIR_FAILURES=0
if $REPAIR; then
  confirm_repair
  mkdir -p "$BACKUP_DIR"
  for file in /Library/Preferences/SystemConfiguration/preferences.plist /Library/Preferences/com.apple.SoftwareUpdate.plist; do
    [ -f "$file" ] || continue
    if $DRY_RUN; then log_action "DRY-RUN: back up $file"; else cp -p "$file" "$BACKUP_DIR/" 2>>"$ACTION_LOG" || REPAIR_FAILURES=$((REPAIR_FAILURES + 1)); fi
  done
  /usr/sbin/scutil --dns > "$BACKUP_DIR/dns-before.txt" 2>/dev/null || true
  /sbin/ifconfig -a > "$BACKUP_DIR/interfaces-before.txt" 2>/dev/null || true

  run_action "Flush Directory Service caches" /usr/bin/dscacheutil -flushcache || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  run_action "Reload mDNSResponder" /usr/bin/killall -HUP mDNSResponder || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  run_action "Run macOS periodic maintenance" /usr/sbin/periodic daily weekly monthly || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  if $REPAIR_VOLUME; then
    run_action "Repair the startup volume" /usr/sbin/diskutil repairVolume / || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  fi
  if $INSTALL_UPDATES; then
    run_action "Install all recommended software updates" /usr/sbin/softwareupdate -ia || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  fi

  printf '\n===== Post-repair verification =====\n' >> "$REPORT"
  /usr/sbin/diskutil verifyVolume / >> "$REPORT" 2>> "$ERRORS" || true
  /usr/sbin/scutil --dns >> "$REPORT" 2>> "$ERRORS" || true
  /bin/df -h / >> "$REPORT" 2>> "$ERRORS" || true
  if ! $SKIP_SOFTWARE_UPDATE; then /usr/sbin/softwareupdate -l >> "$REPORT" 2>> "$ERRORS" || true; fi
fi

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
[ "${ROOT_CAPACITY:-0}" -ge 90 ] && OVERALL="Attention required"
[ "$REPAIR_FAILURES" -gt 0 ] && OVERALL="Repair failed"

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
  "repair_requested": $REPAIR,
  "repair_volume_requested": $REPAIR_VOLUME,
  "install_updates_requested": $INSTALL_UPDATES,
  "dry_run": $DRY_RUN,
  "repair_failures": $REPAIR_FAILURES,
  "overall_status": "$OVERALL"
}
EOF

printf '\nmacOS endpoint health collection completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
if [ "$REPAIR_FAILURES" -gt 0 ]; then exit 20; fi
[ "$OVERALL" = "Healthy" ] && exit 0
exit 10
