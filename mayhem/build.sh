#!/usr/bin/env bash
#
# mayhem/build.sh — build RocksDB's three OSS-Fuzz harnesses (fuzz/db_fuzzer.cc, fuzz/db_map_fuzzer.cc,
# fuzz/sst_file_writer_fuzzer.cc; mayhem/ carries adjusted copies of all three) plus the functional-test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Builds two independent
# CMake trees under the gitignored build/ directory (so `git clean -ffdX` removes both):
#   build/fuzz   librocksdb.a compiled with $SANITIZER_FLAGS $DEBUG_FLAGS + SanCov (fuzzer-no-link)
#   build/tests  librocksdb.a + gtest binaries + the KAT probe with the project's NORMAL flags
# Everything resolves from the image (apt protobuf, libprotobuf-mutator under /opt/toolchains/lpm,
# the in-tree gtest); nothing is fetched, so the offline re-run works and re-running is idempotent.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

LPM=/opt/toolchains/lpm
cd "$SRC"
mkdir -p build

# Flags shared by every sanitized compile. fuzzer-no-link puts SanCov on the library itself, not just
# the harness TU, and stays even when SANITIZER_FLAGS is empty. DEBUG_FLAGS comes last so -gdwarf-3 wins.
FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"

COMMON_CMAKE=(
  -G Ninja
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_BUILD_TYPE=Release
  -DROCKSDB_BUILD_SHARED=OFF -DPORTABLE=1 -DFAIL_ON_WARNINGS=OFF
  -DWITH_GFLAGS=OFF -DWITH_LIBURING=OFF
  -DWITH_TOOLS=OFF -DWITH_CORE_TOOLS=OFF -DWITH_BENCHMARK_TOOLS=OFF -DWITH_TRACE_TOOLS=OFF
)

# CMake caches the compilers it resolved. A build under the ccache masquerade (the image's pre-fill step)
# caches /opt/mayhem/ccache/bin/clang++; re-running with a plain PATH resolves /usr/bin/clang++, CMake then
# wipes the cache mid-configure and falls back to its defaults (Debug, gflags required) and fails. So a tree
# configured with different compilers is discarded here and configured afresh; a same-compiler re-run
# keeps its tree and stays incremental.
drop_tree_if_compiler_changed() {
  local dir="$1" cache="$1/CMakeCache.txt" cc cxx
  [ -f "$cache" ] || return 0
  cc="$(sed -n 's/^CMAKE_C_COMPILER:[A-Z]*=//p' "$cache")"
  cxx="$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' "$cache")"
  if [ "$cc" != "$(command -v "$CC")" ] || [ "$cxx" != "$(command -v "$CXX")" ]; then
    rm -rf "$dir"
  fi
}
drop_tree_if_compiler_changed build/fuzz
drop_tree_if_compiler_changed build/tests

# 1) The sanitized library the fuzzers link.
cmake -S . -B build/fuzz "${COMMON_CMAKE[@]}" -DWITH_TESTS=OFF \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build build/fuzz --target rocksdb -j"$MAYHEM_JOBS"

# 2) Harnesses, each linked twice: libFuzzer engine, and the run-once standalone reproducer.
#    The proto harnesses include "proto/gen/db_operation.pb.h", generated here into build/ (never in-tree).
PROTO_OUT=build/fuzz-proto
mkdir -p "$PROTO_OUT/proto/gen"
protoc --proto_path=fuzz/proto --cpp_out="$PROTO_OUT/proto/gen" fuzz/proto/db_operation.proto

# The library is built -fno-rtti -DNDEBUG with these platform defines; harness TUs must match its ABI
# (an RTTI harness against it fails to link with undefined `typeinfo for rocksdb::DB`).
RDB_DEFS="-DOS_LINUX -DROCKSDB_AUXV_GETAUXVAL_PRESENT -DROCKSDB_FALLOCATE_PRESENT -DROCKSDB_LIB_IO_POSIX \
  -DROCKSDB_MALLOC_USABLE_SIZE -DROCKSDB_NO_DYNAMIC_EXTENSION -DROCKSDB_PLATFORM_POSIX \
  -DROCKSDB_PTHREAD_ADAPTIVE_MUTEX -DROCKSDB_RANGESYNC_PRESENT -DROCKSDB_SCHED_GETCPU_PRESENT"
