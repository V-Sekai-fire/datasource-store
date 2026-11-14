# A FoundationDB client for Mojo, over libfdb_c. Step 2 of the VFS port: the FoundationDB
# side, with no SQLite. Only what `fdb_vfs.c` uses: get, set, clear_range, commit and the
# retry decision. No snapshot reads, atomic operations, versionstamps or watches.
#
# The client needs one thread running the network loop. `fdb_run_network` is handed to
# `pthread_create` as the start routine: it takes no argument and returns an int that
# pthread ignores, so the signature mismatch is harmless on the C ABIs we build for.
#
# Every C pointer crosses as an `Int` address, as in `vfs_mem.mojo`.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from std.ffi import OwnedDLHandle, external_call
from std.memory import alloc
from std.os import getenv

comptime API_VERSION = 730

# The one transaction option the store sets (`bulk_priority` in `fdb_vfs.c`): admission order
# under load, with no effect on what a transaction reads or writes.
comptime TR_OPTION_PRIORITY_BATCH = 201


# The libfdb_c that loads: WEFT_FDB_LIB, then the usual install paths.
def fdb_lib_path() raises -> String:
    var candidates = List[String]()
    var explicit = getenv("WEFT_FDB_LIB")
    if explicit.byte_length() > 0:
        candidates.append(explicit)
    candidates.append("/usr/local/lib/libfdb_c.dylib")
    candidates.append("/usr/lib/libfdb_c.so")
    candidates.append("/usr/local/lib/libfdb_c.so")
    candidates.append("libfdb_c.so")
    for c in candidates:
        try:
            _ = OwnedDLHandle(c)
            return c
        except:
            pass
    raise Error("no libfdb_c found; set WEFT_FDB_LIB")


def _slot() -> Int:
    var p = alloc[Int](4)
    for i in range(4):
        p[unsafe_offset=i] = 0
    return Int(p)


def _rd(addr: Int, index: Int = 0) -> Int:
    return Pointer[Int, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=index]


def _rd32(addr: Int) -> Int:
    return Int(Pointer[Int32, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=0])


# The message FoundationDB has for an error code.
def error_text(lib: OwnedDLHandle, code: Int32) raises -> String:
    var p = lib.call["fdb_get_error", Int](code)
    var out = String()
    var i = 0
    while True:
        var b = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=p)[unsafe_offset=i]
        if b == 0:
            break
        out += chr(Int(b))
        i += 1
    return out^


def check(lib: OwnedDLHandle, code: Int32, what: String) raises:
    if code != 0:
        raise Error(what + ": " + String(code) + " " + error_text(lib, code))


# What a read answers: a FoundationDB error code (0 for none), and the value when there is one.
# The code is returned rather than raised so a retry loop can pass it to `on_error`.
@fieldwise_init
struct GetResult(Copyable, Movable):
    var code: Int32
    var present: Bool
    var value: List[UInt8]


# The first or last key of a range, for `edge_number`: every versioned key in the layout ends
# with its number, so the newest shard version or the oldest pin is read off the edge.
@fieldwise_init
struct EdgeResult(Copyable, Movable):
    var code: Int32
    var found: Bool
    var key: List[UInt8]


struct Fdb(Movable):
    var lib: OwnedDLHandle
    var path: String
    var db: Int
    var thread: Int
    var stopped: Bool
    var owns_network: Bool

    # Select the API version, start the network thread, and open the database.
    def __init__(out self, cluster_file: String) raises:
        self.path = fdb_lib_path()
        self.lib = OwnedDLHandle(self.path)
        self.db = 0
        self.thread = 0
        self.stopped = False
        self.owns_network = False
        # The API version and the network are set once per process. A second handle finds them
        # already set (2201 for the version) and shares the first handle's network thread.
        var vrc = self.lib.call["fdb_select_api_version_impl", Int32](API_VERSION, API_VERSION)
        if vrc != 0 and vrc != 2201:
            check(self.lib, vrc, "select_api_version")
        var nrc = self.lib.call["fdb_setup_network", Int32]()
        var started = nrc == 0
        if nrc != 0 and nrc != 2009:  # 2009: the network is set up already, by an earlier handle
            check(self.lib, nrc, "setup_network")
        self.owns_network = started
        # The network loop, as the thread's start routine.
        if started:
            var sym = self.lib.get_symbol[Int]("fdb_run_network")
            if not sym:
                raise Error("fdb_run_network not found")
            var run = Int(sym.value())
            var tid = _slot()
            var rc = external_call["pthread_create", Int32](tid, 0, run, 0)
            if rc != 0:
                raise Error("pthread_create failed: " + String(rc))
            self.thread = _rd(tid)
        var cf = cluster_file.copy()
        var dbs = _slot()
        check(self.lib, self.lib.call["fdb_create_database", Int32](cf.unsafe_ptr(), dbs), "create_database")
        self.db = _rd(dbs)

    def close(mut self) raises:
        if self.stopped:
            return
        self.stopped = True
        _ = self.lib.call["fdb_database_destroy", Int32](self.db)
        if self.owns_network:
            check(self.lib, self.lib.call["fdb_stop_network", Int32](), "stop_network")
            _ = external_call["pthread_join", Int32](self.thread, 0)


