#!/usr/bin/env bash
# build-ota-bundle.sh - Build & sign ARM64 Cortex-A53 OTA bundle for CardputerZero
#
# Produces in $OUT_DIR (default: output/ota):
#   - kali-cz-ota-<version>-arm64.tar.xz    (~16-22 MB solid xz archive)
#   - kali-cz-ota-<version>-arm64.tar.xz.sha256
#   - ota-manifest.json
#   - ota-manifest.json.sig                 (when OTA_SIGNING_KEY or OTA_SIGNING_KEY_FILE is set)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREBUILT_DIR="${PREBUILT_SHELL_DIR:-$REPO_ROOT/work/prebuilt-shell}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/output/ota}"
PUBKEY_FILE="$REPO_ROOT/overlays/ota/ota-pub.pem"

REBUILD=0
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

OTA_REPO="${OTA_REPO:-on-my-machine-works/kali-on-cardputerzero}"
OTA_VERSION="${OTA_VERSION:-v$(date -u +%Y.%m.%d)}"
OTA_COMMIT="${OTA_COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)}"
OTA_BUILD_DATE="${OTA_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
OTA_IMAGE_EPOCH="${OTA_IMAGE_EPOCH:-1}"
OTA_KERNEL_ABI="${OTA_KERNEL_ABI:-$(python3 -c 'import json; print(json.load(open("'"$REPO_ROOT/upstream.lock.json"'"))["kernel"]["kver"])' 2>/dev/null || echo 6.18.39+rpt-rpi-v8)}"

if [[ -z "${OTA_CHANNEL:-}" ]]; then
    if [[ "$OTA_VERSION" == weekly-* || "$OTA_VERSION" == nightly-* ]]; then
        OTA_CHANNEL="nightly"
    else
        OTA_CHANNEL="release"
    fi
fi
OTA_BRANCH="release"
[[ "$OTA_CHANNEL" == "nightly" ]] && OTA_BRANCH="dev"

if [[ -z "${OTA_BUILD_NUM:-}" ]]; then
    # UTC Unix epoch seconds (strictly monotonic u32 until year 2106 across all tag formats)
    OTA_BUILD_NUM="$(date -u +%s)"
fi

ARCHIVE_NAME="kali-cz-ota-${OTA_VERSION}-arm64.tar.xz"
OTA_DOWNLOAD_URL="${OTA_DOWNLOAD_URL:-https://github.com/${OTA_REPO}/releases/download/${OTA_VERSION}/${ARCHIVE_NAME}}"

need_build="$REBUILD"
for sb in czctl kali-usb-deck flipctl-sysmon cz-term \
          flipctl-recorder flipctl-radio flipctl-disk-bench flipctl-bt-hid; do
    [[ -x "$PREBUILT_DIR/bin/$sb" ]] || need_build=1
done
if (( need_build )); then
    PREBUILT_SHELL_DIR="$PREBUILT_DIR" "$REPO_ROOT/scripts/build-cz-shell.sh"
fi

HOST_ARCH="$(uname -m)"
CC_ARM="gcc"
STRIP_ARM="strip"
OBJDUMP_ARM="objdump"
if [[ "$HOST_ARCH" != "aarch64" ]]; then
    CC_ARM="aarch64-linux-gnu-gcc"
    STRIP_ARM="aarch64-linux-gnu-strip"
    OBJDUMP_ARM="aarch64-linux-gnu-objdump"
fi

STAGE_TMP="$(mktemp -d)"
trap 'rm -rf "$STAGE_TMP"' EXIT
PAYLOAD="$STAGE_TMP/payload"
CSRC="$STAGE_TMP/c-src"

mkdir -p "$PAYLOAD/usr/bin" \
         "$PAYLOAD/usr/local/bin" \
         "$PAYLOAD/usr/lib/cz-kali" \
         "$PAYLOAD/usr/share/czctl/assets" \
         "$PAYLOAD/usr/share/czctl/apps" \
         "$PAYLOAD/usr/share/czctl/payloads" \
         "$PAYLOAD/usr/share/czctl/ota-tools" \
         "$PAYLOAD/etc/umtprd" \
         "$PAYLOAD/etc/systemd/system" \
         "$PAYLOAD/etc/udev/rules.d" \
         "$PAYLOAD/etc/NetworkManager/conf.d" \
         "$PAYLOAD/etc/sysctl.d" \
         "$CSRC"

echo "[1/4] Compiling ARMv8.0 Cortex-A53 C framebuffer utilities & shim ..."
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
   "$CSRC/"

