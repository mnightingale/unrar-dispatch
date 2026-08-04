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
# A skipped CRC must fail the checksum test, so success here means the define
# was missing.
PROBE=""
for arc in "$CORPUS"/*.rar; do
  case $(basename "$arc") in
    *encrypted*|*.part*.rar) continue ;;
  esac
  PROBE=$arc
  break
done
[ -n "$PROBE" ] || { echo "no usable archive in $CORPUS" >&2; exit 1; }

export UNRAR_CRC_SKIP=1
if "$EXE" t -p- -y "$PROBE" >/dev/null 2>&1; then
  unset UNRAR_CRC_SKIP
  echo "!!! UNRAR_CRC_SKIP had no effect: $EXE is not a -DCRCMT_DIAG build" >&2
  exit 1
fi
unset UNRAR_CRC_SKIP

if [ -z "$FOLDS" ]; then
  if { objdump -d "$EXE" 2>/dev/null || otool -tv "$EXE" 2>/dev/null; } |
     grep -qi pclmul; then
    FOLDS="0 256"
  else
    FOLDS="native"
  fi
fi

# Min-of-N wall clock plus the CPU time of that same fastest run, in ms.
# Timing happens inside one python3 process; spawning an interpreter per sample
# would add tens of milliseconds of noise. The minimum is reported rather than
# the mean because it is the sample least polluted by scheduler interference.
# Prints "min_ms cpu_ms spread_pct", spread being (median-min)/min.
best_ms() {
  runs=$1; shift
  python3 -c '
import resource, subprocess, sys, time
runs = int(sys.argv[1])
cmd = [a for a in sys.argv[2:] if a]
subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

samples = []
for _ in range(runs):
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wall = (time.perf_counter() - t) * 1000
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) * 1000
    samples.append((wall, cpu))
samples.sort()
lo, cpu = samples[0]
med = samples[len(samples) // 2][0]
print(round(lo, 1), round(cpu, 1), round((med - lo) / lo * 100, 1))
' "$runs" "$@"
}

if [ -n "$MINBLOCK" ]; then
  export UNRAR_CRC_MINBLOCK=$MINBLOCK
fi

echo "runs per measurement: $RUNS (min-of-N)   unrar flags: ${MTFLAG:-default threads}"
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

  printf '%-22s %8s %9s %9s   %9s %9s %8s %7s %6s\n' \
    archive no-CRC "CRC 1thr" "CRC pool" "cost 1thr" "cost pool" \
    "pool" "cores" "noise"

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
    skip=$1; noise=$3
    unset UNRAR_CRC_SKIP

    export UNRAR_CRC_MT=1
    set -- $(best_ms "$RUNS" "$EXE" t "$MTFLAG" "$pw" -y "$arc")
    one=$1; onenoise=$3
    unset UNRAR_CRC_MT

    set -- $(best_ms "$RUNS" "$EXE" t "$MTFLAG" "$pw" -y "$arc")
    pool=$1; poolcpu=$2; poolnoise=$3

    printf '%-22s %7sms %8sms %8sms   ' \
      "$(basename "$arc" .rar)" "$skip" "$one" "$pool"
    python3 -c "
skip, one, pool, cpu = $skip, $one, $pool, $poolcpu
noise = max($noise, $onenoise, $poolnoise)
d = (one - pool) / one * 100
verdict = 'noise' if abs(d) <= noise else ('' if d > 0 else 'SLOWER')
print(f'{one-skip:8.1f}ms {pool-skip:8.1f}ms {d:+7.1f}% {cpu/pool:7.2f} {noise:5.1f}% {verdict}')"
  done
done

cat <<'EOF'

no-CRC    = UNRAR_CRC_SKIP=1: the same run with CRC32 removed (checksums wrong)
CRC 1thr  = UNRAR_CRC_MT=1: unpack still threaded, CRC on the calling thread
CRC pool  = unmodified
cost      = (that column) - (no-CRC): the CRC-attributable wall clock
pool      = 1thr vs pool wall clock; positive means the pool is faster
cores     = cpu(user+sys)/wall of the pooled run, i.e. what the pool spends
noise     = worst run-to-run spread over the three columns; a smaller |pool|
            than this is not a result
EOF
