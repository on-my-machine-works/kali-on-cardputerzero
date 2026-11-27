#!/usr/bin/env bash
# deploy-live.sh — Unified live SSH deployer for Kali Cyberdeck Edition on M5Stack CardputerZero
#
# Builds & deploys in one idempotent SSH session:
#   1. Cortex-A53 ARM64 `czctl` shell (with `flipctl` symlink), `cz-boot-menu`,
#      `kali-usb-deck`, in-tree Wayland apps (`Voice Recorder`, `Internet Radio`,
#      `Disk Benchmark`, `BT/USB HID Pad`, `System Monitor`), and `cz-term` (`cz-flipper-term`)
#   2. 12 Wayland `.fap.sh` bundles, `:8899` Web KVM assets, `.duck` & `.ir` payloads, `umtprd.conf`
#   3. Native `320x170` C framebuffer utilities (`cz-wifiscan`, `cz-sysmon`, `cz-term80`,
#      `cz-lanscan`, `cz-pktsniff`, `cz-usbgadget`, `libcz_fb_lcd.so`), splash & `APPLaunch` patches
#   4. Composite USB-C OTG Arsenal (`cz-usb-gadget`, `cz-flipper-gadget`, `cz-badusb`) & `cz-ui-mode`
#   5. IMX219 camera `/opt/rpi-libcamera` `0.7.2` SONAME alignment & `/usr/bin/camera_app` fix
#
# Usage:
#   ./scripts/deploy-live.sh kali@<cardputer-ip> [--rebuild] [--skip-apt] [--keep-applaunch]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREBUILT_DIR="${PREBUILT_SHELL_DIR:-$REPO_ROOT/work/prebuilt-shell}"
CAM_CACHE_DIR="$REPO_ROOT/cache/camera"

TARGET=""
REBUILD=0
SKIP_APT=0
UI_MODE="czctl"

for arg in "$@"; do
    case "$arg" in
        --rebuild)        REBUILD=1 ;;
        --skip-apt)       SKIP_APT=1 ;;
        --keep-applaunch) UI_MODE="applaunch" ;;
        -h|--help)
            echo "Usage: $0 kali@<cardputer-ip> [--rebuild] [--skip-apt] [--keep-applaunch]"
            exit 0
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$arg"
            else
                echo "Unknown argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 kali@<cardputer-ip> [--rebuild] [--skip-apt] [--keep-applaunch]" >&2
    exit 1
fi

need_build="$REBUILD"
for sb in czctl kali-usb-deck flipctl-sysmon cz-term \
          flipctl-recorder flipctl-radio flipctl-disk-bench flipctl-bt-hid; do
    [[ -x "$PREBUILT_DIR/bin/$sb" ]] || need_build=1
done
if [[ "$need_build" -eq 1 ]]; then
    PREBUILT_SHELL_DIR="$PREBUILT_DIR" "$REPO_ROOT/scripts/build-cz-shell.sh"
fi

# Ensure SHA256-verified M5 CameraApp 1.0.4+ & full transitive RPi libcamera runtime debs are cached locally
python3 "$REPO_ROOT/scripts/resolve-upstream.py" resolve-camera \
    --lock-file "$REPO_ROOT/upstream.lock.json" \
    --cache-dir "$REPO_ROOT/cache"
CAMERA_APP_DEB="$(ls "$REPO_ROOT/cache/apps/active/"*[Cc]amera*_arm64.deb "$REPO_ROOT/cache/apps/locked/"*[Cc]amera*_arm64.deb 2>/dev/null | head -n1)"
[[ -n "$CAMERA_APP_DEB" && -f "$CAMERA_APP_DEB" ]] || { echo "ERROR: Camera app .deb missing in cache/apps" >&2; exit 1; }

TMP_BUNDLE="$(mktemp -d)"
trap 'rm -rf "$TMP_BUNDLE"' EXIT

mkdir -p "$TMP_BUNDLE/c-src" \
         "$TMP_BUNDLE/usr/bin" \
         "$TMP_BUNDLE/usr/local/bin" \
         "$TMP_BUNDLE/usr/local/sbin" \
         "$TMP_BUNDLE/usr/lib" \
         "$TMP_BUNDLE/usr/share/czctl/assets" \
         "$TMP_BUNDLE/usr/share/czctl/apps" \
         "$TMP_BUNDLE/usr/share/czctl/payloads" \
         "$TMP_BUNDLE/etc/umtprd" \
         "$TMP_BUNDLE/etc/apt/apt.conf.d" \
         "$TMP_BUNDLE/etc/kernel/install.d" \
         "$TMP_BUNDLE/etc/initramfs-tools/hooks" \
         "$TMP_BUNDLE/etc/initramfs-tools/scripts/local-top" \
         "$TMP_BUNDLE/etc/systemd/system" \
         "$TMP_BUNDLE/usr/lib/systemd/system" \
         "$TMP_BUNDLE/etc/udev/rules.d" \
         "$TMP_BUNDLE/camera-debs"

