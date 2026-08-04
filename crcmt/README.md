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

## Status: settled. Where folding is active, do not pool.

A 1 GB corpus resolved the last open row, and it went the way the smaller runs
hinted but could not prove. On `rar5-store-m0` — one stored file, 4 MB
`Update()` calls, the largest unrar makes — the folded CRC32 costs **20.6 ms on
the calling thread and 50.7 ms pooled**. The pool makes the checksum 2.5x more
expensive and the whole command **17.0% slower**, at 2.4% spread.

There is no buffer size at which pooling wins at folding speed, because 4 MB is
the ceiling and 4 MB loses.

x86-64 Linux, `dispatch/corpus -s 1024`, `UNRAR_CRC_FOLD=256`, n=9, medians:

| archive | no CRC | CRC 1 thr | CRC pooled | pool vs 1 thr | iqr |
| --- | ---: | ---: | ---: | ---: | ---: |
| rar5-store-m0 | 156.6 ms | 177.2 ms | 207.3 ms | **-17.0%** | 2.4% |
| rar5-encrypted-m0 | 412.4 ms | 424.0 ms | 475.9 ms | **-12.2%** | 3.1% |
| rar5-text-m5 | 852.9 ms | 878.8 ms | 912.8 ms | **-3.9%** | 1.8% |
| rar5-encrypted | 915.7 ms | 946.9 ms | 968.8 ms | **-2.3%** | 1.7% |
| rar5-vol.part01 | 2115.0 ms | 2189.9 ms | 2186.5 ms | +0.2% (noise) | 1.0% |
| rar5-exe-m5 | 2122.6 ms | 2173.9 ms | 2179.0 ms | -0.2% (noise) | 1.4% |
| rar5-many-m5 | 199.3 ms | 201.0 ms | 194.1 ms | +3.4% (noise) | 5.5% |

Nothing is faster with the pool. The two rows that lose most are the stored
ones, where the CRC is 12% of the run and there is no other work to hide the
overhead behind.

### The cost has two different shapes

Comparing the `CRC pooled` and `CRC 1 thr` columns across rows, the overhead
does not scale with one thing:

- **On 2-4 MB calls it tracks bytes**, at roughly **30 ms per GB** (`store-m0`
  +30.1 ms, `text-m5` +34.0 ms, both about 1 GB of output). That is the cost of
  migrating seven eighths of each buffer out of the producing core's cache into
  seven other cores' — work that did not exist when the CRC was the slow part.
- **On the ~64 KB calls that filters produce it tracks call count**, at a few µs
  each: `exe-m5` and `vol` decompress about as much as `text-m5` but pay only
  ~5 ms, because a 64 KB buffer splits into 4 blocks rather than 8 and there is
  little to migrate. On a 2.1 s run that disappears into the noise.

Both are pure loss against a CRC that now costs 20 ms per GB in total.

### What this corrected from the earlier, smaller runs

The 256 MB corpus was too short to resolve most of this, and it misled in both
directions. `exe-m5` and `vol` read as -3 to -5% across two runs and are now
noise at four times the data; `store-m0` and `mid1m` read as noise and are now
the largest losses in the table. Neither the earlier claim that filtered
archives are the main victim nor the claim that the 4 MB case was unresolvable
survived. The corpus size, not the number of runs, was the binding constraint —
see *Reproducing*.

What holds up unchanged, from the 256 MB runs where the rows were long enough:

- **Below ~512 KB the pool is a large loss at folding speed** — 12-18% of total
  wall clock on `mid256k` and `mid64k`, at 1.4-5.8% spread.
- **The 32 KB threshold is too low even for the table CRC**: `mid64k` loses 5.1%
  at `FOLD=0`. That regression predates folding and ships today.
- **The pool remains right for the table path** (+42% on stored data at
  `FOLD=0`) and marginal for ARM's hardware crc32 (+29% on stored, -25 to -60%
  on 32 KB - 512 KB calls). The threshold has to be a function of the CRC
  implementation's rate.

