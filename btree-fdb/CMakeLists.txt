# Property tests for the order-preserving encoding stated in
# `../spec/BtreeReplacement.lean`. Same shape as `../keys-witness/`:
# witness-cpp for random-plus-shrink property testing, doctest for the
# test-case surface, exception-free build.
#
#   cmake -S btree-fdb -B build-btree-fdb -DCMAKE_BUILD_TYPE=RelWithDebInfo
#   cmake --build build-btree-fdb -j
#   ctest --test-dir build-btree-fdb --output-on-failure
#
# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.19)
project(weft_btree_fdb CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

include(FetchContent)

set(WEFT_WITNESS_CPP_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../../5-repository/witness-cpp")
if(IS_DIRECTORY "${WEFT_WITNESS_CPP_SRC}")
	add_subdirectory("${WEFT_WITNESS_CPP_SRC}" witness-cpp-build EXCLUDE_FROM_ALL)
else()
	FetchContent_Declare(
		witness_cpp
		GIT_REPOSITORY https://github.com/V-Sekai-fire/repository-witness-cpp.git
		GIT_TAG        main
	)
	FetchContent_MakeAvailable(witness_cpp)
endif()

set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
FetchContent_Declare(
	doctest
	GIT_REPOSITORY https://github.com/doctest/doctest.git
	GIT_TAG        v2.4.11
	GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(doctest)

enable_testing()

add_library(weft_btree_fdb_encode STATIC encode.c)
target_include_directories(weft_btree_fdb_encode PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(encode_test main.cpp encode_test.cc)
target_link_libraries(encode_test PRIVATE weft_btree_fdb_encode witness::witness doctest::doctest)
target_compile_options(encode_test PRIVATE -Wall -Wextra)

if(NOT MSVC)
	target_compile_options(encode_test PRIVATE -fno-exceptions -fno-rtti)
	target_compile_definitions(encode_test PRIVATE
		DOCTEST_CONFIG_NO_EXCEPTIONS_BUT_WITH_ALL_ASSERTS)
endif()

include(${doctest_SOURCE_DIR}/scripts/cmake/doctest.cmake)
doctest_discover_tests(encode_test)
