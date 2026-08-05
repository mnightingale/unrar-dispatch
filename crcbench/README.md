# CRC32 folding benchmark

Compares unrar's current CRC32 (slicing-by-16, [crc.cpp:111](../crc.cpp)) against
PCLMULQDQ carry-less-multiply folding.

CRC32 runs over 100% of decompressed output ([rdwrfn.cpp:189](../rdwrfn.cpp)) and
is currently pure table lookup on x86 with no SIMD path at all, so it is the
one remaining large x86 win identified in `dispatch/README.md`.

```bash
make -f crcbench/makefile run          # correctness + throughput
crcbench/build/crcbench check          # correctness only, no timings
crcbench/build/crcbench 25             # 25 timing runs instead of 15
```

Standalone — does not link unrar, builds in a second.

## Status: measured, verified, and integrated

Both folding paths pass the full correctness sweep on real x86-64 hardware,
and the algorithm is now wired into `crc.cpp` (see *Integration* below).

| Implementation | Requires | Correctness | Peak throughput |
| --- | --- | --- | --- |
| `slicing-by-16` | — (current unrar) | verified | ~4.1 GB/s |
| `fold-128` | SSE4.1 + PCLMULQDQ | verified | ~37.7 GB/s |
| `fold-256` | AVX2 + VPCLMULQDQ | verified | ~50.0 GB/s |

Measured on Linux/GCC, min-of-15 (MB/s). Windows/MSVC on the same class of
hardware agrees within a few percent:

| Buffer | slicing-by-16 | fold-128 | fold-256 | best vs baseline |
| ---: | ---: | ---: | ---: | ---: |
| 4 KB | 3347 | 26940 | 31002 | 9.26x |
| 64 KB | 3205 | 37742 | 49960 | **15.59x** |
| 1 MB | 4103 | 37488 | 49933 | 12.17x |
| 4 MB | 4079 | 36243 | 47789 | 11.72x |
| 64 MB | 4054 | 19128 | 21992 | 5.42x |

Two things worth reading off this:

**256-bit earns its place.** It beats the 128-bit path by ~32% across the
cache-resident range and ~15% at the extremes. The prior expectation was that
128-bit folding would already saturate the CLMUL port and 256-bit would add
nothing; that was wrong, so both tiers are kept.

**The 64 MB row is the honest floor.** Both folding paths drop sharply there
(37.7 -> 19.1, 50.0 -> 22.0 GB/s) while slicing-by-16 stays flat at ~4 GB/s.
That is the crossover from compute-bound to memory-bandwidth-bound: the table
version was never near bandwidth, folding is. So 5.4x is what to expect on
buffers that miss cache, not the 15.6x peak.

**End-to-end is far less than either**, because unrar decompresses at a few
hundred MB/s and CRC was only a slice of total runtime — but it is still
large where it counts. Measured with `build-ab.sh` + `dispatch/bench.sh`,
256 MB corpus, min-of-5, single-threaded:

| Archive | table only | folding | Δ | noise |
| --- | ---: | ---: | ---: | ---: |
| `rar5-store-m0` | 82 ms | 25 ms | **+69.5%** | 3.7% |
| `rar5-encrypted-m0` | 171 ms | 109 ms | **+36.3%** | 1.8% |
| `rar5-text-m5` | 383 ms | 325 ms | +15.1% | 1.2% |
| `rar5-encrypted` | 427 ms | 368 ms | +13.8% | 3.6% |
| `rar5-vol.part01` | 849 ms | 774 ms | +8.8% | 1.0% |
| `rar5-exe-m5` | 823 ms | 777 ms | +5.6% | 1.0% |
| `rar5-solid-m5` | 50 ms | 48 ms | +4.0% | 5.3% (noise) |
| `rar5-many-m5` | 181 ms | 179 ms | +1.1% | 2.2% (noise) |

No row is slower in either thread mode. As predicted, the gain concentrates on
stored and encrypted-stored archives, where there is no LZ work to dominate:
**stored data decodes 3.3x faster**.

