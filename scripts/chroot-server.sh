#!/usr/bin/env bash
#
# nspawn içinde çalışır (build.sh adım 3 — server profili).
# KDE/SDDM yok; Ollama + SSH + Tailscale + headless provisioning içeriyor.
#
# bkz. notes/04-arch-pivot.md, notes/02-build-pipeline.md

set -euo pipefail

PROFILE="server"
# shellcheck source=chroot-common.sh
source /root/chroot-common.sh

echo "[chroot-server] varsayılan target = multi-user (grafik arayüz yok)"
systemctl set-default multi-user.target

echo "[chroot-server] tamamlandı (server profili)"