cp "$REPO_ROOT/src/Makefile" \
   "$REPO_ROOT/src/libcz_fb_lcd.c" \
   "$REPO_ROOT/src/cz_ui.h" \
   "$REPO_ROOT/src/flipper_term_fonts.h" \
   "$REPO_ROOT/src/cz-sysmon.c" \
   "$REPO_ROOT/src/cz-term.c" \
   "$REPO_ROOT/src/cz-term80.c" \
   "$REPO_ROOT/src/cz-wifiscan.c" \
   "$REPO_ROOT/src/cz-lanscan.c" \
   "$REPO_ROOT/src/cz-pktsniff.c" \
   "$REPO_ROOT/src/cz-usbgadget.c" \
   "$TMP_BUNDLE/c-src/"

cp "$REPO_ROOT/scripts/gen-kali-splash.py" \
   "$REPO_ROOT/scripts/configure-kali-launcher.py" \
   "$TMP_BUNDLE/"

cp -a "$PREBUILT_DIR/bin/"* "$TMP_BUNDLE/usr/bin/"
cp -a "$PREBUILT_DIR/share/czctl/assets/remote" "$TMP_BUNDLE/usr/share/czctl/assets/remote"
cp -a "$REPO_ROOT/overlays/apps/"*.fap.sh "$TMP_BUNDLE/usr/share/czctl/apps/"
cp -a "$REPO_ROOT/overlays/payloads/"* "$TMP_BUNDLE/usr/share/czctl/payloads/"
cp -a "$REPO_ROOT/overlays/ota/ota-pub.pem" "$TMP_BUNDLE/usr/share/czctl/ota-pub.pem"
mkdir -p "$TMP_BUNDLE/usr/share/czctl/ota-tools" "$TMP_BUNDLE/etc"
cp -a "$REPO_ROOT/scripts/configure-kali-launcher.py" "$TMP_BUNDLE/usr/share/czctl/ota-tools/"
cp -a "$REPO_ROOT/scripts/gen-kali-splash.py" "$TMP_BUNDLE/usr/share/czctl/ota-tools/"
cp -a "$REPO_ROOT/overlays/etc/umtprd/umtprd.conf" "$TMP_BUNDLE/etc/umtprd/umtprd.conf"

DEPLOY_GIT_REV="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
DEPLOY_BUILD_NUM="${CZ_BUILD_NUM:-$(date -u +%s)}"
DEPLOY_VERSION="${CZ_VERSION:-v$(date -u +%Y.%m.%d)}"
DEPLOY_KABI="$(python3 -c 'import json; print(json.load(open("'"$REPO_ROOT/upstream.lock.json"'"))["kernel"]["kver"])' 2>/dev/null || echo 6.18.39+rpt-rpi-v8)"
cat > "$TMP_BUNDLE/etc/cz-release" <<CZREL
CZ_VERSION="${DEPLOY_VERSION}"
CZ_BUILD_NUM="${DEPLOY_BUILD_NUM}"
CZ_COMMIT="${DEPLOY_GIT_REV}"
CZ_CHANNEL="release"
CZ_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CZ_IMAGE_EPOCH="1"
CZ_KERNEL_ABI="${DEPLOY_KABI}"
CZREL

for s in cz-kali-menu cz-kali-pkgs cz-usb-gadget cz-flipper-gadget cz-badusb cz-ui-mode cz-hw-status cz-hdmi-hotplug cz-stealth cz-ota cz-cap-uart; do
    cp -a "$REPO_ROOT/scripts/$s" "$TMP_BUNDLE/usr/local/bin/$s"
done

cp -a "$REPO_ROOT/overlays/systemd/czctl.service" "$TMP_BUNDLE/etc/systemd/system/czctl.service"
cp -a "$REPO_ROOT/overlays/systemd/cz-stealth.service" "$TMP_BUNDLE/etc/systemd/system/cz-stealth.service"
cp -a "$REPO_ROOT/overlays/systemd/cz-ui-ensure.service" "$TMP_BUNDLE/etc/systemd/system/cz-ui-ensure.service"
cp -a "$REPO_ROOT/overlays/systemd/72-seat-cardputer-czctl.rules" "$TMP_BUNDLE/etc/udev/rules.d/72-seat-cardputer-czctl.rules"
cp -a "$REPO_ROOT/overlays/initramfs/hook-flipper-boot-menu" "$TMP_BUNDLE/etc/initramfs-tools/hooks/flipper-boot-menu"
cp -a "$REPO_ROOT/overlays/initramfs/local-top-flipper-boot-menu" "$TMP_BUNDLE/etc/initramfs-tools/scripts/local-top/flipper-boot-menu"

