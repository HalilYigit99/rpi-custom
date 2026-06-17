#!/usr/bin/env bash
#
# chroot-desktop.sh veya chroot-server.sh tarafından nspawn içinde source edilir.
# Doğrudan çalıştırılmaz — PROFILE değişkeni source edilmeden önce ayarlanmış olmalı.
#
# bkz. notes/04-arch-pivot.md, notes/02-build-pipeline.md

: "${PROFILE:?PROFILE değişkeni ayarlanmamış (chroot-desktop.sh veya chroot-server.sh tarafından set edilmeli)}"

# ---------------------------------------------------------------------------
# pacman yapılandırması
# ---------------------------------------------------------------------------
echo "[chroot-common] pacman sandbox devre dışı (nspawn + Landlock uyumsuzluğu)"
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi

echo "[chroot-common] pacman: ParallelDownloads=5"
if grep -q '^#ParallelDownloads' /etc/pacman.conf; then
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
elif ! grep -q '^ParallelDownloads' /etc/pacman.conf; then
    sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf
fi

echo "[chroot-common] pacman keyring kontrolü"
if ! pacman-key --list-keys >/dev/null 2>&1; then
    pacman-key --init
    pacman-key --populate archlinuxarm
fi

echo "[chroot-common] mirrorlist: yedek mirror'lar ekleniyor"
cat >> /etc/pacman.d/mirrorlist <<'EOF'
Server = http://de.mirror.archlinuxarm.org/$arch/$repo
Server = http://fr.mirror.archlinuxarm.org/$arch/$repo
Server = http://nj.us.mirror.archlinuxarm.org/$arch/$repo
EOF

echo "[chroot-common] pacman -Syu"
pacman -Syu --noconfirm

