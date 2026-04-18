#!/usr/bin/env bash
set -euo pipefail

log() { echo "[network_setup] $*"; }

if [ -e /sys/class/net/eth0 ] && [ ! -e /sys/class/net/enp0s2 ]; then
    log "Renaming eth0 -> enp0s2"
    ip link set dev eth0 down
    ip link set dev eth0 name enp0s2
    ip link set dev enp0s2 up
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
