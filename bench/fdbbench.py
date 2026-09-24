import fdb, os, sys, time, threading
fdb.api_version(730)
db = fdb.open()
N = int(sys.argv[1]) if len(sys.argv) > 1 else 400_000
T, B, V = 8, 500, b"x" * 100

@fdb.transactional
def put(tr, start):
    for i in range(start, start + B):
        tr[b"k%09d" % i] = V

def worker(t):
    for s in range(t * (N // T), (t + 1) * (N // T), B):
        put(db, s)

t0 = time.time()
th = [threading.Thread(target=worker, args=(i,)) for i in range(T)]
[x.start() for x in th]; [x.join() for x in th]
w = time.time() - t0

@fdb.transactional
def lat(tr, i):
    tr[b"lat%06d" % i] = V
ls = []
for i in range(300):
    a = time.perf_counter(); lat(db, i); ls.append((time.perf_counter() - a) * 1000)
ls.sort()

t0 = time.time(); cnt = 0
for _k, _v in db.get_range(b"k", b"l", streaming_mode=fdb.StreamingMode.want_all):
    cnt += 1
r = time.time() - t0
db.clear_range(b"", b"\xff")
print(f"fdb write: {N} keys x 100B in {w:.1f}s = {N/w:,.0f} keys/s ({T} threads, {B}/txn)")
print(f"fdb single-key commit latency: p50={ls[150]:.2f}ms p99={ls[297]:.2f}ms")
print(f"fdb range read: {cnt} keys in {r:.2f}s = {cnt/r:,.0f} keys/s")