make -C "$CSRC" CC="$CC_ARM" DESTDIR="$PAYLOAD" install >/dev/null
"$STRIP_ARM" --strip-unneeded \
    "$PAYLOAD/usr/lib/cz-kali/libcz_fb_lcd.so" \
    "$PAYLOAD/usr/local/bin/cz-sysmon" \
    "$PAYLOAD/usr/local/bin/cz-term" \
    "$PAYLOAD/usr/local/bin/cz-term80" \
    "$PAYLOAD/usr/local/bin/cz-wifiscan" \
    "$PAYLOAD/usr/local/bin/cz-lanscan" \
    "$PAYLOAD/usr/local/bin/cz-pktsniff" \
    "$PAYLOAD/usr/local/bin/cz-usbgadget"

echo "[2/4] Staging Cortex-A53 binaries, apps, scripts & configs ..."
for sb in czctl kali-usb-deck flipctl-sysmon cz-term \
          flipctl-recorder flipctl-radio flipctl-disk-bench flipctl-bt-hid; do
    install -m 755 "$PREBUILT_DIR/bin/$sb" "$PAYLOAD/usr/bin/$sb"
done
ln -sfn czctl "$PAYLOAD/usr/bin/flipctl"
ln -sfn cz-term "$PAYLOAD/usr/bin/cz-flipper-term"

for s in cz-kali-menu cz-kali-pkgs cz-usb-gadget cz-flipper-gadget cz-badusb \
         cz-ui-mode cz-hw-status cz-hdmi-hotplug cz-stealth cz-ota cz-cap-uart; do
    install -m 755 "$REPO_ROOT/scripts/$s" "$PAYLOAD/usr/local/bin/$s"
done

cp -a "$PREBUILT_DIR/share/czctl/assets/remote" "$PAYLOAD/usr/share/czctl/assets/remote"
install -m 755 "$REPO_ROOT/overlays/apps/"*.fap.sh "$PAYLOAD/usr/share/czctl/apps/"
install -m 644 "$REPO_ROOT/overlays/payloads/"* "$PAYLOAD/usr/share/czctl/payloads/"
install -m 644 "$PUBKEY_FILE" "$PAYLOAD/usr/share/czctl/ota-pub.pem"
ln -sfn czctl "$PAYLOAD/usr/share/flipctl"

install -m 755 "$REPO_ROOT/scripts/configure-kali-launcher.py" "$PAYLOAD/usr/share/czctl/ota-tools/configure-kali-launcher.py"
install -m 755 "$REPO_ROOT/scripts/gen-kali-splash.py" "$PAYLOAD/usr/share/czctl/ota-tools/gen-kali-splash.py"

cat > "$PAYLOAD/usr/share/czctl/ota-tools/postinstall.sh" <<'POSTEOF'
#!/usr/bin/env bash
# Idempotent post-OTA migration hook shipped inside each signed OTA bundle so
# devices jumping across many versions pick up new units, masks, or sysctl/udev
# tweaks even when started by an older on-device cz-ota script.
set -euo pipefail

install -d -m 755 /etc/default /etc/systemd/system/multi-user.target.wants /etc/modules-load.d
if [[ ! -f /etc/default/cz-stealth ]]; then
    cat > /etc/default/cz-stealth <<'EOF'
# CardputerZero Hostile-Network Stealth Mode: on | off
STEALTH_MODE=off
EOF
fi
if [[ ! -f /etc/default/cz-hdmi-desktop ]]; then
    cat > /etc/default/cz-hdmi-desktop <<'EOF'
# CardputerZero HDMI desktop policy: auto | always | off
HDMI_DESKTOP_MODE=auto
HDMI_UNPLUG_DELAY=5
EOF
fi
if [[ ! -f /etc/default/cz-cap-uart ]]; then
    if [[ -f /boot/firmware/config.txt ]] && grep -qx 'enable_uart=1' /boot/firmware/config.txt 2>/dev/null; then
        printf '# CardputerZero 14-pin Cap UART (/dev/ttyS0 for LoRa/GNSS GPS): on | off\nCAP_UART_MODE=on\n' > /etc/default/cz-cap-uart
    else
        printf '# CardputerZero 14-pin Cap UART (/dev/ttyS0 for LoRa/GNSS GPS): on | off\nCAP_UART_MODE=off\n' > /etc/default/cz-cap-uart
    fi
fi
if ! grep -qx 'uinput' /etc/modules-load.d/cardputerzero.conf 2>/dev/null; then
    echo "uinput" >> /etc/modules-load.d/cardputerzero.conf
fi
modprobe uinput 2>/dev/null || true

ln -sfn /etc/systemd/system/czctl.service /etc/systemd/system/flipctl.service
[[ -f /etc/systemd/system/cz-stealth.service ]] && \
    ln -sfn /etc/systemd/system/cz-stealth.service /etc/systemd/system/multi-user.target.wants/cz-stealth.service
