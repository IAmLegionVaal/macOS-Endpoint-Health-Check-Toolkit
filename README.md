# macOS Endpoint Health Check Toolkit

A Bash toolkit for collecting macOS operating system, hardware, storage, memory, battery, update, security, service, and network health evidence. It also includes a guarded maintenance and repair mode for common endpoint issues.

## Checks performed

- macOS version, build, uptime, model, CPU, and memory
- APFS, filesystem capacity, and startup-volume verification
- Memory pressure, virtual memory, and top processes
- Battery condition and power settings
- Pending software updates and update history
- FileVault, System Integrity Protection, and Gatekeeper status
- Network interfaces, routes, DNS, proxy, and connectivity evidence
- Recent crash, panic, storage, and memory-pressure events
- Text, CSV, JSON, error, and repair-action logs

## Diagnostic usage

```bash
chmod +x src/macos_endpoint_health.sh
sudo ./src/macos_endpoint_health.sh
```

Skip the online update scan:

```bash
sudo ./src/macos_endpoint_health.sh --skip-software-update --output /tmp/macos-health
```

## Repair usage

Preview safe maintenance actions:

```bash
sudo ./src/macos_endpoint_health.sh --repair --dry-run
```

Apply guarded endpoint maintenance:

```bash
sudo ./src/macos_endpoint_health.sh --repair --yes
```

Repair mode performs the following actions:

- Backs up selected SystemConfiguration and Software Update preference files when present
- Flushes Directory Service caches
- Reloads `mDNSResponder`
- Runs the built-in daily, weekly, and monthly maintenance scripts
- Performs post-repair storage, DNS, free-space, and update verification

Two higher-impact actions require explicit opt-in:

```bash
sudo ./src/macos_endpoint_health.sh --repair-volume --yes
sudo ./src/macos_endpoint_health.sh --install-updates --yes
```

`--repair-volume` invokes `diskutil repairVolume /`. `--install-updates` invokes `softwareupdate -ia`; updates may require a restart.

## Safety controls

- Repair mode requires root privileges
- `--dry-run` records intended actions without executing them
- A confirmation prompt is shown unless `--yes` is supplied
- Selected configuration files and pre-repair evidence are copied into the report directory
- Every action and failure is recorded in `repair-actions.log`
- High-impact disk repair and update installation are never enabled by plain `--repair`

## Exit codes

- `0` — healthy or successful repair
- `10` — attention still required or repair cancelled
- `20` — one or more repair actions failed
- `2` — invalid arguments
- `3` — wrong platform or insufficient privileges

## Requirements

- macOS 12 or later recommended
- Bash 3.2+
- Administrator privileges for complete evidence and repair mode

## Validation note

The script has been statically reviewed for shell syntax and control flow. Runtime testing must be performed on a suitable macOS system before production use.

## Author

Dewald Pretorius — L2 IT Support Engineer