At default thread count the gains shrink (`store-m0` +23.5%, most others
2-5%) because `DataHash::Update` already threads CRC above 32 KB
([hash.cpp:134](../hash.cpp)) — much of the win was previously being bought
with extra cores, and folding now buys it outright on one.

### What was verified, and where

`fold-128` passes, on x86-64 glibc:

- the known-answer vectors from unrar's own disabled `TestCRC()`
  ([crc.cpp:184](../crc.cpp)) — an independent check, not just self-consistency
  against the table implementation
- every length 0–600 at 4 buffer offsets (catches the `<64` fallback, the
  scalar remainder after the fold loop, and any accidental alignment
  assumption, since the fold path uses unaligned loads)
- incremental splits across a 64 KB buffer — unrar calls CRC32 per output
  block, so chained calls must equal a single call

Note the harness always runs the full correctness sweep *before* reporting any
timing and aborts on failure, so a fast-but-wrong implementation can never be
mistaken for a result.

`fold-256` could not be executed during development (arm64 host; Rosetta 2 has
no AVX2; QEMU TCG up to 10.0.11 with `-cpu max` does not implement
`CPUID.07H:ECX.vpclmulqdq [bit 10]`). It was verified on the first run against
real hardware with VPCLMULQDQ.

## Integration

`crcfold.cpp` is included by `crc.cpp` and used inside `CRC32()`. The change
to `crc.cpp` is 30 lines, all additive, so upstream drops stay diffable:

- `crcfold.cpp` is `#include`d, not a separate translation unit, matching how
  `blake2s_sse.cpp` is included by `blake2s.cpp`. No makefile or `.vcxproj`
  change is needed, and `rar.hpp` is untouched.
- The fold functions process **whole 64-byte blocks only** and carry no scalar
  tail: `CRC32()` already has slicing-by-16 and byte loops for the remainder,
  so no second table is shipped.
- Width is detected once from `InitCRC32` (alongside the existing `CRC_Neon`
  detection) and cached in `CRCFoldWidth`; it defaults to 0, so if detection
  has not run the code falls through to the table path.
- Excluded from `SFX_MODULE`, matching the existing `USE_SLICING` treatment —
  the SFX module avoids carrying extra license text and benefits little.

### A/B measurement

Build with `-DNO_CRC_FOLD` for the original table-only behaviour.
`build-ab.sh` builds both and confirms they actually differ:

```bash
crcbench/build-ab.sh
dispatch/bench.sh -b crcbench/build-ab -c dispatch/corpus
```

Variants are named `a-nofold` / `b-fold` so `ls` order puts the baseline
first, making bench.sh's `delta` column read as folding-vs-baseline (positive
means folding is faster). Output goes to `crcbench/build-ab/` so it does not
disturb ISA variants in `dispatch/build`.

Verified on x86-64 that `-DNO_CRC_FOLD` yields 0 `pclmulqdq` instructions and
removes every `CRCFold` symbol, while the default build has 24.

## Braided slicing-by-16, and what ILP alone is worth

`braid-2`, `braid-3` and `braid-4` implement the alternative RARLAB raised when
asked about folding: keep the table algorithm, but split the buffer into blocks
in a *single* thread so the out-of-order engine can process several at once. They
use the same tables and the same Galois combine as
[`UpdateCRC32MT`](../hash.cpp) — it is that function with the thread pool removed
and the inner loops interleaved.

Measured on an Apple M2 Pro (arm64, Apple clang `-O2`), min-of-21, MB/s:

| Buffer | slicing-by-16 | braid-2 | braid-3 | braid-4 |
| ---: | ---: | ---: | ---: | ---: |
| 4 KB | 3285 | 5759 | 3501 | 3294 |
| 64 KB | 3270 | **6935** | 4089 | 4164 |
| 1 MB | 3273 | **6828** | 4124 | 4294 |
| 4 MB | 3281 | **6853** | 4158 | 4249 |
| 64 MB | 3301 | **6828** | 4141 | 4253 |

**The idea works, and it is worth about 2.1x.** Two chains is the sweet spot;
three and four are worse than two, most likely register pressure — each chain
needs its accumulator plus three data words live — though it could also be load
ports, and x86-64 with half the general-purpose registers may well behave
differently. Anyone with an x86 box can settle that in a second, which is rather
the point of putting it here.

