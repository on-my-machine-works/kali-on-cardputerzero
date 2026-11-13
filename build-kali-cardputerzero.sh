#!/usr/bin/env bash
# ==============================================================================
# build-kali-cardputerzero.sh
#
# Custom Kali Linux ARM64 Image Builder for M5Stack CardputerZero (v5/CM0)
#
# Follows & adapts the official Kali Linux Custom Raspberry Pi Image workflow:
#   01. Bootstrap a clean ARM64 Kali Rolling rootfs (mmdebstrap / debootstrap)
#   02. Create a sparse disk image (.img)
#   03. Partition (MBR: 512MiB FAT32 /boot/firmware + ext4 /) & loop-mount
#   04. Populate rootfs, install CM0 bootloader + RPi 6.18.39 kernel + Wi-Fi/BT fw
#   05. Compile all M5Stack CardputerZero kernel modules & DT overlays from source,
#       install Kali tools + HDMI LXDE + native 320x170 LCD utilities +
#       APPLaunch integration, run automated verification, finalize & compress.
#
# Usage:
#   sudo ./build-kali-cardputerzero.sh                 # Run full pipeline (all)
#   sudo ./build-kali-cardputerzero.sh verify          # Run verification suite
#   sudo FLASH_DEV=/dev/sdX ./build-kali-cardputerzero.sh flash
#   sudo DEPLOY_SSH_DEV=/dev/sdX ./build-kali-cardputerzero.sh deploy-ssh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/cache}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
ROOTFS_STAGE_DIR="$WORK_DIR/rootfs"
MNT_ROOT="$WORK_DIR/mnt_root"
MNT_BOOT="$WORK_DIR/mnt_boot"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/output}"

IMG_NAME="${IMG_NAME:-kali-cardputerzero-arm64.img}"
OUT_IMG="$OUT_DIR/$IMG_NAME"
IMG_SIZE="${IMG_SIZE:-7G}"
BOOT_MB="${BOOT_MB:-512}"
CZ_HOSTNAME="${CZ_HOSTNAME:-kali-cardputerzero}"
WIFI_REGDOM="${WIFI_REGDOM:-US}"

KALI_MIRROR="${KALI_MIRROR:-https://kali.download/kali}"
LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/upstream.lock.json}"
M5_UPDATE_MODE="${M5_UPDATE_MODE:-auto}"
RPI_LIBCAMERA_DIR="/opt/rpi-libcamera"

KVER=""
KERNEL_HOLD_PKGS=""
DTOVERLAYS_CANDIDATE=""
DTOVERLAYS_LOCKED=""

load_resolved_env() {
    if [[ -f "$WORK_DIR/resolved-env.sh" ]]; then
        # shellcheck disable=SC1091
        source "$WORK_DIR/resolved-env.sh"
    else
        eval "$(python3 - "$LOCK_FILE" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
kver = lock["kernel"]["kver"]
kb = kver.split("+", 1)[0]
hold = (
    f"linux-image-{kver} linux-image-rpi-v8 "
    f"linux-headers-{kver} linux-headers-rpi-v8 "
    f"linux-headers-{kb}+rpt-common-rpi "
    f"linux-kbuild-{kb}+rpt "
    f"linux-base-{kver} linux-base-rpi-v8"
)
dto = lock["dtoverlays"]["commit"]
print(f'KVER="{kver}"')
print(f'KERNEL_HOLD_PKGS="{hold}"')
print(f'DTOVERLAYS_CANDIDATE="{dto}"')
print(f'DTOVERLAYS_LOCKED="{dto}"')
PY
)"
    fi
}
load_resolved_env

LOOP_DEV=""
CHROOT_UP=0
CHECK_DONE=0
CHROOT_RESOLV_LINK=""
CHROOT_RESOLV_SAVED=0
HOST_ARCH="$(uname -m)"

# ─── Logging ─────────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
    C_INFO=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_RST=$'\033[0m'
else
    C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi
log()  { echo "${C_INFO}[*]${C_RST} $*" >&2; }
ok()   { echo "${C_OK}[+]${C_RST} $*" >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[X]${C_RST} $*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo -E "$BASH" "$0" "$@"
    fi
}

