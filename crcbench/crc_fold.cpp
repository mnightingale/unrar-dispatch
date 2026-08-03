/*
 * PCLMULQDQ / VPCLMULQDQ CRC32 folding. See crc_fold.h for the attribution
 * chain (Intel whitepaper -> zlib-ng -> rapidyenc) and licensing.
 */

#include "crc_fold.h"

#ifdef CRC_FOLD_X86

#include <string.h>
#include <immintrin.h>

#if defined(__GNUC__) || defined(__clang__)
#include <cpuid.h>
#define TARGET_128 __attribute__((target("sse4.1,pclmul")))
#define TARGET_256 __attribute__((target("avx2,vpclmulqdq,pclmul,sse4.1")))
#else
/* MSVC permits intrinsics without per-function target attributes. */
#define TARGET_128
#define TARGET_256
#endif

/* ------------------------------------------------------------------ */
/* Scalar tail                                                         */
/*                                                                     */
/* Self-contained so this module can be benchmarked without linking    */
/* unrar. When integrating into crc.cpp, drop this and use the         */
/* existing crc_tables[0] instead of carrying a second copy.           */
/* ------------------------------------------------------------------ */

static unsigned int fold_tail_table[256];
static int fold_tail_ready;

static void InitTailTable(void)
{
  if (fold_tail_ready)
    return;
  for (unsigned int I=0;I<256;I++)
  {
    unsigned int C=I;
    for (unsigned int J=0;J<8;J++)
      C=(C & 1) ? (C>>1)^0xEDB88320 : (C>>1);
    fold_tail_table[I]=C;
  }
  fold_tail_ready=1;
}

static unsigned int CRC32Scalar(unsigned int CRC,const unsigned char *Data,size_t Size)
{
  for (;Size>0;Size--,Data++)
    CRC=fold_tail_table[(unsigned char)(CRC^*Data)]^(CRC>>8);
  return CRC;
}

/* ------------------------------------------------------------------ */
/* Fold constants                                                      */
/* ------------------------------------------------------------------ */

/*
 * k1 = 0x154442bd4, k2 = 0x1c6e41596 - fold a 512-bit distance, used by both
 * the 128-bit (4 xmm) and 256-bit (2 ymm) main loops, since folding four
 * 128-bit lanes forward by 512 bits is the same operation either way.
 *
 * Laid out so one 128-bit lane is { low64 = k2, high64 = k1 }.
 */
#define FOLD4_E3 0x00000001
#define FOLD4_E2 0x54442bd4
#define FOLD4_E1 0x00000001
#define FOLD4_E0 0xc6e41596

/*
 * Tail reduction constants (512->128->64->32 plus Barrett).
 *   rk1/rk2 : fold by 128 bits
 *   rk5/rk6 : fold 128 -> 64
 *   rk7/rk8 : Barrett reduction (mu and the polynomial)
 */
#if defined(_MSC_VER)
__declspec(align(16)) static const unsigned int crc_k[] =
#else
static const unsigned int crc_k[] __attribute__((aligned(16))) =
#endif
{
  0xccaa009e, 0x00000000, /* rk1 */
  0x751997d0, 0x00000001, /* rk2 */
  0xccaa009e, 0x00000000, /* rk5 */
  0x63cd6124, 0x00000001, /* rk6 */
  0xf7011641, 0x00000000, /* rk7 */
  0xdb710640, 0x00000001  /* rk8 */
};

/*
 * Constant that maps the incoming CRC into the folded domain before the
 * first fold step.
 */
#define CRC_INIT_MUL 0xdfded7ec

/* ------------------------------------------------------------------ */
/* Shared 512 -> 32 bit reduction                                      */
/*                                                                     */
/* Deliberately not inlined into the 256-bit path: a plain call across  */
/* differing target attributes is always legal, whereas inlining across  */
/* them is not, and this runs once per CRC32() call so the call is free. */
/* ------------------------------------------------------------------ */