**Where the ceiling comes from.** The braid removes stalls, not work. Each 16-byte
step still issues 20 loads — 16 table lookups and 4 data words — so the table
approach costs **1.25 loads per byte** no matter how the chains are arranged.
Against 2-3 load ports that caps it near 2.4 bytes/cycle; `braid-2` reaches about
1.97, so roughly 80% of the ceiling is already claimed and the remaining chains
have nothing left to buy. Slicing-by-32 would not help either: it doubles the
tables to 32 KB and still does one lookup per byte, which is why
[crc.cpp:138](../crc.cpp) rejects it.

For contrast, per 16 bytes:

| | loads | other |
| --- | ---: | --- |
| slicing-by-16 | 20 | ~16 byte extracts, 15 XORs |
| `fold-128` | 1 | 2 `PCLMULQDQ`, 2 XOR |

So folding's advantage is two separable things, and braiding replicates only one
of them:

1. **Instruction-level parallelism.** `CRCFold128` keeps four independent
   accumulators (`Crc0`..`Crc3`, [crcfold.cpp:147](../crcfold.cpp)) and reduces
   them once at the end — braiding, in registers. This is exactly the suggested
   idea, and folding already depends on it.
2. **Work reduction.** Carry-less multiply does in two instructions what the
   table needs 20 loads and 30-odd ALU operations for. No amount of reordering
   reaches this, and it is where the order of magnitude lives.

**The implementation trap.** Splitting the data into blocks and processing them
*sequentially* gains nothing: the reorder window is a few hundred instructions
and a block is thousands of iterations, so by the time block 2 starts, block 1 has
long retired. The chains must be interleaved in one loop body. This matters
because `hash.cpp` has a commented-out `//#undef USE_THREADS` that makes
`UpdateCRC32MT` run its blocks serially on the calling thread — it looks like this
experiment and is one character away, but it would measure sequential blocks and
report no gain.

**Worth having anyway.** 2.1x for no new instructions, on any architecture, is a
real result for platforms with no carry-less multiply at all — and unlike folding
it needs no runtime dispatch. It is a complement to folding rather than a
substitute for it.

Note the 4 KB row is lower (1.75x) because the combine is a fixed cost per call.
The shift multiplier is cached across calls here, as `UpdateCRC32MT` caches its
own `StdShift`; without that, `gfExpCRC`'s ~0.5 µs lands on every call and buries
the 4 KB result entirely.

## Design notes

**Two widths, deliberately.** The 256-bit path was the starting request, but
VPCLMULQDQ is Ice Lake (2019) / Zen 4 and later only — and it is *not* part of
x86-64-v3, or even v4; it is a separate CPUID bit needing its own detection.
The 128-bit path needs only SSE4.1 + PCLMULQDQ, i.e. Westmere (2010) and
effectively every x86-64 CPU in service. Benchmarking only the 256-bit version
would say nothing about the CPUs most users actually have.

Both fold 512 bits of state and consume 64 bytes per iteration; the 256-bit
version packs the same four lanes into two registers, halving instruction
count for identical work. So the interesting question the benchmark answers is
not "does folding help" but "does the *256-bit* version add anything over the
128-bit one" — on many microarchitectures the 128-bit path already saturates
the CLMUL execution port, and the answer is no.

**Runtime dispatch, no `-march`.** Each implementation carries its own
`__attribute__((target(...)))`, matching how unrar already handles SIMD
([blake2s_sse.cpp:9](../blake2s_sse.cpp), [rijndael.hpp:17](../rijndael.hpp),
[rs16.hpp:19](../rs16.hpp)). One binary runs everywhere and picks its path at
runtime — no ISA ladder or dispatcher needed, unlike the `-march` approach in
`dispatch/`.

**CRC convention.** zlib (and rapidyenc) complement the CRC on entry and exit;
unrar carries the raw running value and leaves the final XOR to the caller
(`CRC32(0xFFFFFFFF, ...) ^ 0xFFFFFFFF`). The two inversions cancel, so
`crc_fold.cpp` simply omits both. This is asserted by the known-answer tests
rather than assumed.

