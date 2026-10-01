#!/usr/bin/env bash
# Configures and builds lld, and llvm-objdump (which provides llvm-otool), from
# a llvm-project checkout, and packs the result.
#   build-lld.sh <llvm-project-dir> <build-dir> <out-dir>
# The out-dir receives lld-macos-arm64.tar and build-info.env. ccache is used
# when it is installed; its directory is taken from CCACHE_DIR.
set -euo pipefail
src=$1
build=$2
out=$3
mkdir -p "$out"
out=$(cd "$out" && pwd)

ncpu=$(sysctl -n hw.ncpu)
memgb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
jobs=$(( ncpu + 1 ))
maxjobs=$(( memgb * 2 / 3 ))
[ "$maxjobs" -lt 1 ] && maxjobs=1
[ "$jobs" -gt "$maxjobs" ] && jobs=$maxjobs
echo "host: ncpu=$ncpu memory=${memgb}GB ninja-jobs=$jobs"

launcher=()
if command -v ccache >/dev/null 2>&1; then
  ccache --max-size=2G >/dev/null
  ccache --zero-stats >/dev/null
  launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

t0=$(date +%s)
cmake -S "$src/llvm" -B "$build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=lld \
  -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  ${launcher[@]+"${launcher[@]}"}
t1=$(date +%s)

ninja -C "$build" -j "$jobs" lld
t2=$(date +%s)

objdump=built
if ! ninja -C "$build" -j "$jobs" llvm-objdump; then
  objdump=failed
fi
t3=$(date +%s)

[ -e "$build/bin/ld64.lld" ] || ln -s lld "$build/bin/ld64.lld"
if [ "$objdump" = built ] && [ ! -e "$build/bin/llvm-otool" ]; then
  ln -s llvm-objdump "$build/bin/llvm-otool"
fi

echo "== lld version"
"$build/bin/ld64.lld" --version
echo "== lld dynamic dependencies"
otool -L "$build/bin/lld"
if otool -L "$build/bin/lld" | tail -n +2 | grep -v -E '^[[:space:]]+(/usr/lib/|/System/)'; then
  echo "unexpected non-system dependency" >&2
  exit 1
fi
ls -l "$build/bin/lld" "$build/bin/ld64.lld"
[ "$objdump" = built ] && ls -l "$build/bin/llvm-objdump" "$build/bin/llvm-otool"

members=(bin/lld bin/ld64.lld)
[ "$objdump" = built ] && members+=(bin/llvm-objdump bin/llvm-otool)
tar -C "$build" -cf "$out/lld-macos-arm64.tar" "${members[@]}"

{
  echo "NINJA_JOBS=$jobs"
  echo "HOST_NCPU=$ncpu"
  echo "HOST_MEMORY_GB=$memgb"
  echo "CONFIGURE_SECONDS=$(( t1 - t0 ))"
  echo "LLD_BUILD_SECONDS=$(( t2 - t1 ))"
  echo "OBJDUMP_BUILD=$objdump"
  echo "OBJDUMP_BUILD_SECONDS=$(( t3 - t2 ))"
  echo "LLD_VERSION=$("$build/bin/ld64.lld" --version | head -n 1)"
  echo "LLD_BYTES=$(stat -f %z "$build/bin/lld")"
} | tee "$out/build-info.env"
if command -v ccache >/dev/null 2>&1; then ccache --show-stats; fi