cp -a "$REPO_ROOT/overlays/btrfs-tools/scripts/"* "$TMP_BUNDLE/usr/local/sbin/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/libs/"* "$TMP_BUNDLE/usr/lib/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/hooks/"* "$TMP_BUNDLE/etc/kernel/install.d/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/systemd/"* "$TMP_BUNDLE/usr/lib/systemd/system/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/apt/80-flipper-apt-backup" "$TMP_BUNDLE/etc/apt/apt.conf.d/80-flipper-apt-backup"

mkdir -p "$TMP_BUNDLE/camera-debs/runtime"
cp -a "$CAM_CACHE_DIR/"*.deb "$TMP_BUNDLE/camera-debs/runtime/"
cp -a "$CAMERA_APP_DEB" "$TMP_BUNDLE/camera-debs/camera-app.deb"

SHIM_UNPACK="$TMP_BUNDLE/cam-rt-probe"
mkdir -p "$SHIM_UNPACK"
for rdeb in "$CAM_CACHE_DIR/libcamera0."*.deb; do
    [[ -f "$rdeb" ]] && dpkg-deb -x "$rdeb" "$SHIM_UNPACK"
done
SONAME_VER="$(basename "$(ls "$SHIM_UNPACK/usr/lib/aarch64-linux-gnu/libcamera.so."0.*.* 2>/dev/null | sort -V | tail -n1)" 2>/dev/null | sed 's/^libcamera\.so\.//')"
SONAME_VER="${SONAME_VER:-0.8.0}"
ABI_XY="$(printf '%s' "$SONAME_VER" | cut -d. -f1-2)"
rm -rf "$SHIM_UNPACK"

SHIM_STAGE="$TMP_BUNDLE/cz-rpi-libcamera-shim"
mkdir -p "$SHIM_STAGE/DEBIAN" "$SHIM_STAGE/usr/share/doc/cz-rpi-libcamera"
cat > "$SHIM_STAGE/DEBIAN/control" <<SHIMEOF
Package: cz-rpi-libcamera
Version: ${SONAME_VER}-2
Section: libs
Priority: optional
Architecture: arm64
Maintainer: Kali Cyberdeck Edition <noreply@kali.org>
Depends: libc6, libdw1t64, libgcc-s1, libgnutls30t64, liblttng-ust1t64, libstdc++6, libudev1, libyaml-0-2
Provides: libcamera${ABI_XY} (= ${SONAME_VER}), libcamera0.8 (= 0.8.0), libcamera0.7 (= 0.7.2), libcamera-ipa (= ${SONAME_VER})
Description: Isolated Raspberry Pi libcamera runtime virtual provider
 Satisfies M5 CameraApp libcamera0.x dpkg dependencies via /opt/rpi-libcamera
 without conflicting with Kali Rolling system Boost, Abseil, or libcamera packages.
SHIMEOF
printf 'Isolated Raspberry Pi libcamera runtime (/opt/rpi-libcamera).\n' > "$SHIM_STAGE/usr/share/doc/cz-rpi-libcamera/README"
dpkg-deb --root-owner-group -Zxz --build "$SHIM_STAGE" "$TMP_BUNDLE/camera-debs/cz-rpi-libcamera.deb" >/dev/null
rm -rf "$SHIM_STAGE"

cat > "$TMP_BUNDLE/camera-debs/camera_app.wrapper" <<'CAMWRAP'
#!/bin/sh
R=/opt/rpi-libcamera
L=$R/usr/lib/aarch64-linux-gnu
export LD_LIBRARY_PATH="$L${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBCAMERA_IPA_MODULE_PATH="$L/libcamera/ipa"
export LIBCAMERA_IPA_PROXY_PATH="$R/usr/libexec/aarch64-linux-gnu/libcamera"
export LIBCAMERA_IPA_CONFIG_PATH="$R/usr/share/libcamera/ipa"
export LIBCAMERA_RPI_CONFIG_FILE="${LIBCAMERA_RPI_CONFIG_FILE:-$R/usr/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml}"
export CAMERA_APP_FB_DEVICE="${CAMERA_APP_FB_DEVICE:-/dev/fb_lcd}"
export LV_LINUX_FBDEV_DEVICE="${LV_LINUX_FBDEV_DEVICE:-/dev/fb_lcd}"
export CAMERA_APP_KEYBOARD_GRAB="${CAMERA_APP_KEYBOARD_GRAB:-0}"
exec /usr/lib/cz-kali/camera_app.real "$@"
CAMWRAP

