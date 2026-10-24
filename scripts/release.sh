#!/bin/bash
#
# MeshXFS — build every release package, and optionally publish a GitHub release
#
# Usage: scripts/release.sh                       build the packages (tools/release_run.py's
#                                                  packages step, into $MXFS_DIST)
#        scripts/release.sh --publish --candidate ID [--notes-file FILE] [--target COMMIT]
#
# --publish publishes ONLY a QUALIFIED release candidate (tools/release_candidate.py,
# tools/release_run.py, docs/release-process.md): its packages, unchanged since
# qualification ran on them, with every frozen file unchanged, every step passed,
# no incident unaccounted for and the release table's gate passing.  The checks
# below that predate candidates (the version-keyed DRBD evidence, the platform
# registry's records) are the candidate's own steps now.
#
# Builds into dist/<version>/:
#   mxfs_<v>_amd64.deb              Debian / Ubuntu / Proxmox (DKMS + tools)
#   pve-storage-mxfs_<v>_all.deb    Proxmox VE storage plugin
#   mxfs-<v>-1.el9.x86_64.rpm       RHEL / AlmaLinux / Rocky 9 (DKMS + tools)
#   SHA256SUMS                      every published package
#
# Each package is built on a lab VM of the OLDEST distribution it targets,
# built here with mkosimage, never on the host and never in a container
# (scripts/vm_package_build.sh).  The userspace tools are linked against the
# build system's glibc and refuse to start on an older one: built on the
# Ubuntu 24.04 host, mkfs.mxfs and chk_mxfs require GLIBC_2.38, which
# Debian 12 (2.36) and RHEL 9 (2.34) do not have.  The .debs are built on
# the debian12 node (Debian 12+, Ubuntu 24.04+, Proxmox VE 9), the .rpm on
# the rhel9 node.  Until 0.90.130 they were built in docker containers from
# downloaded images (debian:bookworm, almalinux:8).
#
# Before anything else, tools/release_text_check.py must pass: the README, the
# manual pages, the module-options file and the module's parameter text are
# checked against the release data, and a disagreement stops the run.
#
# --publish creates GitHub release v<version> on sshoecraft/meshxfs with the
# packages attached.  If dist/<version>/ already holds a build, --publish
# checks it against its SHA256SUMS and publishes it without rebuilding.  Release notes are this version's CHANGELOG.md section
# unless --notes-file is given.  Commit and push first: the tag is created
# on the remote's main.
#
# --version V publishes the existing build in dist/V/ when the tree has
# already moved on to a later VERSION (work committed after V was verified).
# It never builds: the source that made dist/V/ is no longer the tree's, so a
# build now would be a different, unverified package carrying V's number.
#
# --target COMMIT tags the release on that pushed commit instead of main.
# With --version, name the commit V was built and verified from, so the tag's
# source is the packages' source and not the later work on main.
#

set -e

SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SRCDIR/packaging/common.sh"

REPO="sshoecraft/meshxfs"

publish=0
notes=""
version=""
candidate=""
target=main
while [ $# -gt 0 ]; do
    case "$1" in
        --publish) publish=1 ;;
        --notes-file) notes="$2"; shift ;;
        --version) version="$2"; shift ;;
        --target) target="$2"; shift ;;
        --candidate) candidate="$2"; shift ;;
        *) echo "usage: $0 [--publish --candidate ID] [--notes-file FILE] [--target COMMIT]" >&2; exit 2 ;;
    esac
    shift
done

# PUBLISHING NEEDS A QUALIFIED RELEASE CANDIDATE (tools/release_candidate.py,
# tools/release_run.py; docs/release-process.md).  The candidate's manifest
# names the packages qualification ran on, their hashes, and the frozen files
# behind them; the publisher checks all of it and decides nothing else.
# 0.90.131 was published while checks on its build were still running.
if [ "$publish" = 1 ]; then
    [ -n "$candidate" ] || { echo "ERROR: --publish needs --candidate <id>: a release is published only from a QUALIFIED candidate" >&2; exit 2; }
    python3 - "$SRCDIR" "$candidate" <<'PYEOF' || exit 1
