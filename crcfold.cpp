// CRC32 computation using the PCLMULQDQ / VPCLMULQDQ carry-less multiply
// folding algorithm.
//
// THIS FILE IS A LOCAL MODIFICATION, not part of the original UnRAR source
// distribution from RARLAB. See license.txt.
//
// Included by crc.cpp; not a separate translation unit, matching how
// blake2s_sse.cpp is included by blake2s.cpp.
//
// The folding algorithm is Intel's, published in "Fast CRC Computation for
// Generic Polynomials Using PCLMULQDQ Instruction" (2009). This code follows
// the zlib-ng implementation (zlib license) and, for the 256-bit variant,
// animetosho's rapidyenc adaptation of it (Public Domain / CC0):
//
//    https://github.com/animetosho/rapidyenc/blob/master/src/crc_folding_256.cc
//
// The fold constants are properties of the CRC32 polynomial 0xEDB88320.
//
// These functions process whole 64-byte blocks only and deliberately have no
// scalar tail of their own: the caller in crc.cpp already has a slicing-by-16
// loop plus a byte loop for the remainder, so duplicating a table here would
// be wasted space.

// os.hpp already pulls in <x86intrin.h> for GCC/Clang x86 builds, but include
// the intrinsics header explicitly so this file also compiles standalone
// (crcbench/ builds it directly to benchmark exactly what ships).
#include <immintrin.h>
#include <stdlib.h>     // getenv/atoi for the UNRAR_CRC_FOLD override

#if defined(__GNUC__) || defined(__clang__)
  #include <cpuid.h>
  #define CRCFOLD_TARGET_128 __attribute__((target("sse4.1,pclmul")))
  #define CRCFOLD_TARGET_256 __attribute__((target("avx2,vpclmulqdq,pclmul,sse4.1")))
  #define CRCFOLD_HAVE_256
#else
  // __cpuid/__cpuidex live in <intrin.h>, not <immintrin.h>. os.hpp already
  // includes it for MSVC builds of unrar, but crcbench compiles this file
  // standalone without rar.hpp, so include it here too - the include guards
  // make that free in the unrar build.
  #include <intrin.h>

  // MSVC permits these intrinsics without per-function target attributes and
  // without a matching /arch flag. _mm256_clmulepi64_epi128 (VPCLMULQDQ)
  // arrived in Visual Studio 2019, so the 256-bit path is compiled out below
  // that; the 128-bit path works on all supported versions.
  #define CRCFOLD_TARGET_128
  #define CRCFOLD_TARGET_256
  #if _MSC_VER >= 1920
    #define CRCFOLD_HAVE_256
  #endif
#endif

// k1 = 0x154442bd4, k2 = 0x1c6e41596. Folds a 512-bit distance, used by both
// widths: folding four 128-bit lanes forward by 512 bits is the same operation
// whether they live in four xmm or two ymm registers. Laid out so that one
// 128-bit lane is { low64 = k2, high64 = k1 }.
#define CRCFOLD_E3 0x00000001
#define CRCFOLD_E2 0x54442bd4
#define CRCFOLD_E1 0x00000001
#define CRCFOLD_E0 0xc6e41596

// Tail reduction constants: rk1/rk2 fold by 128 bits, rk5/rk6 fold 128->64,
// rk7/rk8 are the Barrett reduction mu and polynomial.
#if defined(_MSC_VER)
__declspec(align(16)) static const uint CRCFoldK[] =
#else
static const uint CRCFoldK[] __attribute__((aligned(16))) =
#endif
{
  0xccaa009e, 0x00000000, // rk1
  0x751997d0, 0x00000001, // rk2
  0xccaa009e, 0x00000000, // rk5
  0x63cd6124, 0x00000001, // rk6
  0xf7011641, 0x00000000, // rk7
  0xdb710640, 0x00000001  // rk8
};

// Maps the incoming CRC into the folded domain before the first fold step.
#define CRCFOLD_INIT_MUL 0xdfded7ec