CXXSTD="-std=gnu++20 -fno-rtti -DNDEBUG $RDB_DEFS"
INC=(-I"$SRC/include" -I"$SRC" -I"$SRC/fuzz" -I"$SRC/$PROTO_OUT" -I"$LPM/include/libprotobuf-mutator")
LPM_LIBS=("$LPM/lib/libprotobuf-mutator-libfuzzer.a" "$LPM/lib/libprotobuf-mutator.a")
# libprotobuf links statically so the target has no uninstrumented shared protobuf to follow at run time.
SYS_LIBS=(-Wl,-Bstatic -lprotobuf -lz -Wl,-Bdynamic -lpthread -ldl -lrt)

# LeakSanitizer off at build time (leaks are not the class this fleet fuzzes); ASan/UBSan stay on.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/standalone_stubs.cc -o build/standalone_stubs.o
$CXX $FUZZ_FLAGS $CXXSTD "${INC[@]}" -c "$PROTO_OUT/proto/gen/db_operation.pb.cc" -o build/db_operation.pb.o

# build_harness <name> [extra objects...] [harness source]; the source defaults to upstream's
# fuzz/<name>.cc, and a trailing *.cc argument overrides it.
build_harness() {
  local name="$1"; shift
  local src="$SRC/fuzz/$name.cc"
  local extra=()
  for a in "$@"; do case "$a" in *.cc) src="$SRC/$a" ;; *) extra+=("$a") ;; esac; done
  $CXX $FUZZ_FLAGS $CXXSTD "${INC[@]}" -c "$src" -o "build/$name.o"
  # libFuzzer binary
  $CXX $FUZZ_FLAGS $LIB_FUZZING_ENGINE "build/$name.o" "${extra[@]}" build/lsan_off.o \
    "${LPM_LIBS[@]}" build/fuzz/librocksdb.a "${SYS_LIBS[@]}" -o "/mayhem/$name"
  # standalone reproducer (no libFuzzer runtime)
  $CXX $FUZZ_FLAGS "build/$name.o" "${extra[@]}" build/lsan_off.o build/standalone_main.o build/standalone_stubs.o \
    "${LPM_LIBS[@]}" build/fuzz/librocksdb.a "${SYS_LIBS[@]}" -o "/mayhem/$name-standalone"
}
# mayhem/db_fuzzer.cc is upstream's harness with a per-process DB path and an empty-input guard (see its header
# comment): the fixed /tmp/testdb path raced between Mayhem's concurrent processes.
build_harness db_fuzzer mayhem/db_fuzzer.cc
# mayhem/db_map_fuzzer.cc is upstream's harness with a per-process DB path (see its header comment): the fixed
# /tmp path raced between Mayhem's concurrent processes.
build_harness db_map_fuzzer build/db_operation.pb.o mayhem/db_map_fuzzer.cc
# mayhem/sst_file_writer_fuzzer.cc is upstream's harness plus one lifetime fix (see its header comment):
# upstream's TableReader outlives the stack objects it points at, so ASan aborts on every input.
build_harness sst_file_writer_fuzzer build/db_operation.pb.o mayhem/sst_file_writer_fuzzer.cc

# 3) Test oracle: the project's NORMAL flags, no sanitizers, no DWARF pin (an honest oracle build).
#    RocksDB's CMake only builds its gtest binaries in a Debug configuration (WITH_TESTS is forced OFF
#    otherwise), so this tree is Debug (RTTI on, asserts on) at -O1 to keep the suites quick.
cmake -S . -B build/tests "${COMMON_CMAKE[@]}" -DCMAKE_BUILD_TYPE=Debug -DWITH_TESTS=ON -DWITH_ALL_TESTS=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_C_FLAGS_DEBUG="-O1 -g" -DCMAKE_CXX_FLAGS_DEBUG="-O1 -g"
cmake --build build/tests --target db_basic_test env_basic_test -j"$MAYHEM_JOBS"
$CXX -O1 $COVERAGE_FLAGS -std=gnu++20 $RDB_DEFS -I"$SRC/include" mayhem/kat/kat.cc build/tests/librocksdb.a \
  -lpthread -ldl -lrt -o build/tests/rocksdb_kat
