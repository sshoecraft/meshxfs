---
name: trap-packaged-text-fixed-before-boards-decide-claims
description: The release chain builds packages (man pages, modprobe.conf) AFTER the boards but claims change from board results; packaged text must state no per-v…
metadata:
  type: feedback
---

**Trap:** `tests/release_verify_chain.sh` runs the boards, then `full_verify` packages,platforms. The packages carry `docs/man/man5/mxfs.5` and `packaging/mxfs-modprobe.conf`. Which configurations a release can claim is only known once the boards finish (e.g. 0.90.131: 4/8/16 net/mesh failed on the release candidate and had to stay unclaimed). If a packaged page says "TCP released for two and four nodes" or "TCP on mpath last verified in 0.90.130", any change of claims after the package step leaves the shipped page wrong, and editing it means a new chain (an edit after the chain's build step breaks "verified build = published build").

**Rule of thumb:** packaged pages name no per-version claim. They say both transports are released "at two to sixteen nodes" (the text check requires the largest size to be named) and point at the README for which configurations and which version verified each. The README and data/configurations.json are not packaged and can be edited after the chain.

**Related chain traps fixed in 0.90.131 (session 832bf9ad):** board lanes started together tripped each other's host preflight on SCST login bursts (fixed: board_4node_chain.sh waits for the previous lane's prep line); bench/README.md must be regenerated from the boards before the package step or release.sh's text check refuses to build (fixed: chain step "bench page").
