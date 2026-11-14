from std.ffi import OwnedDLHandle

def main() raises:
    var lib = OwnedDLHandle("/usr/lib/libsqlite3.dylib")
    var n = lib.call["sqlite3_libversion_number", Int32]()
    print("sqlite version number", n)
