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

Measured, min-of-15 (MB/s):

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

## Remaining gap: MSVC

`CRCFoldDetect()` uses `__builtin_cpu_supports` / `__cpuid_count`, which are
GCC/Clang only. On MSVC it sets `CRCFoldWidth=0`, so Windows builds silently
fall back to the table path.

This is *safe* — correct, just no faster — but the feature is inactive there.
Enabling it means writing the detection with MSVC's `__cpuid`/`__cpuidex`
(the same shape as the existing detection at [system.cpp:206](../system.cpp)).
That is deliberately not done here: it cannot be compiled or tested in this
environment, and shipping untested CPUID code risks breaking the Windows build
for a platform that currently works correctly.

No `.vcxproj` change is needed either way, since `crcfold.cpp` is `#include`d
rather than compiled separately.
