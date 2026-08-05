/*
 * Benchmark and correctness harness comparing unrar's current CRC32
 * (slicing-by-16, crc.cpp) against PCLMULQDQ folding at 128 and 256 bits.
 *
 * Self-contained: does not link unrar. Build with crcbench/makefile.
 *
 * Correctness is checked before any timing is reported. A faster CRC that
 * disagrees with the table implementation is worthless, so a failure here
 * aborts rather than printing numbers.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <chrono>
#include <vector>
#include <algorithm>

/* ------------------------------------------------------------------ */
/* Reference: unrar's slicing-by-16, copied verbatim from crc.cpp so    */
/* the comparison is against exactly what ships today.                  */
/*                                                                      */
/* Original Intel Slicing-by-8 code is licensed under the BSD License;   */
/* see the header of crc.cpp.                                           */
/* ------------------------------------------------------------------ */

typedef unsigned int uint;
typedef unsigned char byte;

/*
 * The folding implementation is included from the production file rather than
 * copied, so the benchmark cannot drift from what actually ships in crc.cpp.
 * crcfold.cpp provides whole-64-byte-block functions with no scalar tail;
 * the wrappers below add the same tail crc.cpp uses.
 */
#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
#define CRC_FOLD_X86
#include "../crcfold.cpp"
#endif

static uint crc_tables[16][256];

static void InitTables()
{
  for (uint I=0;I<256;I++)
  {
    uint C=I;
    for (uint J=0;J<8;J++)
      C=(C & 1) ? (C>>1)^0xEDB88320 : (C>>1);
    crc_tables[0][I]=C;
  }
  for (uint I=0;I<256;I++)
  {
    uint C=crc_tables[0][I];
    for (uint J=1;J<16;J++)
    {
      C=crc_tables[0][(byte)C]^(C>>8);
      crc_tables[J][I]=C;
    }
  }
}

static uint CRC32Slice16(uint StartCRC,const void *Addr,size_t Size)
{
  byte *Data=(byte *)Addr;

  for (;Size>0 && ((size_t)Data & 15)!=0;Size--,Data++)
    StartCRC=crc_tables[0][(byte)(StartCRC^Data[0])]^(StartCRC>>8);

  for (;Size>=16;Size-=16,Data+=16)
  {
    StartCRC ^= *(uint32_t *) Data;
    uint D1 = *(uint32_t *) (Data+4);
    uint D2 = *(uint32_t *) (Data+8);
    uint D3 = *(uint32_t *) (Data+12);
    StartCRC = crc_tables[15][(byte) StartCRC       ] ^
               crc_tables[14][(byte)(StartCRC >> 8) ] ^
               crc_tables[13][(byte)(StartCRC >> 16)] ^
               crc_tables[12][(byte)(StartCRC >> 24)] ^
               crc_tables[11][(byte) D1             ] ^
               crc_tables[10][(byte)(D1       >> 8) ] ^
               crc_tables[ 9][(byte)(D1       >> 16)] ^
               crc_tables[ 8][(byte)(D1       >> 24)] ^
               crc_tables[ 7][(byte) D2             ] ^
               crc_tables[ 6][(byte)(D2       >>  8)] ^
               crc_tables[ 5][(byte)(D2       >> 16)] ^
               crc_tables[ 4][(byte)(D2       >> 24)] ^
               crc_tables[ 3][(byte) D3             ] ^
               crc_tables[ 2][(byte)(D3       >>  8)] ^
               crc_tables[ 1][(byte)(D3       >> 16)] ^
               crc_tables[ 0][(byte)(D3       >> 24)];
  }

  for (;Size>0;Size--,Data++)
    StartCRC=crc_tables[0][(byte)(StartCRC^Data[0])]^(StartCRC>>8);

  return StartCRC;
}



/* ------------------------------------------------------------------ */
/* ARM hardware CRC32, and whether this build can even reach it.         */
/*                                                                      */
/* unrar gates USE_NEON_CRC32 on __ARM_FEATURE_CRC32 (os.hpp:172), which */
/* is a COMPILE-time macro. The runtime HWCAP check in InitCRC32 only    */
/* runs if the path was compiled in, so a build without the right        */
/* -march leaves the instruction unreachable on hardware that has it.    */
/* aarch64's baseline is armv8-a, where CRC32 is optional, so a plain    */
/* `make` on many ARM systems silently ships the table.                  */
/*                                                                      */
/* This file therefore probes the CPU at run time regardless of how it   */
/* was compiled, so it can report that mismatch rather than hide it.     */
/* ------------------------------------------------------------------ */