// Reduce 512 bits of fold state to a 32-bit CRC.
//
// Not inlined into the 256-bit path on purpose: calling across differing
// target attributes is always legal, inlining across them is not, and this
// runs once per CRC32() call so the call costs nothing measurable.
//
// zlib complements the CRC on entry and exit; unrar carries the raw running
// value and leaves the final XOR to the caller, so both inversions present in
// the reference implementation are omitted here - they cancel.
CRCFOLD_TARGET_128
static uint CRCFoldReduce(__m128i Crc0,__m128i Crc1,__m128i Crc2,__m128i Crc3)
{
  const __m128i Mask = _mm_set_epi32(-1,-1,-1,0);
  __m128i T0,T1,T2,Fold;

  // 512 -> 128: fold Crc0..Crc2 down into Crc3.
  Fold = _mm_load_si128((const __m128i *)CRCFoldK);

  T0   = _mm_clmulepi64_si128(Crc0,Fold,0x10);
  Crc0 = _mm_clmulepi64_si128(Crc0,Fold,0x01);
  Crc1 = _mm_xor_si128(_mm_xor_si128(Crc1,T0),Crc0);

  T1   = _mm_clmulepi64_si128(Crc1,Fold,0x10);
  Crc1 = _mm_clmulepi64_si128(Crc1,Fold,0x01);
  Crc2 = _mm_xor_si128(_mm_xor_si128(Crc2,T1),Crc1);

  T2   = _mm_clmulepi64_si128(Crc2,Fold,0x10);
  Crc2 = _mm_clmulepi64_si128(Crc2,Fold,0x01);
  Crc3 = _mm_xor_si128(_mm_xor_si128(Crc3,T2),Crc2);

  // 128 -> 64
  Fold = _mm_load_si128((const __m128i *)CRCFoldK + 1);

  Crc0 = Crc3;
  Crc3 = _mm_clmulepi64_si128(Crc3,Fold,0);
  Crc0 = _mm_srli_si128(Crc0,8);
  Crc3 = _mm_xor_si128(Crc3,Crc0);

  Crc0 = Crc3;
  Crc3 = _mm_slli_si128(Crc3,4);
  Crc3 = _mm_clmulepi64_si128(Crc3,Fold,0x10);
  Crc0 = _mm_and_si128(Crc0,Mask);
  Crc3 = _mm_xor_si128(Crc3,Crc0);

  // Barrett reduction to 32 bits.
  Crc1 = Crc3;
  Fold = _mm_load_si128((const __m128i *)CRCFoldK + 2);

  Crc3 = _mm_clmulepi64_si128(Crc3,Fold,0);
  Crc3 = _mm_clmulepi64_si128(Crc3,Fold,0x10);
  Crc3 = _mm_xor_si128(Crc3,Crc1);

  return (uint)_mm_extract_epi32(Crc3,2);
}


CRCFOLD_TARGET_128
static __m128i CRCFold128Step(__m128i Src,__m128i Data)
{
  const __m128i K = _mm_set_epi32(CRCFOLD_E3,CRCFOLD_E2,CRCFOLD_E1,CRCFOLD_E0);
  return _mm_xor_si128(_mm_xor_si128(Data,
           _mm_clmulepi64_si128(Src,K,0x01)),
           _mm_clmulepi64_si128(Src,K,0x10));
}


// Process 'Blocks' whole 64-byte blocks. Caller advances Data and Size.
CRCFOLD_TARGET_128
static uint CRCFold128(uint StartCRC,const byte *Data,size_t Blocks)
{
  __m128i Crc0=_mm_clmulepi64_si128(_mm_cvtsi32_si128((int)StartCRC),
                                    _mm_cvtsi32_si128((int)CRCFOLD_INIT_MUL),0);
  __m128i Crc1=_mm_setzero_si128();
  __m128i Crc2=_mm_setzero_si128();
  __m128i Crc3=_mm_setzero_si128();

  for (;Blocks>0;Blocks--,Data+=64)
  {
    Crc0=CRCFold128Step(Crc0,_mm_loadu_si128((const __m128i *)(Data   )));
    Crc1=CRCFold128Step(Crc1,_mm_loadu_si128((const __m128i *)(Data+16)));
    Crc2=CRCFold128Step(Crc2,_mm_loadu_si128((const __m128i *)(Data+32)));
    Crc3=CRCFold128Step(Crc3,_mm_loadu_si128((const __m128i *)(Data+48)));
  }

  return CRCFoldReduce(Crc0,Crc1,Crc2,Crc3);
}


#ifdef CRCFOLD_HAVE_256

CRCFOLD_TARGET_256
static __m256i CRCFold256Step(__m256i Src,__m256i Data)
{
  const __m256i K = _mm256_set_epi32(CRCFOLD_E3,CRCFOLD_E2,CRCFOLD_E1,CRCFOLD_E0,
                                     CRCFOLD_E3,CRCFOLD_E2,CRCFOLD_E1,CRCFOLD_E0);
  return _mm256_xor_si256(_mm256_xor_si256(Data,
           _mm256_clmulepi64_epi128(Src,K,0x01)),
           _mm256_clmulepi64_epi128(Src,K,0x10));
}


// Same four 128-bit lanes as CRCFold128, packed two per register:
// Crc0 = [lane1|lane0] covers bytes 0..31, Crc1 covers bytes 32..63.
CRCFOLD_TARGET_256
static uint CRCFold256(uint StartCRC,const byte *Data,size_t Blocks)
{
  __m256i Crc0=_mm256_castsi128_si256(
                 _mm_clmulepi64_si128(_mm_cvtsi32_si128((int)StartCRC),
                                      _mm_cvtsi32_si128((int)CRCFOLD_INIT_MUL),0));
  // castsi128_si256 leaves the upper lane undefined; zero it explicitly.
  Crc0=_mm256_inserti128_si256(Crc0,_mm_setzero_si128(),1);
  __m256i Crc1=_mm256_setzero_si256();

  for (;Blocks>0;Blocks--,Data+=64)
  {
    Crc0=CRCFold256Step(Crc0,_mm256_loadu_si256((const __m256i *)(Data   )));
    Crc1=CRCFold256Step(Crc1,_mm256_loadu_si256((const __m256i *)(Data+32)));
  }

  __m128i X0=_mm256_castsi256_si128(Crc0);
  __m128i X1=_mm256_extracti128_si256(Crc0,1);
  __m128i X2=_mm256_castsi256_si128(Crc1);
  __m128i X3=_mm256_extracti128_si256(Crc1,1);
  _mm256_zeroupper();

  return CRCFoldReduce(X0,X1,X2,X3);
}

