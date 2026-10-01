#!/usr/bin/env bash
# Shallow, sparse fetch of one llvm-project commit: no history, and only the
# directories that the lld and llvm-objdump build needs.
#   fetch-llvm.sh <commit-sha> <directory>
set -euo pipefail
sha=$1
dir=$2
mkdir -p "$dir"
cd "$dir"
git init -q
git remote add origin https://github.com/llvm/llvm-project.git
git sparse-checkout set --cone llvm lld cmake third-party
git fetch --depth 1 --filter=blob:none origin "$sha"
git -c advice.detachedHead=false checkout --detach FETCH_HEAD
test "$(git rev-parse HEAD)" = "$sha"
git log -1 --format='commit %H%ncommitter-date %cI%nsubject %s'