# One transaction. Futures are blocked on from the calling thread; the network thread does the
# I/O. A `Txn` is for one attempt: the retry loop lives in `run`.
struct Txn(Movable):
    var tr: Int

    def __init__(out self, fdb: Fdb) raises:
        var slot = _slot()
        check(fdb.lib, fdb.lib.call["fdb_database_create_transaction", Int32](fdb.db, slot), "create_transaction")
        self.tr = _rd(slot)

    def set(self, fdb: Fdb, key: List[UInt8], value: List[UInt8]) raises:
        _ = fdb.lib.call["fdb_transaction_set", Int32](
            self.tr, Int(key.unsafe_ptr()), Int32(len(key)), Int(value.unsafe_ptr()), Int32(len(value))
        )

    def clear_range(self, fdb: Fdb, begin: List[UInt8], end: List[UInt8]) raises:
        _ = fdb.lib.call["fdb_transaction_clear_range", Int32](
            self.tr, Int(begin.unsafe_ptr()), Int32(len(begin)), Int(end.unsafe_ptr()), Int32(len(end))
        )

    # The value at `key`. The FoundationDB error, if any, is in `code` and is not raised.
    def get_result(self, fdb: Fdb, key: List[UInt8]) raises -> GetResult:
        var f = fdb.lib.call["fdb_transaction_get", Int](self.tr, Int(key.unsafe_ptr()), Int32(len(key)), Int32(0))
        var rc = fdb.lib.call["fdb_future_block_until_ready", Int32](f)
        if rc == 0:
            rc = fdb.lib.call["fdb_future_get_error", Int32](f)
        if rc != 0:
            _ = fdb.lib.call["fdb_future_destroy", Int32](f)
            return GetResult(rc, False, List[UInt8]())
        var out = _slot()  # present@0 (int), value pointer@8, length@16 (int)
        rc = fdb.lib.call["fdb_future_get_value", Int32](f, out, out + 8, out + 16)
        var value = List[UInt8]()
        var present = False
        if rc == 0 and _rd32(out) != 0:
            present = True
            var p = _rd(out, 1)
            for i in range(_rd32(out + 16)):
                value.append(Pointer[UInt8, MutAnyOrigin](unsafe_from_address=p)[unsafe_offset=i])
        _ = fdb.lib.call["fdb_future_destroy", Int32](f)
        return GetResult(rc, present, value^)

    # The value at `key`, or None when the key is absent. Raises on a FoundationDB error.
    def get(self, fdb: Fdb, key: List[UInt8]) raises -> Optional[List[UInt8]]:
        var r = self.get_result(fdb, key)
        check(fdb.lib, r.code, "get")
        if not r.present:
            return None
        return r.value.copy()

    # The first (or last) key in [begin, end), the way `edge_number` reads it. The result is
    # laid out as FDBKeyValue, packed to 4: key pointer at 0, key length at 8.
    def edge(self, fdb: Fdb, begin: List[UInt8], end: List[UInt8], want_last: Bool) raises -> EdgeResult:
        var f = fdb.lib.call["fdb_transaction_get_range", Int](
            self.tr,
            Int(begin.unsafe_ptr()), Int32(len(begin)), Int32(0), Int32(1),
            Int(end.unsafe_ptr()), Int32(len(end)), Int32(0), Int32(1),
            Int32(1), Int32(0), Int32(-2), Int32(1), Int32(0), Int32(1 if want_last else 0),
        )
        var rc = fdb.lib.call["fdb_future_block_until_ready", Int32](f)
        if rc == 0:
            rc = fdb.lib.call["fdb_future_get_error", Int32](f)
        var key = List[UInt8]()
        var found = False
        if rc == 0:
            var out = _slot()  # kv pointer@0, count@8 (int), more@16 (int)
            rc = fdb.lib.call["fdb_future_get_keyvalue_array", Int32](f, out, out + 8, out + 16)
            if rc == 0 and _rd32(out + 8) > 0:
                found = True
                var kv = _rd(out)
                var kp = _rd(kv)
                for i in range(_rd32(kv + 8)):
                    key.append(Pointer[UInt8, MutAnyOrigin](unsafe_from_address=kp)[unsafe_offset=i])
        _ = fdb.lib.call["fdb_future_destroy", Int32](f)
        return EdgeResult(rc, found, key^)

    # Mark this transaction batch priority, as a fold's transactions are. Returns the error code.
    def priority_batch(self, fdb: Fdb) raises -> Int32:
        return fdb.lib.call["fdb_transaction_set_option", Int32](self.tr, Int32(TR_OPTION_PRIORITY_BATCH), 0, Int32(0))

    # Commit. Returns the error code, 0 for success; the caller decides with `on_error`.
    def commit(self, fdb: Fdb) raises -> Int32:
        var f = fdb.lib.call["fdb_transaction_commit", Int](self.tr)
        var rc = fdb.lib.call["fdb_future_block_until_ready", Int32](f)
        if rc == 0:
            rc = fdb.lib.call["fdb_future_get_error", Int32](f)
        _ = fdb.lib.call["fdb_future_destroy", Int32](f)
        return rc

    # Whether `err` may be retried; blocks for the backoff FoundationDB asks for.
    def on_error(self, fdb: Fdb, err: Int32) raises -> Bool:
        var f = fdb.lib.call["fdb_transaction_on_error", Int](self.tr, err)
        var rc = fdb.lib.call["fdb_future_block_until_ready", Int32](f)
        if rc == 0:
            rc = fdb.lib.call["fdb_future_get_error", Int32](f)
        _ = fdb.lib.call["fdb_future_destroy", Int32](f)
        return rc == 0

    def destroy(self, fdb: Fdb) raises:
        _ = fdb.lib.call["fdb_transaction_destroy", Int32](self.tr)