import json, subprocess, sys
from pathlib import Path
root, cid = Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, str(root / "tools"))
import release_candidate
m = release_candidate.load(cid)
bad = []
if m["state"] != "QUALIFIED":
    bad.append(f"candidate {cid} is {m['state']}, not QUALIFIED")
if m.get("dry_run"):
    bad.append(f"candidate {cid} is a dry run")
drift = release_candidate.drift(m)
if drift:
    bad.append(f"{len(drift)} frozen file(s) changed since qualification: " + "; ".join(drift[:5]))
dist = root / m.get("dist", "")
sums = dist / "SHA256SUMS"
if not m.get("dist") or not sums.is_file():
    bad.append(f"no packages for {cid} ({m.get('dist')})")
else:
    got = {l.split()[1]: l.split()[0] for l in sums.read_text().splitlines() if l.strip()}
    if got != m.get("packages"):
        bad.append(f"{sums} does not list the packages qualification ran on")
    for name, digest in (m.get("packages") or {}).items():
        path = dist / name
        if not path.is_file() or release_candidate.sha256(path) != digest:
            bad.append(f"{name} is not the package qualification ran on")
for step, state in (m.get("steps") or {}).items():
    if state.get("outcome") != "PASS":
        bad.append(f"step {step} is {state.get('outcome')}")
for args in (["tools/criteria.py", "incidents"],
             ["tools/release_status.py", "--candidate", cid, "--gate"]):
    if subprocess.run([sys.executable, *args], cwd=root, capture_output=True).returncode != 0:
        bad.append(" ".join(args) + " does not pass")
for line in bad:
    print("ERROR:", line, file=sys.stderr)
sys.exit(1 if bad else 0)
PYEOF
    version=$(jq -r '.version' "$SRCDIR/data/candidates/$candidate.json")
fi

VERSION=${version:-$(mxfs_version)}
# A release candidate's packages are built into dist/<version>/ (tools/release_run.py
# passes MXFS_DIST, and clears an earlier unpublished attempt's build first); a
# published candidate's are found through its manifest.
if [ -n "$candidate" ]; then
    OUT="$SRCDIR/$(jq -r '.dist' "$SRCDIR/data/candidates/$candidate.json")"
else
    OUT="$SRCDIR/${MXFS_DIST:-dist/$VERSION}"
fi
if [ -n "$version" ] && { [ "$publish" = 0 ] || [ ! -f "$OUT/SHA256SUMS" ]; }; then
    echo "ERROR: --version publishes an existing build only: needs --publish and $OUT/SHA256SUMS" >&2
    exit 1
fi

built=0
if [ -f "$OUT/SHA256SUMS" ]; then
    if [ "$publish" = 0 ]; then
        echo "ERROR: $OUT already holds a build; remove it to rebuild $VERSION" >&2
        exit 1
    fi
    # Publish what was built and inspected, never a silent rebuild of it.
    (cd "$OUT" && sha256sum -c SHA256SUMS) || {
        echo "ERROR: $OUT does not match its SHA256SUMS" >&2
        exit 1
    }
    built=1
fi
mkdir -p "$OUT"


# The text a user reads must say what the release data says, before anything is
# built from it and again before it is published: the README, the manual pages
# and the installed module-options file go into the packages.  Two releases
# shipped describing released configurations as unreleased or unverified.
# A release candidate's packages are built before anything is verified on
# them, so only the text they ship is checked here; the README's release
# claims and the benchmark page are written when the version is released and
# are checked at sealing and at publication.
textargs=()
if [ "$publish" = 1 ]; then
    textargs=(--candidate "$candidate")
elif [ -n "${MXFS_CANDIDATE:-}" ]; then
    textargs=(--before-build)
fi
python3 "$SRCDIR/tools/release_text_check.py" "${textargs[@]}" || {
    echo "ERROR: the public text disagrees with the release data (lines above); fix the text, then run this again" >&2
    exit 1
}

