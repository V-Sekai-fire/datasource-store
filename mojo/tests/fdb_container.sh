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
pixi run fdb-client

# MUTANTS=1: break the client four ways and require the test to fail each time.
if [ -n "${MUTANTS:-}" ]; then
	apt-get install -y -qq --no-install-recommends perl >/dev/null
	cp src/fdb_client.mojo /tmp/fdb_client.orig
	mutant() {
		name=$1; shift
		cp /tmp/fdb_client.orig src/fdb_client.mojo
		"$@"
		if cmp -s /tmp/fdb_client.orig src/fdb_client.mojo; then echo "MUTANT $name: pattern did not apply"; return; fi
		if pixi run fdb-client >/tmp/mutant.out 2>&1; then echo "MUTANT $name: SURVIVED"; else echo "MUTANT $name: caught ($(grep -c '^FAIL' /tmp/mutant.out) failed checks)"; fi
	}
	mutant "set drops a byte of the value" sed -i 's/Int32(len(value))/Int32(len(value) - 1)/' src/fdb_client.mojo
	mutant "clear_range has its ends swapped" sed -i 's/Int(begin.unsafe_ptr()), Int32(len(begin)), Int(end.unsafe_ptr()), Int32(len(end))/Int(end.unsafe_ptr()), Int32(len(end)), Int(begin.unsafe_ptr()), Int32(len(begin))/' src/fdb_client.mojo
	mutant "get never sees a value" sed -i 's/if present == 0:/if True:/' src/fdb_client.mojo
	mutant "commit hides its error" perl -0pi -e 's/(fdb_future_get_error", Int32\]\(f\)\n        _ = fdb.lib.call\["fdb_future_destroy", Int32\]\(f\)\n)        return rc\n/$1        return Int32(0)\n/' src/fdb_client.mojo
	cp /tmp/fdb_client.orig src/fdb_client.mojo
fi
