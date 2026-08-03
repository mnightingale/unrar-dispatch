/*
 * PCLMULQDQ / VPCLMULQDQ CRC32 folding for unrar.
 *
 * Computes the same CRC32 as unrar's slicing-by-16 table implementation
 * (crc.cpp), with the same calling convention:
 *
 *     NewCRC = CRC32Fold(StartCRC, Addr, Size)
 *
 * so it is a drop-in replacement for the body of CRC32().
 *
 * Attribution chain
 * -----------------
 * The folding algorithm is Intel's, published in "Fast CRC Computation for
 * Generic Polynomials Using PCLMULQDQ Instruction" (2009). This code follows
 * the zlib-ng implementation (zlib license) and, for the 256-bit variant,
 * animetosho's rapidyenc adaptation of it (Public Domain / CC0):
 *
 *     https://github.com/animetosho/rapidyenc/blob/master/src/crc_folding_256.cc
 *
 * The fold constants are properties of the CRC32 polynomial 0xEDB88320, not
 * creative expression; crcbench.cpp re-derives and asserts them at runtime.
 *
 * Two widths are provided because they target very different CPU populations:
 *
 *   CRC32Fold128 - SSE4.1 + PCLMULQDQ. Westmere (2010) and later, i.e.
 *                  effectively every x86-64 CPU in service.
 *   CRC32Fold256 - AVX2 + VPCLMULQDQ. Ice Lake (2019) / Zen 4 and later only.
 *                  Note VPCLMULQDQ is NOT part of x86-64-v3 or even v4; it is
 *                  a separate feature bit and must be detected on its own.
 *
 * Both fold 512 bits of state per iteration and consume 64 bytes per loop; the
 * 256-bit version simply packs the same four 128-bit lanes into two registers,
 * halving the instruction count for the same work.
 */

#ifndef _RAR_CRC_FOLD_
#define _RAR_CRC_FOLD_

#include <stddef.h>

#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
#define CRC_FOLD_X86
#endif

#ifdef CRC_FOLD_X86

#ifdef __cplusplus
extern "C" {
#endif

/* Runtime capability probes. Safe to call on any x86 CPU. */
int CRC32FoldHave128(void);   /* SSE4.1 + PCLMULQDQ */
int CRC32FoldHave256(void);   /* AVX2 + VPCLMULQDQ  */

/*
 * Both take and return unrar's CRC convention (start at 0xFFFFFFFF, caller
 * XORs the final value with 0xFFFFFFFF). Size may be any value including 0;
 * runs shorter than one 64-byte block fall through to the caller-supplied
 * scalar tail, so these are only worth calling for reasonably large buffers.
 *
 * Calling one whose CRC32FoldHaveNNN() returns 0 is undefined - check first.
 */
unsigned int CRC32Fold128(unsigned int StartCRC, const void *Addr, size_t Size);
unsigned int CRC32Fold256(unsigned int StartCRC, const void *Addr, size_t Size);

#ifdef __cplusplus
}
#endif

#endif /* CRC_FOLD_X86 */
#endif
