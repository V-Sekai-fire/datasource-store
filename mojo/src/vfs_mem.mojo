# A SQLite VFS written in Mojo, over an in-memory file store. Step 1 of the VFS port: the
# SQLite side, with no FoundationDB yet. `fdb_vfs.c` keeps its pages in FoundationDB; this
# keeps them in `MemStore`, which is the seam a later step replaces.
#
# SQLite calls a VFS through two C function tables: an `sqlite3_vfs` (open, delete, access,
# the clock) and, per open file, an `sqlite3_io_methods` (read, write, sync, size). Both are
# built here in raw memory, with Mojo `abi("C")` functions as the entries. Every C pointer
# crosses as a plain `Int` address: this Mojo's `Pointer` is non-null.
#
# Layout of what SQLite reads (64-bit):
#   sqlite3_vfs:        iVersion@0 szOsFile@4 mxPathname@8 pNext@16 zName@24 pAppData@32
#                       xOpen@40 xDelete@48 xAccess@56 xFullPathname@64 xDlOpen@72 xDlError@80
#                       xDlSym@88 xDlClose@96 xRandomness@104 xSleep@112 xCurrentTime@120
#                       xGetLastError@128
#   sqlite3_io_methods: iVersion@0 xClose@8 xRead@16 xWrite@24 xTruncate@32 xSync@40
#                       xFileSize@48 xLock@56 xUnlock@64 xCheckReservedLock@72 xFileControl@80
#                       xSectorSize@88 xDeviceCharacteristics@96
#   our sqlite3_file:   pMethods@0 store@8 file index@16, so szOsFile is 24
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

from std.ffi import OwnedDLHandle
from std.os import getenv
from std.memory import alloc

comptime SQLITE_OK = 0
comptime SQLITE_NOTFOUND = 12
comptime SQLITE_IOERR_SHORT_READ = 522
comptime SQLITE_CANTOPEN = 14
comptime FILE_SIZE = 24
comptime MAX_PATH = 512


# ── Raw memory ────────────────────────────────────────────────────────────────

# SQLite from the pixi environment (CONDA_PREFIX is set under `pixi run`), then the system's.
def open_sqlite() raises -> OwnedDLHandle:
    var candidates = List[String]()
    var prefix = getenv("CONDA_PREFIX")
    if prefix.byte_length() > 0:
        candidates.append(prefix + "/lib/libsqlite3.dylib")
        candidates.append(prefix + "/lib/libsqlite3.so")
    candidates.append("/usr/lib/libsqlite3.dylib")
    candidates.append("libsqlite3.so.0")
    for c in candidates:
        try:
            return OwnedDLHandle(c)
        except:
            pass
    raise Error("no libsqlite3 found")


def _bytes(addr: Int) -> Pointer[UInt8, MutAnyOrigin]:
    return Pointer[UInt8, MutAnyOrigin](unsafe_from_address=addr)


def _words(addr: Int) -> Pointer[Int, MutAnyOrigin]:
    return Pointer[Int, MutAnyOrigin](unsafe_from_address=addr)


def peek64(addr: Int) -> Int:
    return _words(addr)[unsafe_offset=0]


def poke64(addr: Int, v: Int):
    _words(addr)[unsafe_offset=0] = v


def poke32(addr: Int, v: Int32):
    Pointer[Int32, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=0] = v


def poke_i64(addr: Int, v: Int64):
    Pointer[Int64, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=0] = v


def poke_f64(addr: Int, v: Float64):
    Pointer[Float64, MutAnyOrigin](unsafe_from_address=addr)[unsafe_offset=0] = v


def cstr(addr: Int) -> String:
    var out = String()
    var i = 0
    while True:
        var b = _bytes(addr)[unsafe_offset=i]
        if b == 0:
            break
        out += chr(Int(b))
        i += 1
    return out^


# ── The store: files by name, bytes by file ──────────────────────────────────

struct MemStore(Movable):
    var names: List[String]
    var data: List[List[UInt8]]
    var live: List[Bool]
    var io_methods: Int  # address of the shared io_methods table
    var temp_count: Int

    def __init__(out self):
        self.names = List[String]()
        self.data = List[List[UInt8]]()
        self.live = List[Bool]()
        self.io_methods = 0
        self.temp_count = 0

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.live[i] and self.names[i] == name:
                return i
        return -1

    def create(mut self, name: String) -> Int:
        self.names.append(name)
        self.data.append(List[UInt8]())
        self.live.append(True)
        return len(self.names) - 1


def _store(addr: Int) -> Pointer[MemStore, MutAnyOrigin]:
    return Pointer[MemStore, MutAnyOrigin](unsafe_from_address=addr)


