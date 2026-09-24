# Raw results

Unedited output of the runs quoted in [docs/en/analysis.md](../docs/en/analysis.md)
([RU](../docs/ru/analysis.md)). Apple M5, 16 GB, macOS 26.6.2, Lima 2.2.0, 2026-09-24.
The instance names in the files (`dev`, `dev-cloud`) refer to the variant listed below.

| File | Variant | What |
|---|---|---|
| `01-iso-idle-and-load.txt` | ISO (alpine-lima 3.24.1) | idle with FDB + Postgres, pgbench, idle after. The first FDB attempt fails (`libfdb_c.so` not on the loader path); the successful re-run is appended at the end. |
| `02-cloud-untuned-empty-idle.txt` | cloud 3.23, stock | empty idle |
| `03-cloud-untuned-idle-and-load.txt` | cloud 3.23, stock | idle with FDB + Postgres, pgbench, FDB, idle after |
| `04-cloud-init_on_free-memtest.txt` | cloud + `init_on_free=1` | `bench/memtest.sh`: load → drop_caches → host memory pressure → stop; `running`/`stopped` are host `vm_stat` |
| `05-final-template-idle-and-load.txt` | final `minimal-docker.yaml` | `bench/load.sh` |
| `06-iso-wakeup-snapshot.raw.txt` | ISO | raw `/proc/interrupts` + per-thread context switches, two snapshots 30 s apart |
| `07-cloud-wakeup-snapshot.raw.txt` | cloud, stock | same |
| `08-final-template-empty-idle.txt` | final template | empty idle (120 s window) + one-session disk writes (180 s) |

The control run for the memory experiment (without `init_on_free`) was done by hand right after
`03`, so it has no file of its own:

```
guest drop_caches: footprint 6158 MB before and after
memory_pressure -l warn, 40 s: footprint stays 6158 MB (vmmap: resident 6.0G, swapped_out 4.9G)
running: free=2912 active=3158 inactive=3033 wired=1972 compressor_occ=4520 stored=10298 (MB)
stopped: free=7105 active=2328 inactive=2644 wired=1964 compressor_occ=1495 stored=5255 (MB)
```

The per-step CPU figures for the cloud image tuning (kernel upgrade, hotplugd/syslog, ttyAMA0)
come from `bench/idle.sh` runs whose output was not saved; they are quoted in the analysis.
