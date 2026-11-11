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
   "$SCRIPT_DIR/scripts/gen-kali-splash.py" \
   "$SCRIPT_DIR/scripts/configure-kali-launcher.py" \
   "$TMP_BUNDLE/"

echo "[*] Uploading sources and scripts to $TARGET:/tmp/cz-live-sync ..."
ssh "$TARGET" "rm -rf /tmp/cz-live-sync && mkdir -p /tmp/cz-live-sync"
scp -q "$TMP_BUNDLE"/* "$TARGET:/tmp/cz-live-sync/"

echo "[*] Building native 320x170 apps and updating launcher on $TARGET ..."
ssh "$TARGET" 'sudo bash -s' <<'REMOTE'
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
    cp -a /usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5 /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
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
install -m 755 cz-kali-menu  /usr/local/bin/cz-kali-menu
install -m 755 cz-kali-pkgs  /usr/local/bin/cz-kali-pkgs
install -m 755 cz-usb-gadget /usr/local/bin/cz-usb-gadget
install -m 755 cz-hw-status  /usr/local/bin/cz-hw-status
install -d -m 755 -o kali -g kali /home/kali/captures

# 4. Configure launcher layout, manifest & config.json
python3 configure-kali-launcher.py /
chown -R kali:kali /home/kali/.config
touch /home/kali/.hushlogin && chown kali:kali /home/kali/.hushlogin

install -d /etc/systemd/user/APPLaunch.service.d
cat > /etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf <<'EOF'
[Unit]
After=systemd-udev-settle.service pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Environment=LV_LINUX_FBDEV_DEVICE=/dev/fb_lcd
ExecStartPre=-/usr/bin/xdg-user-dirs-update
ExecStartPre=/bin/sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/input/by-path/platform-3f804000.i2c-event ] && [ -e /dev/fb_lcd ] && exit 0; sleep 1; done; exit 0"
EOF

# 5. Generate & install Kali boot splash + APPLaunch logo_lcd.png + lockscreen.png
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

sudo -u kali XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
sudo -u kali XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart APPLaunch.service

rm -rf /tmp/cz-live-sync
echo "[+] Live deployment complete."
REMOTE
