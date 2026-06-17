#!/bin/bash
# rpi-custom: rootfs partition'ını SD kartın tamamını kapsayacak şekilde büyütür.
#
# Not: Stok Raspberry Pi OS zaten ilk açılışta benzer bir resize yapıyor olabilir
# (raspberrypi-sys-mods). Bu script idempotent ve defensif — partition zaten tam
# boyuttaysa parted/resize2fs no-op olarak biter. firstboot-swapfile.service'in
# güvenilir bir After= bağımlılığına sahip olması için ayrıca tutuluyor.

set -euo pipefail

MARKER=/var/lib/rpi-custom/firstboot-resize.done
[[ -f "$MARKER" ]] && exit 0

ROOT_DEV=$(findmnt -no SOURCE /)
ROOT_PART_NUM=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV")"

echo "rootfs: $ROOT_DEV (partition $ROOT_PART_NUM, disk $ROOT_DISK)"

# parted resizepart, root partition mount halindeyken kernel'e değişikliği
# bildiremiyor ("Unable to inform the kernel of the change") ve script
# set -e ile burada hata veriyor. sfdisk (--no-reread, sadece partition
# table'ı diske yazar) + partx -u (BLKPG ioctl ile mounted partition'ı
# canlı olarak büyütür) kombinasyonu mounted root için güvenilir.
echo "size=+" | sfdisk -N "$ROOT_PART_NUM" --no-reread "$ROOT_DISK"
partx -u "$ROOT_DISK"
resize2fs "$ROOT_DEV"

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
