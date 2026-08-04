# The Windows read gap

unrar reads 256 MB of **already-cached** archive data in ~93 ms. A bare loop
making byte-identical `ReadFile` calls does it in ~24 ms. Same file, same
flags, same chunk size, same buffer type, same offset, fresh process each time.

That ~70 ms is the largest unexplained cost in Windows extraction, and it is
what stops the CRC-folding win (~45 ms per 256 MB) from reaching the wall clock
on stored archives. This directory is the investigation into it.

## Status: characterised, cause not yet found

The gap is reproducible and precisely measured. Every candidate cause reachable
from user mode has been eliminated by measurement. The mechanism is still open.

## The measurement

`dispatch/corpus/rar5-store-m0.rar` — a single 256 MB stored file, so
extraction is read + CRC32 and nothing else. Ryzen 7 5800X, Windows 11,
VS2022 v143, `-mt1`. Physical disk reads are ~0 B/s throughout: the file is
entirely in RAM.

| | read 256 MB | stalls |
| --- | ---: | --- |
| unrar (`UnstoreFile` → `UnpRead` → `File::Read` → `ReadFile`) | **~93 ms** | 27 of 64 reads ≥1 ms, worst 25 ms |
| bare loop, fresh process, same everything | **~24 ms** | none |

unrar's reads are perfectly sequential — offset 82 + n·4 MB, no seeking,
verified by logging every `ReadFile` with its offset, size and duration. The
median read is 0.55 ms (7.3 GB/s); the problem is that 44% of them stall for
1-25 ms, and those stalls are 78% of all read time.

The cost is kernel-side page management, charged to kernel worker threads that
unrar then blocks on. From an ETW CPU-sampling trace of unrar and the bare loop
in the same session:

| | during unrar | during the bare loop |
| --- | ---: | ---: |
| `System` process CPU | **49.4 ms/run** | 1.4 ms/run |

Top `System` functions during unrar: `KeZeroPages` 7.6 ms, `MiSafeLockPage`
4.3 ms, `MiUnlinkPageFromListEx` 4.0 ms, `MiUpdateLargePageCandidateValue`
2.5 ms, `MiConvertLargeActivePageToChain` 2.1 ms,
`MiInitializeReadInProgressPfn` 2.0 ms, `MiCanBatchHardFaultPages` 1.2 ms.

`ExReleaseResourceLite` and `KeWaitForSingleObject` appear in unrar's kernel
stacks and are absent from the bare loop's — unrar waits on something the bare
loop never contends for.

## Why this is a Windows problem

A cached `read()` on Linux copies out of the page cache and returns. A cached
`ReadFile` on Windows still goes through cache-manager page work that can block
for milliseconds. That is why `rar5-store-m0` is Linux's best CRC-folding
result (+69.5%) and Windows' worst (+5.7%) — compute-bound there, read-bound
here.

## Eliminated

Each tested, not assumed. Recorded so they are not re-tried.

| Hypothesis | How it was tested | Result |
| --- | --- | --- |
| Antivirus | ETW `Minifilter` provider | `WdFilter` 0.4 ms/run; all filters 6.5 ms |
| Backup agent (Veeam) | stopped the service, re-traced | 153 → 146 ms; not the cause |
| Physical disk I/O | PhysicalDisk counters | ≈ 0 B/s |
| File offset alignment | read from 0 / 64 / 174 / 512 / 4095 / 65536 | all ~11 GB/s |
| `FILE_FLAG_SEQUENTIAL_SCAN` | built without it | 104 vs 104 ms |
| QuickOpen indirection | `-qo-` | 108.8 vs 111.8 ms |
| Seek to EOF for the end-of-archive record | replicated in the bare loop | no stalls |
| Read buffer size | 1 / 2 / 4 / 8 / 16 / 32 MB | 92-138 ms, never better; cost is per-byte, not per-call |
| Process / I/O priority | read the code | `SetPriority` only via `-ri`; background mode commented out |
| Progress percentage output | `-idp`, `-idq` | no improvement |
| Destination page faults | `GetProcessMemoryInfo` in both | 5,733 vs 2,100 — would need ~65,000 |
| Consumer speed | dialled a synthetic consumer 0-16 passes | bare-loop read time flat at 28 ms |
| **Overlapping read with processing** | **built a read-ahead prototype** | **no measurable gain — see below** |

### Read-ahead: tested and rejected

A reader thread with a ring of buffers was implemented, verified correct on all
eight corpus archives, and measured. Every archive came out inside its noise
band, best case +3.2%. It is not the solution, for two independent reasons:

**The ceiling is much lower than it looks.** Overlap does not make the read
cheaper; it only hides the *consumer* behind it. The most it can recover is the
consumer's time — 8.6 ms of folded CRC, about 5% of wall. Read-ahead cannot
recover the CRC-folding win, because the thing it would hide *is* that win.

**It does not even reach its own ceiling.** Dialling the consumer up with
`UNRAR_CRC_FOLD` should grow the saving toward the CRC time:

