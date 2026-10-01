#!/usr/bin/env bash
# Composes the trimmed toolchain from the official LLVM macOS package and the
# lld built from the release branch.
#   compose.sh <official-package.tar.xz> <lld-dir> <out-dir>
#
# <lld-dir> holds bin/lld, bin/ld64.lld and optionally bin/llvm-objdump and
# bin/llvm-otool as produced by build-lld.sh. When <lld-dir> is "-", the lld of
# the official package stands in for it (used only to test the composition
# itself; the manifest then states the substitution).
#
# Environment: BASE_VER (e.g. 23.1.2), LLD_COMMIT (full sha), PKG_SHA256,
# RUN_URL (all optional, recorded in the manifest).
#
# Output, below <out-dir>:
#   listing/official-package-listing.txt   verbose listing of the package
#   listing/package-facts.env              libc++ and std module facts
#   stock/stock-lld.tar                    the lld of the official package
#   dist/<name>.tar.xz, .sha256, MANIFEST.txt
set -euo pipefail

pkg=$1
lld_dir=$2
out=$3
base_ver=${BASE_VER:-unknown}
lld_commit=${LLD_COMMIT:-unknown}
name="llvm-${base_ver}-x1-macos-arm64"

mkdir -p "$out"
out=$(cd "$out" && pwd)
mkdir -p "$out/listing" "$out/stock" "$out/dist" "$out/work"
work=$out/work

echo "== listing the official package"
tar -tvf "$pkg" > "$out/listing/official-package-listing.txt"
tar -tf "$pkg" > "$work/names.txt"
wc -l "$out/listing/official-package-listing.txt"
head -n 5 "$work/names.txt"

top=$(head -n 1 "$work/names.txt" | cut -d/ -f1)
case "$top" in
  bin|lib|include|share|libexec) top="" ;;
esac
echo "top-level directory of the package: '${top}'"
if [ -n "$top" ]; then pre="${top}/"; else pre=""; fi

has() { if grep -E -q "$1" "$work/names.txt"; then echo yes; else echo no; fi; }
facts=$out/listing/package-facts.env
{
  echo "PACKAGE_ENTRIES=$(wc -l < "$work/names.txt" | tr -d ' ')"
  echo "LIBCXX_HEADERS=$(has '(^|/)include/c\+\+/v1/')"
  echo "LIBCXX_LIBRARIES=$(has '(^|/)lib/libc\+\+[^/]*\.(dylib|a|tbd)$')"
  echo "STD_MODULE_SOURCE=$(has '(^|/)share/libc\+\+/v1/std\.cppm$')"
  echo "STD_COMPAT_MODULE_SOURCE=$(has '(^|/)share/libc\+\+/v1/std\.compat\.cppm$')"
  echo "MODULES_JSON=$(has '(^|/)lib/libc\+\+\.modules\.json$')"
} | tee "$facts"
echo "== every package entry that mentions c++ or libc++ (first 60)"
grep -E 'c\+\+' "$work/names.txt" | head -n 60 || true
echo "== bin entries"
grep -E "^${pre}bin/[^/]+$" "$work/names.txt" | sed "s#^${pre}##" | tr '\n' ' ' | fold -w 150
echo

echo "== selecting members"
tools="clang-[0-9]+ clang clang\+\+ lld ld64\.lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-otool llvm-objdump"
{
  for t in $tools; do grep -E "^${pre}bin/${t}\$" "$work/names.txt" || true; done
  grep -E "^${pre}lib/clang/" "$work/names.txt" || true
  grep -E "^${pre}include/c\+\+/" "$work/names.txt" || true
  grep -E "^${pre}lib/(libc\+\+|libc\+\+abi|libunwind)[^/]*\$" "$work/names.txt" || true
  grep -E "^${pre}lib/libc\+\+\.modules\.json\$" "$work/names.txt" || true
  grep -E "^${pre}share/libc\+\+/" "$work/names.txt" || true
  grep -E "^${pre}(LICENSE|LICENSE\.TXT|NOTICE)\$" "$work/names.txt" || true
} | sort -u > "$work/members.txt"
wc -l "$work/members.txt"

