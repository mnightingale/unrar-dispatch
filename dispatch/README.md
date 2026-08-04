# ISA-level dispatch for unrar

Build unrar at higher x86-64 microarchitecture levels (or with aarch64 crypto
extensions) and select the right build at runtime — **without modifying the
vendored upstream source**.

`git status` shows no changes to any tracked file. Everything lives here.

## Outcome (both architectures measured)

| Arch | Result | Action |
| --- | --- | --- |
| **Linux aarch64** | Hardware CRC32 and AES are compiled *out* of stock builds. Up to **5.2x** faster with them. | **Add `-march=armv8-a+crc+crypto`.** One binary, no dispatcher. |
| **macOS arm64** | Already enabled by default. | **None** — adding `-march` would *regress* it (drops the ARMv8.5 baseline). |
| **x86-64** | v2/v3 make no measurable difference; hardware AES was already runtime-dispatched. | **None** — keep the single baseline binary. Do not ship the dispatcher. |

The x86-64 dispatcher is complete and tested, and is kept for reuse — but the
measurements say not to deploy it. The actionable change is the aarch64 flag.

## Why this works without touching upstream

The vendored makefile's compile rule is

```
COMPILE=$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(DEFINES)      # makefile:19
```

and `CPPFLAGS` is never assigned anywhere in it. So `make CPPFLAGS=-march=...`
injects an ISA level into every compile without editing the makefile or
clobbering its own `CXXFLAGS`. `STRIP=true` similarly no-ops the strip step
for symbol-attributed disassembly.

Variants are whole binaries, not per-object mixes. That is deliberate:
`unpack.cpp` aggregates ten decoder `.cpp` files into one object
(`unpack.cpp:3-16`), and `ALLOW_MISALIGNED` (`os.hpp:270`) changes PPM struct
packing in `model.hpp` / `suballoc.hpp`, so mixing flags per translation unit
risks ODR and layout mismatches. Whole binaries are internally consistent.

## Quick start

```bash
make -f dispatch/makefile corpus   # generate benchmark archives (needs `rar`)
make -f dispatch/makefile all      # build variants (+ dispatcher on x86-64)
make -f dispatch/makefile bench    # per-archive timings
make -f dispatch/makefile audit    # ISA containment disassembly audit
dispatch/verify-parity.sh          # correctness gate
```

Requires `python3` (corpus generation, timing, and the CRC exit-code check),
`rar` for corpus generation only, and `objdump`/`nm` (Linux) or `otool`/`nm`
(macOS) for the audit. Verified on Apple clang 21 / arm64-darwin and gcc 13 /
x86-64 glibc.

Corpus size defaults to 256 MB per source file (`-s`), needing roughly 4x that
in disk. Small corpora are a trap: at 64 MB the run-to-run noise floor is
comparable to the effects being measured, so use `-s 256` or `-s 512` for any
result you intend to act on. `bench.sh` reports the measured noise floor and
labels any delta inside it as `noise`.

## Measured results

### aarch64 — real, large, and worth shipping

`os.hpp:163` only defines `USE_NEON_AES` / `USE_NEON_CRC32` when the compiler
already targets `__ARM_FEATURE_CRYPTO` / `__ARM_FEATURE_CRC32`. The vendored
makefile passes no `-march` (`makefile:5-7`), so **stock Linux aarch64 builds
compile the hardware CRC32 loop (`crc.cpp:83`) and NEON AES
(`rijndael.cpp:284`, `:427`) out entirely.**

Measured on Apple M-series, 256 MB corpus, min-of-7 after a discarded warmup,
single-threaded (`-mt1`), comparing a `-march=armv8-a` build (crypto/crc
compiled out — what stock Linux aarch64 produces) against the default target:

