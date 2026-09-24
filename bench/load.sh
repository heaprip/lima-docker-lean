#!/usr/bin/env bash
# Idle-with-containers + load benchmark: FoundationDB 7.3 (ssd engine) and Postgres 17.
#
#   usage: load.sh <instance>        (docker context lima-<instance> must exist)
#
# 1. starts fdb + pg, lets them settle, measures idle cost with both running;
# 2. pgbench -s 50: 8 clients/60 s and 1 client/20 s (commit latency);
# 3. FDB: 400k x 100 B keys from 8 threads, single-key commit latency, full range read;
# 4. idle again after the load.
set -u
I=$1; export DOCKER_CONTEXT=lima-$I; B=$(cd "$(dirname "$0")" && pwd)
[ -d "$B/fdbpy/fdb" ] || "$B/fetch-fdb-bindings.sh"
fp() { echo "host VZ footprint: $(footprint -p "$(pgrep -f com.apple.Virtualization.VirtualMachine | head -1)" | awk '/phys_footprint:/{print $2,$3; exit}')"; }
echo "===== $I  $(date +%T)"; fp
docker rm -f fdb pg >/dev/null 2>&1; docker volume rm fdbdata pgdata >/dev/null 2>&1
docker run -d --name fdb -v fdbdata:/var/fdb/data foundationdb/foundationdb:7.3.77 >/dev/null
docker run -d --name pg -e POSTGRES_PASSWORD=x -v pgdata:/var/lib/postgresql/data postgres:17-alpine >/dev/null
sleep 8
docker exec fdb fdbcli --exec "configure new single ssd" --timeout 30
until docker exec pg pg_isready -q -U postgres; do sleep 1; done
docker cp "$B/fdbpy/fdb" fdb:/usr/lib64/python3.9/site-packages/fdb
docker cp "$B/fdbbench.py" fdb:/tmp/fdbbench.py

echo "--- idle with fdb+pg running (settle 60s, measure 120s)"
"$B/idle.sh" "$I" 120 60
docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'

echo "--- postgres pgbench"
docker exec pg pgbench -q -i -s 50 -U postgres postgres 2>&1 | tail -1
docker exec pg pgbench -c 8 -j 4 -T 60 -U postgres postgres 2>&1 | grep -E "^tps|latency average|number of failed"
docker exec pg pgbench -c 1 -j 1 -T 20 -U postgres postgres 2>&1 | grep -E "^tps|latency average"

echo "--- foundationdb"
# libfdb_c.so lives in /usr/lib, which is not on the loader path of the image
docker exec -e LD_LIBRARY_PATH=/usr/lib fdb python3 /tmp/fdbbench.py 400000
fp

echo "--- idle after load (settle 60s, measure 60s)"
"$B/idle.sh" "$I" 60 60
docker rm -f fdb pg >/dev/null; docker volume rm fdbdata pgdata >/dev/null
