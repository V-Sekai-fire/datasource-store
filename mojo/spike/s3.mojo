from std.ffi import OwnedDLHandle
from std.memory import alloc

comptime XSleep = def(Int, Int32) thin abi("C") -> Int32

def my_sleep(vfs: Int, micros: Int32) abi("C") -> Int32:
    print("xSleep, a Mojo function, called by SQLite with", micros, "microseconds")
    return micros

def fn_addr_xsleep(f: XSleep) -> Int:
    var slot = alloc[XSleep](1)
    slot.unsafe_write(f)
    return Pointer[Int, MutAnyOrigin](unsafe_from_address=Int(slot))[unsafe_offset=0]

def main() raises:
    var lib = OwnedDLHandle("/usr/lib/libsqlite3.dylib")
    var base = lib.call["sqlite3_vfs_find", Int](0)  # the default VFS
    print("default vfs found:", base != 0)
    var mine = alloc[UInt8](192)
    var src = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=base)
    for i in range(160):
        mine[unsafe_offset=i] = src[unsafe_offset=i]
    var name = String("mojo-test")
    Pointer[Int, MutAnyOrigin](unsafe_from_address=Int(mine) + 24)[unsafe_offset=0] = Int(name.unsafe_ptr())
    Pointer[Int, MutAnyOrigin](unsafe_from_address=Int(mine) + 112)[unsafe_offset=0] = fn_addr_xsleep(my_sleep)
    var rc = lib.call["sqlite3_vfs_register", Int32](Int(mine), 1)  # and make it the default
    print("register rc", rc)
    var slept = lib.call["sqlite3_sleep", Int32](3)
    print("sqlite3_sleep returned", slept)
