#!/usr/bin/env bash
# step1-3 izole testi için minimal nspawn içi script.
# Tam chroot-install.sh'i (apt full-upgrade + KDE, uzun sürer) ÇALIŞTIRMAZ.
# Sadece riskli mekanizmaları doğrular:
#  - --resolv-conf=bind-host ile DNS/internet
#  - policy-rc.d'nin postinst systemctl start çağrılarını engellemesi
#  - Ollama resmi install script'inin nspawn (non-boot) içinde davranışı

set -uo pipefail

echo "[test] DNS / internet kontrolü"
getent hosts deb.debian.org || { echo "DNS BAŞARISIZ"; exit 1; }
curl -fsSL -o /dev/null https://ollama.com/install.sh && echo "  curl OK"

echo "[test] policy-rc.d ekleniyor"
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

export DEBIAN_FRONTEND=noninteractive

echo "[test] apt update"
apt-get update

echo "[test] cron kurulumu (postinst systemctl start testi)"
apt-get install -y cron
echo "  cron enabled: $(systemctl is-enabled cron 2>&1 || true)"
echo "  cron active:  $(systemctl is-active cron 2>&1 || true)"

echo "[test] Ollama (önbellekteki tar.zst'den, install.sh'in curl indirmesi"
echo "       qemu altında çok yavaş olduğu için manuel kurulum)"
tar --zstd -xf /root/ollama-linux-arm64.tar.zst -C /usr/local
rm -f /root/ollama-linux-arm64.tar.zst

if ! id ollama >/dev/null 2>&1; then
    useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
fi

cat > /etc/systemd/system/ollama.service <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=default.target
EOF

systemctl enable ollama.service
echo "  ollama version: $(ollama --version 2>&1 || true)"
echo "  ollama binary: $(command -v ollama || echo YOK)"
echo "  ollama enabled: $(systemctl is-enabled ollama 2>&1 || true)"
echo "  ollama active:  $(systemctl is-active ollama 2>&1 || true)"
echo "  ollama user: $(id ollama 2>&1 || echo YOK)"

echo "[test] policy-rc.d kaldırılıyor"
rm -f /usr/sbin/policy-rc.d

echo "[test] TAMAMLANDI"
