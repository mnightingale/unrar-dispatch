// What does the CRC32 thread pool buy, now that CRC32 itself is fast?
//
// THIS FILE IS PART OF A LOCAL MODIFICATION, not part of the original UnRAR
// source distribution from RARLAB. See license.txt.
//
// Drives unrar's own DataHash::Update (hash.cpp) unmodified, so the numbers
// describe the shipping code path rather than a reimplementation of it. On x86
// set UNRAR_CRC_FOLD=0|128|256 to pick the CRC32 implementation underneath
// (crcfold.cpp) without rebuilding, and the same table can be read for a slow
// and a fast CRC.
//
// Two cache models per (size, threads), because the answer differs between
// them and only one of them resembles unrar:
//
//   resident  Update() called repeatedly on one buffer. Each worker's slice
//             stays hot in that worker's own L1/L2. This is the most
//             favourable case the pool can ever see and is NOT how unrar runs;
//             it is here to bound the win from above.
//
//   producer  the buffer is written by this thread (memcpy) before each
//             Update(). That is unrar's real pattern - the reader fills a 4 MB
//             copy buffer, or the decompressor fills the window, on one core
//             and the CRC follows immediately - so the pool has to pull the
//             data out of the producing core's cache. Reported time is
//             (copy+crc) - (copy), isolating the CRC while keeping the cache
//             state honest.
//
// Also measured are the two costs the pool adds regardless of how fast CRC32
// is: the dispatch/join round trip per Update() call, and the Galois combine
// per block. Those are what decide the threshold in UpdateCRC32MT.

#include "rar.hpp"
#include <cstdio>
#include <vector>

static const size_t BenchSizes[]={16u<<10,32u<<10,64u<<10,256u<<10,1u<<20,
                                  4u<<20,16u<<20,64u<<20};
static const uint BenchThreads[]={1,2,4,8};


static double Now()
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC,&ts);
  return ts.tv_sec+ts.tv_nsec/1e9;
}


// Whole-process user+sys. Divided by elapsed time it gives the number of cores
// kept busy, which is the cost side of every row in these tables.
static double CpuNow()
{
  struct rusage ru;
  getrusage(RUSAGE_SELF,&ru);
  return ru.ru_utime.tv_sec+ru.ru_utime.tv_usec/1e6+
         ru.ru_stime.tv_sec+ru.ru_stime.tv_usec/1e6;
}


// Copies of hash.cpp's combine arithmetic. Duplicated rather than exposed,
// because the originals are private and timing them in isolation is the only
// thing this benchmark needs them for.
static uint bBitReverse32(uint N)
{
  uint R=0;
  for (uint I=0;I<32;I++,N>>=1)
    R|=(N & 1)<<(31-I);
  return R;
}


static uint bGfMulCRC(uint A,uint B)
{
  const uint POLY=uint(0x104c11db7);
  uint R=0;
  while (A!=0 && B!=0)
  {
    R^=(B & 1)!=0 ? A : 0;
    A=(A<<1)^((A & 0x80000000)!=0 ? POLY : 0);
    B>>=1;
  }
  return R;
}


static uint bGfExpCRC(uint N)
{
  uint S=2,R=1;
  while (N>1)
  {
    if ((N & 1)!=0)
      R=bGfMulCRC(R,S);
    S=bGfMulCRC(S,S);
    N>>=1;
  }
  return bGfMulCRC(R,S);
}


THREAD_PROC(NopThread)
{
  (void)Data;
}


struct Result
{
  double GbS;   // CRC throughput
  double Cores; // cpu time / elapsed time over the measured region
};


// Repeated Update() on one buffer.
static Result Resident(byte *Buf,size_t Size,uint Threads,double MinSec)
{
  DataHash Hash;
  Hash.Init(HASH_CRC32,Threads);
  Hash.Update(Buf,Size); // Creates the pool and spawns threads, untimed.

  uint64 Done=0;
  double Start=Now(),CpuStart=CpuNow(),Elapsed;
  do
  {
    for (uint I=0;I<8;I++,Done+=Size)
      Hash.Update(Buf,Size);
    Elapsed=Now()-Start;
  } while (Elapsed<MinSec);
  double Cpu=CpuNow()-CpuStart;

  // No keep-alive trick is needed: Update() lives in another translation
  // unit and mutates the object, so it cannot be optimized away.
  Result Res;
  Res.GbS=Done/Elapsed/1e9;
  Res.Cores=Cpu/Elapsed;
  return Res;
}


// Buffer written by this thread, then CRC'd. Runs the copy alone and the copy
// plus CRC, and reports the difference, normalized per byte so the two passes
// need not have completed the same number of iterations.
static Result Producer(byte *Dst,const byte *Src,size_t Size,uint Threads,
                       double MinSec)
{
  DataHash Hash;
  Hash.Init(HASH_CRC32,Threads);
  Hash.Update(Dst,Size); // Pool creation outside the timed region.

  double SecPerByte[2],CpuPerByte[2];
  for (uint Pass=0;Pass<2;Pass++)
  {
    bool WithCRC=Pass==1;
    uint64 Done=0;
    double Start=Now(),CpuStart=CpuNow(),Elapsed;
    do
    {
      for (uint I=0;I<8;I++,Done+=Size)
      {
        memcpy(Dst,Src,Size);
        if (WithCRC)
          Hash.Update(Dst,Size);
      }
      Elapsed=Now()-Start;
    } while (Elapsed<MinSec);
    SecPerByte[Pass]=Elapsed/Done;
    CpuPerByte[Pass]=(CpuNow()-CpuStart)/Done;
  }

  Result Res;
  double PerByte=SecPerByte[1]-SecPerByte[0];
  Res.GbS=PerByte>0 ? 1/PerByte/1e9 : 0;
  Res.Cores=PerByte>0 ? (CpuPerByte[1]-CpuPerByte[0])/PerByte : 0;
  return Res;
}