| Corpus archive | armv8-a | +crypto+crc | Δ | noise |
| --- | ---: | ---: | ---: | ---: |
| `rar5-encrypted-m0` (AES + CRC, no LZ) | 1000 ms | 194 ms | **+80.6%** | 0.7% |
| `rar5-store-m0` (CRC32 in isolation) | 101 ms | 54 ms | **+46.5%** | 1.0% |
| `rar5-encrypted` (AES + blake2sp + LZ) | 633 ms | 480 ms | **+24.2%** | 0.5% |
| `rar5-text-m5` | 457 ms | 412 ms | +9.8% | 1.6% |
| `rar5-vol.part01` | 665 ms | 617 ms | +7.2% | 0.5% |
| `rar5-exe-m5` | 650 ms | 611 ms | +6.0% | 0.2% |
| `rar5-solid-m5` | 66 ms | 65 ms | +1.5% | 0.8% |
| `rar5-many-m5` | 85 ms | 84 ms | +1.2% | 2.1% (noise) |

**Encrypted incompressible data is the extreme case: 5.2x faster.** With
`-m0` on random data there is no LZ decoding at all, so essentially all the
work is AES-CBC over 256 MB. Pairing it with `rar5-store-m0` (same data, no
encryption) decomposes the two hardware paths:

| Component | armv8-a | +crypto+crc | speedup |
| --- | ---: | ---: | ---: |
| CRC32 over 256 MB (`store-m0`) | 101 ms | 54 ms | 1.9x |
| AES over 256 MB (`encrypted-m0` minus `store-m0`) | 899 ms | 140 ms | **6.4x** |

That is ~285 MB/s software AES versus ~1.8 GB/s with the NEON instructions.
Any workload dominated by encrypted archives of already-compressed content —
media, disk images, nested archives — is paying that 6x on a stock Linux
aarch64 build.

Deltas shrink at default thread count (CRC is threaded above 32 KB,
`hash.cpp:134`), but `encrypted-m0` still gains 82.0%: AES is on the critical
path regardless of thread count.

**Recommendation: one binary, no dispatcher.** Both NEON paths are already
runtime-gated in the source — `CRC_Neon` (`crc.cpp:44`) and `AES_Neon`
(`rijndael.cpp:125`) test `getauxval(AT_HWCAP)` — so a `+crc+crypto` build
still runs correctly on ARMv8.0 parts that lack the extensions (common on
Cortex-A53/A72). The `#ifdef` controls availability; the `if` is the gate.

`dispatch/audit-isa.sh` verifies rather than assumes that, and passes cleanly:

| Instruction | Enclosing function |
| --- | --- |
| `crc32b`, `crc32x` | `CRC32(uint, void const*, size_t)` |
| `aese`, `aesmc` | `Rijndael::blockEncryptNeon` |
| `aesd`, `aesimc` | `Rijndael::blockDecryptNeon` |

Zero occurrences anywhere else, so no unguarded instruction can execute on a
CPU lacking the extension.

**macOS arm64 needs no change and must not get `-march`.** Apple clang already
defines `__ARM_FEATURE_CRC32` / `__ARM_FEATURE_CRYPTO` by default; forcing
`-march=armv8-a+crypto+crc` there gains nothing and *drops* the ARMv8.2–8.5
baseline (`__ARM_FEATURE_ATOMICS`/LSE, `DOTPROD`, `RCPC`, `PAUTH`, `BTI`,
`SHA3`, `SHA512`, `FP16_*`). `build-variants.sh` probes for this and skips the
flag automatically — do not "fix" it later.

### x86-64 — settled: no measurable win, do not ship the dispatcher

Measured on x86-64, 256 MB corpus, min-of-7 after warmup, all three levels
(Δ is v3 vs baseline):

| Corpus archive | x86-64 | v2 | v3 | Δ | noise | verdict |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `rar5-encrypted-m0` | 172 ms | 168 ms | 170 ms | +1.2% | 3.2% | noise |
| `rar5-encrypted` | 440 ms | 440 ms | 441 ms | −0.2% | 2.3% | noise |
| `rar5-exe-m5` | 843 ms | 842 ms | 834 ms | +1.1% | 1.5% | noise |
| `rar5-text-m5` | 393 ms | 389 ms | 401 ms | −2.0% | 5.9% | noise |
| `rar5-many-m5` | 188 ms | 188 ms | 193 ms | −2.7% | 3.7% | noise |
| `rar5-store-m0` | 84 ms | 85 ms | 84 ms | 0.0% | 3.9% | noise |
| `rar5-solid-m5` | 51 ms | 54 ms | 51 ms | 0.0% | 3.4% | noise |
| `rar5-vol.part01` | 870 ms | 883 ms | 857 ms | +1.5% | 1.0% | FASTER |

