# Docker host on macOS: analysis and measurements

[Русская версия](../ru/analysis.md)

The goal: a Docker host on an Apple Silicon Mac that costs **nothing when idle**, meaning zero
disk I/O, CPU as close to zero as possible, and RAM handed back to macOS when it is not needed.
The host must still speak the full **Docker Engine API**. The project this was built for
depends on `testcontainers`, several `docker compose` files and `werf`, so a runtime without
`docker.sock` is not an option.

- [Test bench](#test-bench)
- [1. Runtime landscape](#1-runtime-landscape)
- [2. Apple `container machine` as a Docker host](#2-apple-container-machine-as-a-docker-host)
- [3. LinuxKit / a hand-made microVM](#3-linuxkit--a-hand-made-microvm)
- [4. Guest OS: immutable ISO vs cloud image](#4-guest-os-immutable-iso-vs-cloud-image)
- [5. Idle: what costs, what does not](#5-idle-what-costs-what-does-not)
- [6. Memory: VZ never gives it back, and what to do about it](#6-memory-vz-never-gives-it-back-and-what-to-do-about-it)
- [7. Containers under load: Postgres and FoundationDB](#7-containers-under-load-postgres-and-foundationdb)
- [8. Smaller findings](#8-smaller-findings)
- [Limitations](#limitations)
- [Reproducing](#reproducing)

## Test bench

| | |
|---|---|
| Machine | Apple M5 (4 performance + 6 efficiency cores), 16 GB RAM |
| Host | macOS 26.6.2 (25G83) |
| VMM | Lima 2.2.0, `vmType: vz` (Apple Virtualization.framework), 4 vCPU, 6 GiB, virtiofs, Rosetta on |
| Guests | Alpine 3.23.4 cloud image (kernel 6.18.22 / 6.18.53) and alpine-lima `std` ISO v0.2.50 (Alpine 3.24.1, kernel 6.18.38) |
| Docker | 29.5.2 from apk (cloud) / 29.8.1 static docker.com build (ISO); host CLI 29.5.2 |
| Workloads | `postgres:17-alpine` + `pgbench`, `foundationdb/foundationdb:7.3.77` (ssd engine) + Python bindings 7.3.79 |
| Date | 2026-09-24 |

Each figure below comes from a single run, with no repetitions or error bars. Treat
differences of a few percent as noise; see [Limitations](#limitations).

## 1. Runtime landscape

> This section is **desk research** (release notes, docs, issue trackers), not a benchmark.
> Only Lima and Apple `container` were tested hands-on.

| | Lima 2.2 (vz) | OrbStack 2.2.3 | Colima 0.10.3 | Podman 6.1 (libkrun) | Docker Desktop 4.92 | Apple `container` 1.4.1 |
|---|---|---|---|---|---|---|
| Real Docker Engine + `docker.sock` | ✅ | ✅ | ✅ (it *is* Lima) | ⚠️ API emulation | ✅ | ❌ |
| Published ports on `localhost` | ✅ guestagent | ✅ | ✅ | ✅ | ✅ | ❌ for `machine` |
| Gives RAM back to macOS | ❌ ([#4220], [#2789]) | ✅ "dynamic memory" (vendor claim) | ❌ | — | partially | — |
| Idle CPU | ~1% of a core, measured below | ~0.1% (vendor claim) | as Lima | — | higher | — |
| License | Apache-2.0 | proprietary, paid for commercial use | MIT | Apache-2.0 | paid for large orgs | Apache-2.0 |

- **OrbStack** is the only option that solves the one thing Lima cannot: it returns freed
  guest memory to macOS on its own. The costs are closed source and a paid license for work
  use. It was not benchmarked here.
- **Colima** is a wrapper around Lima. It adds convenience but nothing new on the efficiency
  side, and it trails Lima's releases.
- **Podman** is ruled out by `werf`, which wants a Docker daemon. Its default macOS provider,
  libkrun, also has open issues with writable bind mounts.
- **Docker Desktop** is the heaviest of the group. *Resource Saver* stops the VM when idle, but
  the host-side processes stay.

Lima notes: 2.2.0 fixes a **socket FD leak per forwarded connection** ([#5210], fix [#5216]).
On a long-running instance it eventually hit `RLIMIT_NOFILE` and port forwarding died
silently, which matters for `testcontainers` because it opens many connections. Lima 2.2 also
dropped `template:_images/alpine`; templates must now name a version (`_images/alpine-3.23`).

## 2. Apple `container machine` as a Docker host

Tested with `container` 1.3.1, then re-checked against the 1.4.1 release notes. The setup was a
custom Alpine image running `dockerd` on `tcp://0.0.0.0:2375`, driven through `container
machine`.

What does not work, by design rather than by misconfiguration:

- **No port publishing.** `container machine` has no `-p`, so a separate user-space TCP
  forwarder was needed on the host.
- **No socket publishing.** `--publish-socket` exists for `container run`, not for `machine`,
  so the Docker API had to go over plain TCP.
- **A new IP on every start.** The address comes from vmnet DHCP, so the docker context and the
  forwarder need re-pointing after each restart. A static secondary address inside the guest
  (`ip addr add 192.168.64.200/24 dev eth0`) is a workable hack.
- **Not a normal init.** vminit mounts `/proc`, `/sys` and cgroup2 before handing over PID 1,
  and OpenRC's sysinit then fails re-mounting them and reboots the VM, so busybox init has to
  be used instead. `container machine run --root` is not supported.
- **Security.** By default `home-mount=rw` mounts the whole `$HOME` into the machine. Together
  with an unauthenticated `dockerd` on the vmnet bridge, anything that can reach
  192.168.64.0/24 gets root in the VM and write access to your home directory.

**1.3.1 → 1.4.1.** 1.4.0 was withdrawn. 1.4.1 brings two Containerization security fixes
(symlink traversal in OCI image load; a `sun_path` length overflow), `container clean`, a
richer `container system status`, unescaped slashes in JSON output, and Containerization
0.45.0. **Nothing changes for `machine` networking.** Open requests include user mounts
([apple/container#1805], [#2278]) and `machine stats` ([#1919]).

## 3. LinuxKit / a hand-made microVM

The idea: build the guest like Apple's vminit or Docker Desktop's VM, with nothing but a
kernel, an init and `dockerd`.

- **No ready-made LinuxKit image for Lima exists**, and it would not boot as-is. Lima expects
  the guest to run its cidata boot scripts: cloud-init or `lima-init`, user creation, SSH
  keys and the guest agent. LinuxKit has none of these.
- **`linuxkit run virtualization`** is a test runner. It puts the console on stdio and uses
  NAT with a random IP, and it forwards neither vsock nor published ports. The upstream
  `docker-for-mac.yml` example is stale (HyperKit, Docker 20.10) and runs `dockerd` in a dind
  container *on top of* a system containerd, which means more processes, not fewer.
- **A DIY stack of LinuxKit + [vfkit] + [gvisor-tap-vsock]** solves the socket, since
  `virtio-vsock,socketURL=` exposes `docker.sock` as a host unix socket. But automatic
  `localhost` forwarding of *dynamically published* ports, which Lima's guest agent does and
  `testcontainers` relies on, would have to be written from scratch. This is roughly what
  `podman machine` does with Fedora CoreOS.
- **There is little to win anyway.** An idle guest uses ~190 MB, and almost all of it is
  `dockerd` (86 MB RSS), `containerd` (68 MB) and `lima-guestagent` (45 MB); RSS includes
  shared pages, so these add up to more than the total. Everything the usual "minimal VM"
  guides remove (syslogd, acpid, getty, cloud-init-hotplugd, chronyd) adds up to about
  **4.7 MB**. These figures come from an earlier round of measurements (July 2026, Lima 2.1).
- **Memory is the real problem, and a smaller guest does not fix it.** VZ only offers a
  *traditional* memory balloon, with no free page reporting. Memory goes back to macOS only
  if the process that owns the VM actively lowers the balloon target, and neither Lima nor
  vfkit's REST API does that (see §6).

The closest thing Lima supports out of the box is the **alpine-lima ISO**, compared next.

## 4. Guest OS: immutable ISO vs cloud image

- **ISO** ([`templates/minimal-docker-iso.yaml`](../../templates/minimal-docker-iso.yaml)):
  alpine-lima `std`, the image Rancher Desktop builds on. The root file system is a tmpfs
  rebuilt on every boot and there is no cloud-init, a shell script called `lima-init` does its
  job. Only `/etc /home /root /tmp /usr/local /var/lib` persist (bind-mounted from `/mnt/data`),
  so Docker is installed from the static docker.com build into `/usr/local`.
- **Cloud** ([`templates/minimal-docker.yaml`](../../templates/minimal-docker.yaml)): Alpine
  nocloud qcow2 with cloud-init. Lima's stock `alpine` template uses this image.

| | ISO | Cloud, stock | Cloud, tuned (final template) |
|---|---|---|---|
| **Empty idle, host CPU of the VZ process** | 0.96% of a core | 1.31% | 1.00–1.12% |
| Guest disk writes, idle, 180 s (one session) | 0 B | 86 KB in a 120 s window¹ | 0 B |
| Guest RAM after boot (`used`) | 133 MB + 76 MB tmpfs root | 148 MB | — |
| `dockerd` / `containerd` RSS | 79 / 41 MB | 85 / 47 MB | — |
| `limactl restart` → READY | ~12 s | ~26 s | ~14 s |
| Kernel command line editable | ❌ baked into the ISO | ✅ grub | ✅ grub |
| Idle with FDB + Postgres running | 3.88% | 4.13% | 3.77% |
| pgbench, 8 clients, tps | 15,495 | 15,084 | 14,497 |
| FDB write, keys/s | 245k | 246k | 253k |

¹ Measured across two separate `limactl shell` sessions, so the logins are included; not
comparable to the one-session figures.

**Verdict.** After tuning, the two are equally quiet and equally fast. The deciding factor is
the kernel command line: only the cloud image lets you set `init_on_free=1`, which roughly
**halves** the host RAM the VM really holds after a load (§6). The ISO variant stays in the repo
for anyone who values immutability more.

## 5. Idle: what costs, what does not

### Disk: from ~25 KB/min to zero

The only disk writer in an idle guest is `lima-guestagent`. Every 10 s it logs
`SyncTime: system time synchronized with host (drift was 377.9ms)`. The drift never converges
and the loop cannot be configured off (still true in Lima 2.2, where [#5365] only quoted the
string). About 600 B/min of log turns into **~25 KB/min** of block writes through the ext4
journal. The same line also accumulates on the host in `~/.lima/<name>/ha.stderr.log`
(~900 KB/day, not rotated, reset on restart).

The fix is `/var/log` on tmpfs plus `commit=60`, applied in `provision: mode: boot` so that it
happens *before* the guest agent opens its log. `mode: system` is too late, because the daemon
keeps writing to the old inode. Result: **0 bytes** in 180–240 s of idle. On the ISO the root is
already a tmpfs, so there is no need for this.

### CPU: small leaks in the cloud image

Guest wakeup profile over 30 s, empty idle, taken with [`bench/wakeups.sh`](../../bench/wakeups.sh):

| | ISO | Cloud, stock |
|---|---|---|
| `arch_timer` interrupts | ~102/s | ~157/s |
| `lima-guestagent` context switches | ~22/s | ~24/s |
| `containerd` | ~17/s | ~23/s |
| `rcu_preempt` | ~1.3/s | ~9.5/s |
| extras | — | `log_proxy` ~4/s, `syslogd` ~2/s, `init` ~2/s |

Changes applied to the cloud image one by one, with the host CPU of the VZ process after each:

| Step | Host CPU |
|---|---|
| stock | 1.31% |
| kernel 6.18.22 → 6.18.53 | 1.28%, so the kernel is not the cause |
| `cloud-init-hotplugd` off, syslogd to a ring buffer | 1.27% |
| **`ttyAMA0` getty off** | **1.00%** |

The image's `inittab` spawns `getty` on `ttyAMA0`, a device VZ does not have, so busybox init
respawns it forever. That was the largest single drop we measured.

Also:

- **syslogd cannot simply be disabled.** `rc-update del syslog` has no effect, because sshd's
  `use logger` brings it back when Lima restarts sshd at the end of boot. The fix is
  `SYSLOGD_OPTS="-t -C64"`: a fixed 64 KB ring buffer, no file, read with `logread`.
- **`GRUB_TIMEOUT=10`** in the cloud image adds 10 s to every boot.
- **chronyd** is redundant, since Lima syncs the clock itself.
- **Must stay:** `acpid`, because without it `limactl stop` becomes a hard kill followed by fsck.

What remains, about 1% of one core, is mostly Go runtime timers in `lima-guestagent` and
`containerd`. It cannot be tuned away with Lima's settings. `--tick` (default 3 s) is only the
port-polling interval.

`top`'s `IDLEW` column is cumulative since process start, so do not compare it across runs.
Use a CPU-time delta (`ps -o time`) instead.

## 6. Memory: VZ never gives it back, and what to do about it

**Observed.** After one pgbench run the VZ process's `phys_footprint` sits at the full
6 GiB. `echo 3 > /proc/sys/vm/drop_caches` in the guest frees 5.6 GB *inside* the guest, but
the host footprint stays at 6158 MB. VZ has no free page reporting, and Lima does not drive
the balloon.

**How to measure it correctly.** `phys_footprint` (and the *Memory* column in Activity
Monitor) counts **compressed pages at their uncompressed size**, so it cannot show reclaim. For
example, `vmmap` reported *4.9 GB of the VM's 6 GB swapped_out* (there is no swap here; this
means compressed) while the footprint still showed 6 GB. The honest number is how much memory
the host gets back when the VM stops: the change in `free` from `vm_stat`.

**Experiment** ([`bench/memtest.sh`](../../bench/memtest.sh)): pgbench + FDB load →
`drop_caches` in the guest → 40 s of host memory pressure (`memory_pressure -l warn`) →
`limactl stop`.

| | Without `init_on_free` | With `init_on_free=1` |
|---|---|---|
| Host RAM freed by stopping the VM (**the VM's real cost**) | **4,193 MB** | **2,054 MB** |
| VM pages in the compressor → space they occupied | 5,043 MB → 3,025 MB (1.7×) | 4,327 MB → 238 MB (18×) |
| pgbench tps / FDB keys/s in the same run | 15,084 / 246k | 15,713 / 242k |

Why it works: with `init_on_free=1` the guest kernel zeroes every page it frees. The XNU
compressor stores single-value pages at almost no cost, so once macOS needs memory, the VM's
free pages cost next to nothing. Page cache, however, is *used* memory and holds real data.
The final template therefore runs a small `cache-trim` service that drops the clean page cache
**every 10 minutes, and only when the guest is idle** (load1 < 0.2).

Side effects:

- The footprint shows the full `memory:` right away, because the zeroed pages are touched. This
  is expected; the RAM is only taken back under pressure.
- A 2-minute window that contains a trim measured 1.7% CPU instead of ~1.1%, from zeroing about
  2.8 GB of cache.

Without pressure macOS has no reason to reclaim anything, and nothing is lost by that.

## 7. Containers under load: Postgres and FoundationDB

Final template, from [`results/05-final-template-idle-and-load.txt`](../../results/05-final-template-idle-and-load.txt):

| | |
|---|---|
| pgbench -s 50, 8 clients × 60 s | 14,497 tps, 0.55 ms avg latency |
| pgbench, 1 client × 20 s | 3,331 tps, 0.30 ms avg latency |
| FDB, 400k × 100 B keys, 8 threads, 500 keys/txn | 253k keys/s |
| FDB single-key commit latency | p50 1.07 ms, p99 1.61 ms |
| FDB full range read | 535k keys/s |
| Idle with both containers running | 3.8% of a host core; ~33 KB/s of guest disk writes |

- **FoundationDB is never idle.** `fdbserver` keeps its own timers running, at ~1.4% CPU inside
  the guest, and it accounts for most of the 3.8%. Postgres idles at 0%. `docker stop` whatever
  you are not using, and `limactl stop` the VM when you are not working.
- **fsync is suspiciously cheap.** A single-client Postgres commit at 0.3 ms suggests flushes do
  not reach durable media through VZ. This is an inference and was not verified. For
  development that is fine, but assume that the last transactions of databases inside the VM
  can be lost if the host loses power.

## 8. Smaller findings

- **VPN in TUN mode.** With a full-tunnel VPN on the host, VM traffic passes through two
  user-space network stacks: Lima's usernet and the VPN's TUN stack. That showed up as parallel
  CPU spikes in `limactl` and the VPN process during image pulls. Both were idle at ~0 otherwise.
  If registries are reachable directly, a `direct` routing rule for them avoids this.
- **The disk is a sparse file.** Space freed in the guest returns to the host only after a
  discard. `fstrim -a` once returned 2 GB instantly. The template runs it on every boot.
- **Disk usage is dominated by Docker.** `/var/lib/docker` took 11.2 of 11.8 GB, so the
  `daemon.json` limits on log size and BuildKit GC matter more than any OS trimming. (These
  two figures are from the July 2026 round.)
- **Lima template quirk.** `base:` works only in templates. An instance's own `lima.yaml`
  needs explicit `images:`, and `limactl tmpl validate` does not catch this.

## Limitations

- **Single runs.** No repetitions or variance; single-digit percentage differences are within
  noise.
- **One machine.** Everything was measured on one M5 / 16 GB with other apps running
  (browser, terminal, VPN). The memory experiment depends on the host's memory state at the
  time.
- **Two cloud baselines.** The "cloud, stock" and "cloud + `init_on_free`" rows ran on one
  instance at different times, and the kernel was upgraded in between (6.18.22 → 6.18.53).
- **Desk research only.** OrbStack, Podman and Docker Desktop were not benchmarked; their
  figures are vendor claims or documentation.
- **Unverified fsync.** The fsync behaviour is an inference from latency, not a verified fact.

## Reproducing

```sh
limactl start --name=dev ./templates/minimal-docker.yaml && limactl restart dev
docker context create lima-dev --docker "host=unix://$HOME/.lima/dev/sock/docker.sock"
./bench/idle.sh dev 120 60        # empty idle
./bench/disk-writes.sh dev 180    # idle disk writes, one session
./bench/wakeups.sh dev 30         # who wakes the guest
./bench/load.sh dev               # FDB + Postgres: idle with containers, load, idle after
./bench/memtest.sh dev            # real RAM cost after load (stops the VM, applies host memory pressure)
```

The raw outputs of the runs quoted above are in [`results/`](../../results/).

[#4220]: https://github.com/lima-vm/lima/issues/4220
[#2789]: https://github.com/lima-vm/lima/issues/2789
[#5210]: https://github.com/lima-vm/lima/issues/5210
[#5216]: https://github.com/lima-vm/lima/pull/5216
[#5365]: https://github.com/lima-vm/lima/pull/5365
[apple/container#1805]: https://github.com/apple/container/issues/1805
[#2278]: https://github.com/apple/container/issues/2278
[#1919]: https://github.com/apple/container/issues/1919
[vfkit]: https://github.com/crc-org/vfkit
[gvisor-tap-vsock]: https://github.com/containers/gvisor-tap-vsock
