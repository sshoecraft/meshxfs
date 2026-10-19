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
| 2 | 1,785 MiB/s (157%) | 2,701 MiB/s (209%) | 45,093 IOPS (102%) | 40,060 IOPS (92%) | 0.90.130, 2026-10-16 |
| 4 | 2,673 MiB/s (235%) | 3,447 MiB/s (267%) | 67,659 IOPS (153%) | 77,179 IOPS (179%) | 0.90.130, 2026-10-16 |
| 8 | 2,024 MiB/s (178%) | 3,390 MiB/s (262%) | 139,682 IOPS (317%) | 129,010 IOPS (299%) | 0.90.130, 2026-10-16 |
| 16 | 2,470 MiB/s (218%) | 4,468 MiB/s (346%) | 264,560 IOPS (600%) | 302,887 IOPS (702%) | 0.90.130, 2026-10-16 |

#### Shared SAN LUN, multipath

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 1,899 MiB/s (177%) | 1,972 MiB/s (147%) | 41,241 IOPS (82%) | 47,105 IOPS (105%) | 0.90.130, 2026-10-16 |
| 4 | 1,697 MiB/s (158%) | 3,191 MiB/s (238%) | 71,115 IOPS (141%) | 79,647 IOPS (178%) | 0.90.130, 2026-10-16 |
| 8 | 1,110 MiB/s (103%) | 4,036 MiB/s (301%) | 99,734 IOPS (199%) | 146,345 IOPS (327%) | 0.90.130, 2026-10-16 |
| 16 | 2,713 MiB/s (253%) | 3,227 MiB/s (240%) | 166,546 IOPS (332%) | 250,601 IOPS (561%) | 0.90.130, 2026-10-16 |

#### Shared LUN over the TCP lock network, single path

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 2,075 MiB/s (156%) | 2,333 MiB/s (175%) | 46,576 IOPS (118%) | 47,526 IOPS (100%) | 0.90.130, 2026-10-16 |
| 4 | 3,515 MiB/s (265%) | 4,400 MiB/s (330%) | 86,533 IOPS (220%) | 94,227 IOPS (199%) | 0.90.130, 2026-10-16 |
| 8 | 3,090 MiB/s (233%) | 6,511 MiB/s (489%) | 140,714 IOPS (359%) | 167,096 IOPS (353%) | 0.90.130, 2026-10-16 |
| 16 | 4,602 MiB/s (347%) | 3,320 MiB/s (249%) | 253,766 IOPS (647%) | 282,141 IOPS (597%) | 0.90.130, 2026-10-16 |

#### Shared LUN over the TCP lock network, multipath

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 1,885 MiB/s (134%) | 2,251 MiB/s (173%) | 39,921 IOPS (78%) | 43,544 IOPS (91%) | 0.90.130, 2026-10-16 |
| 4 | 2,053 MiB/s (146%) | 4,629 MiB/s (357%) | 84,933 IOPS (167%) | 88,849 IOPS (185%) | 0.90.130, 2026-10-16 |
| 8 | 2,725 MiB/s (194%) | 3,895 MiB/s (301%) | 139,622 IOPS (274%) | 150,543 IOPS (314%) | 0.90.130, 2026-10-16 |
| 16 | 3,849 MiB/s (274%) | 6,864 MiB/s (530%) | 234,490 IOPS (461%) | 309,207 IOPS (646%) | 0.90.130, 2026-10-16 |
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
