#!/usr/bin/env bash
#
# rpi-custom build orkestratörü.
# Arch Linux ARM (aarch64) tabanlı Pi5 imajı sıfırdan oluşturur.
# Kullanım: bash build.sh [desktop|server|prefetch]
#   prefetch  — imaj oluşturmadan sadece paketleri shared cache'e indirir,
#               ardından desktop & server paralel başlatılabilir.
#
# bkz. notes/04-arch-pivot.md, notes/02-build-pipeline.md

set -euo pipefail

# ---------------------------------------------------------------------------
# Konfigürasyon
# ---------------------------------------------------------------------------
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$BASE_DIR/build"
SCRIPTS_DIR="$BASE_DIR/scripts"
OUTPUT_DIR="$BASE_DIR/output"

PROFILE="${1:-desktop}"
if [[ "$PROFILE" != "desktop" && "$PROFILE" != "server" && "$PROFILE" != "prefetch" ]]; then
    echo "Kullanım: $0 [desktop|server|prefetch]" >&2
    exit 1
fi

# Her profil kendi alt dizininde çalışır — paralel build'lerde çakışma olmasın.
IMG="$BUILD_DIR/$PROFILE/archpi.img"
MNT="$BUILD_DIR/$PROFILE/mnt"

IMG_SIZE="16G"             # baştan oluşturulan imaj boyutu
BOOT_SIZE_MB=512           # FAT32 boot partition boyutu
SHRINK_MARGIN_MB=512       # shrink sonrası p2'de bırakılacak boş alan
SECTOR_SIZE=512

ALARM_TARBALL_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
# ALARM tarball ve Ollama tarball paylaşımlı (read-only) — her iki profil
# aynı dosyayı okur, yazma yok, çakışma riski yok.
ALARM_TARBALL="$BUILD_DIR/cache/ArchLinuxARM-aarch64-latest.tar.gz"

OLLAMA_SRC="/var/lib/ollama"
OLLAMA_TARBALL="$BUILD_DIR/cache/ollama-linux-arm64.tar.zst"

# Shared pacman cache — her iki profil aynı cache dizinini kullanır.
# pacman package download atomic'tir (temp→rename), paralel nspawn'lar için güvenli.
# Pre-warm adımı (step0) tüm paketleri önceden indirir, paralel build'ler sadece okur.
PACMAN_CACHE_DIR="$BUILD_DIR/cache/pacman-pkg"

OUTPUT_NAME="pi5-arch-${PROFILE}-$(date +%Y%m%d).img"
OUTPUT_IMG="$OUTPUT_DIR/$OUTPUT_NAME"

NSPAWN_MACHINE="pi-build-${PROFILE}"

# ---------------------------------------------------------------------------
# Hailo AI HAT+ konfigürasyonu
# ---------------------------------------------------------------------------
HAILO_VERSION="${HAILO_VERSION:-4.20.0}"
# HAILO_ENABLED=false ile Hailo kurulumu tamamen atlanır.
HAILO_ENABLED="${HAILO_ENABLED:-true}"
HAILO_DEB_URL="https://github.com/hailo-ai/hailort/releases/download/v${HAILO_VERSION}/hailort_${HAILO_VERSION}_arm64.deb"
HAILO_SRC_URL="https://github.com/hailo-ai/hailort-drivers/archive/refs/tags/v${HAILO_VERSION}.tar.gz"
HAILO_DEB_CACHE="$BUILD_DIR/cache/hailort-${HAILO_VERSION}-arm64.deb"
HAILO_SRC_CACHE="$BUILD_DIR/cache/hailort-src-${HAILO_VERSION}.tar.gz"
# .ko cache: kernel versiyonuna göre keyleniyor — kernel update = cache miss = yeniden derle
HAILO_KO_CACHE_TEMPLATE="$BUILD_DIR/cache/hailo-ko-${HAILO_VERSION}-KERNELVER.tar.zst"