**Scalar tail.** `crc_fold.cpp` carries a private 256-entry table for runs
shorter than 64 bytes and for the remainder after the fold loop. On
integration into `crc.cpp` this should be dropped in favour of the existing
`crc_tables[0]` rather than shipping a second copy.

## Attribution

The folding algorithm is Intel's, from "Fast CRC Computation for Generic
Polynomials Using PCLMULQDQ Instruction" (2009). This implementation follows
zlib-ng (zlib license) and, for the 256-bit variant, animetosho's rapidyenc
adaptation (Public Domain / CC0):

<https://github.com/animetosho/rapidyenc/blob/master/src/crc_folding_256.cc>

The fold constants are properties of the CRC32 polynomial `0xEDB88320`, not
creative expression. This is consistent with the Intel BSD attribution already
carried at the top of [crc.cpp](../crc.cpp).

Note [license.txt](../license.txt) requires modified distributions to state
that they are modified, in both documentation and source comments — relevant
once this is integrated into `crc.cpp`.

## Verification status

Complete. On VPCLMULQDQ hardware (so the `fold-256` path is the one actually
exercised inside unrar), `dispatch/verify-parity.sh` reports:

- both builds pass `unrar t` on every corpus archive
- extractions are byte-identical between them (2003 files)
- extracted content matches the original source data
- error exit codes agree: `corrupt=3`, `badpassword=11`, `missing=10`

Together with the `crcbench` sweep (known answers, lengths 0-600 x 4 offsets,
incremental splits) this covers both the algorithm and its integration.

## MSVC / Windows

Implemented. MSVC and GCC/Clang share one `CRCFoldDetect()`; only the CPUID
and XGETBV *intrinsics* differ, wrapped in `CRCFoldCpuid()` / `CRCFoldXcr0()`:

| | GCC/Clang | MSVC |
| --- | --- | --- |
| CPUID | `__cpuid_count` | `__cpuidex` |
| XCR0 | inline `xgetbv` | `_xgetbv` |
| Per-function ISA | `__attribute__((target(...)))` | not needed |

Sharing the logic means the Linux build exercises the exact bit tests Windows
will run, so `crcbench` cross-checks them against `__builtin_cpu_supports` and
reports `PASS cpuid detection agrees with __builtin_cpu_supports`. Only the
intrinsic spelling is Windows-specific.

The bits tested:

| Feature | CPUID leaf | Bit |
| --- | --- | --- |
| PCLMULQDQ | 1:ECX | 1 |
| SSE4.1 | 1:ECX | 19 |
| OSXSAVE | 1:ECX | 27 |
| AVX | 1:ECX | 28 |
| AVX2 | 7.0:EBX | 5 |
| VPCLMULQDQ | 7.0:ECX | 10 |

The AVX path additionally checks `XCR0` bits 1 and 2, confirming the OS saves
XMM and YMM state. GCC's `__builtin_cpu_supports("avx2")` does this
internally; MSVC has no equivalent, so it is done explicitly for both.

`_mm256_clmulepi64_epi128` arrived in Visual Studio 2019, so `CRCFOLD_HAVE_256`
is gated on `_MSC_VER >= 1920`; older MSVC compiles the 256-bit path out
entirely and still gets `fold-128`. MSVC needs no `/arch` flag for these
intrinsics.

No `.vcxproj` change is needed, since `crcfold.cpp` is `#include`d rather than
compiled separately.

**Confirmed working on Windows/MSVC**, including the 256-bit path. MSVC
accepted `_mm256_clmulepi64_epi128` with no `/arch:AVX2` flag, so runtime
dispatch works there exactly as on GCC/Clang, and all three implementations
pass the correctness sweep. Measured throughput tracks the Linux result
closely (54054 vs 49933 MB/s at 1 MB), so the two toolchains agree.

`unrar.exe` has now been built and A/B'd end-to-end on Windows too — see
*Windows end-to-end results* below. Folding works there, but the percentages
are smaller than on Linux for reasons that are mostly not about the CRC code.