TARGET_128
static unsigned int FoldReduce(__m128i xmm_crc0,__m128i xmm_crc1,
                               __m128i xmm_crc2,__m128i xmm_crc3)
{
  const __m128i xmm_mask = _mm_set_epi32(-1,-1,-1,0);
  __m128i x_tmp0,x_tmp1,x_tmp2,fold;

  /* 512 -> 128: fold crc0..crc2 down into crc3. */
  fold = _mm_load_si128((const __m128i *)crc_k);

  x_tmp0   = _mm_clmulepi64_si128(xmm_crc0,fold,0x10);
  xmm_crc0 = _mm_clmulepi64_si128(xmm_crc0,fold,0x01);
  xmm_crc1 = _mm_xor_si128(_mm_xor_si128(xmm_crc1,x_tmp0),xmm_crc0);

  x_tmp1   = _mm_clmulepi64_si128(xmm_crc1,fold,0x10);
  xmm_crc1 = _mm_clmulepi64_si128(xmm_crc1,fold,0x01);
  xmm_crc2 = _mm_xor_si128(_mm_xor_si128(xmm_crc2,x_tmp1),xmm_crc1);

  x_tmp2   = _mm_clmulepi64_si128(xmm_crc2,fold,0x10);
  xmm_crc2 = _mm_clmulepi64_si128(xmm_crc2,fold,0x01);
  xmm_crc3 = _mm_xor_si128(_mm_xor_si128(xmm_crc3,x_tmp2),xmm_crc2);

  /* 128 -> 64 */
  fold = _mm_load_si128((const __m128i *)crc_k + 1);

  xmm_crc0 = xmm_crc3;
  xmm_crc3 = _mm_clmulepi64_si128(xmm_crc3,fold,0);
  xmm_crc0 = _mm_srli_si128(xmm_crc0,8);
  xmm_crc3 = _mm_xor_si128(xmm_crc3,xmm_crc0);

  xmm_crc0 = xmm_crc3;
  xmm_crc3 = _mm_slli_si128(xmm_crc3,4);
  xmm_crc3 = _mm_clmulepi64_si128(xmm_crc3,fold,0x10);
  xmm_crc0 = _mm_and_si128(xmm_crc0,xmm_mask);
  xmm_crc3 = _mm_xor_si128(xmm_crc3,xmm_crc0);

  /* Barrett reduction to 32 bits.
   *
   * The reference implementation inverts here (xmm_crc1 ^= xmm_mask) because
   * it follows zlib's convention, where the CRC is complemented on entry and
   * exit. unrar's convention carries the raw running value and leaves the
   * final XOR to the caller, so both inversions are omitted - they cancel. */
  xmm_crc1 = xmm_crc3;
  fold = _mm_load_si128((const __m128i *)crc_k + 2);

  xmm_crc3 = _mm_clmulepi64_si128(xmm_crc3,fold,0);
  xmm_crc3 = _mm_clmulepi64_si128(xmm_crc3,fold,0x10);
  xmm_crc3 = _mm_xor_si128(xmm_crc3,xmm_crc1);

  return (unsigned int)_mm_extract_epi32(xmm_crc3,2);
}

/* ------------------------------------------------------------------ */
/* 128-bit path: SSE4.1 + PCLMULQDQ                                    */
/* ------------------------------------------------------------------ */

TARGET_128
static __m128i Fold128Step(__m128i src,__m128i data)
{
  const __m128i k = _mm_set_epi32(FOLD4_E3,FOLD4_E2,FOLD4_E1,FOLD4_E0);
  return _mm_xor_si128(_mm_xor_si128(data,
           _mm_clmulepi64_si128(src,k,0x01)),
           _mm_clmulepi64_si128(src,k,0x10));
}

TARGET_128
unsigned int CRC32Fold128(unsigned int StartCRC,const void *Addr,size_t Size)
{
  const unsigned char *Data=(const unsigned char *)Addr;

  InitTailTable();

  /* Folding only pays for whole 64-byte blocks; anything shorter is left to
     the scalar tail, which is also what handles the remainder below. */
  if (Size<64)
    return CRC32Scalar(StartCRC,Data,Size);

  __m128i xmm_crc0=_mm_clmulepi64_si128(_mm_cvtsi32_si128((int)StartCRC),
                                        _mm_cvtsi32_si128((int)CRC_INIT_MUL),0);
  __m128i xmm_crc1=_mm_setzero_si128();
  __m128i xmm_crc2=_mm_setzero_si128();
  __m128i xmm_crc3=_mm_setzero_si128();

  while (Size>=64)
  {
    xmm_crc0=Fold128Step(xmm_crc0,_mm_loadu_si128((const __m128i *)(Data   )));
    xmm_crc1=Fold128Step(xmm_crc1,_mm_loadu_si128((const __m128i *)(Data+16)));
    xmm_crc2=Fold128Step(xmm_crc2,_mm_loadu_si128((const __m128i *)(Data+32)));
    xmm_crc3=Fold128Step(xmm_crc3,_mm_loadu_si128((const __m128i *)(Data+48)));
    Data+=64;
    Size-=64;
  }

  unsigned int CRC=FoldReduce(xmm_crc0,xmm_crc1,xmm_crc2,xmm_crc3);

  return CRC32Scalar(CRC,Data,Size);
}

