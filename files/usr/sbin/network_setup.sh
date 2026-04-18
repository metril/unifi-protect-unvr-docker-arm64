#!/usr/bin/env bash
set -euo pipefail

log() { echo "[network_setup] $*"; }

if [ -e /sys/class/net/eth0 ] && [ ! -e /sys/class/net/enp0s2 ]; then
    log "Renaming eth0 -> enp0s2 (preserving IP/routes across down/up)"

    # Capture state BEFORE bringing the link down — the kernel removes
    # IPv4 addresses (unless keep_addr_on_down=1) and ALL routes via the
    # interface when it goes down, and does not restore them on up.
    mapfile -t IPV4_ADDRS < <(ip -4 -o addr show dev eth0 scope global | awk '{print $4}')
    mapfile -t IPV6_ADDRS < <(ip -6 -o addr show dev eth0 scope global | awk '{print $4}')
    GW4="$(ip -4 route show default 2>/dev/null | awk '$5=="eth0"{print $3; exit}')"
    GW6="$(ip -6 route show default 2>/dev/null | awk '$5=="eth0"{print $3; exit}')"

    log "Captured IPv4=${IPV4_ADDRS[*]:-none} gw4=${GW4:-none} IPv6=${IPV6_ADDRS[*]:-none} gw6=${GW6:-none}"

    ip link set dev eth0 down
    ip link set dev eth0 name enp0s2
    ip link set dev enp0s2 up

    for a in "${IPV4_ADDRS[@]}"; do
        [ -n "$a" ] && ip -4 addr add "$a" dev enp0s2 2>/dev/null || true
    done
    for a in "${IPV6_ADDRS[@]}"; do
        [ -n "$a" ] && ip -6 addr add "$a" dev enp0s2 2>/dev/null || true
    done
    [ -n "${GW4:-}" ] && ip -4 route add default via "$GW4" dev enp0s2 2>/dev/null || true
    [ -n "${GW6:-}" ] && ip -6 route add default via "$GW6" dev enp0s2 2>/dev/null || true

elif [ -e /sys/class/net/enp0s2 ]; then
    log "enp0s2 already present, ensuring UP"
    ip link set dev enp0s2 up || true
else
    log "WARNING: neither eth0 nor enp0s2 exists"
fi

if [ ! -e /sys/class/net/enp0s1 ]; then
    log "Creating dummy enp0s1"
    modprobe dummy 2>/dev/null || true
    ip link add enp0s1 type dummy
fi
log "Bringing enp0s1 UP"
ip link set dev enp0s1 up

log "Final link state:"
ip -brief link show
ip -brief addr show
ip route show default || true
