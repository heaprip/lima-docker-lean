#!/usr/bin/env bash
# Who wakes the guest up: interrupt deltas and per-command context switches over 30 s.
#   usage: wakeups.sh <instance> [seconds=30]
I=$1; T=${2:-30}
raw=$(limactl shell "$I" sudo sh -c '
snap() { grep -E "arch_timer|virtio|IPI|Resched|Function" /proc/interrupts; echo "@@"
  for t in /proc/[0-9]*/task/[0-9]*; do printf "%s|%s|%s\n" "$t" "$(cat $t/comm 2>/dev/null)" \
    "$(awk "/^voluntary_ctxt/{v=\$2}/^nonvoluntary_ctxt/{n=\$2}END{print v+n}" $t/status 2>/dev/null)"; done; }
snap > /tmp/s0; sleep '"$T"'; snap > /tmp/s1; cat /tmp/s0; echo "####"; cat /tmp/s1')
printf '%s' "$raw" | python3 -c '
import collections, sys
a, b = sys.stdin.read().split("####")
def parse(s):
    irq, th = s.split("@@"); I = {}
    for l in irq.strip().splitlines():
        f = l.split(); I[l.split(":")[0].strip() + " " + " ".join(f[5:])[:40]] = sum(int(x) for x in f[1:5] if x.isdigit())
    T = {}
    for l in th.strip().splitlines():
        p = l.split("|")
        if len(p) == 3 and p[2].isdigit(): T[p[0]] = (p[1], int(p[2]))
    return I, T
(I0, T0), (I1, T1) = parse(a), parse(b)
print(f"== interrupts / {sys.argv[1]}s")
for k, v in sorted(((k, I1[k] - I0.get(k, 0)) for k in I1), key=lambda x: -x[1])[:6]: print(f"{v:6d}  {k}")
w = collections.Counter()
for k, (c, n) in T1.items():
    if k in T0: w[c] += n - T0[k][1]
print(f"== context switches / {sys.argv[1]}s (the measuring 'sh' is noise)")
for c, n in w.most_common(12): print(f"{n:6d}  {c}")
' "$T"
