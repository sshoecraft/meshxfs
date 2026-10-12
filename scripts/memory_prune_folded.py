#!/usr/bin/env python3
"""memory_prune_folded.py — delete the raw ccmemory notes a compiled article
already carries, so the store shrinks instead of only growing.

A `compiled-<topic>` article folds raw notes in and cites each as [[<slug>]].
The compactor never deletes what it folds, so every note survives beside the
article that replaced it: on disk, in the search index and in git.  This
deletes each raw note an article cites, and turns that citation into plain
provenance text (`<slug>`), since there is no longer a file to link to.
Links to files that stay (another compiled article, an uncited note) are left
as they are.  Git history keeps every deleted note.

Usage: scripts/memory_prune_folded.py [--write] [<memory dir>]
  (default dir: .ccmemory beside this script's repo)
Without --write it reports what it would delete and changes nothing.
"""
import os
import re
import sys

LINK = re.compile(r"\[\[([a-z0-9][a-z0-9-]*)\]\]")
TYPE = re.compile(r"^\s*type:\s*(\w+)", re.M)


def main(argv):
    write = "--write" in argv
    rest = [a for a in argv if a != "--write"]
    here = os.path.dirname(os.path.abspath(__file__))
    mdir = rest[0] if rest else os.path.join(here, "..", ".ccmemory")
    names = {f[:-3] for f in os.listdir(mdir) if f.endswith(".md") and f != "MEMORY.md"}
    articles = sorted(n for n in names if n.startswith("compiled-"))

    cited = {}  # raw slug -> the articles that cite it
    for a in articles:
        with open(os.path.join(mdir, a + ".md"), encoding="utf-8") as f:
            text = f.read()
        for slug in LINK.findall(text):
            if slug in names and not slug.startswith("compiled-"):
                cited.setdefault(slug, set()).add(a)

    by_type, size = {}, 0
    for slug in cited:
        p = os.path.join(mdir, slug + ".md")
        size += os.path.getsize(p)
        with open(p, encoding="utf-8") as f:
            m = TYPE.search(f.read(2000))
        t = m.group(1) if m else "?"
        by_type[t] = by_type.get(t, 0) + 1
    print(f"{len(articles)} compiled articles; {len(names) - len(articles)} raw notes; "
          f"{len(cited)} cited by an article ({size} bytes), "
          f"{len(names) - len(articles) - len(cited)} not cited (kept)")
    print("cited, by type: " + ", ".join(f"{t}={n}" for t, n in sorted(by_type.items())))
    if not write:
        return 0

    for a in articles:
        p = os.path.join(mdir, a + ".md")
        with open(p, encoding="utf-8") as f:
            text = f.read()
        new = LINK.sub(lambda m: f"`{m.group(1)}`" if m.group(1) in cited else m.group(0), text)
        if new != text:
            with open(p, "w", encoding="utf-8") as f:
                f.write(new)
    for slug in cited:
        os.remove(os.path.join(mdir, slug + ".md"))
    left = len([f for f in os.listdir(mdir) if f.endswith(".md") and f != "MEMORY.md"])
    print(f"deleted {len(cited)} notes; {left} memory files remain")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