Fifteen of sixteen rows (both thread modes) are `noise` or `SLOWER`. The lone
`FASTER` is +1.5% at 1.0% noise, and the same archive goes *slower* at default
thread count. **This is a null result.**

`rar5-encrypted-m0` is the informative one: on aarch64 it is the single
biggest effect in this study (+80.6%), and on x86-64 it is flat. That is the
whole asymmetry in one line — `os.hpp:80` enables `USE_SSE` on any x86 build
and AES-NI is then chosen at runtime (`rijndael.cpp:109`), so x86 users
already had hardware crypto. `os.hpp:163` gates the NEON equivalents behind
compile-time `__ARM_FEATURE_*`, so aarch64 users never got it. Nothing was
left on the table on x86; a great deal was on ARM.

This matches the static analysis. The hot loops are branch- and latency-bound,
not width-bound: `DecodeNumber` (`unpackinline.cpp:115`) is two table lookups
and a variable shift; RAR3 PPMd is dependent pointer-chasing plus one integer
divide per symbol (`coder.cpp:32`); `CopyString` (`unpackinline.cpp:63`)
already hand-copies 8 bytes at a time. CRC32 covers 100% of output
(`rdwrfn.cpp:189`) but is slicing-by-16 table lookups (`crc.cpp:111`) with no
vectorizable shape, so `-march` cannot touch it.

v3 codegen *does* change — a variable-shift bit-read compiles to BMI2 `shrx`
at `-march=x86-64-v3`, confirmed via `audit-isa.sh` — it simply is not where
the time goes.

**Conclusion: keep shipping a single baseline `-march=x86-64` binary.** The
dispatcher works and is retained here for reuse, but on this evidence it would
be pure distribution cost. This question is closed; re-open it only with new
evidence, not intuition.

If x86 decompression speed becomes a priority again, these are the remaining
avenues, in descending order of expected value:

- A **PCLMULQDQ CRC32**. CRC covers 100% of output (`rdwrfn.cpp:189`) and is
  currently scalar slicing-by-16 (`crc.cpp:111`); a folding implementation is
  typically 3-10x. This is the one large x86 win available — but it needs
  source changes, so it is outside this approach.
- **PGO**, the most promising flag-only option for a branch-bound decompressor.
  Build with `EXTRA_CPPFLAGS=-fprofile-generate EXTRA_LDFLAGS=-fprofile-generate`,
  run the corpus, rebuild with `-fprofile-use`.
- **`-O3`** and **`-flto`** (the latter needs the flag in `EXTRA_LDFLAGS` too,
  since the vendored link rule at `makefile:52` uses only `$(LDFLAGS)`).

## The dispatcher (x86-64)

`unrar-dispatch.c` detects the CPU level and `execv()`s the matching build.
`execv` rather than `dlopen` so exit codes, signals, tty ownership and
process-tree semantics are identical to running unrar directly — and to avoid
`-fPIC` GOT indirection in the loops being optimised.

Detection uses explicit feature queries (`sse4.2`+`popcnt` for v2;
`avx2`+`bmi2`+`fma` for v3) rather than `__builtin_cpu_supports("x86-64-v3")`,
which needs GCC 12+ / Clang 12+.

Variant lookup order: `$UNRAR_ISA_DIR` → `<wrapper dir>/unrar-isa/` →
`<wrapper dir>` → compile-time `UNRAR_VARIANT_DIR` (default
`/usr/libexec/unrar`). Missing higher variants are skipped, so a packager can
ship a subset unchanged.