# ---------------------------------------------------------------------------
# Yavaş ALPM hook'larını geçici devre dışı bırakma
# mkinitcpio, gtk-update-icon-cache, fc-cache — qemu altında her transaction'da
# tetiklenince onlarca dakika kaybettiriyor; bulk install boyunca durdurulup
# script sonunda tek seferlik elle çalıştırılıyor.
# ---------------------------------------------------------------------------
echo "[chroot-common] yavaş ALPM hook'ları geçici devre dışı (mkinitcpio, icon-cache, fc-cache)"
DISABLED_HOOKS_DIR=/root/disabled-hooks
mkdir -p "$DISABLED_HOOKS_DIR"
for pattern in mkinitcpio gtk-update-icon-cache fc-cache; do
    for hook in /usr/share/libalpm/hooks/*"$pattern"*; do
        [[ -e "$hook" ]] && mv "$hook" "$DISABLED_HOOKS_DIR/"
    done
done

echo "[chroot-common] generic linux-aarch64 kernel kaldırılıyor (linux-rpi-16k ile çakışmasın)"
if pacman -Q linux-aarch64 >/dev/null 2>&1; then
    pacman -R --noconfirm linux-aarch64
fi

# ---------------------------------------------------------------------------
# Paket kurulumu — tüm paketler tek transaction'da
# ---------------------------------------------------------------------------
COMMON_PKGS=(
    linux-rpi-16k
    raspberrypi-bootloader
    firmware-raspberrypi
    parted
    e2fsprogs
    networkmanager
    wireless-regdb
    openssh
    tailscale
    zram-generator
    ananicy-cpp
    raspberrypi-utils
    # Kamera HAT desteği (CSI / libcamera tabanlı)
    # rpicam-apps ve python-picamera2 ALARM repo'larında YOK — AUR veya
    # cihazda manuel kurulum gerekiyor.
    libcamera
    v4l-utils
    # DKMS + kernel headers — Hailo ve diğer üçüncü taraf kernel module'leri için.
    # Cihazda kernel güncellendiğinde hailo_pcie.ko otomatik yeniden derlenir.
    dkms
    linux-rpi-16k-headers
    base-devel
    cmake
)

DESKTOP_PKGS=(
    plasma-desktop
    plasma-workspace
    kwin
    sddm
    konsole
    dolphin
    kate
    ark
    spectacle
    firefox
    krdp
    plasma-nm
    plasma-systemmonitor
    papirus-icon-theme
    kvantum
    kvantum-theme-materia
    kscreen
)

if [[ "$PROFILE" == "desktop" ]]; then
    echo "[chroot-common] paketler tek transaction'da (profil: desktop)"
    pacman -S --noconfirm --needed "${COMMON_PKGS[@]}" "${DESKTOP_PKGS[@]}"
else
    echo "[chroot-common] paketler tek transaction'da (profil: server)"
    pacman -S --noconfirm --needed "${COMMON_PKGS[@]}"
fi

# ---------------------------------------------------------------------------
# cmdline.txt: SD kart sabit yolu yerine LABEL kullan (USB/SD bağımsız boot)
# ---------------------------------------------------------------------------
echo "[chroot-common] cmdline.txt: root=/dev/mmcblk0p2 -> root=LABEL=ROOTFS"
sed -i 's#root=/dev/mmcblk0p2#root=LABEL=ROOTFS#' /boot/cmdline.txt

# ---------------------------------------------------------------------------
# config.txt: PCIe 3.0 + overclock (2.8GHz CPU / 900MHz GPU)
# ---------------------------------------------------------------------------
# PCIe 3.0: BCM2712 destekliyor, varsayılan 2.0 — Hailo AI HAT+ throughput için
# gerekli (model yükleme + inference ~2x daha hızlı).
# Overclock: 2.8GHz/900MHz Pi5'te fiziksel stres testinde doğrulandı (+50mV).
# 3.0GHz/1.0GHz denenip kararsız bulundu (RCU stall + GPU flip_done zaman aşımı).
echo "[chroot-common] config.txt: PCIe 3.0 + overclock (2.8GHz/900MHz/+50mV)"
cat >> /boot/config.txt <<'EOF'

# --- rpi-custom ---
# PCIe 3.0 (Hailo AI HAT+ ve NVMe için ~2x bant genişliği)
dtparam=pciex1_gen=3

# Overclock: 2.8GHz CPU / 900MHz GPU (+50mV) — Pi5 stres testinde doğrulandı
arm_freq=2800
gpu_freq=900
over_voltage_delta=50000
EOF

# ---------------------------------------------------------------------------
# NetworkManager
# ---------------------------------------------------------------------------
echo "[chroot-common] NetworkManager enable, systemd-networkd disable"
systemctl enable NetworkManager.service
# ALARM'da NetworkManager-wait-online varsayılan olarak enabled DEĞİL —
# network-online.target (tailscale provisioning'in bağımlısı) için gerekli.
systemctl enable NetworkManager-wait-online.service
systemctl disable systemd-networkd.service systemd-networkd.socket || true

# Pi5 brcmfmac WiFi driver'ı: regulatory domain ayarlı değilse her kanal için
# "brcmf_set_channel: set chanspec fail, reason -52" loglarına dolduruyor.
echo "[chroot-common] WiFi regulatory domain: TR"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/cfg80211.conf <<'EOF'
options cfg80211 ieee80211_regdom=TR
EOF

# ---------------------------------------------------------------------------
# OpenSSH
# ---------------------------------------------------------------------------
echo "[chroot-common] OpenSSH enable + PermitRootLogin yes"
systemctl enable sshd.service
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/rpi-custom.conf <<'EOF'
PermitRootLogin yes
EOF

# ---------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------
echo "[chroot-common] Tailscale enable (up ÇALIŞTIRILMIYOR)"
systemctl enable tailscaled.service

# ---------------------------------------------------------------------------
# zram + sysctl
# ---------------------------------------------------------------------------
echo "[chroot-common] zram-generator (2GB, zstd)"
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = 2048
compression-algorithm = zstd
EOF

echo "[chroot-common] sysctl: vm.swappiness=10"
cat > /etc/sysctl.d/99-rpi-custom.conf <<'EOF'
vm.swappiness=10
EOF

# ---------------------------------------------------------------------------
# CPU governor: performance (Pi5 batarya kullanmıyor, frekans gecikmesi istemiyoruz)
# ---------------------------------------------------------------------------
echo "[chroot-common] CPU governor: performance"
cat > /etc/systemd/system/cpu-governor-performance.service <<'EOF'
[Unit]
Description=CPU governor: performance

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f"; done'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable cpu-governor-performance.service

# ---------------------------------------------------------------------------
# ananicy-cpp — CachyOS kural seti + özel ollama kuralı
# plasmashell/kwin LowLatency_RT, ollama cpu85 cgroup
# ---------------------------------------------------------------------------
echo "[chroot-common] ananicy-cpp kuralları"
mkdir -p /etc/ananicy.d
cp -r /root/ananicy-rules/* /etc/ananicy.d/
rm -rf /root/ananicy-rules
systemctl enable ananicy-cpp.service

# ---------------------------------------------------------------------------
# Ollama — manuel tar.zst kurulumu (qemu altında curl aşırı yavaş)
# ---------------------------------------------------------------------------
echo "[chroot-common] Ollama (önbellekteki tar.zst'den manuel kurulum)"
tar --zstd -xf /root/ollama-linux-arm64.tar.zst -C /usr/local
rm -f /root/ollama-linux-arm64.tar.zst

if ! id ollama >/dev/null 2>&1; then
    useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
fi

echo "[chroot-common] Ollama model dizini: /srv/ollama/models"
mkdir -p /srv/ollama/models
chown -R ollama:ollama /srv/ollama
chmod 2775 /srv/ollama /srv/ollama/models

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
Environment="OLLAMA_MODELS=/srv/ollama/models"

[Install]
WantedBy=default.target
EOF

mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
MemorySwapMax=0
EOF

systemctl enable ollama.service

# ---------------------------------------------------------------------------
# Kullanıcı — tek kullanıcı = root, şifre = root
# ---------------------------------------------------------------------------
echo "[chroot-common] varsayılan 'alarm' kullanıcısı kaldırılıyor"
if id alarm >/dev/null 2>&1; then
    userdel -r alarm || true
fi
rm -f /etc/sudoers.d/*alarm* 2>/dev/null || true

echo "[chroot-common] root şifresi = root"
echo "root:root" | chpasswd

# ---------------------------------------------------------------------------
# Headless provisioning — BOOT/pi-provision/ üzerinden WiFi + Tailscale
# ---------------------------------------------------------------------------
echo "[chroot-common] headless provisioning scriptleri ve servisleri"
mkdir -p /usr/local/bin /var/lib/pi-provision

cat > /usr/local/bin/pi-provision.sh <<'PROVEOF'
#!/bin/bash
set -euo pipefail

PROVISION_DIR="/var/lib/pi-provision"
mkdir -p "$PROVISION_DIR"

# BOOT partition'ı bul
BOOT_DEV=$(blkid -L BOOT 2>/dev/null || true)
if [[ -z "$BOOT_DEV" ]]; then
    echo "pi-provision: BOOT partition bulunamadı, atlanıyor"
    exit 0
fi

BOOT_MOUNT=$(mktemp -d)
mount -o uid=0,gid=0,fmask=0177,dmask=0077,rw "$BOOT_DEV" "$BOOT_MOUNT"

PROVISION_PATH="$BOOT_MOUNT/pi-provision"
if [[ ! -d "$PROVISION_PATH" ]]; then
    echo "pi-provision: $BOOT_MOUNT/pi-provision bulunamadı, atlanıyor"
    umount "$BOOT_MOUNT"
    rmdir "$BOOT_MOUNT"
    exit 0
fi

mkdir -p /etc/NetworkManager/system-connections

# WiFi yapılandırması — wifi-*.conf dosyalarını .nmconnection'a dönüştür
for wifi_file in "$PROVISION_PATH"/wifi-*.conf; do
    [[ -f "$wifi_file" ]] || continue
    ssid="" psk="" hidden="false"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            ssid)   ssid="$val" ;;
            psk)    psk="$val"  ;;
            hidden) hidden="$val" ;;
        esac
    done < "$wifi_file"
    if [[ -n "$ssid" && -n "$psk" ]]; then
        NM_CONN="/etc/NetworkManager/system-connections/${ssid}.nmconnection"
        cat > "$NM_CONN" <<EOF
[connection]
id=${ssid}
type=wifi
autoconnect=true

[wifi]
ssid=${ssid}
hidden=${hidden}

[wifi-security]
key-mgmt=wpa-psk
psk=${psk}

[ipv4]
method=auto

[ipv6]
method=ignore
EOF
        chmod 600 "$NM_CONN"
        echo "pi-provision: WiFi eklendi: $ssid"
    fi
done

# Tailscale auth key
TS_FILE="$PROVISION_PATH/tailscale.conf"
if [[ -f "$TS_FILE" ]]; then
    authkey=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$key" == "authkey" ]] && authkey="$val"
    done < "$TS_FILE"
    if [[ -n "$authkey" ]]; then
        echo "$authkey" > "$PROVISION_DIR/tailscale-authkey"
        chmod 600 "$PROVISION_DIR/tailscale-authkey"
        echo "pi-provision: Tailscale auth key kaydedildi"
    fi
fi

# Provision dosyalarını sil (tek seferlik)
rm -rf "$PROVISION_PATH"
sync
umount "$BOOT_MOUNT"
rmdir "$BOOT_MOUNT"

echo "pi-provision: tamamlandı"
PROVEOF
chmod +x /usr/local/bin/pi-provision.sh

cat > /usr/local/bin/pi-provision-tailscale.sh <<'TSEOF'
#!/bin/bash
set -euo pipefail

KEY_FILE="/var/lib/pi-provision/tailscale-authkey"
[[ -f "$KEY_FILE" ]] || exit 0

AUTHKEY=$(cat "$KEY_FILE")
if [[ -z "$AUTHKEY" ]]; then
    echo "pi-provision-tailscale: auth key boş"
    exit 1
fi

if tailscale up --authkey="$AUTHKEY" --accept-dns=true --accept-routes=false; then
    rm -f "$KEY_FILE"
    echo "pi-provision-tailscale: Tailscale bağlandı, auth key silindi"
else
    echo "pi-provision-tailscale: 'tailscale up' başarısız, yeniden denenecek" >&2
    exit 1
fi
TSEOF
chmod +x /usr/local/bin/pi-provision-tailscale.sh

cat > /etc/systemd/system/pi-provision.service <<'EOF'
[Unit]
Description=İlk-boot headless provisioning (WiFi + Tailscale auth key)
After=local-fs.target
Before=NetworkManager.service
DefaultDependencies=no
ConditionPathExists=!/var/lib/pi-provision/.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pi-provision.sh
ExecStartPost=/bin/touch /var/lib/pi-provision/.done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pi-provision-tailscale.service <<'EOF'
[Unit]
Description=İlk-boot Tailscale kimlik doğrulama
After=network-online.target tailscaled.service
Wants=network-online.target
ConditionPathExists=/var/lib/pi-provision/tailscale-authkey

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pi-provision-tailscale.sh
Restart=on-failure
RestartSec=30
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable pi-provision.service
systemctl enable pi-provision-tailscale.service

# ---------------------------------------------------------------------------
# Lokalizasyon
# ---------------------------------------------------------------------------
HOSTNAME="pi5"
[[ "$PROFILE" == "server" ]] && HOSTNAME="pi5-server"

echo "[chroot-common] Lokalizasyon: tr_TR + en_US, Europe/Istanbul, KEYMAP=trq, hostname=$HOSTNAME"
sed -i \
    -e 's/^#tr_TR.UTF-8 UTF-8/tr_TR.UTF-8 UTF-8/' \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    /etc/locale.gen
locale-gen
echo "LANG=tr_TR.UTF-8" > /etc/locale.conf
echo "KEYMAP=trq" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime

# ---------------------------------------------------------------------------
# Hook restore + mkinitcpio
# ---------------------------------------------------------------------------
echo "[chroot-common] devre dışı bırakılan hook'lar geri yükleniyor"
if [[ -d "$DISABLED_HOOKS_DIR" ]]; then
    mv "$DISABLED_HOOKS_DIR"/* /usr/share/libalpm/hooks/ 2>/dev/null || true
    rmdir "$DISABLED_HOOKS_DIR"
fi

echo "[chroot-common] mkinitcpio -P"
if mkinitcpio -P; then
    touch /var/lib/rpi-custom-initramfs-ok
else
    echo "[chroot-common] UYARI: mkinitcpio başarısız, build.sh adım 3.5 host chroot ile yeniden deneyecek" >&2
fi
