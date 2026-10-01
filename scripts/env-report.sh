#!/usr/bin/env bash
# Prints the properties of the runner image that the validation depends on and
# writes them as KEY=VALUE lines to the file named by the first argument.
#   env-report.sh <out.env>
set -u
out=${1:-env-report.env}
: > "$out"
# The file is sourced by the workflow, hence the quoting.
kv() { echo "$1=\"$2\"" >> "$out"; echo "$1=$2"; }

echo "== operating system"
sw_vers
uname -a
kv MACOS_VERSION "$(sw_vers -productVersion)"
kv MACOS_BUILD "$(sw_vers -buildVersion)"
kv ARCH "$(uname -m)"
kv IMAGE_OS "${ImageOS:-unset}"
kv IMAGE_VERSION "${ImageVersion:-unset}"
kv RUNNER_NAME "${RUNNER_NAME:-unset}"
echo "== xcode"
xcodebuild -version
kv XCODE_VERSION "$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
kv XCODE_SELECT "$(xcode-select -p)"
sdk=$(xcrun --show-sdk-path)
kv SDK_PATH "$sdk"
kv SDK_VERSION "$(xcrun --show-sdk-version)"
echo "== arm64e.x1 in the selected SDK"
tbd="$sdk/usr/lib/libSystem.tbd"
if [ -f "$tbd" ]; then
  if grep -q 'arm64e\.x1' "$tbd"; then
    kv X1_IN_LIBSYSTEM_TBD yes
    grep -n -m 3 'arm64e\.x1' "$tbd" | cut -c1-200
  else
    kv X1_IN_LIBSYSTEM_TBD no
  fi
  head -n 8 "$tbd" | cut -c1-200
else
  kv X1_IN_LIBSYSTEM_TBD "no-libSystem.tbd"
fi
echo "== arm64e.x1 in every SDK found on the image"
for d in /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs /Library/Developer/CommandLineTools/SDKs; do
  for s in "$d"/*.sdk; do
    [ -d "$s" ] || continue
    if grep -q 'arm64e\.x1' "$s/usr/lib/libSystem.tbd" 2>/dev/null; then r=yes; else r=no; fi
    echo "$s arm64e.x1=$r"
  done
done
