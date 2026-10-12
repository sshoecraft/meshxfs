#!/usr/bin/env python3
"""rebrand_prose.py — rename the product in prose, never an identifier.

The product is MeshXFS; `mxfs` stays the name of the module, the filesystem
type, the tools, the packages and every symbol.  This rewrites the bare word
MXFS to MeshXFS where it names the product, and leaves alone everything an
admin or the code uses literally:

  - markdown code: fenced blocks and `inline spans`
  - a word joined to a letter, digit, '_', '-', '/' or '.' on either side:
    MXFS_LEASE_..., MXFSPlugin, D-...-MXFS-..., /sys/fs/mxfs, mxfs.ko
  - URLs
  - "MXFS super" / "MXFS superblock": the on-disk structure whose magic
    reads "MXFS", named after the format, not the product

Usage: scripts/rebrand_prose.py [--write] <file> ...
Without --write it prints each change as file:line, old -> new, and a count.
"""
import re
import sys

WORD = re.compile(r"(?<![A-Za-z0-9_\-/.])MXFS(?![A-Za-z0-9_\-/])(?!\.[A-Za-z0-9])(?! super)")
URL = re.compile(r"https?://\S+")
INLINE = re.compile(r"`[^`\n]*`")


def rewrite_line(line, is_md):
    # protect URLs and (in markdown) inline code spans; rewrite only what is left
    keep = [m.span() for m in URL.finditer(line)]
    if is_md:
        keep += [m.span() for m in INLINE.finditer(line)]
    keep.sort()
    out, pos = [], 0
    for a, b in keep:
        if a < pos:
            continue
        out.append(WORD.sub("MeshXFS", line[pos:a]))
        out.append(line[a:b])
        pos = b
    out.append(WORD.sub("MeshXFS", line[pos:]))
    return "".join(out)


def main(argv):
    write = "--write" in argv
    files = [a for a in argv if a != "--write"]
    if not files:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    total = 0
    for path in files:
        is_md = path.endswith(".md")
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        fence = False
        changed = 0
        for i, line in enumerate(lines):
            if is_md and line.lstrip().startswith("```"):
                fence = not fence
                continue
            if fence:
                continue
            new = rewrite_line(line, is_md)
            if new != line:
                changed += len(WORD.findall(line)) - len(WORD.findall(new))
                if not write:
                    print(f"{path}:{i + 1}: {line.strip()[:160]}")
                lines[i] = new
        if write and changed:
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(lines))
        print(f"== {path}: {changed} rename(s){' written' if write and changed else ''}")
        total += changed
    print(f"== total {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
