#!/usr/bin/env bash
# deploy-live.sh — Sync native 320x170 Kali LCD apps, helper scripts,
# launcher configuration, and splash assets to a running CardputerZero over SSH.
#
# Usage:
#   ./scripts/deploy-live.sh kali@<cardputer-ip>

set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 kali@<cardputer-ip>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BUNDLE="$(mktemp -d)"
trap 'rm -rf "$TMP_BUNDLE"' EXIT

cp "$SCRIPT_DIR/src/Makefile" \
   "$SCRIPT_DIR/src/libcz_fb_lcd.c" \
   "$SCRIPT_DIR/src/cz_ui.h" \
   "$SCRIPT_DIR/src/cz-sysmon.c" \
   "$SCRIPT_DIR/src/cz-term80.c" \
   "$SCRIPT_DIR/src/cz-wifiscan.c" \
   "$SCRIPT_DIR/src/cz-lanscan.c" \
   "$SCRIPT_DIR/src/cz-pktsniff.c" \
   "$SCRIPT_DIR/src/cz-usbgadget.c" \
   "$SCRIPT_DIR/scripts/cz-kali-menu" \
   "$SCRIPT_DIR/scripts/cz-kali-pkgs" \
   "$SCRIPT_DIR/scripts/cz-usb-gadget" \
   "$SCRIPT_DIR/scripts/cz-hw-status" \
   "$SCRIPT_DIR/scripts/cz-hdmi-hotplug" \
   "$SCRIPT_DIR/scripts/gen-kali-splash.py" \
   "$SCRIPT_DIR/scripts/configure-kali-launcher.py" \
   "$TMP_BUNDLE/"

cat > "$TMP_BUNDLE/_deploy_remote.sh" <<'REMOTE'
set -euo pipefail
cd /tmp/cz-live-sync

# 1. Remove excluded default packages if present
dpkg --purge \
    m5cardputerzero-music m5cardputerzero-piano m5cardputerzero-keyboard-guide 2>/dev/null || true
rm -f /usr/share/APPLaunch/applications/{music,piano,keyboard-guide}.desktop

# 2. Divert ZClaw, preinstalled-desktop-apps.tsv & M5CardputerZero-APPLaunch
mkdir -p /usr/lib/cz-kali /usr/local/bin
for zf in /usr/share/APPLaunch/applications/zclaw.desktop \
          /usr/share/APPLaunch/bin/ZClaw \
          /usr/share/APPLaunch/preinstalled-desktop-apps.tsv; do
    base="$(basename "$zf")"
    if ! dpkg-divert --list "$zf" | grep -q "$zf"; then
        dpkg-divert --local --rename --divert "/usr/lib/cz-kali/${base}.disabled" --add "$zf" || true
    fi
done
rm -f /usr/share/APPLaunch/applications/zclaw.desktop /usr/share/APPLaunch/bin/ZClaw

if ! dpkg-divert --list /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch | grep -q M5CardputerZero-APPLaunch; then
    dpkg-divert --local --rename \
        --divert /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 \
        --add /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
    install -m 755 /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
fi

# 3. Ensure wireless/Python runtime helpers & kali-tweaks are present
missing_pkgs=()
for pkg in python3-requests python3-scapy bully cowpatty bettercap-caplets kali-tweaks; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
done
if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${missing_pkgs[@]}"
    apt-get clean
fi

# 4. Compile native 320x170 RGB565 Kali LCD apps + helper scripts
make install
install -m 755 cz-kali-menu    /usr/local/bin/cz-kali-menu
install -m 755 cz-kali-pkgs    /usr/local/bin/cz-kali-pkgs
install -m 755 cz-usb-gadget   /usr/local/bin/cz-usb-gadget
install -m 755 cz-hw-status    /usr/local/bin/cz-hw-status
install -m 755 cz-hdmi-hotplug /usr/local/bin/cz-hdmi-hotplug
cat > /etc/sudoers.d/kali-nopasswd <<'EOF'
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
kali ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/kali-nopasswd
install -d -m 755 -o kali -g kali /home/kali/captures

# 5. Configure launcher layout, manifest, config.json & APPLaunch ELF64 patches
python3 configure-kali-launcher.py /
chown -R kali:kali /home/kali/.config
touch /home/kali/.hushlogin && chown kali:kali /home/kali/.hushlogin

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

# 6. Idle CPU, RAM & battery optimizations:
#    - Stop & mask unused PipeWire filter-chain and BlueZ mpris-proxy user daemons
#    - Load 88XXau.ko on USB hotplug only (reclaim ~3 MiB kernel RAM when unplugged)
#    - Default Bluetooth to powered off at boot (AutoEnable=false) + netdev rfkill access
sudo -u kali XDG_RUNTIME_DIR=/run/user/1000 \
    systemctl --user stop filter-chain.service mpris-proxy.service 2>/dev/null || true
rm -rf /etc/pipewire/filter-chain.conf.d \
       /home/kali/.config/systemd/user/filter-chain.service.d
rm -f /etc/systemd/user/default.target.wants/filter-chain.service \
      /etc/systemd/user/default.target.wants/mpris-proxy.service
ln -sfn /dev/null /etc/systemd/user/filter-chain.service
ln -sfn /dev/null /etc/systemd/user/mpris-proxy.service

