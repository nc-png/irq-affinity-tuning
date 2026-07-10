#!/bin/bash
# Self-check for Phase 3 core allocation, incl. --overlap-cores.
# Extracts the live Phase 3 block from irq-affinity-auto.sh and runs it
# against the ext0/ext2/ext4 topology from a real 2-node box.
set -uo pipefail
cd "$(dirname "$0")"

phase3=$(sed -n '/^declare -A NODE_NICS/,/^# ====/p' irq-affinity-auto.sh | sed '$d')

run() { # <OPT_OVERLAP>
    OPT_OVERLAP=$1
    NICS=(ext0 ext2 ext4)
    declare -A NIC_NUMA=([ext0]=0 [ext2]=0 [ext4]=1)
    declare -A NIC_ROLE=([ext0]=bond_slave [ext2]=bond_slave [ext4]=bond_slave)
    declare -A NIC_SPEED=([ext0]=40000 [ext2]=100000 [ext4]=100000)
    declare -A NIC_IRQS=([ext0]="$(seq -s' ' 100 132)" [ext2]="$(seq -s' ' 200 263)" [ext4]="$(seq -s' ' 300 333)")
    declare -A NUMA_AVAIL_CORES=([0]="$(seq -s' ' 1 15)" [1]="$(seq -s' ' 17 31)")
    declare -A NIC_CORES=()
    nic_weight() { local s=${NIC_SPEED[$1]}; [[ $s -ge 100000 ]] && echo 12 || echo 3; }
    eval "$phase3" >/dev/null
    echo "${NIC_CORES[ext0]}|${NIC_CORES[ext2]}|${NIC_CORES[ext4]}"
}

out=$(run 0)
[[ "$out" == "1 2 3|4 5 6 7 8 9 10 11 12 13 14 15|$(seq -s' ' 17 31)" ]] \
    || { echo "FAIL default: $out"; exit 1; }

out=$(run 1)
[[ "$out" == "1 2 3|$(seq -s' ' 1 15)|$(seq -s' ' 17 31)" ]] \
    || { echo "FAIL overlap: $out"; exit 1; }

echo "PASS: default partitions exclusively; --overlap-cores gives ext2 the full NUMA0 pool, ext0 keeps 1-3, single-NIC node unchanged"

# --softirq-siblings: ht_sibling must agree with lscpu on the real topology
# (highest CPU per NODE+CORE pair; own CPU when SMT is off).
eval "$(sed -n '/^expand_cpulist/,/^}/p; /^ht_sibling/,/^}/p' irq-affinity-auto.sh)"
while read -r cpu node core; do
    want=$(lscpu -e=CPU,NODE,CORE | awk -v n="$node" -v c="$core" '$2==n && $3==c {m=$1>m?$1:m} END{print m}')
    got=$(ht_sibling "$cpu")
    [[ "$got" == "$want" ]] || { echo "FAIL ht_sibling cpu$cpu: got $got want $want"; exit 1; }
done < <(lscpu -e=CPU,NODE,CORE | tail -n +2)
echo "PASS: ht_sibling matches lscpu for all $(nproc) CPUs"
