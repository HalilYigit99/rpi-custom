#!/usr/bin/env bash
#
# nspawn içinde çalışır (build.sh adım 3 — desktop profili).
# Ortak kurulumu chroot-common.sh'e devredip KDE/KRDP/lazy-start/SDDM
# yapılandırmasını üstlenir.
#
# bkz. notes/04-arch-pivot.md, notes/02-build-pipeline.md

set -euo pipefail

PROFILE="desktop"
# shellcheck source=chroot-common.sh
source /root/chroot-common.sh

# ---------------------------------------------------------------------------
# KDE icon teması
# ---------------------------------------------------------------------------
echo "[chroot-desktop] Varsayılan ikon teması: Papirus-Dark"
mkdir -p /root/.config
cat > /root/.config/kdeglobals <<'EOF'
[Icons]
Theme=Papirus-Dark
EOF

# ---------------------------------------------------------------------------
# PipeWire — root için aktif etme
# pipewire.service/.socket varsayılan olarak ConditionUser=!root taşıyor.
# Root/root modelinde PipeWire başlamıyor → KWin "Failed to connect PipeWire
# context" → KRDP --plasma ekran akışı nullptr, bembeyaz ekran.
# ---------------------------------------------------------------------------
echo "[chroot-desktop] PipeWire'ı root için aktif etme (ConditionUser=!root kaldırılıyor)"
mkdir -p /etc/systemd/user/pipewire.service.d /etc/systemd/user/pipewire.socket.d
printf '[Unit]\nConditionUser=\n' > /etc/systemd/user/pipewire.service.d/override.conf
printf '[Unit]\nConditionUser=\n' > /etc/systemd/user/pipewire.socket.d/override.conf
systemctl --global enable pipewire.socket wireplumber.service

# ---------------------------------------------------------------------------
# KRDP TLS sertifikası
# krdpserver sertifikasız başlatılamıyor — otomatik geçici sertifika üretimi
# çalışmıyor, bu yüzden self-signed build zamanında üretiliyor.
# ---------------------------------------------------------------------------
echo "[chroot-desktop] KRDP TLS sertifikası üretiliyor"
mkdir -p /etc/krdp
openssl req -x509 -newkey rsa:2048 -keyout /etc/krdp/krdp.key -out /etc/krdp/krdp.crt \
    -days 3650 -nodes -subj '/CN=pi5'
chmod 600 /etc/krdp/krdp.key

# ---------------------------------------------------------------------------
# KRDP fix — 3 upstream bug (krdp 6.6.5)
# 1. activeStream() nullptr → bembeyaz ekran
# 2. FakeInput authenticate() eksik → klavye çalışmıyor
# 3. wl_fixed_from_double() eksik → fare 256x küçük koordinat
# /root/krdp-fix içindeki ikili dosyalar Pi5'te (aarch64) derlenmiş yamalar.
# ---------------------------------------------------------------------------
echo "[chroot-desktop] KRDP --plasma fix (nullptr + fake-input authenticate + fare koordinat)"
install -m755 /root/krdp-fix/libKRdp.so.6.6.5 /usr/lib/libKRdp.so.6.6.5
install -m755 /root/krdp-fix/krdpserver /usr/bin/krdpserver
ldconfig
rm -rf /root/krdp-fix

# ---------------------------------------------------------------------------
# KRDP otomatik başlatma (--plasma, KWallet'sız, root/root)
# ---------------------------------------------------------------------------
echo "[chroot-desktop] KRDP otomatik başlatma"
mkdir -p /etc/systemd/user/app-org.kde.krdpserver.service.d
cat > /etc/systemd/user/app-org.kde.krdpserver.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/krdpserver --plasma -u root -p root --port 3389 --monitor 0 --certificate /etc/krdp/krdp.crt --certificate-key /etc/krdp/krdp.key
EOF
systemctl --global enable app-org.kde.krdpserver.service

