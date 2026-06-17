#!/bin/bash
# rpi-custom: dinamik swapfile oluşturur (resize sonrası gerçek boş alana göre).
#
# Formül (bkz. notes/01-decisions.md "zram / Swap"):
#   boş_alan < 4GB  -> swapfile yok (sadece zram)
#   boş_alan >= 4GB -> swapfile = min(2GB, boş_alan'ın %10'u)

set -euo pipefail

MARKER=/var/lib/rpi-custom/firstboot-swapfile.done
[[ -f "$MARKER" ]] && exit 0

FREE_KB=$(df --output=avail -k / | tail -1 | tr -d ' ')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))

echo "Boş alan: ${FREE_GB}GB"

if (( FREE_GB < 4 )); then
    echo "Boş alan < 4GB, swapfile oluşturulmuyor (sadece zram kullanılacak)"
else
    SWAP_MB=$(( FREE_GB * 1024 / 10 ))
    if (( SWAP_MB > 2048 )); then
        SWAP_MB=2048
    fi

    echo "Swapfile oluşturuluyor: ${SWAP_MB}MB"
    fallocate -l "${SWAP_MB}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
