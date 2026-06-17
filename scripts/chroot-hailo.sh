#!/usr/bin/env bash
#
# nspawn içinde çalışır (build.sh step3_7 tarafından kopyalanıp çağrılır).
# Hailo PCIe kernel driver'ını DKMS ile derler ve kurar.
# Girdi: /root/hailort-src.tar.gz (hailo-ai/hailort-drivers kaynak tarball)
# Çıktı: /lib/modules/<kernelver>/updates/hailo_pcie.ko (kurulu)

set -euo pipefail

HAILO_VERSION="${HAILO_VERSION:?HAILO_VERSION ayarlanmamış}"

echo "[chroot-hailo] Hailo PCIe kernel driver DKMS kurulumu (v${HAILO_VERSION})"

# Kernel versiyonunu tespit et (linux-rpi-16k tarafından kuruldu)
kernel_ver=$(ls /lib/modules/ | grep rpi-16k | head -1)
if [[ -z "$kernel_ver" ]]; then
    echo "[chroot-hailo] HATA: /lib/modules/ altında rpi-16k kernel bulunamadı" >&2
    exit 1
fi
echo "[chroot-hailo] Hedef kernel: $kernel_ver"

# Kaynak tarball'ı extract et
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "[chroot-hailo] Kaynak extract ediliyor"
tar -xzf /root/hailort-src.tar.gz -C "$TMPDIR"

# Tarball genellikle hailort-drivers-<version>/ dizinine çıkar
src_root=$(find "$TMPDIR" -maxdepth 1 -type d -name "hailort-drivers-*" | head -1)
if [[ -z "$src_root" ]]; then
    echo "[chroot-hailo] HATA: hailort-drivers-* dizini tarball'da bulunamadı" >&2
    exit 1
fi

# DKMS için kaynak /usr/src/hailort-<version>/ altında olmalı.
# hailort-drivers repo'su kendi dkms.conf'unu içeriyor.
dkms_src="/usr/src/hailort-${HAILO_VERSION}"
if [[ -d "$dkms_src" ]]; then
    echo "[chroot-hailo] Mevcut DKMS kaynağı temizleniyor: $dkms_src"
    dkms remove "hailort/${HAILO_VERSION}" --all --force 2>/dev/null || true
    rm -rf "$dkms_src"
fi
cp -r "$src_root" "$dkms_src"

# dkms.conf konumunu bul (repo root'unda veya alt dizinde olabilir)
dkms_conf=$(find "$dkms_src" -name "dkms.conf" | head -1)
if [[ -z "$dkms_conf" ]]; then
    echo "[chroot-hailo] HATA: dkms.conf kaynak dizininde bulunamadı" >&2
    exit 1
fi

# dkms.conf repo root'ta değilse, alt dizini DKMS kaynağı olarak ayarla
dkms_conf_dir=$(dirname "$dkms_conf")
if [[ "$dkms_conf_dir" != "$dkms_src" ]]; then
    echo "[chroot-hailo] dkms.conf alt dizinde: $dkms_conf_dir — yeniden düzenleniyor"
    new_src="/usr/src/hailort-${HAILO_VERSION}"
    rm -rf "$new_src"
    cp -r "$dkms_conf_dir" "$new_src"
    dkms_src="$new_src"
fi

echo "[chroot-hailo] DKMS add: hailort/${HAILO_VERSION}"
dkms add "hailort/${HAILO_VERSION}"

echo "[chroot-hailo] DKMS build: hailort/${HAILO_VERSION} -k ${kernel_ver}"
dkms build "hailort/${HAILO_VERSION}" --kernelver "$kernel_ver"

echo "[chroot-hailo] DKMS install: hailort/${HAILO_VERSION} -k ${kernel_ver}"
dkms install "hailort/${HAILO_VERSION}" --kernelver "$kernel_ver"

echo "[chroot-hailo] depmod -a ${kernel_ver}"
depmod -a "$kernel_ver"

echo "[chroot-hailo] tamamlandı — hailo_pcie.ko kuruldu"
