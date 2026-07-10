# irq-affinity-auto.sh

NUMA-aware IRQ affinity pinning for high-bandwidth NICs (100GE and up, including 2×100GE bonds). Knows Mellanox ConnectX-3 (`mlx4_core`), ConnectX-6 (`mlx5_core`) and Chelsio T62100 (`cxgb4`); other drivers get the generic treatment.

## Run

```
sudo ./irq-affinity-auto.sh [--reduce-queues] [--dry-run] [--verbose] [--overlap-cores] [--no-adaptive-rx]
  --overlap-cores   heaviest NIC per NUMA node is pinned across the whole
                    node core pool (overlapping lighter NICs) instead of an
                    exclusive slice — for NICs in different bonds that do
                    not fire at the same time
  --no-adaptive-rx  do not touch interrupt coalescing (leave adaptive-rx as configured)
```

Run it once with `--dry-run` first; it prints exactly what it would change and touches nothing. Everything (dry or not) is appended to `/var/log/irq-affinity.log`.

Root required, enforced. Needs `ethtool` and `python3` on PATH; `lspci` and `ovs-appctl` are optional (the phases that use them skip cleanly if missing).

Flag notes beyond the usage block:

- `--reduce-queues` shrinks each NIC's channel count (`ethtool -L`) to match the cores it was allocated. Off by default because it briefly bounces the queues.
- `--overlap-cores` only kicks in on NUMA nodes shared by several NICs. Default allocation splits the node pool exclusively by weight, which takes cores away from the heavy NIC even when the lighter one next to it belongs to another bond and is idle at the time. With the flag, the heaviest NIC spans the full node pool and the lighter ones keep their exclusive slice. Skip it when the co-located NICs are busy simultaneously — then you're just putting the contention back.
- `--no-adaptive-rx` skips the coalescing write, it does NOT turn adaptive-rx off. If a previous run (or the driver default) already switched it on, clear it once by hand: `ethtool -C <iface> adaptive-rx off rx-usecs 8 tx-usecs 8`, then tune `rx-usecs` against your workload. Phase 13 in the output tells you the current state per NIC.

## What a run changes

Five things, in this order:

1. Stops `irqbalance`
2. Queue counts via `ethtool -L` (only with `--reduce-queues`)
3. `/proc/irq/*/smp_affinity_list` for every MSI-X vector of every discovered NIC, spread across physical cores of the NIC's own NUMA node (CPU0 excluded)
4. XPS masks (`/sys/class/net/*/queues/tx-*/xps_cpus`) — skipped for `mlx5_core`, which manages XPS itself, and for bond slaves, where XPS was measured to cost ~25% throughput on mlx4
5. Ring buffers to hardware max plus adaptive-rx coalescing via `ethtool -G`/`-C` (coalescing skipped with `--no-adaptive-rx`)

Everything after that (phases 7–17: FEC, PCIe MaxReadReq, offloads, sysctls, conntrack, RDMA, and so on) is read-only diagnostics: current value, recommended value, `[OK]`/`[LOW]`/`[WARN]` tag, and the exact command to fix it yourself. The script deliberately never applies those.

## Rollback

Every non-dry run writes `/tmp/irq/restore_<YYYYmmdd>_<HHMMSS>.sh` capturing the pre-run value of everything in the list above. Run it as root to restore.

## Known sharp edges

- **cxgb4 refuses ring resizes at runtime** (`EBUSY` once the adapter is up). The script can't work around that live; it prints a ready-to-paste systemd `.link` file that applies the ring size before the driver opens the port. That's the one change it can't do for you.
- Bond slaves sharing a PCI function with another interface are deduplicated by role priority, so the slave wins even if it's link-down at run time. If a NIC you expected is missing from Phase 2 output, check there first.
- With `--overlap-cores`, two NICs tied for heaviest weight on the same node both get the full pool. Fine for different bonds; wrong if same-bond heavies ever land on one node.
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

Bond-related phases skip themselves on machines with no bonds. Core allocation gives bond slaves and OVS bonds weight 3 and everything else weight 2, so the forwarding path gets more cores when they're contended. `--overlap-cores` layers on top of that as described above.

`test_core_alloc.sh` exercises the Phase 3 allocation logic (extracted live from the script) against a known two-node topology; run it after touching the allocator.
