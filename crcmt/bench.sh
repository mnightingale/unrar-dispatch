#!/bin/sh
#
# End-to-end: what does the CRC32 thread pool buy, per archive, at a given
# CRC32 speed?
#
# Microbenchmark throughput is not user-visible speedup, and neither is the
# CRC's share of a run something you can infer from it - so each archive is
# timed three ways with everything else held fixed:
#
#   no CRC     UNRAR_CRC_SKIP=1, the rest of the run with the CRC removed.
#              Wrong checksums by design; it is a floor, not a mode.
#   CRC 1thr   UNRAR_CRC_MT=1. Unpack stays multithreaded, only the CRC comes
#              off the pool. This is "what if the pool were not used here".
#   CRC pool   unmodified.
#
# The difference between the first two is what the CRC costs single-threaded;
# between the first and third, what it costs pooled. Those two numbers are the
# whole argument, and both are archive-dependent.
#
# On x86, -f sweeps UNRAR_CRC_FOLD so the same table can be read at each CRC32
# speed. That matters because the pool was tuned for a ~4 GB/s table CRC and
# folding is 5-15x that.
#
# Requires a -DCRCMT_DIAG build; this script makes one. Usage:
#
#   crcmt/bench.sh [-c corpusdir] [-n runs] [-t mtflag] [-f "0 256"] [-j jobs]
#                  [-b minblock]
#
# -b overrides MinBlock in UpdateCRC32MT (UNRAR_CRC_MINBLOCK), which is what
# decides whether an Update() call is pooled at all. Use it to test a threshold
# without rebuilding: `-b 0x80000` engages the pool only from 1 MB up.
#
# The corpus is dispatch/make-corpus.sh's. rar5-many-m5 and rar5-solid-m5 are
# the interesting rows for small Update() sizes; rar5-store-m0 for large ones.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORPUS="$ROOT/dispatch/corpus"
OUT="$ROOT/crcmt/build"
RUNS=5
MTFLAG=""
FOLDS=""
JOBS=""
MINBLOCK=""
BUILD=1

while [ $# -gt 0 ]; do
  case $1 in
    -c) CORPUS=$2; shift 2 ;;
    -c*) CORPUS=${1#-c}; shift ;;
    -n) RUNS=$2; shift 2 ;;
    -n*) RUNS=${1#-n}; shift ;;
    -t) MTFLAG=$2; shift 2 ;;
    -f) FOLDS=$2; shift 2 ;;
    -b) MINBLOCK=$2; shift 2 ;;
    -b*) MINBLOCK=${1#-b}; shift ;;
    -j) JOBS=$2; shift 2 ;;
    -j*) JOBS=${1#-j}; shift ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -d "$CORPUS" ] || {
  echo "no corpus at $CORPUS - run dispatch/make-corpus.sh first" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "$0: python3 is required for sub-millisecond timing." >&2; exit 1; }

[ -n "$JOBS" ] || JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

EXE="$OUT/unrar-diag"

if [ "$BUILD" -eq 1 ]; then
  mkdir -p "$OUT"
  echo "==> building $EXE (-DCRCMT_DIAG)"
  # clean first: the diag knobs are a compile-time define, and object files are
  # shared between builds with different defines.
  make -C "$ROOT" clean >/dev/null
  make -C "$ROOT" -j"$JOBS" CPPFLAGS="-DCRCMT_DIAG" >"$OUT/build.log" 2>&1 || {
    echo "!!! build failed; see $OUT/build.log" >&2
    tail -20 "$OUT/build.log" >&2
    exit 1
  }
  mv "$ROOT/unrar" "$EXE"
  make -C "$ROOT" clean >/dev/null 2>&1 || true
fi

[ -x "$EXE" ] || { echo "missing $EXE - run without --no-build" >&2; exit 1; }

