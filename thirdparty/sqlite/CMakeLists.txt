# SQLite as a static library the store links, instead of the system copy. See
# `../../CMakeLists.txt`. This is the first slice of Rung 10 (btree fork): the
# amalgamation is dropped in verbatim and the build shape is verified against
# the existing store proofs and benchmarks, with `btree.c` still upstream. A
# later slice cuts `btree.c` out of the amalgamation and links a replacement
# from `../../btree-fdb/` in its place.
#
# Version pin: 3.40.1, matching what Debian bookworm-slim ships as
# `libsqlite3-0`. Kept as-shipped from sqlite.org so a reader can diff against
# the upstream tarball; no local edits.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT) AND sqlite-blessing
cmake_minimum_required(VERSION 3.22)

option(WEFT_BTREE_FDB "Replace SQLite's btree.c with btree-fdb/btree_fdb_stubs.inl" OFF)

if(WEFT_BTREE_FDB)
  # Slice 2 (Rung 10): the vendored amalgamation stays pristine, but the
  # build produces a patched copy `sqlite3_weftbtree.c` whose btree.c section
  # is excised and replaced by an `#include` of the stubs file. `awk` finds
  # the section markers written into the amalgamation by sqlite.org and
  # snips lines [Begin file btree.c] .. [End of btree.c] inclusive.
  set(SQLITE_SRC ${CMAKE_CURRENT_BINARY_DIR}/sqlite3_weftbtree.c)
  set(BTREE_STUBS ${CMAKE_CURRENT_SOURCE_DIR}/../../btree-fdb/btree_fdb_stubs.inl)
  set(PAGER_STUBS ${CMAKE_CURRENT_SOURCE_DIR}/../../btree-fdb/pager_fdb_stubs.inl)
  set(WAL_STUBS   ${CMAKE_CURRENT_SOURCE_DIR}/../../btree-fdb/wal_fdb_stubs.inl)
  add_custom_command(
    OUTPUT ${SQLITE_SRC}
    COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/patch_amalgamation.py
      --in ${CMAKE_CURRENT_SOURCE_DIR}/sqlite3.c
      --out ${SQLITE_SRC}
      --btree-stubs ${BTREE_STUBS}
      --pager-stubs ${PAGER_STUBS}
      --wal-stubs ${WAL_STUBS}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/sqlite3.c
            ${BTREE_STUBS} ${PAGER_STUBS} ${WAL_STUBS}
            ${CMAKE_CURRENT_SOURCE_DIR}/patch_amalgamation.py
    COMMENT "Patching sqlite3.c: excise btree.c + pager.c + wal.c")
else()
  set(SQLITE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/sqlite3.c)
endif()

add_library(weft_sqlite3 STATIC ${SQLITE_SRC})
target_include_directories(weft_sqlite3 PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
set_property(TARGET weft_sqlite3 PROPERTY POSITION_INDEPENDENT_CODE ON)

# The omits shrink the surface. Shared-cache and autovacuum are the ones
# `spec/BtreeReplacement.lean` calls out as reducing the shim's ~97 entry
# points by roughly ten. Load-extension stays on because sqlite-jdbc uses it
# in the roundtable path. Threadsafe=2 (SERIALIZED-off, MULTI-THREAD on) is
# what `store.cpp`'s per-avatar handle already assumes; the store gives one
# thread one handle by construction, so there is no need to pay SQLite's
# global-mutex cost.
target_compile_definitions(weft_sqlite3 PUBLIC
  SQLITE_THREADSAFE=2
  SQLITE_OMIT_SHARED_CACHE
  SQLITE_OMIT_AUTOVACUUM
  SQLITE_OMIT_DEPRECATED
  SQLITE_ENABLE_LOAD_EXTENSION
  SQLITE_DEFAULT_MEMSTATUS=0)

target_link_libraries(weft_sqlite3 PUBLIC ${CMAKE_DL_LIBS})

# Silence upstream warnings — the vendored copy is not linted here, since
# a reader is supposed to diff against sqlite.org rather than us.
if(NOT MSVC)
  target_compile_options(weft_sqlite3 PRIVATE
    -w
    -Wno-unused-parameter
    -Wno-unused-function
    # Rung 10 Slice 2c: -O3 elides sqlite3_file_control's else branch as
    # "unreachable" when it inlines our stubbed sqlite3Pager* accessors and
    # can prove fd's provenance too tightly. Drop to -O1 for the amalgamation
    # only — everything else in the tree stays at project optimisation level.
    -O1)
endif()
