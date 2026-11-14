from std.ffi import OwnedDLHandle
from std.memory import alloc

def on_row(arg: Int, n: Int32, vals: Int, names: Int) abi("C") -> Int32:
    print("callback from C, columns =", n)
    return 0

def main() raises:
    var lib = OwnedDLHandle("/usr/lib/libsqlite3.dylib")
    var slot = alloc[Int](1)
    slot[unsafe_offset=0] = 0
    var path = String(":memory:")
    var rc = lib.call["sqlite3_open", Int32](path.unsafe_ptr(), slot)
    var db = slot[unsafe_offset=0]
    print("open rc", rc, "db != 0:", db != 0)
    var sql = String("select 1, 2, 3")
    var rc2 = lib.call["sqlite3_exec", Int32](db, sql.unsafe_ptr(), on_row, 0, 0)
    print("exec rc", rc2)
