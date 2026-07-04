#!/bin/bash
# ===========================================================================
# irq-affinity-auto.sh  v5  —  Dynamic NUMA-aware IRQ affinity
#
# v5 fixes:
#   1. /proc/net/bonding/ pre-scan detects bond slaves even when link is down
#   2. Two-pass NIC discovery: gather all interfaces first, then deduplicate
#      by PCI selecting the HIGHEST-PRIORITY role — fixes the bug where a
#      standalone interface (e.g., eth2) sharing a PCI address with a bond
#      slave (ext3) was picked first alphabetically, silently discarding ext3.
#   3. OVS port detection (master == ovs-system → role=ovs_port)
#   4. OVS bond detection via ovs-appctl bond/show (→ role=ovs_bond, weight 3)
#
# Role priority for PCI deduplication (highest wins):
#   bond_slave=4  >  ovs_bond=4  >  bridge_member=3  >  ovs_port=2  >  standalone=1
#
# Core allocation weights:
#   bond_slave / ovs_bond  → 3  (hot forwarding path)
#   bridge_member / ovs_port / standalone → 2
#
# Usage:  ./irq-affinity-auto.sh [--reduce-queues] [--dry-run] [--verbose]
# ===========================================================================
set -uo pipefail
[[ $EUID -ne 0 ]] && { echo "[ERROR] must run as root"; exit 1; }
LOG="/var/log/irq-affinity.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date) ==="

# ── CLI args ──────────────────────────────────────────────────────────────────
OPT_REDUCE=0 OPT_DRY=0 OPT_VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --reduce-queues) OPT_REDUCE=1   ;;
        --dry-run)       OPT_DRY=1      ;;
        --verbose|-v)    OPT_VERBOSE=1  ;;
        --help|-h)
            echo "Usage: $0 [--reduce-queues] [--dry-run] [--verbose]"
            echo "Non-dry runs write a rollback script to /tmp/irq/restore_<date>_<time>.sh"
            exit 0 ;;
    esac
done
[[ $OPT_DRY -eq 1 ]] && echo "[DRY RUN] No changes will be applied"

# ── Restore script ────────────────────────────────────────────────────────────
# Every runtime write below snapshots the previous value into a rollback script
# so a bad tuning run can be reverted without a reboot.
RESTORE="" IRQBALANCE_RESTORE=""
if [[ $OPT_DRY -eq 0 ]]; then
    # Atomic create (no -p): fails if /tmp/irq exists as anything, including a
    # symlink — no check-then-create race. A pre-existing dir is accepted only
    # if it is already a root-owned real directory; root-owned entries in
    # sticky /tmp cannot be swapped out by other users afterwards.
    if ! mkdir -m 700 /tmp/irq 2>/dev/null; then
        if [[ -L /tmp/irq || ! -d /tmp/irq || "$(stat -c '%u' /tmp/irq)" != "0" ]]; then
            echo "[ERROR] /tmp/irq exists and is not a root-owned directory — refusing to write restore script"
            exit 1
        fi
        chmod 700 /tmp/irq
    fi
    RESTORE="/tmp/irq/restore_$(date +%Y%m%d_%H%M%S).sh"
    (
        set -o noclobber
        {
            echo "#!/bin/bash"
            echo "# Rollback for irq-affinity-auto.sh run of $(date)"
            echo "# Restores pre-run values in write order: queue counts, IRQ affinity,"
            echo "# XPS masks, rings/coalescing, then irqbalance (last, so it can rebalance"
            echo "# any IRQs recreated by a queue-count restore). Lines fail independently."
            echo "[[ \$EUID -ne 0 ]] && { echo 'run as root'; exit 1; }"
        } > "$RESTORE"
    ) || { echo "[ERROR] could not create $RESTORE (already exists?)"; exit 1; }
    chmod 700 "$RESTORE"
    echo "[OK] restore script: $RESTORE"
fi
snap() { [[ -n "$RESTORE" ]] && echo "$*" >> "$RESTORE" || true; }

# ── Stop irqbalance ───────────────────────────────────────────────────────────
[[ $OPT_DRY -eq 0 ]] && {
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        IRQBALANCE_RESTORE="systemctl unmask irqbalance; systemctl enable irqbalance; systemctl start irqbalance"
    elif systemctl is-enabled --quiet irqbalance 2>/dev/null; then
        IRQBALANCE_RESTORE="systemctl unmask irqbalance; systemctl enable irqbalance"
    fi
    systemctl stop    irqbalance 2>/dev/null && echo "[OK] irqbalance stopped" \
        || echo "[INFO] irqbalance not running"
    systemctl disable irqbalance 2>/dev/null || true
    systemctl mask    irqbalance 2>/dev/null || true
}

# ── Helpers ───────────────────────────────────────────────────────────────────

expand_cpulist() {  # "0-3,8,10-12" → "0 1 2 3 8 10 11 12"
    local list="$1" result=()
    IFS=',' read -ra parts <<< "$list"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
                result+=("$i")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            result+=("$part")
        fi
    done
    echo "${result[@]}"
}

is_physical_core() {
    local cpu="$1"
    local f="/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list"
    [[ ! -f "$f" ]] && return 0
    local first; first=$(cut -d',' -f1 "$f" | cut -d'-' -f1 | tr -d ' \n')
    [[ "$first" == "$cpu" ]]
}

pin() {
    local irq="$1" cpu="$2" label="${3:-}"
    local f="/proc/irq/${irq}/smp_affinity_list"
    [[ ! -f "$f" ]] && {
        [[ $OPT_VERBOSE -eq 1 ]] && printf "  [SKIP] IRQ %-5s (no longer exists)\n" "$irq"
        return 0
    }
    if [[ $OPT_DRY -eq 0 ]]; then
        local prev; prev=$(cat "$f" 2>/dev/null || echo "")
        [[ -n "$prev" ]] && snap "echo '$prev' > $f 2>/dev/null"
        echo "$cpu" > "$f" 2>/dev/null \
            && { [[ $OPT_VERBOSE -eq 1 ]] && printf "  IRQ %-5s → CPU %-3s  %s\n" "$irq" "$cpu" "$label"; true; } \
            || printf "  [WARN] IRQ %-5s write failed\n" "$irq"
    else
        [[ $OPT_VERBOSE -eq 1 ]] && printf "  [DRY] IRQ %-5s → CPU %-3s  %s\n" "$irq" "$cpu" "$label"
    fi
}

role_priority() {
    case "$1" in
        bond_slave)    echo 4 ;;
        ovs_bond)      echo 4 ;;
        bridge_member) echo 3 ;;
        ovs_port)      echo 2 ;;
        standalone)    echo 1 ;;
        *)             echo 0 ;;
    esac
}

weight_of() {
    case "$1" in
        bond_slave|ovs_bond)     echo 3 ;;
        bridge_member|ovs_port)  echo 2 ;;
        *)                       echo 2 ;;
    esac
}

# ============================================================================
# Phase 1 — NUMA topology
# ============================================================================
echo ""
echo "=== Phase 1: NUMA Topology ==="
declare -A NUMA_AVAIL_CORES

