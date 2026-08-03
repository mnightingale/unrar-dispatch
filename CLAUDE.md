# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RARLAB's portable UnRAR source (version 7.23, see [version.hpp](version.hpp)) — a C++11 decompressor for RAR 1.4/1.5/2.x/3.x/5.0/7.0 archives. Vendored upstream drop, single `Initial` commit, no local modifications yet.

Per [readme.txt](readme.txt): this source is *generated* from the proprietary RAR source by a tool that strips `#ifndef UNRAR ... #endif` blocks. That process is imperfect, so compression-side declarations and RAR-only leftovers survive in headers (`CmdAdd`, `PPack`, `compress.hpp`, packer flags in `ComprDataIO`). Don't "clean up" apparent dead code — it exists so upstream drops stay diffable. Keep local changes minimal and surgical for the same reason.

Licensing constraint from [license.txt](license.txt): the code may not be used to re-create the RAR compression algorithm, and modified distributions must state that in docs and source comments.

## Build

No test suite, no linter, no CI. The makefile is Unix-only; [UnRAR.vcxproj](UnRAR.vcxproj) / [UnRARDll.vcxproj](UnRARDll.vcxproj) are the MSVC equivalents.

```bash
make -j8
```

Other targets:

```bash
make lib
```

Builds `libunrar.so` + `libunrar.a` (`-DRARDLL`, adds `-fPIC`). `make sfx` builds `default.sfx` (`-DSFX_MODULE`). `make clean` removes objects and binaries. `make install` / `install-lib` honor `DESTDIR` (default `/usr`).

The build variant is selected by the makefile `WHAT` variable, which becomes `-D$(WHAT)` on every compile: `UNRAR` (default CLI), `RARDLL`, or `SFX_MODULE`. Object files are shared between variants but compiled with different defines, so **always `make clean` when switching targets**.

Verification is manual — build and run `./unrar` against real archives (`./unrar t arc.rar`, `./unrar l`, `./unrar x`). Exit codes are the `RAR_EXIT` enum in [errhnd.hpp](errhnd.hpp:4).

### Feature macros

- Platform: `_WIN_ALL` / `_UNIX` / `_APPLE` / `_ANDROID` are derived in [raros.hpp](raros.hpp) from compiler predefines; everything platform-conditional keys off those, not off raw `__APPLE__` etc.
- `RAR_SMP` — multithreaded unpack (set by the makefile `DEFINES`, and on Windows by [os.hpp](os.hpp)). Guards [threadpool.cpp](threadpool.cpp) and [unpack50mt.cpp](unpack50mt.cpp).
- `SILENT` — auto-defined whenever `RARDLL` is; swaps the UI implementation and compiles out the console code.
- `USE_QOPEN`, `PROPAGATE_MOTW` — set in [rardefs.hpp](rardefs.hpp); quick-open header cache and Windows Mark-of-the-Web propagation.
- `USE_SSE` / `USE_NEON_AES` / `USE_NEON_CRC32`, `ALLOW_MISALIGNED`, `LITTLE_ENDIAN`/`BIG_ENDIAN` — resolved in [os.hpp](os.hpp). Porting to a new arch means editing os.hpp and [rartypes.hpp](rartypes.hpp).

## Architecture

### Two build-level structures you must know before editing

**1. [rar.hpp](rar.hpp) is a master umbrella header.** Nearly every `.cpp` starts with `#include "rar.hpp"` and nothing else; rar.hpp includes every other `.hpp` in a fixed dependency order. A new header must be added there, in the right position, or it won't be visible.

**2. Many `.cpp` files are `#include`d into other `.cpp` files**, not compiled separately. Only the files listed in `OBJECTS` / `UNRAR_OBJ` / `LIB_OBJ` in the [makefile](makefile) are real translation units. The aggregators:

| Translation unit | Pulls in |
| --- | --- |
| `unpack.cpp` | `coder`, `suballoc`, `model`, `unpackinline`, `unpack50mt`, `unpack15`, `unpack20`, `unpack30`, `unpack50`, `unpack50frag` |
| `crypt.cpp` | `crypt1`, `crypt2`, `crypt3`, `crypt5` |
| `ui.cpp` | `uicommon`, `uisilent`, `uiconsole` |
| `extinfo.cpp` | `hardlinks`, `win32stm`, `win32acl`, `win32lnk`, `uowners`, `ulinks` |
| `cmddata.cpp` | `cmdfilter`, `cmdmix` |
| `recvol.cpp` | `recvol3`, `recvol5` |
| `blake2s.cpp` | `blake2s_sse`, `blake2sp` |
| `archive.cpp` | `arccmt` |
| `consio.cpp` | `log` |
| `threadpool.cpp` | `threadmisc` |

Consequence: static/file-scope symbols leak across these boundaries, and editing e.g. `unpack50.cpp` recompiles `unpack.o`. Adding a genuinely new TU requires editing both the makefile object lists and both `.vcxproj` files.

### Entry points