# ── sqlite3_io_methods: one open file ─────────────────────────────────────────

def io_close(file: Int) abi("C") -> Int32:
    return 0


def io_read(file: Int, buf: Int, amt: Int32, ofst: Int64) abi("C") -> Int32:
    ref s = _store(peek64(file + 8))[]
    ref d = s.data[peek64(file + 16)]
    var n = Int(amt)
    var at = Int(ofst)
    var out = _bytes(buf)
    var rc = Int32(SQLITE_OK)
    for i in range(n):
        if at + i < len(d):
            out[unsafe_offset=i] = d[at + i]
        else:
            out[unsafe_offset=i] = 0
            rc = Int32(SQLITE_IOERR_SHORT_READ)
    return rc


def io_write(file: Int, buf: Int, amt: Int32, ofst: Int64) abi("C") -> Int32:
    ref s = _store(peek64(file + 8))[]
    ref d = s.data[peek64(file + 16)]
    var n = Int(amt)
    var at = Int(ofst)
    if at + n > len(d):
        d.resize(at + n, 0)
    var src = _bytes(buf)
    for i in range(n):
        d[at + i] = src[unsafe_offset=i]
    return 0


def io_truncate(file: Int, size: Int64) abi("C") -> Int32:
    ref s = _store(peek64(file + 8))[]
    s.data[peek64(file + 16)].resize(Int(size), 0)
    return 0


def io_sync(file: Int, flags: Int32) abi("C") -> Int32:
    return 0


def io_file_size(file: Int, res: Int) abi("C") -> Int32:
    ref s = _store(peek64(file + 8))[]
    poke_i64(res, Int64(len(s.data[peek64(file + 16)])))
    return 0


def io_lock(file: Int, level: Int32) abi("C") -> Int32:
    return 0


def io_unlock(file: Int, level: Int32) abi("C") -> Int32:
    return 0


def io_check_reserved(file: Int, res: Int) abi("C") -> Int32:
    poke32(res, 0)
    return 0


def io_file_control(file: Int, op: Int32, arg: Int) abi("C") -> Int32:
    return Int32(SQLITE_NOTFOUND)


def io_sector_size(file: Int) abi("C") -> Int32:
    return 4096


def io_device_chars(file: Int) abi("C") -> Int32:
    return 0


# ── sqlite3_vfs ───────────────────────────────────────────────────────────────

def vfs_open(vfs: Int, zname: Int, file: Int, flags: Int32, out_flags: Int) abi("C") -> Int32:
    ref s = _store(peek64(vfs + 32))[]
    var name: String
    if zname == 0:
        s.temp_count += 1
        name = "temp-" + String(s.temp_count)
    else:
        name = cstr(zname)
    var idx = s.find(name)
    if idx < 0:
        if (Int(flags) & 0x4) == 0:  # SQLITE_OPEN_CREATE
            return Int32(SQLITE_CANTOPEN)
        idx = s.create(name)
    poke64(file, s.io_methods)
    poke64(file + 8, peek64(vfs + 32))
    poke64(file + 16, idx)
    if out_flags != 0:
        poke32(out_flags, flags)
    return 0


def vfs_delete(vfs: Int, zname: Int, sync_dir: Int32) abi("C") -> Int32:
    ref s = _store(peek64(vfs + 32))[]
    var idx = s.find(cstr(zname))
    if idx >= 0:
        s.live[idx] = False
        s.data[idx] = List[UInt8]()
    return 0


def vfs_access(vfs: Int, zname: Int, flags: Int32, res: Int) abi("C") -> Int32:
    ref s = _store(peek64(vfs + 32))[]
    poke32(res, Int32(1) if s.find(cstr(zname)) >= 0 else Int32(0))
    return 0


def vfs_full_pathname(vfs: Int, zname: Int, n_out: Int32, res: Int) abi("C") -> Int32:
    var i = 0
    while i < Int(n_out) - 1:
        var b = _bytes(zname)[unsafe_offset=i]
        _bytes(res)[unsafe_offset=i] = b
        if b == 0:
            return 0
        i += 1
    _bytes(res)[unsafe_offset=i] = 0
    return 0


def vfs_randomness(vfs: Int, n: Int32, res: Int) abi("C") -> Int32:
    var x = UInt64(0x9E3779B97F4A7C15)
    for i in range(Int(n)):
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        _bytes(res)[unsafe_offset=i] = UInt8((x * 0x2545F4914F6CDD1D) >> 56)
    return n


def vfs_sleep(vfs: Int, micros: Int32) abi("C") -> Int32:
    return micros


def vfs_current_time(vfs: Int, res: Int) abi("C") -> Int32:
    poke_f64(res, 2460000.5)  # a Julian day; SQLite's own clock is not what is under test
    return 0