#if defined(__aarch64__) || defined(__arm64__)
#define CRC_ARM64

#if defined(__APPLE__)
#include <sys/sysctl.h>
#elif defined(__linux__)
#include <sys/auxv.h>
#include <asm/hwcap.h>
#endif

/* Does the CPU have the instruction, whatever this build was told? */
static bool ArmHasCRC32()
{
#if defined(__APPLE__)
  unsigned Value=0;
  size_t Size=sizeof(Value);
  return sysctlbyname("hw.optional.armv8_crc32",&Value,&Size,NULL,0)==0 && Value!=0;
#elif defined(__linux__) && defined(HWCAP_CRC32)
  return (getauxval(AT_HWCAP) & HWCAP_CRC32)!=0;
#else
  return false;
#endif
}

#ifdef __ARM_FEATURE_CRC32
#define CRC_NEON_BUILT
#include <arm_neon.h>

/* Same loop as crc.cpp:100, which is why it is measured rather than assumed
   to be faster: on a narrow core the table is not always far behind. */
static uint CRC32Neon(uint StartCRC,const void *Addr,size_t Size)
{
  const byte *Data=(const byte *)Addr;
  for (;Size>=8;Size-=8,Data+=8)
  {
    uint64_t V;
    memcpy(&V,Data,8); /* compiles to one load; avoids a misaligned cast */
#ifdef __clang__
    StartCRC=__builtin_arm_crc32d(StartCRC,V);
#else
    StartCRC=__builtin_aarch64_crc32x(StartCRC,V);
#endif
  }
  for (;Size>0;Size--,Data++)
#ifdef __clang__
    StartCRC=__builtin_arm_crc32b(StartCRC,*Data);
#else
    StartCRC=__builtin_aarch64_crc32b(StartCRC,*Data);
#endif
  return StartCRC;
}
#endif /* __ARM_FEATURE_CRC32 */
#endif /* CRC_ARM64 */

/* ------------------------------------------------------------------ */
/* Braided slicing-by-16: the maintainer's suggestion, implemented.      */
/*                                                                      */
/* The loop above carries a serial dependency - StartCRC for iteration   */
/* N+1 cannot begin until iteration N produces it - so the chain is      */
/* roughly extract-byte, L1 load, XOR tree, about 9 cycles per 16 bytes  */
/* against a measured ~17. There is idle machine underneath.             */
/*                                                                      */
/* Braiding splits the buffer into K blocks and runs K independent       */
/* chains INTERLEAVED IN ONE LOOP BODY, so the out-of-order engine has   */
/* K independent chains in flight and one chain's latency overlaps the   */
/* others' work. Interleaving is the whole point: splitting the data and */
/* processing the blocks one after another gains nothing, because the    */
/* reorder window is a few hundred instructions and a block is thousands */
/* of iterations. (zlib ships a braided CRC in its own crc32.c.)         */
/*                                                                      */
/* The partial CRCs are combined with the same Galois shift-and-multiply */
/* UpdateCRC32MT uses for its threads, copied from hash.cpp - so this is */
/* precisely that function with the thread pool removed and the inner    */
/* loops interleaved instead.                                           */
/* ------------------------------------------------------------------ */

static uint BraidBitReverse32(uint N)
{
  uint R=0;
  for (uint I=0;I<32;I++,N>>=1)
    R|=(N & 1)<<(31-I);
  return R;
}

static uint BraidGfMul(uint A,uint B)
{
  const uint POLY=(uint)0x104c11db7;
  uint R=0;
  while (A!=0 && B!=0)
  {
    R^=(B & 1)!=0 ? A : 0;
    A=(A<<1)^((A & 0x80000000)!=0 ? POLY : 0);
    B>>=1;
  }
  return R;
}

static uint BraidGfExp(uint N)
{
  uint S=2,R=1;
  while (N>1)
  {
    if ((N & 1)!=0)
      R=BraidGfMul(R,S);
    S=BraidGfMul(S,S);
    N>>=1;
  }
  return BraidGfMul(R,S);
}

/* One 16-byte slicing-by-16 step, identical to the body of the loop in
   CRC32Slice16. Factored out only so K copies can be interleaved. */
