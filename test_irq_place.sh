#!/bin/bash
# Self-check for data-queue-first IRQ placement (Phase 1 spare pool +
# Phase 4).  Fixture: the o1 box — cxgb4 T62100 at 0000:08:00.4, 185
# vectors, 16 "ext1 (queue N)" data IRQs 252-267, sibling port ext0 down,
# NUMA 0 = cores 0-13 + siblings 28-41, run with --softirq-siblings.
# Expected: 16 distinct CPUs = siblings 28-41 (14) + primaries 13,12.
set -uo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ── fixtures ────────────────────────────────────────────────────────────────
mkdir -p "$T/node0"; echo "0-13,28-41" > "$T/node0/cpulist"
{
    printf '%4d: %s IR-PCI-MSIX-0000:08:00.4 %d-edge %s\n' 234 "$(seq -s' ' 0 0 | sed 's/.*/1 2 3/')" 0 "0000:08:00.4"
    printf '%4d: 1 2 3 IR-PCI-MSIX-0000:08:00.4 1-edge 0000:08:00.4-FWeventq\n' 235
    for q in $(seq 0 15); do printf '%4d: 1 2 3 IR-PCI-MSIX-0000:08:00.4 %d-edge ext0 (queue %d)\n' $((236+q)) $((2+q)) $q; done
    for q in $(seq 0 15); do printf '%4d: 1 2 3 IR-PCI-MSIX-0000:08:00.4 %d-edge ext1 (queue %d)\n' $((252+q)) $((18+q)) $q; done
    for i in $(seq 0 63);  do printf '%4d: 1 2 3 IR-PCI-MSIX-0000:08:00.4 %d-edge 0000:08:00.4-ofld%d\n' $((268+i)) $((34+i)) $i; done
    for i in $(seq 0 86);  do printf '%4d: 1 2 3 IR-PCI-MSIX-0000:08:00.4 %d-edge 0000:08:00.4-uld%d\n' $((332+i)) $((98+i)) $i; done
} > "$T/interrupts"
[[ $(wc -l < "$T/interrupts") -eq 185 ]] || { echo "FAIL fixture: $(wc -l < "$T/interrupts") lines"; exit 1; }

# ── mocks: topology helpers from sysfs → fixture ─────────────────────────────
eval "$(sed -n '/^expand_cpulist/,/^}/p' irq-affinity-auto.sh)"
is_physical_core() { [[ $1 -lt 14 ]]; }
ht_sibling() { [[ $1 -lt 14 ]] && echo $(( $1 + 28 )) || echo "$1"; }
pin() { echo "$1:$2" >> "$T/pins"; }

# ── Phase 1 (spare pool) against the fixture node ────────────────────────────
OPT_SIBLINGS=1 OPT_DRY=1 OPT_VERBOSE=0
declare -A NUMA_AVAIL_CORES NUMA_SPARE
phase1=$(sed -n '/^for node_dir in \/sys\/devices\/system\/node/,/^done$/p' irq-affinity-auto.sh \
         | sed "s|/sys/devices/system/node/node\[0-9\]\*/|$T/node[0-9]*/|")
eval "$phase1" >/dev/null
[[ "${NUMA_AVAIL_CORES[0]}" == "$(seq -s' ' 29 41)" ]] || { echo "FAIL pool: ${NUMA_AVAIL_CORES[0]}"; exit 1; }
[[ "$(echo ${NUMA_SPARE[0]})" == "28 $(seq -s' ' 13 -1 0)" ]] || { echo "FAIL spare: ${NUMA_SPARE[0]}"; exit 1; }

# ── Phase 4 against the fixture /proc/interrupts ─────────────────────────────
NICS=(ext1)
declare -A NIC_PCI=([ext1]=0000:08:00.4) NIC_NUMA=([ext1]=0) NIC_ROLE=([ext1]=bond_slave)
declare -A NIC_IRQS=([ext1]="$(seq -s' ' 234 418)") NIC_CORES=([ext1]="${NUMA_AVAIL_CORES[0]}")
phase4=$(sed -n '/^echo "=== Phase 4: IRQ Pinning ==="/,/^done$/p' irq-affinity-auto.sh \
         | sed "s|/proc/interrupts|$T/interrupts|")
eval "$phase4" > "$T/out"

data_cpus=$(awk -F: '$1>=252 && $1<=267 {print $2}' "$T/pins")
[[ "$(echo $data_cpus)" == "$(seq -s' ' 29 41) 28 13 12" ]] \
    || { echo "FAIL data placement: $(echo $data_cpus)"; exit 1; }
[[ $(echo "$data_cpus" | sort -u | wc -l) -eq 16 ]] || { echo "FAIL: data queues doubled"; exit 1; }
[[ $(wc -l < "$T/pins") -eq 185 ]] || { echo "FAIL: pinned $(wc -l < "$T/pins") of 185"; exit 1; }
[[ "${NIC_CORES[ext1]}" == "$(seq -s' ' 29 41) 28 13 12" ]] || { echo "FAIL NIC_CORES: ${NIC_CORES[ext1]}"; exit 1; }
grep -q '^  data  IRQ 267   → CPU 12   ext1 (queue 15)$' "$T/out" || { echo "FAIL table:"; tail -3 "$T/out"; exit 1; }
# ext0's 16 queues (sibling port, down) must NOT be treated as data
grep -q '16 data + 169 other' "$T/out" || { echo "FAIL classify:"; grep OK "$T/out"; exit 1; }

echo "PASS: 16 cxgb4 data queues on 16 distinct threads (29-41, 28, 13, 12), ext0's queues in the rest bucket, 185/185 pinned"
