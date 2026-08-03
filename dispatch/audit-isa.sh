#!/bin/sh
#
# Attribute ISA-extension instructions to their enclosing function.
#
# This is the gate on the aarch64 "one binary, no launcher" recommendation.
# The source already runtime-gates the NEON paths (crc.cpp:44 CRC_Neon,
# rijndael.cpp:125 AES_Neon), so building with +crc+crypto is only safe on
# CPUs lacking those extensions if the compiler confined those instructions
# to the guarded functions. This checks that, rather than assuming it.
#
# Expected containment:
#   crc32*  -> CRC32
#   aes*    -> Rijndael::blockEncryptNeon, Rijndael::blockDecryptNeon
#
# Any hit outside those means the single-binary approach is unsafe and the
# two-variant launcher is required instead.
#
# Usage: dispatch/audit-isa.sh <unstripped-binary> [pattern]

set -eu

BIN=${1:?usage: audit-isa.sh <unstripped-binary> [instruction-regex]}
[ -f "$BIN" ] || { echo "no such file: $BIN" >&2; exit 1; }

# On x86 this is less a containment check than evidence of what the higher
# -march levels actually bought: BMI1/BMI2 (shrx/bzhi/andn/...) are the
# plausible v3 win on the bit-reader shifts in getbits.hpp / unpackinline.cpp,
# and vp*/vfmadd show AVX2 vectorisation.
case $(uname -m) in
  arm64|aarch64) DEFAULT_PAT='^(crc32|aes|sha1|sha256|sha512|sha3|pmull)' ;;
  *)             DEFAULT_PAT='^(shrx|sarx|shlx|bzhi|andn|mulx|pdep|pext|blsr|blsi|tzcnt|lzcnt|popcnt|crc32|aes|pclmul|vp|vfmadd)' ;;
esac
PAT=${2:-$DEFAULT_PAT}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Symbol table: "address name", sorted by address, text symbols only.
# -C demangles where supported; fall back to mangled names if not.
{ nm -nC "$BIN" 2>/dev/null || nm -n "$BIN" 2>/dev/null; } \
  | awk '$2 ~ /^[tT]$/ && $1 ~ /^[0-9a-fA-F]+$/ {addr=$1; $1=""; $2=""; sub(/^  /,""); print addr, $0}' \
  > "$TMP/syms"
[ -s "$TMP/syms" ] || { echo "no text symbols found - is '$BIN' stripped? Rebuild with build-variants.sh -u" >&2; exit 1; }

# Disassembly: "address mnemonic".
#
# --no-show-raw-insn suppresses the hex byte column, which is essential: with
# it present the mnemonic's field index shifts with instruction length, so a
# fixed $N lands on an opcode byte for long instructions.
if command -v objdump >/dev/null 2>&1 && objdump -d "$BIN" >/dev/null 2>&1; then
  objdump -d --no-show-raw-insn "$BIN" 2>/dev/null \
    | awk '/^[[:space:]]*[0-9a-f]+:/ {addr=$1; sub(/:$/,"",addr); print addr, $2}' \
    > "$TMP/dis"
else
  otool -tv "$BIN" 2>/dev/null | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9a-f]+$/ {print $1, $2}' > "$TMP/dis"
fi
[ -s "$TMP/dis" ] || { echo "could not disassemble $BIN" >&2; exit 1; }

echo "=== ISA-extension instruction containment: $BIN ==="
echo "    pattern: $PAT"
echo

# For each matching instruction, binary-search the symbol table for the
# greatest symbol address <= instruction address.
awk -v pat="$PAT" '
  # strtonum() is a gawk extension; BSD awk on macOS lacks it.
  function hex2dec(s,   i,c,v,r) {
    r=0; s=tolower(s)
    for (i=1; i<=length(s); i++) {
      c=substr(s,i,1); v=index("0123456789abcdef",c)-1
      if (v<0) continue
      r=r*16+v
    }
    return r
  }
  NR==FNR { saddr[FNR]=hex2dec($1); sname[FNR]=substr($0, index($0," ")+1); n=FNR; next }
  {
    mnem=$2
    if (mnem !~ pat) next
    a=hex2dec($1)
    lo=1; hi=n; best=0
    while (lo<=hi) { mid=int((lo+hi)/2); if (saddr[mid]<=a) { best=mid; lo=mid+1 } else hi=mid-1 }
    fn = best ? sname[best] : "<unknown>"
    count[fn "\t" mnem]++
  }
  END {
    for (k in count) { split(k,p,"\t"); printf "%-6d %-12s %s\n", count[k], p[2], p[1] }
  }
' "$TMP/syms" "$TMP/dis" | sort -k3 -k2

echo
case $(uname -m) in
  arm64|aarch64)
    echo "Containment check: every row above must name one of"
    echo "  CRC32 / Rijndael::blockEncryptNeon / Rijndael::blockDecryptNeon"
    echo "Anything else means an unguarded instruction could execute on a CPU"
    echo "without the extension - use the two-variant dispatcher instead."
    ;;
  *)
    echo "This is evidence of what the -march level bought, not a safety check:"
    echo "each variant is selected by CPU detection, so instructions may appear"
    echo "anywhere. Compare levels - BMI2 (shrx/bzhi) in the bit-reader and"
    echo "decode paths is the plausible v3 win; vp*/vfmadd show AVX2 use."
    ;;
esac