static inline uint Slice16Step(uint C,const byte *Data)
{
  C ^= *(const uint32_t *) Data;
  uint D1 = *(const uint32_t *) (Data+4);
  uint D2 = *(const uint32_t *) (Data+8);
  uint D3 = *(const uint32_t *) (Data+12);
  return crc_tables[15][(byte) C            ] ^
         crc_tables[14][(byte)(C  >> 8)     ] ^
         crc_tables[13][(byte)(C  >> 16)    ] ^
         crc_tables[12][(byte)(C  >> 24)    ] ^
         crc_tables[11][(byte) D1           ] ^
         crc_tables[10][(byte)(D1 >> 8)     ] ^
         crc_tables[ 9][(byte)(D1 >> 16)    ] ^
         crc_tables[ 8][(byte)(D1 >> 24)    ] ^
         crc_tables[ 7][(byte) D2           ] ^
         crc_tables[ 6][(byte)(D2 >>  8)    ] ^
         crc_tables[ 5][(byte)(D2 >> 16)    ] ^
         crc_tables[ 4][(byte)(D2 >> 24)    ] ^
         crc_tables[ 3][(byte) D3           ] ^
         crc_tables[ 2][(byte)(D3 >>  8)    ] ^
         crc_tables[ 1][(byte)(D3 >> 16)    ] ^
         crc_tables[ 0][(byte)(D3 >> 24)    ];
}

template<unsigned K>
static uint CRC32Braid(uint StartCRC,const void *Addr,size_t Size)
{
  const byte *Data=(const byte *)Addr;

  /* Same leading alignment as CRC32Slice16, which also makes every chain
     start 16-aligned since the block size below is a multiple of 16. */
  for (;Size>0 && ((size_t)Data & 15)!=0;Size--,Data++)
    StartCRC=crc_tables[0][(byte)(StartCRC^Data[0])]^(StartCRC>>8);

  /* Below this the combine costs more than the chains save, and the
     correctness sweep exercises every length so the fallback matters. */
  const size_t MinPerChain=256;
  if (Size<K*MinPerChain)
    return CRC32Slice16(StartCRC,Data,Size);

  size_t Block=(Size/K) & ~(size_t)15; /* whole 16-byte steps per chain */
  size_t Steps=Block/16;

  uint C[K];
  const byte *P[K];
  for (unsigned I=0;I<K;I++)
  {
    C[I]=0;              /* zero init, so the combine below is a plain XOR */
    P[I]=Data+I*Block;
  }

  for (size_t S=0;S<Steps;S++)
    for (unsigned I=0;I<K;I++) /* K is a constant, so this unrolls */
    {
      C[I]=Slice16Step(C[I],P[I]);
      P[I]+=16;
    }

  /* Shift the running total left by one block width and XOR in each block's
     CRC, in order. One multiplier serves all blocks since they are equal.
     8*Block overflows uint above a 512 MB block, far beyond any Update().

     Cached across calls, because a real implementation would use a fixed block
     size and hash.cpp already reuses its own StdShift the same way. Without
     this, gfExpCRC's ~0.5 us lands on every call and buries the result at 4 KB,
     which would be an artifact of the harness rather than of braiding. */
  static size_t CachedBlock=0;
  static uint CachedShift=0;
  if (Block!=CachedBlock)
  {
    CachedBlock=Block;
    CachedShift=BraidGfExp((uint)(8*Block));
  }
  uint Shift=CachedShift;
  uint Total=StartCRC;
  for (unsigned I=0;I<K;I++)
  {
    Total=BraidBitReverse32(BraidGfMul(BraidBitReverse32(Total),Shift));
    Total^=C[I];
  }

  /* Whatever the split could not cover follows the last block. */
  return CRC32Slice16(Total,Data+K*Block,Size-K*Block);
}

/* ------------------------------------------------------------------ */
/* Wrappers pairing the block-only fold functions with the same scalar   */
/* tail crc.cpp applies, so timings reflect a complete CRC32() call.     */
/* ------------------------------------------------------------------ */

#ifdef CRC_FOLD_X86
static uint Bench128(uint CRC,const void *Addr,size_t Size)
{
  const byte *Data=(const byte *)Addr;
  size_t Blocks=Size/64;
  if (Blocks>0)
  {
    CRC=CRCFold128(CRC,Data,Blocks);
    Data+=Blocks*64;
    Size-=Blocks*64;
  }
  return CRC32Slice16(CRC,Data,Size);
}