### Building on Windows from the command line

All commands need a **Developer Command Prompt for VS** (or run `vcvars64.bat`
first), so `cl.exe` and `msbuild.exe` are on `PATH`:

```
"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
```

**The benchmark** is one self-contained file:

```
cl /O2 /EHsc /Fe:crcbench.exe crcbench\crcbench.cpp
crcbench.exe
```

**unrar itself** builds from the existing project, but the shipped project is
old enough to need two overrides:

```
msbuild UnRAR.vcxproj /p:Configuration=Release /p:Platform=x64 ^
        /p:PlatformToolset=v143 /p:WindowsTargetPlatformVersion=10.0
```

Output lands in `build\unrar64\Release\unrar.exe`.

Both overrides are required:

- **`PlatformToolset=v143`** — the project ships `v140_xp` (VS2015,
  `_MSC_VER` 1900), which is usually not installed alongside a modern Visual
  Studio, *and* is below the `_MSC_VER >= 1920` gate for
  `_mm256_clmulepi64_epi128`. With the stock toolset you silently get
  `fold-128` only. `v143` is VS2022; use `v142` for VS2019.
- **`WindowsTargetPlatformVersion=10.0`** — the project pins Windows SDK 8.1,
  which modern Visual Studio installs do not ship, failing with
  `error MSB8036`. Bare `10.0` resolves to the newest installed Windows 10/11
  SDK.

Passing these on the command line rather than editing the `.vcxproj` keeps the
vendored project files byte-identical to upstream, which is the same principle
the rest of this work follows.

`crcfold.cpp` is deliberately absent from the `.vcxproj` file list, because
`crc.cpp` `#include`s it. Do not add it, or it will be compiled twice and
fail to link on duplicate symbols.

Note `crcfold.cpp` includes `<intrin.h>` itself for `__cpuid`/`__cpuidex`.
[os.hpp](../os.hpp) already does that for MSVC unrar builds, but `crcbench`
compiles the file standalone without `rar.hpp`, so it cannot rely on it.

MSVC turned out **not** to need `/arch:AVX2` for `_mm256_clmulepi64_epi128`
(verified on VS2022), so no per-file project settings are required and the
`.vcxproj` files stay untouched. Had it demanded that flag, the fix would have
been a separate `.cpp` with a per-file `/arch:AVX2` setting — never the flag
globally, which would let the compiler emit AVX2 anywhere and break the binary
on pre-AVX2 CPUs.

#### VEX containment — verified, and worth re-verifying

Not needing `/arch:AVX2` is convenient but it is not automatically safe, and
this is the one part of the MSVC build that deserves an actual disassembly
check rather than trust. MSVC has no `__attribute__((target))`, so
`CRCFOLD_TARGET_128/256` expand to nothing and the compiler is free to inline
`CRCFold256` and `CRCFold128` into `CRC32` and schedule them together. Two
things could then go wrong:

- AVX2 setup (constant materialisation, register zeroing) hoisted *above* the
  `CRCFoldWidth>=256` test, so a ymm instruction executes on a CPU without
  AVX2.
- The 128-bit path VEX-encoded because it shares a function with AVX code —
  `vpxor xmm` instead of `pxor`. Those are AVX instructions, so this would
  fault on exactly the Westmere-era SSE4.1+PCLMULQDQ parts the 128-bit path
  exists to serve.

Checked on the VS2022 v143 x64 Release build (`dumpbin /disasm`), both are
clean:

- `CRC32` loads `CRCFoldWidth`, tests it against 0, tests `Size>=64`, then
  branches on `cmp eax,100h`. Every VEX-encoded instruction in the function —
  including the 128-bit `vpxor xmm5,xmm5,xmm5` and `vmovdqu xmm4,xmm4` that
  set up the fold state — lies *after* that branch. Nothing VEX-encoded is
  reachable when `CRCFoldWidth` is 128.
- `CRCFold128` was kept out of line and is entirely legacy-SSE encoded: 0 VEX
  instructions in the function or in the reduction it inlines (`pclmulqdq`
  `66 0F 3A 44`, `movdqa` `66 0F 6F`, `xorps` `0F 57`).