static void FixedCosts(double MinSec)
{
  printf("\n=== fixed costs the pool adds, whatever the CRC32 rate ===\n");

  for (uint Threads=2;Threads<=8;Threads*=2)
  {
    ThreadPool Pool(8);
    for (uint I=0;I<Threads;I++) // Spawn the threads before timing.
      Pool.AddTask(NopThread,nullptr);
    Pool.WaitDone();

    uint64 Calls=0;
    double Start=Now(),Elapsed;
    do
    {
      for (uint I=0;I<200;I++,Calls++)
      {
        for (uint J=0;J<Threads;J++)
          Pool.AddTask(NopThread,nullptr);
        Pool.WaitDone();
      }
      Elapsed=Now()-Start;
    } while (Elapsed<MinSec);
    printf("  dispatch+join of %u empty tasks : %7.2f us per Update() call\n",
            Threads,Elapsed/Calls*1e6);
  }

  uint Sink=0;
  uint64 Iter=0;
  double Start=Now(),Elapsed;
  do
  {
    for (uint I=0;I<2000;I++,Iter++)
      // Exactly the per-block combine in UpdateCRC32MT for an equal-sized
      // block: one gfMulCRC on the bit-reversed running CRC, plus both
      // reversals. gfExpCRC is hoisted out of the loop there, as it is here.
      Sink^=bBitReverse32(bGfMulCRC(bBitReverse32(Sink+I),0x1234abcd));
    Elapsed=Now()-Start;
  } while (Elapsed<MinSec);
  printf("  galois combine per block       : %7.3f us (x blocks per call)\n",
          Elapsed/Iter*1e6);

  Iter=0;
  Start=Now();
  do
  {
    for (uint I=0;I<2000;I++,Iter++)
      Sink^=bGfExpCRC(8*0x4000u+I);
    Elapsed=Now()-Start;
  } while (Elapsed<MinSec);
  printf("  gfExpCRC, once per call        : %7.3f us\n",Elapsed/Iter*1e6);
  if (Sink==0xffffffff)
    printf(" "); // Keep the arithmetic live.
}


static void Throughput(byte *Dst,const byte *Src,bool ProducerModel,
                       double MinSec)
{
  printf("\n=== %s ===\n",ProducerModel ?
    "producer: buffer written by this thread first (unrar's real pattern)" :
    "resident: repeated Update() on one buffer (upper bound, unrealistic)");
  printf("%8s  %-27s %9s  %11s\n","size","GB/s at 1 / 2 / 4 / 8 thr",
         "best/1thr","cores at 8");

  for (uint S=0;S<ASIZE(BenchSizes);S++)
  {
    double GbS[ASIZE(BenchThreads)],Cores[ASIZE(BenchThreads)];
    for (uint I=0;I<ASIZE(BenchThreads);I++)
    {
      Result R=ProducerModel ?
        Producer(Dst,Src,BenchSizes[S],BenchThreads[I],MinSec) :
        Resident(Dst,BenchSizes[S],BenchThreads[I],MinSec);
      GbS[I]=R.GbS;
      Cores[I]=R.Cores;
    }
    double Best=0;
    for (uint I=0;I<ASIZE(BenchThreads);I++)
      if (GbS[I]>Best)
        Best=GbS[I];

    printf("%7lluK  ",(unsigned long long)(BenchSizes[S]>>10));
    for (uint I=0;I<ASIZE(BenchThreads);I++)
      printf("%6.2f ",GbS[I]);
    printf("  %8.2fx  %11.2f\n",GbS[0]>0 ? Best/GbS[0] : 0,
           Cores[ASIZE(BenchThreads)-1]);
  }
}


int main(int argc,char *argv[])
{
  double MinSec=argc>1 ? atof(argv[1]) : 0.25;

  const char *Fold=getenv("UNRAR_CRC_FOLD");
  printf("CRC32 path: UNRAR_CRC_FOLD=%s"
         "  (x86 only; unset means the widest available)\n",
         Fold==nullptr ? "unset" : Fold);
  printf("%.2f s minimum per measurement\n",MinSec);

  const size_t MaxSize=BenchSizes[ASIZE(BenchSizes)-1];
  std::vector<byte> Src(MaxSize),Dst(MaxSize);
  for (size_t I=0;I<MaxSize;I++)
    Src[I]=(byte)(I*2654435761u >> 13);
  memcpy(Dst.data(),Src.data(),MaxSize);

  FixedCosts(MinSec);
  Throughput(Dst.data(),Src.data(),false,MinSec);
  Throughput(Dst.data(),Src.data(),true,MinSec);
  return 0;
}
