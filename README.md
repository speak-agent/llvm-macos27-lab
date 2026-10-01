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
| `check-x1` | `xcode-27` | Positive test. First asserts that the macOS major version is 27 and reports the image, Xcode, SDK and the presence of `arm64e.x1` in `libSystem.tbd`. Then compiles, links and runs a C++23 program (`iostream`, `std::vector`, `std::format`), a C program, an `import std;` program (the std module is compiled from the package sources) and a synthetic stub that lists `arm64e.x1`, with the composed toolchain. |
| `check-x1-negative` | `xcode-27` | Negative control. The same tests with the stock 23.1.2 `ld64.lld` in place of the lld under test. The C++ link must fail with a TAPI load failure that names `arm64e.x1` and contains `unknown architecture` (wording of the original report) or `unknown target` (wording observed with 23.1.2); if it links, the job fails because the image no longer exercises the defect and the positive result would not discriminate. |
| `check-macos15` | `macos-15` | Control on an SDK without `arm64e.x1`: both lld variants must link and run the C++, C and `import std;` programs. The synthetic stub must link with the lld under test and must fail with the stock lld. |

On a push to `main`, the composed toolchain is published as a release asset under the tag `toolchain-<first 12 characters of the lld commit>`.

## Results

The rows below come from the workflow run [36870234932](https://github.com/speak-agent/llvm-macos27-lab/actions/runs/36870234932) of the pull request (all jobs concluded `success`). The pinned inputs of that run were `LLVM_RELEASE_REF=21ef2ddb806006eba611b8a769ae72e5f86f9418` (`release/23.x`, 2026-09-30, containing `532fa5afbe2b` and `ee66426152f9`) and `LLVM_BASE_RELEASE=23.1.2`. The lld built from that ref reports `LLD 23.1.3 (https://github.com/llvm/llvm-project.git 21ef2ddb806006eba611b8a769ae72e5f86f9418)`; the stock one reports `LLD 23.1.2 (https://github.com/llvm/llvm-project 85ac560262434c9ccfc0c183ec22d4138ed647fb)`.

| Run | Job | Runner image, ImageVersion | Xcode, SDK | `arm64e.x1` in SDK `libSystem.tbd` | lld | Conclusion |
| --- | --- | --- | --- | --- | --- | --- |
| 36870234932 | `build-lld` | `macos-15-arm64`, 20260907.0337.1 | Xcode 16.4 | not examined | builds `21ef2ddb8060` | success: lld and llvm-objdump built in 1864 s and 14 s (3 cores, 7 GB; ccache restored from a partial cache, 103 of 1966 compilations were hits) |
| 36870234932 | `compose` | `macos-15-arm64`, 20260907.0337.1 | Xcode 16.4 | not examined | `21ef2ddb8060` | success: 77.9 MB toolchain, 439632 KiB unpacked |
| 36870234932 | `check-x1` | `xcode-27-arm64`, 20260928.0222.1 (macOS 27.0, 26A428) | Xcode 27.0 (27A266a), SDK 27.0 | yes | `21ef2ddb8060` | success: C++23 with `std::format`, C and `import std;` link and run; synthetic stub links |
| 36870234932 | `check-x1-negative` | `xcode-27-arm64`, 20260928.0222.1 | Xcode 27.0 (27A266a), SDK 27.0 | yes | stock 23.1.2 | success: the stock lld fails to link C++ and C (`could not load TAPI file`, `unknown target`, `arm64e.x1`); the job asserts this failure |
| 36870234932 | `check-macos15` | `macos-15-arm64`, 20260907.0337.1 (macOS 15.7.9) | Xcode 16.4 (16F6), SDK 15.5 | no | `21ef2ddb8060` and stock 23.1.2 | success: both lld variants link and run C++23, C and `import std;`; only the synthetic stub separates them |

### Evidence

1. The selected SDK of the `xcode-27` image is `MacOSX.sdk` of `/Applications/Xcode_27.app` (SDK 27.0). Its `libSystem.tbd` is a version 4 text stub whose `targets:` list contains `arm64e.x1-macos, arm64e.x1-maccatalyst` (lines 4, 9 and 42); `libc++.tbd` contains them as well. All Xcode 27.x SDKs of the image (27.0, 27.1, 27.1 beta, 27.2, 27.2 beta) and the Command Line Tools `MacOSX27.0.sdk` list `arm64e.x1`; the Command Line Tools `MacOSX26.5.sdk` and `MacOSX26.sdk` do not.
2. The stock 23.1.2 `ld64.lld` rejects the stub. The first lines of the failing C++ link are

   ```
   ld64.lld: error: could not load TAPI file at <SDK>/usr/lib/libc++.tbd: malformed file
   <SDK>/usr/lib/libc++.tbd:4:54: error: unknown target
                      arm64e-macos, arm64e-maccatalyst, arm64e.x1-macos, arm64e.x1-maccatalyst ]
   ld64.lld: error: could not load TAPI file at <SDK>/usr/lib/libSystem.tbd: malformed file
   <SDK>/usr/lib/libSystem.tbd:4:20: error: unknown target
                      arm64e.x1-macos, arm64e.x1-maccatalyst ]
   ```

   followed by undefined-symbol errors that are consequences of the two stubs not loading. The C program fails in the same way on `libSystem.tbd`.
3. The wording in 23.1.2 is `unknown target`, not `unknown architecture` as quoted in the report of the defect. The negative job therefore asserts a TAPI load failure that names `arm64e.x1` and contains `unknown architecture` or `unknown target`. Whether `unknown architecture` is the wording of another LLVM version or of another stub format was not examined.
4. The failure depends on the SDK and not on the runner: on the same `xcode-27` runner the stock lld links and runs the C++, C and `import std;` programs against `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, whose `libSystem.tbd` has no `arm64e.x1` (informational step of `check-x1-negative`).
5. A synthetic stub (`libx1.tbd`, targets `arm64-macos, arm64e-macos, arm64e.x1-macos`) is rejected by the stock lld on both runner images (`unknown target`) and accepted by the lld built from the release branch. It makes the result independent of the SDK of the image.
6. The lld built from `21ef2ddb8060` links, and the programs run, against the Xcode 27.0 SDK: `sum=6 count=3` (C++), `hello from C`, `import std: 3`.

### Conclusion

The `release/23.x` commit `21ef2ddb8060`, which contains the backport of llvm/llvm-project#222721, yields an `ld64.lld` that is usable against the Xcode 27 SDK of the GitHub `xcode-27` image for C and C++23 programs, including `import std;`. The stock 23.1.2 `ld64.lld` is not, and the negative control confirms that this image still exercises the defect. The lld built here can be replaced by the stock one once an LLVM release (23.1.3 is expected) contains the backport.

## Official package content

The official `LLVM-23.1.2-macOS-ARM64.tar.xz` (1569989604 bytes, sha256 `d7c26fc6177e42842e2d1ffaad31aec057c56a924392b1a23d830abe2c5d53b1`, equal to the digest published by GitHub) has 10782 entries and carries all of the following, so the composed toolchain includes them:

| Item | Present |
| --- | --- |
| libc++ headers, `include/c++/v1` | yes |
| libc++ libraries (`libc++.dylib`, `libc++.a`, `libc++abi`, `libunwind`, `libc++experimental.a`) | yes |
| std module sources, `share/libc++/v1/std.cppm` and `std.compat.cppm` | yes |
| `lib/libc++.modules.json` | yes |

The listing of the package is the `official-package-listing` artifact of each run.

## The published toolchain

On a push to `main` the workflow publishes the composed toolchain as the release `toolchain-<first 12 characters of the lld commit>`, here `toolchain-21ef2ddb8060`, with the assets `llvm-23.1.2-x1-macos-arm64.tar.xz`, its `.sha256` and `MANIFEST.txt`. An existing release is never modified.

Layout, relative to the unpacked directory `llvm-23.1.2-x1-macos-arm64`:

| Path | Origin |
| --- | --- |
| `bin/clang`, `bin/clang++` (symlinks), `bin/clang-23` | official 23.1.2 package |
| `bin/lld`, `bin/ld64.lld` (symlink), `bin/llvm-objdump`, `bin/llvm-otool` (symlink) | built from `LLVM_RELEASE_REF` |
| `bin/llvm-ar`, `bin/llvm-ranlib` (symlink), `bin/llvm-nm`, `bin/llvm-objcopy`, `bin/llvm-strip` (symlink) | official 23.1.2 package |
| `lib/clang/23` (resource directory) | official 23.1.2 package |
| `include/c++/v1`, `lib/libc++*`, `lib/libc++abi*`, `lib/libunwind*`, `share/libc++` | official 23.1.2 package |
| `MANIFEST.txt` | generated; states the origin of each component and the lld commit |

Use by path:

```
gh release download toolchain-21ef2ddb8060 --repo speak-agent/llvm-macos27-lab
shasum -a 256 -c llvm-23.1.2-x1-macos-arm64.tar.xz.sha256
tar -xf llvm-23.1.2-x1-macos-arm64.tar.xz
llvm-23.1.2-x1-macos-arm64/bin/clang++ -std=c++23 -fuse-ld=lld -isysroot "$(xcrun --show-sdk-path)" hello.cpp -o hello
```

The release page states the size and the sha256 of the asset.

## Rerun

```
gh workflow run lab.yml --repo speak-agent/llvm-macos27-lab
```

A change of `refs.env` (for example a newer `release/23.x` commit, or `LLVM_BASE_RELEASE=23.1.3` once it exists) is validated through a pull request, which runs the same workflow.

## Licence

Apache-2.0; see `LICENSE`. The published toolchain consists of binaries of the LLVM project, which is distributed under the Apache-2.0 licence with LLVM exceptions.