[[ -f /etc/systemd/system/cz-ui-ensure.service ]] && \
    ln -sfn /etc/systemd/system/cz-ui-ensure.service /etc/systemd/system/multi-user.target.wants/cz-ui-ensure.service
if [[ ! -L /etc/systemd/system/multi-user.target.wants/czctl.service ]] && \
   [[ ! -L /home/kali/.config/systemd/user/default.target.wants/APPLaunch.service ]] && \
   [[ ! -L /etc/systemd/user/default.target.wants/APPLaunch.service ]]; then
    install -d -m 755 /etc/systemd/system/graphical.target.wants
    ln -sfn /etc/systemd/system/czctl.service /etc/systemd/system/multi-user.target.wants/czctl.service
    ln -sfn /etc/systemd/system/czctl.service /etc/systemd/system/graphical.target.wants/czctl.service
fi
sysctl --system >/dev/null 2>&1 || sysctl -qw "net.ipv4.ping_group_range=0 2147483647" 2>/dev/null || true
if [[ -x /usr/bin/ping ]] && command -v setcap >/dev/null 2>&1; then
    setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || true
fi
POSTEOF
chmod 755 "$PAYLOAD/usr/share/czctl/ota-tools/postinstall.sh"

install -m 644 "$REPO_ROOT/overlays/etc/umtprd/umtprd.conf" "$PAYLOAD/etc/umtprd/umtprd.conf"
install -m 644 "$REPO_ROOT/overlays/systemd/czctl.service" "$PAYLOAD/etc/systemd/system/czctl.service"
install -m 644 "$REPO_ROOT/overlays/systemd/cz-stealth.service" "$PAYLOAD/etc/systemd/system/cz-stealth.service"
install -m 644 "$REPO_ROOT/overlays/systemd/cz-ui-ensure.service" "$PAYLOAD/etc/systemd/system/cz-ui-ensure.service"
install -m 644 "$REPO_ROOT/overlays/systemd/72-seat-cardputer-czctl.rules" "$PAYLOAD/etc/udev/rules.d/72-seat-cardputer-czctl.rules"

cat > "$PAYLOAD/etc/udev/rules.d/70-cardputerzero-peripherals.rules" <<'EOF'
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
ACTION=="add|bind|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="05e3", ATTR{idProduct}=="0610", ATTR{power/autosuspend_delay_ms}="0", ATTR{power/control}="auto"
ACTION=="add|bind|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="0fe6", ATTR{idProduct}=="9900", ATTR{power/autosuspend_delay_ms}="500", ATTR{power/control}="auto"
ACTION=="add|bind", SUBSYSTEM=="usb", DRIVER=="r8152", ATTRS{idVendor}=="0fe6", ATTRS{idProduct}=="9900", RUN+="/bin/sh -c 'echo 500 > /sys$devpath/../power/autosuspend_delay_ms; echo auto > /sys$devpath/../power/control'"
EOF

cat > "$PAYLOAD/etc/NetworkManager/conf.d/20-wifi-powersave.conf" <<'EOF'
[connection]
wifi.powersave = 3
EOF

cat > "$PAYLOAD/etc/NetworkManager/conf.d/25-cz-privacy.conf" <<'EOF'
[device]
wifi.scan-rand-mac-address=yes

[connection]
ipv4.dhcp-send-hostname=0
ipv6.dhcp-send-hostname=0
EOF

cat > "$PAYLOAD/etc/sysctl.d/50-cz-network.conf" <<'EOF'
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

cat > "$PAYLOAD/etc/cz-release" <<EOF
CZ_VERSION="${OTA_VERSION}"
CZ_BUILD_NUM="${OTA_BUILD_NUM}"
CZ_COMMIT="${OTA_COMMIT}"
CZ_CHANNEL="${OTA_CHANNEL}"
CZ_BUILD_DATE="${OTA_BUILD_DATE}"
CZ_IMAGE_EPOCH="${OTA_IMAGE_EPOCH}"
CZ_KERNEL_ABI="${OTA_KERNEL_ABI}"
EOF

# Audit every ELF binary in payload for unguarded ARMv8.1+ LSE instructions
while IFS= read -r -d '' elf; do
    file "$elf" | grep -q 'ELF 64-bit' || continue
    bad_lse="$("$OBJDUMP_ARM" -d "$elf" | awk '
        {
            if ($3 ~ /^(ldadd|ldclr|ldeor|ldset|swp|cas)[a-z]*$/ && prev !~ /cbz[[:space:]]+w16,/) {
                print $0
            }
            prev = $0
        }
    ' | head -n 3)"
    if [[ -n "$bad_lse" ]]; then
        echo "ERROR: Unguarded ARMv8.1+ LSE atomic instruction in $elf:" >&2
        echo "$bad_lse" >&2
        exit 1
    fi
