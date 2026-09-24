#!/usr/bin/env bash
# Guest block-level writes over a window, measured inside ONE shell session, so that
# ssh login/logout of the measurement itself does not pollute the number.
#   usage: disk-writes.sh <instance> [seconds=180]
I=$1; T=${2:-180}
limactl shell "$I" sh -c "a=\$(awk '\$3==\"vda\"{print \$10}' /proc/diskstats); sleep $T; b=\$(awk '\$3==\"vda\"{print \$10}' /proc/diskstats); echo \"write in ${T}s: \$(( (b-a)*512 )) B\""