echo "== extracting"
mkdir -p "$work/staging"
tar -xf "$pkg" -C "$work/staging" -T "$work/members.txt"
src=$work/staging/${top}
[ -d "$src/bin" ] || { echo "no bin directory in the extracted package" >&2; exit 1; }
du -sh "$src"

real_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

tree=$work/tree/$name
mkdir -p "$tree/bin" "$tree/lib"
origins=$work/origins.txt
: > "$origins"

# Copies one tool of the package as a regular file; a name that is a symlink in
# the package becomes a relative symlink to the real file.
place_tool() {
  local n=$1 p="$src/bin/$1" real base
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then echo "absent in package: $n"; return 0; fi
  real=$(real_of "$p")
  case "$real" in "$src"/bin/*) ;; *) echo "skipping $n: resolves outside bin ($real)"; return 0 ;; esac
  if [ ! -e "$real" ]; then echo "skipping $n: dangling link ($real)"; return 0; fi
  base=$(basename "$real")
  if [ ! -e "$tree/bin/$base" ]; then
    cp -p "$real" "$tree/bin/$base"
    echo "bin/$base  official $name package" >> "$origins"
  fi
  if [ "$n" != "$base" ] && [ ! -L "$tree/bin/$n" ] && [ ! -e "$tree/bin/$n" ]; then
    ln -s "$base" "$tree/bin/$n"
    echo "bin/$n  symlink to $base" >> "$origins"
  fi
}
for f in "$src"/bin/clang-[0-9]*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  place_tool "$(basename "$f")"
done
for t in clang 'clang++' llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-otool; do
  place_tool "$t"
done

# Hard-linked or copied duplicates (clang, clang++, llvm-ranlib, ...) that were
# placed as separate regular files become symlinks to the first identical file.
hashes=$work/hashes.txt
: > "$hashes"
for f in "$tree"/bin/*; do
  if [ -L "$f" ]; then continue; fi
  h=$(shasum -a 256 "$f" | cut -d' ' -f1)
  first=$(grep "^$h " "$hashes" | head -n 1 | cut -d' ' -f2 || true)
  if [ -n "$first" ]; then
    rm -f "$f"
    ln -s "$first" "$f"
    echo "bin/$(basename "$f")  symlink to $first (identical content)" >> "$origins"
  else
    echo "$h $(basename "$f")" >> "$hashes"
  fi
done

# The stock lld of the official package (negative control, and the stand-in when requested).
stock=$work/stock-tree
mkdir -p "$stock/bin"
stock_real=$(real_of "$src/bin/lld")
cp -p "$stock_real" "$stock/bin/lld"
ln -s lld "$stock/bin/ld64.lld"
"$stock/bin/ld64.lld" --version | head -n 1 | tee "$out/stock/stock-lld-version.txt"
tar -C "$stock" -cf "$out/stock/stock-lld.tar" bin/lld bin/ld64.lld

# The lld under test.
if [ "$lld_dir" = "-" ]; then
  fixed=$stock
  lld_origin="official $base_ver package (SUBSTITUTION: the lld under test was not built)"
else
  fixed=$lld_dir
  lld_origin="built from llvm-project $lld_commit"
fi
rm -f "$tree/bin/lld" "$tree/bin/ld64.lld"
cp -p "$fixed/bin/lld" "$tree/bin/lld"
ln -s lld "$tree/bin/ld64.lld"
echo "bin/lld  $lld_origin" >> "$origins"
echo "bin/ld64.lld  symlink to lld" >> "$origins"
if [ "$lld_dir" != "-" ] && [ -e "$fixed/bin/llvm-objdump" ]; then
  rm -f "$tree/bin/llvm-objdump" "$tree/bin/llvm-otool"
  cp -p "$fixed/bin/llvm-objdump" "$tree/bin/llvm-objdump"
  ln -s llvm-objdump "$tree/bin/llvm-otool"
  echo "bin/llvm-objdump  built from llvm-project $lld_commit" >> "$origins"
  echo "bin/llvm-otool  symlink to llvm-objdump" >> "$origins"
fi

# Resource directory and libc++ material, moved as they are in the package.
if [ -d "$src/lib/clang" ]; then
  mv "$src/lib/clang" "$tree/lib/clang"
  echo "lib/clang  official $name package (clang resource directory)" >> "$origins"
fi
if [ -d "$src/include/c++" ]; then
  mkdir -p "$tree/include"
  mv "$src/include/c++" "$tree/include/c++"
  echo "include/c++  official package (libc++ headers)" >> "$origins"
fi
for f in "$src"/lib/libc++* "$src"/lib/libunwind*; do
  if [ -e "$f" ] || [ -L "$f" ]; then
    mv "$f" "$tree/lib/"
    echo "lib/$(basename "$f")  official package (libc++ family)" >> "$origins"
  fi
done
if [ -d "$src/share/libc++" ]; then
  mkdir -p "$tree/share"
  mv "$src/share/libc++" "$tree/share/libc++"
  echo "share/libc++  official package (libc++ module sources)" >> "$origins"
fi
for f in "$src"/LICENSE "$src"/LICENSE.TXT "$src"/NOTICE; do
  [ -e "$f" ] && cp -p "$f" "$tree/" && echo "$(basename "$f")  official package" >> "$origins"
done
true

echo "== composed tree"
( cd "$tree" && find . -maxdepth 2 | sort | head -n 80 )
ls -l "$tree/bin"
for d in "$tree"/lib/clang/*; do echo "resource dir: $d"; du -sh "$d"; done 2>/dev/null || true
du -sh "$tree"
echo "== dynamic dependencies of the clang binary"
otool -L "$tree"/bin/clang-[0-9]* | head -n 20

echo "== smoke test of the composed tree"
sdk=$(xcrun --show-sdk-path)
"$tree/bin/clang" --version
"$tree/bin/clang" -print-resource-dir
"$tree/bin/ld64.lld" --version
printf '#include <stdio.h>\nint main(void){puts("smoke");return 0;}\n' > "$work/smoke.c"
"$tree/bin/clang" -fuse-ld=lld -isysroot "$sdk" "$work/smoke.c" -o "$work/smoke"
"$work/smoke"

echo "== manifest"
{
  echo "name: $name"
  echo "purpose: trimmed LLVM toolchain for validation; clang and the resource directory are the official ${base_ver} ones, lld is built from the release branch"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "${RUN_URL:-}" ] && echo "workflow run: $RUN_URL"
  echo "official package: LLVM-${base_ver}-macOS-ARM64.tar.xz sha256 ${PKG_SHA256:-unknown}"
  echo "lld source: llvm-project commit $lld_commit (release/23.x)"
  echo "lld version: $("$tree/bin/ld64.lld" --version | head -n 1)"
  echo "stock lld version: $(cat "$out/stock/stock-lld-version.txt")"
  echo "clang version: $("$tree/bin/clang" --version | head -n 1)"
  echo
  echo "facts about the official package (from its listing):"
  sed 's/^/  /' "$facts"
  echo
  echo "origin of each component:"
  sed 's/^/  /' "$origins"
  echo
  echo "layout:"
  ( cd "$tree" && find . -maxdepth 3 -not -path './lib/clang/*/*' -not -path './include/c++/*/*' | sort | sed 's/^/  /' )
} > "$tree/MANIFEST.txt"
cat "$tree/MANIFEST.txt"

echo "== packing"
export COPYFILE_DISABLE=1
tar -C "$work/tree" -cJf "$out/dist/$name.tar.xz" "$name"
( cd "$out/dist" && shasum -a 256 "$name.tar.xz" > "$name.tar.xz.sha256" )
cp "$tree/MANIFEST.txt" "$out/dist/MANIFEST.txt"
ls -l "$out/dist"
cat "$out/dist/$name.tar.xz.sha256"
echo "uncompressed tree: $(du -sk "$tree" | cut -f1) KiB"
echo "SIZE_BYTES=$(stat -f %z "$out/dist/$name.tar.xz")" | tee -a "$facts"
echo "SHA256=$(cut -d' ' -f1 "$out/dist/$name.tar.xz.sha256")" | tee -a "$facts"