# ---------------------------------------------------------------------------
# Sıkıştırma seviyesi — env var ile override edilebilir.
# Hızlı test: XZ_LEVEL=1 bash build.sh desktop  (~3 dk, ~%10 büyük çıktı)
# Dağıtım:    XZ_LEVEL=6 (default, ~20 dk, optimal boyut)
# ---------------------------------------------------------------------------
XZ_LEVEL="${XZ_LEVEL:-6}"

# ---------------------------------------------------------------------------
# Ön kontroller
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Bu script root olarak çalıştırılmalı (losetup/mount/nspawn gerekiyor)." >&2
    exit 1
fi

for cmd in parted losetup mkfs.vfat mkfs.ext4 bsdtar resize2fs e2fsck dumpe2fs sfdisk systemd-nspawn xz ar; do
    command -v "$cmd" >/dev/null || { echo "Eksik bağımlılık: $cmd" >&2; exit 1; }
done

if [[ "$PROFILE" != "prefetch" ]] && [[ ! -f "$OLLAMA_TARBALL" ]]; then
    echo "Ollama tarball bulunamadı, indiriliyor..."
    curl -fL --retry 3 -o "$OLLAMA_TARBALL" \
        "https://ollama.com/download/ollama-linux-arm64.tar.zst"
fi

mkdir -p "$BUILD_DIR/cache" "$BUILD_DIR/$PROFILE"
if [[ ! -f "$ALARM_TARBALL" ]]; then
    echo "ALARM rootfs tarball indiriliyor: $ALARM_TARBALL_URL"
    curl -fL -o "$ALARM_TARBALL" "$ALARM_TARBALL_URL"
fi

# ---------------------------------------------------------------------------
# Eski artifact temizliği
# Profil sistemi öncesi bırakılan büyük dosyalar (Debian ve profil-öncesi build).
# ---------------------------------------------------------------------------
for old_artifact in "$BUILD_DIR/pios.img" "$BUILD_DIR/archpi.img"; do
    if [[ -f "$old_artifact" ]]; then
        echo "Eski artifact siliniyor: $old_artifact ($(numfmt --to=iec "$(stat -c %s "$old_artifact")"))"
        rm -f "$old_artifact"
    fi
done

# ---------------------------------------------------------------------------
# Global state (cleanup için)
# ---------------------------------------------------------------------------
LOOP_DEV=""
BUILD_START=$SECONDS

# ---------------------------------------------------------------------------
# Yardımcı: step süre raporlama
# ---------------------------------------------------------------------------
_step_timer() { echo "  süre: $(( SECONDS - $1 ))s"; }

# ---------------------------------------------------------------------------
# Cleanup — normal çıkış VEYA hata durumunda çağrılır
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    set +e

    # pre-warm rootfs üzerindeki bind-mount (step0'dan kalabilir)
    local prewarm_dir="$BUILD_DIR/cache/prewarm-rootfs"
    if mountpoint -q "$prewarm_dir/var/cache/pacman/pkg" 2>/dev/null; then
        umount "$prewarm_dir/var/cache/pacman/pkg"
    fi

    for sub in sys proc dev; do
        if mountpoint -q "$MNT/$sub" 2>/dev/null; then
            echo "[cleanup] $MNT/$sub unmount ediliyor"
            umount "$MNT/$sub"
        fi
    done

    if mountpoint -q "$MNT/var/cache/pacman/pkg" 2>/dev/null; then
        echo "[cleanup] $MNT/var/cache/pacman/pkg unmount ediliyor"
        umount "$MNT/var/cache/pacman/pkg"
    fi

    if mountpoint -q "$MNT/boot" 2>/dev/null; then
        echo "[cleanup] $MNT/boot unmount ediliyor"
        umount "$MNT/boot"
    fi

    if mountpoint -q "$MNT" 2>/dev/null; then
        echo "[cleanup] $MNT unmount ediliyor"
        umount "$MNT"
    fi

    if [[ -n "$LOOP_DEV" ]] && losetup "$LOOP_DEV" &>/dev/null; then
        echo "[cleanup] $LOOP_DEV detach ediliyor"
        losetup -d "$LOOP_DEV"
    fi

    exit "$exit_code"
}
trap cleanup EXIT TERM INT

