#!/usr/bin/env bash
# step1-3 izole testi.
# build.sh'i source eder (main otomatik çalışmaz), step1+step2'yi gerçek
# haliyle, step3'ü ise minimal chroot-install-test.sh ile çalıştırır.
# Script bitince (normal/hatalı fark etmez) build.sh'in trap cleanup'ı
# mount/loop'u otomatik temizler.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build.sh"

echo "########## TEST: step1 (grow image) ##########"
step1_grow_image

echo "########## TEST: step2 (mount) ##########"
step2_mount

echo "########## TEST: step3 (minimal nspawn) ##########"
cp "$SCRIPT_DIR/chroot-install-test.sh" "$MNT/root/chroot-install-test.sh"
chmod +x "$MNT/root/chroot-install-test.sh"

# Ollama tar.zst'sini host'tan (native, hızlı) önbellekten kopyala —
# qemu altında curl ile indirmek aşırı yavaş.
cp -v "$BASE_DIR/build/cache/ollama-linux-arm64.tar.zst" "$MNT/root/ollama-linux-arm64.tar.zst"

systemd-nspawn \
    --quiet \
    -D "$MNT" \
    -M "$NSPAWN_MACHINE" \
    --resolv-conf=bind-host \
    /root/chroot-install-test.sh

rm -f "$MNT/root/chroot-install-test.sh"

echo "########## TEST TAMAMLANDI — cleanup (trap) çalışacak ##########"
