# Is the CRC32 thread pool still worth it?

`DataHash::Update` splits CRC32 across a thread pool for any buffer of 32 KB or
more ([hash.cpp:213](../hash.cpp)). That threshold was chosen when CRC32 was a
~4 GB/s table. Folding makes it 10-15x faster
([crcbench/README.md](../crcbench/README.md)), which raised the question this
directory answers: what is the pool still buying, is it ever worse, and would
removing it be better?

```bash
make -f crcmt/makefile run                 # microbenchmark, real DataHash path
crcmt/add-midsize-corpus.sh                # adds the archives that matter here
crcmt/bench.sh -c dispatch/corpus          # end-to-end, three ways per archive
crcmt/bench.sh -c dispatch/corpus -f "0 256"   # x86: both CRC speeds
crcmt/bench.sh -c dispatch/corpus -b 0x80000   # ...with a raised threshold
```

## Status: measured on ARM and x86, answered

**With folding active, the pool is a net loss at every buffer size unrar
generates.** Not "below a threshold" — everywhere, including the 4 MB calls of
the stored path, which is the largest `Update()` unrar ever makes. With the
table CRC the same pool is a large win. The tuning was right for the CRC it was
written for and folding inverts it:

| `dispatch/corpus` row | pool vs 1 thread, `FOLD=0` (table) | `FOLD=256` |
| --- | ---: | ---: |
| rar5-store-m0 | **+42.0%** | **-4.7%** |
| rar5-mid1m-m0 | **+39.4%** | **-15.9%** (11% noise) |
| rar5-mid256k-m0 | **+16.2%** | **-15.6%** |
| rar5-encrypted-m0 | **+15.2%** | **-10.9%** |
| rar5-text-m5 | **+14.9%** | -2.8% (noise) |
| rar5-vol.part01 | +5.2% | **-3.3%** |
| rar5-exe-m5 | +2.6% | **-3.8%** |
| rar5-mid64k-m0 | **-5.1%** | **-14.1%** |

Positive means the pool is faster. Measured on x86-64 Linux, 256 MB corpus,
min-of-5, one binary with `UNRAR_CRC_FOLD` switching the CRC32 implementation
underneath, so nothing but the CRC differs between the two columns.

Four findings, in order of how much they should change the code:

1. **The pool should not be used when folding is active.** There is no threshold
   that rescues it: `rar5-store-m0` issues 4 MB `Update()` calls — the largest
   `File::CopyBufferSize()` produces — and loses 4.7% at 1.6% noise. Anything
   smaller loses by more.

2. **The pool now costs more than the work it is parallelising.** On
   `rar5-exe-m5`, folded CRC32 is 4.7 ms of a 580 ms run when left on the
   calling thread — 0.8%. Pooled, the same checksum costs 26.5 ms, or 4.6%. The
   overhead is over five times the job.

3. **The current 32 KB threshold was too low even for the table CRC.**
   `rar5-mid64k-m0` loses 5.1% at `FOLD=0`. That regression predates folding
   entirely and is in shipping unrar today on x86.

4. **The pool is still right for the table path, and marginal for ARM.** At
   `FOLD=0` it earns +42% on stored data. On ARM's hardware crc32 (~8.7 GB/s,
   between the two x86 tiers) it earns +29% on stored data but loses 25-60% on
   32 KB - 512 KB calls. So the threshold has to be a function of the CRC
   implementation's rate; a single constant cannot serve all four paths.

The recommendation is in *What the threshold should be* below. Nothing in this
directory changes shipping behaviour — the harness and the analysis are here,
the fix is not applied.

