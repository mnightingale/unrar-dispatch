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

  // Warm up: first pass pulls the buffer into cache.
  Sink^=I.Func(0xffffffff,Buf,Size);

  for (int R=0;R<Runs;R++)
  {
    auto T0=std::chrono::steady_clock::now();
    Sink^=I.Func(0xffffffff,Buf,Size);
    auto T1=std::chrono::steady_clock::now();
    double Sec=std::chrono::duration<double>(T1-T0).count();
    if (Sec<Best) Best=Sec;
  }
  (void)Sink;
  return (double)Size/Best/(1024.0*1024.0);
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