cat > "$TMP_BUNDLE/_deploy_remote.sh" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
rm -rf /tmp/cz-live-sync
cd /var/tmp/cz-live-sync

# 1. Remove excluded default demo packages if present & divert ZClaw / APPLaunch
dpkg --purge m5cardputerzero-music m5cardputerzero-piano m5cardputerzero-keyboard-guide 2>/dev/null || true
rm -f /usr/share/APPLaunch/applications/{music,piano,keyboard-guide}.desktop

mkdir -p /usr/lib/cz-kali /usr/local/bin /usr/local/sbin
for zf in /usr/share/APPLaunch/applications/zclaw.desktop \
          /usr/share/APPLaunch/bin/ZClaw \
          /usr/share/APPLaunch/preinstalled-desktop-apps.tsv; do
    base="\$(basename "\$zf")"
    if ! dpkg-divert --list "\$zf" | grep -q "\$zf"; then
        dpkg-divert --local --rename --divert "/usr/lib/cz-kali/\${base}.disabled" --add "\$zf" || true
    fi
done
rm -f /usr/share/APPLaunch/applications/zclaw.desktop /usr/share/APPLaunch/bin/ZClaw

if [[ -e /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch ]] && ! dpkg-divert --list /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch | grep -q M5CardputerZero-APPLaunch; then
    dpkg-divert --local --rename \
        --divert /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 \
        --add /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
    install -m 755 /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
fi