static uint Bench256(uint CRC,const void *Addr,size_t Size)
{
  const byte *Data=(const byte *)Addr;
  size_t Blocks=Size/64;
  if (Blocks>0)
  {
    CRC=CRCFold256(CRC,Data,Blocks);
    Data+=Blocks*64;
    Size-=Blocks*64;
  }
  return CRC32Slice16(CRC,Data,Size);
}
#endif

/* ------------------------------------------------------------------ */

typedef uint (*CRCFunc)(uint,const void *,size_t);

struct Impl
{
  const char *Name;
  CRCFunc Func;
  bool Available;
  const char *Requires;
};

static std::vector<Impl> BuildImpls()
{
  std::vector<Impl> V;
  V.push_back({"slicing-by-16", CRC32Slice16, true, "baseline (current unrar)"});
  /* Same tables, same arithmetic, only the dependency chain is broken - so
     these isolate what instruction-level parallelism alone is worth. */
  V.push_back({"braid-2", CRC32Braid<2>, true, "no new instructions"});
  V.push_back({"braid-3", CRC32Braid<3>, true, "no new instructions"});
  V.push_back({"braid-4", CRC32Braid<4>, true, "no new instructions"});
#ifdef CRC_NEON_BUILT
  V.push_back({"neon-crc32", CRC32Neon, true, "ARMv8 CRC32, what unrar uses"});
#endif
#ifdef CRC_FOLD_X86
  CRCFoldDetect();
  V.push_back({"fold-128", Bench128, CRCFoldWidth>=128, "SSE4.1 + PCLMULQDQ"});
  V.push_back({"fold-256", Bench256, CRCFoldWidth>=256, "AVX2 + VPCLMULQDQ"});
#endif
  return V;
}

/* ------------------------------------------------------------------ */
/* Correctness                                                          */
/* ------------------------------------------------------------------ */

static int Failures=0;

/*
 * Cross-check the hand-rolled CPUID bit tests in crcfold.cpp against the
 * compiler's own feature detection.
 *
 * This matters for MSVC: that build uses the same shared detection logic with
 * only the CPUID/XGETBV intrinsic spelled differently, and MSVC has no
 * __builtin_cpu_supports to fall back on. Validating the bit numbers here
 * means the only thing untested on Windows is the intrinsic name.
 */
#if defined(CRC_FOLD_X86) && (defined(__GNUC__) || defined(__clang__))
static void CheckDetection()
{
  __builtin_cpu_init();

  bool WantPclmul=__builtin_cpu_supports("pclmul")!=0;
  bool WantSSE41 =__builtin_cpu_supports("sse4.1")!=0;
  bool WantAVX2  =__builtin_cpu_supports("avx2")!=0;

  bool Got128=(CRCFoldWidth>=128);
  bool Want128=WantSSE41 && WantPclmul;
  if (Got128!=Want128)
  {
    printf("  FAIL  cpuid 128-bit detect: got %d, __builtin_cpu_supports says %d\n",
           (int)Got128,(int)Want128);
    Failures++;
  }

  /* 256-bit needs AVX2 too; if the compiler says no AVX2 we must not have
     selected it. The converse is not implied - VPCLMULQDQ is separate. */
  if (CRCFoldWidth>=256 && !WantAVX2)
  {
    printf("  FAIL  cpuid 256-bit detect: selected AVX2 path but CPU lacks AVX2\n");
    Failures++;
  }

  if (Failures==0)
    printf("  PASS  cpuid detection agrees with __builtin_cpu_supports (width=%u)\n",
           CRCFoldWidth);
}
#endif

static void Fail(const char *Impl,const char *What,uint Got,uint Want)
{
  printf("  FAIL  %-14s %s: got %08x want %08x\n",Impl,What,Got,Want);
  Failures++;
}

/*
 * Known-answer tests, taken from the disabled TestCRC() block in crc.cpp so
 * the reference itself is validated rather than merely self-consistent.
 */
