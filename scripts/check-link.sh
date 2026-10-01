#!/usr/bin/env bash
# Compiles, links and runs test programs with a toolchain directory against the
# SDK of the running machine, with lld as the linker.
#   [LAB_SDK=<sdk-path>] check-link.sh <toolchain-dir> <work-dir>
# Each step leaves <step>.log in the work directory and a line in results.env.
# The script reports and does not abort on a failing step; the calling job
# asserts the outcome it expects.
set -u
tc=$(cd "$1" && pwd)
mkdir -p "$2"
work=$(cd "$2" && pwd)
cd "$work" || exit 2
sdk=${LAB_SDK:-$(xcrun --show-sdk-path)}   # LAB_SDK selects another SDK
cxx=$tc/bin/clang++
cc=$tc/bin/clang
: > results.env
record() { echo "$1=$2" >> results.env; echo "RESULT $1=$2"; }  # values never contain spaces
show() { sed 's/^/    | /' "$1"; }

echo "toolchain: $tc"
echo "sdk: $sdk"
echo "linker version: $("$tc/bin/ld64.lld" --version | head -n 1)"
"$tc/bin/ld64.lld" --version | head -n 1 > linker-version.txt
echo "clang: $("$cxx" --version | head -n 1)"

cat > hello.cpp <<'SRC'
#include <format>
#include <iostream>
#include <vector>

int main() {
  std::vector<int> v{1, 2, 3};
  int sum = 0;
  for (int x : v) sum += x;
  std::cout << std::format("sum={} count={}", sum, v.size()) << '\n';
  return sum == 6 ? 0 : 1;
}
SRC
cat > hello.c <<'SRC'
#include <stdio.h>

int main(void) {
  puts("hello from C");
  return 0;
}
SRC

echo "== C++ (iostream, std::vector, std::format)"
"$cxx" -std=c++23 -fuse-ld=lld -isysroot "$sdk" -### hello.cpp -o hello > cxx-driver.log 2>&1
grep -E 'ld64\.lld|"ld"' cxx-driver.log | head -n 1 | cut -c1-300
if "$cxx" -std=c++23 -fuse-ld=lld -isysroot "$sdk" hello.cpp -o hello > cxx-link.log 2>&1; then
  record CXX_LINK pass
  if ./hello > cxx-run.log 2>&1; then record CXX_RUN pass; show cxx-run.log; else record CXX_RUN fail; show cxx-run.log; fi
else
  record CXX_LINK fail
  record CXX_RUN skipped
  show cxx-link.log
fi

echo "== C"
if "$cc" -fuse-ld=lld -isysroot "$sdk" hello.c -o hello_c > c-link.log 2>&1; then
  record C_LINK pass
  if ./hello_c > c-run.log 2>&1; then record C_RUN pass; show c-run.log; else record C_RUN fail; show c-run.log; fi
else
  record C_LINK fail
  record C_RUN skipped
  show c-link.log
fi

echo "== import std"
if [ -f "$tc/share/libc++/v1/std.cppm" ]; then
  cat > import_std.cpp <<'SRC'
import std;

int main() {
  std::vector<int> v{1, 2, 3};
  std::cout << std::format("import std: {}", v.size()) << '\n';
  return 0;
}
SRC
  if "$cxx" -std=c++23 -stdlib=libc++ -isysroot "$sdk" -Wno-reserved-module-identifier \
       --precompile -x c++-module "$tc/share/libc++/v1/std.cppm" -o std.pcm > std-bmi.log 2>&1 \
     && "$cxx" -std=c++23 -stdlib=libc++ -fuse-ld=lld -isysroot "$sdk" -fmodule-file=std=std.pcm \
          import_std.cpp std.pcm -o import_std > import-std-link.log 2>&1 \
     && ./import_std > import-std-run.log 2>&1; then
    record IMPORT_STD pass
    show import-std-run.log
  else
    record IMPORT_STD fail
    show std-bmi.log
    [ -f import-std-link.log ] && show import-std-link.log
  fi
else
  record IMPORT_STD "not-applicable"
  echo "not applicable: the release package carries no std module sources"
fi

echo "== synthetic stub that lists arm64e.x1 (independent of the SDK)"
cat > libx1.tbd <<'SRC'
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-macos, arm64e-macos, arm64e.x1-macos ]
install-name:    '/usr/lib/libx1.dylib'
current-version: 1
compatibility-version: 1
exports:
  - targets:         [ arm64-macos, arm64e-macos, arm64e.x1-macos ]
    symbols:         [ _x1_function ]
...
SRC
cat > synth.c <<'SRC'
extern int x1_function(void);
int synth_caller(void) { return x1_function(); }
SRC
if "$cc" -target arm64-apple-macos14.0 -isysroot "$sdk" -c synth.c -o synth.o > synth-compile.log 2>&1 \
   && "$tc/bin/ld64.lld" -arch arm64 -platform_version macos 14.0 14.0 -dylib -o libsynth.dylib synth.o libx1.tbd > synth-link.log 2>&1; then
  record SYNTH_LINK pass
else
  record SYNTH_LINK fail
fi
[ -f synth-compile.log ] && show synth-compile.log
[ -f synth-link.log ] && show synth-link.log
echo "== results"
cat results.env
