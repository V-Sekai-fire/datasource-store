#!/bin/sh
# sqllogictest files through SQLite's own file VFS and through the Mojo VFS, diffed record by
# record. Run by fdb_container.sh with SLT=1, from store/mojo, with the corpus at $SLT_DIR (a
# checkout of github.com/gregrahn/sqllogictest) and build/slt built.
#
# Every file runs on a fresh database on each side. A line that differs between the two sides is
# the VFS changing what SQLite answers; a file passes when there are none.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -u
D=${SLT_DIR:-/slt}/test
# a ten page cache, so reads go back through the VFS and a fault in what it stored shows
PRAGMAS="pragma journal_mode=memory; pragma locking_mode=exclusive; pragma cache_size=10;"
FILES=${SLT_FILES:-"select1.test select2.test select3.test select4.test select5.test $(cd $D && ls evidence/*.test) index/between/10/slt_good_0.test index/commute/10/slt_good_0.test index/delete/10/slt_good_0.test index/in/10/slt_good_0.test index/orderby/10/slt_good_0.test index/random/10/slt_good_0.test"}
n=0 bad=0 recs=0
for f in $FILES; do
	n=$((n + 1))
	rm -f /tmp/slt-u.db*
	timeout 900 build/slt "$D/$f" /tmp/slt-u.db unix "$PRAGMAS" > /tmp/slt-u.out 2>/tmp/slt-u.err
	timeout 1800 build/slt "$D/$f" "slt-$$-$n" weft_mojo_fdb "$PRAGMAS" > /tmp/slt-m.out 2>/tmp/slt-m.err
	# the last two lines of each output are its own times; the diff leaves them out. fdb_ms is
	# FoundationDB's clock (read versions, about 1,000,000 a second), read by the runner itself.
	ums=$(tail -2 /tmp/slt-u.out | head -1 | awk '{print $2}'); mms=$(tail -2 /tmp/slt-m.out | head -1 | awk '{print $2}')
	fms=$(tail -1 /tmp/slt-m.out | awk '{print $2}')
	sed '$d' /tmp/slt-u.out | sed '$d' > /tmp/slt-u.cmp; sed '$d' /tmp/slt-m.out | sed '$d' > /tmp/slt-m.cmp
	r=$(tail -3 /tmp/slt-u.out | head -1)
	nd=$(diff /tmp/slt-u.cmp /tmp/slt-m.cmp | grep -c '^[<>]')
	recs=$((recs + $(echo "$r" | awk '{print $2+0}')))
	if [ "$nd" -eq 0 ] && [ -s /tmp/slt-u.cmp ] && [ -s /tmp/slt-m.cmp ]; then st=same; else st=DIFFER; bad=$((bad + 1)); fi
	echo "$st $f: $r; differing lines $nd; unix ${ums} ms, mojo vfs ${mms} ms (FoundationDB's clock: ${fms} ms)"
	if [ "$st" = DIFFER ]; then
		diff /tmp/slt-u.cmp /tmp/slt-m.cmp | grep '^<' | head -4
		diff /tmp/slt-u.cmp /tmp/slt-m.cmp | grep '^>' | head -4
		echo "mojo output ends: $(tail -2 /tmp/slt-m.out | tr '\n' '|')"
		head -c 400 /tmp/slt-m.err
	fi
done
echo "SLT files $n, differing $bad, records $recs"
[ "$bad" -eq 0 ]