static void KnownAnswerTests(const Impl &I)
{
  uint r;
  char what[64];

  r=I.Func(0xffffffff,(const byte*)"testtesttest",12)^0xffffffff;
  if (r!=0x44608e84) Fail(I.Name,"KAT 'testtesttest'",r,0x44608e84);

  r=I.Func(0,(const byte*)"te\x80st",5);
  if (r!=0xB2E5C5AE) Fail(I.Name,"KAT 'te\\x80st'",r,0xB2E5C5AE);

  byte b[300];
  for (uint J=0;J<14;J++) b[J]=(byte)(0x7f+J);
  r=I.Func(0xffffffff,b,14)^0xffffffff;
  if (r!=0x1DFA75DA) Fail(I.Name,"KAT sign-extension",r,0x1DFA75DA);

  for (uint J=0;J<300;J++) b[J]=(byte)J;
  uint r32=I.Func(0xffffffff,b,300);
  for (uint J=300;J<1024;J++)
  {
    b[0]=(byte)J;
    r32=I.Func(r32,b,1);
  }
  if ((r32^0xffffffff)!=0xB70B4C26) Fail(I.Name,"KAT incremental",r32^0xffffffff,0xB70B4C26);

  (void)what;
}

/*
 * Every length from 0 to 600 at four different buffer offsets. Length sweeps
 * catch mistakes in the <64 fallback and in the scalar remainder after the
 * fold loop; offset sweeps catch any accidental alignment assumption, since
 * the fold path uses unaligned loads.
 */
static void LengthAndOffsetSweep(const Impl &I,const byte *Buf)
{
  for (size_t Off=0;Off<4;Off++)
    for (size_t Len=0;Len<=600;Len++)
    {
      uint Want=CRC32Slice16(0xffffffff,Buf+Off,Len);
      uint Got =I.Func(0xffffffff,Buf+Off,Len);
      if (Got!=Want)
      {
        char what[80];
        snprintf(what,sizeof(what),"len=%zu off=%zu",Len,Off);
        Fail(I.Name,what,Got,Want);
        return; // one report per implementation is enough
      }
    }
}

/*
 * Split a buffer at every boundary and feed it as two calls. unrar calls
 * CRC32 incrementally per output block (rdwrfn.cpp:189), so chained calls
 * must agree with a single call over the whole range.
 */
static void IncrementalSweep(const Impl &I,const byte *Buf,size_t Size)
{
  uint Want=CRC32Slice16(0xffffffff,Buf,Size);
  for (size_t Split=0;Split<=Size;Split+=(Size/97)+1)
  {
    uint Got=I.Func(0xffffffff,Buf,Split);
    Got=I.Func(Got,Buf+Split,Size-Split);
    if (Got!=Want)
    {
      char what[80];
      snprintf(what,sizeof(what),"split at %zu of %zu",Split,Size);
      Fail(I.Name,what,Got,Want);
      return;
    }
  }
}

/* ------------------------------------------------------------------ */
/* Timing                                                               */
/* ------------------------------------------------------------------ */

static double ThroughputMBs(const Impl &I,const byte *Buf,size_t Size,int Runs)
{
  volatile uint Sink=0;
  double Best=1e30;

  /*
   * Repeat small buffers inside the timed region. A single 4KB pass at
   * ~39 GB/s takes ~100ns, which is exactly one tick of the Windows
   * steady_clock - the measurement quantises and every implementation
   * reports the same fabricated number. Aim for at least 64MB of work per
   * timed region so elapsed time is far above clock resolution.
   */
  const size_t TargetBytes=64u<<20;
  size_t Reps=TargetBytes/Size;
  if (Reps<1) Reps=1;

  // Warm up: first pass pulls the buffer into cache.
  Sink^=I.Func(0xffffffff,Buf,Size);

  for (int R=0;R<Runs;R++)
  {
    auto T0=std::chrono::steady_clock::now();
    for (size_t K=0;K<Reps;K++)
      Sink^=I.Func(0xffffffff,Buf,Size);
    auto T1=std::chrono::steady_clock::now();
    double Sec=std::chrono::duration<double>(T1-T0).count();
    if (Sec<Best) Best=Sec;
  }
  (void)Sink;
  return (double)Size*(double)Reps/Best/(1024.0*1024.0);
}

