#!/bin/sh
# Runs the Mojo FoundationDB client test against a throwaway server, all inside one Linux
# container. The repo is mounted read-only at /src; mojo/ is copied so the Mac's .pixi is not used.
set -eu
FDB_VERSION=7.3.76
ARCH=$(uname -m)
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null
curl -fsSL https://pixi.sh/install.sh | sh >/dev/null 2>&1
export PATH="$HOME/.pixi/bin:$PATH"
pixi --version

mkdir -p /opt/fdb /work /data /logs
base=https://github.com/apple/foundationdb/releases/download/$FDB_VERSION
for f in fdbserver fdbcli; do curl -fsSL -o /opt/fdb/$f $base/$f.$ARCH; chmod +x /opt/fdb/$f; done
curl -fsSL -o /opt/fdb/libfdb_c.so $base/libfdb_c.$ARCH.so
echo "mojo:test@127.0.0.1:4500" > /opt/fdb/fdb.cluster
/opt/fdb/fdbserver -p 127.0.0.1:4500 -C /opt/fdb/fdb.cluster -d /data -L /logs >/logs/server.out 2>&1 &
sleep 4
/opt/fdb/fdbcli -C /opt/fdb/fdb.cluster --exec "configure new single memory" --timeout 30
/opt/fdb/fdbcli -C /opt/fdb/fdb.cluster --exec "status minimal" --timeout 30

(cd /src/mojo && tar cf - --exclude=.pixi --exclude=build --exclude=spike .) | (mkdir -p /work/mojo && cd /work/mojo && tar xf -)
cd /work/mojo
pixi install --locked 2>&1 | tail -1
export WEFT_FDB_LIB=/opt/fdb/libfdb_c.so WEFT_FDB_CLUSTER_FILE=/opt/fdb/fdb.cluster
if [ -z "${BENCH:-}" ] && [ -z "${SLT:-}" ]; then
	pixi run fdb-client
	pixi run vfs-fdb
fi