**Measured on**: x86-64 Linux for the folding tables (the same class of machine
as `crcbench`'s ~4.1 / 37.7 / 50.0 GB/s figures), and Apple M2 Pro (8P+4E),
macOS 15, Apple clang for the ARM tables. ARM is included because its hardware
CRC32 sits between the table and folding in rate, which is what shows the
threshold has to scale rather than take one of two values.

### One prediction was wrong, in the direction that matters

The x86 run was set up to test a prediction that folding would be
*bandwidth*-bound on unrar's 4 MB buffers, around 15-20 GB/s, so that the pool
would keep a little headroom. It is not: `rar5-store-m0` CRCs 256 MB in 5.6 ms
single-threaded, **45.9 GB/s**, essentially `crcbench`'s cache-hot peak. The
4 MB copy buffer is L2/L3-resident when the CRC runs, so folding gets its full
rate and the pool has no headroom left to sell. That is why every row flipped
and not just the 1 MB one.

The same row is a useful cross-check on the whole harness: at `FOLD=0` it gives
256 MiB / 60.7 ms = **4.4 GB/s**, against `crcbench`'s standalone 4.1 GB/s for
slicing-by-16 on comparable hardware. Two independent harnesses, one driving the
real `DataHash` through `unrar t` and one not linking unrar at all, agreeing
within 7% — so the 45.9 GB/s figure from the same subtraction can be trusted
too.

## What the pool is actually for

`UpdateCRC32MT` splits the buffer into blocks, CRCs each on a pool thread, then
stitches the results with Galois-field arithmetic
([hash.cpp:206](../hash.cpp)'s derivation). Blocks are at least `MinBlock`
(16 KB), so the thread count falls automatically for small buffers: a 64 KB
`Update()` becomes 4 blocks, not 8.

Two costs are paid per `Update()` call regardless of how fast CRC32 is, and they
are what the threshold has to cover:

```
=== fixed costs the pool adds, whatever the CRC32 rate ===
  dispatch+join of 2 empty tasks :   12.15 us per Update() call
  dispatch+join of 4 empty tasks :   12.73 us per Update() call
  dispatch+join of 8 empty tasks :   13.76 us per Update() call
  galois combine per block       :   0.058 us (x blocks per call)
  gfExpCRC, once per call        :   0.498 us
```

The combine arithmetic is noise — 8 blocks cost 0.5 µs of `gfMulCRC` plus one
0.5 µs `gfExpCRC`. **Dispatch is the entire cost: ~13 µs of condition-variable
round trip per `Update()` call**, paid on the calling thread
([threadpool.cpp:279](../threadpool.cpp) broadcasts and then waits).

13 µs buys 43 KB of CRC at 3.3 GB/s, but 113 KB at 8.7 GB/s and something like
260 KB at 20 GB/s. That is the whole story: **the break-even `Update()` size
scales with the CRC rate, and the threshold is a constant.**

## Throughput vs `Update()` size

From `make -f crcmt/makefile run`, producer model — the buffer is written by the
calling thread before each `Update()`, as it is in unrar, so the pool has to
pull the data out of the producing core's cache. GB/s of CRC:

| `Update()` size | 1 thr | 2 | 4 | 8 | best/1thr |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 16 KB | 9.11 | 8.87 | 8.87 | 8.92 | 1.00x (below threshold) |
| 32 KB | 8.76 | 1.70 | 1.71 | 1.73 | **0.20x** |
| 64 KB | 8.72 | 2.97 | 2.78 | 2.48 | **0.34x** |
| 256 KB | 8.56 | 6.86 | 6.78 | 7.18 | **0.84x** |
| 1 MB | 8.75 | 11.40 | 16.05 | 18.77 | 2.14x |
| 4 MB | 8.70 | 14.41 | 25.92 | 27.33 | 3.14x |
| 16 MB | 8.26 | 15.44 | 27.70 | 43.45 | 5.26x |
| 64 MB | 8.16 | 15.95 | 30.47 | 51.22 | 6.28x |

The same table with the table CRC (build `crc.cpp` with
`-U__ARM_FEATURE_CRC32`, the ARM equivalent of `UNRAR_CRC_FOLD=0`):

| `Update()` size | 1 thr | 2 | 4 | 8 | best/1thr |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 32 KB | 3.34 | 1.42 | 1.43 | 1.32 | **0.43x** |
| 64 KB | 3.28 | 2.33 | 2.40 | 2.28 | **0.73x** |
| 256 KB | 3.33 | 4.12 | 5.56 | 5.67 | 1.71x |
| 1 MB | 3.36 | 5.27 | 8.71 | 11.19 | 3.33x |
| 4 MB | 3.27 | 5.82 | 10.17 | 14.85 | 4.54x |
| 64 MB | 3.20 | 5.91 | 10.55 | 15.26 | 4.77x |

Read the two together and the mechanism is unambiguous:

- **The 32 KB row is a cliff in both.** Just above the threshold the buffer is
  split into 2 blocks and the run costs 13 µs of dispatch to save ~2 µs of CRC.
  With the fast CRC it is 5x slower than not pooling; with the table, 2.4x.
- **The crossover moves right as CRC gets faster.** Break-even is ~150 KB with
  the table and ~600 KB with the hardware CRC. Extrapolating by rate alone puts
  it at 1.5-2.5 MB for x86 folding.
- **The ceiling is bandwidth, not cores.** Eight threads never reach 8x. The
  fast-CRC column tops out at 51 GB/s and the table column at 15 GB/s, both
  short of 8x their single-thread rate, and 8 threads only ever cost ~4-7 cores
  of CPU because they spend the rest stalled on memory.

The microbench also prints a `resident` table (repeated `Update()` on one
buffer, each worker's slice staying hot in its own L1/L2). It is 20-40% kinder
to the pool at large sizes and is included only to bound the win from above —
unrar never gets that cache state.

## Which sizes does unrar actually use?

The cliff only matters if real archives land on it. `UNRAR_CRC_HIST=1` dumps
the distribution:

| archive | `Update()` sizes | share of bytes |
| --- | --- | --- |
| one 512 MB stored file | 128 calls, all 4 MB | 100% |
| one 512 MB text file, `-m5` | 128 calls ≥ 2 MB | 99.2% |
| " | 15 calls, 16 KB - 256 KB | 0.8% |
| `rar5-exe-m5` (64 MB, `-m5`) | 315 calls, 64 - 128 KB | **32.8%** |
| " | 89 calls, 32 - 64 KB | 6.3% |
| " | 66 calls, 128 - 512 KB | 24.8% |
| " | 1 call ≥ 1 MB | 1.8% |
| 2048 stored 64 KB files | 2048 calls, all exactly 64 KB | 100% |

Three distinct regimes, and only the first is the one the threshold was tuned
for:

**One large file: 4 MB, cliff irrelevant.** The stored path CRCs
`File::CopyBufferSize()` chunks ([file.hpp:148](../file.hpp), 4 MB) and the
RAR5 unpack path ramps up to similar sizes for unfiltered data. Note
`CopyBufferSize`'s own comment says 4 MB was chosen because *"multithreaded
CRC32 seems to benefit from 0x400000, especially on ARM CPUs"* — the buffer size
and the threshold were co-tuned for the slow-CRC world.

**Filtered data: mostly 32 - 512 KB, squarely on the cliff.** This is the row
that makes the finding matter. `UnpWriteBuf` flushes at every filter boundary
([unpack50.cpp:320](../unpack50.cpp)), so an executable compressed with `-m5` —
where the x86 filter fires constantly — is CRC'd in ~64 KB pieces for its whole
length. 494 of `rar5-exe-m5`'s 1257 calls are pooled and **95% of its bytes
arrive in calls below 512 KB**. Compressed executables are not a corner case,
and `rar5-vol` (the same `exe.bin`, split into volumes) behaves the same way.

**Many small files: one `Update()` per file.** Files of 32 KB to a few hundred
KB are entirely ordinary. `dispatch/corpus` did not cover this band —
`rar5-many-m5`'s 4 KB files are *below* the threshold and never pooled, and
`rar5-store-m0` is one big file — which is why
[add-midsize-corpus.sh](add-midsize-corpus.sh) exists.

## End-to-end, ARM

The x86 tables are in *Status* above; this section is the ARM run, which is where
the intermediate CRC rate makes the scaling visible.

`crcmt/bench.sh`, `dispatch/corpus` at `-s 64` plus the three mid-size arms,
default threads, min-of-7, page cache warm. Each archive is timed three ways
with everything else held fixed: CRC skipped entirely, CRC on the calling thread
(`UNRAR_CRC_MT=1`, unpack still threaded), and unmodified.

| archive | no CRC | CRC 1 thr | CRC pool | pool vs 1 thr | cores | noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| rar5-store-m0 | 9.6 ms | 17.3 ms | 12.5 ms | **+27.7%** | 1.58 | 11.5% |
| rar5-mid1m-m0 | 18.6 ms | 34.0 ms | 30.9 ms | +9.1% | 1.67 | 1.3% |
| rar5-encrypted-m0 | 83.4 ms | 90.4 ms | 85.3 ms | +5.6% | 1.08 | 2.1% |
| rar5-text-m5 | 60.9 ms | 61.5 ms | 59.9 ms | +2.6% (noise) | 1.94 | 8.4% |
| rar5-solid-m5 | 24.2 ms | 24.4 ms | 24.1 ms | +1.2% (noise) | 1.15 | 3.4% |
| rar5-many-m5 | 24.4 ms | 24.2 ms | 24.6 ms | -1.7% (noise) | 0.95 | 2.9% |
| rar5-vol.part01 | 91.6 ms | 101.1 ms | 110.2 ms | **-9.0%** | 2.11 | 4.4% |
| rar5-exe-m5 | 90.5 ms | 98.3 ms | 109.7 ms | **-11.6%** | 2.09 | 2.0% |
| rar5-mid256k-m0 | 33.4 ms | 48.7 ms | 63.3 ms | **-30.0%** | 1.76 | 2.5% |
| rar5-mid64k-m0 | 95.7 ms | 109.1 ms | 178.4 ms | **-63.5%** | 1.74 | 1.8% |

The 512 MB single-file cases, run separately because at 64 MB the stored row is
too short to resolve (11.5% spread above):

| archive | no CRC | CRC 1 thr | CRC pool | pool vs 1 thr | cores |
| --- | ---: | ---: | ---: | ---: | ---: |
| 512 MB stored | 48.0 ms | 106.7 ms | 64.2 ms | **+39.8%** | 2.01 |
| 512 MB text `-m5` | 445.3 ms | 511.1 ms | 483.5 ms | +5.4% | 2.01 |

Four things worth reading off these:

**Four of eleven rows are slower with the pool, two of them from the stock
corpus.** `rar5-exe-m5` and `rar5-vol` are not synthetic - they are the
filtered-executable rows that were already in `dispatch/corpus` when the folding
work was benchmarked, and the pool costs them 9-12% of wall clock. That was
invisible before because nothing had measured the pool against its own absence.

**The regression is bigger end-to-end than the microbench suggests.** On the
64 KB archive the CRC's own cost goes from 13.4 ms to 82.7 ms - 6.2x - because
2048 calls x 13 µs of dispatch is 27 ms of pure overhead on the calling thread,
and the workers add cache-transfer cost on top. The whole command takes 63%
longer than it needs to, for a checksum a single core does in 13 ms.

**On compressed archives the pool is nearly free but also nearly pointless.**
The 512 MB text row saves 30 ms of a 483 ms run. It costs almost nothing in
cores (2.01 against 1.90 with no CRC at all) because unpack leaves most of the
machine idle - but it is 6% of the run, against 40% for the stored case.

**The deal gets worse as CRC gets faster.** Same 512 MB stored archive, same
`-mt8`, only the CRC implementation differing:

| CRC32 | CRC cost, 1 thread | CRC cost, pooled | wall saved | extra CPU | saved per extra CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| slicing-by-16 (~3.3 GB/s) | 152 ms | 32 ms | 120 ms | 34 ms | 3.5x |
| ARM hw crc32 (~8.7 GB/s) | 58 ms | 18 ms | 40 ms | 27 ms | 1.5x |

Both rows are still wins. But the pooled column barely improved when CRC32 got
2.6x faster (32 → 18 ms) because it was already bandwidth-bound, while the
single-threaded column improved by the full 2.6x. That is the whole trend in one
table, and x86 folding is where it ends up.

### Where ARM's break-even is

Raising `MinBlock` from 16 KB to 512 KB, so the pool engages from 1 MB up. Same
corpus, same run, min-of-7 — this is the measurement behind the ARM row of the
threshold table:

| archive | `MinBlock=0x4000` | `0x80000` | cores, before → after |
| --- | ---: | ---: | ---: |
| rar5-mid64k-m0 | **-63.5%** | +0.1% (noise) | 1.74 → 0.99 |
| rar5-mid256k-m0 | **-30.0%** | -0.2% (noise) | 1.76 → 0.97 |
| rar5-exe-m5 | **-11.6%** | -1.6% (noise) | 2.09 → 1.82 |
| rar5-vol.part01 | **-9.0%** | -1.9% (noise) | 2.11 → 1.83 |
| rar5-mid1m-m0 | +9.1% | +10.3% | 1.67 → 1.43 |
| rar5-encrypted-m0 | +5.6% | +4.9% | 1.08 → 1.08 |
| rar5-store-m0 | +27.7% | +31.9% | 1.58 → 1.64 |
| 512 MB stored | +39.8% | +39.0% | 2.01 → 2.01 |
| 512 MB text `-m5` | +5.4% | +5.8% | 2.01 → 2.00 |

On ARM that one constant removes every regression and costs none of the win,
which is why 512 KB is the suggested value for that tier. On x86 with folding it
is not enough, because the crossover is above the largest call unrar makes.

## What the threshold should be

`MinBlock` is the only thing that needs to change, but it cannot stay a
constant. It gates pooling (`DataSize < 2*MinBlock` stays serial) and floors the
block size, and the measured break-even moves by more than an order of magnitude
across the four CRC32 implementations unrar ships:

| CRC32 path | single-thread rate | measured break-even `Update()` size | suggested `MinBlock` |
| --- | ---: | --- | --- |
| slicing-by-16 table | ~4.2 GB/s | between 64 KB and 256 KB | `0x20000` |
| ARM hw crc32 | ~8.7 GB/s | between 256 KB and 1 MB | `0x80000` |
| `fold-128` | ~37 GB/s | above 4 MB, i.e. never reached | do not pool |
| `fold-256` | ~46 GB/s | above 4 MB, i.e. never reached | do not pool |

The evidence for each row: at `FOLD=0`, `mid64k` loses 5.1% and `mid256k` wins
16.2%. On ARM, `mid256k` loses 25.4% and `mid1m` wins 20.1%. At `FOLD=256`,
`store-m0`'s 4 MB calls lose 4.7% and nothing unrar does is larger.

That implies exporting the tier from [crc.cpp](../crc.cpp) — it already knows,
via `CRCFoldWidth` and `CRC_Neon` — rather than hardcoding one number in
hash.cpp. Something as small as a `CRC32MinSplitSize()` alongside `InitCRC32`,
returning `SIZE_MAX` for the folding paths, keeps the decision next to the
implementation it depends on.

Two caveats on the "do not pool" rows, neither resolvable with the hardware in
hand:

- **`fold-128` on pre-Haswell parts.** PCLMULQDQ was much slower on Westmere and
  Sandy Bridge than the 37 GB/s measured here, and `fold-128` exists to serve
  exactly those CPUs. If it runs at table-like rates there, they want the table
  row's threshold, not "never". Gating only `fold-256` on "never" and giving
  `fold-128` the 1 MB tier is the conservative reading; confirming it needs a
  2010-2012 x86 box.
- **Dispatch cost is platform-specific.** ~13 µs on macOS pthreads. Linux futex
  wakeups are cheaper, which is visible in the ARM-vs-x86 `mid64k` rows (-59.8%
  against -5.1% at comparable CRC rates). A cheaper wakeup moves every
  break-even down but does not change their ordering.

**Deleting the pool outright would be wrong**, even though it is dead weight on
every modern x86. It earns +42% on the table path, which is what non-x86, non-ARM
builds and `SFX_MODULE` use, and the pool object is shared with BLAKE2sp
([hash.hpp:53](../hash.hpp)), so removing CRC pooling would not remove the
threads, the pool, or its cost — only the benefit.

One second-order observation, not worth acting on alone: at 1 MB on ARM, 4
threads reach 16.05 GB/s against 8 threads' 18.77 for half the CPU. The
`BlockSize<MinBlock` clamp is the right shape for capping thread count; it is
the value that is out of date.

## Reproducing

```bash
crcmt/add-midsize-corpus.sh                          # 64K / 256K / 1M arms
crcmt/bench.sh -c dispatch/corpus -f "0 256"         # both CRC speeds
crcmt/bench.sh -c dispatch/corpus -f 256 -b 0x80000  # ...and with a threshold
make -f crcmt/makefile run                           # per-size crossover
UNRAR_CRC_FOLD=0 crcmt/build/mtbench                 # ...at table speed
```

Read `mtbench`'s producer table for where the crossover lands, and `bench.sh`'s
`pool` column for whether a row is `SLOWER`. The `cores` column is the cost side;
a row inside noise on wall clock but above 1.0 on cores is the pool spending CPU
for nothing.

Two things to be careful of when reading a `bench.sh` table:

- **The `cost` columns need a low-noise row to mean anything.** They are
  differences against the no-CRC baseline, so on a 25 ms measurement with 11%
  spread a 1 ms "cost" is not a number. The `pool` column is a direct
  1-thread-versus-pool comparison and does not have that problem — prefer it.
  `rar5-mid1m-m0` at `FOLD=256` is the row to re-run with `-n 15` if it matters.
- **Windows.** `ResetFileCache` ([extract.cpp:244](../extract.cpp)) purges the
  archive before `unrar t`, so stored rows there are I/O-bound and understate
  both the win and the regression — the trap
  [winread/README.md](../winread/README.md) documents. Use `unrar x`, or suppress
  the purge.

## How the measurements are made

`hash.cpp` carries four env knobs under `-DCRCMT_DIAG`, following the
`UNRAR_CRC_FOLD` precedent in [crcfold.cpp](../crcfold.cpp) — read once, no
effect unless set, and absent from a normal build:

| knob | effect |
| --- | --- |
| `UNRAR_CRC_MT=<n>` | force the CRC32 thread count. `1` keeps unpack multithreaded and takes only the CRC off the pool. |
| `UNRAR_CRC_MINBLOCK=<n>` | override `MinBlock`, to test a threshold without rebuilding. |
| `UNRAR_CRC_SKIP=1` | skip CRC32 entirely, to measure the same run without it. |
| `UNRAR_CRC_HIST=1` | dump the `Update()` size histogram to stderr at exit. |

`UNRAR_CRC_SKIP` also makes `DataHash::Cmp` report a match. Without that, `unrar
t` formats a checksum failure for every file, and on a 2000-file archive that
made the no-CRC baseline *slower* than the run it was supposed to be a floor
for — the `cost` columns came out negative. `bench.sh` uses `UNRAR_CRC_HIST` as
its "is this really a diag build" probe for the same reason: it is the only knob
whose presence is observable rather than merely timeable.

`UNRAR_CRC_SKIP` produces wrong checksums by design, which is why the block is
behind a define rather than always compiled like `UNRAR_CRC_FOLD`.
`crcmt/bench.sh` builds with the define itself and refuses to report numbers if
the knob turns out to have no effect — a non-diag binary would otherwise print
three identical columns, which reads exactly like "the pool makes no
difference".

`UNRAR_CRC_MT=1` rather than `-mt1` is the load-bearing detail in the
end-to-end table: `-mt1` would also serialise unpack, and the two effects are
not separable that way.
