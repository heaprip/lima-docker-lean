#!/usr/bin/env bash
# How much host RAM does the VM *really* hold after a load?
#
#   usage: memtest.sh <instance>     WARNING: stops the instance at the end,
#                                    and briefly puts the Mac under memory pressure.
#
# phys_footprint of the VZ process counts compressed pages at their uncompressed size,
# so it is useless here. Instead: load the guest, drop its page cache, apply host memory
# pressure (memory_pressure -l warn, 40 s) so the macOS compressor takes what it can,
# then stop the VM and see how much memory the host gets back (vm_stat).
I=$1; export DOCKER_CONTEXT=lima-$I; B=$(cd "$(dirname "$0")" && pwd)
[ -d "$B/fdbpy/fdb" ] || "$B/fetch-fdb-bindings.sh"
snap() { vm_stat | awk -v ps="$(pagesize)" '/Pages free/{f=$3} /occupied by compressor/{c=$5} /stored in compressor/{s=$5} END{printf "free=%d compressor_occupied=%d compressor_stored=%d MB\n", f*ps/1048576, c*ps/1048576, s*ps/1048576}'; }
vm=$(pgrep -f com.apple.Virtualization.VirtualMachine | head -1)
docker rm -f fdb pg >/dev/null 2>&1; docker volume rm fdbdata pgdata >/dev/null 2>&1
docker run -d --name pg -e POSTGRES_PASSWORD=x -v pgdata:/var/lib/postgresql/data postgres:17-alpine >/dev/null
docker run -d --name fdb -v fdbdata:/var/fdb/data foundationdb/foundationdb:7.3.77 >/dev/null; sleep 8
docker exec fdb fdbcli --exec "configure new single ssd" --timeout 30 >/dev/null
until docker exec pg pg_isready -q -U postgres; do sleep 1; done
docker cp "$B/fdbpy/fdb" fdb:/usr/lib64/python3.9/site-packages/fdb; docker cp "$B/fdbbench.py" fdb:/tmp/fdbbench.py
docker exec pg pgbench -q -i -s 50 -U postgres postgres >/dev/null 2>&1
docker exec pg pgbench -c 8 -j 4 -T 60 -U postgres postgres 2>&1 | grep -E "^tps"
docker exec -e LD_LIBRARY_PATH=/usr/lib fdb python3 /tmp/fdbbench.py 400000 | head -1
echo "after load: footprint=$(footprint -p "$vm" | awk '/phys_footprint:/{print $2}')MB"
limactl shell "$I" sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; free -m | sed -n 2p'
memory_pressure -l warn -Q >/dev/null 2>&1 & mp=$!; sleep 40; kill $mp; wait $mp 2>/dev/null; sleep 5
echo "vmmap: $(vmmap -summary "$vm" 2>/dev/null | grep '^Writable regions')"
echo "running: $(snap)"
docker rm -f fdb pg >/dev/null; docker volume rm fdbdata pgdata >/dev/null
limactl stop "$I" >/dev/null 2>&1; sleep 5
echo "stopped: $(snap)"