| CRC path | sync | read-ahead | saved | ceiling (= CRC time) |
| --- | ---: | ---: | ---: | ---: |
| `fold=0` | 192 ms | 183 ms | 10 ms | 53 ms |
| `fold=128` | 184 ms | 189 ms | −5 ms | 18 ms |
| `fold=256` | 192 ms | 194 ms | −2 ms | 9 ms |

With 53 ms of CRC available to hide it recovers 10 ms, and deeper rings make it
*worse* (198 ms at depth 2 → 208 ms at depth 8) — the opposite of a reader
starved for buffers. Consistent with the page work being serialised on the file
object: moving `ReadFile` to another thread does not let it proceed in
parallel, and extra buffers only add pages for the memory manager to churn.

Two things worth carrying forward from that attempt:

- `UnstoreFile` is called **once per file**, not once per archive. The first
  version started a thread and allocated `Depth` × 4 MB per call, which made
  `rar5-many-m5` (thousands of small stored files) 3x slower.
- Overlap is only worth it where there is substantial work per byte to hide
  behind. Stored archives with a folded CRC have almost none.

## The bare loop *inside* unrar's process

The discriminator between "unrar's code is slow" and "unrar's process is slow"
is to run the bare read loop from inside unrar itself, at the moment unrar is
about to do the real read. Done by compiling with `-DRAR_READTEST` and calling
a bare `CreateFileW` + `ReadFile` loop at the top of `UnstoreFile`, pointed at
a path given in `UNRAR_READTEST`.

The answer is neither of the two expected ones:

| Bare loop, 256 MB, 4 MB chunks | time | stalls |
| --- | ---: | ---: |
| standalone process | 29-34 ms | 0 |
| **inside unrar, on a file unrar does _not_ have open** | **23-37 ms** | **0** |
| **inside unrar, on the file unrar _does_ have open** | **103-110 ms** | **22-27** |
| unrar's own read of that same file | 84-92 ms | 22-26 |

So unrar's process is *not* the problem — the same loop is fast there, on a
different file, in the same run. The cost attaches to **the file unrar has
open**, and it applies to reads through a second, independent handle just as
much as to unrar's own.

### What that rules out, and what it does not explain

unrar opens the archive exactly **once** — verified by logging every
`File::Open`. And its `CreateFile` parameters are byte-for-byte what the fast
bare loop uses:

```
unrar:     access=80000000 share=00000001 flags=08000000  (PreserveAtime=0)
bare loop: access=80000000 share=00000001 flags=08000000
```

`GENERIC_READ`, `FILE_SHARE_READ`, `FILE_FLAG_SEQUENTIAL_SCAN`. Identical. The
handle usage before the bulk read is replicated too — four small header reads
at the start, a seek to EOF, three more small reads, seek back to offset 82 —
and a bare loop doing exactly that stays fast.

Holding an extra idle handle in a standalone program reproduces the slowdown
only partially and unreliably (28-60 ms across runs, against a consistent
103-110 ms inside unrar), so "two file objects" is not on its own a sufficient
explanation.

**Current state: the trigger is having the file open through a `File::Open`ed
handle in unrar's process, but the mechanism by which that poisons the file's
cached-read path is not established.** Everything about the handle that can be
observed from user mode is identical to a handle that performs three times
better.

## Next steps

In rough order of expected value:

1. **Close and reopen the archive handle immediately before the bulk read.** If
   a fresh file object reads at bare-loop speed, the cause is accumulated state
   on the file object and the fix is trivial. Needs a temporary accessor —
   `ComprDataIO::SrcFile` is private and `UnstoreFile` only receives the
   `ComprDataIO`.
2. **Kernel-stack diff of the slow reads specifically**, rather than
   whole-process CPU. The existing `dispatch/profile-win.ps1` trace is the
   vehicle; it needs `FILE_IO` with stacks, which in turn needs a hand-written
   `.wpaProfile` for `wpaexporter`, because `xperf -a profile` cannot analyse a
   trace containing managed-provider events (see `dispatch/README.md`).
3. **`SetFileInformationByHandle`** with `FileIoPriorityHintInfo` on unrar's
   handle, to check whether the handle is being treated as low-priority I/O.

## Reproducing the diagnostics

All of the instrumentation was temporary and has been reverted. To recreate it:

| What | Where | Guard |
| --- | --- | --- |
| Per-`ReadFile` offset, size, duration | `File::DirectRead`, `file.cpp` | `RAR_READ_PROF` |
| Every `File::Open` with its CreateFile parameters | `File::Open`, `file.cpp` | `RAR_READTEST` |
| Bare read loop inside unrar's process | top of `UnstoreFile`, `extract.cpp` | `RAR_READTEST` |
| Read buffer size override | `File::CopyBufferSize`, `file.hpp` | `RAR_READ_PROF` |

Guard everything behind a define and drive it from an environment variable, so
one binary covers both paths and build differences cannot enter the
measurement — the same approach as `UNRAR_CRC_FOLD` in `crcfold.cpp`.

## Files

| File | Purpose |
| --- | --- |
| `README.md` | This document |