#endif // CRCFOLD_HAVE_256


// Detected once from InitCRC32. 0 = none, 128 = SSE4.1+PCLMULQDQ,
// 256 = AVX2+VPCLMULQDQ.
static uint CRCFoldWidth;


// CPUID and XGETBV, spelled per compiler. Only these two wrappers differ
// between MSVC and GCC/Clang; the detection logic below is shared, so the
// GCC build exercises exactly the same bit tests the MSVC build will use.
static void CRCFoldCpuid(uint Leaf,uint SubLeaf,uint Regs[4])
{
#if defined(_MSC_VER)
  __cpuidex((int *)Regs,(int)Leaf,(int)SubLeaf);
#else
  uint A,B,C,D;
  __cpuid_count(Leaf,SubLeaf,A,B,C,D);
  Regs[0]=A; Regs[1]=B; Regs[2]=C; Regs[3]=D;
#endif
}


// Low 32 bits of XCR0. Only valid if OSXSAVE is set - executing XGETBV
// without it raises #UD, so callers must check first.
static uint CRCFoldXcr0()
{
#if defined(_MSC_VER)
  return (uint)_xgetbv(0);
#else
  uint Lo,Hi;
  __asm__ __volatile__("xgetbv" : "=a"(Lo),"=d"(Hi) : "c"(0));
  (void)Hi;
  return Lo;
#endif
}


static void CRCFoldDetect()
{
  uint Regs[4];

  CRCFoldWidth=0;

  CRCFoldCpuid(0,0,Regs);
  uint MaxLeaf=Regs[0];
  if (MaxLeaf<1)
    return;

  CRCFoldCpuid(1,0,Regs);
  bool HasPclmul =(Regs[2] & (1u<< 1))!=0; // CPUID.1:ECX[1]
  bool HasSSE41  =(Regs[2] & (1u<<19))!=0; // CPUID.1:ECX[19]
  bool HasOSXsave=(Regs[2] & (1u<<27))!=0; // CPUID.1:ECX[27]
  bool HasAVX    =(Regs[2] & (1u<<28))!=0; // CPUID.1:ECX[28]

  if (!HasSSE41 || !HasPclmul)
    return;
  CRCFoldWidth=128;

#ifdef CRCFOLD_HAVE_256
  if (!HasOSXsave || !HasAVX || MaxLeaf<7)
    return;

  // The OS must have enabled XMM (bit 1) and YMM (bit 2) state saving,
  // otherwise AVX registers are not preserved across context switches.
  if ((CRCFoldXcr0() & 6)!=6)
    return;

  CRCFoldCpuid(7,0,Regs);
  bool HasAVX2   =(Regs[1] & (1u<< 5))!=0; // CPUID.7.0:EBX[5]
  bool HasVpclmul=(Regs[2] & (1u<<10))!=0; // CPUID.7.0:ECX[10]

  if (HasAVX2 && HasVpclmul)
    CRCFoldWidth=256;
#endif

  // Diagnostic override: UNRAR_CRC_FOLD=0|128|256 selects a path at run time,
  // so the three can be compared within a single binary instead of building
  // one executable per configuration - which removes build differences, and
  // anti-virus first-run scanning, as sources of measurement error.
  //
  // It can only narrow what detection found, never enable an unsupported
  // path, so it cannot be used to crash on a CPU lacking the instructions.
  const char *Env=getenv("UNRAR_CRC_FOLD");
  if (Env!=NULL && *Env!=0)
  {
    uint Want=(uint)atoi(Env);
    if (Want<128)
      CRCFoldWidth=0;
    else if (Want<256 && CRCFoldWidth>128)
      CRCFoldWidth=128;
  }
}


// Single entry point: picks the widest available path. Keeps the width
// logic here rather than in crc.cpp, so the call site needs no #ifdef.
// 'inline' only to avoid an unused-function warning in crcbench, which
// includes this file but calls the two widths directly to compare them.
static inline uint CRCFoldBlocks(uint StartCRC,const byte *Data,size_t Blocks)
{
#ifdef CRCFOLD_HAVE_256
  if (CRCFoldWidth>=256)
    return CRCFold256(StartCRC,Data,Blocks);
#endif
  return CRCFold128(StartCRC,Data,Blocks);
}
