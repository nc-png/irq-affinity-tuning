# irq-affinity-auto.sh

NUMA-aware IRQ affinity pinning for high-bandwidth NICs (100GE and up, including 2×100GE bonds).

Knows Mellanox ConnectX-3 (`mlx4_core`), ConnectX-6 (`mlx5_core`) and Chelsio T62100 (`cxgb4`); other drivers get the generic treatment.

## Run

```
sudo ./irq-affinity-auto.sh [--reduce-queues] [--dry-run] [--verbose]
```

```
Usage: ./irq-affinity-auto.sh [--reduce-queues] [--dry-run] [--verbose]
Non-dry runs write a rollback script to /tmp/irq/restore_<date>_<time>.sh
```

Run it once with `--dry-run` first — it prints exactly what it would change and touches nothing. Everything (dry or not) is appended to `/var/log/irq-affinity.log`.

`--reduce-queues` additionally shrinks each NIC's channel count (`ethtool -L`) to match the cores it was allocated. Off by default because it briefly bounces the queues.

Root required, enforced. Needs `ethtool` and `python3` on PATH; `lspci` and `ovs-appctl` are optional (the phases that use them skip cleanly if missing).

## Runtime

A non-dry run changes five things, in this order:

1. Stops `irqbalance`
2. Queue counts via `ethtool -L` (only with `--reduce-queues`)
3. `/proc/irq/*/smp_affinity_list` for every MSI-X vector of every discovered NIC, spread across physical cores of the NIC's own NUMA node (CPU0 excluded)
4. XPS masks (`/sys/class/net/*/queues/tx-*/xps_cpus`) — skipped for `mlx5_core`, which manages XPS itself, and for bond slaves, where XPS was measured to cost ~25% throughput on mlx4
5. Ring buffers to hardware max plus adaptive-rx coalescing via `ethtool -G`/`-C`

Everything after that (phases 7–17: FEC, PCIe MaxReadReq, offloads, sysctls, conntrack, RDMA, and so on) is read-only diagnostics — current value, recommended value, `[OK]`/`[LOW]`/`[WARN]` tag, and the exact command to fix it yourself. The script deliberately never applies those.

## Rollback

Every non-dry run writes `/tmp/irq/restore_<YYYYmmdd>_<HHMMSS>.sh` capturing the pre-run value of everything in the list above. Run it to restore. 

## Known sharp edges

- **cxgb4 refuses ring resizes at runtime** (`EBUSY` once the adapter is up). The script can't work around that live; it prints a ready-to-paste systemd `.link` file that applies the ring size before the driver opens the port. That's the one change it can't do for you.
- Bond slaves sharing a PCI function with another interface are deduplicated by role priority, so the slave wins even if it's link-down at run time. If a NIC you expected is missing from Phase 2 output, check there first.
- The script is one-shot and does not survive reboots nor NIC driver reloads.

## Phases

For reading the output, the run is numbered 1–17. Short version:

| Phase | Does |
|---|---|
| 1–3 | NUMA topology, NIC discovery (bond/OVS/bridge role detection), core allocation weighted by role |
| 3b | Queue reduction (`--reduce-queues` only) |
| 4, 4b | IRQ pinning, XPS |
| 5 | Verification — re-reads what was just written |
| 6 | Ring buffers + adaptive-rx (last phase that writes anything) |
| 7–17 | Diagnostics: link/FEC, PCIe, offloads, kernel tunables, bond RFS, system health, rings/coalescing report, RSS indirection, conntrack, memory/sysctls, RDMA/RoCE/XDP |

Bond-related phases skip themselves on machines with no bonds. Core allocation gives bond slaves and OVS bonds weight 3 and everything else weight 2, so the forwarding path gets more cores when they're contended.