# Confirm the knobs are actually compiled in. Without this check every column
# would be identical and the run would read as "the pool makes no difference".
# UNRAR_CRC_HIST is the probe because it is the only knob whose presence is
# directly observable: the others change timing, which is what we are measuring.
PROBE=""
for arc in "$CORPUS"/*.rar; do
  case $(basename "$arc") in
    *encrypted*|*.part*.rar) continue ;;
  esac
  PROBE=$arc
  break
done
[ -n "$PROBE" ] || { echo "no usable archive in $CORPUS" >&2; exit 1; }

if ! UNRAR_CRC_HIST=1 "$EXE" t -inul -p- -y "$PROBE" 2>&1 >/dev/null |
     grep -q "Update CRC32 call sizes"; then
  echo "!!! the diag knobs had no effect: $EXE is not a -DCRCMT_DIAG build" >&2
  exit 1
fi

if [ -z "$FOLDS" ]; then
  if { objdump -d "$EXE" 2>/dev/null || otool -tv "$EXE" 2>/dev/null; } |
     grep -qi pclmul; then
    FOLDS="0 256"
  else
    FOLDS="native"
  fi
fi

# Per-archive timing. Prints "min_ms median_ms iqr_pct median_cpu_ms".
#
# Timing happens inside one python3 process; spawning an interpreter per sample
# would add tens of milliseconds of noise.
#
# The verdict is decided on *medians*, not minima, and the noise band is the
# interquartile spread. That is a deliberate change from dispatch/bench.sh,
# which used min-of-N with (median-min)/min as its band: that band grows with N,
# because more samples find a lower minimum while the median barely moves. A
# row read as a solid result at -n 5 and as noise at -n 15 with no underlying
# change, purely from that. Median and IQR are both stable in N, so two runs at
# different -n are comparable. The minimum is still printed, since it is the
# sample least polluted by scheduler interference and useful for reading rates
# off, but nothing is decided on it.
best_ms() {
  runs=$1; shift
  python3 -c '
import resource, subprocess, sys, time
runs = int(sys.argv[1])
cmd = [a for a in sys.argv[2:] if a]
# One untimed warmup: the first read pulls the archive into page cache.
subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

walls, cpus = [], []
for _ in range(runs):
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    walls.append((time.perf_counter() - t) * 1000)
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpus.append(((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) * 1000)

walls_s = sorted(walls)
cpus_s = sorted(cpus)

def pct(v, q):
    if len(v) == 1:
        return v[0]
    i = (len(v) - 1) * q
    lo, hi = int(i), min(int(i) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (i - lo)

med = pct(walls_s, 0.5)
iqr = pct(walls_s, 0.75) - pct(walls_s, 0.25)
# Median CPU rather than the CPU of the fastest run: the cpu columns are a
# result in their own right, so they get the same robust statistic as the wall.
print(round(walls_s[0], 1), round(med, 1),
      round(iqr / med * 100, 1) if med else 0.0,
      round(pct(cpus_s, 0.5), 1))
' "$runs" "$@"
}

if [ -n "$MINBLOCK" ]; then
  export UNRAR_CRC_MINBLOCK=$MINBLOCK
fi

echo "runs per measurement: $RUNS   unrar flags: ${MTFLAG:-default threads}"
echo "MinBlock: ${MINBLOCK:-0x4000 (default)}"

for fold in $FOLDS; do
  if [ "$fold" = native ]; then
    unset UNRAR_CRC_FOLD || true
    echo
    echo "########  native CRC32 (non-x86: ARM hw crc32 or the table)  ########"
  else
    export UNRAR_CRC_FOLD=$fold
    echo
    case $fold in
      0) echo "########  UNRAR_CRC_FOLD=0  (slicing-by-16 table)  ########" ;;
      *) echo "########  UNRAR_CRC_FOLD=$fold  (${fold}-bit folding)  ########" ;;
    esac
  fi

  printf '%-22s %8s %9s %9s   %9s %9s   %9s %9s   %7s %6s\n' \
    archive no-CRC "CRC 1thr" "CRC pool" "wall 1thr" "wall pool" \
    "cpu 1thr" "cpu pool" "pool" "iqr"

  for arc in "$CORPUS"/*.rar; do
    case $(basename "$arc") in
      *.part01.rar|*.part1.rar) ;;
      *.part*.rar) continue ;;
    esac
    case $(basename "$arc") in
      *encrypted*) pw="-pbenchpw" ;;
      *) pw="-p-" ;;
    esac

    export UNRAR_CRC_SKIP=1
    set -- $(best_ms "$RUNS" "$EXE" t "$MTFLAG" "$pw" -y "$arc")
    skipmed=$2; skipiqr=$3; skipcpu=$4
    unset UNRAR_CRC_SKIP

    export UNRAR_CRC_MT=1
    set -- $(best_ms "$RUNS" "$EXE" t "$MTFLAG" "$pw" -y "$arc")
    onemed=$2; oneiqr=$3; onecpu=$4
    unset UNRAR_CRC_MT

    set -- $(best_ms "$RUNS" "$EXE" t "$MTFLAG" "$pw" -y "$arc")
    poolmed=$2; pooliqr=$3; poolcpu=$4

    printf '%-22s %7sms %8sms %8sms   ' \
      "$(basename "$arc" .rar)" "$skipmed" "$onemed" "$poolmed"
    python3 -c "
skip, one, pool = $skipmed, $onemed, $poolmed
skipcpu, onecpu, poolcpu = $skipcpu, $onecpu, $poolcpu
band = max($skipiqr, $oneiqr, $pooliqr)
d = (one - pool) / one * 100
verdict = 'noise' if abs(d) <= band else ('' if d > 0 else 'SLOWER')
# A few percent cannot be resolved on a run this short whatever the spread
# says, so label it rather than letting it read as a measurement.
if pool < 100:
    verdict = (verdict + ' short').strip()
print(f'{one-skip:8.1f}ms {pool-skip:8.1f}ms   '
      f'{onecpu-skipcpu:8.1f}ms {poolcpu-skipcpu:8.1f}ms   '
      f'{d:+6.1f}% {band:5.1f}% {verdict}')"
  done
done

cat <<'EOF'

All wall-clock columns are medians of the runs, so they are comparable between
two invocations with different -n.

no-CRC    = UNRAR_CRC_SKIP=1: the same run with CRC32 removed
CRC 1thr  = UNRAR_CRC_MT=1: unpack still threaded, CRC on the calling thread
CRC pool  = unmodified
cost      = (that column) - (no-CRC): the CRC-attributable wall clock. Only
            meaningful on a row whose iqr is well under the cost being claimed.
pool      = 1thr vs pool, on medians; positive means the pool is faster
cores     = cpu(user+sys)/wall of the fastest pooled run
iqr       = worst interquartile spread over the three columns; a smaller |pool|
            than this is not a result
short     = the run is under 100 ms, too brief to resolve a few percent at all.
            Rebuild the corpus larger (make-corpus.sh -s 512) for those rows.
EOF