# 2. Optionally install missing runtime packages via APT if reachable
if [[ "$SKIP_APT" -eq 0 ]]; then
    missing_pkgs=()
    command -v sway >/dev/null 2>&1 || missing_pkgs+=(sway)
    command -v umtprd >/dev/null 2>&1 || missing_pkgs+=(umtp-responder)
    command -v mkfs.vfat >/dev/null 2>&1 || missing_pkgs+=(dosfstools)
    command -v fusermount3 >/dev/null 2>&1 || missing_pkgs+=(fuse3)
    if [[ "\$(findmnt -no FSTYPE / 2>/dev/null || true)" == "btrfs" ]]; then
        command -v btrfs >/dev/null 2>&1 || missing_pkgs+=(btrfs-progs)
    fi
    for pkg in python3-requests python3-scapy kali-tweaks; do
        dpkg -s "\$pkg" >/dev/null 2>&1 || missing_pkgs+=("\$pkg")
    done
    if [[ \${#missing_pkgs[@]} -gt 0 ]]; then
        echo "[*] Installing missing packages (\${missing_pkgs[*]}) via APT ..."
        if DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                "\${missing_pkgs[@]}" || echo "[!] Warning: optional APT install failed; continuing."
            apt-get clean
        else
            echo "[!] Warning: APT offline; skipping optional package install (\${missing_pkgs[*]})."
        fi
    fi
fi

# 3. Stop active LCD UI services (and any stray standalone process) before updating binaries
systemctl stop czctl.service flipctl.service 2>/dev/null || true
pkill -x czctl 2>/dev/null || true
pkill -x flipctl 2>/dev/null || true

# 4. Build & install C framebuffer utilities + libcz_fb_lcd.so + helper scripts + Cortex-A53 binaries
TARGET_FSTYPE="\$(findmnt -no FSTYPE / 2>/dev/null || echo ext4)"
make -C c-src install
for f in usr/bin/*; do
    base="\$(basename "\$f")"
    if [[ "\$TARGET_FSTYPE" != "btrfs" && ( "\$base" == "cz-boot-menu" || "\$base" == "flipper-boot-menu" ) ]]; then
        continue
    fi
    if [[ -L "\$f" ]]; then
        cp -d --remove-destination "\$f" "/usr/bin/\$base"
    else
        install -m 755 "\$f" "/usr/bin/\$base"
    fi
done
ln -sfn czctl /usr/bin/flipctl
ln -sfn cz-term /usr/bin/cz-flipper-term

install -m 755 usr/local/bin/* /usr/local/bin/
if [[ "\$TARGET_FSTYPE" == "btrfs" ]]; then
    [[ -x /usr/bin/cz-boot-menu ]] && ln -sfn cz-boot-menu /usr/bin/flipper-boot-menu
    install -m 755 usr/local/sbin/* /usr/local/sbin/
    for lf in usr/lib/*; do
        [[ -f "\$lf" ]] && install -m 644 "\$lf" "/usr/lib/\$(basename "\$lf")"
    done
    install -d -m 755 /etc/kernel/install.d /etc/apt/apt.conf.d /usr/lib/systemd/system \
                      /etc/initramfs-tools/hooks /etc/initramfs-tools/scripts/local-top
    install -m 755 etc/kernel/install.d/* /etc/kernel/install.d/
    install -m 644 etc/apt/apt.conf.d/80-flipper-apt-backup /etc/apt/apt.conf.d/80-flipper-apt-backup
    install -m 644 usr/lib/systemd/system/* /usr/lib/systemd/system/
    install -m 755 etc/initramfs-tools/hooks/flipper-boot-menu /etc/initramfs-tools/hooks/flipper-boot-menu
    install -m 755 etc/initramfs-tools/scripts/local-top/flipper-boot-menu /etc/initramfs-tools/scripts/local-top/flipper-boot-menu
else
    # Keep ext4 systems clean of Btrfs boot-menu binaries, profile scripts & apt snapshot hooks
    rm -f /usr/bin/cz-boot-menu /usr/bin/flipper-boot-menu \
          /usr/local/sbin/add-dtbo /usr/local/sbin/apt-backup-profile /usr/local/sbin/boot-profile \
          /usr/local/sbin/btrfs-maintenance /usr/local/sbin/btrfs-show-space /usr/local/sbin/check-profile \
          /usr/local/sbin/create-profile /usr/local/sbin/create-snapshot /usr/local/sbin/create-swap \
          /usr/local/sbin/delete-profile /usr/local/sbin/delete-snapshot /usr/local/sbin/flipmeta \
          /usr/local/sbin/flipper-bless-boot /usr/local/sbin/list-profiles /usr/local/sbin/list-snapshots \
          /usr/local/sbin/migrate-profile /usr/local/sbin/receive-snapshot /usr/local/sbin/rename-profile \
          /usr/local/sbin/send-snapshot /usr/local/sbin/set-boot-order /usr/local/sbin/update-profile \
          /usr/lib/flipper-accountdb.awk /usr/lib/flipper-bls.sh /usr/lib/flipper-blsname.sh \
          /usr/lib/flipper-btrfs.sh /usr/lib/flipper-rootinfo.sh \
          /etc/kernel/install.d/55-flipper-initrd.install \
          /etc/kernel/install.d/90-loaderentry.install \
          /etc/kernel/install.d/99-flipper-clean-staging.install \
          /usr/lib/systemd/system/flipper-bless-boot.service \
          /etc/apt/apt.conf.d/80-flipper-apt-backup \
          /etc/initramfs-tools/hooks/flipper-boot-menu \
          /etc/initramfs-tools/scripts/local-top/flipper-boot-menu
fi

# 5. Install /usr/share/czctl (+ /usr/share/flipctl symlink), umtprd.conf, systemd & udev rules
rm -rf /usr/share/flipctl /usr/share/czctl/assets/remote
install -d -m 755 /usr/share/czctl/assets /usr/share/czctl/apps /usr/share/czctl/payloads /usr/share/czctl/ota-tools /etc/umtprd
cp -a usr/share/czctl/assets/remote /usr/share/czctl/assets/remote
install -m 755 usr/share/czctl/apps/* /usr/share/czctl/apps/
install -m 644 usr/share/czctl/payloads/* /usr/share/czctl/payloads/
install -m 644 usr/share/czctl/ota-pub.pem /usr/share/czctl/ota-pub.pem
install -m 755 usr/share/czctl/ota-tools/* /usr/share/czctl/ota-tools/
ln -sfn czctl /usr/share/flipctl
install -m 644 etc/umtprd/umtprd.conf /etc/umtprd/umtprd.conf
install -m 644 etc/cz-release /etc/cz-release

rm -f /etc/systemd/system/flipctl.service \
      /etc/systemd/system/multi-user.target.wants/flipctl.service \
      /etc/systemd/system/graphical.target.wants/flipctl.service \
      /etc/udev/rules.d/72-seat-cardputer-flipctl.rules
install -m 644 etc/systemd/system/czctl.service /etc/systemd/system/czctl.service
install -m 644 etc/systemd/system/cz-stealth.service /etc/systemd/system/cz-stealth.service
install -m 644 etc/systemd/system/cz-ui-ensure.service /etc/systemd/system/cz-ui-ensure.service
ln -sfn /etc/systemd/system/czctl.service /etc/systemd/system/flipctl.service
install -d -m 755 /etc/systemd/system/multi-user.target.wants
ln -sfn /etc/systemd/system/cz-stealth.service /etc/systemd/system/multi-user.target.wants/cz-stealth.service
ln -sfn /etc/systemd/system/cz-ui-ensure.service /etc/systemd/system/multi-user.target.wants/cz-ui-ensure.service
install -m 644 etc/udev/rules.d/72-seat-cardputer-czctl.rules /etc/udev/rules.d/72-seat-cardputer-czctl.rules

cat > /etc/udev/rules.d/70-cardputerzero-peripherals.rules <<'EOF'
# Allow kali user (video/i2c/plugdev/netdev/input) to use IR TX/RX, hardware RTC, USB HID gadgets, rfkill, and uinput
SUBSYSTEM=="lirc", GROUP="video", MODE="0660"
SUBSYSTEM=="rtc", GROUP="i2c", MODE="0664"
ACTION=="add", SUBSYSTEM=="rtc", KERNEL=="rtc0", RUN+="/sbin/hwclock --hctosys --utc --noadjfile"
KERNEL=="hidg[0-9]*", GROUP="plugdev", MODE="0660"
KERNEL=="rfkill", SUBSYSTEM=="misc", GROUP="netdev", MODE="0664"
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660"

# Set conservative 60% initial LCD backlight on boot & tuned ondemand DVFS governor (600 MHz idle / 1000 MHz turbo)
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="backlight", ATTR{brightness}="60"
ACTION=="add", SUBSYSTEM=="cpu", TEST=="cpufreq/scaling_governor", ATTR{cpufreq/scaling_governor}="ondemand", RUN+="/bin/sh -c '[ -w /sys/devices/system/cpu/cpufreq/ondemand/up_threshold ] && echo 85 > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold || true'"

# Enable USB runtime autosuspend on internal USB 2.0 Hub (05e3:0610) & 10/100 LAN (0fe6:9900)
# Note: r8152 calls usb_disable_autosuspend() inside rtl8152_probe() when binding 1-1.1:1.0,
# so we also re-enable autosuspend on the parent usb_device upon DRIVER=="r8152" bind.
# Drops unplugged dwc2 High-Speed SOF interrupts from 8,004/sec to 0/sec (~350 mW battery savings)
# while preserving USB Remote Wakeup (bmAttributes=0xa0) on RJ45 link-up.
ACTION=="add|bind|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="05e3", ATTR{idProduct}=="0610", ATTR{power/autosuspend_delay_ms}="0", ATTR{power/control}="auto"
ACTION=="add|bind|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0fe6", ATTR{idProduct}=="9900", ATTR{power/autosuspend_delay_ms}="500", ATTR{power/control}="auto"
ACTION=="add|bind", SUBSYSTEM=="usb", DRIVER=="r8152", ATTRS{idVendor}=="0fe6", ATTRS{idProduct}=="9900", RUN+="/bin/sh -c 'echo 500 > /sys\$devpath/../power/autosuspend_delay_ms; echo auto > /sys\$devpath/../power/control'"
EOF

modprobe uinput 2>/dev/null || true
install -d /etc/modules-load.d
if ! grep -qx 'uinput' /etc/modules-load.d/cardputerzero.conf 2>/dev/null; then
    echo "uinput" >> /etc/modules-load.d/cardputerzero.conf
fi

# 6. Seed kali user directories, BadUSB .duck & IR .ir files, launcher layout & splash
if id kali >/dev/null 2>&1; then
    install -d -m 755 -o kali -g kali \
        /home/kali/Apps \
        /home/kali/isos \
        /home/kali/payloads \
        /home/kali/ir \
        /home/kali/captures \
        /home/kali/Recordings
    for p in /usr/share/czctl/payloads/*.duck; do
        [[ -f "\$p" ]] || continue
        dest="/home/kali/payloads/\$(basename "\$p")"
        [[ -e "\$dest" ]] || install -m 644 -o kali -g kali "\$p" "\$dest"
    done
    for p in /usr/share/czctl/payloads/*.ir; do
        [[ -f "\$p" ]] || continue
        dest="/home/kali/ir/\$(basename "\$p")"
        [[ -e "\$dest" ]] || install -m 644 -o kali -g kali "\$p" "\$dest"
    done
    touch /home/kali/.hushlogin && chown kali:kali /home/kali/.hushlogin
fi

cat > /etc/sudoers.d/kali-nopasswd <<'EOF'
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
kali ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/kali-nopasswd

if [[ -d /usr/share/APPLaunch ]]; then
    python3 configure-kali-launcher.py /
    id kali >/dev/null 2>&1 && chown -R kali:kali /home/kali/.config
    install -d /etc/systemd/user /etc/systemd/user/APPLaunch.service.d
    cat > /etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf <<'EOF'
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
    for img in /usr/share/APPLaunch/share/images/logo_lcd.png \
               /usr/share/APPLaunch/share/images/lockscreen.png; do
        base="\$(basename "\$img")"
        if [[ -e "\$img" ]] && ! dpkg-divert --list "\$img" | grep -q "\$img"; then
            dpkg-divert --local --rename --divert "/usr/lib/cz-kali/\${base}.m5" --add "\$img"
        fi
    done
    python3 gen-kali-splash.py \
        --emblem /usr/share/icons/desktop-base/256x256/emblems/emblem-kali.png \
        --bmp /boot/firmware/splash.bmp \
        --logo-png /usr/share/APPLaunch/share/images/logo_lcd.png \
        --lock-png /usr/share/APPLaunch/share/images/lockscreen.png
fi

# 7. Install isolated /opt/rpi-libcamera 0.8 runtime, cz-rpi-libcamera shim, CameraApp 1.0.4+ & wrapper
if [[ -d camera-debs/runtime ]]; then
    rm -rf /opt/rpi-libcamera
    mkdir -p /opt/rpi-libcamera /usr/lib/cz-kali
    for d in camera-debs/runtime/*.deb; do
        [[ -f "\$d" ]] && dpkg-deb -x "\$d" /opt/rpi-libcamera
    done
    rm -rf /opt/rpi-libcamera/usr/share/doc /opt/rpi-libcamera/usr/share/lintian
    if [[ -f camera-debs/cz-rpi-libcamera.deb ]]; then
        DEBIAN_FRONTEND=noninteractive dpkg -i camera-debs/cz-rpi-libcamera.deb >/dev/null
    fi
    if ! dpkg-divert --list /usr/bin/camera_app 2>/dev/null | grep -q '/usr/bin/camera_app'; then
        if [[ -f /usr/bin/camera_app && -f /usr/lib/cz-kali/camera_app.real ]]; then
            rm -f /usr/bin/camera_app
        fi
        dpkg-divert --local --rename --divert /usr/lib/cz-kali/camera_app.real --add /usr/bin/camera_app
    fi
    if [[ -f camera-debs/camera-app.deb ]]; then
        DEBIAN_FRONTEND=noninteractive dpkg -i --force-overwrite camera-debs/camera-app.deb >/dev/null
    fi
    install -m 755 camera-debs/camera_app.wrapper /usr/bin/camera_app
fi

# 8. Idle power, RAM/CPU hygiene & on-demand HDMI hotplug sync
sudo -u kali XDG_RUNTIME_DIR=/run/user/1000 \
    systemctl --user stop filter-chain.service mpris-proxy.service 2>/dev/null || true
ln -sfn /dev/null /etc/systemd/user/filter-chain.service
ln -sfn /dev/null /etc/systemd/user/mpris-proxy.service

# Stop & disable idle background pollers (iio-sensor-proxy IMU poller & unused ModemManager)
systemctl stop iio-sensor-proxy.service ModemManager.service 2>/dev/null || true
systemctl disable ModemManager.service iio-sensor-proxy.service 2>/dev/null || true
ln -sfn /dev/null /etc/systemd/system/iio-sensor-proxy.service
rm -f /etc/systemd/system/multi-user.target.wants/ModemManager.service \
      /etc/systemd/system/dbus-org.freedesktop.ModemManager1.service

# Volatile bounded journald (eliminates background ext4 jbd2 / microSD writes)
install -d -m 755 /etc/systemd/journald.conf.d /etc/NetworkManager/conf.d /etc/sysctl.d
cat > /etc/sysctl.d/50-cz-network.conf <<'EOF'
# Standard Debian/Kali sysctl defaults (unprivileged ping, fq_codel, fs link guards)
-net.ipv4.ping_group_range = 0 2147483647
-net.core.default_qdisc = fq_codel
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.promote_secondaries = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 1
EOF
sysctl --system >/dev/null 2>&1 || sysctl -qw "net.ipv4.ping_group_range=0 2147483647" 2>/dev/null || true
[[ -x /usr/bin/ping ]] && command -v setcap >/dev/null 2>&1 && setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || true
rm -f /etc/systemd/journald.conf.d/persist.conf
cat > /etc/systemd/journald.conf.d/volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF
systemctl restart systemd-journald.service 2>/dev/null || true

# Explicit Wi-Fi 802.11 PSM power-save in NetworkManager + live wlan0 apply
cat > /etc/NetworkManager/conf.d/20-wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave = 3
EOF
iw dev wlan0 set power_save on 2>/dev/null || true

# Boot config.txt DVFS & ACT LED tuning (preserves user's cz-cap-uart ON/OFF choice!)
install -d -m 755 /etc/default
if [[ ! -f /etc/default/cz-cap-uart ]]; then
    if [[ -f /boot/firmware/config.txt ]] && grep -qx 'enable_uart=1' /boot/firmware/config.txt 2>/dev/null; then
        printf '# CardputerZero 14-pin Cap UART (/dev/ttyS0 for LoRa/GNSS GPS): on | off\nCAP_UART_MODE=on\n' > /etc/default/cz-cap-uart
    else
        printf '# CardputerZero 14-pin Cap UART (/dev/ttyS0 for LoRa/GNSS GPS): on | off\nCAP_UART_MODE=off\n' > /etc/default/cz-cap-uart
    fi
fi
if [[ -f /boot/firmware/config.txt && -w /boot/firmware/config.txt ]]; then
    sed -i '/^arm_boost=1$/d' /boot/firmware/config.txt
    if ! grep -qxF 'dtparam=act_led_trigger=mmc0' /boot/firmware/config.txt; then
        sed -i '/^dtparam=audio=off$/a dtparam=act_led_trigger=mmc0' /boot/firmware/config.txt
    fi
    sed -i '/^arm_freq_min=/d' /boot/firmware/config.txt
    for kv in "enable_tvout=0" "initial_turbo=15" "arm_freq=1000" \
              "gpu_freq_min=150" "sdram_freq_min=250" "over_voltage_min=-2"; do
        k="\${kv%%=*}"
        if grep -qE "^\${k}=" /boot/firmware/config.txt; then
            sed -i "s|^\${k}=.*|\${kv}|" /boot/firmware/config.txt
        else
            sed -i "/^disable_overscan=1$/a \${kv}" /boot/firmware/config.txt
        fi
    done
    if grep -q '^CAP_UART_MODE=.*on' /etc/default/cz-cap-uart 2>/dev/null; then
        /usr/local/bin/cz-cap-uart on >/dev/null 2>&1 || true
    else
        /usr/local/bin/cz-cap-uart off >/dev/null 2>&1 || true
    fi
fi
[[ -w /sys/class/leds/ACT/trigger ]] && echo mmc0 > /sys/class/leds/ACT/trigger 2>/dev/null || true

install -d -m 755 /etc/default /etc/systemd/system/lightdm.service.d /etc/systemd/system/fb_load.service.d
if [[ ! -f /etc/default/cz-hdmi-desktop ]]; then
    cat > /etc/default/cz-hdmi-desktop <<'EOF'
# CardputerZero HDMI desktop policy: auto | always | off
HDMI_DESKTOP_MODE=auto
HDMI_UNPLUG_DELAY=5
EOF
fi
if [[ ! -f /etc/default/cz-stealth ]]; then
    cat > /etc/default/cz-stealth <<'EOF'
# CardputerZero Hostile-Network Stealth Mode: on | off
STEALTH_MODE=off
EOF
fi
cat > /etc/systemd/system/fb_load.service.d/kali-splash.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/fb_load --keep-open /boot/firmware/splash.bmp /dev/dri/cardputer-zero-internal
EOF

udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=drm --subsystem-match=graphics --subsystem-match=input --subsystem-match=backlight --subsystem-match=misc --subsystem-match=usb 2>/dev/null || true
for udev_dir in /sys/bus/usb/devices/*; do
    [[ -f "\$udev_dir/idVendor" && -f "\$udev_dir/idProduct" ]] || continue
    vid="\$(cat "\$udev_dir/idVendor" 2>/dev/null || true)"
    pid="\$(cat "\$udev_dir/idProduct" 2>/dev/null || true)"
    if [[ "\$vid:\$pid" == "05e3:0610" ]]; then
        echo 0 > "\$udev_dir/power/autosuspend_delay_ms" 2>/dev/null || true
        echo auto > "\$udev_dir/power/control" 2>/dev/null || true
    elif [[ "\$vid:\$pid" == "0fe6:9900" ]]; then
        echo 500 > "\$udev_dir/power/autosuspend_delay_ms" 2>/dev/null || true
        echo auto > "\$udev_dir/power/control" 2>/dev/null || true
    fi
done
systemctl daemon-reload
/usr/local/bin/cz-stealth apply >/dev/null 2>&1 || true
systemctl stop fb_load.service 2>/dev/null || true
/usr/local/bin/cz-hdmi-hotplug sync 2>/dev/null || true

/usr/local/bin/cz-ui-mode "$UI_MODE"
/usr/local/bin/cz-ui-mode status
free -m | awk 'NR==1 || NR==2 {print}'
REMOTE
chmod 755 "$TMP_BUNDLE/_deploy_remote.sh"

echo "[*] Streaming Kali Cyberdeck bundle & deploying over SSH to $TARGET ..."
tar -C "$TMP_BUNDLE" -czf - . | ssh "$TARGET" \
    'set -e; sudo rm -rf /tmp/cz-live-sync /var/tmp/cz-live-sync && mkdir -p /var/tmp/cz-live-sync && tar -xzf - -C /var/tmp/cz-live-sync && sudo /var/tmp/cz-live-sync/_deploy_remote.sh && sudo rm -rf /var/tmp/cz-live-sync'
echo "[+] Live deployment complete!"
