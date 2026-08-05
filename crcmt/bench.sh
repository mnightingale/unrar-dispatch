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

# Ask the binary which CRC32 path it actually took, for the given
# UNRAR_CRC_FOLD. crcfold.cpp's override can only narrow what CPUID detected,
# never widen it, so requesting 256 on a part with PCLMULQDQ and no VPCLMULQDQ
# silently runs fold-128 - and a header claiming otherwise makes the whole table
# say the wrong thing about the wrong implementation. Guessing this from
# /proc/cpuinfo was the previous approach and it got exactly that case wrong.
active_path() { # fold_mode -> e.g. "fold-128"
  if [ "$1" = native ]; then
    unset UNRAR_CRC_FOLD || true
  else
    UNRAR_CRC_FOLD=$1; export UNRAR_CRC_FOLD
  fi
  UNRAR_CRC_HIST=1 "$EXE" t -inul -p- -y "$PROBE" 2>&1 >/dev/null |
    sed -n 's/^CRC32 path: //p' | head -1
}

if [ -z "$FOLDS" ]; then
  case $(active_path 256) in
    fold-256) FOLDS="0 256" ;;
    fold-128) FOLDS="0 128"
              echo "==> this CPU has PCLMULQDQ but not VPCLMULQDQ: comparing 0 vs 128" ;;
    *)        FOLDS="native"
              echo "==> no folding available here: only the table path exists" ;;
  esac
fi
unset UNRAR_CRC_FOLD || true

# Times all three modes for one archive, interleaved: one sample of each per
# round rather than all N of one mode and then all N of the next. Sequential
# blocks let any drift over the run - thermal on a fanless or low-TDP part,
# turbo residency, page cache - land entirely on whichever mode goes last. On a
# 15 W dual-core that showed up as CRC costs coming out negative, i.e. the
# baseline measured slower than the run it was a floor for. The root bench.sh
# alternates variant order for the same reason.
#
# Prints nine fields: median, iqr%, median cpu, for skip / 1-thread / pool.
# Medians and interquartile spread rather than min-of-N with (median-min)/min:
# that band grows with N, so the same row could read as a result at -n 5 and as
# noise at -n 15 with nothing underlying changing.
best_ms() {
  runs=$1; shift
  python3 -c '
import os, resource, subprocess, sys, time
runs = int(sys.argv[1])
cmd = [a for a in sys.argv[2:] if a]

MODES = (("UNRAR_CRC_SKIP", "1"), ("UNRAR_CRC_MT", "1"), (None, None))

def run(mode):
    env = dict(os.environ)
    for name, _ in MODES:
        if name:
            env.pop(name, None)
    name, value = mode
    if name:
        env[name] = value
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env=env)
    wall = (time.perf_counter() - t) * 1000
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) * 1000
    return wall, cpu

for mode in MODES:          # untimed warmup, so the page cache is not a factor
    run(mode)

walls = [[] for _ in MODES]
cpus = [[] for _ in MODES]
for _ in range(runs):
    for i, mode in enumerate(MODES):
        w, c = run(mode)
        walls[i].append(w)
        cpus[i].append(c)

def pct(v, q):
    v = sorted(v)
    if len(v) == 1:
        return v[0]
    i = (len(v) - 1) * q
    lo, hi = int(i), min(int(i) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (i - lo)

out = []
for i in range(len(MODES)):
    med = pct(walls[i], 0.5)
    iqr = pct(walls[i], 0.75) - pct(walls[i], 0.25)
    out += [round(med, 1), round(iqr / med * 100, 1) if med else 0.0,
            round(pct(cpus[i], 0.5), 1)]
print(*out)
' "$runs" "$@"
}

if [ -n "$MINBLOCK" ]; then
  export UNRAR_CRC_MINBLOCK=$MINBLOCK
fi

echo "runs per measurement: $RUNS   unrar flags: ${MTFLAG:-default threads}"
echo "MinBlock: ${MINBLOCK:-0x4000 (default)}"

for fold in $FOLDS; do
  # PATH is what ran; $fold is only what was asked for. If they differ, say so
  # rather than printing a header the numbers do not match.
  ACTIVE=$(active_path "$fold")
  if [ "$fold" = native ]; then
    unset UNRAR_CRC_FOLD || true
  else
    UNRAR_CRC_FOLD=$fold; export UNRAR_CRC_FOLD
  fi
  echo
  if [ "$fold" != native ] && [ "$fold" != 0 ] &&
     [ "$ACTIVE" != "fold-$fold" ]; then
    echo "########  requested UNRAR_CRC_FOLD=$fold, THIS CPU RAN ${ACTIVE}  ########"
  else
    echo "########  CRC32 path: ${ACTIVE}  ########"
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

    set -- $(best_ms "$RUNS" "$EXE" t "$MTFLAG" "$pw" -y "$arc")
    skipmed=$1; skipiqr=$2; skipcpu=$3
    onemed=$4;  oneiqr=$5;  onecpu=$6
    poolmed=$7; pooliqr=$8; poolcpu=$9

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
