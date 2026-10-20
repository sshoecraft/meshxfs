---
name: compiled-sibling-prep-mkfs-and-register-word-decoding
description: Assorted: sibling-checkout run.sh prep formats with main tree's mkfs (A/Bs vacuous); decode crash register words as data to name the writer.
metadata:
  type: feedback
tags: [compiled, run-sh, mkfs, sibling-checkout, crash-forensics, register-decode, clyde]
---

Assorted group (the tail the clusterer could not fit to a topic), both found session 36: `trap-sibling-checkout-prep-formats-with-main-tree-mkfs` and `technique-decode-corrupt-register-words-as-data-to-name-the-writer`. What they share: an observed result gets credited to the wrong producer until the real one is read back. In one it is which tree's `mkfs_mxfs` formatted the LUN; in the other it is which writer's bytes sit in a crash register.

## Trap: a sibling checkout's `run.sh` prep formats the LUN with the main tree's `mkfs_mxfs`

Source: `trap-sibling-checkout-prep-formats-with-main-tree-mkfs`

- Mechanism: `run.sh`'s mkfs step ran `bash /src/mxfs/tests/setup/prep_fs.sh` without `MXFS_REPO`, and `prep_fs.sh` defaults `MXFS_REPO=/src/mxfs`. So every sibling checkout's (`~/src/mxfs-X`) prep formatted the LUN with the MAIN tree's `tools/mkfs_mxfs`, while `prep_node.sh` (given `MXFS_REPO=$NODE_REPO`) loaded the sibling's module.
- `run.sh`'s own comment says the nodes run "the tree's own tools"; the mkfs call did not.
- Consequence: any A/B of an mkfs/format change run from a sibling (e.g. the D-0349 ledger routing version, `mkfs -H 1|2` in `~/src/mxfs-d0349`) would have formatted every arm with the old mkfs (or failed on an unknown option), silently or loudly vacuous. Sibling A/Bs of module-only changes were unaffected (same mkfs).
- Fix: made first in `~/src/mxfs-d0349/run.sh`, passing `MXFS_REPO='/src/$(basename "$REPO")'` to `prep_fs.sh`. The main tree's `run.sh` needs the same one-line change, made only when no lap is executing it (bash reads a running script incrementally).
- Also: board test scripts are run as `/src/mxfs/tests/<cat>/<name>.sh` on the nodes, i.e. main's copies, even from a sibling.
- When a sibling arm must prove what it ran, read it back on the node. The d0349 arm reads `P-TAUTH-OPEN` `hash_version=` from each node's mount.
- Found session 36.

## Technique: decode a crash's "impossible" register words as data to name the writer

Source: `technique-decode-corrupt-register-words-as-data-to-name-the-writer`

- When a kernel crash shows "impossible" values (a non-canonical pointer in a register, a folio order of 189), the value is usually the BYTES OF WHATEVER OVERWROTE the structure, not a random flip. Decode it before calling the source unknown.
- How: take the 64-bit word, split it in memory order (little-endian on x86), and read it as fp16, bf16, two fp32, ASCII, and small ints. Structured data stands out.
- Worked case: `D-HOST-CLYDE-CRASH-XAS-SPLIT-ALLOC-FOLIO-ORDER-CORRUPT-0901A` (clyde host panic 2026-09-01) carried RSI `0xc1d8c166c1c7c1d1` and `0xc21dc0d8c0fcc209` for two months as "neither a valid kernel pointer, source unproven". Decoded, each is four fp16 values, all negative in a -2.4..-3.1 band (log-probability shaped tensor data). Eight halves with top byte 0xc0-0xc2 occur by chance ~1e-15. That was the direct evidence that disposed the record: ML tensor data over the `radix_tree_node` slab; mxfs never loads on the host.
- Why two unrelated processes hit it in the same millisecond: `xa_get_order` adds `xa_node->shift`, so a garbage `order` in `__filemap_add_folio` means the shared radix-tree node slab was overwritten.
- Why it matters: the record was mis-disposed once on another crash's evidence, then sat open as "unknown corrupter"; the answer was in the registers already transcribed.
- Transcribe register dumps verbatim when filing a host crash. The archived dmesg and pstore copies of that crash were later found deleted (empty `/var/lib/systemd/pstore/<id>/` dirs, no `.evidence/crash_*`), and the transcription was the only surviving copy.
- Found session 36 (run 7e16fd1d).
