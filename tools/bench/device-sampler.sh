#!/bin/sh
# Runs ON THE DEVICE (piped over ssh: `ssh root@host sh -s -- COUNT INTERVAL PROCNAME < device-sampler.sh`).
# Read-only: only reads /proc, /sys and vcgencmd. Prints one line per sample:
#   S|<uptime_s>|<cpu line of /proc/stat>|<pid>|<utime>|<stime>|<VmRSS kB>|<temp mC>|<throttled>|<arm Hz>|<loadavg 1m>
COUNT=${1:-30}
INTERVAL=${2:-1}
PROCNAME=${3:-java}

findpid() {
    for p in /proc/[0-9]*; do
        c=$(cat "$p/comm" 2>/dev/null) || continue
        if [ "$c" = "$PROCNAME" ]; then echo "${p#/proc/}"; return; fi
    done
    echo 0
}

PID=$(findpid)
HAVE_VC=0
command -v vcgencmd >/dev/null 2>&1 && HAVE_VC=1
echo "I|ncpu=$(grep -c '^processor' /proc/cpuinfo)|pid=$PID|proc=$PROCNAME|vcgencmd=$HAVE_VC|kernel=$(uname -r)"
if [ "$PID" != 0 ]; then
    echo "X|$(tr '\0' ' ' < /proc/$PID/cmdline | cut -c1-600)"
fi

i=0
while [ "$i" -lt "$COUNT" ]; do
    up=$(cut -d' ' -f1 /proc/uptime)
    cpu=$(head -1 /proc/stat)
    ut=0; st=0; rss=0
    if [ "$PID" != 0 ] && [ -r "/proc/$PID/stat" ]; then
        # fields after the ")" of comm: state is $1 -> utime is $12, stime $13
        set -- $(sed 's/^.*) //' "/proc/$PID/stat")
        ut=${12}; st=${13}
        rss=$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status")
    fi
    temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo -1)
    if [ "$HAVE_VC" = 1 ]; then
        thr=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
        clk=$(vcgencmd measure_clock arm 2>/dev/null | cut -d= -f2)
    else
        thr=na
        clk=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo -1)
    fi
    la=$(cut -d' ' -f1 /proc/loadavg)
    echo "S|$up|$cpu|$PID|$ut|$st|$rss|$temp|$thr|$clk|$la"
    i=$((i + 1))
    sleep "$INTERVAL"
done
# context: who else is using the CPU (other agents' streams etc.)
top -b -n 1 2>/dev/null | sed -n '4,12p' | cut -c1-140 | sed 's/^/T|/'