- The only other ymm instructions in the binary are inside the CRT's own
  runtime-dispatched `memcpy`/string routines.

This is a property of one compiler version's inliner, not something the source
guarantees, so re-check it after a toolset upgrade:

```
dumpbin /disasm build\unrar64\Release\unrar-fold.exe > fold.asm
```

then confirm every `ymm` reference and every `C5`/`C4` VEX prefix in `CRC32`
sits below the `cmp eax,100h` branch. If a future MSVC ever hoists one above
it, the fix is to move `CRCFold256` into its own translation unit compiled
with `/arch:AVX2`, keeping `crc.cpp` itself at the default ISA.

**A/B measurement on Windows.** MSVC's `cl.exe` honours the `CL` environment
variable, so the baseline needs no project edit:

```
set CL=/DNO_CRC_FOLD
msbuild UnRAR.vcxproj /p:Configuration=Release /p:Platform=x64 ^
        /p:PlatformToolset=v143 /p:WindowsTargetPlatformVersion=10.0 /t:Rebuild
set CL=
```

Use `/t:Rebuild` when toggling the define — MSBuild will not otherwise notice
that compiler flags changed, only that sources did not, and would silently
reuse the previous objects.

Rename the resulting `unrar.exe` between the two builds, since both
configurations write to the same output path.

Then benchmark with [dispatch/bench.ps1](../dispatch/bench.ps1), the Windows
equivalent of `dispatch/bench.sh` (same min-of-N, warmup, and noise/verdict
columns; written for Windows PowerShell 5.1):

```
.\dispatch\bench.ps1 -Exe unrar-nofold.exe,unrar-fold.exe -Corpus dispatch\corpus
```

List the baseline first — `delta` compares the last exe against the first. If
execution policy blocks it, use
`powershell -ExecutionPolicy Bypass -File dispatch\bench.ps1 ...`.

The corpus itself needs `rar` and a POSIX shell to generate
(`dispatch/make-corpus.sh`), so copy `dispatch\corpus` across from the Linux
machine rather than rebuilding it on Windows.

Better still, use `crcbench\build-ab.ps1`, which does both builds and then
*verifies* them. Two hand-driven builds that both write to
`build\unrar64\Release\unrar.exe` have to be told apart by renaming, and a
rename done backwards yields two working binaries whose A/B result is simply
inverted — with nothing in the output to say so. That happened here once
already. The script fails if the baseline contains `pclmulqdq` or the folding
build does not.

### Windows end-to-end results

> **Correction — the Windows numbers below understate the win.** They were
> measured with `unrar t`, and on Windows the test command deliberately purges
> the archive from the file cache first (`ResetFileCache`,
> [extract.cpp:244](../extract.cpp)). Linux has no such call, so the two
> platforms were never measuring the same thing. On `rar5-store-m0`, folding is
> worth **+5.1%** under `unrar t` but **+25.1%** under `unrar x`, and +36.2% for
> `t` with the purge suppressed. See [winread/README.md](../winread/README.md).
> The table below is left as measured; read it as a floor, not as the result.

Measured on a Ryzen 7 5800X (Zen 3, 8C/16T, 32 GB), Windows 11, VS2022 v143,
min-of-11, `-mt1`, comparing `UNRAR_CRC_FOLD` modes of one binary:

