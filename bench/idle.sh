#!/usr/bin/env bash
# Measure what a Lima (vmType: vz) instance costs the macOS host while idle.
#
#   usage: idle.sh <instance> [window_seconds=120] [settle_seconds=0]
#
# Reports, for the measurement window:
#   * CPU time burned by the Virtualization.framework process and by the Lima hostagent
#     (a real delta from `ps -o time`, not a top snapshot);
#   * block-level reads/writes of the guest disk (/proc/diskstats in the guest);
#   * host memory footprint of the VM process and guest `free -m`;
#   * RSS of the main guest daemons.
#
# NB: the IDLEW column that `top` prints is cumulative since process start, do not
# compare it across runs. Trust the CPU delta.
set -u
I=$1; T=${2:-120}; sleep "${3:-0}"
dir=$HOME/.lima/$I
ha=$(cat "$dir/ha.pid")
vm=$(pgrep -f com.apple.Virtualization.VirtualMachine | head -1)   # assumes one running VM
cs() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF==4) print ($1*3600+$2*60+$3)*100+$4; else print ($1*60+$2)*100+$3 }'; }
disk() { limactl shell "$I" sh -c "awk '\$3==\"vda\"{print \$6, \$10}' /proc/diskstats"; }

read -r r0 w0 < <(disk); c0=$(cs "$vm"); h0=$(cs "$ha")
sleep "$T"
read -r r1 w1 < <(disk); c1=$(cs "$vm"); h1=$(cs "$ha")

echo "window ${T}s"
echo "VZ pid=$vm  cpu=$(( (c1-c0)*10 ))ms  ($(echo "scale=3; ($c1-$c0)/$T" | bc)% of 1 core)"
echo "hostagent pid=$ha  cpu=$(( (h1-h0)*10 ))ms"
echo "guest vda: read $(( (r1-r0)*512 )) B, write $(( (w1-w0)*512 )) B"
echo "host footprint VZ: $(footprint -p "$vm" 2>/dev/null | awk '/phys_footprint:/{print $2,$3; exit}')"
limactl shell "$I" sh -c 'free -m | sed -n 2p; for p in dockerd containerd lima-guestagent; do pid=$(pidof $p | cut -d" " -f1); [ -n "$pid" ] && echo "$p $(awk "/VmRSS/{print \$2}" /proc/$pid/status)kB"; done' 2>/dev/null
