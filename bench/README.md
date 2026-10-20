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
| 2 | 1,838 MiB/s (162%) | 2,055 MiB/s (159%) | 69,375 IOPS (157%) | 87,891 IOPS (203%) | 292B547486AE6E75317F308, 2026-10-20 |
| 4 | 1,814 MiB/s (160%) | 3,573 MiB/s (276%) | 135,417 IOPS (307%) | 151,361 IOPS (351%) | 292B547486AE6E75317F308, 2026-10-20 |
| 8 | 1,274 MiB/s (112%) | 7,175 MiB/s (555%) | 246,065 IOPS (558%) | 249,925 IOPS (579%) | 292B547486AE6E75317F308, 2026-10-20 |
| 16 | 4,042 MiB/s (356%) | 3,957 MiB/s (306%) | 389,745 IOPS (884%) | 430,179 IOPS (997%) | 292B547486AE6E75317F308, 2026-10-20 |

#### Shared SAN LUN, multipath

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 2,031 MiB/s (189%) | 2,216 MiB/s (165%) | 54,598 IOPS (108%) | 79,071 IOPS (177%) | 292B547486AE6E75317F308, 2026-10-20 |
| 4 | 1,717 MiB/s (160%) | 2,881 MiB/s (215%) | 101,835 IOPS (203%) | 134,923 IOPS (302%) | 292B547486AE6E75317F308, 2026-10-20 |
| 8 | 1,782 MiB/s (166%) | 4,675 MiB/s (348%) | 183,800 IOPS (366%) | 278,795 IOPS (624%) | 292B547486AE6E75317F308, 2026-10-20 |
| 16 | 3,691 MiB/s (344%) | 4,327 MiB/s (322%) | 352,181 IOPS (702%) | 444,039 IOPS (994%) | 292B547486AE6E75317F308, 2026-10-20 |

#### Shared LUN over the TCP lock network, single path

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 1,951 MiB/s (147%) | 2,578 MiB/s (193%) | 70,472 IOPS (179%) | 90,416 IOPS (191%) | 292B547486AE6E75317F308, 2026-10-20 |
| 4 | 1,944 MiB/s (146%) | 4,469 MiB/s (335%) | 147,337 IOPS (375%) | 167,622 IOPS (355%) | B0D2E3F5A70C96237681DF2, 2026-10-20 |
| 8 | 2,190 MiB/s (165%) | 4,442 MiB/s (333%) | 244,370 IOPS (623%) | 261,798 IOPS (554%) | B0D2E3F5A70C96237681DF2, 2026-10-20 |
| 16 | 2,348 MiB/s (177%) | 5,307 MiB/s (398%) | 349,558 IOPS (891%) | 437,276 IOPS (926%) | B0D2E3F5A70C96237681DF2, 2026-10-20 |

#### Shared LUN over the TCP lock network, multipath

| Nodes | Sequential write | Sequential read | Random write | Random read | Measured |
|---:|---:|---:|---:|---:|:---|
| 2 | 2,220 MiB/s (158%) | 1,982 MiB/s (153%) | 58,509 IOPS (115%) | 65,533 IOPS (136%) | 292B547486AE6E75317F308, 2026-10-20 |
| 4 | 2,389 MiB/s (170%) | 3,117 MiB/s (240%) | 104,619 IOPS (205%) | 165,992 IOPS (347%) | B0D2E3F5A70C96237681DF2, 2026-10-20 |
| 8 | 2,198 MiB/s (156%) | 5,884 MiB/s (454%) | 173,117 IOPS (340%) | 261,980 IOPS (547%) | B0D2E3F5A70C96237681DF2, 2026-10-20 |
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
