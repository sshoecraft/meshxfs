#!/bin/bash
# zombie_nblk_sweep.sh — count the freed-shell-with-blocks signature and the
# dinode-verifier fallout in lap kernel-log streams, with verbatim evidence.
#
# usage: scripts/zombie_nblk_sweep.sh OUT DIR [DIR...]
#   DIR  an evidence run dir; every DIR/*_dmesg_stream.gz in it is scanned.
#        A stream holds the node's whole log since its last prep, so it can
#        carry lines from earlier laps; counts are per stream as found.
#   OUT  the report.  OUT.tsv gets one count row per stream; OUT.work.XXXXXX/
#        keeps each stream's prefiltered lines (sN.hits = line N of list).
#   env  PAR   streams read in parallel                  (default 4)
#        MAXA  streams given a section-3 listing         (default 15)
#        NA    A lines followed up per listed stream     (default 5)
#
# Each stream is decompressed exactly once, under its own `timeout 60`, and
# prefiltered with `grep -a -n -F` to the lines holding any tag below.  Every
# count is `grep -c` over that superset, so it equals
# `zcat STREAM | grep -c PATTERN`, and each quoted line keeps its 1-based line
# number in the decompressed stream.  Quoted text is cut at 300 chars.
#   A  P-CR63-SHELL .* mode=00 .*nblk=[1-9]      (basic regex)
#   B  P-CR63-SHELL
#   C  P-RECYCLE-SANITIZE
#   D  P116-ZOMBIE-ADOPT
#   E  xfs_dinode_verify.part.0+0x80a            (offset is build-specific)
#   F  Metadata corruption detected at xfs_dinode_verify
#   G  P-SFV-FAIL
# Section 3 follows each of a stream's first NA A lines to the first later line
# of the same stream that carries P-RECYCLE-SANITIZE, P-RECYCLE-GATE,
# P128-REARM-UNPUB or P2G-LOGWHO and whose ino= field is the same inode,
# written in decimal or 0x-hex.
# A stream that times out, that zcat cannot read to its end (one still being
# written stops mid-member), or that grew while it was read, is listed with its
# exit codes and sizes; whatever was read before the stop is still counted.
set -u
export LC_ALL=C
usage='usage: zombie_nblk_sweep.sh OUT DIR [DIR...]'
[ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
OUT=$1
shift
PAR=${PAR:-4}
MAXA=${MAXA:-15}
NA=${NA:-5}
WORK=$(mktemp -d "$OUT.work.XXXXXX") || exit 1
export WORK
export PATS=$WORK/patterns
RXA='P-CR63-SHELL .* mode=00 .*nblk=[1-9]'
printf '%s\n' 'P-CR63-SHELL' 'P-RECYCLE-SANITIZE' 'P116-ZOMBIE-ADOPT' \
    'xfs_dinode_verify.part.0+0x80a' \
    'Metadata corruption detected at xfs_dinode_verify' 'P-SFV-FAIL' \
    'P-RECYCLE-GATE' 'P128-REARM-UNPUB' 'P2G-LOGWHO' > "$PATS"

ndirs=0
: > "$WORK/list"
for d in "$@"; do
    [ -d "$d" ] || { echo "not a directory, skipped: $d" >&2; continue; }
    ndirs=$((ndirs + 1))
    for f in "${d%/}"/*_dmesg_stream.gz; do
        [ -f "$f" ] && printf '%s\n' "$f" >> "$WORK/list"
    done
done
nfiles=$(wc -l < "$WORK/list")
nsdirs=$(sed 's#/[^/]*$##' "$WORK/list" | sort -u | wc -l)

scan_one() {
    w=$WORK/s$1
    s0=$(stat -c %s -- "$2")
    t0=$(date +%s%N)
    timeout 60 bash -c 'zcat -- "$1" 2> "$2.zerr" | grep -a -n -F -f "$3" > "$2.hits"
        echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}" > "$2.prc"' _ "$2" "$w" "$PATS"
    rc=$?
    echo "$rc $(( ($(date +%s%N) - t0) / 1000000 ))" > "$w.trc"
    echo "$s0 $(stat -c %s -- "$2") $(date -u -r "$2" +%Y-%m-%dT%H:%M:%SZ)" > "$w.stat"
}
export -f scan_one

t0=$(date +%s)
n=0
while IFS= read -r f; do
    n=$((n + 1))
    printf '%s\0%s\0' "$n" "$f"
done < "$WORK/list" | xargs -0 -n 2 -P "$PAR" bash -c 'scan_one "$1" "$2"' _
scansecs=$(( $(date +%s) - t0 ))

quote() {
    gawk '{ c = index($0, ":"); t = substr($0, c + 1)
            if (length(t) > 300) t = substr(t, 1, 300) " [cut at 300]"
            print "    " substr($0, 1, c - 1) ":" t }'
}

TSV=$OUT.tsv
printf 'path\tA\tB\tC\tD\tE\tF\tG\tbytes_before\tbytes_after\tmtime_utc\ttimeout_rc\tms\tzcat_rc\tgrep_rc\n' > "$TSV"
S1=$WORK/sec1 S3=$WORK/sec3 S4=$WORK/sec4 BAD=$WORK/bad AREST=$WORK/arest
: > "$S1"; : > "$S3"; : > "$S4"; : > "$BAD"; : > "$AREST"
ta=0 tb=0 tc=0 td=0 te=0 tf=0 tg=0 na=0 nf=0 n1=0 maxms=0 maxf=
n=0
while IFS= read -r f; do
    n=$((n + 1))
    w=$WORK/s$n
    h=$w.hits
    [ -f "$h" ] || : > "$h"
    a=$(grep -a -c -e "$RXA" "$h")
    b=$(grep -a -c -F -e 'P-CR63-SHELL' "$h")
    c=$(grep -a -c -F -e 'P-RECYCLE-SANITIZE' "$h")
    d=$(grep -a -c -F -e 'P116-ZOMBIE-ADOPT' "$h")
    e=$(grep -a -c -F -e 'xfs_dinode_verify.part.0+0x80a' "$h")
    fv=$(grep -a -c -F -e 'Metadata corruption detected at xfs_dinode_verify' "$h")
    g=$(grep -a -c -F -e 'P-SFV-FAIL' "$h")
    trc=missing ms=0 zrc=missing grc=missing s0=? s1=? mt=?
    [ -f "$w.trc" ] && read -r trc ms < "$w.trc"
    [ -f "$w.prc" ] && read -r zrc grc < "$w.prc"
    [ -f "$w.stat" ] && read -r s0 s1 mt < "$w.stat"
    ta=$((ta + a)); tb=$((tb + b)); tc=$((tc + c)); td=$((td + d))
    te=$((te + e)); tf=$((tf + fv)); tg=$((tg + g))
    if [ "$ms" -gt "$maxms" ] 2>/dev/null; then maxms=$ms; maxf=$f; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$f" "$a" "$b" "$c" "$d" "$e" "$fv" "$g" "$s0" "$s1" "$mt" "$trc" "$ms" "$zrc" "$grc" >> "$TSV"
    flag=
    [ "$trc" = 0 ] || flag="$flag timeout_rc=$trc"
    [ "$zrc" = 0 ] || flag="$flag zcat_rc=$zrc"
    case $grc in 0|1) ;; *) flag="$flag grep_rc=$grc" ;; esac
    [ "$s0" = "$s1" ] || flag="$flag grew_during_read=$s0->$s1"
    if [ -n "$flag" ]; then
        printf '  %s  %s ms=%s mtime=%s zcat_stderr=[%s]\n' "$f" "${flag# }" "$ms" "$mt" \
            "$(head -c 200 "$w.zerr" 2>/dev/null | tr '\n' ' ')" >> "$BAD"
        flag=" SCAN:${flag# }"
    fi
    if [ $((a + e + fv + g)) -gt 0 ]; then
        n1=$((n1 + 1))
        printf '  %s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$f" "$a" "$b" "$c" "$d" "$e" "$fv" "$g" "$flag" >> "$S1"
    fi
    if [ "$a" -gt 0 ]; then
        na=$((na + 1))
        if [ "$na" -le "$MAXA" ]; then
            {
                printf '\n  FILE %s  A=%s  (first %s A lines; under each, its first later same-ino line among P-RECYCLE-SANITIZE / P-RECYCLE-GATE / P128-REARM-UNPUB / P2G-LOGWHO)\n' "$f" "$a" "$NA"
                grep -a -e "$RXA" "$h" | head -n "$NA" > "$w.a"
                while IFS= read -r al; do
                    printf '%s\n' "$al" | quote
                    ln=${al%%:*}
                    hx=$(printf '%s\n' "${al#*:}" | grep -o -E 'ino=0x[0-9a-fA-F]+' | head -n 1)
                    hx=${hx#ino=0x}
                    if [ -z "$hx" ]; then
                        echo '      follow-up: no ino=0x field on this A line'
                        continue
                    fi
                    hx=${hx,,}
                    dec=$((16#$hx))
                    fu=$(gawk -v after="$ln" -v dec="$dec" -v hx="$hx" '
                        { c = index($0, ":"); n = substr($0, 1, c - 1) + 0
                          if (n <= after) next
                          t = substr($0, c + 1)
                          if (!(index(t, "P-RECYCLE-SANITIZE") || index(t, "P-RECYCLE-GATE") ||
                                index(t, "P128-REARM-UNPUB") || index(t, "P2G-LOGWHO"))) next
                          if (t ~ ("ino=" dec "([^0-9]|$)") || tolower(t) ~ ("ino=0x0*" hx "([^0-9a-f]|$)")) {
                              if (length(t) > 300) t = substr(t, 1, 300) " [cut at 300]"
                              print n ":" t
                              exit
                          } }' "$h")
                    printf '      follow-up ino=0x%s (=%s): %s\n' "$hx" "$dec" "${fu:-NONE later in this stream}"
                done < "$w.a"
            } >> "$S3"
        else
            printf '  %s  A=%s\n' "$f" "$a" >> "$AREST"
        fi
    fi
    if [ "$fv" -gt 0 ]; then
        nf=$((nf + 1))
        {
            printf '\n  FILE %s  F=%s G=%s\n   first 3 F lines:\n' "$f" "$fv" "$g"
            grep -a -F -e 'Metadata corruption detected at xfs_dinode_verify' "$h" | head -n 3 | quote
            printf '   first 3 G lines:\n'
            if [ "$g" -gt 0 ]; then
                grep -a -F -e 'P-SFV-FAIL' "$h" | head -n 3 | quote
            else
                echo '    (none)'
            fi
        } >> "$S4"
    fi
done < "$WORK/list"

{
    echo "ZOMBIE-NBLK SWEEP — scripts/zombie_nblk_sweep.sh, finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "per-stream TSV (all streams): $TSV"
    echo "prefiltered lines: $WORK/sN.hits (N = line N of $WORK/list), grep -n format"
    echo "A regex (BRE): $RXA ; B..G fixed strings ; each count = grep -c over the stream's prefilter"
    echo
    echo "SECTION 1 — streams with A, E, F or G non-zero (n=$n1 of $nfiles)"
    printf '  path\tA\tB\tC\tD\tE\tF\tG\n'
    cat "$S1"
    [ "$n1" -gt 0 ] || echo "  (none)"
    echo
    echo "SECTION 2 — totals over all $nfiles streams scanned"
    echo "  A=$ta B=$tb C=$tc D=$td E=$te F=$tf G=$tg"
    echo "  dirs given=$ndirs  dirs holding >=1 *_dmesg_stream.gz=$nsdirs  streams scanned=$nfiles"
    echo "  streams with A>0=$na  streams with F>0=$nf"
    echo "  scan wall=${scansecs}s at PAR=$PAR; slowest stream ${maxms}ms: $maxf"
    echo "  streams with a scan problem (timeout / zcat or grep error / grew while read): $(wc -l < "$BAD")"
    cat "$BAD"
    echo
    echo "SECTION 3 — A lines and same-ino follow-up (streams with A>0: $na; listed: $(( na < MAXA ? na : MAXA )), in list order)"
    cat "$S3"
    if [ -s "$AREST" ]; then
        echo
        echo "  A>0 streams beyond the cap of $MAXA (path, A count):"
        cat "$AREST"
    fi
    [ "$na" -gt 0 ] || echo "  (none)"
    echo
    echo "SECTION 4 — streams with F>0 (n=$nf): first 3 F lines, first 3 G lines"
    cat "$S4"
    [ "$nf" -gt 0 ] || echo "  (none)"
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