for node_dir in /sys/devices/system/node/node[0-9]*/; do
    node=$(basename "$node_dir" | tr -d 'node')
    cpulist=$(cat "${node_dir}cpulist" 2>/dev/null) || continue
    [[ -z "$cpulist" ]] && continue

    all_cpus=($(expand_cpulist "$cpulist"))
    physical=()
    for cpu in "${all_cpus[@]}"; do
        is_physical_core "$cpu" && physical+=("$cpu")
    done
    [[ ${#physical[@]} -eq 0 ]] && continue

    reserved="${physical[0]}"
    avail=("${physical[@]:1}")
    NUMA_AVAIL_CORES[$node]="${avail[*]}"
    printf "  NUMA %s: %d physical cores | OS reserved: CPU %s | NIC pool: %s\n" \
        "$node" "${#physical[@]}" "$reserved" "${avail[*]}"
done

# ============================================================================
# Phase 2 — NIC discovery  (TWO-PASS: gather all, then deduplicate by priority)
#
# Pre-build membership maps before the NIC loop so role detection works
# correctly even when interfaces are link-down or OVS-managed.
# ============================================================================
echo ""
echo "=== Phase 2: NIC Discovery ==="

# ── 2a: Linux bond slaves from /proc/net/bonding/ ────────────────────────────
# Reliable regardless of link state. sysfs master symlink only exists when UP.
declare -A BOND_SLAVES=()
for bond_file in /proc/net/bonding/bond*; do
    [[ -f "$bond_file" ]] || continue
    bond_name=$(basename "$bond_file")
    while IFS= read -r line; do
        if [[ "$line" =~ ^"Slave Interface: "(.+)$ ]]; then
            slave=$(echo "${BASH_REMATCH[1]}" | tr -d ' \r\n')
            BOND_SLAVES[$slave]="$bond_name"
        fi
    done < "$bond_file"
done
[[ ${#BOND_SLAVES[@]} -gt 0 ]] \
    && echo "  Linux bond slaves (/proc/net/bonding): ${!BOND_SLAVES[*]}" \
    || echo "  No Linux bond slaves found"

# ── 2b: OVS bond members from ovs-appctl (optional, graceful if absent) ──────
declare -A OVS_BOND_SLAVES=()
if command -v ovs-appctl >/dev/null 2>&1; then
    current_bond=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^----\ (.+)\ ---- ]]; then
            current_bond="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^slave\ ([^:]+):\ (enabled|disabled) ]]; then
            OVS_BOND_SLAVES["${BASH_REMATCH[1]}"]="$current_bond"
        fi
    done < <(ovs-appctl bond/show 2>/dev/null)
    [[ ${#OVS_BOND_SLAVES[@]} -gt 0 ]] \
        && echo "  OVS bond slaves (ovs-appctl):         ${!OVS_BOND_SLAVES[*]}" \
        || echo "  No OVS bond slaves found (ovs-appctl present but returned nothing)"
else
    echo "  ovs-appctl not available — OVS bond detection skipped"
fi

# ── 2c: Pass 1 — gather all interfaces with roles (no dedup yet) ─────────────
declare -A P1_ROLE=()    # iface → role
declare -A P1_PCI=()     # iface → pci
declare -A P1_NUMA=()    # iface → numa
declare -A P1_BY_PCI=()  # pci   → "iface1 iface2 ..."

for iface_dir in /sys/class/net/*/; do
    iface=$(basename "$iface_dir")

    # Skip virtual / non-physical by name
    case "$iface" in
        lo|bond*|virbr*|docker*|veth*|wg*|tun*|tap*|dummy*|ovs-system) continue ;;
    esac
    [[ "$iface" == br-* ]] && continue

    # Require a real PCI device
    pci_link=$(readlink "${iface_dir}device" 2>/dev/null) || continue
    pci=$(basename "$pci_link")
    [[ ! "$pci" =~ ^[0-9a-f]{4}:[0-9a-f]{2}: ]] && continue

    # NUMA node (-1 means NUMA-unaware hardware, treat as node 0)
    numa=0
    numa_file="/sys/bus/pci/devices/${pci}/numa_node"
    [[ -f "$numa_file" ]] && { n=$(cat "$numa_file"); [[ $n -ge 0 ]] && numa=$n; }

    # ── Role detection ────────────────────────────────────────────────────────
    role="standalone"

    # Linux bond: /proc/net/bonding/ first (works even when link-down)
    [[ "${BOND_SLAVES[$iface]+_}" ]] && role="bond_slave"

    # OVS bond: pre-scan (works even when link-down, mirrors Linux bond pre-scan)
    [[ "$role" == "standalone" && "${OVS_BOND_SLAVES[$iface]+_}" ]] && role="ovs_bond"

    # Linux bond: sysfs master fallback (only when link is up)
    if [[ "$role" == "standalone" && -L "${iface_dir}master" ]]; then
        master=$(basename "$(readlink "${iface_dir}master" 2>/dev/null || echo "")")
        if [[ -d "/sys/class/net/${master}/bonding" ]]; then
            role="bond_slave"
        elif [[ "$master" == "ovs-system" ]]; then
            # OVS port: check if it is also in an OVS bond (higher weight)
            if [[ "${OVS_BOND_SLAVES[$iface]+_}" ]]; then
                role="ovs_bond"
            else
                role="ovs_port"
            fi
        fi
    fi

    # Traditional kernel bridge member (only when not already a higher-priority role)
    [[ -d "${iface_dir}brport" && "$role" == "standalone" ]] && role="bridge_member"

    P1_ROLE[$iface]="$role"
    P1_PCI[$iface]="$pci"
    P1_NUMA[$iface]="$numa"
    P1_BY_PCI[$pci]="${P1_BY_PCI[$pci]+${P1_BY_PCI[$pci]} }${iface}"
done

# ── 2d: Pass 2 — for each PCI group, select highest-priority role ─────────────
# Fixes the bug where eth2 (standalone, 82:00.4) was picked over
# ext3 (bond_slave, 82:00.4) because eth2 sorts before ext3 alphabetically.
declare -A NIC_PCI NIC_NUMA NIC_ROLE NIC_IRQS NIC_CORES
declare -a NICS=()

for pci in $(echo "${!P1_BY_PCI[@]}" | tr ' ' '\n' | sort); do
    read -ra candidates <<< "${P1_BY_PCI[$pci]}"
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort)

    # Select the candidate with the highest role priority
    best="" best_prio=0
    for c in "${candidates[@]}"; do
        prio=$(role_priority "${P1_ROLE[$c]}")
        if [[ $prio -gt $best_prio ]]; then
            best="$c"
            best_prio=$prio
        fi
    done

    # Collect IRQs for the winning interface
    irqs=()
    while IFS= read -r line; do
        irq=$(awk -F: '{gsub(/ /,"",$1); print $1}' <<< "$line")
        [[ "$irq" =~ ^[0-9]+$ ]] && irqs+=("$irq")
    done < <(grep -iF "$pci" /proc/interrupts 2>/dev/null | sort -t: -k1,1n)

    if [[ ${#irqs[@]} -eq 0 ]]; then
        printf "  %-12s PCI=%-15s NUMA=%s  (no IRQs — skipping)\n" \
            "$best" "$pci" "${P1_NUMA[$best]}"
        continue
    fi

    # Skip standalone interfaces that have no link (operstate != "up").
    # These are unplugged or unused ports — no point pinning their IRQs.
    # Bond slaves, OVS ports, and bridge members are always kept regardless
    # of link state (a bond slave can legitimately be link-down but active).
    if [[ "${P1_ROLE[$best]}" == "standalone" ]]; then
        operstate=$(cat "/sys/class/net/${best}/operstate" 2>/dev/null || echo "down")
        if [[ "$operstate" != "up" ]]; then
            printf "  %-12s PCI=%-15s NUMA=%s  role=%-14s (no link — skipped)\n" \
                "$best" "$pci" "${P1_NUMA[$best]}" "${P1_ROLE[$best]}"
            # Still show any deduplicated siblings for clarity
            for c in "${candidates[@]}"; do
                [[ "$c" == "$best" ]] && continue
                printf "  %-12s PCI=%-15s (shares PCI with %s — also skipped)\n" \
                    "$c" "$pci" "$best"
            done
            continue
        fi
    fi

    NIC_PCI[$best]="$pci"
    NIC_NUMA[$best]="${P1_NUMA[$best]}"
    NIC_ROLE[$best]="${P1_ROLE[$best]}"
    NIC_IRQS[$best]="${irqs[*]}"
    NICS+=("$best")

    printf "  %-12s PCI=%-15s NUMA=%s  role=%-14s IRQs=%d\n" \
        "$best" "$pci" "${P1_NUMA[$best]}" "${P1_ROLE[$best]}" "${#irqs[@]}"

    # Print deduplicated siblings
    for c in "${candidates[@]}"; do
        [[ "$c" == "$best" ]] && continue
        printf "  %-12s PCI=%-15s (shares PCI with %s — deduplicated, role=%s)\n" \
            "$c" "$pci" "$best" "${P1_ROLE[$c]}"
    done
done

[[ ${#NICS[@]} -eq 0 ]] && { echo "[ERROR] No physical NICs with IRQs found."; exit 1; }

# ============================================================================
# Phase 3 — Core allocation
# ============================================================================
echo ""
echo "=== Phase 3: Core Allocation ==="
declare -A NODE_NICS=()

for iface in "${NICS[@]}"; do
    node="${NIC_NUMA[$iface]}"
    NODE_NICS[$node]="${NODE_NICS[$node]+${NODE_NICS[$node]} }${iface}"
done

for node in $(echo "${!NODE_NICS[@]}" | tr ' ' '\n' | sort -n); do
    avail_str="${NUMA_AVAIL_CORES[$node]:-}"
    if [[ -z "$avail_str" ]]; then
        echo "  [WARN] No available cores for NUMA $node"
        continue
    fi
    read -ra avail <<< "$avail_str"
    total=${#avail[@]}
    read -ra node_nics <<< "${NODE_NICS[$node]}"

    total_w=0
    for n in "${node_nics[@]}"; do
        total_w=$(( total_w + $(weight_of "${NIC_ROLE[$n]}") ))
    done

    echo "  NUMA $node | ${total} cores | ${#node_nics[@]} NIC(s) | total_weight=$total_w"
    idx=0 n_count=${#node_nics[@]}

    for i in "${!node_nics[@]}"; do
        n="${node_nics[$i]}"
        w=$(weight_of "${NIC_ROLE[$n]}")
        remaining=$(( total - idx ))
        nics_left=$(( n_count - i - 1 ))

        if [[ $i -eq $(( n_count - 1 )) ]]; then
            n_cores=$remaining
        else
            n_cores=$(( (w * total + total_w / 2) / total_w ))
            [[ $n_cores -lt 1 ]] && n_cores=1
            max_take=$(( remaining - nics_left ))
            [[ $n_cores -gt $max_take && $max_take -gt 0 ]] && n_cores=$max_take
        fi

        assigned=("${avail[@]:$idx:$n_cores}")
        NIC_CORES[$n]="${assigned[*]}"
        idx=$(( idx + n_cores ))

        read -ra irq_arr <<< "${NIC_IRQS[$n]}"
        irq_count=${#irq_arr[@]}
        per_core=$(( (irq_count + n_cores - 1) / n_cores ))

        printf "    %-12s role=%-14s weight=%d  cores=[%-20s]  %3d IRQs (~%d/core)\n" \
            "$n" "${NIC_ROLE[$n]}" "$w" "${assigned[*]}" "$irq_count" "$per_core"
    done
done

# ============================================================================
# Phase 3b — Optional queue reduction (--reduce-queues)
# ============================================================================
if [[ $OPT_REDUCE -eq 1 ]]; then
    echo ""
    echo "=== Phase 3b: Queue Reduction ==="
    needs_rediscovery=0

    for iface in "${NICS[@]}"; do
        cores_str="${NIC_CORES[$iface]:-}"
        [[ -z "$cores_str" ]] && continue
        read -ra cores <<< "$cores_str"
        target=${#cores[@]}

        current=$(ethtool -l "$iface" 2>/dev/null \
            | awk '/^Current hardware/,0' | grep "Combined:" | awk '{print $2}')
        [[ -z "$current" || "$current" == "n/a" ]] && {
            echo "  $iface: ethtool -l not supported — skipping"
            continue
        }
        [[ "$current" -le "$target" ]] && {
            printf "  %-12s already at %d queues (target %d) — no change\n" \
                "$iface" "$current" "$target"
            continue
        }

        printf "  %-12s  %d → %d queues\n" "$iface" "$current" "$target"
        if [[ $OPT_DRY -eq 0 ]]; then
            # IRQs removed by the reduction lose their affinity snapshot; on
            # restore they reappear with default affinity and irqbalance (if
            # restored) rebalances them.
            snap "ip link set $iface down 2>/dev/null; ethtool -L $iface combined $current 2>/dev/null; ip link set $iface up 2>/dev/null"
            ip link set "$iface" down 2>/dev/null || true
            sleep 0.5
            ethtool -L "$iface" combined "$target" 2>/dev/null \
                && echo "    [OK] queues set to $target" \
                || echo "    [WARN] failed (bond constraint or driver limit)"
            ip link set "$iface" up 2>/dev/null || true
            needs_rediscovery=1
        else
            echo "  [DRY] Would set $iface combined $target"
        fi
    done

    if [[ $needs_rediscovery -eq 1 ]]; then
        sleep 1
        echo "  Re-reading IRQs after queue change..."
        for iface in "${NICS[@]}"; do
            pci="${NIC_PCI[$iface]}"
            irqs=()
            while IFS= read -r line; do
                irq=$(awk -F: '{gsub(/ /,"",$1); print $1}' <<< "$line")
                [[ "$irq" =~ ^[0-9]+$ ]] && irqs+=("$irq")
            done < <(grep -iF "$pci" /proc/interrupts 2>/dev/null | sort -t: -k1,1n)
            if [[ ${#irqs[@]} -gt 0 ]]; then
                NIC_IRQS[$iface]="${irqs[*]}"
                printf "  %-12s  %d IRQs after reduction\n" "$iface" "${#irqs[@]}"
            fi
        done
    fi
fi

# ============================================================================
# Phase 4 — IRQ pinning
# Async IRQs → first core (management plane, low traffic)
# Comp/data IRQs → round-robin across allocated cores
# ============================================================================
echo ""
echo "=== Phase 4: IRQ Pinning ==="

for iface in "${NICS[@]}"; do
    cores_str="${NIC_CORES[$iface]:-}"
    irqs_str="${NIC_IRQS[$iface]:-}"
    [[ -z "$cores_str" || -z "$irqs_str" ]] && {
        echo "  [SKIP] $iface — no cores or IRQs"
        continue
    }

    read -ra cores <<< "$cores_str"
    read -ra all_irqs <<< "$irqs_str"
    n_cores=${#cores[@]}
    idx=0 pinned=0

    echo ""
    echo "  --- $iface (NUMA ${NIC_NUMA[$iface]}, ${NIC_ROLE[$iface]}) ---"

    for irq in "${all_irqs[@]}"; do
        irq_name=$(grep -m1 "^ *${irq}:" /proc/interrupts 2>/dev/null | awk '{print $NF}')
        if echo "$irq_name" | grep -q "async"; then
            cpu="${cores[0]}"
        else
            cpu="${cores[$((idx % n_cores))]}"
            ((idx++))
        fi
        pin "$irq" "$cpu" "$irq_name"
        ((pinned++))
    done

    echo "  [OK] $iface: $pinned IRQs → cores: [$cores_str]"
done

# ============================================================================
# Phase 4b — XPS (Transmit Packet Steering)
#
# Sets each NIC's TX queues to prefer the CPUs on its own NUMA node,
# reducing cross-NUMA TX overhead on the transmit path.
#
# Skips mlx5e (ConnectX-6/7): that driver calls netif_set_xps_queue()
# automatically during open and manages XPS correctly on its own,
# including when the NIC is a bond slave.
#
# Skips bond_slave / ovs_bond roles for all other drivers: the bonding
# driver owns TX queue selection on the slave device. Writing a full-NUMA
# all-to-all XPS mask to every TX queue interferes with bond queue routing
# and was measured to reduce throughput ~25% on mlx4 bond slaves.
#
# For standalone / bridge_member drivers (cxgb4, mlx4_core, ixgbe, etc.):
# reads the existing xps_cpus file width to produce a format-matched mask,
# avoiding the "Value too large for defined data type" error caused by
# hardcoded hex strings that don't match the 56-bit (Chelsio) vs 64-bit
# (mlx4) formats used by different drivers on the same machine.
# ============================================================================
echo ""
echo "=== Phase 4b: XPS (Transmit Packet Steering) ==="

# helper: compute a format-matched XPS mask using the existing file as template
# Usage: _xps_mask <xps_cpus_file> <cpulist>   e.g. _xps_mask /sys/.../xps_cpus "0-13,28-41"
_xps_mask() {
    local file="$1" cpulist="$2"
    python3 - "$file" "$cpulist" <<'PYEOF'
import sys

def expand(s):
    cpus = []
    for part in s.split(','):
        part = part.strip()
        if '-' in part:
            a, b = part.split('-')
            cpus.extend(range(int(a), int(b)+1))
        else:
            cpus.append(int(part))
    return cpus

sample  = open(sys.argv[1]).read().strip()
groups  = sample.split(',')
widths  = [len(g) for g in groups]          # hex digits per group
cpus    = expand(sys.argv[2])
mask    = sum(1 << c for c in cpus)

out = []
for w in reversed(widths):                  # process LSB group first
    bits  = w * 4
    chunk = mask & ((1 << bits) - 1)
    mask >>= bits
    out.append(f'{chunk:0{w}x}')

print(','.join(reversed(out)))
PYEOF
}

if command -v python3 >/dev/null 2>&1; then
    for iface in "${NICS[@]}"; do
        node="${NIC_NUMA[$iface]}"

        # Detect driver — mlx5e manages XPS internally, skip it
        drv=$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null)
        if [[ "$drv" == "mlx5_core" ]]; then
            printf "  %-12s driver=%-12s (XPS managed by driver — skipped)\n" "$iface" "$drv"
            continue
        fi

        # Bond slaves: the bonding driver controls TX queue selection on the
        # slave; a full-NUMA all-to-all XPS mask disrupts that and was
        # measured to reduce throughput ~25% on mlx4 bond slaves.
        if [[ "${NIC_ROLE[$iface]}" == "bond_slave" || "${NIC_ROLE[$iface]}" == "ovs_bond" ]]; then
            printf "  %-12s driver=%-12s role=%-12s (bond slave — XPS skipped)\n" \
                "$iface" "$drv" "${NIC_ROLE[$iface]}"
            continue
        fi

        # Use the full NUMA CPU list (physical + HT siblings) for XPS.
        # IRQ affinity uses only physical cores, but XPS should cover ALL threads
        # on the NUMA node so any TX-originating app thread prefers the local NIC.
        cpulist=$(cat "/sys/devices/system/node/node${node}/cpulist" 2>/dev/null)
        if [[ -z "$cpulist" ]]; then
            printf "  %-12s NUMA %s: no cpulist found — skipped\n" "$iface" "$node"
            continue
        fi

        q_dirs=( "/sys/class/net/${iface}/queues"/tx-*/ )
        if [[ ! -d "${q_dirs[0]}" ]]; then
            printf "  %-12s no TX queues found — skipped\n" "$iface"
            continue
        fi

        pinned=0 failed=0 last_mask=""
        for q_dir in "${q_dirs[@]}"; do
            [[ -d "$q_dir" ]] || continue
            q_file="${q_dir}xps_cpus"
            [[ -f "$q_file" ]] || continue

            mask=$(_xps_mask "$q_file" "$cpulist")
            if [[ -z "$mask" ]]; then ((failed++)); continue; fi
            last_mask="$mask"
            if [[ $OPT_DRY -eq 1 ]]; then
                ((pinned++))
            else
                prev=$(cat "$q_file" 2>/dev/null || echo "")
                if echo "$mask" > "$q_file" 2>/dev/null; then
                    ((pinned++))
                    [[ -n "$prev" && "$prev" != "$mask" ]] && snap "echo '$prev' > $q_file 2>/dev/null"
                else
                    ((failed++))
                fi
            fi
        done

        if [[ $OPT_DRY -eq 1 ]]; then
            # Dry run: show computed mask vs current value
            readback="$(cat "${q_dirs[0]}xps_cpus" 2>/dev/null)"
            printf "  %-12s NUMA %s  driver=%-12s  CPUs=%-15s  %d TX queues  would write: %s  (current: %s)\n" \
                "$iface" "$node" "$drv" "$cpulist" "$pinned" \
                "$last_mask" "$readback"
        elif [[ $failed -eq 0 ]]; then
            readback="$(cat "${q_dirs[0]}xps_cpus" 2>/dev/null)"
            mismatch=""
            [[ "$readback" != "$last_mask" ]] && mismatch=" [WARN: driver reset XPS]"
            printf "  %-12s NUMA %s  driver=%-12s  CPUs=%-15s  %d TX queues → %s%s\n" \
                "$iface" "$node" "$drv" "$cpulist" "$pinned" \
                "$readback" "$mismatch"
        else
            printf "  %-12s [WARN] %d/%d TX queues failed to set XPS\n" \
                "$iface" "$failed" "$((pinned+failed))"
        fi
    done
else
    echo "  [SKIP] python3 not found — XPS configuration skipped"
fi

echo ""
echo "=== Phase 5: Verification ==="
printf "  %-14s %-6s %-16s %-22s %s\n" "Interface" "NUMA" "Role" "Cores" "Status"
printf "  %s\n" "────────────────────────────────────────────────────────────────────────"

all_ok=1
for iface in "${NICS[@]}"; do
    irqs_str="${NIC_IRQS[$iface]:-}"
    [[ -z "$irqs_str" ]] && continue
    cores_str="${NIC_CORES[$iface]:-}"
    read -ra irq_arr <<< "$irqs_str"

    wrong=0
    if [[ $OPT_DRY -eq 0 && -n "$cores_str" ]]; then
        for irq in "${irq_arr[@]}"; do
            # smp_affinity_list may return a range ("1-8") when multiple CPUs
            # share the same IRQ vector, or a single CPU number.
            # Expand to individual CPUs before checking membership.
            affinity=$(cat "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null || echo "?")
            [[ "$affinity" == "?" ]] && continue
            # Expand affinity range into individual CPUs
            match=0
            IFS=',' read -ra aparts <<< "$affinity"
            for apart in "${aparts[@]}"; do
                if [[ "$apart" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    for ((ac=${BASH_REMATCH[1]}; ac<=${BASH_REMATCH[2]}; ac++)); do
                        echo "$cores_str" | grep -qw "$ac" && { match=1; break 2; }
                    done
                elif echo "$cores_str" | grep -qw "$apart"; then
                    match=1; break
                fi
            done
            [[ $match -eq 0 ]] && ((wrong++)) || true
        done
    fi

    if   [[ $OPT_DRY -eq 1 ]];   then status="[DRY RUN]"
    elif [[ $wrong -eq 0 ]];      then status="[OK] ${#irq_arr[@]} IRQs pinned"
    else                               status="[WARN] $wrong/${#irq_arr[@]} off-target"; all_ok=0
    fi

    printf "  %-14s %-6s %-16s %-22s %s\n" \
        "$iface" "${NIC_NUMA[$iface]}" "${NIC_ROLE[$iface]}" \
        "$(echo "$cores_str" | tr ' ' ',' | cut -c1-20)" "$status"
done

echo ""
if   [[ $OPT_DRY -eq 1 ]];  then echo "  Dry run complete. Re-run without --dry-run to apply."
elif [[ $all_ok -eq 1 ]];   then echo "  All NIC IRQs correctly placed on NUMA-local cores."
else                              echo "  [WARN] Some IRQs may be off-target — review output above."
fi
echo ""
# ============================================================================
# Phase 6 — NIC Hardware Tuning
# Maximizes ring buffers to hardware limit and enables adaptive RX coalescing.
#
# Chelsio (cxgb4): ethtool -G fails with EBUSY while adapter is running.
# If that happens, a warning is printed with the systemd .link file workaround.
# All other drivers (mlx5e, mlx4_core) accept -G at runtime.
# ============================================================================
echo ""
echo "=== Phase 6: NIC Hardware Tuning ==="

for iface in "${NICS[@]}"; do
    # ── Ring buffers ─────────────────────────────────────────────────────────
    ring_out=$(ethtool -g "$iface" 2>/dev/null)
    if [[ -z "$ring_out" ]]; then
        printf "  %-12s ethtool -g not supported — skipping rings\n" "$iface"
    else
        rx_max=$(awk '/^Pre-set/{found=1} found && /^RX:/{print $2; exit}' <<< "$ring_out")
        tx_max=$(awk '/^Pre-set/{found=1} found && /^TX:/{print $2; exit}' <<< "$ring_out")
        rx_cur=$(awk '/^Current hardware/{found=1} found && /^RX:/{print $2; exit}' <<< "$ring_out")
        tx_cur=$(awk '/^Current hardware/{found=1} found && /^TX:/{print $2; exit}' <<< "$ring_out")

        if [[ "$rx_max" =~ ^[0-9]+$ && "$tx_max" =~ ^[0-9]+$ ]]; then
            if [[ "$rx_cur" == "$rx_max" && "$tx_cur" == "$tx_max" ]]; then
                printf "  %-12s rings already at maximum (RX=%s TX=%s)\n" \
                    "$iface" "$rx_max" "$tx_max"
            elif [[ $OPT_DRY -eq 1 ]]; then
                printf "  [DRY] %-12s rings: RX %s→%s  TX %s→%s\n" \
                    "$iface" "$rx_cur" "$rx_max" "$tx_cur" "$tx_max"
            else
                [[ "$rx_cur" =~ ^[0-9]+$ && "$tx_cur" =~ ^[0-9]+$ ]] && \
                    snap "ethtool -G $iface rx $rx_cur tx $tx_cur 2>/dev/null"
                err=$(ethtool -G "$iface" rx "$rx_max" tx "$tx_max" 2>&1)
                if [[ $? -eq 0 ]]; then
                    printf "  %-12s rings set:  RX=%s TX=%s\n" "$iface" "$rx_max" "$tx_max"
                else
                    printf "  %-12s [WARN] rings failed (%s)\n" "$iface" "$err"
                    # cxgb4 returns EBUSY while adapter is running (FULL_INIT_DONE flag).
                    # Workaround: use a systemd .link file applied before the driver opens.
                    drv=$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null)
                    if [[ "$drv" == "cxgb4" ]]; then
                        mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null)
                        printf "  %-12s [INFO] cxgb4 ring fix — create /etc/systemd/network/10-%s-rings.link:\n" \
                            "$iface" "$iface"
                        printf "         [Match]\\n         MACAddress=%s\\n         [Link]\\n         RxBufferSize=%s\\n         TxBufferSize=%s\\n" \
                            "$mac" "$rx_max" "$tx_max"
                    fi
                fi
            fi
        else
            printf "  %-12s could not parse ring maximums — skipping\n" "$iface"
        fi
    fi

    # ── Adaptive RX coalescing ────────────────────────────────────────────────
    if [[ $OPT_DRY -eq 1 ]]; then
        printf "  [DRY] %-12s adaptive-rx on\n" "$iface"
    else
        prev_adap=$(ethtool -c "$iface" 2>/dev/null | awk '/^Adaptive RX:/{print $3}')
        if ethtool -C "$iface" adaptive-rx on 2>/dev/null; then
            [[ "$prev_adap" == "off" ]] && snap "ethtool -C $iface adaptive-rx off 2>/dev/null"
            printf "  %-12s adaptive-rx: on\n" "$iface"
        else
            printf "  %-12s adaptive-rx: not supported by driver\n" "$iface"
        fi
    fi
done

# ============================================================================
# Phase 7 — Link Layer Verification
#
# FEC: 100GE (CAUI-4) requires RS-FEC (Clause 91) for reliable operation.
#      Misconfigured FEC causes CRC errors, link flapping, or PCS deskew loss.
#      Chelsio T6 often ships with Auto/Off — force RS explicitly.
# Flow control: global Ethernet PAUSE typically causes head-of-line blocking
#      on leaf/spine fabrics. PFC is the modern replacement, configured
#      out-of-band. This phase reports state — user decides the policy.
# ============================================================================
echo ""
echo "=== Phase 7: Link Layer Verification ==="

for iface in "${NICS[@]}"; do
    speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo "0")
    [[ ! "$speed" =~ ^-?[0-9]+$ ]] && speed=0

    # ── FEC ──────────────────────────────────────────────────────────────────
    fec_out=$(ethtool --show-fec "$iface" 2>/dev/null)
    if [[ -z "$fec_out" ]]; then
        printf "  %-12s FEC:   not supported by driver\n" "$iface"
    else
        fec_active=$(awk -F': ' '/Active FEC encoding/{print $2}' <<< "$fec_out" | xargs)
        fec_config=$(awk -F': ' '/Configured FEC encodings/{print $2}' <<< "$fec_out" | xargs)
        [[ -z "$fec_active" ]] && fec_active="unknown"
        [[ -z "$fec_config" ]] && fec_config="unknown"

        if [[ $speed -ge 100000 ]]; then
            if [[ "${fec_active,,}" == *rs* ]]; then
                printf "  %-12s FEC:   active=%-8s configured=%-22s [OK] RS-FEC on 100GE\n" \
                    "$iface" "$fec_active" "$fec_config"
            else
                printf "  %-12s FEC:   active=%-8s configured=%-22s [WARN] 100GE without RS-FEC\n" \
                    "$iface" "$fec_active" "$fec_config"
                printf "  %-12s        [HINT] ethtool --set-fec %s encoding rs\n" "" "$iface"
            fi
        else
            printf "  %-12s FEC:   active=%-8s configured=%-22s (link %sMbps)\n" \
                "$iface" "$fec_active" "$fec_config" "$speed"
        fi
    fi

    # ── Flow control (pause frames) ──────────────────────────────────────────
    pause_out=$(ethtool -a "$iface" 2>/dev/null)
    if [[ -z "$pause_out" ]]; then
        printf "  %-12s Pause: not supported by driver\n" "$iface"
    else
        rx_pause=$(awk '/^RX:/{print $2}' <<< "$pause_out")
        tx_pause=$(awk '/^TX:/{print $2}' <<< "$pause_out")
        autoneg=$(awk '/^Autonegotiate:/{print $2}' <<< "$pause_out")
        [[ -z "$rx_pause" ]] && rx_pause="?"
        [[ -z "$tx_pause" ]] && tx_pause="?"
        [[ -z "$autoneg"  ]] && autoneg="?"

        if [[ "$rx_pause" == "off" && "$tx_pause" == "off" ]]; then
            printf "  %-12s Pause: rx=%-3s tx=%-3s autoneg=%-3s  [OK] pause disabled\n" \
                "$iface" "$rx_pause" "$tx_pause" "$autoneg"
        else
            printf "  %-12s Pause: rx=%-3s tx=%-3s autoneg=%-3s  [INFO] global pause enabled\n" \
                "$iface" "$rx_pause" "$tx_pause" "$autoneg"
            printf "  %-12s        [HINT] for fat-pipe fabrics: ethtool -A %s rx off tx off autoneg off\n" "" "$iface"
        fi
    fi
done

# ============================================================================
# Phase 8 — PCIe Configuration
#
# MaxReadReq: default 512B is undersized for 100GE cards. 4096B lets the NIC
#      issue larger DMA reads, reducing PCIe transaction overhead. The actual
#      DevCtl register offset is CAP_EXP+8; MaxReadReq is bits 14:12 (value
#      5 = 4096B). MaxPayload is platform-capped by the root complex and is
#      only reported here for context.
# MSI-X: each RSS queue needs its own MSI-X vector. If the capability is
#      absent or disabled, the driver falls back to INTx and all queue
#      interrupts serialize through one line — a hard pps ceiling.
# ============================================================================
echo ""
echo "=== Phase 8: PCIe Configuration ==="

if ! command -v lspci >/dev/null 2>&1; then
    echo "  [SKIP] lspci not available — Phase 8 skipped"
else
    for iface in "${NICS[@]}"; do
        pci="${NIC_PCI[$iface]}"
        lspci_out=$(lspci -vvv -s "$pci" 2>/dev/null)

        if [[ -z "$lspci_out" ]]; then
            printf "  %-12s PCIe:  lspci returned no data for %s\n" "$iface" "$pci"
            continue
        fi

        # ── MaxReadReq / MaxPayload ──────────────────────────────────────────
        max_read=$(grep -oE "MaxReadReq [0-9]+ bytes" <<< "$lspci_out" | head -1 | awk '{print $2}')
        max_payload=$(grep -oE "MaxPayload [0-9]+ bytes" <<< "$lspci_out" | head -1 | awk '{print $2}')
        [[ -z "$max_read" ]]    && max_read="?"
        [[ -z "$max_payload" ]] && max_payload="?"

        if [[ "$max_read" =~ ^[0-9]+$ && "$max_read" -ge 4096 ]]; then
            printf "  %-12s PCIe:  MaxReadReq=%-6s MaxPayload=%-6s [OK] MaxReadReq at maximum\n" \
                "$iface" "${max_read}B" "${max_payload}B"
        elif [[ "$max_read" =~ ^[0-9]+$ ]]; then
            printf "  %-12s PCIe:  MaxReadReq=%-6s MaxPayload=%-6s [INFO] 4096B recommended for 100GE\n" \
                "$iface" "${max_read}B" "${max_payload}B"
            printf "  %-12s        [HINT] setpci -s %s CAP_EXP+8.w  (bits 14:12, value 5 = 4096B)\n" "" "$pci"
        else
            printf "  %-12s PCIe:  could not parse DevCtl  [INFO]\n" "$iface"
        fi

        # ── MSI-X state ──────────────────────────────────────────────────────
        msix_line=$(grep "MSI-X:" <<< "$lspci_out" | head -1)
        read -ra irq_arr <<< "${NIC_IRQS[$iface]:-}"
        irq_cnt=${#irq_arr[@]}

        if [[ -z "$msix_line" ]]; then
            printf "  %-12s MSI-X: capability not present  [WARN] driver may be using INTx\n" "$iface"
        else
            msix_count=$(grep -oE "Count=[0-9]+" <<< "$msix_line" | head -1 | cut -d= -f2)
            [[ -z "$msix_count" ]] && msix_count="?"

            if [[ "$msix_line" == *"Enable+"* ]]; then
                printf "  %-12s MSI-X: enabled  capacity=%-5s in-use=%-4d [OK]\n" \
                    "$iface" "$msix_count" "$irq_cnt"
            else
                printf "  %-12s MSI-X: DISABLED capacity=%-5s in-use=%-4d [WARN] INTx fallback caps pps\n" \
                    "$iface" "$msix_count" "$irq_cnt"
            fi
        fi
    done
fi

# ============================================================================
# Phase 9 — NIC Offload State
#
# Standard offloads (TSO/GSO/GRO/LRO): reports current state. LRO merges
#      receive segments in hardware — a win for host endpoints, but it
#      breaks forwarded TCP end-to-end semantics. Flagged when the NIC role
#      is bond_slave, ovs_bond, bridge_member, or ovs_port (forwarding).
# ConnectX-6 private flags (mlx5_core): CQE compression, striding RQ, and
#      CQE moderation meaningfully reduce PCIe traffic and CPU load at
#      100GE. Reports current state and hints at flags worth enabling.
# Chelsio T6 (cxgb4): only reports if cxgbtool is available. When present,
#      prints firmware version and notes the tool can do advanced tuning
#      (PFC, DCB, firmware management) that ethtool cannot reach.
# ============================================================================
echo ""
echo "=== Phase 9: NIC Offload State ==="

for iface in "${NICS[@]}"; do
    drv=$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null)
    [[ -z "$drv" ]] && drv="unknown"

    case "${NIC_ROLE[$iface]}" in
        bond_slave|ovs_bond|bridge_member|ovs_port) is_forwarding=1 ;;
        *)                                          is_forwarding=0 ;;
    esac

    # ── Standard offloads ────────────────────────────────────────────────────
    ethtool_k=$(ethtool -k "$iface" 2>/dev/null)
    if [[ -z "$ethtool_k" ]]; then
        printf "  %-12s offloads: ethtool -k unsupported\n" "$iface"
    else
        tso=$(awk -F': ' '/^tcp-segmentation-offload/{print $2}'     <<< "$ethtool_k" | awk '{print $1}')
        gso=$(awk -F': ' '/^generic-segmentation-offload/{print $2}' <<< "$ethtool_k" | awk '{print $1}')
        gro=$(awk -F': ' '/^generic-receive-offload/{print $2}'      <<< "$ethtool_k" | awk '{print $1}')
        lro=$(awk -F': ' '/^large-receive-offload/{print $2}'        <<< "$ethtool_k" | awk '{print $1}')
        lro_fixed=$(grep -c "^large-receive-offload:.*\[fixed\]" <<< "$ethtool_k" || true)
        [[ -z "$tso" ]] && tso="?"
        [[ -z "$gso" ]] && gso="?"
        [[ -z "$gro" ]] && gro="?"
        [[ -z "$lro" ]] && lro="?"

        if [[ "$lro" == "on" && $is_forwarding -eq 1 ]]; then
            if [[ "$lro_fixed" -gt 0 ]]; then
                printf "  %-12s offloads: tso=%-3s gso=%-3s gro=%-3s lro=%-3s  [INFO] LRO=on (fixed by driver, role=%s)\n" \
                    "$iface" "$tso" "$gso" "$gro" "$lro" "${NIC_ROLE[$iface]}"
            else
                printf "  %-12s offloads: tso=%-3s gso=%-3s gro=%-3s lro=%-3s  [HINT] forwarding role\n" \
                    "$iface" "$tso" "$gso" "$gro" "$lro"
                printf "  %-12s        [HINT] role=%s: LRO breaks forwarded TCP; ethtool -K %s lro off\n" \
                    "" "${NIC_ROLE[$iface]}" "$iface"
            fi
        else
            printf "  %-12s offloads: tso=%-3s gso=%-3s gro=%-3s lro=%-3s  [OK]\n" \
                "$iface" "$tso" "$gso" "$gro" "$lro"
        fi
    fi

    # ── ConnectX-6 private flags (mlx5_core) ─────────────────────────────────
    if [[ "$drv" == "mlx5_core" ]]; then
        priv_out=$(ethtool --show-priv-flags "$iface" 2>/dev/null)
        if [[ -z "$priv_out" ]]; then
            printf "  %-12s priv:  mlx5_core priv-flags unavailable\n" "$iface"
        else
            rcc=$(awk -F': ' '/^rx_cqe_compress/{print $2}' <<< "$priv_out" | xargs)
            rsr=$(awk -F': ' '/^rx_striding_rq/{print $2}'  <<< "$priv_out" | xargs)
            rcm=$(awk -F': ' '/^rx_cqe_moder/{print $2}'    <<< "$priv_out" | xargs)
            tcm=$(awk -F': ' '/^tx_cqe_moder/{print $2}'    <<< "$priv_out" | xargs)
            hgr=$(awk -F': ' '/^hw_gro/{print $2}'          <<< "$priv_out" | xargs)

            parts=()
            [[ -n "$rcc" ]] && parts+=("rx_cqe_compress=$rcc")
            [[ -n "$rsr" ]] && parts+=("rx_striding_rq=$rsr")
            [[ -n "$rcm" ]] && parts+=("rx_cqe_moder=$rcm")
            [[ -n "$tcm" ]] && parts+=("tx_cqe_moder=$tcm")
            [[ -n "$hgr" ]] && parts+=("hw_gro=$hgr")

            if [[ ${#parts[@]} -eq 0 ]]; then
                printf "  %-12s priv:  no recognized mlx5_core flags found\n" "$iface"
            else
                printf "  %-12s priv:  %s\n" "$iface" "${parts[*]}"

                suggest=()
                [[ "$rcc" == "off" ]] && suggest+=("rx_cqe_compress on")
                [[ "$rsr" == "off" ]] && suggest+=("rx_striding_rq on")
                [[ "$rcm" == "off" ]] && suggest+=("rx_cqe_moder on")
                if [[ ${#suggest[@]} -gt 0 ]]; then
                    printf "  %-12s        [HINT] for 100GE: ethtool --set-priv-flags %s %s\n" \
                        "" "$iface" "${suggest[*]}"
                fi
            fi
        fi
    fi

    # ── Chelsio T6 (cxgb4) — only if cxgbtool is available ───────────────────
    if [[ "$drv" == "cxgb4" ]] && command -v cxgbtool >/dev/null 2>&1; then
        fw=$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^firmware-version/{print $2}' | xargs)
        [[ -z "$fw" ]] && fw="unknown"
        printf "  %-12s cxgb4: firmware=%s  [INFO] cxgbtool available for PFC/DCB/FW tuning\n" \
            "$iface" "$fw"
    fi
done

# ============================================================================
# Phase 10 — Per-Interface Kernel Tunables
#
# txqueuelen: qdisc queue depth. Default 1000 is undersized for 100GE bursts;
#      10000 is the common recommendation.
# gro_flush_timeout (ns): soft-deadline for NAPI GRO flush. Reported as [INFO]
#      only — optimal value is workload-dependent and no universal recommendation
#      applies. High values (~200µs) reduce IRQ rate for high-PPS forwarding
#      workloads but delay ACK generation and hurt bulk single-flow TCP
#      throughput. Low values (0–50ns) are better for bulk transfer servers.
# napi_defer_hard_irqs (kernel 5.11+): defers hard IRQ re-arming for N NAPI
#      polls. Combined with a non-zero gro_flush_timeout this is often the
#      single biggest CPU-reduction win for receive-heavy 100GE workloads.
# ============================================================================
echo ""
echo "=== Phase 10: Per-Interface Kernel Tunables ==="

TXQ_RECOMMEND=10000
NAPI_RECOMMEND=2

echo "  Recommended: txqueuelen=${TXQ_RECOMMEND}, napi_defer_hard_irqs=${NAPI_RECOMMEND}"
echo "  gro_flush_timeout: reported as [INFO] — optimal value is workload-dependent (see phase header)"

for iface in "${NICS[@]}"; do
    txq=$(cat "/sys/class/net/${iface}/tx_queue_len" 2>/dev/null || echo "?")
    gro=$(cat "/sys/class/net/${iface}/gro_flush_timeout" 2>/dev/null || echo "?")

    napi_file="/sys/class/net/${iface}/napi_defer_hard_irqs"
    if [[ -f "$napi_file" ]]; then
        napi=$(cat "$napi_file" 2>/dev/null || echo "?")
        napi_supported=1
    else
        napi="n/a"
        napi_supported=0
    fi

    hints=()
    [[ "$txq" =~ ^[0-9]+$ && $txq -lt $TXQ_RECOMMEND ]] && \
        hints+=("ip link set $iface txqueuelen $TXQ_RECOMMEND")
    [[ $napi_supported -eq 1 && "$napi" =~ ^[0-9]+$ && $napi -lt $NAPI_RECOMMEND ]] && \
        hints+=("echo $NAPI_RECOMMEND > /sys/class/net/$iface/napi_defer_hard_irqs")

    if [[ ${#hints[@]} -eq 0 ]]; then
        printf "  %-12s txqueuelen=%-6s gro_flush=%-8s napi_defer=%-4s [OK]\n" \
            "$iface" "$txq" "$gro" "$napi"
    else
        printf "  %-12s txqueuelen=%-6s gro_flush=%-8s napi_defer=%-4s [HINT] %d tunable(s) below recommended\n" \
            "$iface" "$txq" "$gro" "$napi" "${#hints[@]}"
        for h in "${hints[@]}"; do
            printf "  %-12s        [HINT] %s\n" "" "$h"
        done
    fi
done

# ============================================================================
# Phase 11 — Bond Receive Flow Steering (RFS)
#
# RFS pins a TCP flow to the CPU running the receiving application, even
# when RSS placed the packet on a different CPU. On bonds this matters
# because slave selection (Linux bond hash or OVS hash) is independent of
# the app's CPU — without RFS, receive processing and the app frequently
# land on different cores, hurting cache locality.
#
# Needs two knobs set together:
#   net.core.rps_sock_flow_entries                             (global)
#   /sys/class/net/<slave>/queues/rx-N/rps_flow_cnt            (per-queue)
#
# Phase is skipped when no bonded NICs exist.
# ============================================================================
echo ""
echo "=== Phase 11: Bond Receive Flow Steering ==="

BOND_IFACES=()
for iface in "${NICS[@]}"; do
    case "${NIC_ROLE[$iface]}" in
        bond_slave|ovs_bond) BOND_IFACES+=("$iface") ;;
    esac
done

if [[ ${#BOND_IFACES[@]} -eq 0 ]]; then
    echo "  No bonded NICs detected — skipped"
else
    RPS_SOCK_RECOMMEND=1048576
    RPS_FLOW_RECOMMEND=32768

    # ── Global sysctl ────────────────────────────────────────────────────────
    RPS_SOCK_CURRENT=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo "?")

    if [[ "$RPS_SOCK_CURRENT" =~ ^[0-9]+$ && $RPS_SOCK_CURRENT -ge $RPS_SOCK_RECOMMEND ]]; then
        printf "  Global:   net.core.rps_sock_flow_entries = %-10s [OK]\n" "$RPS_SOCK_CURRENT"
    else
        printf "  Global:   net.core.rps_sock_flow_entries = %-10s (recommended: %d)\n" \
            "$RPS_SOCK_CURRENT" "$RPS_SOCK_RECOMMEND"
        printf "            [HINT] sysctl -w net.core.rps_sock_flow_entries=%d\n" "$RPS_SOCK_RECOMMEND"
    fi

    # ── Per-slave rps_flow_cnt ───────────────────────────────────────────────
    for iface in "${BOND_IFACES[@]}"; do
        q_dirs=( "/sys/class/net/${iface}/queues"/rx-*/ )
        if [[ ! -d "${q_dirs[0]}" ]]; then
            printf "  %-12s rps_flow_cnt: no RX queues found\n" "$iface"
            continue
        fi

        q_count=0 min_val="" max_val=""
        for q_dir in "${q_dirs[@]}"; do
            [[ -d "$q_dir" ]] || continue
            fc_file="${q_dir}rps_flow_cnt"
            [[ -f "$fc_file" ]] || continue
            fc=$(cat "$fc_file" 2>/dev/null) || continue
            [[ ! "$fc" =~ ^[0-9]+$ ]] && continue

            q_count=$(( q_count + 1 ))
            [[ -z "$min_val" || $fc -lt $min_val ]] && min_val=$fc
            [[ -z "$max_val" || $fc -gt $max_val ]] && max_val=$fc
        done

        if [[ $q_count -eq 0 ]]; then
            printf "  %-12s rps_flow_cnt: no readable queues\n" "$iface"
            continue
        fi

        if [[ "$min_val" == "$max_val" ]]; then
            value_str="$min_val (all $q_count queues)"
        else
            value_str="min=$min_val max=$max_val ($q_count queues)"
        fi

        if [[ $min_val -ge $RPS_FLOW_RECOMMEND ]]; then
            printf "  %-12s rps_flow_cnt: %-32s [OK]\n" "$iface" "$value_str"
        else
            printf "  %-12s rps_flow_cnt: %-32s (recommended: %d per queue)\n" \
                "$iface" "$value_str" "$RPS_FLOW_RECOMMEND"
            printf "  %-12s        [HINT] for q in /sys/class/net/%s/queues/rx-*; do echo %d > \$q/rps_flow_cnt; done\n" \
                "" "$iface" "$RPS_FLOW_RECOMMEND"
        fi
    done
fi

# ============================================================================
# Phase 12 — System-Level Health
#
# CPU governor: "performance" keeps cores at max frequency, avoiding the
#      ramp-up latency spike that IRQ-bursts suffer with ondemand/powersave.
# C-states: deep states save power but exit latency (tens of µs) shows up
#      directly in tail latency on IRQ-driven workloads. C1 is usually the
#      sweet spot for networking boxes.
# NUMA balancing: periodically migrates pages between nodes. On a box where
#      we've just pinned IRQs to NUMA-local cores, migration invalidates
#      that locality — disable on forwarding/latency-sensitive workloads.
# Kernel boot params: isolcpus / nohz_full / rcu_nocbs remove scheduler
#      interference from NIC-dedicated cores. Requires reboot to change.
# Network sysctls: defaults are tuned for 1GE. Prints current alongside
#      recommended so the operator can see how far off they are.
# ============================================================================
echo ""
echo "=== Phase 12: System-Level Health ==="

# ── 12a: CPU governor ────────────────────────────────────────────────────────
declare -A GOV_COUNT=()
for g_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$g_file" ]] || continue
    gov=$(cat "$g_file" 2>/dev/null) || continue
    [[ -z "$gov" ]] && continue
    GOV_COUNT[$gov]=$(( ${GOV_COUNT[$gov]:-0} + 1 ))
done

if [[ ${#GOV_COUNT[@]} -eq 0 ]]; then
    printf "  CPU governor:   cpufreq not exposed (virtualized or no driver)\n"
else
    total_cpus=0
    for c in "${GOV_COUNT[@]}"; do total_cpus=$(( total_cpus + c )); done
    gov_summary=""
    for gov in "${!GOV_COUNT[@]}"; do
        gov_summary+="${gov}:${GOV_COUNT[$gov]} "
    done
    gov_summary="${gov_summary% }"

    if [[ "${GOV_COUNT[performance]:-0}" -eq $total_cpus ]]; then
        printf "  CPU governor:   %s  [OK]\n" "$gov_summary"
    else
        printf "  CPU governor:   %s  [HINT] recommended: performance\n" "$gov_summary"
        printf "                  [HINT] cpupower frequency-set -g performance\n"
    fi
fi

# ── 12b: C-states ────────────────────────────────────────────────────────────
deepest_enabled="" deepest_id=-1
for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
    [[ -d "$state_dir" ]] || continue
    disable=$(cat "${state_dir}disable" 2>/dev/null || echo "1")
    [[ "$disable" != "0" ]] && continue
    name=$(cat "${state_dir}name" 2>/dev/null || echo "?")
    state_num=$(basename "$state_dir" | sed 's/state//')
    [[ "$state_num" =~ ^[0-9]+$ ]] || continue
    if [[ $state_num -gt $deepest_id ]]; then
        deepest_id=$state_num
        deepest_enabled="$name"
    fi
done

if [[ -z "$deepest_enabled" ]]; then
    printf "  C-states:       cpuidle not exposed\n"
else
    case "$deepest_enabled" in
        POLL|C1|C1E|C1_ACPI)
            printf "  C-states:       deepest enabled (cpu0): %s  [OK]\n" "$deepest_enabled"
            ;;
        *)
            printf "  C-states:       deepest enabled (cpu0): %s  [HINT] deep C-state exit adds IRQ latency\n" "$deepest_enabled"
            printf "                  [HINT] cpupower idle-set -D 1   (disables states deeper than C1)\n"
            ;;
    esac
fi

# ── 12c: NUMA balancing ──────────────────────────────────────────────────────
nb=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo "?")
if [[ "$nb" == "0" ]]; then
    printf "  NUMA balancing: kernel.numa_balancing=%s  [OK]\n" "$nb"
elif [[ "$nb" == "1" ]]; then
    printf "  NUMA balancing: kernel.numa_balancing=%s  [HINT] disable on forwarding boxes\n" "$nb"
    printf "                  [HINT] sysctl -w kernel.numa_balancing=0\n"
else
    printf "  NUMA balancing: kernel.numa_balancing=%s  (could not read)\n" "$nb"
fi

# ── 12d: Kernel boot params ──────────────────────────────────────────────────
cmdline=$(cat /proc/cmdline 2>/dev/null || echo "")
isolcpus=$(grep -oE 'isolcpus=[^ ]+'  <<< "$cmdline" | cut -d= -f2-)
nohz_full=$(grep -oE 'nohz_full=[^ ]+' <<< "$cmdline" | cut -d= -f2-)
rcu_nocbs=$(grep -oE 'rcu_nocbs=[^ ]+' <<< "$cmdline" | cut -d= -f2-)

printf "  Boot params (from /proc/cmdline):\n"
printf "    isolcpus  = %s\n" "${isolcpus:-<not set>}"
printf "    nohz_full = %s\n" "${nohz_full:-<not set>}"
printf "    rcu_nocbs = %s\n" "${rcu_nocbs:-<not set>}"
if [[ -z "$isolcpus" && -z "$nohz_full" && -z "$rcu_nocbs" ]]; then
    printf "    [INFO] NIC-dedicated cores share the scheduler with other tasks\n"
    printf "    [HINT] for lowest jitter add to kernel cmdline (requires reboot):\n"
    printf "           isolcpus=<cores> nohz_full=<cores> rcu_nocbs=<cores>\n"
fi
iommu_pt=$(grep -oE 'iommu=pt' <<< "$cmdline" | head -1)
iommu_intel=$(grep -oE 'intel_iommu=[^ ]+' <<< "$cmdline" | head -1)
iommu_amd=$(grep -oE 'amd_iommu=[^ ]+' <<< "$cmdline" | head -1)
if [[ -n "$iommu_pt" ]]; then
    printf "    iommu     = pt  [OK] passthrough — no per-DMA address translation overhead\n"
elif [[ -n "$iommu_intel" ]]; then
    printf "    iommu     = %s  [INFO] full IOMMU translation active\n" "$iommu_intel"
    printf "                  [HINT] add iommu=pt for lower DMA overhead on trusted hardware\n"
elif [[ -n "$iommu_amd" ]]; then
    printf "    iommu     = %s  [INFO] full AMD IOMMU translation active\n" "$iommu_amd"
    printf "                  [HINT] add iommu=pt for lower DMA overhead on trusted hardware\n"
else
    printf "    iommu     = <not set>  [INFO] IOMMU mode unspecified in cmdline\n"
fi

# ── 12e: Network sysctls ─────────────────────────────────────────────────────
declare -a SYSCTLS_SCALAR=(
    "net.core.rmem_max:268435456"
    "net.core.wmem_max:268435456"
    "net.core.rmem_default:16777216"
    "net.core.wmem_default:16777216"
    "net.core.netdev_max_backlog:250000"
    "net.core.netdev_budget:600"
    "net.core.netdev_budget_usecs:8000"
    "net.core.optmem_max:65536"
    "net.ipv4.tcp_mtu_probing:1"
    "net.core.busy_poll:50"
    "net.core.busy_read:50"
)
declare -a SYSCTLS_VECTOR=(
    "net.ipv4.tcp_rmem:4096 131072 268435456"
    "net.ipv4.tcp_wmem:4096 65536 268435456"
)

printf "  Network sysctls (current  →  recommended):\n"
low_count=0
for entry in "${SYSCTLS_SCALAR[@]}"; do
    name="${entry%%:*}"
    recommend="${entry#*:}"
    proc_path="/proc/sys/${name//./\/}"
    current=$(cat "$proc_path" 2>/dev/null || echo "?")

    if [[ "$current" =~ ^[0-9]+$ && $current -ge $recommend ]]; then
        tag="[OK]"
    elif [[ "$current" =~ ^[0-9]+$ ]]; then
        tag="[LOW]"
        low_count=$(( low_count + 1 ))
    else
        tag="[?]"
    fi
    printf "    %-32s = %-14s →  %-14s %s\n" "$name" "$current" "$recommend" "$tag"
done

for entry in "${SYSCTLS_VECTOR[@]}"; do
    name="${entry%%:*}"
    recommend="${entry#*:}"
    proc_path="/proc/sys/${name//./\/}"
    current=$(cat "$proc_path" 2>/dev/null | tr -s '\t ' ' ' || echo "?")
    [[ -z "$current" ]] && current="?"
    printf "    %-32s = %s\n" "$name" "$current"
    printf "    %-32s →  %s\n" "" "$recommend"
done

declare -a SYSCTLS_MAX=(   # lower-is-better: [OK] when current <= recommend
    "vm.zone_reclaim_mode:0"
)
for entry in "${SYSCTLS_MAX[@]}"; do
    name="${entry%%:*}"
    recommend="${entry#*:}"
    proc_path="/proc/sys/${name//./\/}"
    current=$(cat "$proc_path" 2>/dev/null || echo "?")
    if [[ "$current" =~ ^[0-9]+$ && $current -le $recommend ]]; then
        tag="[OK]"
    elif [[ "$current" =~ ^[0-9]+$ ]]; then
        tag="[WARN]"
        low_count=$(( low_count + 1 ))
    else
        tag="[?]"
    fi
    printf "    %-32s = %-14s →  %-14s %s\n" "$name" "$current" "$recommend" "$tag"
done

cc_cur=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "?")
cc_avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
if [[ "$cc_cur" == "bbr" || "$cc_cur" == "bbr2" ]]; then
    printf "    %-32s = %-14s →  %-14s [OK]\n" \
        "net.ipv4.tcp_congestion_control" "$cc_cur" "bbr"
else
    printf "    %-32s = %-14s →  %-14s [HINT]\n" \
        "net.ipv4.tcp_congestion_control" "$cc_cur" "bbr"
    low_count=$(( low_count + 1 ))
    if [[ "$cc_avail" == *"bbr"* ]]; then
        printf "    %-32s    [HINT] sysctl -w net.ipv4.tcp_congestion_control=bbr\n" ""
    else
        printf "    %-32s    [INFO] BBR not loaded; modprobe tcp_bbr first\n" ""
    fi
fi

if [[ $low_count -gt 0 ]]; then
    printf "    [HINT] %d sysctl(s) need attention — apply via /etc/sysctl.d/99-netperf.conf\n" "$low_count"
fi

# ============================================================================
# Phase 13 — NIC Ring Buffers & Interrupt Coalescing
#
# Ring depth: at 100GE line rate (~14.8 Mpps small frames) a shallow ring fills
#   in under 20µs. Running below the hardware maximum guarantees drops under
#   any scheduling jitter.
# Coalescing: adaptive-rx auto-tunes for throughput; fixed low rx-usecs favours
#   latency. Values are reported so the user can tune for their workload profile.
# ============================================================================
echo ""
echo "=== Phase 13: NIC Ring Buffers & Interrupt Coalescing ==="

for iface in "${NICS[@]}"; do
    # ── Ring buffers ─────────────────────────────────────────────────────────
    ring_out=$(ethtool -g "$iface" 2>/dev/null)
    if [[ -z "$ring_out" ]]; then
        printf "  %-12s rings: not reported by driver\n" "$iface"
    else
        rx_max=$(awk '/^Pre-set maximums:/{f=1} f && /^RX:[[:space:]]/{print $2; exit}' <<< "$ring_out")
        tx_max=$(awk '/^Pre-set maximums:/{f=1} f && /^TX:[[:space:]]/{print $2; exit}' <<< "$ring_out")
        rx_cur=$(awk '/^Current hardware settings:/{f=1} f && /^RX:[[:space:]]/{print $2; exit}' <<< "$ring_out")
        tx_cur=$(awk '/^Current hardware settings:/{f=1} f && /^TX:[[:space:]]/{print $2; exit}' <<< "$ring_out")
        [[ -z "$rx_max" ]] && rx_max="?"
        [[ -z "$tx_max" ]] && tx_max="?"
        [[ -z "$rx_cur" ]] && rx_cur="?"
        [[ -z "$tx_cur" ]] && tx_cur="?"

        rx_hint=0 tx_hint=0
        if [[ "$rx_cur" =~ ^[0-9]+$ && "$rx_max" =~ ^[0-9]+$ && $rx_cur -lt $rx_max ]]; then
            rx_tag="[LOW]"; rx_hint=1
        else
            rx_tag="[OK]"
        fi
        if [[ "$tx_cur" =~ ^[0-9]+$ && "$tx_max" =~ ^[0-9]+$ && $tx_cur -lt $tx_max ]]; then
            tx_tag="[LOW]"; tx_hint=1
        else
            tx_tag="[OK]"
        fi

        printf "  %-12s rings:  RX cur=%-6s max=%-6s %s  TX cur=%-6s max=%-6s %s\n" \
            "$iface" "$rx_cur" "$rx_max" "$rx_tag" "$tx_cur" "$tx_max" "$tx_tag"
        if [[ $rx_hint -eq 1 || $tx_hint -eq 1 ]]; then
            _rx_target="$( [[ $rx_hint -eq 1 ]] && echo "$rx_max" || echo "$rx_cur" )"
            _tx_target="$( [[ $tx_hint -eq 1 ]] && echo "$tx_max" || echo "$tx_cur" )"
            printf "  %-12s        [HINT] ethtool -G %s rx %s tx %s\n" \
                "" "$iface" "$_rx_target" "$_tx_target"
        fi
    fi

    # ── IRQ coalescing ───────────────────────────────────────────────────────
    coal_out=$(ethtool -c "$iface" 2>/dev/null)
    if [[ -z "$coal_out" ]]; then
        printf "  %-12s coal:  not reported by driver\n" "$iface"
    else
        adaptive_rx=$(awk '/^Adaptive RX:/{print $3}' <<< "$coal_out")
        rx_usecs=$(awk '/^rx-usecs:/{print $2}' <<< "$coal_out")
        tx_usecs=$(awk '/^tx-usecs:/{print $2}' <<< "$coal_out")
        [[ -z "$adaptive_rx" ]] && adaptive_rx="?"
        [[ -z "$rx_usecs"    ]] && rx_usecs="?"
        [[ -z "$tx_usecs"    ]] && tx_usecs="?"

        if [[ "$adaptive_rx" == "on" ]]; then
            coal_tag="[INFO] adaptive mode — driver auto-tunes for throughput"
        elif [[ "$rx_usecs" =~ ^[0-9]+$ && $rx_usecs -le 5 ]]; then
            coal_tag="[HINT] very low rx-usecs; consider 50–100 for bulk throughput"
        elif [[ "$rx_usecs" =~ ^[0-9]+$ && $rx_usecs -ge 500 ]]; then
            coal_tag="[HINT] high rx-usecs may increase tail latency"
        else
            coal_tag="[OK]"
        fi

        printf "  %-12s coal:  adaptive-rx=%-3s rx-usecs=%-6s tx-usecs=%-6s %s\n" \
            "$iface" "$adaptive_rx" "$rx_usecs" "$tx_usecs" "$coal_tag"
    fi
done

# ============================================================================
# Phase 14 — RSS Indirection Table
#
# After ethtool -L reduces queue count, the RSS indirection table may still
# reference old queue indices — leaving some queues idle and others saturated.
# ethtool -X equal <N> redistributes uniformly across active queues.
# ============================================================================
echo ""
echo "=== Phase 14: RSS Indirection Table ==="

for iface in "${NICS[@]}"; do
    rss_out=$(ethtool -x "$iface" 2>/dev/null)
    if [[ -z "$rss_out" ]]; then
        printf "  %-12s RSS:   ethtool -x not supported by driver\n" "$iface"
        continue
    fi

    num_rings=$(grep -oE 'with [0-9]+ RX ring' <<< "$rss_out" | grep -oE '[0-9]+' | head -1)
    [[ -z "$num_rings" ]] && num_rings=0

    table_entries=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*[0-9]+:[[:space:]] ]] || continue
        for entry in ${line#*:}; do
            [[ "$entry" =~ ^[0-9]+$ ]] && table_entries+=("$entry")
        done
    done <<< "$rss_out"

    total=${#table_entries[@]}
    if [[ $total -eq 0 ]]; then
        printf "  %-12s RSS:   rings=%-3s  could not parse indirection table\n" "$iface" "$num_rings"
        continue
    fi

    declare -A _rss_cnt=()
    for q in "${table_entries[@]}"; do
        _rss_cnt[$q]=$(( ${_rss_cnt[$q]:-0} + 1 ))
    done
    num_used=${#_rss_cnt[@]}
    rss_min=$total rss_max=0
    for cnt in "${_rss_cnt[@]}"; do
        [[ $cnt -lt $rss_min ]] && rss_min=$cnt
        [[ $cnt -gt $rss_max ]] && rss_max=$cnt
    done
    unset _rss_cnt

    if [[ "$num_rings" =~ ^[0-9]+$ && $num_rings -gt 0 && $num_used -ne $num_rings ]]; then
        printf "  %-12s RSS:   rings=%-3s table=%s entries  queues referenced=%s  [WARN] stale table\n" \
            "$iface" "$num_rings" "$total" "$num_used"
        printf "  %-12s        [HINT] ethtool -X %s equal %s\n" "" "$iface" "$num_rings"
    elif [[ $rss_max -gt $(( rss_min + 1 )) ]]; then
        printf "  %-12s RSS:   rings=%-3s table=%s entries  skew: min=%s max=%s per queue  [WARN]\n" \
            "$iface" "$num_rings" "$total" "$rss_min" "$rss_max"
        printf "  %-12s        [HINT] ethtool -X %s equal %s\n" "" "$iface" "$num_rings"
    else
        printf "  %-12s RSS:   rings=%-3s table=%s entries  [OK] evenly distributed\n" \
            "$iface" "$num_rings" "$total"
    fi
done

# ============================================================================
# Phase 15 — Connection Tracking (nf_conntrack)
#
# nf_conntrack performs a hash lookup on every forwarded packet. At 100GE line
# rate this becomes a serialisation point. On pure forwarding boxes without
# NAT or stateful firewall rules, removing the module eliminates the overhead.
# ============================================================================
echo ""
echo "=== Phase 15: Connection Tracking (nf_conntrack) ==="

if ! lsmod 2>/dev/null | grep -qF "nf_conntrack"; then
    printf "  nf_conntrack:   not loaded  [OK]\n"
else
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max   2>/dev/null || echo "?")
    printf "  nf_conntrack:   loaded  count=%-8s max=%s\n" "$ct_count" "$ct_max"
    printf "                  [INFO] per-packet hash lookup active at line rate\n"
    printf "                  [HINT] if no NAT/stateful rules: modprobe -r nf_conntrack\n"
    if [[ "$ct_max" =~ ^[0-9]+$ && $ct_max -lt 1000000 ]]; then
        printf "                  [HINT] for 100GE with NAT: nf_conntrack_max >= 1000000 recommended\n"
        printf "                         sysctl -w net.netfilter.nf_conntrack_max=2000000\n"
    fi
fi

# ============================================================================
# Phase 16 — Memory & Kernel Configuration
#
# THP: background compaction (khugepaged) and page splits under THP=always
#   cause latency spikes in packet-processing paths. madvise lets apps opt in.
# ksoftirqd: ksoftirqd/N is a per-CPU thread. Without isolcpus, non-NIC
#   softirqs (block, timer, etc.) share these threads on NIC-pinned cores.
# Intel DDIO: NIC DMA directly into L3 cache. On by default on Xeon Broadwell+;
#   BIOS-controlled. Detection requires the msr kernel module + rdmsr tool.
# ============================================================================
echo ""
echo "=== Phase 16: Memory & Kernel Configuration ==="

# ── THP ──────────────────────────────────────────────────────────────────────
thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
if [[ -f "$thp_file" ]]; then
    thp_val=$(grep -oE '\[[a-z]+\]' "$thp_file" 2>/dev/null | tr -d '[]')
    [[ -z "$thp_val" ]] && thp_val="?"
    if [[ "$thp_val" == "never" || "$thp_val" == "madvise" ]]; then
        printf "  THP:            %-10s [OK]\n" "$thp_val"
    else
        printf "  THP:            %-10s [HINT] 'always' triggers khugepaged compaction stalls\n" "$thp_val"
        printf "                  [HINT] echo madvise > %s\n" "$thp_file"
    fi
else
    printf "  THP:            not exposed by kernel\n"
fi

# ── ksoftirqd on NIC-pinned cores ────────────────────────────────────────────
nic_pinned_cpus=()
for _iface in "${NICS[@]}"; do
    _msi_dir="/sys/class/net/${_iface}/device/msi_irqs"
    [[ ! -d "$_msi_dir" ]] && continue
    for _irq_f in "${_msi_dir}"/*; do
        [[ -f "$_irq_f" ]] || continue
        _irqn=$(basename "$_irq_f")
        _aff=$(cat "/proc/irq/${_irqn}/smp_affinity_list" 2>/dev/null || echo "")
        [[ -z "$_aff" ]] && continue
        for _cpu in $(expand_cpulist "$_aff"); do
            nic_pinned_cpus+=("$_cpu")
        done
    done
done

if [[ ${#nic_pinned_cpus[@]} -gt 0 ]]; then
    mapfile -t nic_pinned_cpus < <(printf '%s\n' "${nic_pinned_cpus[@]}" | sort -un)
    nic_cores_str=$(IFS=','; echo "${nic_pinned_cpus[*]}")
    printf "  ksoftirqd:      NIC IRQ cores: {%s}\n" "$nic_cores_str"
    if [[ -n "$isolcpus" ]]; then
        printf "                  isolcpus=%s  [OK]\n" "$isolcpus"
    else
        printf "                  [INFO] ksoftirqd/{%s} also handles non-NIC softirqs (no isolcpus set)\n" \
            "$nic_cores_str"
        printf "                  [HINT] add isolcpus=%s nohz_full=%s rcu_nocbs=%s to cmdline\n" \
            "$nic_cores_str" "$nic_cores_str" "$nic_cores_str"
    fi
else
    printf "  ksoftirqd:      no NIC MSI-X IRQ pins found — skipping\n"
fi

# ── Intel DDIO ───────────────────────────────────────────────────────────────
cpu_vendor=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null | xargs)
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    if command -v rdmsr >/dev/null 2>&1; then
        # IIO_LLC_WAYS (0xC8B) = LLC ways allocated to DDIO inbound writes.
        # Nonzero => DDIO active (popcount = number of ways). 0xC8F is NOT a
        # DDIO register — reading it produced false "disabled" warnings. The
        # global disable is iiomiscctrl Disable_All_Allocating_Flows, a PCIe
        # config-space bit (not an MSR); on Xeon, DDIO is on by default.
        ddio=$(rdmsr -p 0 0xC8B 2>/dev/null | head -1 | tr -d ' \n' || echo "")
        if [[ -z "$ddio" ]]; then
            printf "  Intel DDIO:     IIO_LLC_WAYS (0xC8B) unreadable (modprobe msr)\n"
        elif [[ "$ddio" =~ ^0+$ ]]; then
            printf "  Intel DDIO:     IIO_LLC_WAYS=0x%s  [WARN] 0 ways — DDIO disabled\n" "$ddio"
        else
            dec=$((16#$ddio)); ways=0
            while [[ $dec -gt 0 ]]; do ways=$(( ways + (dec & 1) )); dec=$(( dec >> 1 )); done
            printf "  Intel DDIO:     IIO_LLC_WAYS=0x%s  [OK] DDIO active (%d LLC ways)\n" "$ddio" "$ways"
        fi
    else
        printf "  Intel DDIO:     [INFO] Intel CPU — DDIO state requires msr-tools (apt/yum: msr-tools)\n"
        printf "                  [INFO] DDIO is on by default on Xeon Broadwell+ (no BIOS toggle on most platforms)\n"
    fi
else
    printf "  Intel DDIO:     [INFO] non-Intel CPU (%s) — DDIO not applicable\n" "${cpu_vendor:-unknown}"
fi

# ============================================================================
# Phase 17 — RDMA / RoCE / XDP
#
# RDMA/RoCE: ConnectX-6 supports RoCE v2. Without end-to-end PFC, incast
#   congestion collapses RDMA throughput to retransmit storms.
# XDP: native XDP (driver hook, pre-sk_buff) vs generic XDP (post-sk_buff)
#   have a large performance gap. mlx5_core and cxgb4 both support native mode.
# ============================================================================
echo ""
echo "=== Phase 17: RDMA / RoCE / XDP ==="

# ── RDMA / RoCE (mlx5_core only) ─────────────────────────────────────────────
mlx5_present=0
for iface in "${NICS[@]}"; do
    _drv=$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null || echo "")
    [[ "$_drv" == "mlx5_core" ]] && { mlx5_present=1; break; }
done

if [[ $mlx5_present -eq 1 ]]; then
    printf "  --- RDMA / RoCE (ConnectX) ---\n"
    if command -v rdma >/dev/null 2>&1; then
        rdma_out=$(rdma link show 2>/dev/null || echo "")
        if [[ -z "$rdma_out" ]]; then
            printf "  RDMA links:     none enumerated  [INFO] is ib_core loaded?\n"
        else
            printf "  RDMA links:\n"
            while IFS= read -r line; do
                printf "    %s\n" "$line"
            done <<< "$rdma_out"
        fi
    else
        printf "  RDMA:           rdma tool not found  [SKIP]\n"
    fi

    for iface in "${NICS[@]}"; do
        _drv=$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null || echo "")
        [[ "$_drv" != "mlx5_core" ]] && continue
        if command -v mlnx_qos >/dev/null 2>&1; then
            pfc_out=$(mlnx_qos -i "$iface" 2>/dev/null || echo "")
            pfc_line=$(grep -i "pfc" <<< "$pfc_out" | head -1 | xargs)
            if [[ -n "$pfc_line" ]]; then
                printf "  %-12s PFC:   %s\n" "$iface" "$pfc_line"
            else
                printf "  %-12s PFC:   mlnx_qos returned no PFC data\n" "$iface"
            fi
        else
            printf "  %-12s PFC:   mlnx_qos not available  [SKIP]\n" "$iface"
            printf "  %-12s        [INFO] for RoCE v2: PFC must be enabled end-to-end (switch + NIC)\n" ""
        fi
    done
fi

# ── XDP mode ─────────────────────────────────────────────────────────────────
printf "  --- XDP ---\n"
for iface in "${NICS[@]}"; do
    drv=$(basename "$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null)" 2>/dev/null || echo "unknown")
    [[ -z "$drv" ]] && drv="unknown"
    ip_out=$(ip -d link show "$iface" 2>/dev/null || echo "")

    xdp_mode=""
    if grep -qF "xdpoffload" <<< "$ip_out"; then
        xdp_mode="offload"
    elif grep -qF "xdpdrv" <<< "$ip_out"; then
        xdp_mode="native"
    elif grep -qF "xdp" <<< "$ip_out"; then
        xdp_mode="generic"
    fi

    if [[ -z "$xdp_mode" ]]; then
        case "$drv" in
            mlx5_core) xdp_cap="native+offload capable" ;;
            cxgb4)     xdp_cap="native capable" ;;
            bnxt_en)   xdp_cap="native capable" ;;
            i40e|ice)  xdp_cap="native capable" ;;
            *)         xdp_cap="capability unknown — check driver docs" ;;
        esac
        printf "  %-12s XDP:   no program attached  [INFO] %s\n" "$iface" "$xdp_cap"
    elif [[ "$xdp_mode" == "native" || "$xdp_mode" == "offload" ]]; then
        printf "  %-12s XDP:   mode=%-10s  [OK]\n" "$iface" "$xdp_mode"
    else
        printf "  %-12s XDP:   mode=%-10s  [WARN] generic XDP still allocates sk_buff\n" "$iface" "$xdp_mode"
        printf "  %-12s        [HINT] reattach program in driver mode: ip link set %s xdp obj <prog.o> sec xdp\n" \
            "" "$iface"
    fi
done

if [[ -n "$RESTORE" ]]; then
    [[ -n "$IRQBALANCE_RESTORE" ]] && echo "$IRQBALANCE_RESTORE" >> "$RESTORE"
    echo 'echo "[restore] done — pre-run settings reapplied"' >> "$RESTORE"
    echo "=== Restore script: $RESTORE  (run as root to roll back this run) ==="
fi
echo "=== DONE. Log: $LOG ==="
