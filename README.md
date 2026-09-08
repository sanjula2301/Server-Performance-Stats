# server-stats.sh

A single-file Bash script that reports the performance of any Linux server: CPU, memory, disk, top processes, and a few extras. No dependencies beyond coreutils.

Built as a solution to the [Server Performance Stats](https://roadmap.sh/projects/server-stats) project on roadmap.sh.

---

## What it reports

- **CPU** — total usage, sampled over a real time window
- **Memory** — used vs free, in GB and percent, plus swap
- **Disk** — used vs free across all real block devices, plus a per-filesystem breakdown
- **Top 5 processes by CPU**
- **Top 5 processes by memory**

Stretch goals also implemented:

- OS name, kernel version, architecture, core count
- Uptime and load average, including load as a percentage of core capacity
- Logged-in users and active sessions
- Total process count
- Failed SSH login attempts
- Threshold health check with a meaningful exit code

---

## Quick start

```bash
git clone https://github.com/YOUR_USERNAME/server-stats.git
cd server-stats
chmod +x server-stats.sh
./server-stats.sh
```

---

## Usage

```
Usage: server-stats.sh [-i SECONDS] [-n TOP_N] [-h]

Options:
  -i SECONDS   CPU sampling interval (default: 1)
  -n TOP_N     number of processes to list (default: 5)
  -h           show this help
```

```bash
./server-stats.sh              # defaults
./server-stats.sh -i 5         # sample CPU over 5 seconds — more accurate
./server-stats.sh -n 10        # show the top 10 processes
./server-stats.sh -i 3 -n 10   # both
```

---

## Sample output

```
SYSTEM
------------------------------------------------------------
Hostname:          web-01
OS:                Ubuntu 24.04.4 LTS
Kernel:            6.8.0-45-generic
Architecture:      x86_64
CPU cores:         4
Uptime:            12 days, 7 hours, 43 minutes
Load average:      0.42 (1m)  0.51 (5m)  0.48 (15m)
Load per core:     10.5% of capacity

CPU USAGE
------------------------------------------------------------
Total CPU used:    23.4% [######........................]
Idle:              76.6%
Sampled over:      1 seconds

MEMORY USAGE
------------------------------------------------------------
Total:             7.76 GB
Used:              3.12 GB (40.2%)
Free:              4.64 GB (59.8%)
Swap used:         0.00 GB / 2.00 GB (0.0%)
                   [############..................]

DISK USAGE
------------------------------------------------------------
Total:             98.30 GB
Used:              41.20 GB (41.9%)
Free:              57.10 GB (58.1%)

Per filesystem:
  MOUNT                        SIZE     USED    AVAIL  USE%
  /                             98G      41G      57G  42%

TOP 5 PROCESSES BY CPU
------------------------------------------------------------
  PID      USER            CPU%    MEM%  COMMAND
  1421     www-data        18.2     4.1  nginx
  2203     postgres         6.7    12.3  postgres
  ...

HEALTH
------------------------------------------------------------
  OK    CPU at 23.4%
  OK    Memory at 40.2%
  OK    Disk / at 42%
```

---

## How it works

### CPU is sampled twice, not read once

`/proc/stat` reports **cumulative** CPU jiffies since boot:

```
cpu  123456 789 45678 9876543 ...
```

Reading it once gives the average CPU usage across the entire uptime of the machine, which tells you nothing about current load. The script takes two readings separated by `$INTERVAL` seconds and computes the delta:

```
cpu% = 100 × (1 − Δidle / Δtotal)
```

Idle is counted as `idle + iowait`. Time spent waiting on disk is not CPU work, so counting iowait as busy would overstate usage on I/O-heavy servers.

### Data comes from /proc, not from parsing commands

Wherever possible the script reads `/proc` directly rather than parsing the output of `top`, `free`, or `uptime`.

`/proc` is a kernel interface with a stable, documented format. Command output is a human interface — column positions shift between versions, and wording changes with locale. A script that greps `top` output works on the developer's laptop and breaks on a server with `LANG=de_DE`.

| Stat | Source |
|---|---|
| CPU | `/proc/stat` |
| Memory | `/proc/meminfo` |
| Uptime | `/proc/uptime` |
| Load | `/proc/loadavg` |
| OS | `/etc/os-release` |

### Disk totals filter by device, not filesystem type

An early version excluded pseudo-filesystems by type (`df -x tmpfs -x overlay`). Testing inside a container produced a total of **4,194,322 GB** — fuse mounts each reported a fictional 1 PB and were not covered by the type exclusions.

The script now includes only rows whose source begins with `/dev/`, i.e. real block devices. This is robust against network mounts, container overlays, and fuse filesystems that no type-based blocklist can fully enumerate.

### Optional data degrades gracefully

Failed login records live in `journalctl` on systemd systems, `/var/log/auth.log` on Debian/Ubuntu, and `/var/log/secure` on RHEL/CentOS — and all of them require root. The script tries each source in turn and prints a clear explanatory message if none is readable, rather than erroring out.

### The exit code is meaningful

The script exits `1` if CPU exceeds 80%, memory exceeds 85%, or the root filesystem exceeds 80%. Monitoring systems and cron read exit codes, not formatted output, so this is what makes the script operationally useful rather than merely informative.

---

## Running it on a schedule

Log every 15 minutes and email on any threshold breach:

```cron
*/15 * * * * /opt/scripts/server-stats.sh > /var/log/server-stats.log 2>&1 || mail -s "ALERT: $(hostname)" ops@example.com < /var/log/server-stats.log
```

Note that cron runs with a minimal environment and no login profile, so absolute paths are required.

Adjust the thresholds near the bottom of the script:

```bash
check "CPU"    "$CPU_USAGE" 80
check "Memory" "$MEM_PCT"   85
check "Disk /" "$DISK_PCT"  80
```

---

## Requirements

- Any Linux distribution with a `/proc` filesystem
- Bash 4.0 or later
- coreutils (`awk`, `df`, `ps`, `hostname`, `uname`, `nproc`)

No packages to install. Runs as an unprivileged user; root only adds the failed-login section.

---

## Design notes

- `set -euo pipefail` at the top: exit on error, error on undefined variables, and fail a pipeline if any stage fails.
- All arguments are validated before any work is done, with clear errors on stderr.
- Errors and warnings go to stderr so stdout stays pipeable.
- Passes `shellcheck` with no warnings.

---

## Things I would add next

- JSON output mode (`--json`) for ingestion by a monitoring agent
- Network interface throughput from `/proc/net/dev`, sampled the same way as CPU
- Per-core CPU breakdown
- Configurable thresholds via a config file rather than editing the script

---
