#!/bin/bash
#
# server-stats.sh — analyse basic server performance statistics
#
# Runs on any Linux server. Reads from /proc where possible so the output
# format does not depend on the distribution or the locale.
#
# Usage:
#   ./server-stats.sh [-i SECONDS] [-n TOP_N] [-h]
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INTERVAL=1      # sampling window for the CPU measurement, in seconds
TOP_N=5         # how many processes to list

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [-i SECONDS] [-n TOP_N] [-h]

Reports CPU, memory, disk and process statistics for this server.

Options:
  -i SECONDS   CPU sampling interval (default: $INTERVAL)
  -n TOP_N     number of processes to list (default: $TOP_N)
  -h           show this help
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

header() {
    printf '\n\033[1m%s\033[0m\n' "$1"
    printf '%s\n' "------------------------------------------------------------"
}

# Draw a proportional bar: bar <percent> <width>
bar() {
    local pct=${1%.*} width=${2:-30} filled i out=""
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    filled=$(( pct * width / 100 ))
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then out+="#"; else out+="."; fi
    done
    printf '[%s]' "$out"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -i) [[ $# -ge 2 ]] || die "-i requires a value"; INTERVAL="$2"; shift 2 ;;
        -n) [[ $# -ge 2 ]] || die "-n requires a value"; TOP_N="$2";    shift 2 ;;
        *)  die "Unknown option: $1" ;;
    esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ ]] && (( INTERVAL > 0 )) || die "-i must be a positive integer"
[[ "$TOP_N"    =~ ^[0-9]+$ ]] && (( TOP_N    > 0 )) || die "-n must be a positive integer"

# ---------------------------------------------------------------------------
# System identification
# ---------------------------------------------------------------------------
header "SYSTEM"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME $VERSION_ID}")
else
    OS_NAME="Unknown Linux"
fi

printf '%-18s %s\n' "Hostname:"  "$(hostname)"
printf '%-18s %s\n' "OS:"        "$OS_NAME"
printf '%-18s %s\n' "Kernel:"    "$(uname -r)"
printf '%-18s %s\n' "Architecture:" "$(uname -m)"
printf '%-18s %s\n' "CPU cores:" "$(nproc)"

# Uptime from /proc rather than parsing `uptime`, whose wording varies.
if [[ -r /proc/uptime ]]; then
    read -r UP_SECONDS _ < /proc/uptime
    UP_SECONDS=${UP_SECONDS%.*}
    printf '%-18s %d days, %d hours, %d minutes\n' "Uptime:" \
        $(( UP_SECONDS / 86400 )) \
        $(( UP_SECONDS % 86400 / 3600 )) \
        $(( UP_SECONDS % 3600 / 60 ))
fi

if [[ -r /proc/loadavg ]]; then
    read -r L1 L5 L15 _ < /proc/loadavg
    printf '%-18s %s (1m)  %s (5m)  %s (15m)\n' "Load average:" "$L1" "$L5" "$L15"
    # A load equal to the core count means fully saturated.
    awk -v l="$L1" -v c="$(nproc)" \
        'BEGIN { printf "%-18s %.1f%% of capacity\n", "Load per core:", l*100/c }'
fi

# ---------------------------------------------------------------------------
# CPU — two samples of /proc/stat, then the delta
# ---------------------------------------------------------------------------
header "CPU USAGE"

read_cpu() {
    # Fields after "cpu": user nice system idle iowait irq softirq steal ...
    awk '/^cpu / {
        idle = $5 + $6                     # idle + iowait
        total = 0
        for (i = 2; i <= NF; i++) total += $i
        print idle, total
    }' /proc/stat
}

read -r IDLE_1 TOTAL_1 <<< "$(read_cpu)"
sleep "$INTERVAL"
read -r IDLE_2 TOTAL_2 <<< "$(read_cpu)"

