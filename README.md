# llvm-macos27-lab

A validation repository. It establishes, by continuous integration on GitHub-hosted runners, whether an `ld64.lld` built from the LLVM `release/23.x` branch links programs against the Xcode 27 macOS SDK, where the stock LLVM 23.1.2 `ld64.lld` does not. It also publishes the toolchain that the validation uses, in a trimmed form, so that other validation repositories can consume it by path as "a developer's own complete toolchain".

## Background

1. The GitHub `xcode-27` runner image (macOS 27 with Xcode 27) is a preview image; see [actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404).
2. The SDK of that image lists the architecture `arm64e.x1` in its `.tbd` text stubs. LLVM 22.x and 23.1.2 `ld64.lld` reject the file:

   ```
   ld64.lld: error: could not load TAPI file at <SDK>/usr/lib/libSystem.tbd: malformed file
   <SDK>/usr/lib/libSystem.tbd:4:20: error: unknown architecture  arm64e.x1-macos, ...
   ```

   The defect is tracked in [mcpp-community/mcpp#669](https://github.com/mcpp-community/mcpp/issues/669). The build tool [mcpp](https://github.com/mcpp-community/mcpp) links macOS programs with `ld64.lld`.
3. The upstream fix is [llvm/llvm-project#222721](https://github.com/llvm/llvm-project/pull/222721) (`main`, commit `b8007a8e4020`), titled "[ld64.lld, llvm-otool] Minimal arm64e.x1 support".
4. Its `release/23.x` backport [llvm/llvm-project#224185](https://github.com/llvm/llvm-project/pull/224185) was closed and merged manually by the release manager: the cherry-pick is commit `532fa5afbe2b` and the follow-up "Avoid abi break" is commit [`ee66426152f9`](https://github.com/llvm/llvm-project/commit/ee66426152f9e7e17f98db4691414ad7cf0c66ea), both dated 2026-09-29.
5. No LLVM release contains the backport yet. `llvmorg-23.1.2` (2026-09-22) is 21 commits before `ee66426152f9`. The release 23.1.3 is expected around 2026-10-06; this is unconfirmed.

## Method

The workflow `.github/workflows/lab.yml` runs five jobs. The pinned inputs are in `refs.env`.

| Job | Runner | Purpose |
| --- | --- | --- |
| `build-lld` | `macos-15` | Builds `lld` (and `llvm-objdump`, which provides `llvm-otool`) from `LLVM_RELEASE_REF`, a `release/23.x` commit at or after `ee66426152f9`, using a shallow fetch, CMake, Ninja and ccache. |
| `compose` | `macos-15` | Downloads the official `LLVM-23.1.2-macOS-ARM64.tar.xz`, records its content (in particular libc++ headers, libc++ libraries and std module sources), and composes a trimmed toolchain in which `ld64.lld` and `lld` are the ones from `build-lld`. |
| `check-x1` | `xcode-27` | Positive test. Compiles, links and runs a C++23 program and a C program with the composed toolchain against the Xcode 27 SDK. |
| `check-x1-negative` | `xcode-27` | Negative control. The same C++ test with the stock 23.1.2 `ld64.lld`. It must fail with `unknown architecture` and `arm64e.x1`; if it links, the job fails because the image no longer exercises the defect and the positive result would not discriminate. |
| `check-macos15` | `macos-15` | Control on an SDK without `arm64e.x1`: both lld variants must succeed. |

On a push to `main`, the composed toolchain is published as a release asset under the tag `toolchain-<first 12 characters of the lld commit>`.

## Results

The table is filled from the pull-request run. Each row cites the run that produced it.

| Run | Job | ImageVersion | Xcode | `arm64e.x1` in SDK `libSystem.tbd` | Refs | Conclusion |
| --- | --- | --- | --- | --- | --- | --- |
| pending | pending | pending | pending | pending | pending | pending |

## Rerun

```
gh workflow run lab.yml --repo speak-agent/llvm-macos27-lab
```

A change of `refs.env` (for example a newer `release/23.x` commit, or `LLVM_BASE_RELEASE=23.1.3` once it exists) is validated through a pull request, which runs the same workflow.

## Licence

Apache-2.0; see `LICENSE`. The published toolchain consists of binaries of the LLVM project, which is distributed under the Apache-2.0 licence with LLVM exceptions.
