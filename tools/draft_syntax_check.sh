#!/bin/bash
# draft_syntax_check.sh — compile-check kernel sources drafted under
# tests/evidence/drafts/tree/ against the tree they will land in, without a
# copy of the tree.
#
# A draft of a module source cannot be built in place while a release
# candidate has the tree frozen, and a sibling copy of the tree is not made.
# Each source's own compiler line is in the last build's .<name>.o.cmd; this
# runs that line with -fsyntax-only on the draft instead of the tree's file.
# The saved line chains objtool after the compiler with ';', so only its first
# command is taken. A draft's quoted includes resolve first beside the draft
# (a drafted header there is used) and then in the tree's own directories.
#
# Usage: tools/draft_syntax_check.sh <path relative to the tree, e.g. xfs/xfs_log_recover.c> ...
# Exit: 0 every draft compiles with no error, 1 an error, 2 cannot check.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
while [ ! -f "$ROOT/VERSION" ] || [ ! -d "$ROOT/dlm" ]; do
    [ "$ROOT" = / ] && { echo "draft_syntax_check: no tree root above $HERE"; exit 2; }
    ROOT=$(cd "$ROOT/.." && pwd)
done
ROOT=$(cd "$ROOT" && pwd)
DRAFTS=$ROOT/tests/evidence/drafts/tree
KB=/lib/modules/$(uname -r)/build
[ $# -ge 1 ] || { echo "usage: $0 <tree-relative source> ..."; exit 2; }
worst=0
for rel in "$@"; do
    d=$(dirname "$rel"); f=$(basename "$rel" .c)
    cmdfile=$ROOT/$d/.$f.o.cmd
    [ -f "$cmdfile" ] || { echo "$rel: no $cmdfile (build the module once first)"; worst=2; continue; }
    [ -f "$DRAFTS/$rel" ] || { echo "$rel: no draft at $DRAFTS/$rel"; worst=2; continue; }
    cmd=$(sed -n '1s/^savedcmd_[^:]*:= //p' "$cmdfile" | cut -d';' -f1 \
          | sed -e 's#-Wp,-MMD,[^ ]*##' -e 's# -o [^ ]*\.o # #')
    cmd=${cmd//$ROOT\/$rel/$DRAFTS\/$rel}
    out=$( (cd "$KB" && timeout 180 bash -c "$cmd -fsyntax-only -I$ROOT/$d -I$ROOT/dlm") 2>&1)
    rc=$?
    errors=$(grep -c 'error:' <<< "$out")
    warnings=$(grep -c 'warning:' <<< "$out")
    echo "$rel: rc=$rc errors=$errors warnings=$warnings"
    grep -E 'error:|warning:' <<< "$out" | head -20
    if [ "$rc" != 0 ] || [ "$errors" != 0 ]; then
        [ $worst = 0 ] && worst=1
    fi
done
exit $worst