# ─── Chroot & Mount Lifecycle ────────────────────────────────────────────────
chroot_up() {
    (( CHROOT_UP )) && return 0
    if [[ "$HOST_ARCH" != "aarch64" ]]; then
        [[ -x /usr/bin/qemu-aarch64-static && -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
            || err "Non-aarch64 host ($HOST_ARCH) requires qemu-user-static + binfmt_misc"
        cp -f /usr/bin/qemu-aarch64-static "$MNT_ROOT/usr/bin/"
    fi

    local r="$MNT_ROOT/etc/resolv.conf"
    if [[ -L "$r" ]]; then
        CHROOT_RESOLV_LINK="$(readlink "$r")"
        rm -f "$r"
    elif [[ -f "$r" ]]; then
        cp -a "$r" "$r.build-bak"
        CHROOT_RESOLV_SAVED=1
    fi
    cat /etc/resolv.conf > "$r"

    printf '#!/bin/sh\nexit 101\n' > "$MNT_ROOT/usr/sbin/policy-rc.d"
    chmod 755 "$MNT_ROOT/usr/sbin/policy-rc.d"

    mount --bind /dev     "$MNT_ROOT/dev"
    mount --bind /dev/pts "$MNT_ROOT/dev/pts"
    mount -t proc proc    "$MNT_ROOT/proc"
    mount -t sysfs sysfs  "$MNT_ROOT/sys"
    mkdir -p "$MNT_ROOT/boot/firmware"
    mount --bind "$MNT_BOOT" "$MNT_ROOT/boot/firmware"
    CHROOT_UP=1
}

chroot_down() {
    (( CHROOT_UP )) || return 0
    local m
    for m in boot/firmware sys proc dev/pts dev; do
        if mountpoint -q "$MNT_ROOT/$m" 2>/dev/null; then
            umount "$MNT_ROOT/$m" 2>/dev/null || umount -l "$MNT_ROOT/$m" 2>/dev/null || true
        fi
    done
    rm -f "$MNT_ROOT/usr/sbin/policy-rc.d"
    [[ "$HOST_ARCH" != "aarch64" ]] && rm -f "$MNT_ROOT/usr/bin/qemu-aarch64-static" || true

    local r="$MNT_ROOT/etc/resolv.conf"
    if [[ -n "$CHROOT_RESOLV_LINK" ]]; then
        rm -f "$r"; ln -s "$CHROOT_RESOLV_LINK" "$r"
    elif (( CHROOT_RESOLV_SAVED )); then
        mv -f "$r.build-bak" "$r"
    fi
    CHROOT_RESOLV_LINK=""; CHROOT_RESOLV_SAVED=0; CHROOT_UP=0
}

run_chroot() {
    chroot_up
    chroot "$MNT_ROOT" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive \
        HOME=/root \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C.UTF-8 \
        LANG=C.UTF-8 \
        TERM=dumb \
        KVER="$KVER" \
        KERNEL_HOLD_PKGS="$KERNEL_HOLD_PKGS" \
        RPI_LIBCAMERA_DIR="$RPI_LIBCAMERA_DIR" \
        bash -e -s -- "$@"
}

unmount_image() {
    chroot_down
    for m in "$MNT_ROOT" "$MNT_BOOT"; do
        if mountpoint -q "$m" 2>/dev/null; then
            sync
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
    if [[ -f "$OUT_IMG" ]]; then
        while read -r lp; do
            [[ -n "$lp" ]] && losetup -d "$lp" 2>/dev/null || true
        done < <(losetup -j "$OUT_IMG" 2>/dev/null | cut -d: -f1)
    fi
    LOOP_DEV=""
}

trap unmount_image EXIT

dpkg_installed() {
    awk -v pkg="$1" '/^Package: /{p=($2==pkg)} p && /^Status: .* installed$/{f=1} END{exit !f}' \
        "$MNT_ROOT/var/lib/dpkg/status"
}

dpkg_held() {
    awk -v pkg="$1" '/^Package: /{p=($2==pkg)} p && /^Status: hold ok installed$/{h=1} END{exit !h}' \
        "$MNT_ROOT/var/lib/dpkg/status"
}

kernel_img_version() {
    { zcat "$MNT_BOOT/kernel8.img" 2>/dev/null || cat "$MNT_BOOT/kernel8.img"; } \
        | strings 2>/dev/null | grep -m1 'Linux version' | awk '{print $3}' || true
}

# ─── Stage 00: Check Host Dependencies ───────────────────────────────────────
stage_check() {
    (( CHECK_DONE )) && return 0
    log "Checking host build tools (Host arch: $HOST_ARCH)"
    local req=(parted partprobe losetup mkfs.vfat mkfs.ext4 e2fsck resize2fs blkid
               rsync xz zstd ar tar dpkg-deb curl git sha256sum dtc strings python3)
    local missing=()
    for c in "${req[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if ! command -v mmdebstrap >/dev/null 2>&1 && ! command -v debootstrap >/dev/null 2>&1; then
        missing+=("mmdebstrap/debootstrap")
    fi
    if [[ "$HOST_ARCH" != "aarch64" ]]; then
        [[ -x /usr/bin/qemu-aarch64-static && -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
            || missing+=("qemu-user-static+binfmt-support")
        command -v arch-test >/dev/null 2>&1 || missing+=("arch-test")
    fi
    if [[ ${#missing[@]} -ne 0 ]]; then
        err "Missing host tools: ${missing[*]}
Install on Debian/Ubuntu/Kali with:
  sudo apt update && sudo apt install -y parted dosfstools e2fsprogs util-linux rsync xz-utils zstd binutils dpkg curl git ca-certificates device-tree-compiler python3 mmdebstrap debootstrap zerofree$( [[ "$HOST_ARCH" != "aarch64" ]] && printf ' qemu-user-static binfmt-support arch-test' )"
    fi
    CHECK_DONE=1
    ok "Host environment verified"
}

# ─── Stage 01a: Resolve & Verify Upstream Inputs ─────────────────────────────
stage_fetch() {
    if [[ "${FORCE_FETCH:-0}" != "1" \
       && -f "$WORK_DIR/resolved-env.sh" \
       && -f "$WORK_DIR/apps-manifest.txt" \
       && -f "$WORK_DIR/resolved-lock.json" ]]; then
        load_resolved_env
        return 0
    fi
    log "Resolving and verifying upstream packages & sources (mode: $M5_UPDATE_MODE)"
    python3 "$SCRIPT_DIR/scripts/resolve-upstream.py" resolve \
        --lock-file "$LOCK_FILE" \
        --cache-dir "$CACHE_DIR" \
        --work-dir "$WORK_DIR" \
        --mode "$M5_UPDATE_MODE"
    load_resolved_env
    ok "Upstream kernel ($KVER), firmware, drivers, camera runtime, and M5 packages ready"
}

# ─── Stage 01b: Bootstrap Kali Linux ARM64 Rootfs ────────────────────────────
stage_rootfs() {
    if [[ -f "$ROOTFS_STAGE_DIR/.bootstrapped" ]]; then
        ok "Kali ARM64 rootfs already bootstrapped at $ROOTFS_STAGE_DIR"
        return 0
    fi
    log "Bootstrapping fresh Kali Rolling arm64 rootfs into $ROOTFS_STAGE_DIR"
    rm -rf "$ROOTFS_STAGE_DIR"
    mkdir -p "$ROOTFS_STAGE_DIR"

    local keyring="$CACHE_DIR/keyring/kali-archive-keyring.gpg"
    local base_pkgs="kali-archive-keyring,ca-certificates,apt-transport-https,systemd,systemd-sysv,udev,dbus,locales,sudo,bash,zsh,eatmydata,initramfs-tools,kmod,iproute2,iputils-ping,procps,parted,e2fsprogs,dosfstools,rsync,curl,gnupg"

    if command -v mmdebstrap >/dev/null 2>&1; then
        mmdebstrap \
            --architectures=arm64 \
            --variant=minbase \
            --components="main,contrib,non-free,non-free-firmware" \
            --keyring="$keyring" \
            --include="$base_pkgs" \
            kali-rolling "$ROOTFS_STAGE_DIR" "$KALI_MIRROR"
    else
        ln -sf sid /usr/share/debootstrap/scripts/kali-rolling 2>/dev/null || true
        debootstrap \
            --arch=arm64 \
            --components=main,contrib,non-free,non-free-firmware \
            --keyring="$keyring" \
            --include="$base_pkgs" \
            kali-rolling "$ROOTFS_STAGE_DIR" "$KALI_MIRROR"
    fi

    if [[ ! -f "$ROOTFS_STAGE_DIR/usr/share/keyrings/kali-archive-keyring.gpg" ]]; then
        cp --remove-destination "$keyring" "$ROOTFS_STAGE_DIR/etc/apt/trusted.gpg.d/kali-archive-keyring.gpg"
    fi
    cat > "$ROOTFS_STAGE_DIR/etc/apt/sources.list" <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

    mkdir -p "$ROOTFS_STAGE_DIR/etc/initramfs-tools/conf.d"
    echo "RESUME=none" > "$ROOTFS_STAGE_DIR/etc/initramfs-tools/conf.d/resume"

    touch "$ROOTFS_STAGE_DIR/.bootstrapped"
    ok "Kali Rolling arm64 base rootfs created"
}

# ─── Stage 02 & 03: Create, Partition, Format & Populate Image File ──────────
stage_image() {
    if [[ -f "$OUT_IMG" && -f "$OUT_IMG.populated" ]]; then
        ok "Disk image $OUT_IMG already created and populated"
        return 0
    fi
    [[ -f "$ROOTFS_STAGE_DIR/.bootstrapped" ]] || stage_rootfs

    unmount_image
    mkdir -p "$OUT_DIR" "$MNT_ROOT" "$MNT_BOOT"
    rm -f "$OUT_IMG" "$OUT_IMG.populated"

    log "Creating sparse image $OUT_IMG ($IMG_SIZE)"
    truncate -s "$IMG_SIZE" "$OUT_IMG"

    log "Partitioning $OUT_IMG (MBR: ${BOOT_MB}MiB FAT32 /boot/firmware + ext4 /)"
    parted --script "$OUT_IMG" \
        mklabel msdos \
        mkpart primary fat32 1MiB "$((BOOT_MB + 1))MiB" \
        set 1 boot on \
        set 1 lba on \
        mkpart primary ext4 "$((BOOT_MB + 1))MiB" 100%

    LOOP_DEV="$(losetup -fP --show "$OUT_IMG")"
    partprobe "$LOOP_DEV" || true
    udevadm settle 2>/dev/null || sleep 1

    log "Formatting partitions (${LOOP_DEV}p1=FAT32, ${LOOP_DEV}p2=ext4)"
    mkfs.vfat -F 32 -n BOOT "${LOOP_DEV}p1" >/dev/null
    mkfs.ext4 -F -L ROOTFS -O ^metadata_csum_seed "${LOOP_DEV}p2" >/dev/null

    mount -o noatime "${LOOP_DEV}p2" "$MNT_ROOT"
    mkdir -p "$MNT_ROOT/boot/firmware"
    mount "${LOOP_DEV}p1" "$MNT_BOOT"

    log "Copying Kali rootfs into mounted image via rsync"
    rsync -HPavz -q --exclude='.bootstrapped' --exclude='/boot/firmware/*' \
        "$ROOTFS_STAGE_DIR/" "$MNT_ROOT/"

    local boot_puuid root_puuid
    boot_puuid="$(blkid -s PARTUUID -o value "${LOOP_DEV}p1")"
    root_puuid="$(blkid -s PARTUUID -o value "${LOOP_DEV}p2")"

    cat > "$MNT_ROOT/etc/fstab" <<EOF
proc            /proc           proc    defaults          0       0
PARTUUID=${boot_puuid}  /boot/firmware  vfat    defaults          0       2
PARTUUID=${root_puuid}  /               ext4    defaults,noatime  0       1
EOF

    if [[ ! -L "$MNT_ROOT/boot/overlays" ]]; then
        ln -sf firmware/overlays "$MNT_ROOT/boot/overlays"
    fi

    touch "$OUT_IMG.populated"
    ok "Image partitioned, formatted & populated (ROOT PARTUUID=$root_puuid)"
}

stage_mount() {
    [[ -f "$OUT_IMG" ]] || stage_image
    if mountpoint -q "$MNT_ROOT" && mountpoint -q "$MNT_BOOT"; then
        LOOP_DEV="$(findmnt -no SOURCE "$MNT_ROOT" | sed 's/p[0-9]*$//')"
        return 0
    fi
    mkdir -p "$MNT_ROOT" "$MNT_BOOT"
    LOOP_DEV="$(losetup -fP --show "$OUT_IMG")"
    partprobe "$LOOP_DEV" || true
    mount -o noatime "${LOOP_DEV}p2" "$MNT_ROOT"
    mkdir -p "$MNT_ROOT/boot/firmware"
    mount "${LOOP_DEV}p1" "$MNT_BOOT"
    ok "Image loop-mounted on $LOOP_DEV"
}

# ─── Stage 04: Install CM0 Bootloader, 6.18.39 Kernel & Wireless Firmware ────
stage_kernel() {
    log "Installing Raspberry Pi CM0 bootloader, kernel $KVER & Broadcom/Cypress firmware"

    if [[ "$(kernel_img_version)" == "$KVER" ]] \
       && dpkg_installed "linux-image-$KVER" \
       && dpkg_installed "linux-headers-$KVER" \
       && [[ -f "$MNT_BOOT/bootcode.bin" ]] \
       && [[ -f "$MNT_BOOT/bcm2710-rpi-cm0.dtb" ]]; then
        ok "Kernel $KVER & CM0 boot firmware already installed"
    else
        local stage="$MNT_ROOT/var/cache/cz-build/kernel"
        mkdir -p "$stage" "$MNT_ROOT/etc/apt/preferences.d"
        cp "$CACHE_DIR/kernel/"*.deb "$stage/"
        cp "$CACHE_DIR/bsp/raspi-firmware_"*.deb "$stage/"
        install -m 644 "$CACHE_DIR/pigen/kernel.pref" "$MNT_ROOT/etc/apt/preferences.d/cardputerzero-kernel"

        cat > "$MNT_ROOT/etc/kernel-img.conf" <<'EOF'
do_symlinks=0
EOF

        run_chroot <<'CHROOT'
export APT_LISTCHANGES_FRONTEND=none
# Use fast mirror during build, restore http.kali.org at finalize
echo "deb https://kali.download/kali kali-rolling main contrib non-free non-free-firmware" > /etc/apt/sources.list
apt-get update -qq

# Bridge RPi 6.18 DTB directory layout for z50-raspi-firmware hook
[ -e "/usr/lib/linux-image-$KVER" ] || ln -s "modules/$KVER/dtb" "/usr/lib/linux-image-$KVER"

eatmydata apt-get install -y --no-install-recommends \
    --allow-downgrades --allow-change-held-packages \
    /var/cache/cz-build/kernel/*.deb

# Populate /boot/firmware with RPi GPU bootloader (bootcode.bin, start*.elf, fixup*.dat)
if [ -d /usr/lib/raspi-firmware ]; then
    cp -a /usr/lib/raspi-firmware/* /boot/firmware/
fi

# Populate kernel8.img, initramfs8, all Broadcom DTBs (incl. bcm2710-rpi-cm0.dtb) & overlays
cp -f "/boot/vmlinuz-$KVER" /boot/firmware/kernel8.img
cp -f /usr/lib/modules/"$KVER"/dtb/broadcom/*.dtb /boot/firmware/
mkdir -p /boot/firmware/overlays
cp -f /usr/lib/modules/"$KVER"/dtb/overlays/*.dtbo /boot/firmware/overlays/
for extra_ovl in overlay_map.dtb README; do
    [ -f "/usr/lib/modules/$KVER/dtb/overlays/$extra_ovl" ] && \
        cp -f "/usr/lib/modules/$KVER/dtb/overlays/$extra_ovl" /boot/firmware/overlays/ || true
done

update-initramfs -c -k "$KVER" || update-initramfs -u -k "$KVER"
cp -f "/boot/initrd.img-$KVER" /boot/firmware/initramfs8

apt-mark hold $KERNEL_HOLD_PKGS raspi-firmware
rm -rf /var/cache/cz-build/kernel
CHROOT
    fi

    # Install CM0 Wi-Fi (BCM43439 SDIO NVRAM boardflags3=0x04000000) & Bluetooth (BCM4343A2.hcd)
    local tmpfw
    tmpfw="$(mktemp -d)"
    dpkg-deb -x "$CACHE_DIR/bsp/firmware-brcm80211_"*.deb "$tmpfw/wifi"
    dpkg-deb -x "$CACHE_DIR/bsp/bluez-firmware_"*.deb     "$tmpfw/bt"
    dpkg-deb -x "$CACHE_DIR/bsp/pi-bluetooth_"*.deb       "$tmpfw/pibt"
    dpkg-deb -x "$CACHE_DIR/bsp/raspberrypi-sys-mods_"*.deb "$tmpfw/sysmods"

    mkdir -p "$MNT_ROOT/usr/lib/firmware/brcm" \
             "$MNT_ROOT/usr/lib/firmware/cypress" \
             "$MNT_ROOT/usr/lib/firmware/synaptics"

    cp -a --remove-destination "$tmpfw/wifi/usr/lib/firmware/cypress/." "$MNT_ROOT/usr/lib/firmware/cypress/"
    cp -a --remove-destination "$tmpfw/wifi/usr/lib/firmware/brcm/."    "$MNT_ROOT/usr/lib/firmware/brcm/"
    cp -a --remove-destination "$tmpfw/bt/usr/lib/firmware/brcm/."      "$MNT_ROOT/usr/lib/firmware/brcm/"
    cp -a --remove-destination "$tmpfw/bt/usr/lib/firmware/synaptics/." "$MNT_ROOT/usr/lib/firmware/synaptics/"

    # Install pi-bluetooth scripts, udev rules & systemd units (btuart, bthelper, hciuart.service)
    install -d "$MNT_ROOT/usr/bin" "$MNT_ROOT/usr/lib/systemd/system" "$MNT_ROOT/usr/lib/udev/rules.d"
    install -m 755 "$tmpfw/pibt/usr/bin/btuart"   "$MNT_ROOT/usr/bin/btuart"
    install -m 755 "$tmpfw/pibt/usr/bin/bthelper" "$MNT_ROOT/usr/bin/bthelper"
    install -m 644 "$tmpfw/pibt/lib/systemd/system/hciuart.service"   "$MNT_ROOT/usr/lib/systemd/system/"
    install -m 644 "$tmpfw/pibt/lib/systemd/system/bthelper@.service" "$MNT_ROOT/usr/lib/systemd/system/"
    install -m 644 "$tmpfw/pibt/lib/udev/rules.d/90-pi-bluetooth.rules" "$MNT_ROOT/usr/lib/udev/rules.d/"

    # Install Raspberry Pi hardware udev rules (serial0/serial1, backlight, dma_heap, spi/i2c/gpio, DT i2cprobe)
    for rule in 10-vc.rules 15-i2c-modprobe.rules 60-backlight.rules 60-dma-heap.rules \
                60-gpiochip4.rules 60-i2c-aliases.rules 60-piolib.rules 61-drm.rules 99-com.rules; do
        [[ -f "$tmpfw/sysmods/usr/lib/udev/rules.d/$rule" ]] && \
            install -m 644 "$tmpfw/sysmods/usr/lib/udev/rules.d/$rule" "$MNT_ROOT/usr/lib/udev/rules.d/$rule"
    done
    if [[ -f "$tmpfw/sysmods/usr/lib/raspberrypi-sys-mods/i2cprobe" ]]; then
        install -d "$MNT_ROOT/usr/lib/raspberrypi-sys-mods"
        install -m 755 "$tmpfw/sysmods/usr/lib/raspberrypi-sys-mods/i2cprobe" \
            "$MNT_ROOT/usr/lib/raspberrypi-sys-mods/i2cprobe"
    fi

    rm -rf "$tmpfw"
    ok "CM0 kernel, bootloader, Wi-Fi/BT firmware, and RPi udev rules installed"
}

# ─── Stage 05: Compile CardputerZero Kernel Modules & Overlays ───────────────
build_dtoverlays_commit() {
    local commit="$1" src="$MNT_ROOT/usr/src/m5stack-linux-dtoverlays"
    rm -rf "$src" "$MNT_ROOT/usr/src/pigpio"
    mkdir -p "$src" "$MNT_ROOT/usr/src/pigpio"
    tar -xzf "$CACHE_DIR/src/m5stack-linux-dtoverlays-${commit}.tar.gz" --strip-components=1 -C "$src"
    tar -xzf "$CACHE_DIR/src/pigpio.tar.gz" --strip-components=1 -C "$MNT_ROOT/usr/src/pigpio"

    run_chroot <<'CHROOT'
eatmydata apt-get install -y --no-install-recommends build-essential device-tree-compiler kmod

# Bridge RPi 6.18 headers' gcc-14 compiler name to Kali's default gcc toolchain if gcc-14 is absent
for _t in gcc gcc-ar gcc-nm gcc-ranlib; do
    [ -e "/usr/bin/aarch64-linux-gnu-${_t}-14" ] || \
        ln -sf "aarch64-linux-gnu-${_t}" "/usr/bin/aarch64-linux-gnu-${_t}-14"
done

mkdir -p /usr/share/keymaps /etc/udev/rules.d /usr/lib/udev/rules.d /usr/lib/tmpfiles.d \
         /etc/systemd/system/sysinit.target.wants /usr/lib/firmware /usr/sbin \
         /boot/firmware/overlays "/usr/lib/modules/$KVER/extra"

# Build & install all CardputerZero v5 (and v3 fallback) modules + overlays
cd /usr/src/m5stack-linux-dtoverlays/modules/CardputerZero
make KERNELDIR="/usr/lib/modules/$KVER/build" EXTRADIR="/usr/lib/modules/$KVER/extra" \
     ARCH=arm64 CONFIG_CARDPUTERO_V0_5=y -j"$(nproc)" all
make KERNELDIR="/usr/lib/modules/$KVER/build" EXTRADIR="/usr/lib/modules/$KVER/extra" \
     ARCH=arm64 CONFIG_CARDPUTERO_V0_5=y install
make ROOTFSPATH= install_led_permissions

# Also build standalone rx8130-overlay.dtbo for reference/debugging
make -C /usr/src/m5stack-linux-dtoverlays/modules/rx8130 install

depmod -a "$KVER"

# Build & install pigpio (libpigpio.so, pigpiod, pigs + Python module) for GPIO PWM control
cd /usr/src/pigpio
sed -i '/setup\.py install/d' Makefile
make -j"$(nproc)" CC="gcc -std=gnu17" STRIP=strip
make install
install -D -m 644 pigpio.py /usr/lib/python3/dist-packages/pigpio.py
ldconfig
rm -rf /usr/src/pigpio
CHROOT
    echo "$commit:$KVER" > "$src/.built-commit"
}

stage_drivers() {
    load_resolved_env
    log "Building M5Stack CardputerZero v5 kernel drivers, DT overlays & pigpio"
    local src="$MNT_ROOT/usr/src/m5stack-linux-dtoverlays"
    local target_commit="$DTOVERLAYS_CANDIDATE"

    if [[ "$(cat "$src/.built-commit" 2>/dev/null || true)" == "$target_commit:$KVER" \
       && -f "$MNT_ROOT/usr/lib/modules/$KVER/extra/panel-mipi-dbi-m.ko" \
       && -f "$MNT_BOOT/overlays/cardputerzero-v5-overlay.dtbo" \
       && -x "$MNT_ROOT/usr/local/bin/pigpiod" ]]; then
        ok "CardputerZero drivers (${target_commit:0:7}) & pigpio already built"
    else
        if ! build_dtoverlays_commit "$target_commit"; then
            if [[ "$target_commit" != "$DTOVERLAYS_LOCKED" ]]; then
                python3 "$SCRIPT_DIR/scripts/resolve-upstream.py" record-fallback \
                    --lock-file "$LOCK_FILE" \
                    --work-dir "$WORK_DIR" \
                    --component dtoverlays \
                    --reason "\`m5stack-linux-dtoverlays\` \`${target_commit:0:7}\` failed to compile against \`$KVER\`; reverted to locked \`${DTOVERLAYS_LOCKED:0:7}\`"
                build_dtoverlays_commit "$DTOVERLAYS_LOCKED"
            else
                err "Failed to compile m5stack-linux-dtoverlays ($target_commit) against $KVER"
            fi
        fi
    fi

    # Hardware udev rules:
    #  1) Isolate internal I2C TCA8418 keypad onto seat1 so X11/LightDM never grabs it
    #  2) Strip master-of-seat from internal SPI ST7789 DRM card so APPLaunch owns /dev/fb_lcd
    #  3) Grant non-root video/i2c access to LIRC IR TX/RX (/dev/lirc*) and RTC (/dev/rtc*)
    #  4) Sync system clock from hardware Epson RX8130CE RTC at boot when /dev/rtc0 appears
    install -d "$MNT_ROOT/etc/udev/rules.d" "$MNT_ROOT/usr/lib/udev/rules.d"
    cat > "$MNT_ROOT/etc/udev/rules.d/99-ignore-i2c-key.rules" <<'EOF'
ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_PATH}=="platform-3f804000.i2c", ENV{ID_SEAT}="seat1", GROUP="input", MODE="0660"
EOF
    cat > "$MNT_ROOT/usr/lib/udev/rules.d/zz-cardputerzero-hdmi-display.rules" <<'EOF'
ACTION!="remove", SUBSYSTEM=="drm", KERNEL=="card*", ENV{ID_PATH}=="platform-3f204000.spi-cs-0", TAG-="master-of-seat"
EOF
    cat > "$MNT_ROOT/etc/udev/rules.d/70-cardputerzero-peripherals.rules" <<'EOF'
# Allow kali user (video/i2c/plugdev/netdev) to use IR TX/RX, hardware RTC, USB HID gadgets, and rfkill
SUBSYSTEM=="lirc", GROUP="video", MODE="0660"
SUBSYSTEM=="rtc", GROUP="i2c", MODE="0664"
ACTION=="add", SUBSYSTEM=="rtc", KERNEL=="rtc0", RUN+="/sbin/hwclock --hctosys --utc --noadjfile"
KERNEL=="hidg[0-9]*", GROUP="plugdev", MODE="0660"
KERNEL=="rfkill", SUBSYSTEM=="misc", GROUP="netdev", MODE="0664"
EOF

    # Ensure critical modules autoload reliably at boot
    install -d "$MNT_ROOT/etc/modules-load.d"
    cat > "$MNT_ROOT/etc/modules-load.d/cardputerzero.conf" <<'EOF'
i2c-dev
panel_mipi_dbi_m
rtc-ds1307
libcomposite
EOF

    # Ensure fb_load splash service is linked into sysinit.target.wants and loads Kali splash.bmp
    if [[ -f "$MNT_ROOT/etc/systemd/system/fb_load.service" ]]; then
        install -d "$MNT_ROOT/etc/systemd/system/sysinit.target.wants" \
                   "$MNT_ROOT/etc/systemd/system/fb_load.service.d"
        ln -sfn ../fb_load.service "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/fb_load.service"
        cat > "$MNT_ROOT/etc/systemd/system/fb_load.service.d/kali-splash.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/fb_load --keep-open /boot/firmware/splash.bmp /dev/dri/cardputer-zero-internal
EOF
    fi

    ok "All CardputerZero kernel drivers, DTBOs, udev rules & pigpio installed"
}

# ─── Stage 06: Install Kali Packages, Desktop, Audio & USB Wi-Fi DKMS ────────
PACKAGES_STAMP="/var/lib/cz-kali/packages.v1"

stage_packages() {
    if [[ -f "$MNT_ROOT$PACKAGES_STAMP" ]]; then
        ok "Kali & system packages already installed"
        return 0
    fi
    log "Installing Kali packages, LXDE HDMI desktop, PipeWire & Realtek DKMS"

    run_chroot <<'CHROOT'
export APT_LISTCHANGES_FRONTEND=none
apt-get update -qq

# Create 'kali' user (UID 1000 / GID 1000) and system groups BEFORE apt-get install
# so package preconfigure scripts (e.g. kismet-capture-common, lightdm) see user 'kali'
for grp in gpio spi i2c input video audio dialout plugdev netdev render bluetooth wireshark kismet; do
    getent group "$grp" >/dev/null || groupadd --system "$grp"
done
if ! getent passwd kali >/dev/null; then
    getent group kali >/dev/null || groupadd -g 1000 kali
    useradd -m -u 1000 -g 1000 -s /usr/bin/zsh kali
fi

# Pre-seed debconf for non-interactive Wireshark/Kismet/console installs
# (leave kismet install-users empty in debconf; we add kali to 'kismet' group directly)
echo RESET kismet-capture-common/install-users | debconf-communicate 2>/dev/null || true
cat <<'DEBCONF' | debconf-set-selections
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
kismet-capture-common kismet-capture-common/install-users string
kismet-capture-common kismet-capture-common/install-setuid boolean true
wireshark-common wireshark-common/install-setuid boolean true
DEBCONF

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
dpkg --configure -a || true

eatmydata apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    kali-defaults \
    kali-menu \
    kali-themes-common \
    kali-wallpapers-2024 \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    openssh-server \
    network-manager \
    wpasupplicant \
    wireless-tools \
    iw \
    rfkill \
    wireless-regdb \
    bluez \
    bluez-tools \
    systemd-timesyncd \
    util-linux-extra \
    zram-tools \
    cloud-guest-utils \
    parted \
    psmisc \
    less \
    vim \
    tmux \
    btop \
    htop \
    fastfetch \
    jq \
    unzip \
    zip \
    p7zip-full \
    file \
    usbutils \
    pciutils \
    ethtool \
    usb-modeswitch \
    v4l-utils \
    i2c-tools \
    spi-tools \
    gpiod \
    python3 \
    python-is-python3 \
    python3-gi \
    python3-gi-cairo \
    gir1.2-gtk-3.0 \
    python3-spidev \
    python3-smbus2 \
    python3-libgpiod \
    python3-serial \
    minicom \
    picocom \
    fbset \
    xdg-user-dirs \
    fonts-noto-cjk \
    fonts-dejavu-core \
    adbd \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    pulseaudio-utils \
    alsa-utils \
    rtkit \
    lxde-core \
    xorg \
    xserver-xorg-video-fbdev \
    xserver-xorg-input-libinput \
    lightdm \
    lightdm-autologin-greeter \
    qterminal \
    feh \
    polkitd \
    libcamera0.7 \
    libcamera-ipa \
    ffmpeg \
    libfmt10 \
    libfreetype6 \
    libpng16-16t64 \
    libjpeg62-turbo \
    gpsd \
    gpsd-clients \
    kali-tweaks \
    python3-requests \
    python3-scapy \
    aircrack-ng \
    wifite \
    bully \
    cowpatty \
    hcxdumptool \
    hcxtools \
    kismet \
    bettercap \
    bettercap-caplets \
    nmap \
    arp-scan \
    tcpdump \
    tshark \
    netcat-traditional \
    socat \
    macchanger \
    mdk4 \
    reaver \
    pixiewps \
    dnsmasq \
    hostapd \
    smbclient \
    libnfc-bin \
    libnfc-examples \
    mfoc \
    mfcuk \
    rtl-sdr \
    rtl-433 \
    flashrom \
    qrencode \
    firmware-atheros \
    firmware-realtek \
    firmware-mediatek \
    dkms \
    realtek-rtl88xxau-dkms

# Patch & compile realtek-rtl88xxau-dkms (88XXau.ko) against RPi Linux 6.18
cat > /tmp/rtw_compat_6_16.h <<'COMPAT'
#ifndef RTW_COMPAT_6_16_H
#define RTW_COMPAT_6_16_H
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)
# ifndef from_timer
#  define from_timer(var, cb, field) timer_container_of(var, cb, field)
# endif
# ifndef del_timer_sync
#  define del_timer_sync(t) timer_delete_sync(t)
# endif
#endif
#endif
COMPAT

cat > /tmp/patch_cfg80211.py <<'PYPATCH'
import sys
p = sys.argv[1]
with open(p) as f: c = f.read()
for old, new in [
    ('cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, u32 changed)',
     'cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, int radio_idx __maybe_unused, u32 changed)'),
    ('#endif\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)) || defined(COMPAT_KERNEL_RELEASE)\n\tenum nl80211_tx_power_setting type, int mbm)',
     '#endif\n\tint radio_idx __maybe_unused,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)) || defined(COMPAT_KERNEL_RELEASE)\n\tenum nl80211_tx_power_setting type, int mbm)'),
    ('#endif\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))\n\tunsigned int link_id,',
     '#endif\n\tint radio_idx __maybe_unused,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))\n\tunsigned int link_id,'),
]:
    if old in c: c = c.replace(old, new, 1)
with open(p, 'w') as f: f.write(c)
PYPATCH

rtl_src=$(ls -d /usr/src/*rtl88xxau-* 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$rtl_src" ]; then
    for _t in gcc gcc-ar gcc-nm gcc-ranlib; do
        [ -e "/usr/bin/aarch64-linux-gnu-${_t}-14" ] || \
            ln -sf "aarch64-linux-gnu-${_t}" "/usr/bin/aarch64-linux-gnu-${_t}-14"
    done
    sed -i 's/^EXTRA_CFLAGS\b/ccflags-y/g; s/^EXTRA_LDFLAGS\b/ldflags-y/g' "$rtl_src/Makefile"
    cp /tmp/rtw_compat_6_16.h "$rtl_src/include/"
    grep -q 'rtw_compat_6_16.h' "$rtl_src/include/osdep_service_linux.h" || \
        sed -i '/#define __OSDEP_LINUX_SERVICE_H_/a #include "rtw_compat_6_16.h"' "$rtl_src/include/osdep_service_linux.h"
    python3 /tmp/patch_cfg80211.py "$rtl_src/os_dep/linux/ioctl_cfg80211.c"
    sed -i '/BUILD_EXCLUSIVE_KERNEL/d' "$rtl_src/dkms.conf"
    dname=$(awk -F'"' '/^PACKAGE_NAME/{print $2; exit}' "$rtl_src/dkms.conf")
    dver=$(awk -F'"' '/^PACKAGE_VERSION/{print $2; exit}' "$rtl_src/dkms.conf")
    dkms add -m "$dname" -v "$dver" 2>/dev/null || true
    if ! dkms install --force -m "$dname" -v "$dver" -k "$KVER"; then
        (cd "$rtl_src" && make -j"$(nproc)" KVER="$KVER" KSRC="/usr/lib/modules/$KVER/build")
        mkdir -p "/usr/lib/modules/$KVER/updates/dkms"
        cp "$(find "$rtl_src" -name '88XXau.ko' | head -1)" "/usr/lib/modules/$KVER/updates/dkms/88XXau.ko"
    fi
    depmod -a "$KVER"
fi
rm -f /tmp/rtw_compat_6_16.h /tmp/patch_cfg80211.py

# Create 'kali' user at UID 1000 / GID 1000 (required by APPLaunch user unit)
for grp in gpio spi i2c input video audio dialout plugdev netdev render bluetooth wireshark kismet; do
    getent group "$grp" >/dev/null || groupadd --system "$grp"
done
if ! getent passwd kali >/dev/null; then
    getent group kali >/dev/null || groupadd -g 1000 kali
    useradd -m -u 1000 -g 1000 -s /usr/bin/zsh kali
fi
usermod -s /usr/bin/zsh kali
for grp in sudo users adm dialout cdrom audio video plugdev games input gpio spi i2c netdev render bluetooth wireshark kismet; do
    getent group "$grp" >/dev/null && usermod -aG "$grp" kali
done
echo 'kali:kali' | chpasswd
echo 'kali ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kali-nopasswd
chmod 440 /etc/sudoers.d/kali-nopasswd
install -d -m 700 -o 1000 -g 1000 /home/kali/.ssh
if [ -f /etc/skel/.zshrc ]; then
    cp -f /etc/skel/.zshrc /home/kali/.zshrc
    chown 1000:1000 /home/kali/.zshrc
fi

# Set locales & wireless regdb
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream 2>/dev/null || true
update-alternatives --set x-session-manager /usr/bin/startlxde 2>/dev/null || true
update-alternatives --set x-terminal-emulator /usr/bin/qterminal 2>/dev/null || true

# Do not let dnsmasq/hostapd auto-start at boot (used on-demand by pentesting tools)
systemctl disable dnsmasq.service hostapd.service 2>/dev/null || true

# Enable core system services
systemctl set-default graphical.target
systemctl enable NetworkManager.service ssh.service bluetooth.service hciuart.service \
                 rtkit-daemon.service zramswap.service lightdm.service systemd-timesyncd.service

# Hold firmware packages so apt upgrade cannot overwrite CM0 Wi-Fi/BT firmware
for pkg in firmware-brcm80211 firmware-nexmon kali-linux-firmware; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        apt-mark hold "$pkg"
    fi
done

apt-get clean
CHROOT

    mkdir -p "$MNT_ROOT$(dirname "$PACKAGES_STAMP")"
    echo "1" > "$MNT_ROOT$PACKAGES_STAMP"
    ok "Kali packages, LXDE, PipeWire, and 88XXau USB Wi-Fi driver installed"
}

# ─── Stage 07: Install APPLaunch, Official Hardware Apps & Camera ────────────
stage_apps() {
    load_resolved_env
    log "Installing CardputerZero APPLaunch (with AppStore), hardware apps & RPi libcamera"

    # 1. Unpack isolated Raspberry Pi libcamera runtime tree first so CameraApp ldd checks can resolve against it
    local camstage="$MNT_ROOT/var/cache/cz-build/camera" cam_args=() f
    rm -rf "$camstage"
    mkdir -p "$camstage"
    for f in "$CACHE_DIR/camera/"*.deb; do
        cp "$f" "$camstage/"
        cam_args+=("/var/cache/cz-build/camera/$(basename "$f")")
    done

    run_chroot "${cam_args[@]}" <<'CHROOT'
rm -rf "$RPI_LIBCAMERA_DIR"
mkdir -p "$RPI_LIBCAMERA_DIR"
for d in "$@"; do dpkg-deb -x "$d" "$RPI_LIBCAMERA_DIR"; done
rm -rf "$RPI_LIBCAMERA_DIR/usr/share/doc" "$RPI_LIBCAMERA_DIR/usr/share/lintian" /var/cache/cz-build/camera
CHROOT

    # 2. Install raspi-utils & M5 apps with per-package ldd verification and lockfile fallback
    local stage="$MNT_ROOT/var/cache/cz-build/apps"
    rm -rf "$stage"
    mkdir -p "$stage/active" "$stage/locked" "$MNT_ROOT/usr/src/cz-kali"
    cp -f "$SCRIPT_DIR/src/Makefile" "$SCRIPT_DIR/src/libcz_fb_lcd.c" "$MNT_ROOT/usr/src/cz-kali/"

    local bsp_install=()
    for pkg in raspi-utils-core raspi-utils-dt libgpiolib0 libdtovl0; do
        f="$(ls "$CACHE_DIR/bsp/${pkg}_"*.deb | head -1)"
        cp "$f" "$stage/"
        bsp_install+=("/var/cache/cz-build/apps/$(basename "$f")")
    done

    run_chroot "${bsp_install[@]}" <<'CHROOT'
export APT_LISTCHANGES_FRONTEND=none
apt-get update -qq
eatmydata apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-overwrite" "$@"
CHROOT

    local slug pkg_name active_deb locked_deb
    while IFS='|' read -r slug pkg_name active_deb locked_deb; do
        [[ -z "$slug" ]] && continue
        cp "$active_deb" "$stage/active/"
        cp "$locked_deb" "$stage/locked/"
        local ch_active="/var/cache/cz-build/apps/active/$(basename "$active_deb")"
        local ch_locked="/var/cache/cz-build/apps/locked/$(basename "$locked_deb")"

        if ! run_chroot "$slug" "$pkg_name" "$ch_active" <<'CHROOT'
s="$1"; p="$2"; deb="$3"
export APT_LISTCHANGES_FRONTEND=none
eatmydata apt-get install -y --no-install-recommends --allow-downgrades -o Dpkg::Options::="--force-overwrite" "$deb"
ld_extra=""
[ "$s" = "camera" ] && ld_extra="$RPI_LIBCAMERA_DIR/usr/lib/aarch64-linux-gnu"
bins="$(dpkg -L "$p" 2>/dev/null | grep -E '^/usr/(bin|sbin|share/.*/bin)/' || true)"
[ "$s" = "camera" ] && [ -f /usr/lib/cz-kali/camera_app.real ] && bins="$bins /usr/lib/cz-kali/camera_app.real"
[ "$s" = "launcher" ] && [ -f /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 ] && bins="$bins /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5"
for bin in $bins; do
    [ -f "$bin" ] && [ -x "$bin" ] || continue
    if file "$bin" | grep -q 'ELF 64-bit'; then
        if LD_LIBRARY_PATH="$ld_extra" ldd "$bin" | grep -q 'not found'; then
            exit 1
        fi
    fi
done
CHROOT
        then
            if [[ "$active_deb" != "$locked_deb" ]]; then
                python3 "$SCRIPT_DIR/scripts/resolve-upstream.py" record-fallback \
                    --lock-file "$LOCK_FILE" \
                    --work-dir "$WORK_DIR" \
                    --component "app:$slug" \
                    --reason "\`$slug\` (\`$(basename "$active_deb")\`) failed install or chroot \`ldd\` check; reverted to locked \`$(basename "$locked_deb")\`"
                run_chroot "$ch_locked" <<'CHROOT'
export APT_LISTCHANGES_FRONTEND=none
eatmydata apt-get install -y --no-install-recommends --allow-downgrades -o Dpkg::Options::="--force-overwrite" "$1"
CHROOT
            else
                err "Failed to install or verify M5 package $slug ($(basename "$active_deb"))"
            fi
        fi
    done < "$WORK_DIR/apps-manifest.txt"

    run_chroot <<'CHROOT'
# Remove excluded default packages if present
dpkg --purge \
    m5cardputerzero-music \
    m5cardputerzero-piano \
    m5cardputerzero-keyboard-guide 2>/dev/null || true
rm -f /usr/share/APPLaunch/applications/music.desktop \
      /usr/share/APPLaunch/applications/piano.desktop \
      /usr/share/APPLaunch/applications/keyboard-guide.desktop

# Divert ZClaw, preinstalled-desktop-apps.tsv, M5CardputerZero-APPLaunch, and camera_app
mkdir -p /usr/lib/cz-kali
for zf in /usr/share/APPLaunch/applications/zclaw.desktop \
          /usr/share/APPLaunch/bin/ZClaw \
          /usr/share/APPLaunch/preinstalled-desktop-apps.tsv; do
    base="$(basename "$zf")"
    if ! dpkg-divert --list "$zf" | grep -q "$zf"; then
        dpkg-divert --local --rename --divert "/usr/lib/cz-kali/${base}.disabled" --add "$zf"
    fi
done
rm -f /usr/share/APPLaunch/applications/zclaw.desktop /usr/share/APPLaunch/bin/ZClaw
printf '# filename\tName\tIcon\tExec\tTerminal\tSysplause\n' > /usr/share/APPLaunch/preinstalled-desktop-apps.tsv

if ! dpkg-divert --list /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch | grep -q M5CardputerZero-APPLaunch; then
    dpkg-divert --local --rename \
        --divert /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 \
        --add /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
fi
cp -a /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch

if [ ! -f /usr/lib/cz-kali/camera_app.real ]; then
    dpkg-divert --local --rename --divert /usr/lib/cz-kali/camera_app.real --add /usr/bin/camera_app
fi

# Build libcz_fb_lcd.so framebuffer redirect helper
make -C /usr/src/cz-kali install-shim

# Keep ADB off by default at boot (can be toggled in APPLaunch -> Settings -> ADB)
systemctl disable cardputer-adb-hotplug.service adbd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service \
      /etc/systemd/system/multi-user.target.wants/adbd.service

rm -rf /var/cache/cz-build/apps /usr/src/cz-kali
apt-get clean
CHROOT

    # Enable systemd user lingering for kali (UID 1000) so APPLaunch starts at boot
    install -d "$MNT_ROOT/var/lib/systemd/linger"
    : > "$MNT_ROOT/var/lib/systemd/linger/kali"
    rm -f "$MNT_ROOT/etc/systemd/user/default.target.wants/APPLaunch.service"

    # Ensure APPLaunch user unit is enabled for kali
    install -d -m 755 -o 1000 -g 1000 "$MNT_ROOT/home/kali/.config/systemd/user/default.target.wants"
    ln -sfn /usr/lib/systemd/user/APPLaunch.service \
        "$MNT_ROOT/home/kali/.config/systemd/user/default.target.wants/APPLaunch.service"
    chown -h 1000:1000 "$MNT_ROOT/home/kali/.config/systemd/user/default.target.wants/APPLaunch.service"

    # Prevent race between APPLaunch startup and udev creating keypad/LCD nodes,
    # export LV_LINUX_FBDEV_DEVICE=/dev/fb_lcd to all child LVGL apps, and stop
    # fb_load (--keep-open) once APPLaunch takes over the LCD
    install -d "$MNT_ROOT/etc/systemd/user/APPLaunch.service.d"
    cat > "$MNT_ROOT/etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf" <<'EOF'
[Unit]
After=systemd-udev-settle.service pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Environment=LV_LINUX_FBDEV_DEVICE=/dev/fb_lcd
UnsetEnvironment=DISPLAY WAYLAND_DISPLAY XAUTHORITY
ExecStartPre=-/usr/bin/xdg-user-dirs-update
ExecStartPre=/bin/sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/input/by-path/platform-3f804000.i2c-event ] && [ -e /dev/fb_lcd ] && exit 0; sleep 1; done; exit 0"
ExecStartPost=-/usr/bin/sudo -n /usr/bin/systemctl --no-block stop fb_load.service
EOF

    cat > "$MNT_ROOT/usr/bin/camera_app" <<EOF
#!/bin/sh
R=$RPI_LIBCAMERA_DIR
L=\$R/usr/lib/aarch64-linux-gnu
export LD_LIBRARY_PATH="\$L\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBCAMERA_IPA_MODULE_PATH="\$L/libcamera/ipa"
export LIBCAMERA_IPA_PROXY_PATH="\$R/usr/libexec/aarch64-linux-gnu/libcamera"
export LIBCAMERA_IPA_CONFIG_PATH="\$R/usr/share/libcamera/ipa"
export LIBCAMERA_RPI_CONFIG_FILE="\${LIBCAMERA_RPI_CONFIG_FILE:-\$R/usr/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml}"
exec /usr/lib/cz-kali/camera_app.real "\$@"
EOF
    chmod 755 "$MNT_ROOT/usr/bin/camera_app"

    # Install LCD -> HDMI mirror tool
    install -m 755 "$CACHE_DIR/pigen/fb-mirror.py"      "$MNT_ROOT/usr/bin/fb-mirror.py"
    install -m 644 "$CACHE_DIR/pigen/fb-mirror.desktop" "$MNT_ROOT/usr/share/applications/fb-mirror.desktop"

    # Optional M5Stack CardputerZero community APT repository reference
    cat > "$MNT_ROOT/etc/apt/sources.list.d/cardputerzero-apps.list" <<'EOF'
# M5Stack CardputerZero community packages mirror (also browsable via on-device Store app)
# deb [trusted=yes] https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/packages stable main
EOF

    ok "APPLaunch, AppStore, M5 hardware apps & IMX219 camera wrapper installed"
}

# ─── Stage 08: Build 320x170 LCD Utilities & Configure APPLaunch ─────────────
stage_launcher() {
    log "Building native 320x170 LCD utilities, helper scripts & APPLaunch configuration"

    install -d -m 755 "$MNT_ROOT/usr/local/bin" \
                      "$MNT_ROOT/usr/src/cz-kali" \
                      "$MNT_ROOT/usr/share/APPLaunch/applications" \
                      "$MNT_ROOT/usr/share/APPLaunch/share/images"
    install -d -m 755 -o 1000 -g 1000 "$MNT_ROOT/home/kali/captures"
    install -m 755 "$SCRIPT_DIR/scripts/cz-usb-gadget"   "$MNT_ROOT/usr/local/bin/cz-usb-gadget"
    install -m 755 "$SCRIPT_DIR/scripts/cz-hw-status"    "$MNT_ROOT/usr/local/bin/cz-hw-status"
    install -m 755 "$SCRIPT_DIR/scripts/cz-hdmi-hotplug" "$MNT_ROOT/usr/local/bin/cz-hdmi-hotplug"
    install -m 755 "$SCRIPT_DIR/scripts/cz-kali-menu"    "$MNT_ROOT/usr/local/bin/cz-kali-menu"
    install -m 755 "$SCRIPT_DIR/scripts/cz-kali-pkgs"    "$MNT_ROOT/usr/local/bin/cz-kali-pkgs"

    cp -f "$SCRIPT_DIR/src/Makefile" \
          "$SCRIPT_DIR/src/cz_ui.h" \
          "$SCRIPT_DIR/src/cz-sysmon.c" \
          "$SCRIPT_DIR/src/cz-term80.c" \
          "$SCRIPT_DIR/src/cz-wifiscan.c" \
          "$SCRIPT_DIR/src/cz-lanscan.c" \
          "$SCRIPT_DIR/src/cz-pktsniff.c" \
          "$SCRIPT_DIR/src/cz-usbgadget.c" \
          "$MNT_ROOT/usr/src/cz-kali/"

    run_chroot <<'CHROOT'
set -e
make -C /usr/src/cz-kali install-apps
rm -rf /usr/src/cz-kali
CHROOT

    # Install Kali monstart / monstop wireless monitor mode helpers (auto-selects external USB Wi-Fi if present)
    cat > "$MNT_ROOT/usr/local/bin/monstart" <<'EOF'
#!/usr/bin/env bash
set -e
iface="${1:-}"
if [[ -z "$iface" ]]; then
    # Prefer USB wireless adapter (wlan1+) since onboard BCM43439 lacks monitor mode
    iface="$(iw dev | awk '$1=="Interface" && $2!="wlan0"{print $2; exit}')"
    iface="${iface:-wlan0}"
fi
ip link set "$iface" down
iw dev "$iface" set type monitor 2>/dev/null || iw phy "$(iw dev "$iface" info | awk '/wiphy/{print "phy"$2}')" interface add "${iface}mon" type monitor
ip link set "$iface" up 2>/dev/null || ip link set "${iface}mon" up
iw dev
EOF
    cat > "$MNT_ROOT/usr/local/bin/monstop" <<'EOF'
#!/usr/bin/env bash
set -e
iface="${1:-wlan1}"
if iw dev "${iface}mon" info >/dev/null 2>&1; then
    ip link set "${iface}mon" down
    iw dev "${iface}mon" del
else
    ip link set "$iface" down
    iw dev "$iface" set type managed
    ip link set "$iface" up
fi
iw dev
EOF
    chmod 755 "$MNT_ROOT/usr/local/bin/monstart" "$MNT_ROOT/usr/local/bin/monstop"

    # Generate icons, .desktop files, preinstalled-desktop-apps.tsv, config.json & carousel sort order
    python3 "$SCRIPT_DIR/scripts/configure-kali-launcher.py" "$MNT_ROOT"
    chown -R 1000:1000 "$MNT_ROOT/home/kali/.config"

    ok "320x170 LCD utilities & APPLaunch configuration installed"
}

# ─── Stage 09: Boot Partition Configuration (config.txt, cmdline.txt, splash) ─
stage_boot() {
    log "Writing /boot/firmware/config.txt, cmdline.txt & Kali Linux LCD boot splash"

    # Divert APPLaunch's M5Stack startup logo & lockscreen so upgrades preserve Kali branding
    run_chroot <<'CHROOT'
mkdir -p /usr/lib/cz-kali
for img in /usr/share/APPLaunch/share/images/logo_lcd.png \
           /usr/share/APPLaunch/share/images/lockscreen.png; do
    base="$(basename "$img")"
    if [ -e "$img" ] && ! dpkg-divert --list "$img" | grep -q "$img"; then
        dpkg-divert --local --rename --divert "/usr/lib/cz-kali/${base}.m5" --add "$img"
    fi
done
CHROOT

    python3 "$SCRIPT_DIR/scripts/gen-kali-splash.py" \
        --emblem "$MNT_ROOT/usr/share/icons/desktop-base/256x256/emblems/emblem-kali.png" \
        --bmp "$MNT_BOOT/splash.bmp" \
        --logo-png "$MNT_ROOT/usr/share/APPLaunch/share/images/logo_lcd.png" \
        --lock-png "$MNT_ROOT/usr/share/APPLaunch/share/images/lockscreen.png"
    chmod 644 "$MNT_BOOT/splash.bmp" \
              "$MNT_ROOT/usr/share/APPLaunch/share/images/logo_lcd.png" \
              "$MNT_ROOT/usr/share/APPLaunch/share/images/lockscreen.png"

    # Ensure fb_load.service renders /boot/firmware/splash.bmp onto /dev/dri/cardputer-zero-internal
    install -d "$MNT_ROOT/etc/systemd/system/fb_load.service.d"
    cat > "$MNT_ROOT/etc/systemd/system/fb_load.service.d/kali-splash.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/fb_load --keep-open /boot/firmware/splash.bmp /dev/dri/cardputer-zero-internal
EOF

    cat > "$MNT_BOOT/config.txt" <<'EOF'
# ==============================================================================
# Kali Linux for M5Stack CardputerZero (CM0 / RP3A0 / Hardware Rev v5)
# ==============================================================================

# Hardware buses (I2C1, I2S audio, SPI0)
dtparam=i2c_arm=on
dtparam=i2s=on
dtparam=spi=on
# Disable legacy PWM bcm2835 audio; ES8389 I2S codec handles onboard audio
dtparam=audio=off

# Sony IMX219 8MP CSI Camera (explicit overlay rather than firmware auto-probe)
camera_auto_detect=0
dtoverlay=imx219
display_auto_detect=1

# 64-bit kernel + initramfs + VC4 KMS (64MiB CMA tuned for 512MB LPDDR2 RAM)
arm_64bit=1
auto_initramfs=1
dtoverlay=vc4-kms-v3d,cma-64
max_framebuffers=2
disable_fw_kms_setup=1
disable_overscan=1
arm_boost=1

[cm4]
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
# Enable UART (ttyAMA0 -> Bluetooth HCI; ttyS0 -> 14P Cap Bus / LoRa+GNSS)
enable_uart=1

# USB 2.0 OTG controller (supports both Host mode and USB Gadget mode)
dtoverlay=dwc2

# CardputerZero v5 carrier board overlays:
#   - ST7789v3 320x170 SPI LCD + M5IOE1 PWM Backlight
#   - TCA8418 46-key I2C Matrix Keyboard + Fn/Sym/Caps LEDs
#   - ES8389 I2S Codec + Speaker Switch (GPIO24) + 3.5mm Jack Detect (GPIO17)
#   - Epson RX8130CE RTC (0x32), Power-fail Shutdown (GPIO6), GPIO Forwarder (SPI0 CS2)
#   - M5IOE1 5V Grove/Ext power switches & USB/Grove muxes
dtoverlay=cardputerzero-v5-overlay
# (For early prototype v3 boards only, swap v5 above for cardputerzero-v3-overlay + bq27220_v3)
dtoverlay=bq27220_v5
dtoverlay=bmi270_bmm150_overlay

# Infrared Receiver (GPIO13) & Transmitter (GPIO12)
dtoverlay=gpio-ir,gpio_pin=13,gpio_pull=up
dtoverlay=gpio-ir-tx,gpio_pin=12
EOF

    local root_puuid
    root_puuid="$(blkid -s PARTUUID -o value "${LOOP_DEV}p2")"
    # Important:
    # - NO console=serial0,115200: keeps /dev/ttyS0 free for the LoRa+GNSS Cap
    # - fbcon=map:99: keeps kernel fbcon off /dev/fb_lcd so APPLaunch owns LCD cleanly
    cat > "$MNT_BOOT/cmdline.txt" <<EOF
console=tty1 root=PARTUUID=${root_puuid} rootfstype=ext4 fsck.repair=yes rootwait quiet fbcon=map:99 consoleblank=0 modules-load=dwc2 cfg80211.ieee80211_regdom=${WIFI_REGDOM}
EOF

    for f in config.txt cmdline.txt; do
        printf "DO NOT EDIT THIS FILE\n\nThe active boot configuration is at /boot/firmware/%s\n" "$f" \
            > "$MNT_ROOT/boot/$f"
    done

    ok "Boot partition configured (ROOT PARTUUID=$root_puuid)"
}

# ─── Stage 10: Hardware, Audio, Display, Low-RAM & System Configs ────────────
stage_configs() {
    log "Applying PipeWire/WirePlumber, Xorg/HDMI, console, low-RAM & peripheral configs"

    # 1. PipeWire + WirePlumber RTKit & Default Volume & ES8389 Priority
    for dir in pipewire.conf.d pipewire-pulse.conf.d client.conf.d; do
        install -d "$MNT_ROOT/etc/pipewire/$dir"
        install -m 644 "$CACHE_DIR/pigen/20-rtkit-direct.conf" \
            "$MNT_ROOT/etc/pipewire/$dir/20-rtkit-direct.conf"
    done
    rm -rf "$MNT_ROOT/etc/pipewire/filter-chain.conf.d" \
           "$MNT_ROOT/home/kali/.config/systemd/user/filter-chain.service.d"
    install -d "$MNT_ROOT/etc/systemd/system/user@1000.service.d"
    install -m 644 "$CACHE_DIR/pigen/20-rtkit-order.conf" \
        "$MNT_ROOT/etc/systemd/system/user@1000.service.d/20-rtkit-order.conf"

    for svc in pipewire pipewire-pulse; do
        local dropin="$MNT_ROOT/home/kali/.config/systemd/user/${svc}.service.d"
        install -d -m 755 -o 1000 -g 1000 "$dropin"
        install -m 644 -o 1000 -g 1000 "$CACHE_DIR/pigen/20-audio-rlimits.conf" \
            "$dropin/20-audio-rlimits.conf"
    done

    # Mask unused PipeWire DSP filter-chain & Bluetooth MPRIS proxy user daemons (~8-12 MiB RAM)
    install -d "$MNT_ROOT/etc/systemd/user"
    rm -f "$MNT_ROOT/etc/systemd/user/default.target.wants/filter-chain.service" \
          "$MNT_ROOT/etc/systemd/user/default.target.wants/mpris-proxy.service"
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/user/filter-chain.service"
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/user/mpris-proxy.service"

    install -d "$MNT_ROOT/etc/wireplumber/wireplumber.conf.d"
    install -m 644 "$CACHE_DIR/pigen/50-cardputerzero-default-volume.conf" \
        "$MNT_ROOT/etc/wireplumber/wireplumber.conf.d/50-cardputerzero-default-volume.conf"
    cat > "$MNT_ROOT/etc/wireplumber/wireplumber.conf.d/51-cardputerzero-es8389-priority.conf" <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.*ES8389.*" }
      { node.name = "~alsa_output.*platform-sound.*" }
    ]
    actions = {
      update-props = {
        priority.driver = 2000
        priority.session = 2000
      }
    }
  }
  {
    matches = [
      { node.name = "~alsa_output.*hdmi.*" }
    ]
    actions = {
      update-props = {
        priority.driver = 500
        priority.session = 500
      }
    }
  }
]
EOF

    # Mask systemd-backlight auto-restore (M5IOE1 PWM driver sets safe boot brightness)
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/systemd-backlight@backlight:backlight.service"

    # 2. X11 / HDMI Desktop Separation:
    #    - Ignore internal TCA8418 keypad & IR receiver in Xorg so APPLaunch keeps exclusive LCD control
    #    - Disable V3D glamor 2D acceleration to save CMA memory on 512MB LPDDR2 SoC
    install -d "$MNT_ROOT/etc/X11/xorg.conf.d"
    cat > "$MNT_ROOT/etc/X11/xorg.conf.d/40-cardputerzero-no-grab.conf" <<'EOF'
Section "InputClass"
    Identifier "CardputerZero integrated keypad - ignore in X11"
    MatchProduct "tca8418c"
    Option "Ignore" "on"
EndSection

Section "InputClass"
    Identifier "CardputerZero IR receiver - ignore in X11"
    MatchProduct "gpio_ir_recv"
    Option "Ignore" "on"
EndSection
EOF

    cat > "$MNT_ROOT/etc/X11/xorg.conf.d/98-vc4-no-glamor.conf" <<'EOF'
Section "Device"
    Identifier "vc4-noaccel"
    Driver "modesetting"
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
EndSection
EOF

    # LightDM autologin to LXDE on HDMI
    install -d "$MNT_ROOT/etc/lightdm/lightdm.conf.d"
    cat > "$MNT_ROOT/etc/lightdm/lightdm.conf.d/lightdm-autologin-greeter.conf" <<'EOF'
[LightDM]
logind-check-graphical=false

[Seat:*]
autologin-user=kali
autologin-session=LXDE
user-session=LXDE
greeter-session=lightdm-autologin-greeter
EOF

    install -d "$MNT_ROOT/etc/xdg/lxsession/LXDE"
    cat > "$MNT_ROOT/etc/xdg/lxsession/LXDE/autostart" <<'EOF'
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
xset s off
xset -dpms
xset s noblank
EOF

    local bg=""
    bg="$(ls "$MNT_ROOT/usr/share/backgrounds/kali/"*.jpg "$MNT_ROOT/usr/share/backgrounds/kali/"*.png 2>/dev/null | head -1 || true)"
    if [[ -n "$bg" && -f "$MNT_ROOT/etc/xdg/pcmanfm/LXDE/pcmanfm.conf" ]]; then
        bg="${bg#"$MNT_ROOT"}"
        sed -i "s|^wallpaper=.*|wallpaper=${bg}|" "$MNT_ROOT/etc/xdg/pcmanfm/LXDE/pcmanfm.conf"
    fi

    cat > "$MNT_ROOT/etc/skel/.xsession" <<'EOF'
exec startlxde
EOF
    chmod 755 "$MNT_ROOT/etc/skel/.xsession"
    install -m 755 -o 1000 -g 1000 "$MNT_ROOT/etc/skel/.xsession" "$MNT_ROOT/home/kali/.xsession"

    # 3. Console Safety & HDMI VT2..VT6 Mapping:
    #    Mask tty1 so keypad presses in APPLaunch never type into an active VT shell
    rm -rf "$MNT_ROOT/etc/systemd/system/getty@tty1.service.d"
    rm -f  "$MNT_ROOT/etc/systemd/system/getty.target.wants/getty@tty1.service"
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/getty@tty1.service"
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/autovt@tty1.service"

    install -d -m 755 "$MNT_ROOT/usr/local/sbin"
    cat > "$MNT_ROOT/usr/local/sbin/cz-hdmi-console" <<'EOF'
#!/bin/sh
fb="$1"
[ -n "$fb" ] || exit 0
con2fbmap=$(command -v con2fbmap || echo /usr/bin/con2fbmap)
for vt in 2 3 4 5 6; do
    "$con2fbmap" "$vt" "$fb" || true
done
EOF
    chmod 755 "$MNT_ROOT/usr/local/sbin/cz-hdmi-console"
    cat > "$MNT_ROOT/etc/udev/rules.d/90-cz-hdmi-console.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb[0-9]*", ATTR{name}=="vc4drmfb", RUN+="/usr/local/sbin/cz-hdmi-console %n"
EOF

    # On-demand HDMI desktop: skip LightDM/Xorg when booted unplugged, auto-start on
    # HDMI plug-in, and stop after 5s unplug debounce to reclaim ~75-90 MiB RAM
    install -d -m 755 "$MNT_ROOT/etc/default" \
                      "$MNT_ROOT/etc/systemd/system/lightdm.service.d"
    cat > "$MNT_ROOT/etc/default/cz-hdmi-desktop" <<'EOF'
# CardputerZero HDMI desktop policy: auto | always | off
HDMI_DESKTOP_MODE=auto
HDMI_UNPLUG_DELAY=5
EOF
    cat > "$MNT_ROOT/etc/systemd/system/lightdm.service.d/hdmi-on-demand.conf" <<'EOF'
[Unit]
After=systemd-user-sessions.service systemd-udev-settle.service
OnFailure=

[Service]
ExecCondition=/usr/local/bin/cz-hdmi-hotplug check
Restart=on-failure
RestartSec=2s
TimeoutStopSec=10s
EOF
    cat > "$MNT_ROOT/etc/systemd/system/cz-hdmi-hotplug.service" <<'EOF'
[Unit]
Description=CardputerZero On-Demand HDMI Desktop Hotplug Handler
After=systemd-user-sessions.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cz-hdmi-hotplug sync
EOF
    cat > "$MNT_ROOT/etc/udev/rules.d/91-cz-hdmi-hotplug.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*-HDMI-A-*", RUN+="/usr/bin/systemctl --no-block start cz-hdmi-hotplug.service"
ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}!="platform-3f204000.spi-cs-0", RUN+="/usr/bin/systemctl --no-block start cz-hdmi-hotplug.service"
EOF

    # 4. Glycin Sandbox Bypass & Thumbnailer Diversion + 512MB RAM Diet
    install -d "$MNT_ROOT/etc/environment.d" "$MNT_ROOT/etc/profile.d"
    echo "GLYCIN_SANDBOX_MECHANISM=not-sandboxed" > "$MNT_ROOT/etc/environment.d/glycin-nosandbox.conf"
    echo "export GLYCIN_SANDBOX_MECHANISM=not-sandboxed" > "$MNT_ROOT/etc/profile.d/glycin-nosandbox.sh"
    if ! grep -q '^GLYCIN_SANDBOX_MECHANISM=' "$MNT_ROOT/etc/environment" 2>/dev/null; then
        echo "GLYCIN_SANDBOX_MECHANISM=not-sandboxed" >> "$MNT_ROOT/etc/environment"
    fi

    run_chroot <<'CHROOT'
for f in $(ls /usr/share/thumbnailers/glycin-*.thumbnailer 2>/dev/null) \
         $(ls /usr/share/glycin-loaders/*/conf.d/glycin-svg.conf 2>/dev/null); do
    [ -e "$f" ] && dpkg-divert --rename --divert "$f.disabled" --add "$f" || true
done

for f in blueman.desktop orca-autostart.desktop onboard-autostart.desktop \
         geoclue-demo-agent.desktop print-applet.desktop xiccd.desktop \
         xcape-super-key-bind.desktop pkcs11-register.desktop \
         gnome-keyring-pkcs11.desktop gnome-keyring-secrets.desktop; do
    p="/etc/xdg/autostart/$f"
    [ -f "$p" ] && ! grep -q "^Hidden=true" "$p" && echo "Hidden=true" >> "$p" || true
done

# Free /dev/ttyS0 for LoRa+GNSS Cap; keep gpsd socket-activated only
systemctl mask serial-getty@ttyS0.service
systemctl disable gpsd.service 2>/dev/null || true
systemctl enable gpsd.socket
CHROOT

    # 5. ZRAM Swap (75% zstd) + gpsd (/dev/ttyS0 @ 115200) + dbus workdir fix
    cat > "$MNT_ROOT/etc/default/zramswap" <<'EOF'
ALGO=zstd
PERCENT=75
PRIORITY=100
EOF

    cat > "$MNT_ROOT/etc/default/gpsd" <<'EOF'
DEVICES="/dev/ttyS0"
GPSD_OPTIONS="-s 115200"
USBAUTO="false"
START_DAEMON="true"
EOF

    install -d "$MNT_ROOT/etc/systemd/system/dbus.service.d"
    cat > "$MNT_ROOT/etc/systemd/system/dbus.service.d/workdir.conf" <<'EOF'
[Service]
WorkingDirectory=/
EOF

    # 6. Realtek USB Wi-Fi Monitor/Injection Modprobe & Hotplug Rules + RFKill Unblock
    install -d "$MNT_ROOT/etc/modprobe.d"
    cat > "$MNT_ROOT/etc/modprobe.d/blacklist-8192cu.conf" <<'EOF'
blacklist 8192cu
EOF
    cat > "$MNT_ROOT/etc/modprobe.d/rfkill_default.conf" <<'EOF'
options rfkill default_state=1
EOF
    cat > "$MNT_ROOT/etc/modprobe.d/rtw88-dkms-override.conf" <<'EOF'
blacklist rtw88_8821au
blacklist rtw88_8821a
blacklist rtw88_88xxa
blacklist rtw88_8812au
blacklist rtw88_8814au
EOF
    # Load 88XXau.ko (~3 MiB) on USB hotplug/modalias rather than at every boot
    rm -f "$MNT_ROOT/etc/modules-load.d/rtw88xxau.conf"
    cat > "$MNT_ROOT/etc/udev/rules.d/99-rtw88xxau.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0811", RUN+="/usr/sbin/modprobe 88XXau"
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8822", RUN+="/usr/sbin/modprobe 88XXau"
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="a811", RUN+="/usr/sbin/modprobe 88XXau"
EOF

    # Pre-seed systemd-rfkill unblocked so BlueZ/NetworkManager control radios cleanly,
    # and set BlueZ AutoEnable=false so Bluetooth stays powered down at boot to save battery
    # until enabled in APPLaunch -> Settings -> Bluetooth or `bluetoothctl power on`
    install -d "$MNT_ROOT/var/lib/systemd/rfkill"
    for addr in 107d50c000.serial 3f215040.serial 3f201000.serial 20215040.serial fe215040.serial soc; do
        echo 0 > "$MNT_ROOT/var/lib/systemd/rfkill/platform-${addr}:bluetooth"
    done
    if [[ -f "$MNT_ROOT/etc/bluetooth/main.conf" ]]; then
        if grep -qE '^#?[[:space:]]*AutoEnable[[:space:]]*=' "$MNT_ROOT/etc/bluetooth/main.conf"; then
            sed -i -E 's/^#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable=false/' "$MNT_ROOT/etc/bluetooth/main.conf"
        else
            printf '\n[Policy]\nAutoEnable=false\n' >> "$MNT_ROOT/etc/bluetooth/main.conf"
        fi
    else
        install -d "$MNT_ROOT/etc/bluetooth"
        printf '[Policy]\nAutoEnable=false\n' > "$MNT_ROOT/etc/bluetooth/main.conf"
    fi

    # 7. Polkit rule so kali (in netdev/sudo) can join Wi-Fi via APPLaunch / nmcli without prompt
    install -d "$MNT_ROOT/etc/polkit-1/rules.d"
    cat > "$MNT_ROOT/etc/polkit-1/rules.d/10-networkmanager.rules" <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
        (subject.isInGroup("netdev") || subject.isInGroup("sudo"))) {
        return polkit.Result.YES;
    }
});
EOF

    # 8. Trim ultra-thin font weights that render poorly on 320x170 RGB565 LCD
    install -d "$MNT_ROOT/etc/dpkg/dpkg.cfg.d"
    cat > "$MNT_ROOT/etc/dpkg/dpkg.cfg.d/01-cardputerzero-fonts" <<'EOF'
path-exclude=/usr/share/fonts/opentype/noto/NotoSansCJK-DemiLight.ttc
path-exclude=/usr/share/fonts/opentype/noto/NotoSansCJK-Light.ttc
path-exclude=/usr/share/fonts/opentype/noto/NotoSansCJK-Thin.ttc
EOF

    # 9. Persistent bounded systemd journal (max 50M)
    install -d "$MNT_ROOT/var/log/journal" "$MNT_ROOT/etc/systemd/journald.conf.d"
    cat > "$MNT_ROOT/etc/systemd/journald.conf.d/persist.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
EOF

    ok "All hardware, audio, display, low-RAM & peripheral configs staged"
}

# ─── Stage 11: Network, Hostname & First-Boot Provisioning Tweaks ────────────
stage_tweaks() {
    log "Configuring NetworkManager, hostname ($CZ_HOSTNAME), first-boot resize & SSH keygen"

    # NetworkManager owns all interfaces (including USB/RJ45 Ethernet)
    install -d "$MNT_ROOT/etc/NetworkManager"
    cat > "$MNT_ROOT/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true
EOF
    ln -sfn /dev/null "$MNT_ROOT/etc/systemd/system/networking.service"

    # Hostname & /etc/hosts
    echo "$CZ_HOSTNAME" > "$MNT_ROOT/etc/hostname"
    cat > "$MNT_ROOT/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	${CZ_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

    # First-boot SD card root partition & ext4 online expansion
    install -d -m 755 "$MNT_ROOT/usr/local/sbin" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
    cat > "$MNT_ROOT/usr/local/sbin/cz-firstboot-resize.sh" <<'EOF'
#!/bin/sh
set -e
SENTINEL=/var/lib/cz-kali/.resized
[ -e "$SENTINEL" ] && exit 0
SRC=$(findmnt -no SOURCE /)
DISK=$(lsblk -no PKNAME "$SRC" 2>/dev/null)
PART=$(printf '%s' "$SRC" | grep -oE '[0-9]+$')
if [ -n "$DISK" ] && [ -n "$PART" ]; then
    growpart "/dev/$DISK" "$PART" || true
    resize2fs "$SRC" || true
fi
mkdir -p "$(dirname "$SENTINEL")"
: > "$SENTINEL"
EOF
    chmod 755 "$MNT_ROOT/usr/local/sbin/cz-firstboot-resize.sh"

    cat > "$MNT_ROOT/etc/systemd/system/cz-firstboot-resize.service" <<'EOF'
[Unit]
Description=Expand Kali root partition to fill microSD card on first boot
ConditionPathExists=!/var/lib/cz-kali/.resized
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cz-firstboot-resize.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    ln -sfn /etc/systemd/system/cz-firstboot-resize.service \
        "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/cz-firstboot-resize.service"

    # First-boot unique SSH host key regeneration (so flashed images don't share host keys)
    cat > "$MNT_ROOT/etc/systemd/system/cz-firstboot-sshkeys.service" <<'EOF'
[Unit]
Description=Generate unique OpenSSH host keys on first boot
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    ln -sfn /etc/systemd/system/cz-firstboot-sshkeys.service \
        "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/cz-firstboot-sshkeys.service"

    # Suppress verbose Kali login banner so 45x10 LCD Zsh opens to a clean prompt
    : > "$MNT_ROOT/etc/skel/.hushlogin"
    install -m 644 -o 1000 -g 1000 "$MNT_ROOT/etc/skel/.hushlogin" "$MNT_ROOT/home/kali/.hushlogin"

    # Restore critical directory permissions defensively
    chmod 755 "$MNT_ROOT" "$MNT_ROOT/usr" "$MNT_ROOT/usr/bin" "$MNT_ROOT/usr/sbin" \
              "$MNT_ROOT/usr/lib" "$MNT_ROOT/etc" "$MNT_ROOT/var" "$MNT_ROOT/var/lib" \
              "$MNT_ROOT/run" "$MNT_ROOT/home"
    chmod 1777 "$MNT_ROOT/tmp"

    ok "First-boot services, NetworkManager & hostname configured"
}

# ─── Stage 12: Comprehensive Automated Hardware & System Verification ────────
VERIFY_ERRS=0
VERIFY_PASS=0
vpass() { VERIFY_PASS=$((VERIFY_PASS + 1)); }
vfail() { warn "FAIL: $1"; VERIFY_ERRS=$((VERIFY_ERRS + 1)); }
vcheck() { if eval "$1"; then vpass; else vfail "$2"; fi; }

stage_verify() {
    log "Running comprehensive hardware & OS verification suite on image"
    VERIFY_ERRS=0
    VERIFY_PASS=0

    # Run dynamic linker & module vermagic checks inside chroot first
    chroot_up
    local chroot_report
    chroot_report="$(run_chroot <<'CHROOT'
set -e
# 1. Check APPLaunch shared libraries
if ldd /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch | grep -q 'not found'; then
    echo "LDD_FAIL:M5CardputerZero-APPLaunch"
fi
# 2. Check AppStore shared libraries
if [ -x /usr/share/APPLaunch/bin/M5CardputerZero-AppStore ]; then
    if ldd /usr/share/APPLaunch/bin/M5CardputerZero-AppStore | grep -q 'not found'; then
        echo "LDD_FAIL:M5CardputerZero-AppStore"
    fi
fi
# 3. Check framebuffer shim + all 6 native 320x170 Kali C binaries
if ldd /usr/lib/cz-kali/libcz_fb_lcd.so | grep -q 'not found'; then
    echo "LDD_FAIL:libcz_fb_lcd.so"
fi
for app in cz-sysmon cz-term80 cz-wifiscan cz-lanscan cz-pktsniff cz-usbgadget; do
    if ldd "/usr/local/bin/$app" | grep -q 'not found'; then
        echo "LDD_FAIL:$app"
    fi
    CZ_DUMP_PPM=/tmp/cz_verify.ppm "/usr/local/bin/$app"
    if ! head -n 2 /tmp/cz_verify.ppm | tr '\n' ' ' | grep -q '^P6 320 170 ' || [ "$(stat -c '%s' /tmp/cz_verify.ppm)" != "163215" ]; then
        echo "RENDER_FAIL:$app"
    fi
    rm -f /tmp/cz_verify.ppm
done
echo "LCD_REDIRECT_OK" > /tmp/cz_fake_lcd
redir_out=$(CZ_FORCE_FB_LCD=1 CZ_FB_TARGET=/tmp/cz_fake_lcd LD_PRELOAD=/usr/lib/cz-kali/libcz_fb_lcd.so \
    python3 -c 'import os, subprocess; fd=os.open("/dev/fb0", os.O_RDWR); d=os.read(fd, 32).decode().strip(); os.close(fd); c=subprocess.check_output(["/bin/sh","-c","printf %s \"${LD_PRELOAD:-CLEAN}\""]).decode(); print(f"{d}:{c}")')
rm -f /tmp/cz_fake_lcd
if [ "$redir_out" != "LCD_REDIRECT_OK:CLEAN" ]; then
    echo "FB_REDIRECT_FAIL:$redir_out"
fi
# 4. Check CameraApp against private Raspberry Pi libcamera tree
if LD_LIBRARY_PATH="$RPI_LIBCAMERA_DIR/usr/lib/aarch64-linux-gnu" ldd /usr/lib/cz-kali/camera_app.real | grep -q 'not found'; then
    echo "LDD_FAIL:camera_app.real"
fi
# 5. Check vermagic of every compiled CardputerZero .ko module
for ko in /usr/lib/modules/"$KVER"/extra/*.ko; do
    vm=$(modinfo -F vermagic "$ko" | awk '{print $1}')
    if [ "$vm" != "$KVER" ]; then
        echo "VERMAGIC_FAIL:$ko:$vm"
    fi
done
# 6. Verify RX8130 RTC kernel support exists in RPi 6.18 modules.alias
if ! grep -q 'rx8130' /usr/lib/modules/"$KVER"/modules.alias; then
    echo "RTC_ALIAS_FAIL"
fi
echo "CHROOT_CHECKS_DONE"
CHROOT
)"
    chroot_down

    [[ "$chroot_report" == *"CHROOT_CHECKS_DONE"* ]] && vpass || vfail "chroot verification aborted"
    for bad in $(grep -E '^(LDD_FAIL|VERMAGIC_FAIL|RTC_ALIAS_FAIL|RENDER_FAIL|FB_REDIRECT_FAIL)' <<< "$chroot_report" || true); do
        vfail "Binary/Module check failed: $bad"
    done
    if ! grep -qE '^(LDD_FAIL|VERMAGIC_FAIL|RTC_ALIAS_FAIL|RENDER_FAIL|FB_REDIRECT_FAIL)' <<< "$chroot_report"; then
        ok "ldd library resolution, all 6 native 320x170 Kali apps, fb_lcd shim & module vermagic ($KVER) verified inside chroot"
        VERIFY_PASS=$((VERIFY_PASS + 12))
    fi

    # Bootloader, Kernel, DTBs & Overlays
    for f in bootcode.bin start.elf fixup.dat kernel8.img initramfs8 bcm2710-rpi-cm0.dtb splash.bmp \
             overlays/vc4-kms-v3d.dtbo overlays/imx219.dtbo overlays/dwc2.dtbo \
             overlays/gpio-ir.dtbo overlays/gpio-ir-tx.dtbo \
             overlays/cardputerzero-v5-overlay.dtbo overlays/cardputerzero-v3-overlay.dtbo \
             overlays/bq27220_v5.dtbo overlays/bmi270_bmm150_overlay.dtbo \
             overlays/spi0-spidev2-gpio22-overlay.dtbo overlays/rx8130-overlay.dtbo; do
        vcheck "[[ -f '$MNT_BOOT/$f' ]]" "Missing boot file: /boot/firmware/$f"
    done
    vcheck "[[ '$(kernel_img_version)' == '$KVER' ]]" "kernel8.img version mismatch (expected $KVER)"
    vcheck "[[ -d '$MNT_ROOT/usr/lib/modules/$KVER' ]]" "Missing /usr/lib/modules/$KVER"

    for p in $KERNEL_HOLD_PKGS raspi-firmware; do
        vcheck "dpkg_held '$p'" "Package not installed+held: $p"
    done
    vcheck "! dpkg_installed brcmfmac-nexmon-dkms" "brcmfmac-nexmon-dkms must not be installed"

    # Boot config.txt & cmdline.txt
    for line in "dtparam=i2c_arm=on" "dtparam=i2s=on" "dtparam=spi=on" "dtparam=audio=off" \
                "dtoverlay=imx219" "dtoverlay=vc4-kms-v3d,cma-64" "enable_uart=1" "dtoverlay=dwc2" \
                "dtoverlay=cardputerzero-v5-overlay" "dtoverlay=bq27220_v5" "dtoverlay=bmi270_bmm150_overlay" \
                "dtoverlay=gpio-ir,gpio_pin=13,gpio_pull=up" "dtoverlay=gpio-ir-tx,gpio_pin=12"; do
        vcheck "grep -qxF '$line' '$MNT_BOOT/config.txt'" "config.txt missing: $line"
    done
    vcheck "grep -q 'root=PARTUUID=' '$MNT_BOOT/cmdline.txt'" "cmdline.txt missing root=PARTUUID"
    vcheck "grep -qw 'fbcon=map:99' '$MNT_BOOT/cmdline.txt'" "cmdline.txt missing fbcon=map:99"
    vcheck "! grep -qE 'console=(serial0|ttyS0)' '$MNT_BOOT/cmdline.txt'" "cmdline.txt must not claim serial0/ttyS0"

    # CardputerZero Out-of-Tree Kernel Modules & Firmware Blobs
    for m in panel-mipi-dbi-m st7789v_m5stack pwm_bl_m5stack tca8418_keypad_m5stack \
             es8389_m5stack simple-amplifier cardputerzero-audio \
             bq27xxx_battery bq27xxx_battery_i2c m5ioe1 gpio-forwarder powerfail_suo \
             bmi270_core bmi270_i2c bmc150_magn bmc150_magn_bmi270; do
        vcheck "[[ -f '$MNT_ROOT/usr/lib/modules/$KVER/extra/$m.ko' ]]" "Missing CZ module: $m.ko"
    done
    vcheck "grep -q 'extra/panel-mipi-dbi-m.ko' '$MNT_ROOT/usr/lib/modules/$KVER/modules.dep'" "depmod missing CZ extra modules"
    vcheck "[[ -f '$MNT_ROOT/usr/lib/firmware/cardputerzero,st7789v_lcd.bin' ]]" "Missing ST7789v3 panel init firmware"
    vcheck "[[ -f '$MNT_ROOT/usr/lib/firmware/bmi270-init-data.fw' ]]" "Missing BMI270 IMU firmware"
    vcheck "[[ -x '$MNT_ROOT/usr/sbin/fb_load' ]]" "Missing fb_load splash binary"
    vcheck "[[ -x '$MNT_ROOT/usr/local/bin/pigpiod' ]]" "Missing pigpiod GPIO PWM daemon"

    # CM0 Wi-Fi, Bluetooth & External USB Wi-Fi Monitor/Injection
    vcheck "grep -q '^boardflags3=0x04000000' '$MNT_ROOT/usr/lib/firmware/cypress/cyfmac43439-sdio.txt'" "Wrong/missing CM0 BCM43439 Wi-Fi NVRAM"
    vcheck "[[ -e '$MNT_ROOT/usr/lib/firmware/brcm/brcmfmac43439-sdio.raspberrypi,0-compute-module.bin' ]]" "Missing CM0 brcmfmac43439 SDIO firmware"
    vcheck "[[ -e '$MNT_ROOT/usr/lib/firmware/brcm/BCM4343A2.raspberrypi,0-compute-module.hcd' ]]" "Missing CM0 BCM4343A2 Bluetooth HCD firmware"
    vcheck "[[ -x '$MNT_ROOT/usr/bin/btuart' ]]" "Missing btuart Bluetooth attach helper"
    vcheck "find '$MNT_ROOT/usr/lib/modules/$KVER' -name '88XXau.ko*' | grep -q ." "Missing patched 88XXau.ko USB Wi-Fi driver"

    # Udev Rules, Permissions & User Groups
    for r in etc/udev/rules.d/99-cardputer-zero-lcd.rules \
             etc/udev/rules.d/99-cardputer-zero-keyboard.rules \
             etc/udev/rules.d/99-ignore-i2c-key.rules \
             etc/udev/rules.d/70-cardputerzero-peripherals.rules \
             etc/udev/rules.d/90-cz-hdmi-console.rules \
             etc/udev/rules.d/91-cz-hdmi-hotplug.rules \
             usr/lib/udev/rules.d/zz-cardputerzero-hdmi-display.rules \
             usr/lib/udev/rules.d/60-cardputerzero-leds.rules \
             usr/lib/udev/rules.d/99-com.rules \
             usr/lib/udev/rules.d/60-backlight.rules \
             usr/lib/udev/rules.d/60-dma-heap.rules \
             usr/lib/tmpfiles.d/cardputerzero-leds.conf; do
        vcheck "[[ -f '$MNT_ROOT/$r' ]]" "Missing udev/tmpfiles rule: $r"
    done

    for grp in sudo gpio spi i2c input video audio dialout plugdev netdev render bluetooth wireshark kismet; do
        vcheck "grep '^$grp:' '$MNT_ROOT/etc/group' | grep -qw kali" "kali user missing from group: $grp"
    done

    local g
    for g in $(grep -hoE 'GROUP="[a-z0-9_-]+"' "$MNT_ROOT"/usr/lib/udev/rules.d/*.rules \
                   "$MNT_ROOT"/etc/udev/rules.d/*.rules 2>/dev/null | cut -d'"' -f2 | sort -u); do
        vcheck "grep -q '^$g:' '$MNT_ROOT/etc/group'" "udev rule references non-existent group: $g"
    done

    # Audio, Display, Consoles, Power/RAM & Launcher Integration
    vcheck "[[ -f '$MNT_ROOT/etc/wireplumber/wireplumber.conf.d/50-cardputerzero-default-volume.conf' ]]" "Missing WirePlumber default volume config"
    vcheck "[[ -f '$MNT_ROOT/etc/wireplumber/wireplumber.conf.d/51-cardputerzero-es8389-priority.conf' ]]" "Missing WirePlumber ES8389 priority config"
    vcheck "[[ \"\$(readlink '$MNT_ROOT/etc/systemd/user/filter-chain.service')\" == '/dev/null' && \"\$(readlink '$MNT_ROOT/etc/systemd/user/mpris-proxy.service')\" == '/dev/null' ]]" "filter-chain / mpris-proxy user units not masked"
    vcheck "[[ ! -e '$MNT_ROOT/etc/modules-load.d/rtw88xxau.conf' && -f '$MNT_ROOT/etc/udev/rules.d/99-rtw88xxau.rules' ]]" "88XXau must be hotplug-only (no boot modules-load)"
    vcheck "grep -qx 'AutoEnable=false' '$MNT_ROOT/etc/bluetooth/main.conf'" "Bluetooth AutoEnable=false not set in /etc/bluetooth/main.conf"
    vcheck "grep -q 'KERNEL==\"rfkill\"' '$MNT_ROOT/etc/udev/rules.d/70-cardputerzero-peripherals.rules'" "Missing rfkill netdev permission rule"
    vcheck "[[ -f '$MNT_ROOT/etc/X11/xorg.conf.d/40-cardputerzero-no-grab.conf' ]]" "Missing X11 keypad/IR ignore config"
    vcheck "[[ -f '$MNT_ROOT/etc/X11/xorg.conf.d/98-vc4-no-glamor.conf' ]]" "Missing X11 no-glamor config"
    vcheck "[[ -f '$MNT_ROOT/etc/systemd/system/lightdm.service.d/hdmi-on-demand.conf' && -f '$MNT_ROOT/etc/systemd/system/cz-hdmi-hotplug.service' && -f '$MNT_ROOT/etc/default/cz-hdmi-desktop' ]]" "Missing on-demand HDMI desktop units/config"
    vcheck "[[ -f '$MNT_ROOT/var/lib/systemd/linger/kali' ]]" "Missing systemd linger for kali"
    vcheck "[[ -x '$MNT_ROOT/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch' && -f '$MNT_ROOT/usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5' ]] && ! cmp -s '$MNT_ROOT/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch' '$MNT_ROOT/usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5'" "APPLaunch missing or sort/power patch not applied"
    vcheck "[[ -f '$MNT_ROOT/usr/lib/cz-kali/libcz_fb_lcd.so' ]]" "Missing libcz_fb_lcd.so"
    vcheck "grep -q 'LV_LINUX_FBDEV_DEVICE=/dev/fb_lcd' '$MNT_ROOT/etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf' && grep -q 'stop fb_load.service' '$MNT_ROOT/etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf'" "APPLaunch drop-in missing LV_LINUX_FBDEV_DEVICE or fb_load stop"
    vcheck "[[ -x '$MNT_ROOT/usr/bin/camera_app' ]] && grep -q '$RPI_LIBCAMERA_DIR' '$MNT_ROOT/usr/bin/camera_app'" "Camera wrapper invalid"
    vcheck "dpkg_installed python3-requests && dpkg_installed kali-tweaks" "Missing python3-requests or kali-tweaks"
    for kbin in cz-sysmon cz-term80 cz-wifiscan cz-lanscan cz-pktsniff cz-usbgadget cz-kali-menu cz-kali-pkgs cz-usb-gadget cz-hw-status cz-hdmi-hotplug monstart monstop; do
        vcheck "[[ -x '$MNT_ROOT/usr/local/bin/$kbin' ]]" "Missing helper binary/script: /usr/local/bin/$kbin"
    done
    for kdt in kali-wifi.desktop kali-term80.desktop kali-zsh.desktop kali-menu.desktop kali-btop.desktop kali-lanscan.desktop kali-pktsniff.desktop kali-usbgadget.desktop kali-pkgs.desktop; do
        vcheck "[[ -f '$MNT_ROOT/usr/share/APPLaunch/applications/$kdt' ]] && grep -q '^${kdt}	' '$MNT_ROOT/usr/share/APPLaunch/preinstalled-desktop-apps.tsv'" "Launcher app missing or not registered in preinstalled-desktop-apps.tsv: $kdt"
    done
    for enabled_key in app_desktop_kali_wifi_desktop_84940702 app_desktop_kali_term80_desktop_127bc199 app_desktop_kali_zsh_desktop_0f623300 app_desktop_kali_menu_desktop_6439a2fc app_desktop_kali_btop_desktop_1e5276de app_desktop_kali_lanscan_desktop_e2c9f473 app_desktop_kali_pktsniff_desktop_2c852172 app_desktop_kali_usbgadget_desktop_1923607b app_desktop_kali_pkgs_desktop_cce61bf0; do
        vcheck "grep -q '\"$enabled_key\": 1' '$MNT_ROOT/home/kali/.config/cardputerzero/config.json'" "App toggle missing in config.json: $enabled_key"
    done
    vcheck "[[ \"\$(stat -c '%u:%g' '$MNT_ROOT/home/kali/.config/cardputerzero/config.json')\" == '1000:1000' ]]" "config.json not owned by 1000:1000 (kali:kali)"
    vcheck "! dpkg_installed m5cardputerzero-piano && ! dpkg_installed m5cardputerzero-music && ! dpkg_installed m5cardputerzero-keyboard-guide" "Excluded demo packages still installed"
    for removed_dt in zclaw.desktop piano.desktop music.desktop keyboard-guide.desktop; do
        vcheck "[[ ! -e '$MNT_ROOT/usr/share/APPLaunch/applications/$removed_dt' ]]" "Excluded desktop entry still present: $removed_dt"
    done
    vcheck "! grep -q 'zclaw.desktop' '$MNT_ROOT/usr/share/APPLaunch/preinstalled-desktop-apps.tsv'" "zclaw still listed in preinstalled-desktop-apps.tsv"
    for disabled_key in app_Python app_Game app_Tank app_Math; do
        vcheck "grep -q '\"$disabled_key\": 0' '$MNT_ROOT/home/kali/.config/cardputerzero/config.json'" "Built-in app not disabled in config.json: $disabled_key"
    done
    local m5_splash_sha=""
    [[ -f "$CACHE_DIR/pigen/splash.bmp" ]] && m5_splash_sha="$(sha256sum "$CACHE_DIR/pigen/splash.bmp" | awk '{print $1}')"
    vcheck "[[ \"\$(stat -c '%s' '$MNT_BOOT/splash.bmp')\" == '108866' ]] && [[ \"\$(sha256sum '$MNT_BOOT/splash.bmp' | awk '{print \$1}')\" != '$m5_splash_sha' ]]" "Kali splash.bmp invalid"
    vcheck "grep -q '/boot/firmware/splash.bmp /dev/dri/cardputer-zero-internal' '$MNT_ROOT/etc/systemd/system/fb_load.service.d/kali-splash.conf'" "fb_load.service missing Kali splash override"
    vcheck "[[ -f '$MNT_ROOT/usr/share/APPLaunch/share/images/logo_lcd.png' && -f '$MNT_ROOT/usr/lib/cz-kali/logo_lcd.png.m5' ]]" "APPLaunch logo_lcd.png not replaced/diverted"
    vcheck "[[ ! -e '$MNT_ROOT/usr/sbin/policy-rc.d' ]]" "policy-rc.d left behind in rootfs"

    for d in / /usr /usr/bin /usr/sbin /usr/lib /lib /etc /var /var/lib /run /home; do
        local mode
        mode="$(stat -L -c '%a' "$MNT_ROOT$d")"
        vcheck "[[ '$mode' == '755' || '$mode' == '555' ]]" "Bad mode $mode on $d"
    done
    vcheck "[[ '$(stat -L -c '%a' "$MNT_ROOT/tmp")' == '1777' ]]" "/tmp mode is not 1777"

    if (( VERIFY_ERRS == 0 )); then
        ok "ALL $VERIFY_PASS verification checks PASSED with 0 errors!"
        if [[ "$M5_UPDATE_MODE" == "auto" && "${NO_LOCK_WRITE:-0}" != "1" && -f "$WORK_DIR/resolved-lock.json" ]]; then
            local lock_owner
            lock_owner="$(stat -c '%u:%g' "$LOCK_FILE" 2>/dev/null || echo '0:0')"
            cp -f "$WORK_DIR/resolved-lock.json" "$LOCK_FILE"
            chown "$lock_owner" "$LOCK_FILE" 2>/dev/null || true
        fi
    else
        err "$VERIFY_ERRS verification check(s) failed ($VERIFY_PASS passed)"
    fi
}

# ─── Stage 13: Finalize Image & Compress (.img.xz + .sha256) ─────────────────
stage_finalize() {
    log "Finalizing rootfs for clean first-boot distribution"
    chroot_down

    # Point APT back to canonical GeoIP load-balanced http.kali.org mirror
    cat > "$MNT_ROOT/etc/apt/sources.list" <<'EOF'
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

    # Remove build-time caches, apt lists, host-specific resolv.conf backup & SSH host keys
    rm -rf "$MNT_ROOT/var/lib/apt/lists/"* \
           "$MNT_ROOT/var/cache/apt/archives/"*.deb \
           "$MNT_ROOT/var/cache/cz-build" \
           "$MNT_ROOT/etc/ssh/"ssh_host_*_key* \
           "$MNT_ROOT/root/.bash_history" \
           "$MNT_ROOT/var/lib/dbus/machine-id"
    rm -f "$MNT_ROOT/etc/resolv.conf"
    echo "nameserver 1.1.1.1" > "$MNT_ROOT/etc/resolv.conf"
    echo "uninitialized" > "$MNT_ROOT/etc/machine-id"

    # Zero free blocks inside mounted filesystems for optimal xz compression
    dd if=/dev/zero of="$MNT_BOOT/.zero" bs=1M 2>/dev/null || true
    rm -f "$MNT_BOOT/.zero"

    sync
    local root_part="${LOOP_DEV}p2"
    umount "$MNT_BOOT"
    umount "$MNT_ROOT"

    e2fsck -f -y "$root_part" || true
    if command -v zerofree >/dev/null 2>&1; then
        zerofree "$root_part" || true
    fi
    unmount_image
    ok "Image finalized & cleanly unmounted: $OUT_IMG"
}

stage_compress() {
    unmount_image
    [[ -f "$OUT_IMG" ]] || err "Missing $OUT_IMG"
    log "Compressing $OUT_IMG -> ${OUT_IMG}.xz using multi-threaded xz"
    xz -f -k -T 0 -6 "$OUT_IMG"
    (
        cd "$OUT_DIR"
        sha256sum "$IMG_NAME" "${IMG_NAME}.xz" > "${IMG_NAME}.sha256"
        awk '/\.xz$/{print}' "${IMG_NAME}.sha256" > "${IMG_NAME}.xz.sha256"
    )
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -R "${SUDO_UID}:${SUDO_GID}" "$OUT_DIR" 2>/dev/null || true
    fi
    ok "Compressed image & SHA256 sums ready in $OUT_DIR:"
    ls -lh "$OUT_IMG" "${OUT_IMG}.xz" "${IMG_NAME}.sha256" "${IMG_NAME}.xz.sha256" 2>/dev/null >&2 || ls -lh "$OUT_DIR" >&2
}

# ─── Stage Flash & SSH Key Deploy ────────────────────────────────────────────
stage_flash() {
    local dev="${FLASH_DEV:-}"
    [[ -n "$dev" && -b "$dev" ]] || err "Usage: sudo FLASH_DEV=/dev/sdX $0 flash"
    [[ -f "$OUT_IMG" ]] || err "Image not built yet: $OUT_IMG"
    [[ "$(lsblk -dno TYPE "$dev")" == "disk" ]] || err "$dev is not a whole disk"
    local rootdisk
    rootdisk="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)"
    [[ "/dev/$rootdisk" != "$dev" ]] || err "Refusing to overwrite host root disk $dev"
    if lsblk -nro MOUNTPOINTS "$dev" | grep -q .; then
        err "$dev has mounted partitions — unmount them first"
    fi
    unmount_image
    log "Flashing $OUT_IMG -> $dev"
    dd if="$OUT_IMG" of="$dev" bs=4M status=progress conv=fsync
    sync
    partprobe "$dev" 2>/dev/null || true
    ok "Successfully flashed $dev"
}

stage_deploy_ssh() {
    local dev="${DEPLOY_SSH_DEV:-}"
    local pub="${DEPLOY_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
    [[ -n "$dev" && -b "$dev" ]] || err "Usage: sudo DEPLOY_SSH_DEV=/dev/sdX [DEPLOY_SSH_PUBKEY=...] $0 deploy-ssh"
    [[ -f "$pub" ]] || err "SSH public key not found: $pub"
    local p2="${dev}2"
    [[ -b "$p2" ]] || p2="${dev}p2"
    local mnt
    mnt="$(mktemp -d)"
    mount "$p2" "$mnt"
    install -d -m 700 -o 1000 -g 1000 "$mnt/home/kali/.ssh"
    install -m 600 -o 1000 -g 1000 "$pub" "$mnt/home/kali/.ssh/authorized_keys"
    sync
    umount "$mnt"
    rmdir "$mnt"
    ok "Deployed SSH public key ($pub) to kali user on $dev"
}

# ─── CLI Dispatch ────────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help|help)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

require_root "$@"

STAGES=("$@")
[[ ${#STAGES[@]} -gt 0 ]] || STAGES=(all)

for s in "${STAGES[@]}"; do
    case "$s" in
        check)       stage_check ;;
        fetch)       stage_check; FORCE_FETCH=1 stage_fetch ;;
        rootfs)      stage_check; stage_fetch; stage_rootfs ;;
        image)       stage_check; stage_fetch; stage_rootfs; stage_image ;;
        mount)       stage_check; stage_mount ;;
        kernel)      stage_check; stage_fetch; stage_mount; stage_kernel ;;
        drivers)     stage_check; stage_fetch; stage_mount; stage_drivers ;;
        packages)    stage_check; stage_fetch; stage_mount; stage_packages ;;
        apps)        stage_check; stage_fetch; stage_mount; stage_apps ;;
        launcher)    stage_check; stage_mount; stage_launcher ;;
        boot)        stage_check; stage_fetch; stage_mount; stage_boot ;;
        configs)     stage_check; stage_fetch; stage_mount; stage_configs ;;
        tweaks)      stage_check; stage_mount; stage_tweaks ;;
        verify)      stage_check; stage_mount; stage_verify ;;
        finalize)    stage_check; stage_mount; stage_finalize ;;
        compress)    stage_compress ;;
        flash)       stage_flash ;;
        deploy-ssh)  stage_deploy_ssh ;;
        all)
            stage_check
            stage_fetch
            stage_rootfs
            stage_image
            stage_mount
            stage_kernel
            stage_drivers
            stage_packages
            stage_apps
            stage_launcher
            stage_boot
            stage_configs
            stage_tweaks
            stage_verify
            stage_finalize
            stage_compress
            ;;
        *)
            err "Unknown stage '$s' (run $0 --help)"
            ;;
    esac
done
