# macOS Endpoint Health Check Toolkit

A read-only Bash toolkit for collecting macOS operating system, hardware, storage, memory, battery, update, security, service, and network health evidence.

## Checks performed

- macOS version, build, uptime, model, serial number, CPU, and memory
- APFS and filesystem capacity
- Memory pressure, virtual memory, and top processes
- Battery condition and power settings on portable Macs
- Pending software updates and update history
- FileVault, System Integrity Protection, and Gatekeeper status
- Network interfaces, Wi-Fi, routes, DNS, proxy, and connectivity
- Failed application, kernel, storage, and memory-pressure events
- Text, CSV, and JSON reports

## Usage

```bash
chmod +x src/macos_endpoint_health.sh
sudo ./src/macos_endpoint_health.sh
```

Skip the online update scan:

```bash
sudo ./src/macos_endpoint_health.sh --skip-software-update --output /tmp/macos-health
```

## Safety

The toolkit does not install updates, restart services, alter security controls, change network settings, or modify the Mac.

## Requirements

- macOS 12 or later recommended
- Bash 3.2+
- Administrator privileges for complete security and log evidence

## Author

Dewald Pretorius — L2 IT Support Engineer