`UNRAR_ISA=x86-64|x86-64-v2|x86-64-v3` pins a level — this is what makes
post-install benchmarking repeatable, and the escape hatch for
AVX2-downclocking workloads or a VM with bad CPUID.

Verified behaviour (x86-64 build run under Rosetta 2, which offers SSE4.2 but
not AVX2): auto-detect selects `x86-64-v2`; each explicit pin resolves; a
missing variant walks down v3 → v2 → baseline; `argv` passes through exactly,
spaces and all; an unknown `UNRAR_ISA` and total lookup failure both exit 2
(`RARX_FATAL`, `errhnd.hpp:8`).

## Profiling on Windows

`bench.ps1` says which archives are slow; `profile-win.ps1` says where the time
goes inside one. It records a 1 kHz sampled-CPU ETW trace with stacks, plus
file I/O, and analyses it with `xperf -a profile`.

```
# elevated - ETW kernel sessions require it
.\dispatch\profile-win.ps1 -Exe build\unrar64\Release\unrar.exe -Archive dispatch\corpus\rar5-store-m0.rar

# analysis needs no elevation, and can be re-run with symbols
.\dispatch\profile-win.ps1 -AnalyzeOnly -Etl dispatch\unrar-profile.etl -SymbolPath "srv*C:\symbols*https://msdl.microsoft.com/download/symbols"
```

**`unrar t` is the wrong command for measuring CPU work on Windows.** The test
command purges the archive from the file cache before reading it
(`ResetFileCache`, [extract.cpp:244](../extract.cpp)) — Windows-only, and not
done for extraction. Every read then pays for a cold cache, which swamps
decode- and checksum-side gains and makes Windows `t` numbers incomparable to
Linux `t` numbers. Use `x`, or suppress the purge. See
[winread/README.md](../winread/README.md).

Three things about profiling were learned the hard way and are encoded in the
script, so they do not have to be rediscovered:

- **Record with xperf, not WPR.** WPR's built-in profiles pull in managed-code
  providers, and `xperf -a profile` then aborts on the first .NET event with
  `HRESULT 0x80070032` — it cannot analyse a recording WPR just made. A
  kernel-only xperf trace analyses cleanly and needs no hand-written
  `.wpaProfile`. `-UseWpr` remains for when something else holds the single
  shared NT Kernel Logger.
- **Verify the session started, do not trust the exit code.** `xperf -on` has
  returned 0 without creating a session, which silently runs the whole workload
  untraced and then merges nothing. The script checks `xperf -loggers`.
- **`$ErrorActionPreference = "Stop"` is wrong for driving these tools.** They
  write banners and benign warnings to stderr, and under `Stop` that alone
  raises a terminating error — a harmless "no session to stop" during cleanup
  will kill the script before it does any work. Exit codes are checked
  explicitly instead.

- **`-a profile` needs `-detail`, and is the only action to trust for CPU
  time.** Without `-detail` it emits a per-CPU utilisation summary that says
  nothing about where time went. And do not reach for `xperf -a stack`
  instead: that action counts every event carrying a stack, so on a trace
  containing `FILE_IO` the file-I/O stacks swamp the CPU samples and
  `EtwpTraceStackWalk` appears to be 59% of the machine. It is not — in the
  sampled profile ETW is about 1%. `stack -butterfly` is for call
  relationships (it is how the read path below was traced through unrar into
  the cache manager); `profile -detail` is for magnitudes.

Symbol decoding is opt-in via `-SymbolPath`, because otherwise xperf reaches
for the public symbol server and stalls. For function names inside unrar you
need a PDB matching that exact binary: MSBuild rewrites `UnRAR.pdb` on every
build, so a PDB left from a later build will not match a renamed earlier exe
and you will silently get module-level attribution only. Copy the PDB aside at
build time when profiling a specific binary.

### `-mlp` (large memory pages) — tried, not worth shipping

Large pages looked promising because `MiUpdateLargePageCandidateValue` and
`MiDemoteLocalLargePage` both appear in the profile's top functions. They are
not the win they look like.

