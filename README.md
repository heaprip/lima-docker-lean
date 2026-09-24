# lima-docker-lean: Docker on macOS with near-zero idle cost

**English** · [Русский](README.ru.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Lima 2.2](https://img.shields.io/badge/Lima-2.2-green)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M5%20tested-black)
![Virtualization.framework](https://img.shields.io/badge/vmType-vz-lightgrey)

A measured, minimal **Docker host for Apple Silicon Macs**, built on [Lima](https://github.com/lima-vm/lima)
and Apple's Virtualization.framework. When idle it writes **nothing** to disk and uses about **1% of
one core**. Unlike a stock Lima VM, it lets macOS take back **about half** of the RAM the VM holds
after a load. It is a real Docker Engine with `docker.sock`, so `testcontainers`,
`docker compose`, `buildx` and `werf` work unchanged.

This is not another wrapper. It is one Lima template plus the analysis behind every line of it,
with the raw benchmark output included.

## Results

Apple M5, 16 GB, macOS 26.6, Lima 2.2.0, 4 vCPU / 6 GiB guest. Single runs; see
[limitations](docs/en/analysis.md#limitations).

| | Stock Alpine on Lima | **This template** |
|---|---|---|
| Idle host CPU (empty VM) | 1.31% of a core | **1.00–1.12%** |
| Idle disk writes | ~25 KB/min ([why](docs/en/analysis.md#disk-from-25-kbmin-to-zero)) | **0 B** |
| `limactl restart` → ready | ~26 s | **~14 s** |
| Host RAM really held after a Postgres + FoundationDB load | ~4.2 GB | **~2.1 GB** ([how](docs/en/analysis.md#6-memory-vz-never-gives-it-back-and-what-to-do-about-it)) |
| pgbench (8 clients) / FoundationDB writes | ~15k tps / ~246k keys/s | same |

## Quick start

```sh
brew install lima docker            # Lima >= 2.2 and the docker CLI (+ compose/buildx plugins)
git clone https://github.com/heaprip/lima-docker-lean && cd lima-docker-lean

limactl start --name=dev ./templates/minimal-docker.yaml
limactl restart dev                 # once, to boot with init_on_free=1

docker context create lima-dev --docker "host=unix://$HOME/.lima/dev/sock/docker.sock"
docker context use lima-dev
docker run --rm -p 8080:80 nginx:alpine   # published ports appear on localhost
```

For `testcontainers`, point `DOCKER_HOST` at the same socket (or use the context). When you
are not working, `limactl stop dev` brings the cost to zero.

## What the template does

Each of these is explained and measured in the [analysis](docs/en/analysis.md):

- **`/var/log` on tmpfs + `commit=60`.** Lima's guest agent logs a never-converging `SyncTime`
  line every 10 s, and the ext4 journal amplifies it to ~25 KB/min.
- **Kernel `init_on_free=1` + an idle-only page-cache trim.** VZ never returns guest memory, but
  zeroed pages compress to almost nothing in the macOS compressor.
- **No phantom `ttyAMA0` getty.** The cloud image respawns a getty on a device VZ does not have.
  This was the largest single CPU leak.
- **`GRUB_TIMEOUT=0`**, **syslogd in a 64 KB ring buffer** (it cannot simply be disabled), and
  `chronyd` and `cloud-init-hotplugd` off.
- **Docker limits:** capped container logs, BuildKit GC, `fstrim` on boot (the disk is a sparse file).
- **Kept on purpose:** `acpid`, without which `limactl stop` is a hard kill.

## Findings in short

- **Apple `container machine`** (1.3 / 1.4.1) is not usable as a Docker host yet. It has no port
  or socket publishing, a new IP on every start, and `$HOME` is mounted read-write by default.
- **LinuxKit / DIY microVM:** there is no ready image for Lima, and there is little to gain.
  `dockerd` + `containerd` + the guest agent are almost all of the guest's idle RAM, and the
  OS services people usually strip add up to ~5 MB.
- **Immutable ISO (alpine-lima) vs cloud image:** after tuning, the two are equally quiet and fast,
  but only the cloud image lets you change the kernel command line, which is what `init_on_free`
  needs. The ISO variant is kept in [`templates/minimal-docker-iso.yaml`](templates/minimal-docker-iso.yaml).
- **OrbStack** is the one alternative that returns RAM to macOS on its own. It is proprietary
  and paid for commercial use, and it was not benchmarked here.
- **FoundationDB never idles.** `fdbserver` alone keeps the VM at ~3–4% of a core, so stop it
  when you do not need it.

## Repository layout

```
templates/   minimal-docker.yaml (recommended), minimal-docker-iso.yaml (immutable alternative)
docs/en/     analysis.md: full write-up with methodology and limitations
docs/ru/     analysis.md: the same in Russian
bench/       idle.sh, disk-writes.sh, wakeups.sh, load.sh, memtest.sh, fdbbench.py
results/     raw output of every run quoted in the docs
```

## Reproduce

```sh
./bench/idle.sh dev 120 60      # empty idle: host CPU, guest disk I/O, memory
./bench/load.sh dev             # Postgres + FoundationDB: idle with containers, load, idle after
./bench/memtest.sh dev          # real host RAM cost after load (stops the VM!)
```

## License

[MIT](LICENSE). Measurements and write-up by [@heaprip](https://github.com/heaprip), assisted by Claude.