int main(int argc,char *argv[])
{
  int Runs=15;
  bool CheckOnly=false;

  /* "check" skips timing entirely. Useful under an emulator, where the
     correctness sweep is worth running but throughput numbers are noise. */
  if (argc>1 && strcmp(argv[1],"check")==0)
    CheckOnly=true;
  else if (argc>1)
    Runs=atoi(argv[1]);
  if (Runs<1) Runs=1;

  InitTables();

  std::vector<Impl> Impls=BuildImpls();

  printf("=== implementations ===\n");
  for (size_t K=0;K<Impls.size();K++)
    printf("  %-14s %-28s %s\n",Impls[K].Name,Impls[K].Requires,
           Impls[K].Available ? "available" : "NOT SUPPORTED ON THIS CPU");
#ifdef CRC_ARM64
  /* The important case is a CPU that has the instruction while the build
     cannot reach it, which is silent in unrar and is the default on aarch64
     since armv8-a leaves CRC32 optional. */
#ifndef CRC_NEON_BUILT
  if (ArmHasCRC32())
    printf("  %-14s %-28s %s\n","neon-crc32","ARMv8 CRC32, what unrar uses",
           "CPU HAS IT, NOT COMPILED IN: add -march=armv8-a+crc");
  else
    printf("  %-14s %-28s %s\n","neon-crc32","ARMv8 CRC32, what unrar uses",
           "not compiled in, and this CPU lacks it");
#else
  if (!ArmHasCRC32())
    printf("  WARNING: compiled with __ARM_FEATURE_CRC32 but the CPU reports"
           " no CRC32; neon-crc32 may fault\n");
#endif
#endif
  printf("\n");

  // Deterministic test data.
  const size_t TestSize=1<<16;
  std::vector<byte> Test(TestSize+16);
  uint32_t S=12345;
  for (size_t K=0;K<Test.size();K++)
  {
    S=S*1103515245u+12345u;
    Test[K]=(byte)(S>>16);
  }

  printf("=== correctness ===\n");
#if defined(CRC_FOLD_X86) && (defined(__GNUC__) || defined(__clang__))
  CheckDetection();
#endif
  for (size_t K=0;K<Impls.size();K++)
  {
    if (!Impls[K].Available)
    {
      printf("  SKIP  %-14s (CPU lacks %s)\n",Impls[K].Name,Impls[K].Requires);
      continue;
    }
    int Before=Failures;
    KnownAnswerTests(Impls[K]);
    LengthAndOffsetSweep(Impls[K],Test.data());
    IncrementalSweep(Impls[K],Test.data(),TestSize);
    if (Failures==Before)
      printf("  PASS  %-14s known answers, lengths 0-600 x 4 offsets, incremental splits\n",
             Impls[K].Name);
  }
  printf("\n");

  if (Failures>0)
  {
    printf("%d correctness failure(s) - not reporting timings.\n",Failures);
    return 1;
  }

  if (CheckOnly)
  {
    printf("correctness only (timing skipped).\n");
    return 0;
  }

  // Sizes chosen around how unrar actually calls CRC32: per output block via
  // UnpWriteData, up to UNPACK_MAX_WRITE = 4MB (unpack.hpp:28), but often far
  // smaller. L1/L2/L3-resident and memory-resident cases behave differently.
  const size_t Sizes[]={4096, 64*1024, 1024*1024, 4*1024*1024, 64*1024*1024};
  const int NSizes=(int)(sizeof(Sizes)/sizeof(Sizes[0]));

  size_t MaxSize=Sizes[NSizes-1];
  std::vector<byte> Big(MaxSize);
  for (size_t K=0;K<Big.size();K++)
  {
    S=S*1103515245u+12345u;
    Big[K]=(byte)(S>>16);
  }

  printf("=== throughput (MB/s, min-of-%d) ===\n",Runs);
  printf("%12s","buffer");
  for (size_t K=0;K<Impls.size();K++)
    if (Impls[K].Available)
      printf("%16s",Impls[K].Name);
  printf("%12s\n","speedup");

  for (int Si=0;Si<NSizes;Si++)
  {
    char Label[32];
    if (Sizes[Si]>=1024*1024)
      snprintf(Label,sizeof(Label),"%zuMB",Sizes[Si]/(1024*1024));
    else
      snprintf(Label,sizeof(Label),"%zuKB",Sizes[Si]/1024);
    printf("%12s",Label);

    double BaseRate=0,BestRate=0;
    for (size_t K=0;K<Impls.size();K++)
    {
      if (!Impls[K].Available)
        continue;
      double Rate=ThroughputMBs(Impls[K],Big.data(),Sizes[Si],Runs);
      printf("%16.0f",Rate);
      if (K==0) BaseRate=Rate;
      if (Rate>BestRate) BestRate=Rate;
    }
    if (BaseRate>0)
      printf("%11.2fx\n",BestRate/BaseRate);
    else
      printf("%12s\n","-");
  }

  printf("\nspeedup = best available implementation vs slicing-by-16\n");
  return 0;
}