# MUTANTS=1: break the client and the VFS and require the matching test to fail each time.
if [ -n "${MUTANTS:-}" ]; then
	apt-get install -y -qq --no-install-recommends perl >/dev/null
	cp src/fdb_client.mojo /tmp/fdb_client.orig
	cp src/vfs_fdb.mojo /tmp/vfs_fdb.orig
	mutant() {
		task=$1; file=$2; name=$3; shift 3
		cp /tmp/fdb_client.orig src/fdb_client.mojo
		cp /tmp/vfs_fdb.orig src/vfs_fdb.mojo
		"$@"
		if cmp -s /tmp/fdb_client.orig src/fdb_client.mojo && cmp -s /tmp/vfs_fdb.orig src/vfs_fdb.mojo; then echo "MUTANT $name: pattern did not apply"; return; fi
		if pixi run $task >/tmp/mutant.out 2>&1; then echo "MUTANT $name: SURVIVED"; else echo "MUTANT $name: caught ($(grep -c '^FAIL' /tmp/mutant.out) failed checks, $(grep -c 'Unhandled exception' /tmp/mutant.out) crash)"; fi
	}
	C=src/fdb_client.mojo
	V=src/vfs_fdb.mojo
	mutant fdb-client $C "client: the read version is in the wrong unit" sed -i 's|        return _rd(out)$|        return _rd(out) // 1000|' $C
	mutant fdb-client $C "client: set drops a byte of the value" sed -i 's/Int32(len(value))/Int32(len(value) - 1)/' $C
	mutant fdb-client $C "client: clear_range has its ends swapped" sed -i 's/Int(begin.unsafe_ptr()), Int32(len(begin)), Int(end.unsafe_ptr()), Int32(len(end))/Int(end.unsafe_ptr()), Int32(len(end)), Int(begin.unsafe_ptr()), Int32(len(begin))/' $C
	mutant fdb-client $C "client: get never sees a value" sed -i 's/if rc == 0 and _rd32(out) != 0:/if False:/' $C
	mutant fdb-client $C "client: commit hides its error" perl -0pi -e 's/(fdb_future_get_error", Int32\]\(f\)\n        _ = fdb.lib.call\["fdb_future_destroy", Int32\]\(f\)\n)        return rc\n/$1        return Int32(0)\n/' $C
	mutant fdb-client $C "client: the range read takes the first key, not the last" sed -i 's/Int32(1 if want_last else 0)/Int32(0)/' $C
	mutant fdb-client $C "client: the batch priority option has the wrong code" sed -i 's/^comptime TR_OPTION_PRIORITY_BATCH = 201/comptime TR_OPTION_PRIORITY_BATCH = 999/' $C
	mutant vfs-fdb $V "vfs: the fence is never checked" sed -i 's/if not r.present or be64_of(r) != f.fence:/if False:/' $V
	mutant vfs-fdb $V "vfs: a commit writes no index rows" perl -0pi -e 's/    for i in range\(len\(f.pgnos\)\):\n        t.set\(fdb, key_pidx\(f.name, UInt32\(f.pgnos\[i\]\)\), u64_value\(txid\)\)\n//' $V
	mutant vfs-fdb $V "vfs: open leaves an unfinished commit behind" sed -i 's/    t.clear_range(fdb, drop_from, key_after(key_prefix(f.name, "DELTA")))//' $V
	mutant vfs-fdb $V "vfs: open does not raise the fence" sed -i 's/    t.set(fdb, key_meta(f.name, "FENCE"), u64_value(f.fence))//' $V
	mutant vfs-fdb $V "vfs: HEAD is not advanced" sed -i 's/    t.set(fdb, key_meta(f.name, "HEAD"), u64_value(txid))//' $V
	mutant vfs-fdb $V "vfs: a read ignores the buffered page" perl -0pi -e 's/        if d:\n            ref src = f.pages/        if False:\n            ref src = f.pages/' $V
	mutant vfs-fdb $V "fold: it is never owed" sed -i 's/f.compact_due = True/pass/' $V
	mutant vfs-fdb $V "fold: no shard pages are written" sed -i 's/t.set(fdb, key_shard(f.name, UInt64(as_of), UInt32(lo + i)), w.pages\[i\])/pass/' $V
	mutant vfs-fdb $V "fold: the index is not cleared" sed -i 's/t.clear_range(fdb, pidx, key_after(pidx))/pass/' $V
	mutant vfs-fdb $V "fold: the log rows are not cleared" sed -i 's/t.clear_range(fdb, delta, key_after(delta))/pass/' $V
	mutant vfs-fdb $V "fold: LOGN is not reset" sed -i 's/t.set(fdb, key_meta(f.name, "LOGN"), u64_value(0))/pass/' $V
	mutant vfs-fdb $V "recovery: a committed group is not resolved" sed -i 's/t.set(fdb, key_meta(p.name, "HEAD"), u64_value(p.txid))/pass/' $V
	mutant vfs-fdb $V "recovery: an abort fences a healthy participant" sed -i 's/    if fence_it:/    if True:/' $V
	mutant vfs-fdb $V "recovery: a decided record is not dropped" sed -i 's/t.clear_range(fdb, pre, key_after(pre))\n    return 0\n\n\ndef recover_one/XX/;/^def drop_record_body/,/return 0/{s/    t.clear_range(fdb, pre, key_after(pre))/    pass/}' $V
	mutant vfs-fdb $V "recovery: a writer's open never runs it" sed -i 's/        var rec = recover_groups(fdb)/        var rec = Int32(0)/' $V
	mutant vfs-fdb $V "staging: the last chunk is never written" sed -i 's/            lo += STAGE_TXN_PAGES/            lo += 2 * STAGE_TXN_PAGES/' $V
	mutant vfs-fdb $V "staging: a chunk does not check the fence" perl -0pi -e 's/(def delta_body.*?\n)    var fc = check_fence\(fdb, t, f\)\n    if fc != 0:\n        return fc\n/$1/s' $V
	cp /tmp/fdb_client.orig src/fdb_client.mojo
	cp /tmp/vfs_fdb.orig src/vfs_fdb.mojo
fi