# Sistem Ayarları > "Uzak Masaüstü" KCM'nin root'u görmesi ve açık gelmesi için
# kullanıcı seviyesi sembolik bağ + krdpserverrc gerekiyor.
echo "[chroot-desktop] KRDP Sistem Ayarları: root kullanıcısı görünür + açık"
mkdir -p /root/.config/systemd/user/plasma-workspace.target.wants
ln -sf /usr/lib/systemd/user/app-org.kde.krdpserver.service \
    /root/.config/systemd/user/plasma-workspace.target.wants/app-org.kde.krdpserver.service

cat > /root/.config/krdpserverrc <<'EOF'
[General]
AutogenerateCertificates=false
Certificate=/etc/krdp/krdp.crt
CertificateKey=/etc/krdp/krdp.key
ListenPort=3389

[Users][root]
SystemUserEnabled=true
EOF

# xdg-desktop-portal app ID uyumsuzluğu: krdpserver "org.kde.krdp-server"
# (tireli) ID ile kayıt deniyor ama masaüstü dosyası tiresiz — "Could not
# register app ID" hatası. Tireli kopya ekleniyor.
echo "[chroot-desktop] xdg-desktop-portal app ID düzeltmesi (org.kde.krdp-server.desktop)"
sed 's/^Exec=.*/Exec=\/usr\/bin\/krdpserver/' /usr/share/applications/org.kde.krdpserver.desktop \
    > /usr/share/applications/org.kde.krdp-server.desktop
update-desktop-database /usr/share/applications

# ---------------------------------------------------------------------------
# KDE Plasma lazy-start
# Varsayılan boot hedefi = multi-user.target (SDDM/Plasma açılmıyor).
# Plasma yalnızca şu durumlarda tetikleniyor:
#   1) 3389'a bağlantı denemesi gelirse (socket activation)
#   2) HDMI ekran takılırsa (udev drm change event)
# "Lazy unload" YOK — Plasma bir kez açıldıktan sonra kapatılmıyor.
# ---------------------------------------------------------------------------
echo "[chroot-desktop] KDE lazy-start: krdp-trigger.socket + HDMI hotplug udev rule"
cat > /usr/local/bin/krdp-lazy-trigger.sh <<'EOF'
#!/bin/sh
systemctl is-active --quiet graphical.target && exit 0
systemctl stop --no-block krdp-trigger.socket
systemctl isolate --no-block graphical.target
EOF
chmod +x /usr/local/bin/krdp-lazy-trigger.sh

cat > /etc/systemd/system/krdp-trigger.socket <<'EOF'
[Unit]
Description=KRDP lazy-start tetikleyici (3389 dinleyici)

[Socket]
ListenStream=3389
Accept=no

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/krdp-trigger.service <<'EOF'
[Unit]
Description=KRDP bağlantı denemesi — Plasma başlatılıyor

[Service]
Type=oneshot
ExecStart=/usr/local/bin/krdp-lazy-trigger.sh
EOF

systemctl enable krdp-trigger.socket

mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-hdmi-hotplug.rules <<'EOF'
SUBSYSTEM=="drm", ACTION=="change", RUN+="/usr/local/bin/krdp-lazy-trigger.sh"
EOF

# Boot anında monitör zaten takılıysa "change" event gelmez (sadece "add" gelir).
# Bu durumu yakalamak için boot-time tek seferlik kontrol:
cat > /usr/local/bin/krdp-lazy-boot-check.sh <<'EOF'
#!/bin/sh
for f in /sys/class/drm/card*-HDMI-A-*/status; do
    [ -e "$f" ] || continue
    if [ "$(cat "$f")" = "connected" ]; then
        exec /usr/local/bin/krdp-lazy-trigger.sh
    fi
done
EOF
chmod +x /usr/local/bin/krdp-lazy-boot-check.sh

cat > /etc/systemd/system/krdp-lazy-boot-check.service <<'EOF'
[Unit]
Description=Boot anında monitör takılıysa Plasma'yı başlat
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/krdp-lazy-boot-check.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable krdp-lazy-boot-check.service