# ---------------------------------------------------------------------------
# 0. Paket önbellekleme (pre-warm) — paralel build'ler için
# ---------------------------------------------------------------------------
# Hem desktop hem server profilinin tüm paketlerini shared PACMAN_CACHE_DIR'e
# önceden indirir. Paralel build'ler bu cache'den okuyarak network'e gitmez.
# Sonuç: paralel build'lerde duplicate download yok, rate-limit riski yok.
#
# Son 24 saat içinde zaten çalıştıysa stamp dosyasına bakarak atlanır.
# Yeniden zorlamak için: rm -f build/cache/.prewarm-done
# ---------------------------------------------------------------------------
COMMON_PKGS_PREFETCH=(
    linux-rpi-16k raspberrypi-bootloader firmware-raspberrypi
    parted e2fsprogs networkmanager wireless-regdb openssh tailscale
    zram-generator ananicy-cpp raspberrypi-utils
    libcamera v4l-utils
    dkms linux-rpi-16k-headers base-devel cmake
)
DESKTOP_PKGS_PREFETCH=(
    plasma-desktop plasma-workspace kwin sddm konsole dolphin
    kate ark spectacle firefox krdp plasma-nm plasma-systemmonitor
    papirus-icon-theme kvantum kvantum-theme-materia kscreen
)

