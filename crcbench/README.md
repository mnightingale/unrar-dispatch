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

## Status

| Implementation | Requires | Correctness | Throughput |
| --- | --- | --- | --- |
| `slicing-by-16` | — (current unrar) | verified | baseline |
| `fold-128` | SSE4.1 + PCLMULQDQ | **verified** | **not yet measured on real hardware** |
| `fold-256` | AVX2 + VPCLMULQDQ | **NOT VERIFIED — see below** | not measured |

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

### The fold-256 caveat

**`fold-256` has never been executed.** It is written and compiles cleanly,
but no available environment can run it:

- the development machine is arm64
- Rosetta 2 provides SSE4.2 but not AVX2
- QEMU TCG — tested up to QEMU 10.0.11 with `-cpu max` — does not implement
  `CPUID.07H:ECX.vpclmulqdq [bit 10]`

Its structure mirrors the 128-bit path exactly (the same four 128-bit lanes,
just packed two per register, with the same per-lane constants and the same
lane→register extraction order as the rapidyenc reference), so the risk is
low. But low risk is not verification.

**This is safe in practice because the harness always runs the full
correctness sweep before reporting any timing, and aborts on failure.** Run it
on a CPU with VPCLMULQDQ and it either verifies or fails loudly. Until then,
treat `fold-256` as unproven and do not integrate it.

### Throughput numbers are not yet meaningful

An emulated run showed ~11x for `fold-128`, but that figure is an artifact:
QEMU translates table lookups and PCLMULQDQ with wildly different overheads.
Published results for this algorithm are typically **3–10x** over
slicing-by-N. Real numbers require real hardware.

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

## Next step

Run on x86-64 hardware. The output reports whether the CPU supports each path,
so it is self-describing:

1. If `fold-128` shows a large win — integrate it into `crc.cpp` behind a
   runtime check, replacing the bulk loop and keeping slicing-by-16 as the
   fallback for non-PCLMUL CPUs and the SFX build.
2. If `fold-256` is available and beats `fold-128` by more than noise, add it
   as a second tier. If it does not, drop it — it costs code for nothing.
3. If neither beats the table meaningfully, this closes the same way the
   `-march` investigation did.