# ---------------------------------------------------------------------------
# First-boot: panele CPU/RAM widget ekle (Plasma Scripting API)
# ---------------------------------------------------------------------------
echo "[chroot-desktop] First-boot: panel CPU/RAM widget'ları"
cat > /usr/local/sbin/firstboot-plasma-layout.sh <<'EOF'
#!/bin/bash
set -euo pipefail

MARKER=/var/lib/rpi-custom/firstboot-plasma-layout.done
[[ -f "$MARKER" ]] && exit 0

for _ in $(seq 1 60); do
    if busctl --user list 2>/dev/null | grep -q org.kde.plasmashell; then
        break
    fi
    sleep 2
done

busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s '
var p = panels()[0];
var cpu = p.addWidget("org.kde.plasma.systemmonitor.cpu");
cpu.currentConfigGroup = ["Appearance"];
cpu.writeConfig("totalSensors", ["cpu/all/usage"]);
var mem = p.addWidget("org.kde.plasma.systemmonitor.memory");
mem.currentConfigGroup = ["Appearance"];
mem.writeConfig("totalSensors", ["memory/physical/usedPercent"]);
p.reloadConfig();
'

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
EOF
chmod +x /usr/local/sbin/firstboot-plasma-layout.sh

mkdir -p /etc/systemd/user
cat > /etc/systemd/user/firstboot-plasma-layout.service <<'EOF'
[Unit]
Description=First-boot Plasma panel layout (CPU/RAM widget)
After=plasma-workspace.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-plasma-layout.sh
RemainAfterExit=yes

[Install]
WantedBy=plasma-workspace.target
EOF
systemctl --global enable firstboot-plasma-layout.service

# ---------------------------------------------------------------------------
# SDDM + lazy-start
# sddm.service enable ama varsayılan target = multi-user.target.
# graphical.target yalnızca krdp-trigger veya HDMI hotplug tarafından tetikleniyor.
# ---------------------------------------------------------------------------
echo "[chroot-desktop] SDDM enable + varsayılan target = multi-user (lazy-start)"
systemctl enable sddm.service
systemctl set-default multi-user.target

echo "[chroot-desktop] SDDM root autologin"
mkdir -p /etc/sddm.conf.d
# DisplayServer=wayland: Pi5 vc4 modesetting sürücüsünde SDDM Xorg başlatmaya
# çalışınca "No devices detected" ile çöküyor — kwin_wayland doğrudan KMS/DRM.
cat > /etc/sddm.conf.d/rpi-custom.conf <<'EOF'
[General]
DisplayServer=wayland

[Autologin]
User=root
Session=plasma.desktop
Relogin=true

[Users]
MinimumUid=0
EOF

echo "[chroot-desktop] PAM: SDDM root login engeli kaldırılıyor"
for f in /etc/pam.d/sddm /etc/pam.d/sddm-greeter /etc/pam.d/sddm-autologin; do
    if [[ -f "$f" ]]; then
        sed -i '/pam_succeed_if\.so user != root/d' "$f"
    fi
done

# ---------------------------------------------------------------------------
# X11/Wayland klavye düzeni
# KEYMAP=trq TTY için, localectl kullanılamadığından (chroot'ta systemd-localed
# çalışmıyor) XKB ayarı doğrudan yazılıyor.
# ---------------------------------------------------------------------------
echo "[chroot-desktop] X11/Wayland klavye düzeni: tr (Türkçe Q)"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "tr"
EndSection
EOF

# ---------------------------------------------------------------------------
# Icon cache + font cache (desktop-only paketler kurulduktan sonra bir kez)
# ---------------------------------------------------------------------------
echo "[chroot-desktop] icon-cache + fc-cache (tek seferlik)"
gtk-update-icon-cache -f -t /usr/share/icons/Papirus-Dark >/dev/null 2>&1 || true
gtk-update-icon-cache -f -t /usr/share/icons/breeze >/dev/null 2>&1 || true
gtk-update-icon-cache -f -t /usr/share/icons/breeze-dark >/dev/null 2>&1 || true
fc-cache -f >/dev/null 2>&1 || true

echo "[chroot-desktop] tamamlandı (desktop profili)"