def vfs_last_error(vfs: Int, n: Int32, res: Int) abi("C") -> Int32:
    return 0


# ── Function addresses ────────────────────────────────────────────────────────
#
# `Int(f)` and `rebind` do not compile for a function value. Writing it into a slot typed as
# the function and reading the same bytes back as an `Int` does. One alias per signature.

comptime F_close = def(Int) thin abi("C") -> Int32
comptime F_rw = def(Int, Int, Int32, Int64) thin abi("C") -> Int32
comptime F_trunc = def(Int, Int64) thin abi("C") -> Int32
comptime F_int = def(Int, Int32) thin abi("C") -> Int32
comptime F_ptr = def(Int, Int) thin abi("C") -> Int32
comptime F_ctl = def(Int, Int32, Int) thin abi("C") -> Int32
comptime F_one = def(Int) thin abi("C") -> Int32
comptime F_open = def(Int, Int, Int, Int32, Int) thin abi("C") -> Int32
comptime F_del = def(Int, Int, Int32) thin abi("C") -> Int32
comptime F_acc = def(Int, Int, Int32, Int) thin abi("C") -> Int32
comptime F_full = def(Int, Int, Int32, Int) thin abi("C") -> Int32
comptime F_rnd = def(Int, Int32, Int) thin abi("C") -> Int32


def _addr[F: Movable](var f: F) -> Int:
    var slot = alloc[F](1)
    slot.unsafe_write(f^)
    return peek64(Int(slot))


# ── Registration ──────────────────────────────────────────────────────────────

# Register a VFS called `name`. Returns the address of its store, so a caller can look at the
# bytes SQLite wrote. The name string must outlive the VFS, so it is leaked on purpose.
def register(lib: OwnedDLHandle, name: String, make_default: Bool) raises -> Int:
    var store_slot = alloc[MemStore](1)
    store_slot.unsafe_write(MemStore())
    var store_addr = Int(store_slot)

    # sqlite3_io_methods, shared by every file
    var io = alloc[UInt8](112)
    for i in range(112):
        io[unsafe_offset=i] = 0
    var io_addr = Int(io)
    poke32(io_addr, 1)
    poke64(io_addr + 8, _addr[F_close](io_close))
    poke64(io_addr + 16, _addr[F_rw](io_read))
    poke64(io_addr + 24, _addr[F_rw](io_write))
    poke64(io_addr + 32, _addr[F_trunc](io_truncate))
    poke64(io_addr + 40, _addr[F_int](io_sync))
    poke64(io_addr + 48, _addr[F_ptr](io_file_size))
    poke64(io_addr + 56, _addr[F_int](io_lock))
    poke64(io_addr + 64, _addr[F_int](io_unlock))
    poke64(io_addr + 72, _addr[F_ptr](io_check_reserved))
    poke64(io_addr + 80, _addr[F_ctl](io_file_control))
    poke64(io_addr + 88, _addr[F_one](io_sector_size))
    poke64(io_addr + 96, _addr[F_one](io_device_chars))
    _store(store_addr)[].io_methods = io_addr

    # sqlite3_vfs
    var v = alloc[UInt8](192)
    for i in range(192):
        v[unsafe_offset=i] = 0
    var va = Int(v)
    var leaked = alloc[UInt8](name.byte_length() + 1)
    for i in range(name.byte_length()):
        leaked[unsafe_offset=i] = name.as_bytes()[i]
    leaked[unsafe_offset=name.byte_length()] = 0
    poke32(va, 1)
    poke32(va + 4, Int32(FILE_SIZE))
    poke32(va + 8, Int32(MAX_PATH))
    poke64(va + 24, Int(leaked))
    poke64(va + 32, store_addr)
    poke64(va + 40, _addr[F_open](vfs_open))
    poke64(va + 48, _addr[F_del](vfs_delete))
    poke64(va + 56, _addr[F_acc](vfs_access))
    poke64(va + 64, _addr[F_full](vfs_full_pathname))
    poke64(va + 104, _addr[F_rnd](vfs_randomness))
    poke64(va + 112, _addr[F_int](vfs_sleep))
    poke64(va + 120, _addr[F_ptr](vfs_current_time))
    poke64(va + 128, _addr[F_rnd](vfs_last_error))
    var rc = lib.call["sqlite3_vfs_register", Int32](va, 1 if make_default else 0)
    if rc != 0:
        raise Error("sqlite3_vfs_register failed: " + String(rc))
    return store_addr


def store_file_size(store_addr: Int, name: String) -> Int:
    ref s = _store(store_addr)[]
    var idx = s.find(name)
    if idx < 0:
        return -1
    return len(s.data[idx])