CPU_USAGE=$(awk -v i1="$IDLE_1" -v t1="$TOTAL_1" -v i2="$IDLE_2" -v t2="$TOTAL_2" '
    BEGIN {
        di = i2 - i1
        dt = t2 - t1
        if (dt <= 0) { print "0.0"; exit }
        printf "%.1f", (1 - di/dt) * 100
    }')

printf '%-18s %s%% %s\n' "Total CPU used:" "$CPU_USAGE" "$(bar "$CPU_USAGE")"
printf '%-18s %.1f%%\n' "Idle:" "$(awk -v c="$CPU_USAGE" 'BEGIN{print 100-c}')"
printf '%-18s %s seconds\n' "Sampled over:" "$INTERVAL"

# ---------------------------------------------------------------------------
# Memory — /proc/meminfo is stable across distributions
# ---------------------------------------------------------------------------
header "MEMORY USAGE"

awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    /^SwapTotal:/    { swtot = $2 }
    /^SwapFree:/     { swfree = $2 }
    END {
        used = total - avail
        printf "%-18s %.2f GB\n",            "Total:", total/1048576
        printf "%-18s %.2f GB (%.1f%%)\n",   "Used:",  used/1048576,  used*100/total
        printf "%-18s %.2f GB (%.1f%%)\n",   "Free:",  avail/1048576, avail*100/total
        if (swtot > 0) {
            swused = swtot - swfree
            printf "%-18s %.2f GB / %.2f GB (%.1f%%)\n", "Swap used:",
                swused/1048576, swtot/1048576, swused*100/swtot
        } else {
            printf "%-18s none configured\n", "Swap:"
        }
        printf "%.1f\n", used*100/total > "/tmp/.mempct.$$"
    }' /proc/meminfo

if [[ -r "/tmp/.mempct.$$" ]]; then
    MEM_PCT=$(cat "/tmp/.mempct.$$")
    printf '%-18s %s\n' "" "$(bar "$MEM_PCT")"
    rm -f "/tmp/.mempct.$$"
fi

# ---------------------------------------------------------------------------
# Disk — real filesystems only, tmpfs and overlays excluded
# ---------------------------------------------------------------------------
header "DISK USAGE"

# -P forces POSIX output so long device names stay on one line.
# Only count real block devices (/dev/...). Excluding by filesystem type is
# not enough: network mounts, fuse mounts and container overlays all report
# fictional sizes that would wreck the totals.
df -P 2>/dev/null \
  | awk '$1 ~ /^\/dev\// { used += $3; avail += $4 }
    END {
        total = used + avail
        if (total == 0) { print "No filesystems found."; exit }
        printf "%-18s %.2f GB\n",          "Total:", total/1048576
        printf "%-18s %.2f GB (%.1f%%)\n", "Used:",  used/1048576,  used*100/total
        printf "%-18s %.2f GB (%.1f%%)\n", "Free:",  avail/1048576, avail*100/total
    }'

echo
echo "Per filesystem:"
df -h -P 2>/dev/null \
  | awk 'BEGIN { printf "  %-24s %8s %8s %8s  %s\n", "MOUNT", "SIZE", "USED", "AVAIL", "USE%" }
         $1 ~ /^\/dev\// { printf "  %-24s %8s %8s %8s  %s\n", $6, $2, $3, $4, $5 }'

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------
header "TOP $TOP_N PROCESSES BY CPU"

ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu 2>/dev/null \
  | head -n $(( TOP_N + 1 )) \
  | awk 'NR == 1 { printf "  %-8s %-12s %7s %7s  %s\n", "PID", "USER", "CPU%", "MEM%", "COMMAND"; next }
         { printf "  %-8s %-12s %7s %7s  %s\n", $1, $2, $3, $4, $5 }'

header "TOP $TOP_N PROCESSES BY MEMORY"

ps -eo pid,user,pcpu,pmem,comm --sort=-pmem 2>/dev/null \
  | head -n $(( TOP_N + 1 )) \
  | awk 'NR == 1 { printf "  %-8s %-12s %7s %7s  %s\n", "PID", "USER", "CPU%", "MEM%", "COMMAND"; next }
         { printf "  %-8s %-12s %7s %7s  %s\n", $1, $2, $3, $4, $5 }'

# ---------------------------------------------------------------------------
# Stretch goals
# ---------------------------------------------------------------------------
header "USERS AND SESSIONS"

printf '%-18s %s\n' "Processes:" "$(ps -e --no-headers | wc -l)"

if command -v who >/dev/null 2>&1; then
    LOGGED_IN=$(who | wc -l)
    printf '%-18s %s\n' "Logged in now:" "$LOGGED_IN"
    if (( LOGGED_IN > 0 )); then
        who | awk '{ printf "  %-12s %-10s %s %s %s\n", $1, $2, $3, $4, $5 }'
    fi
fi

# Failed logins live in different places depending on the distribution, and
# all of them need root. Try each source, then give up quietly.
header "FAILED LOGIN ATTEMPTS"

FAILED=""
if command -v journalctl >/dev/null 2>&1 && journalctl -q -n0 >/dev/null 2>&1; then
    FAILED=$(journalctl _SYSTEMD_UNIT=ssh.service _SYSTEMD_UNIT=sshd.service \
                --since "24 hours ago" 2>/dev/null | grep -ci "failed password" || true)
elif [[ -r /var/log/auth.log ]]; then
    FAILED=$(grep -ci "failed password" /var/log/auth.log 2>/dev/null || true)
elif [[ -r /var/log/secure ]]; then
    FAILED=$(grep -ci "failed password" /var/log/secure 2>/dev/null || true)
fi

if [[ -n "$FAILED" ]]; then
    printf '%-18s %s\n' "Failed logins:" "$FAILED"
else
    echo "Not available (needs root, or no auth log on this system)."
fi

# ---------------------------------------------------------------------------
# Threshold check — exit non-zero so this is usable from cron or monitoring
# ---------------------------------------------------------------------------
header "HEALTH"

ALERTS=0

check() {
    local label=$1 value=$2 threshold=$3
    if awk -v v="$value" -v t="$threshold" 'BEGIN { exit !(v > t) }'; then
        printf '  WARN  %s at %s%% (threshold %s%%)\n' "$label" "$value" "$threshold"
        return 1
    fi
    printf '  OK    %s at %s%%\n' "$label" "$value"
    return 0
}

DISK_PCT=$(df -P / | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')
MEM_PCT=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.1f", (t-a)*100/t}' /proc/meminfo)

check "CPU"    "$CPU_USAGE" 80 || ALERTS=$(( ALERTS + 1 ))
check "Memory" "$MEM_PCT"   85 || ALERTS=$(( ALERTS + 1 ))
check "Disk /" "$DISK_PCT"  80 || ALERTS=$(( ALERTS + 1 ))

echo

if (( ALERTS > 0 )); then
    echo "$ALERTS threshold(s) exceeded." >&2
    exit 1
fi

exit 0