- **CLI**: `main()` in [rar.cpp](rar.cpp), compiled only when `RARDLL` is undefined. Sets up console + signal handlers, builds a `CommandData`, parses the command line twice (pre-pass, then config file + env var, then real pass), and calls `CommandData::ProcessCommand()`.
- **Library**: [dll.cpp](dll.cpp) implements the C API declared in [dll.hpp](dll.hpp) (`RAROpenArchiveEx`, `RARReadHeaderEx`, `RARProcessFileW`, callbacks). `RAR_DLL_VERSION` and the `ERAR_*` codes live there; the `RARHeaderDataEx`/`RAROpenArchiveDataEx` structs have `Reserved[]` padding — extend into it rather than growing the struct, to preserve ABI.

### Request flow

`CommandData::ProcessCommand()` ([cmddata.cpp:1094](cmddata.cpp:1094)) resolves the archive name (appends `.rar`, expands `.partN`, wildcard-scans via `ScanTree`), then dispatches on the command letter: `P/X/E/T` → `CmdExtract::DoExtract()` ([extract.cpp](extract.cpp)), `V/L` → `ListArchive()` ([list.cpp](list.cpp)).

`CmdExtract` drives the whole extraction: per-volume iteration, `AnalyzeArchive` for volume-set detection, password acquisition, destination path construction, file creation, and reference/hardlink/symlink resolution.

### Archive reading

`Archive` ([archive.hpp](archive.hpp)) derives from `File`, so an archive *is* a file handle with header state layered on. `IsSignature()` classifies the format (`RARFMT14`/`RARFMT15`/`RARFMT50`), and `ReadHeader()` dispatches to `ReadHeader14/15/50` — all three implemented in [arcread.cpp](arcread.cpp), the largest parser file. Parsed headers land in public members (`MainHead`, `FileHead`, `CryptHead`, `EndArcHead`, …) declared in [headers.hpp](headers.hpp) / [headers5.hpp](headers5.hpp); `CurBlockPos`/`NextBlockPos` track position. Raw field decoding goes through [rawread.cpp](rawread.cpp).

### Decompression

`Unpack::DoUnpack(Method, Solid)` ([unpack.cpp:160](unpack.cpp:160)) switches on the archive's compression version to a per-era implementation: 15 → `Unpack15`, 20/26 → `Unpack20`, 29 → `Unpack29`, `VER_PACK5` (50) / `VER_PACK7` (70) → `Unpack5` or `Unpack5MT` when `RAR_SMP` and threads > 1. Legacy methods are compiled out under `SFX_MODULE` and are unavailable in `Fragmented` (low-memory, no contiguous window) mode. RAR3 uses the PPM model in [model.cpp](model.cpp)/[suballoc.cpp](suballoc.cpp); RAR5 uses filters executed by the pseudo-VM in [rarvm.cpp](rarvm.cpp).

`ComprDataIO` ([rdwrfn.hpp](rdwrfn.hpp)) is the I/O bridge between `Archive` and `Unpack` — it feeds packed bytes in, takes unpacked bytes out, and layers decryption, checksumming, progress reporting, and memory-vs-file source/destination on top. It is what makes the same unpacker serve both the CLI and the DLL's memory-output mode.

### Cross-cutting services

- **Errors**: fatal paths `throw` a `RAR_EXIT` value; only `main()` and the DLL entry points catch. The global `ErrHandler` ([errhnd.cpp](errhnd.cpp)) accumulates the exit code and handles signals.
- **UI**: everything user-facing goes through the variadic `uiMsg(UIMESSAGE_CODE, ...)` in [ui.hpp](ui.hpp:185). Three implementations are compiled behind it (`uicommon`/`uiconsole`/`uisilent`); which one is active depends on `SILENT`. Message text lives in [loclang.hpp](loclang.hpp) — add a `UIMESSAGE_CODE` and its string there together.
- **Strings**: `std::wstring` and `wchar` everywhere internally, with conversions in [unicode.cpp](unicode.cpp). Path manipulation is centralized in [pathfn.cpp](pathfn.cpp). Newer upstream code uses `std::wstring`/`std::vector`; older code still uses raw buffers — match whichever the surrounding function uses.
- **Crypto/hash**: AES in [rijndael.cpp](rijndael.cpp), key derivation split per archive generation across `crypt1/2/3/5.cpp`, checksums in [crc.cpp](crc.cpp), [sha1.cpp](sha1.cpp), [sha256.cpp](sha256.cpp), [blake2s.cpp](blake2s.cpp), unified behind `HashValue`/`DataHash` in [hash.hpp](hash.hpp).
- **Recovery volumes**: [recvol3.cpp](recvol3.cpp)/[recvol5.cpp](recvol5.cpp) over the Reed-Solomon coders in [rs.cpp](rs.cpp)/[rs16.cpp](rs16.cpp). Not part of the DLL build.

## Style

Follow the surrounding upstream conventions: 2-space indent, opening brace on its own line, no space after commas in argument lists, `//` comments. The makefile suppresses `-Wlogical-op-parentheses`, `-Wswitch`, and `-Wdangling-else`, so the existing code relies on those patterns.