done < <(find "$PAYLOAD" -type f -print0)

(cd "$PAYLOAD" && find . \( -type f -o -type l \) ! -name 'FILELIST.txt' | sed 's|^\./||' | LC_ALL=C sort) > "$PAYLOAD/FILELIST.txt"

echo "[3/4] Compressing OTA payload ($ARCHIVE_NAME) ..."
mkdir -p "$OUT_DIR"
tar --sort=name --owner=0 --group=0 --numeric-owner -cf - -C "$PAYLOAD" . | xz -6 -T0 > "$OUT_DIR/$ARCHIVE_NAME"

SHA256="$(sha256sum "$OUT_DIR/$ARCHIVE_NAME" | awk '{print $1}')"
SIZE_BYTES="$(stat -c '%s' "$OUT_DIR/$ARCHIVE_NAME")"
(cd "$OUT_DIR" && printf '%s  %s\n' "$SHA256" "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256")

python3 - "$OUT_DIR/ota-manifest.json" \
    "$OTA_VERSION" "$OTA_BUILD_NUM" "$OTA_COMMIT" "$OTA_CHANNEL" "$OTA_BRANCH" \
    "$OTA_BUILD_DATE" "$OTA_IMAGE_EPOCH" "$OTA_KERNEL_ABI" \
    "$ARCHIVE_NAME" "$SIZE_BYTES" "$SHA256" "$OTA_DOWNLOAD_URL" "${OTA_NOTES:-}" <<'PY'
import json
import subprocess
import sys

(
    out_path, ver, bnum, commit, channel, branch,
    built_at, epoch, kabi, archive, size_b, sha256, url, raw_notes
) = sys.argv[1:15]

notes = []
if raw_notes.strip():
    for line in raw_notes.replace("\\n", "\n").splitlines():
        clean = line.strip().lstrip("-* ").strip()
        if clean:
            notes.append(clean)
else:
    try:
        log = subprocess.check_output(
            ["git", "log", "-n", "3", "--pretty=%s"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        for line in log.splitlines():
            if "[skip ci]" not in line and line.strip():
                notes.append(line.strip())
    except Exception:
        pass

manifest = {
    "format": 1,
    "version": ver,
    "build_num": int(bnum),
    "commit": commit,
    "channel": channel,
    "branch": branch,
    "built_at": built_at,
    "min_image_epoch": int(epoch),
    "kernel_abi": kabi,
    "archive": archive,
    "size_bytes": int(size_b),
    "sha256": sha256,
    "download_url": url,
    "notes": notes[:4],
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "[4/4] Signing ota-manifest.json (if Ed25519 signing key provided) ..."
rm -f "$OUT_DIR/ota-manifest.json.sig"
KEY_TMP=""
if [[ -n "${OTA_SIGNING_KEY_FILE:-}" && -f "${OTA_SIGNING_KEY_FILE}" ]]; then
    KEY_SRC="$OTA_SIGNING_KEY_FILE"
elif [[ -n "${OTA_SIGNING_KEY:-}" ]]; then
    KEY_TMP="$(mktemp)"
    chmod 600 "$KEY_TMP"
    printf '%s\n' "$OTA_SIGNING_KEY" > "$KEY_TMP"
    KEY_SRC="$KEY_TMP"
else
    KEY_SRC=""
fi

if [[ -n "$KEY_SRC" ]]; then
    openssl pkeyutl -sign -inkey "$KEY_SRC" -rawin \
        -in "$OUT_DIR/ota-manifest.json" \
        -out "$OUT_DIR/ota-manifest.json.sig"
    [[ -n "$KEY_TMP" ]] && rm -f "$KEY_TMP"
    openssl pkeyutl -verify -pubin -inkey "$PUBKEY_FILE" \
        -sigfile "$OUT_DIR/ota-manifest.json.sig" -rawin \
        -in "$OUT_DIR/ota-manifest.json"
    echo "[+] Ed25519 signature verified against $PUBKEY_FILE"
else
    echo "[!] Note: OTA_SIGNING_KEY / OTA_SIGNING_KEY_FILE not set; generated unsigned ota-manifest.json"
fi

echo "[+] Built OTA bundle: $OUT_DIR/$ARCHIVE_NAME ($(du -h "$OUT_DIR/$ARCHIVE_NAME" | awk '{print $1}'), build ${OTA_BUILD_NUM})"