cat > /etc/udev/rules.d/70-cardputerzero-peripherals.rules <<'EOF'
# Allow kali user (video/i2c/plugdev/netdev) to use IR TX/RX, hardware RTC, USB HID gadgets, and rfkill
SUBSYSTEM=="lirc", GROUP="video", MODE="0660"
SUBSYSTEM=="rtc", GROUP="i2c", MODE="0664"
ACTION=="add", SUBSYSTEM=="rtc", KERNEL=="rtc0", RUN+="/sbin/hwclock --hctosys --utc --noadjfile"
KERNEL=="hidg[0-9]*", GROUP="plugdev", MODE="0660"
KERNEL=="rfkill", SUBSYSTEM=="misc", GROUP="netdev", MODE="0664"
EOF

rm -f /etc/modules-load.d/rtw88xxau.conf
cat > /etc/udev/rules.d/99-rtw88xxau.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0811", RUN+="/usr/sbin/modprobe 88XXau"
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8822", RUN+="/usr/sbin/modprobe 88XXau"
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="a811", RUN+="/usr/sbin/modprobe 88XXau"
EOF
if lsmod | grep -q '^88XXau ' && ! iw dev 2>/dev/null | grep -q 'wlan1'; then
    modprobe -r 88XXau 2>/dev/null || true
fi

if [ -f /etc/bluetooth/main.conf ]; then
    if grep -qE '^#?[[:space:]]*AutoEnable[[:space:]]*=' /etc/bluetooth/main.conf; then
        sed -i -E 's/^#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable=false/' /etc/bluetooth/main.conf
    else
        printf '\n[Policy]\nAutoEnable=false\n' >> /etc/bluetooth/main.conf
    fi
else
    install -d /etc/bluetooth
    printf '[Policy]\nAutoEnable=false\n' > /etc/bluetooth/main.conf
fi
if command -v bluetoothctl >/dev/null 2>&1; then
    if [ -z "$(bluetoothctl devices Connected 2>/dev/null || true)" ]; then
        bluetoothctl power off >/dev/null 2>&1 || true
    fi
fi

# 7. On-demand HDMI desktop hotplug + RAM reclaim
install -d -m 755 /etc/default /etc/systemd/system/lightdm.service.d
if [ ! -f /etc/default/cz-hdmi-desktop ]; then
    cat > /etc/default/cz-hdmi-desktop <<'EOF'
# CardputerZero HDMI desktop policy: auto | always | off
HDMI_DESKTOP_MODE=auto
HDMI_UNPLUG_DELAY=5
EOF
fi
cat > /etc/systemd/system/lightdm.service.d/hdmi-on-demand.conf <<'EOF'
[Unit]
After=systemd-user-sessions.service systemd-udev-settle.service
OnFailure=

[Service]
ExecCondition=/usr/local/bin/cz-hdmi-hotplug check
Restart=on-failure
RestartSec=2s
TimeoutStopSec=10s
EOF
cat > /etc/systemd/system/cz-hdmi-hotplug.service <<'EOF'
[Unit]
Description=CardputerZero On-Demand HDMI Desktop Hotplug Handler
After=systemd-user-sessions.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cz-hdmi-hotplug sync
EOF
cat > /etc/udev/rules.d/91-cz-hdmi-hotplug.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*-HDMI-A-*", RUN+="/usr/bin/systemctl --no-block start cz-hdmi-hotplug.service"
ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}!="platform-3f204000.spi-cs-0", RUN+="/usr/bin/systemctl --no-block start cz-hdmi-hotplug.service"
EOF

# 8. Generate & install Kali boot splash + APPLaunch logo_lcd.png + lockscreen.png
for img in /usr/share/APPLaunch/share/images/logo_lcd.png \
           /usr/share/APPLaunch/share/images/lockscreen.png; do
    base="$(basename "$img")"
    if [ -e "$img" ] && ! dpkg-divert --list "$img" | grep -q "$img"; then
        dpkg-divert --local --rename --divert "/usr/lib/cz-kali/${base}.m5" --add "$img"
    fi
done
python3 gen-kali-splash.py \
    --emblem /usr/share/icons/desktop-base/256x256/emblems/emblem-kali.png \
    --bmp /boot/firmware/splash.bmp \
    --logo-png /usr/share/APPLaunch/share/images/logo_lcd.png \
    --lock-png /usr/share/APPLaunch/share/images/lockscreen.png

install -d /etc/systemd/system/fb_load.service.d
cat > /etc/systemd/system/fb_load.service.d/kali-splash.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/fb_load --keep-open /boot/firmware/splash.bmp /dev/dri/cardputer-zero-internal
EOF
systemctl daemon-reload
systemctl stop fb_load.service 2>/dev/null || true
udevadm control --reload-rules
udevadm trigger --subsystem-match=misc --sysname-match=rfkill 2>/dev/null || true
/usr/local/bin/cz-hdmi-hotplug sync
/usr/local/bin/cz-hdmi-hotplug status

sudo -u kali XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
sudo -u kali XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart APPLaunch.service

rm -rf /tmp/cz-live-sync
echo "[+] Live deployment complete."
free -m | awk 'NR==1 || NR==2 {print}'
REMOTE

echo "[*] Streaming bundle & deploying over a single SSH session to $TARGET ..."
tar -C "$TMP_BUNDLE" -czf - . | ssh "$TARGET" \
    'set -e; rm -rf /tmp/cz-live-sync && mkdir -p /tmp/cz-live-sync && tar -xzf - -C /tmp/cz-live-sync && sudo bash /tmp/cz-live-sync/_deploy_remote.sh'