| Archive | fold=0 | fold=256 | saved | Δ raw | Δ less launch floor |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rar5-encrypted-m0` | 261 ms | 218 ms | 43 ms | +16.6% | **+19.6%** |
| `rar5-text-m5` | 449 ms | 409 ms | 40 ms | +8.9% | +9.7% |
| `rar5-exe-m5` | 876 ms | 830 ms | 46 ms | +5.3% | +5.5% |
| `rar5-store-m0` | 174 ms | 167 ms | 8 ms | +4.4% | +5.7% |

Folding is a real win on Windows, and the *absolute* saving is a consistent
~40-46 ms per 256 MB — the same order as Linux. What differs is the
percentage, for three reasons, none of them a defect in the folding code:

**1. A ~40 ms process-launch floor.** Measured with `bench.ps1`, which now
reports it. Windows process creation plus on-access anti-virus scanning of the
freshly written `unrar.exe` costs tens of milliseconds against roughly one for
`fork`+`exec`. That floor sits inside every row and shrinks every percentage
without changing the milliseconds saved. Subtract it from both columns before
comparing a Windows percentage against a Linux one.

**2. `rar5-store-m0` is I/O-bound here, not CRC-bound.** It was Linux's
headline result (+69.5%) and is Windows' weakest row, which looks alarming
until the CPU time is separated from the wall clock:

| Archive | fold | CPU/run | wall/run |
| --- | ---: | ---: | ---: |
| `store-m0` | 0 | 109.4 ms | 155.3 ms |
| `store-m0` | 256 | 82.8 ms | 149.0 ms |
| `encrypted-m0` | 0 | 248.4 ms | 258.6 ms |
| `encrypted-m0` | 256 | 201.6 ms | 213.3 ms |

For `encrypted-m0` the 46.8 ms of CPU saved becomes 45.3 ms of wall time — it
converts one-for-one. For `store-m0` a 26.6 ms CPU saving buys only 6.3 ms of
wall time, because ~46 ms of its wall clock is I/O wait that folding cannot
touch: the process simply waits on the file instead. A stored archive is read
and CRC'd and nothing else, so it has no other CPU work to hide the wait
behind. On Linux the page cache served the same file with almost no wait —
its entire `store-m0` run (82 ms) was shorter than this machine's CPU time
alone.

Note also that `store-m0` saves less *CPU* (26.6 ms) than the microbenchmark
predicts (~57 ms). In the stored path the CRC reads a 4 MB buffer
(`File::CopyBufferSize()`, [file.hpp:148](../file.hpp)) that `ReadFile` has
just filled, so it streams from L3/DRAM and is bandwidth-bound. In the
encrypted path AES has already pulled that buffer into cache, so the CRC runs
cache-hot and folding delivers its full rate. This is the "64 MB row is the
honest floor" caveat from the throughput table, showing up end-to-end.

**3. This CPU folds at about half the Linux box's rate.** `crcbench` on the
same hardware as the table above:

| | slicing-by-16 | fold-128 | fold-256 |
| --- | ---: | ---: | ---: |
| Linux box (1 MB) | 4103 | 37488 | 49933 |
| This 5800X (1 MB) | 3913 | 18322 | 32502 |

The table path matches within 5%, so the machines are comparable in general;
`(V)PCLMULQDQ` throughput is what differs. Zen 3 splits 256-bit CLMUL into two
128-bit operations, so `fold-256` is only 1.77x `fold-128` here against 1.33x
there, and both widths are roughly half the absolute rate. That is a hardware
difference, not a Windows or MSVC one — do not read the earlier claim that
"Windows/MSVC agrees within a few percent" as covering this part, since that
comparison was made on different silicon.

### Two Windows benchmarking traps

Both of these produced a confident, wrong "folding does nothing on Windows".

**`-FoldModes` silently collapsed to one variant.** `powershell -File
bench.ps1 -FoldModes 0,128,256` passes the list as the single *string*
`"0,128,256"`, and PowerShell reads those commas as thousands separators, so
the old `[int[]]` parameter converted it to the single value `128256`. The run
then had one variant, compared it against itself, and printed `0.0%` delta and
`noise` on every row — which reads exactly like a null result. `bench.ps1` now
takes the argument as a string, splits it itself, rejects anything that is not
`0`, `128` or `256`, and warns loudly when only one variant is being timed.

**Defender inflates the noise floor.** Windows rows here show 6-9% run-to-run
spread against 1-4% on Linux, which is enough to push a genuine +5.8% result
into the `noise` verdict. If you have administrator rights, adding
`dispatch\corpus` and the build output directory to Defender's exclusion list
for the duration of the benchmarking makes the numbers considerably more
stable. That is a change to a security setting, so it is a deliberate decision
to make and to undo afterwards, not something the scripts do for you.