**Measured on**: x86-64 Linux/GCC for the folding tables (the same class of
machine as `crcbench`'s ~4.1 / 37.7 / 50.0 GB/s figures) and Apple M2 Pro
(8P+4E), macOS 15, Apple clang for the ARM ones.

### Dispatch cost is platform-specific, and it explains the ARM/x86 gap

| | 2 tasks | 4 tasks | 8 tasks |
| --- | ---: | ---: | ---: |
| Linux, x86-64 | 2.91 µs | 3.95 µs | 5.76 µs |
| macOS, arm64 | 12.15 µs | 12.73 µs | 13.76 µs |

Linux futex wakeups are 2-4x cheaper and scale with the number of threads woken
(~0.7 µs each); macOS pthread condvars cost ~13 µs almost flat. That is why the
same 64 KB archive loses 61% on ARM and 12% on x86 — the wakeup cost differing,
not the CRC ratio. The Galois combine is negligible on both (0.119 µs per block
on x86, 0.058 on ARM).

### The microbenchmark was wrong at 4 MB, and the end-to-end run caught it

Worth recording, because it is the one place the two methods disagreed and the
disagreement was real:

| 4 MB buffers, x86 `fold-256` | 1 thread | 8 threads |
| --- | ---: | ---: |
| `unrar t` on `rar5-store-m0`, 1 GB | 52.1 GB/s | **21.2 GB/s** |
| `mtbench` producer, as originally written | 52.50 GB/s | **83.99 GB/s** |

The single-thread columns agree to within 1%, which says the subtraction method
is sound. The pooled columns differ by 4x, and `unrar t` is right: `mtbench`
copied from one small fixed source buffer, so its entire working set — 4 MB
source plus 4 MB destination — stayed resident in L3 for the whole run, and each
worker found its slice already in its own cache. unrar reuses one 4 MB buffer
too, but it streams gigabytes of archive through the cache to fill it, evicting
that buffer between calls.

`mtbench` now reads from a source region four times the largest measured buffer
(256 MB) at a rotating offset, so the cache is churned the way it is in a real
run. On ARM this changed nothing measurable — at 8.4 GB/s the CRC is
compute-bound, not cache-bound — so **whether the fix works is itself an open
check on x86**: the producer 4 MB row should now read near 21 GB/s at 8 threads
and stay near 52 at one thread. If it still reports 84, the model has another
leak in it and the end-to-end numbers remain the only trustworthy ones.

## What the pool is actually for

`UpdateCRC32MT` splits the buffer into blocks, CRCs each on a pool thread, then
stitches the results with Galois-field arithmetic
([hash.cpp:206](../hash.cpp)'s derivation). Blocks are at least `MinBlock`
(16 KB), so the thread count falls automatically for small buffers: a 64 KB
`Update()` becomes 4 blocks, not 8.

Two costs are paid per `Update()` call regardless of how fast CRC32 is, and they
are what the threshold has to cover. `mtbench` measures both directly; the
per-platform figures are in *Dispatch cost is platform-specific* above.

**Dispatch is essentially the entire cost**: 5.76 µs on Linux/x86 and 13.76 µs
on macOS/arm64 for an 8-way split, paid on the calling thread as a
condition-variable round trip ([threadpool.cpp:279](../threadpool.cpp) broadcasts
and then waits). The Galois combine is 0.06-0.12 µs per block plus one
~0.45 µs `gfExpCRC`, so under a microsecond for an 8-block call — negligible
beside the wakeup, and negligible beside the CRC itself at any rate.

That single number is the whole story, because what it buys scales with the CRC
rate. 5.76 µs of dispatch is worth 24 KB of CRC at the table's 4.4 GB/s, 50 KB at
ARM's 8.7, and **288 KB at folding's 50** — before counting the cache traffic of
moving seven eighths of the buffer to other cores. The threshold is a constant;
the thing it has to cover is not.

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

And on x86-64 Linux with `fold-256`, the same producer model — note that the
single-thread column only collapses at 16 MB, and that 8 threads still win at
4 MB — that last figure is the one the end-to-end run later contradicted, see
*The microbenchmark was wrong at 4 MB* above:

| `Update()` size | 1 thr | 2 | 4 | 8 | best/1thr |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 16 KB | 50.17 | 49.23 | 48.53 | 48.63 | 1.00x (below threshold) |
| 32 KB | 57.37 | 4.58 | 4.51 | 4.65 | **0.08x** |
| 64 KB | 60.24 | 7.86 | 7.13 | 7.26 | **0.13x** |
| 256 KB | 53.48 | 17.96 | 17.31 | 16.76 | **0.34x** |
| 1 MB | 58.22 | 36.84 | 41.98 | 41.23 | **0.72x** |
| 4 MB | 52.50 | 58.68 | 75.63 | 83.99 | 1.60x |
| 16 MB | 18.11 | 22.50 | 26.33 | 25.47 | 1.45x |
| 64 MB | 20.19 | 28.75 | 39.75 | 41.94 | 2.08x |

The 32 KB row is the whole problem in one line: pooling a 32 KB buffer costs
**12x** its single-threaded time at folding speed.

The ARM table again with ARM's table CRC (build `crc.cpp` with
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

- **The 32 KB row is a cliff on every path.** Just above the threshold the
  buffer is split into 2 blocks, and the run pays a full dispatch to save a
  couple of microseconds of CRC. It is 2.4x slower than not pooling with ARM's
  table, 5x with ARM's hardware CRC, and **12x** with `fold-256`.
- **The crossover moves right as CRC gets faster.** ~150 KB with ARM's table,
  ~600 KB with ARM's hardware CRC, and between 1 MB and 4 MB with `fold-256`.
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
constant. The measured break-even moves by more than an order of magnitude
across the CRC32 implementations unrar ships, and `crc.cpp` already knows which
one it took (via `CRCFoldWidth` and `CRC_Neon`):

| CRC32 path | 1-thread rate | measured break-even | `MinBlock` | evidence |
| --- | ---: | --- | --- | --- |
| slicing-by-16 | ~4.4 GB/s | 64 KB - 256 KB | `0x10000`-`0x20000` | bracketed by two corpus rows at `FOLD=0` |
| ARM hw crc32 | ~8.7 GB/s | 256 KB - 1 MB | `0x80000` | bracketed, and `0x80000` verified end-to-end |
| `fold-128` / `fold-256` | 37-52 GB/s | above 4 MB, i.e. never | do not pool | `store-m0` at 1 GB loses 17.0% on 4 MB calls |

Evidence per row: at `FOLD=0`, `mid64k` loses 5.1% and `mid256k` wins 16.2%. On
ARM, `mid256k` loses 25.4% and `mid1m` wins 20.1%, and raising `MinBlock` to
`0x80000` removed every ARM regression without costing a win. At `FOLD=256`,
every size loses, including the largest one unrar generates.

That argues for exporting the tier from [crc.cpp](../crc.cpp) rather than
hardcoding a number in hash.cpp — something as small as a `CRC32MinSplitSize()`
next to `InitCRC32`, returning `SIZE_MAX` for the folding widths, so the decision
lives beside the implementation it depends on. Note `UpdateCRC32MT`'s existing
`DataSize < 2*MinBlock` guard already means a large enough `MinBlock` disables
pooling without a second code path — but watch for overflow if `SIZE_MAX` is
used literally, since that guard doubles it.

### The one caveat left, and it needs hardware nobody here has

**`fold-128` on pre-Haswell parts.** PCLMULQDQ was far slower on Westmere and
Sandy Bridge than the 37 GB/s measured here, and `fold-128` exists to serve
exactly those CPUs. If it runs at table-like rates there, they want the table
row's threshold rather than "do not pool", and a blanket rule on `CRCFoldWidth!=0`
would cost them the +42% the table path still earns. Gating "do not pool" on
`fold-256` and giving `fold-128` the ARM tier (`0x80000`) is the conservative
reading: it gives up a little on modern `fold-128` machines, where the true
answer is "never", in exchange for not regressing 2010-2012 hardware that cannot
be tested. Settling it needs a Westmere or Sandy Bridge box and one
`crcbench` run.

A second, smaller caveat: every break-even above scales with the platform's
thread-wakeup cost, so a platform cheaper than Linux futexes would move them all
down. The ordering does not change, and the folding row cannot move — it is
already past the largest buffer in the program.

One second-order observation, not worth acting on alone: at 1 MB on ARM, 4
threads reach 16.05 GB/s against 8 threads' 18.77 for half the CPU. The
`BlockSize<MinBlock` clamp is the right shape for capping thread count; it is the
value that is out of date.

**Deleting the pool outright would still be wrong**, even though it is dead
weight on every modern x86. It earns +42% on the table path, which is what
non-x86 non-ARM builds use, and the pool object is shared with BLAKE2sp
([hash.hpp:53](../hash.hpp)) — removing CRC pooling would not remove the threads,
the pool, or its cost, only the benefit.

## Reproducing

```bash
dispatch/make-corpus.sh -s 1024                      # see the size note below
crcmt/add-midsize-corpus.sh                          # 64K / 256K / 1M arms
crcmt/bench.sh -c dispatch/corpus -f "0 256"         # both CRC speeds
crcmt/bench.sh -c dispatch/corpus -f 256 -b 0x80000  # ...and with a threshold
make -f crcmt/makefile run                           # per-size crossover
UNRAR_CRC_FOLD=0 crcmt/build/mtbench                 # ...at table speed
```

**Corpus size is the binding constraint here, not run count.** At folding speed
the CRC is 2% of a stored run and under 3% of a compressed one, so at `-s 256`
most rows finish in under 100 ms and cannot resolve the effect at any `-n`. Every
conclusion in this file that changed, changed because the corpus grew. Use
`-s 1024` and treat `-s 256` as a smoke test.

**`make-corpus.sh` deletes its output directory**, so `add-midsize-corpus.sh` has
to be re-run after any regeneration or the 64K/256K/1M arms silently vanish from
the table.

Read `mtbench`'s producer table for where the crossover lands, and `bench.sh`'s
`pool` column for whether a row is `SLOWER`. The `cores` column is the cost side;
a row inside noise on wall clock but above 1.0 on cores is the pool spending CPU
for nothing.

Two things to be careful of when reading a `bench.sh` table:

- **A `short` label is not a small effect, it is no measurement.** Rows under
  100 ms cannot resolve a few percent however tight the spread looks. Rebuild
  bigger rather than reading those rows.
- **More runs does not make a row more significant.** The band is an
  interquartile spread on medians precisely so `-n 5` and `-n 15` are
  comparable; raising `-n` tightens the median but will not rescue a run that is
  too short.
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