`-mlp` reaches only the `Unpack` window allocator (`extract.cpp:28`), so it can
reduce TLB pressure in the LZ decode loops and nothing else. It cannot touch
the read path, which is where the Windows time actually goes, and it does
nothing at all for stored archives, which bypass `Unpack`. It also needs a
dictionary of at least `GetLargePageMinimum()` (2 MB) before `new_large`
(`largepage.cpp:170`) takes the large-page path.

Measured on the 5800X, fold=256, min-of-9, against archives with 32 MB and
8 MB dictionaries. Deltas run from −2.6% to +6.5% and **every row except one
sits inside its own noise band**; the exception (`rar5-vol.part01` at default
threads, +6.5% against 6.1% noise) is marginal and does not reproduce in the
single-thread run. Single-threaded, all five large-dictionary archives came out
slightly positive (+0.5% to +3.5%); at default threads the signs are mixed. So
there may be a real effect of order 1-3%, but this measurement cannot separate
it from noise, and it is not the Windows bottleneck.

Verify that `-mlp` is actually doing something before trusting any measurement
of it: `new_large` returns `nullptr` on failure and the caller silently falls
back to normal pages, so a clean run proves nothing. Large pages need
contiguous physical memory, which fragments with uptime — the same command can
work after a reboot and fail hours later. Check by enabling
`SeLockMemoryPrivilege` and calling `VirtualAlloc(..., MEM_LARGE_PAGES)` for
the dictionary size directly.

Note also that `-mlp` requires the "Lock pages in memory" privilege, which
unrar will offer to assign (`cmddata.cpp:678`). That is a genuinely powerful
privilege — it allows pinning physical memory — so granting it to a user
account to buy a percent or two of decompression speed is a security trade,
not a free tuning knob.

## Correctness gate

`verify-parity.sh` is the check that matters — a variant that decodes fast but
wrong is worse than a slow one. It confirms every variant passes `unrar t` on
the whole corpus, produces byte-identical extractions (2003 files), matches
the original source data, and agrees on error exit codes.

Current status on aarch64: **PASS** — `corrupt=3` (`RARX_CRC`),
`badpassword=11` (`RARX_BADPWD`), `missing=10` (`RARX_NOFILES`), identical
across variants.

## Known gaps

- **No RAR3/PPMd benchmark arm.** RAR 7.x removed the ability to *create*
  RAR4-format archives (`-ma4` is rejected), so `make-corpus.sh` skips that
  arm and says so. Drop pre-made RAR3 archives into `dispatch/corpus/` to
  cover the PPMd path. It is the path least likely to benefit from any ISA
  level, so this is a low-priority gap.
- **Windows is not implemented.** MSVC has no `/arch` between `SSE2` (the x64
  default) and `AVX`, so x86-64-v2 is not expressible without `clang-cl`, and
  the wrapper needs `CreateProcessW` + a Job Object rather than `execv` (the
  CRT `_wexecv` returns to the shell immediately, breaking `.bat` callers).
- **Windows ARM64 gets nothing.** `os.hpp:80` excludes ARM Windows from
  `USE_SSE`, and `os.hpp:163` requires `__aarch64__`, which MSVC does not
  define (it uses `_M_ARM64`). Closing that needs an upstream `os.hpp` change.

## Files

| File | Purpose |
| --- | --- |
| `build-variants.sh` | Builds one binary per ISA level via the `CPPFLAGS` hook |
| `make-corpus.sh` | Generates the benchmark archives (needs `rar`) |
| `bench.sh` | Per-archive min-of-N timings with noise floor, `-mt1` and default threads |
| `bench.ps1` | Windows equivalent of `bench.sh`, plus `-FoldModes` within one binary |
| `check-builds.ps1` | Confirms two Windows builds differ only in the CRC define |
| `profile-win.ps1` | ETW CPU-sampling trace of unrar on Windows (needs elevation) |
| `audit-isa.sh` | Attributes ISA instructions to enclosing functions |
| `verify-parity.sh` | Correctness gate across variants |
| `unrar-dispatch.c` | The x86-64 runtime dispatcher |
| `makefile` | Standalone driver + install targets |