step0_prefetch_packages() {
    local t0=$SECONDS
    local stamp="$BUILD_DIR/cache/.prewarm-done"

    # flock ile race condition: iki paralel build aynı anda pre-warm başlatmaz
    (
        flock 200
        if [[ -f "$stamp" ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 86400 )); then
            echo "== 0. Pre-warm atlanıyor (son 24 saat içinde yapıldı) =="
            exit 0
        fi

        echo "== 0. Paket önbellekleme (pre-warm) — tüm paketler shared cache'e =="

        local prewarm_dir="$BUILD_DIR/cache/prewarm-rootfs"
        if [[ ! -d "$prewarm_dir/etc" ]]; then
            echo "  pre-warm rootfs oluşturuluyor (ALARM extract)..."
            mkdir -p "$prewarm_dir"
            bsdtar -xpf "$ALARM_TARBALL" -C "$prewarm_dir"
        fi

        # pacman ayarları (nspawn + Landlock uyumsuzluğu + paralel indirme)
        grep -q '^DisableSandbox' "$prewarm_dir/etc/pacman.conf" || \
            sed -i '/^\[options\]/a DisableSandbox' "$prewarm_dir/etc/pacman.conf"
        grep -q '^ParallelDownloads' "$prewarm_dir/etc/pacman.conf" || \
            sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$prewarm_dir/etc/pacman.conf"

        # Yedek mirror'lar
        grep -q 'de.mirror.archlinuxarm.org' "$prewarm_dir/etc/pacman.d/mirrorlist" || \
            cat >> "$prewarm_dir/etc/pacman.d/mirrorlist" <<'EOF'
Server = http://de.mirror.archlinuxarm.org/$arch/$repo
Server = http://fr.mirror.archlinuxarm.org/$arch/$repo
Server = http://nj.us.mirror.archlinuxarm.org/$arch/$repo
EOF

        mkdir -p "$PACMAN_CACHE_DIR" "$prewarm_dir/var/cache/pacman/pkg"
        mount --bind "$PACMAN_CACHE_DIR" "$prewarm_dir/var/cache/pacman/pkg"

        echo "  paketler indiriliyor (download-only, kurulum yok)..."
        systemd-nspawn --quiet -D "$prewarm_dir" \
            -M "pi-prewarm" \
            --resolv-conf=bind-host -- \
            pacman -Syw --noconfirm --needed \
                "${COMMON_PKGS_PREFETCH[@]}" "${DESKTOP_PKGS_PREFETCH[@]}" || true

        umount "$prewarm_dir/var/cache/pacman/pkg"
        touch "$stamp"
        echo "  pre-warm tamamlandı — paralel build'ler cache'den okuyacak"

    ) 200>"$BUILD_DIR/cache/.prewarm.lock"

    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 1. İmaj oluşturma + partition'lama
# ---------------------------------------------------------------------------
step1_create_image() {
    local t0=$SECONDS
    echo "== 1. İmaj oluşturma ($IMG_SIZE) =="

    truncate -s "$IMG_SIZE" "$IMG"
    parted --script "$IMG" \
        mklabel msdos \
        mkpart primary fat32 1MiB "${BOOT_SIZE_MB}MiB" \
        set 1 lba on \
        mkpart primary ext4 "${BOOT_SIZE_MB}MiB" 100%

    LOOP_DEV=$(losetup -fP --show "$IMG")
    echo "  loop device: $LOOP_DEV"

    mkfs.vfat -F32 -n BOOT "${LOOP_DEV}p1"
    mkfs.ext4 -L ROOTFS "${LOOP_DEV}p2"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 2. Mount + ALARM rootfs extract
# ---------------------------------------------------------------------------
step2_mount_and_extract() {
    local t0=$SECONDS
    echo "== 2. Mount + ALARM rootfs extract =="

    mkdir -p "$MNT"
    mount "${LOOP_DEV}p2" "$MNT"

    echo "  rootfs extract ediliyor (bsdtar)..."
    bsdtar -xpf "$ALARM_TARBALL" -C "$MNT"
    sync

    mkdir -p "$MNT/boot"
    mount "${LOOP_DEV}p1" "$MNT/boot"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 3. nspawn içinde kurulumlar
# ---------------------------------------------------------------------------
step3_nspawn_install() {
    local t0=$SECONDS
    echo "== 3. nspawn içinde kurulumlar (profil: $PROFILE) =="

    local chroot_script="chroot-${PROFILE}.sh"
    cp "$SCRIPTS_DIR/chroot-common.sh" "$MNT/root/chroot-common.sh"
    cp "$SCRIPTS_DIR/$chroot_script" "$MNT/root/$chroot_script"
    chmod +x "$MNT/root/chroot-common.sh" "$MNT/root/$chroot_script"

    # Ollama tar.zst'sini host'tan (native, hızlı) kopyala — qemu altında
    # curl ile indirmek aşırı yavaş.
    cp -v "$OLLAMA_TARBALL" "$MNT/root/ollama-linux-arm64.tar.zst"

    # KRDP --plasma beyaz ekran + fare/klavye fix'i — yalnızca desktop profili.
    if [[ "$PROFILE" == "desktop" ]]; then
        cp -rv "$SCRIPTS_DIR/krdp-fix" "$MNT/root/krdp-fix"
    fi

    # ananicy-cpp kuralları: her iki profilde de ollama cpu85 cgroup gerekiyor.
    cp -rv "$SCRIPTS_DIR/ananicy-rules" "$MNT/root/ananicy-rules"

    # Shared pacman cache bind-mount — paketler önceden indirildi (step0),
    # yalnızca okuma yapılıyor, iki nspawn aynı anda güvenle kullanabilir.
    mkdir -p "$PACMAN_CACHE_DIR" "$MNT/var/cache/pacman/pkg"
    mount --bind "$PACMAN_CACHE_DIR" "$MNT/var/cache/pacman/pkg"

    systemd-nspawn \
        --quiet \
        -D "$MNT" \
        -M "$NSPAWN_MACHINE" \
        --resolv-conf=bind-host \
        /root/"$chroot_script"

    rm -f "$MNT/root/chroot-common.sh" "$MNT/root/$chroot_script"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 3.5 initramfs fallback (host chroot, nspawn DIŞINDA)
# ---------------------------------------------------------------------------
step3_5_fix_initramfs() {
    local t0=$SECONDS
    echo "== 3.5 initramfs fallback (host chroot) =="

    if [[ -f "$MNT/var/lib/rpi-custom-initramfs-ok" ]]; then
        echo "  chroot-common.sh içinde initramfs zaten üretildi, atlanıyor"
        rm -f "$MNT/var/lib/rpi-custom-initramfs-ok"
        _step_timer $t0
        return
    fi

    echo "  initramfs üretilemedi, host chroot ile yeniden deneniyor"
    mount --bind /dev "$MNT/dev"
    mount -t proc proc "$MNT/proc"
    mount --bind /sys "$MNT/sys"

    chroot "$MNT" env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        mkinitcpio -P

    umount "$MNT/sys"
    umount "$MNT/proc"
    umount "$MNT/dev"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 3.7 Hailo AI HAT+ kurulumu
# ---------------------------------------------------------------------------
# İki aşama:
#   A) User-space runtime: hailo .deb'den extract (kernel-agnostik, hızlı)
#   B) Kernel driver: DKMS ile derleme (kernel-specific, önbellekli)
#
# HAILO_ENABLED=false ile tamamen atlanır.
# Kernel değişirse HAILO_KO_CACHE_TEMPLATE'deki dosya yoktur → yeniden derlenir.
# ---------------------------------------------------------------------------
step3_7_build_hailo() {
    local t0=$SECONDS
    echo "== 3.7 Hailo AI HAT+ kurulumu (v${HAILO_VERSION}) =="

    if [[ "$HAILO_ENABLED" != "true" ]]; then
        echo "  HAILO_ENABLED=false, atlanıyor"
        return
    fi

    # ---- A) User-space runtime (.deb extract) --------------------------------
    echo "  [A] User-space runtime (.deb → $MNT)"

    if [[ ! -f "$HAILO_DEB_CACHE" ]]; then
        echo "  hailort .deb indiriliyor: $HAILO_DEB_URL"
        if ! curl -fL --retry 3 -o "$HAILO_DEB_CACHE" "$HAILO_DEB_URL"; then
            echo "  UYARI: hailort .deb indirilemedi (v${HAILO_VERSION} arm64 mevcut olmayabilir)" >&2
            echo "  UYARI: User-space runtime atlanıyor, yalnızca kernel driver kurulacak" >&2
            rm -f "$HAILO_DEB_CACHE"
        fi
    fi

    if [[ -f "$HAILO_DEB_CACHE" ]]; then
        local deb_tmp
        deb_tmp=$(mktemp -d)
        trap 'rm -rf "$deb_tmp"' RETURN

        pushd "$deb_tmp" >/dev/null
        ar x "$HAILO_DEB_CACHE"

        # data.tar'ın sıkıştırma formatı .deb versiyonuna göre değişir
        local data_tar
        data_tar=$(ls data.tar.* 2>/dev/null | head -1)
        if [[ -z "$data_tar" ]]; then
            echo "  UYARI: .deb içinde data.tar bulunamadı, user-space runtime atlanıyor" >&2
        else
            echo "  $data_tar → $MNT"
            tar -xf "$data_tar" -C "$MNT"

            # .deb Debian çok-mimari yolunu kullanıyor (aarch64-linux-gnu/);
            # Arch /usr/lib/ kullandığı için her ikisini ldconfig'e bildiriyoruz.
            mkdir -p "$MNT/etc/ld.so.conf.d"
            echo "/usr/lib/aarch64-linux-gnu" > "$MNT/etc/ld.so.conf.d/hailo.conf"

            echo "  user-space runtime extract edildi"
        fi
        popd >/dev/null
    fi

    # ---- B) Kernel driver (DKMS, önbellekli) --------------------------------
    echo "  [B] Kernel driver (DKMS)"

    local kernel_ver
    kernel_ver=$(ls "$MNT/lib/modules/" | grep rpi-16k | head -1)
    if [[ -z "$kernel_ver" ]]; then
        echo "  UYARI: $MNT/lib/modules/ altında rpi-16k kernel bulunamadı" >&2
        echo "  UYARI: Kernel driver kurulumu atlanıyor" >&2
        _step_timer $t0
        return
    fi
    echo "  Hedef kernel: $kernel_ver"

    local ko_cache="${HAILO_KO_CACHE_TEMPLATE/KERNELVER/$kernel_ver}"

    if [[ -f "$ko_cache" ]]; then
        echo "  Hailo .ko cache'den yükleniyor: $(basename "$ko_cache")"
        tar --zstd -xf "$ko_cache" -C "$MNT"
    else
        echo "  Cache yok — DKMS ile derleniyor (ilk seferinde ~10-20 dk sürebilir)"

        if [[ ! -f "$HAILO_SRC_CACHE" ]]; then
            echo "  hailort-drivers kaynak indiriliyor: $HAILO_SRC_URL"
            curl -fL --retry 3 -o "$HAILO_SRC_CACHE" "$HAILO_SRC_URL" || {
                echo "  UYARI: Kernel driver kaynağı indirilemedi, atlanıyor" >&2
                _step_timer $t0
                return
            }
        fi

        cp "$HAILO_SRC_CACHE" "$MNT/root/hailort-src.tar.gz"
        cp "$SCRIPTS_DIR/chroot-hailo.sh" "$MNT/root/chroot-hailo.sh"
        chmod +x "$MNT/root/chroot-hailo.sh"

        systemd-nspawn \
            --quiet \
            -D "$MNT" \
            -M "${NSPAWN_MACHINE}-hailo" \
            --resolv-conf=bind-host \
            --setenv="HAILO_VERSION=${HAILO_VERSION}" \
            /root/chroot-hailo.sh || {
            echo "  UYARI: DKMS build başarısız oldu — cihazda 'dkms install hailort/${HAILO_VERSION}' ile yeniden denenebilir" >&2
            rm -f "$MNT/root/chroot-hailo.sh" "$MNT/root/hailort-src.tar.gz"
            _step_timer $t0
            return
        }

        rm -f "$MNT/root/chroot-hailo.sh" "$MNT/root/hailort-src.tar.gz"

        # Derlenmiş .ko'yu önbellekle (kernel versiyonuna göre keyleniyor)
        local ko_file="$MNT/lib/modules/$kernel_ver/updates/hailo_pcie.ko"
        if [[ -f "$ko_file" ]]; then
            echo "  .ko önbellekleniyor: $(basename "$ko_cache")"
            tar --zstd -cf "$ko_cache" \
                -C "$MNT" "lib/modules/$kernel_ver/updates/hailo_pcie.ko"
        fi
    fi

    # ---- Post-install -------------------------------------------------------
    echo "  [C] Post-install: depmod + hailo group + udev"

    systemd-nspawn -q -D "$MNT" -- depmod -a "$kernel_ver" || true

    # hailo grubu — /dev/hailo0 erişimi için
    systemd-nspawn -q -D "$MNT" -- \
        bash -c 'getent group hailo >/dev/null || groupadd --system hailo'
    systemd-nspawn -q -D "$MNT" -- gpasswd -a root hailo || true

    # Udev rule — .deb extract'ından gelmemişse manuel yaz
    if [[ ! -f "$MNT/etc/udev/rules.d/99-hailo-udev.rules" ]] && \
       [[ ! -f "$MNT/etc/udev/rules.d/99-hailo.rules" ]]; then
        mkdir -p "$MNT/etc/udev/rules.d"
        cat > "$MNT/etc/udev/rules.d/99-hailo.rules" <<'EOF'
KERNEL=="hailo[0-9]*", MODE="0660", GROUP="hailo"
EOF
        echo "  udev rule yazıldı: /etc/udev/rules.d/99-hailo.rules"
    fi

    # hailort.service varsa enable et (user-space daemon)
    if systemd-nspawn -q -D "$MNT" -- \
            systemctl cat hailort.service >/dev/null 2>&1; then
        systemd-nspawn -q -D "$MNT" -- systemctl enable hailort.service
        echo "  hailort.service enable edildi"
    fi

    echo "  Hailo kurulumu tamamlandı"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 4. Ollama modellerini kopyalama (host'tan, nspawn dışında)
# ---------------------------------------------------------------------------
step4_copy_ollama_models() {
    local t0=$SECONDS
    echo "== 4. Ollama modellerini kopyalama =="

    if [[ ! -d "$OLLAMA_SRC" ]]; then
        echo "  UYARI: $OLLAMA_SRC bulunamadı, model kopyalama atlanıyor" >&2
        _step_timer $t0
        return
    fi

    local dest="$MNT/srv/ollama/models"
    mkdir -p "$dest/manifests/registry.ollama.ai/library/gemma3" "$dest/blobs"

    local manifests=(
        "$OLLAMA_SRC/manifests/registry.ollama.ai/library/gemma3/1b"
        "$OLLAMA_SRC/manifests/registry.ollama.ai/library/gemma3/4b"
    )

    for manifest in "${manifests[@]}"; do
        if [[ ! -f "$manifest" ]]; then
            echo "  UYARI: $manifest bulunamadı, atlanıyor" >&2
            continue
        fi

        cp -v "$manifest" "$dest/manifests/registry.ollama.ai/library/gemma3/"

        for digest in $(grep -oE '"digest":"sha256:[a-f0-9]+"' "$manifest" \
                          | grep -oE 'sha256:[a-f0-9]+' | sort -u); do
            local blob_file="${digest/sha256:/sha256-}"
            cp -nv "$OLLAMA_SRC/blobs/$blob_file" "$dest/blobs/"
        done
    done

    local ollama_uid ollama_gid
    ollama_uid=$(systemd-nspawn -q -D "$MNT" -- id -u ollama | tr -dc '0-9')
    ollama_gid=$(systemd-nspawn -q -D "$MNT" -- id -g ollama | tr -dc '0-9')
    chown -R "${ollama_uid}:${ollama_gid}" "$MNT/srv/ollama"
    chmod -R g+rwX "$MNT/srv/ollama"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 5. First-boot dosyalarını yerleştirme
# ---------------------------------------------------------------------------
step5_firstboot_files() {
    local t0=$SECONDS
    echo "== 5. First-boot dosyalarını yerleştirme =="

    if [[ -d "$SCRIPTS_DIR/skel/Desktop" ]] && [[ -n "$(ls -A "$SCRIPTS_DIR/skel/Desktop" 2>/dev/null)" ]]; then
        mkdir -p "$MNT/root/Desktop"
        cp -rv "$SCRIPTS_DIR/skel/Desktop/." "$MNT/root/Desktop/"
    fi

    if [[ -d "$SCRIPTS_DIR/skel/.config" ]] && [[ -n "$(ls -A "$SCRIPTS_DIR/skel/.config" 2>/dev/null)" ]]; then
        mkdir -p "$MNT/root/.config"
        cp -rv "$SCRIPTS_DIR/skel/.config/." "$MNT/root/.config/"
    fi

    if [[ -d "$SCRIPTS_DIR/firstboot" ]] && [[ -n "$(ls -A "$SCRIPTS_DIR/firstboot" 2>/dev/null)" ]]; then
        cp -v "$SCRIPTS_DIR/firstboot/"*.sh "$MNT/usr/local/sbin/"
        chmod +x "$MNT"/usr/local/sbin/firstboot-*.sh
        cp -v "$SCRIPTS_DIR/firstboot/"*.service "$MNT/etc/systemd/system/"

        systemd-nspawn -q -D "$MNT" -- systemctl enable \
            firstboot-resize.service \
            firstboot-swapfile.service
    fi
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 6. Temizlik ve unmount
# ---------------------------------------------------------------------------
step6_unmount() {
    local t0=$SECONDS
    echo "== 6. Temizlik ve unmount =="

    systemd-nspawn -q -D "$MNT" -- bash -c "rm -rf /tmp/* /var/tmp/*"

    echo "  pacman cache unmount ediliyor"
    umount "$MNT/var/cache/pacman/pkg"

    echo "  machine-id sıfırlanıyor, ssh host key'leri siliniyor"
    rm -f "$MNT"/etc/ssh/ssh_host_*
    truncate -s 0 "$MNT/etc/machine-id"

    sync
    umount "$MNT/boot"
    umount "$MNT"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 7. İmajı küçültme
# ---------------------------------------------------------------------------
step7_shrink() {
    local t0=$SECONDS
    echo "== 7. İmajı küçültme =="

    e2fsck -f -y "${LOOP_DEV}p2"
    resize2fs -M "${LOOP_DEV}p2"

    local block_count block_size fs_bytes margin_bytes target_bytes
    block_count=$(dumpe2fs -h "${LOOP_DEV}p2" 2>/dev/null \
        | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}')
    block_size=$(dumpe2fs -h "${LOOP_DEV}p2" 2>/dev/null \
        | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')

    fs_bytes=$(( block_count * block_size ))
    margin_bytes=$(( SHRINK_MARGIN_MB * 1024 * 1024 ))
    target_bytes=$(( fs_bytes + margin_bytes ))

    local p2_start_sector
    p2_start_sector=$(parted --script "$LOOP_DEV" unit s print \
        | awk '$1 == "2" {gsub(/s/,"",$2); print $2}')

    local target_end_sector=$(( p2_start_sector + (target_bytes / SECTOR_SIZE) ))
    local new_size_sectors=$(( target_end_sector - p2_start_sector + 1 ))

    echo "size=${new_size_sectors}" | sfdisk -N 2 --no-reread "$LOOP_DEV"
    e2fsck -f -y "${LOOP_DEV}p2"

    local last_sector
    last_sector=$(parted --script "$LOOP_DEV" unit s print \
        | awk '$1 == "2" {gsub(/s/,"",$3); print $3}')

    losetup -d "$LOOP_DEV"
    LOOP_DEV=""

    local truncate_bytes=$(( (last_sector + 1) * SECTOR_SIZE ))
    truncate -s "$truncate_bytes" "$IMG"

    echo "  yeni imaj boyutu: $(numfmt --to=iec "$truncate_bytes")"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# 8. Sıkıştırma
# ---------------------------------------------------------------------------
step8_compress() {
    local t0=$SECONDS
    echo "== 8. Sıkıştırma (xz -${XZ_LEVEL}) =="

    mkdir -p "$OUTPUT_DIR"
    xz -T0 "-${XZ_LEVEL}" -k -c "$IMG" > "${OUTPUT_IMG}.xz"

    echo "  -> ${OUTPUT_IMG}.xz ($(numfmt --to=iec "$(stat -c %s "${OUTPUT_IMG}.xz")"))"
    _step_timer $t0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    # Sadece paket önbellekleme modu
    if [[ "$PROFILE" == "prefetch" ]]; then
        step0_prefetch_packages
        echo "== Prefetch tamamlandı — artık 'bash build.sh desktop &' ve 'bash build.sh server &' paralel başlatılabilir =="
        return
    fi

    step0_prefetch_packages
    step1_create_image
    step2_mount_and_extract
    step3_nspawn_install
    step3_5_fix_initramfs
    step3_7_build_hailo
    step4_copy_ollama_models
    step5_firstboot_files
    step6_unmount
    step7_shrink
    step8_compress

    echo "== Tamamlandı [$PROFILE]: ${OUTPUT_IMG}.xz — toplam süre: ${SECONDS}s =="
}

# Sadece doğrudan çalıştırılınca main'i çağır.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
