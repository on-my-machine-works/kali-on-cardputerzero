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

LIBCAM07_DEB="libcamera0.7_0.7.2+rpt20261009-1_arm64.deb"
LIBCAM07_SHA="371424b861f0a6611babab81561c66e7c8cb8160798fe31a2f011826673ff549"
LIBCAM_IPA07_DEB="libcamera-ipa_0.7.2+rpt20261009-1_arm64.deb"
LIBCAM_IPA07_SHA="0ee197e03669f755dc437d5a1784b10eb12369fad299f5ef87dbc1bbc43a386f"
RPI_LIBCAM_POOL="https://archive.raspberrypi.com/debian/pool/main/libc/libcamera"

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

# Ensure SHA256-verified RPi libcamera 0.7.2 runtime packages are cached locally for live camera repair
mkdir -p "$CAM_CACHE_DIR"
for pair in "$LIBCAM07_DEB:$LIBCAM07_SHA" "$LIBCAM_IPA07_DEB:$LIBCAM_IPA07_SHA"; do
    deb="${pair%%:*}"
    want_sha="${pair##*:}"
    if [[ ! -f "$CAM_CACHE_DIR/$deb" ]] || [[ "$(sha256sum "$CAM_CACHE_DIR/$deb" | awk '{print $1}')" != "$want_sha" ]]; then
        curl -fsSL --retry 3 -o "$CAM_CACHE_DIR/$deb" "$RPI_LIBCAM_POOL/$deb"
    fi
    actual_sha="$(sha256sum "$CAM_CACHE_DIR/$deb" | awk '{print $1}')"
    if [[ "$actual_sha" != "$want_sha" ]]; then
        echo "ERROR: SHA256 mismatch for $CAM_CACHE_DIR/$deb ($actual_sha != $want_sha)" >&2
        rm -f "$CAM_CACHE_DIR/$deb"
        exit 1
    fi
done

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
cp -a "$REPO_ROOT/overlays/etc/umtprd/umtprd.conf" "$TMP_BUNDLE/etc/umtprd/umtprd.conf"

for s in cz-kali-menu cz-kali-pkgs cz-usb-gadget cz-flipper-gadget cz-badusb cz-ui-mode cz-hw-status cz-hdmi-hotplug; do
    cp -a "$REPO_ROOT/scripts/$s" "$TMP_BUNDLE/usr/local/bin/$s"
done

cp -a "$REPO_ROOT/overlays/systemd/czctl.service" "$TMP_BUNDLE/etc/systemd/system/czctl.service"
cp -a "$REPO_ROOT/overlays/systemd/72-seat-cardputer-czctl.rules" "$TMP_BUNDLE/etc/udev/rules.d/72-seat-cardputer-czctl.rules"
cp -a "$REPO_ROOT/overlays/initramfs/hook-flipper-boot-menu" "$TMP_BUNDLE/etc/initramfs-tools/hooks/flipper-boot-menu"
cp -a "$REPO_ROOT/overlays/initramfs/local-top-flipper-boot-menu" "$TMP_BUNDLE/etc/initramfs-tools/scripts/local-top/flipper-boot-menu"

cp -a "$REPO_ROOT/overlays/btrfs-tools/scripts/"* "$TMP_BUNDLE/usr/local/sbin/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/libs/"* "$TMP_BUNDLE/usr/lib/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/hooks/"* "$TMP_BUNDLE/etc/kernel/install.d/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/systemd/"* "$TMP_BUNDLE/usr/lib/systemd/system/"
cp -a "$REPO_ROOT/overlays/btrfs-tools/apt/80-flipper-apt-backup" "$TMP_BUNDLE/etc/apt/apt.conf.d/80-flipper-apt-backup"

cp -a "$CAM_CACHE_DIR/$LIBCAM07_DEB" "$CAM_CACHE_DIR/$LIBCAM_IPA07_DEB" "$TMP_BUNDLE/camera-debs/"
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
install -d -m 755 /usr/share/czctl/assets /usr/share/czctl/apps /usr/share/czctl/payloads /etc/umtprd
cp -a usr/share/czctl/assets/remote /usr/share/czctl/assets/remote
install -m 755 usr/share/czctl/apps/* /usr/share/czctl/apps/
install -m 644 usr/share/czctl/payloads/* /usr/share/czctl/payloads/
ln -sfn czctl /usr/share/flipctl
install -m 644 etc/umtprd/umtprd.conf /etc/umtprd/umtprd.conf

rm -f /etc/systemd/system/flipctl.service \
      /etc/systemd/system/multi-user.target.wants/flipctl.service \
      /etc/systemd/system/graphical.target.wants/flipctl.service \
      /etc/udev/rules.d/72-seat-cardputer-flipctl.rules
install -m 644 etc/systemd/system/czctl.service /etc/systemd/system/czctl.service
ln -sfn /etc/systemd/system/czctl.service /etc/systemd/system/flipctl.service
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
ACTION=="add|bind|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="05e3", ATTR{idProduct}=="0610", ATTR{power/autosuspend_delay_ms}="0", ATTR{power/control}="auto"
ACTION=="add|bind|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="0fe6", ATTR{idProduct}=="9900", ATTR{power/autosuspend_delay_ms}="500", ATTR{power/control}="auto"
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

# 7. Repair /opt/rpi-libcamera 0.7.2 SONAME alignment & /usr/bin/camera_app wrapper
if [[ -x /usr/lib/cz-kali/camera_app.real && -d /opt/rpi-libcamera && -d camera-debs ]]; then
    rm -f /opt/rpi-libcamera/usr/lib/aarch64-linux-gnu/libcamera*.so.0.8*
    for d in camera-debs/*.deb; do
        [[ -f "\$d" ]] && dpkg-deb -x "\$d" /opt/rpi-libcamera
    done
    rm -rf /opt/rpi-libcamera/usr/share/doc /opt/rpi-libcamera/usr/share/lintian
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
install -d -m 755 /etc/systemd/journald.conf.d /etc/NetworkManager/conf.d
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

# Boot config.txt DVFS & ACT LED tuning (effective on reboot; ACT trigger also applied live)
if [[ -f /boot/firmware/config.txt && -w /boot/firmware/config.txt ]]; then
    sed -i '/^arm_boost=1$/d' /boot/firmware/config.txt
    if ! grep -qxF 'dtparam=act_led_trigger=mmc0' /boot/firmware/config.txt; then
        sed -i '/^dtparam=audio=off$/a dtparam=act_led_trigger=mmc0' /boot/firmware/config.txt
    fi
    sed -i 's/^enable_uart=1$/enable_uart=0/' /boot/firmware/config.txt
    sed -i '/^arm_freq_min=/d' /boot/firmware/config.txt
    for kv in "enable_tvout=0" "initial_turbo=15" "arm_freq=1000" "core_freq_min=150" \
              "gpu_freq_min=150" "sdram_freq_min=250" "over_voltage_min=-2"; do
        k="\${kv%%=*}"
        if grep -qE "^\${k}=" /boot/firmware/config.txt; then
            sed -i "s|^\${k}=.*|\${kv}|" /boot/firmware/config.txt
        else
            sed -i "/^disable_overscan=1$/a \${kv}" /boot/firmware/config.txt
        fi
    done
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