/* ------------------------------------------------------------------ */
/* 256-bit path: AVX2 + VPCLMULQDQ                                     */
/* ------------------------------------------------------------------ */

TARGET_256
static __m256i Fold256Step(__m256i src,__m256i data)
{
  const __m256i k = _mm256_set_epi32(FOLD4_E3,FOLD4_E2,FOLD4_E1,FOLD4_E0,
                                     FOLD4_E3,FOLD4_E2,FOLD4_E1,FOLD4_E0);
  return _mm256_xor_si256(_mm256_xor_si256(data,
           _mm256_clmulepi64_epi128(src,k,0x01)),
           _mm256_clmulepi64_epi128(src,k,0x10));
}

TARGET_256
unsigned int CRC32Fold256(unsigned int StartCRC,const void *Addr,size_t Size)
{
  const unsigned char *Data=(const unsigned char *)Addr;

  InitTailTable();

  if (Size<64)
    return CRC32Scalar(StartCRC,Data,Size);

  /* Same initial state as the 128-bit path, just packed two lanes per
     register: ymm0 = [crc1|crc0], ymm1 = [crc3|crc2]. */
  __m256i crc0=_mm256_castsi128_si256(
                 _mm_clmulepi64_si128(_mm_cvtsi32_si128((int)StartCRC),
                                      _mm_cvtsi32_si128((int)CRC_INIT_MUL),0));
  /* castsi128_si256 leaves the upper lane undefined; zero it explicitly. */
  crc0=_mm256_inserti128_si256(crc0,_mm_setzero_si128(),1);
  __m256i crc1=_mm256_setzero_si256();

  while (Size>=64)
  {
    crc0=Fold256Step(crc0,_mm256_loadu_si256((const __m256i *)(Data   )));
    crc1=Fold256Step(crc1,_mm256_loadu_si256((const __m256i *)(Data+32)));
    Data+=64;
    Size-=64;
  }

  __m128i xmm_crc0=_mm256_castsi256_si128(crc0);
  __m128i xmm_crc1=_mm256_extracti128_si256(crc0,1);
  __m128i xmm_crc2=_mm256_castsi256_si128(crc1);
  __m128i xmm_crc3=_mm256_extracti128_si256(crc1,1);
  _mm256_zeroupper();

  unsigned int CRC=FoldReduce(xmm_crc0,xmm_crc1,xmm_crc2,xmm_crc3);

  return CRC32Scalar(CRC,Data,Size);
}

/* ------------------------------------------------------------------ */
/* Capability detection                                                */
/* ------------------------------------------------------------------ */

int CRC32FoldHave128(void)
{
#if defined(__GNUC__) || defined(__clang__)
  __builtin_cpu_init();
  return __builtin_cpu_supports("sse4.1") && __builtin_cpu_supports("pclmul");
#else
  return 0;
#endif
}

int CRC32FoldHave256(void)
{
#if defined(__GNUC__) || defined(__clang__)
  __builtin_cpu_init();

  /* AVX2 first: it also covers the OSXSAVE/xgetbv check for YMM state. */
  if (!__builtin_cpu_supports("avx2") || !__builtin_cpu_supports("pclmul"))
    return 0;

  /* VPCLMULQDQ is CPUID.(EAX=7,ECX=0):ECX bit 10. Queried directly rather
     than via __builtin_cpu_supports("vpclmulqdq"), which needs GCC 11+. */
  unsigned int eax,ebx,ecx,edx;
  if (__get_cpuid_max(0,NULL)<7)
    return 0;
  __cpuid_count(7,0,eax,ebx,ecx,edx);
  return (ecx & (1u<<10))!=0;
#else
  return 0;
#endif
}

#endif /* CRC_FOLD_X86 */
