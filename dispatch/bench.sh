#!/bin/sh
#
# Benchmark each built variant across the corpus.
#
# Uses `unrar t` (test) rather than `x` (extract): test mode does a full
# decompress plus CRC check with no disk writes, isolating decompression
# from filesystem I/O.
#
# Results are reported per archive, never as one aggregate: the paths have
# different bottlenecks, and e.g. a CopyString win on RAR5 text would be
# hidden by a wash on the divide-bound RAR3 PPMd path.
#
# Usage: dispatch/bench.sh [-b builddir] [-c corpusdir] [-n runs] [-t threads]

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$ROOT/dispatch/build"
CORPUS="$ROOT/dispatch/corpus"
RUNS=5
THREADS="mt1 default"

while [ $# -gt 0 ]; do
  case $1 in
    -b) BUILD=$2; shift 2 ;;
    -b*) BUILD=${1#-b}; shift ;;
    -c) CORPUS=$2; shift 2 ;;
    -c*) CORPUS=${1#-c}; shift ;;
    -n) RUNS=$2; shift 2 ;;
    -n*) RUNS=${1#-n}; shift ;;
    -t) THREADS=$2; shift 2 ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -d "$CORPUS" ] || { echo "no corpus at $CORPUS - run dispatch/make-corpus.sh first" >&2; exit 1; }

VARIANTS=$(ls "$BUILD"/unrar.* 2>/dev/null | grep -v '\.buildlog$' || true)
[ -n "$VARIANTS" ] || { echo "no variants in $BUILD - run dispatch/build-variants.sh first" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "$0: python3 is required for sub-millisecond timing without hyperfine." >&2
  exit 1
}

# Min-of-N wall-clock milliseconds for one command.
#
# Timing happens inside a single python3 process: spawning the interpreter
# around the measured region would add tens of milliseconds of noise to every
# sample. The minimum, not the mean, is reported - it is the sample least
# polluted by scheduler interference, which is what matters for a CPU-bound
# decode loop.
# Prints "min_ms spread_pct", where spread is (median-min)/min over the runs.
# The spread is the empirical noise floor for that measurement: a variant
# delta smaller than it is not evidence of anything.
#
# Median rather than max: max-min is destroyed by a single scheduler hiccup,
# which was labelling reproducible 45%+ effects as noise off one bad sample.
best_ms() {
  runs=$1; shift
  python3 -c '
import subprocess, sys, time
runs = int(sys.argv[1])
cmd = [a for a in sys.argv[2:] if a]
# One untimed warmup: the first read pulls the archive into page cache, and
# including it inflates the spread enough to mask real differences (a 250MB
# archive showed a 57% spread from this alone).
subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

times = []
for _ in range(runs):
    t = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    times.append((time.perf_counter() - t) * 1000)
times.sort()
lo = times[0]
med = times[len(times) // 2]
print(int(lo), round((med - lo) / lo * 100, 1))
' "$runs" "$@"
}

echo "runs per measurement: $RUNS (min-of-N)   variants: $(echo "$VARIANTS" | wc -l | tr -d ' ')"
echo

for mode in $THREADS; do
  case $mode in
    mt1)     mtflag="-mt1"; label="single-thread (-mt1)" ;;
    default) mtflag="";     label="default threads" ;;
    *)       mtflag="-mt$mode"; label="-mt$mode" ;;
  esac

  echo "########  $label  ########"
  printf '%-24s' "archive"
  for v in $VARIANTS; do printf '%14s' "$(basename "$v" | sed 's/^unrar\.//')"; done
  printf '%10s%8s   %s\n' "delta" "noise" "verdict"

  for arc in "$CORPUS"/*.rar; do
    # Multi-volume sets are driven from part01 only; skip the continuation
    # volumes so they are not timed as separate archives.
    case $(basename "$arc") in
      *.part01.rar|*.part1.rar) ;;
      *.part*.rar) continue ;;
    esac
    # Any *encrypted* archive shares the fixed benchmark password.
    case $(basename "$arc") in
      *encrypted*) pw="-pbenchpw" ;;
      *) pw="-p-" ;;
    esac

    printf '%-24s' "$(basename "$arc" .rar)"
    baseline=""
    last=""
    worst_noise=0
    for v in $VARIANTS; do
      set -- $(best_ms "$RUNS" "$v" t "$mtflag" "$pw" -y "$arc")
      best=$1; noise=$2
      printf '%13sms' "$best"
      [ -z "$baseline" ] && baseline=$best
      last=$best
      worst_noise=$(python3 -c "print(max($worst_noise, $noise))")
    done
    if [ -n "$baseline" ] && [ "$baseline" -gt 0 ] && [ "$last" -gt 0 ]; then
      # A delta inside the noise band is not a result; label it so, rather
      # than letting a +2% line read as a win.
      python3 -c "
d = ($baseline - $last) / $baseline * 100
n = $worst_noise
print(f'{d:+9.1f}%{n:7.1f}%   ' + ('noise' if abs(d) <= n else ('FASTER' if d > 0 else 'SLOWER')))"
    else
      printf '%10s\n' "n/a"
    fi
  done
  echo
done

echo "delta   = last variant vs first (positive means the last variant is faster)"
echo "noise   = worst run-to-run spread (median-min) seen for that row"
echo "verdict = 'noise' means |delta| <= noise, i.e. not a measurable difference"
