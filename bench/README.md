# MeshXFS performance

Every MeshXFS release is measured on each shared-LUN configuration it ships.
The tables below are those measurements, copied from the release boards by
`tools/bench_report.py`; the release checks refuse to publish a release whose
page differs from its boards.

## What is measured

On each configuration, every node runs the same four fio workloads at the
same time, each node writing and reading its own file on the shared MeshXFS
mount (`tests/suite/fio_perf.sh`):

| Workload | Block size | I/O |
|---|---|---|
| Sequential write | 1 MiB | O_DIRECT, libaio, queue depth 32 |
| Sequential read | 1 MiB | O_DIRECT, libaio, queue depth 32 |
| Random write | 4 KiB | O_DIRECT, libaio, queue depth 32 |
| Random read | 4 KiB | O_DIRECT, libaio, queue depth 32 |

Each figure is the whole cluster's throughput: the sum over its nodes. The
percentage beside it is that sum against native XFS mounted on one node, on
the same LUN, over the same path, on the same hardware
(`tests/suite/fio_perf_vs_xfs.sh`). At 100% the cluster together moves as much
as one native XFS mount of that LUN.

The test hardware: each node is a KVM virtual machine on one host, and the
shared LUN is served to the nodes by an SCST iSCSI target on that host. A
single-path configuration reaches the LUN over one iSCSI session per node; a
multipath one over two, assembled by dm-multipath. On a shared SAN LUN the
nodes take every cluster lock with SCSI COMPARE AND WRITE on the LUN itself;
over the TCP lock network they exchange locks with each other instead.

## Results

<!-- bench_report: start (written by tools/bench_report.py from the release boards; edit the tool, not this table) -->
#### Shared SAN LUN, single path

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 1,780 MiB/s (157%) | 2,542 MiB/s (196%) | 66,953 IOPS (152%) | 84,566 IOPS (196%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 4 | 1,924 MiB/s (169%) | 4,038 MiB/s (312%) | 135,283 IOPS (307%) | 130,172 IOPS (301%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 8 | 1,954 MiB/s (172%) | 5,005 MiB/s (387%) | 245,526 IOPS (557%) | 251,502 IOPS (583%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 16 | 3,096 MiB/s (273%) | 3,526 MiB/s (273%) | 387,928 IOPS (880%) | 411,321 IOPS (953%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |

#### Shared SAN LUN, multipath

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 2,043 MiB/s (190%) | 1,873 MiB/s (139%) | 56,448 IOPS (112%) | 73,393 IOPS (164%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 4 | 1,286 MiB/s (120%) | 3,391 MiB/s (253%) | 103,056 IOPS (205%) | 152,403 IOPS (341%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 8 | 1,918 MiB/s (179%) | 3,738 MiB/s (278%) | 191,224 IOPS (381%) | 276,573 IOPS (619%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 16 | 5,118 MiB/s (477%) | 4,688 MiB/s (349%) | 316,313 IOPS (631%) | 450,905 IOPS (1010%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |

#### Shared LUN over the TCP lock network, single path

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 1,926 MiB/s (145%) | 2,167 MiB/s (162%) | 65,820 IOPS (167%) | 66,524 IOPS (140%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 4 | 1,979 MiB/s (149%) | 4,402 MiB/s (330%) | 136,237 IOPS (347%) | 146,429 IOPS (310%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 8 | 3,123 MiB/s (235%) | 6,001 MiB/s (450%) | 256,085 IOPS (653%) | 251,793 IOPS (533%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 16 | 2,508 MiB/s (189%) | 7,022 MiB/s (527%) | 386,467 IOPS (985%) | 324,098 IOPS (686%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |

#### Shared LUN over the TCP lock network, multipath

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 1,901 MiB/s (135%) | 2,580 MiB/s (199%) | 57,691 IOPS (113%) | 76,740 IOPS (160%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 4 | 1,744 MiB/s (124%) | 3,361 MiB/s (259%) | 108,786 IOPS (214%) | 137,075 IOPS (286%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 8 | 2,700 MiB/s (192%) | 5,081 MiB/s (392%) | 197,297 IOPS (388%) | 219,884 IOPS (459%) | 71AC6107043DD5BE3D9181A, 2026-10-21 |
| 16 | 2,528 MiB/s (180%) | 12,286 MiB/s (949%) | 278,732 IOPS (548%) | 429,719 IOPS (898%) | B0D2E3F5A70C96237681DF2, 2026-10-20 |
<!-- bench_report: end -->

## Running it

On the lab rig these rows run through the suite runner, one configuration at
a time; the native-XFS baseline is captured once per rig and path with
`./run.sh 1/xfs fio_perf` (the exact command is in the header of
`tests/suite/fio_perf_vs_xfs.sh`):

```
./run.sh 2/disk/caw/direct fio_perf fio_perf_vs_xfs   # one configuration's rows
tools/criteria.py 2/disk/caw/direct                   # the board they land on
tools/bench_report.py                                 # rewrite the tables above from the boards
```
