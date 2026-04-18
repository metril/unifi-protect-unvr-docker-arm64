#!/usr/bin/env bash
#
# Rename the container's docker-assigned interfaces to what UNVR firmware
# expects:
#   - enp0s2 := the interface on the LAN subnet (macvlan). Owns the
#     default route; ubnt-tools derives the device serial from its MAC.
#   - enp0s1 := the other attached interface (bridge to the Traefik
#     proxy network), renamed for UNVR two-NIC conventions.
#
# The LAN subnet prefix is read from the LAN_SUBNET_PREFIX env var
# (e.g. "10.10.76"), which is passed via docker-compose's `environment:`
# block. We source /proc/1/environ because systemd does not propagate
# docker env into unit ExecStart.

set -euo pipefail

log() { echo "[network_setup] $*"; }

# Pull docker-provided env vars into this script's environment.
for e in $(tr "\000" "\n" < /proc/1/environ); do
    eval "export $e"
done

LAN_SUBNET_PREFIX="${LAN_SUBNET_PREFIX:-}"
if [ -z "$LAN_SUBNET_PREFIX" ]; then
    log "ERROR: LAN_SUBNET_PREFIX env var not set; cannot identify the LAN interface"
    log "       (set e.g. LAN_SUBNET_PREFIX=10.10.76 in docker-compose environment)"
    exit 1
fi
log "LAN_SUBNET_PREFIX=$LAN_SUBNET_PREFIX"

# Capture IPv4/IPv6 global-scope addrs and the default route via $1.
# The kernel removes IPv4 addrs (unless keep_addr_on_down=1) and ALL
# routes via the link on link-down; we must restore them after rename.
_v4=(); _v6=(); _gw4=""; _gw6=""
save_state() {
    local iface=$1
    mapfile -t _v4 < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    mapfile -t _v6 < <(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    _gw4="$(ip -4 route show default 2>/dev/null | awk -v i="$iface" '$5==i{print $3; exit}')"
    _gw6="$(ip -6 route show default 2>/dev/null | awk -v i="$iface" '$5==i{print $3; exit}')"
}

restore_state() {
    local iface=$1
    for a in "${_v4[@]}"; do
        [ -n "$a" ] && ip -4 addr add "$a" dev "$iface" 2>/dev/null || true
    done
    for a in "${_v6[@]}"; do
        [ -n "$a" ] && ip -6 addr add "$a" dev "$iface" 2>/dev/null || true
    done
    [ -n "$_gw4" ] && ip -4 route add default via "$_gw4" dev "$iface" 2>/dev/null || true
    [ -n "$_gw6" ] && ip -6 route add default via "$_gw6" dev "$iface" 2>/dev/null || true
}

rename_preserve() {
    local from=$1 to=$2
    log "Renaming $from -> $to (preserving IP/routes)"
    save_state "$from"
    log "  captured v4=${_v4[*]:-none} gw4=${_gw4:-none} v6=${_v6[*]:-none} gw6=${_gw6:-none}"
    ip link set dev "$from" down
    ip link set dev "$from" name "$to"
    ip link set dev "$to" up
    restore_state "$to"
}

# Discover which pre-rename interface holds the LAN IP and which holds
# the bridge IP. Skip lo and anything already renamed.
lan_iface=""
bridge_iface=""
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    name=$(basename "$d")
    case "$name" in
        lo|enp0s1|enp0s2) continue ;;
    esac
    ipv4=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{print $4}' | head -1)
    if [[ "$ipv4" == "$LAN_SUBNET_PREFIX."* ]]; then
        lan_iface="$name"
    elif [ -n "$ipv4" ]; then
        bridge_iface="$name"
    fi
done
log "Detected lan_iface=${lan_iface:-none} bridge_iface=${bridge_iface:-none}"

# enp0s2 <- LAN (primary, owns default route, MAC source for ubnt-tools)
if [ ! -e /sys/class/net/enp0s2 ]; then
    if [ -n "$lan_iface" ]; then
        rename_preserve "$lan_iface" enp0s2
    else
        log "WARNING: no interface detected on LAN subnet $LAN_SUBNET_PREFIX; enp0s2 not created"
    fi
else
    log "enp0s2 already present, ensuring UP"
    ip link set dev enp0s2 up || true
fi

# enp0s1 <- Traefik bridge (secondary)
if [ ! -e /sys/class/net/enp0s1 ]; then
    if [ -n "$bridge_iface" ]; then
        rename_preserve "$bridge_iface" enp0s1
    else
        log "WARNING: no bridge interface detected for Traefik; enp0s1 not created"
    fi
else
    log "enp0s1 already present, ensuring UP"
    ip link set dev enp0s1 up || true
fi

log "Final link state:"
ip -brief link show
ip -brief addr show
log "Routes:"
ip route show