if [ "$built" = 0 ]; then
    # Every platform a release claims (data/platforms.json, status released)
    # must compile the module before any package is built: the rig's kernel
    # is not the product's, and 0.89.77 shipped a .deb that failed on Proxmox.
    # A check's stdin is /dev/null: the checks run ssh, which would otherwise
    # read the rest of the list from the loop's here-string and end the loop
    # after the first platform without a word.
    checks=$(python3 "$SRCDIR/tools/platforms.py" build-checks) || exit 1
    while IFS= read -r check; do
        [ -n "$check" ] || continue
        echo "=== MeshXFS $VERSION — platform build check: $check ==="
        (cd "$SRCDIR" && eval "$check" < /dev/null) || {
            echo "ERROR: '$check' failed; no packages built" >&2
            exit 1
        }
    done <<< "$checks"

    echo "=== MeshXFS $VERSION — .deb packages on the debian12 lab node ==="
    "$SRCDIR/scripts/vm_package_build.sh" deb "$OUT" || { echo "ERROR: the .deb build failed; no release" >&2; exit 1; }

    echo "=== MeshXFS $VERSION — .rpm package on the rhel9 lab node ==="
    "$SRCDIR/scripts/vm_package_build.sh" rpm "$OUT" || { echo "ERROR: the .rpm build failed; no release" >&2; exit 1; }

    (cd "$OUT" && sha256sum *.deb *.rpm > SHA256SUMS)

    echo ""
    echo "=== Built in $OUT ==="
    ls -l "$OUT"
fi

[ "$publish" = 1 ] || exit 0
# Every platform, the DRBD rig and the Proxmox kernels were verified as steps of
# the candidate's qualification, checked above with the rest of its manifest.

if [ -z "$notes" ]; then
    notes="$OUT/CHANGELOG_NOTES.md"
    awk -v v="$VERSION" '
        /^## / { if (found) exit; if (index($0, "— " v " —")) found = 1 }
        found' "$SRCDIR/CHANGELOG.md" > "$notes"
    if [ ! -s "$notes" ]; then
        echo "ERROR: no CHANGELOG.md section for $VERSION; pass --notes-file" >&2
        exit 1
    fi
fi

# The title carries the version's banner, the third field of its CHANGELOG.md
# heading ("## <date> — <version> — <banner>"), which GPT writes from that section.
banner=$(awk -v v="$VERSION" '/^## / && index($0, "— " v " —") { sub(/^## [^—]*— [^—]*— /, ""); print; exit }' "$SRCDIR/CHANGELOG.md")
[ -n "$banner" ] || { echo "ERROR: CHANGELOG.md's heading for $VERSION has no banner" >&2; exit 1; }
gh release create "v$VERSION" -R "$REPO" --target "$target" \
    --title "MeshXFS $VERSION — $banner" --notes-file "$notes" \
    "$OUT"/*.deb "$OUT"/*.rpm "$OUT/SHA256SUMS"

# What the release now is, recorded from the candidate it was published from:
# its state, each platform's verification at this version, and the module
# build each kernel ran (data/release_builds.json, which the release table and
# the benchmark page read).
python3 - "$SRCDIR" "$candidate" <<'PYEOF'
import json, subprocess, sys
from pathlib import Path
root, cid = Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, str(root / "tools"))
import release_candidate
m = release_candidate.load(cid)
release_candidate.move(m, "PUBLISHED", f"published as v{m['version']}")
# the platforms step's own log, named by the attempt that qualified
log = m["steps"]["platforms"]["evidence"]
platforms = json.loads((root / "data/platforms.json").read_text())["platforms"]
for key, info in platforms.items():
    if info.get("status") == "released":
        subprocess.run([sys.executable, "tools/platforms.py", "verify", key, "--version",
                        m["version"], "--evidence", log], cwd=root, check=False)
builds_path = root / "data/release_builds.json"
builds = json.loads(builds_path.read_text())
rig_kernel = dict(kv.split("=", 1) for kv in (root / "tools/.built_for").read_text().split()
                  if "=" in kv).get("kernel")
entry = builds.setdefault(m["version"], {})
if rig_kernel:
    entry[rig_kernel] = m["srcversion"]
entry.update(m.get("kernels") or {})
builds_path.write_text(json.dumps(builds, indent=2) + "\n")
print(f"recorded {cid} as published: platforms verified at {m['version']}, builds {entry}")
PYEOF
