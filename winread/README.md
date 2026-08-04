# The Windows read gap — SOLVED

`unrar t` on Windows deliberately purges the archive from the file cache before
reading it. Linux has no equivalent code. That single call is the whole
Linux/Windows asymmetry, and it is why CRC32 folding appeared not to help on
Windows.

[extract.cpp:244](../extract.cpp):

```cpp
#if defined(_WIN_ALL) && !defined(SFX_MODULE)
    if (Cmd->Command[0]=='T' || Cmd->Test)
      ResetFileCache(ArcName); // Reset the file cache when testing an archive.
#endif
```

[filefn.cpp:542](../filefn.cpp):

```cpp
void ResetFileCache(const std::wstring &Name)
{
  // To reset file cache in Windows it is enough to open it with
  // FILE_FLAG_NO_BUFFERING and then close it.
```

It is intentional and it is correct: `t` is supposed to verify that the archive
really reads back from disk, so testing a 256 MB archive out of RAM would
verify nothing. It is Windows-only and **Test-command-only** — extraction never
calls it.

## What it costs

Reading 256 MB of the archive with an identical bare loop, in unrar's own
process, before and after that call:

| | read | stalls |
| --- | ---: | ---: |
| before `ResetFileCache` (start of `main`) | 22.7 / 23.0 ms | 0 |
| after it (in `UnstoreFile`) | 70.1 / 68.8 ms | 21-23 |
| after it, with the call skipped | 25.4 / 26.8 ms | 0 |

An identical *copy* of the archive, read from the same process at the same
moments, stays fast throughout (30-38 ms, 0 stalls) — the effect is specific to
the file unrar purged.

## What it did to the CRC32 folding result

This is why `rar5-store-m0` was Linux's best folding result and Windows' worst.

`rar5-store-m0`, wall clock, min-of-7:

| | fold=0 | fold=256 | CRC win |
| --- | ---: | ---: | ---: |
| `unrar t`, cache purge as shipped | 147 ms | 139 ms | **+5.1%** |
| `unrar t`, purge skipped (what Linux does) | 125 ms | 80 ms | **+36.2%** |
| `unrar x`, real extraction | 186 ms | 139 ms | **+25.1%** |

The folding win was always there on Windows. `unrar t` was hiding it by making
every read pay for a cold cache. Extraction — what users actually do — gets
+25.1% on this archive; the percentage is lower than the purge-free `t` figure
only because `x` also writes 256 MB back out.

**Benchmarking consequence:** `dispatch/bench.ps1` and `dispatch/bench.sh` both
use `unrar t`. On Windows that measures cache-purged reads, on Linux it does
not, so the two are not comparable and the Windows numbers understate every
CPU-side optimisation. Any future Windows measurement of decode or checksum
work should use `x`, or skip the purge.

## How it was found

Six hypotheses were eliminated one at a time from the slow end without
converging (see below). What worked was bisecting on **time within unrar's own
run**: call the same bare read loop from two places — the top of `main()` and
`UnstoreFile` — in one process, against both the archive and an untouched copy
of it.

That immediately showed the file was fast at the first site and slow at the
second, while the copy was fast at both. From there the interval between the
two sites contained exactly one thing that touches the file, and reading the
code found it. An `UNRAR_NO_CACHERESET` switch around the call confirmed it.

The general lesson: when experiments from the slow end keep eliminating things
without converging, bisect from the fast end instead. It is guaranteed to
terminate, because one end is known fast and the other known slow.

## Eliminated along the way

All tested, not assumed. Recorded so they are not re-tried — and note that
several were only ever "suspicious" because the cache purge was making reads
expensive in the first place.

| Hypothesis | How it was tested | Result |
| --- | --- | --- |
| Antivirus | ETW `Minifilter` provider | `WdFilter` 0.4 ms/run; all filters 6.5 ms |
| Backup agent (Veeam) | stopped the service, re-traced | 153 → 146 ms; not the cause |
| Physical disk I/O | PhysicalDisk counters | ≈ 0 B/s (data was in the standby list) |
| File offset alignment | offsets 0 / 64 / 174 / 512 / 4095 / 65536 | all ~11 GB/s |
| `FILE_FLAG_SEQUENTIAL_SCAN` | built without it | 104 vs 104 ms |
| QuickOpen indirection | `-qo-` | 108.8 vs 111.8 ms |
| Seek to EOF for the end-of-archive record | replicated in a bare loop | no stalls |
| Read buffer size | 1 / 2 / 4 / 8 / 16 / 32 MB | 92-138 ms, never better |
| Process / I/O priority | read the code | `SetPriority` only via `-ri` |
| Progress output | `-idp`, `-idq` | no improvement |
| Destination page faults | `GetProcessMemoryInfo` | 5,733 vs 2,100 — needed ~65,000 |
| A second open handle on the file | held 1-2 idle handles, 5 samples each | 27-29 ms either way |
| Accumulated file-object state | swapped in a fresh handle before the bulk read | 68.4 vs 68.6 ms — no change |
| unrar's process environment | bare loop inside unrar, on an untouched copy | 23-37 ms — fast |
| Overlapping read with processing | built a read-ahead prototype | no gain — see below |

### Read-ahead: tested and rejected

A reader thread with a ring of buffers, verified correct on all eight corpus
archives, measured inside its noise band on every one (best case +3.2%).

**The ceiling was much lower than estimated.** Overlap does not make the read
cheaper, only hides the *consumer* behind it — at most the 8.6 ms of folded
CRC, about 5% of wall.

**And it did not reach even that.** With `UNRAR_CRC_FOLD=0` giving it 53 ms of
CRC to hide, it recovered 10 ms; deeper rings made it worse (198 ms at depth 2
→ 208 ms at depth 8). In hindsight that is expected: the reads were slow
because the pages had been purged, and no amount of overlapping conjures them
back.

Worth carrying forward: `UnstoreFile` is called **once per file**, not once per
archive. The first version started a thread and allocated `Depth` × 4 MB per
call, making `rar5-many-m5` (thousands of small stored files) 3x slower.

## What to tell upstream

Nothing here is a defect. `ResetFileCache` does what its comment says and is
deliberate. The two things worth raising are documentation, not code:

1. **`unrar t` and `unrar x` have very different I/O costs on Windows** and the
   difference is invisible from the outside. Anyone benchmarking unrar on
   Windows with `t` — which is the natural choice, since it needs no output
   directory — is measuring cold-cache reads and will conclude that CPU-side
   work does not matter.
2. **The same command is cache-warm on Linux**, so cross-platform comparisons
   using `t` are not measuring the same thing.

If upstream wanted to act on it, a switch to suppress the purge for
benchmarking would be enough. The behaviour itself should stay.

## Reproducing the diagnostics

All instrumentation was temporary and has been reverted. To recreate:

| What | Where | Guard |
| --- | --- | --- |
| Bare read loop at two points in one run | `main()` in `rar.cpp`, `UnstoreFile` in `extract.cpp` | `RAR_READTEST` |
| Skip the cache purge | `ExtractArchive`, `extract.cpp` | `UNRAR_NO_CACHERESET=1` |
| Per-`ReadFile` offset, size, duration | `File::DirectRead`, `file.cpp` | `RAR_READ_PROF` |
| Every `File::Open` with CreateFile parameters | `File::Open`, `file.cpp` | `RAR_READTEST` |

Take a `;`-separated path list in the environment and read each at every site —
comparing the archive against an untouched copy in the same run is what made
the effect unambiguous.

## Files

| File | Purpose |
| --- | --- |
| `README.md` | This document |
