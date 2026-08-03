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

#if defined(__GNUC__) || defined(__clang__)
  #include <cpuid.h>
  #define CRCFOLD_TARGET_128 __attribute__((target("sse4.1,pclmul")))
  #define CRCFOLD_TARGET_256 __attribute__((target("avx2,vpclmulqdq,pclmul,sse4.1")))
#else
  // MSVC permits these intrinsics without per-function target attributes.
  #define CRCFOLD_TARGET_128
  #define CRCFOLD_TARGET_256
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


// Detected once from InitCRC32. 0 = none, 128 = SSE4.1+PCLMULQDQ,
// 256 = AVX2+VPCLMULQDQ.
static uint CRCFoldWidth;

static void CRCFoldDetect()
{
#if defined(__GNUC__) || defined(__clang__)
  __builtin_cpu_init();

  if (!__builtin_cpu_supports("sse4.1") || !__builtin_cpu_supports("pclmul"))
  {
    CRCFoldWidth=0;
    return;
  }
  CRCFoldWidth=128;

  // AVX2 first: it also covers the OSXSAVE/xgetbv check for YMM state.
  // VPCLMULQDQ is CPUID.(EAX=7,ECX=0):ECX bit 10, queried directly because
  // __builtin_cpu_supports("vpclmulqdq") needs GCC 11+.
  if (__builtin_cpu_supports("avx2") && __get_cpuid_max(0,NULL)>=7)
  {
    uint EAX,EBX,ECX,EDX;
    __cpuid_count(7,0,EAX,EBX,ECX,EDX);
    if ((ECX & (1u<<10))!=0)
      CRCFoldWidth=256;
  }
#else
  CRCFoldWidth=0;
#endif
}