# CROSS=1: the C VFS and the Mojo VFS on one store, each reading what the other wrote.
if [ -n "${CROSS:-}" ]; then
	apt-get install -y -qq --no-install-recommends cmake gcc g++ make libsqlite3-dev >/dev/null
	case "$ARCH" in x86_64) DEB=amd64 ;; *) DEB=$ARCH ;; esac
	curl -fsSL -o /tmp/fdbc.deb "$base/foundationdb-clients_$FDB_VERSION-1_$DEB.deb"
	dpkg -x /tmp/fdbc.deb /tmp/fdbc
	mkdir -p /tmp/csrc && (cd /src && tar cf - --exclude=mojo --exclude=.git --exclude=thirdparty .) | (cd /tmp/csrc && tar xf -)
	[ -d /src/thirdparty ] && cp -r /src/thirdparty /tmp/csrc/ 2>/dev/null || true
	cmake -S /tmp/csrc -B /tmp/cbuild -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DFDB_INCLUDE_DIR=/tmp/fdbc/usr/include -DFDB_LIBRARY=/tmp/fdbc/usr/lib/libfdb_c.so >/dev/null
	cmake --build /tmp/cbuild --target sqlrun -j4 2>&1 | tail -2
	WEFT_SQLITE_LIB=/usr/lib/$ARCH-linux-gnu/libsqlite3.so.0 SQLRUN=/tmp/cbuild/sqlrun FDBCLI=/opt/fdb/fdbcli sh tests/cross.sh
fi

# BENCH=1: pure SQLite, the C VFS and the Mojo VFS on the $12-server challenge's workload.
if [ -n "${BENCH:-}" ]; then
	apt-get install -y -qq --no-install-recommends cmake gcc g++ make libsqlite3-dev >/dev/null
	case "$ARCH" in x86_64) DEB=amd64 ;; *) DEB=$ARCH ;; esac
	curl -fsSL -o /tmp/fdbc.deb "$base/foundationdb-clients_$FDB_VERSION-1_$DEB.deb"
	dpkg -x /tmp/fdbc.deb /tmp/fdbc
	mkdir -p /tmp/csrc && (cd /src && tar cf - --exclude=mojo --exclude=.git .) | (cd /tmp/csrc && tar xf -)
	cmake -S /tmp/csrc -B /tmp/cbuild -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DFDB_INCLUDE_DIR=/tmp/fdbc/usr/include -DFDB_LIBRARY=/tmp/fdbc/usr/lib/libfdb_c.so >/dev/null
	cmake --build /tmp/cbuild --target weft_fdb_vfs -j4 2>&1 | tail -1
	mkdir -p build
	gcc -O2 -I/tmp/csrc -o build/bench_c bench/bench_c.c /tmp/cbuild/libweft_fdb_vfs.a \
		-L/tmp/fdbc/usr/lib -lfdb_c -lsqlite3 -lpthread -lm
	export LD_LIBRARY_PATH=/tmp/fdbc/usr/lib
	pixi run mojo build -I src bench/bench.mojo -o build/bench 2>&1 | grep -E "^.*error" -A3 || true
	WEFT_SQLITE_LIB=/usr/lib/$ARCH-linux-gnu/libsqlite3.so.0 FDBCLI=/opt/fdb/fdbcli sh bench/bench.sh
fi


# SLT=1: the sqllogictest corpus through SQLite's own file VFS and the Mojo VFS, diffed.
if [ -n "${SLT:-}" ]; then
	apt-get install -y -qq --no-install-recommends gcc libc6-dev libsqlite3-dev >/dev/null
	# SLT_SED: a sed expression applied to src/vfs_fdb.mojo first, to plant a fault and see the
	# suite catch it.
	if [ -n "${SLT_SED:-}" ]; then sed -i "$SLT_SED" src/vfs_fdb.mojo; fi
	mkdir -p build
	pixi run mojo build -I src bench/slt.mojo -o build/slt 2>&1 | grep -E "^.*error" -A3 || true
	WEFT_SQLITE_LIB=/usr/lib/$ARCH-linux-gnu/libsqlite3.so.0 sh bench/slt.sh
fi
