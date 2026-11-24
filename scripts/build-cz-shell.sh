#!/usr/bin/env bash
# build-cz-shell.sh — Build & stage Cortex-A53 ARM64 `czctl` (with `flipctl` symlink),
# `cz-boot-menu`, `kali-usb-deck`, in-tree Wayland apps (`Voice Recorder`, `Internet Radio`,
# `Disk Benchmark`, `BT/USB HID Pad`, `System Monitor`), and `cz-term` (`cz-flipper-term`)
# for M5Stack CardputerZero (Kali Dark 320x170 RGB565 + :8899 Web KVM).
#
# Enforces `-C target-cpu=cortex-a53` (ARMv8.0-A) and `-march=armv8-a+crc` plus an
# automated `objdump -d` gate rejecting any unguarded ARMv8.1+ LSE atomic instructions
# (`ldadd`, `ldclr`, `ldeor`, `ldset`, `swp`, `cas`) that would SIGILL on BCM2837/RP3A0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_SRC="$REPO_ROOT/shell"
PREBUILT_DIR="${PREBUILT_SHELL_DIR:-$REPO_ROOT/work/prebuilt-shell}"
APPS_TARGET_DIR="$SHELL_SRC/target/cz-apps"

HOST_ARCH="$(uname -m)"
CARGO_TARGET_ARGS=()
RELEASE_SUBDIR="release"
CC_ARM="gcc"
OBJDUMP_ARM="objdump"
STRIP_ARM="strip"

if [[ "$HOST_ARCH" != "aarch64" ]]; then
    CARGO_TARGET_ARGS=(--target aarch64-unknown-linux-gnu)
    RELEASE_SUBDIR="aarch64-unknown-linux-gnu/release"
    CC_ARM="aarch64-linux-gnu-gcc"
    OBJDUMP_ARM="aarch64-linux-gnu-objdump"
    STRIP_ARM="aarch64-linux-gnu-strip"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="aarch64-linux-gnu-gcc"
    export CC_aarch64_unknown_linux_gnu="aarch64-linux-gnu-gcc"
    export CXX_aarch64_unknown_linux_gnu="aarch64-linux-gnu-g++"
fi

ROOT_FS="${ROOT_FS:-ext4}"
WITH_BOOT_MENU=0
[[ "$ROOT_FS" == "btrfs" || "${1:-}" == "--with-boot-menu" ]] && WITH_BOOT_MENU=1

echo "[1/5] Checking token & panel-dimension guardrails (shell/ci/no-raw-colours.sh) ..."
sh "$SHELL_SRC/ci/no-raw-colours.sh"

echo "[2/5] Compiling czctl, kali-usb-deck & sysmon-app for Cortex-A53 ..."
BOOT_MENU_PKGS=()
(( WITH_BOOT_MENU )) && BOOT_MENU_PKGS=(-p flipper-boot-menu)
(
    cd "$SHELL_SRC"
    CARGO_PROFILE_RELEASE_DEBUG=0 \
    CFLAGS="${CFLAGS:-} -march=armv8-a+crc" \
    CXXFLAGS="${CXXFLAGS:-} -march=armv8-a+crc" \
    RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=cortex-a53" \
        cargo build --release "${CARGO_TARGET_ARGS[@]}" \
            -p flipctl --features flipctl/device,flipctl/slint,flipctl/remote,flipctl/wayland \
            "${BOOT_MENU_PKGS[@]}" \
            -p kali-usb-deck \
            -p sysmon-app
)

REBUILD_APPS=0
[[ "${1:-}" == "--rebuild-apps" ]] && REBUILD_APPS=1

echo "[3/5] Compiling Cortex-A53 Wayland apps (recorder, radio, disk-benchmark, usb-keyboard-touchpad) & cz-term ..."
mkdir -p "$APPS_TARGET_DIR/$RELEASE_SUBDIR"
for spec in \
    "recorder:recorder-app:flipctl-recorder" \
    "radio:radio-app:flipctl-radio" \
    "disk-benchmark:disk-benchmark-app:flipctl-disk-bench" \
    "usb-keyboard-touchpad:usb-keyboard-touchpad-app:flipctl-bt-hid"
do
    IFS=':' read -r app_dir out_bin staged_bin <<< "$spec"
    if [[ "$REBUILD_APPS" -eq 0 && ! -x "$APPS_TARGET_DIR/$RELEASE_SUBDIR/$out_bin" && -x "$PREBUILT_DIR/bin/$staged_bin" ]]; then
        cp -a "$PREBUILT_DIR/bin/$staged_bin" "$APPS_TARGET_DIR/$RELEASE_SUBDIR/$out_bin"
        continue
    fi
    CARGO_PROFILE_RELEASE_DEBUG=0 \
    CFLAGS="${CFLAGS:-} -march=armv8-a+crc" \
    CXXFLAGS="${CXXFLAGS:-} -march=armv8-a+crc" \
    RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=cortex-a53" \
        cargo build --release "${CARGO_TARGET_ARGS[@]}" \
            --manifest-path "$SHELL_SRC/apps/$app_dir/Cargo.toml" \
            --target-dir "$APPS_TARGET_DIR"
done

mkdir -p "$SHELL_SRC/target/$RELEASE_SUBDIR"
"$CC_ARM" -O2 -Wall -Wextra -march=armv8-a+crc \
    -I"$REPO_ROOT/src" \
    "$REPO_ROOT/src/cz-term.c" \
    -o "$SHELL_SRC/target/$RELEASE_SUBDIR/cz-term" \
    -lutil

BIN_MAP=(
    "$SHELL_SRC/target/$RELEASE_SUBDIR/flipctl:czctl"
    "$SHELL_SRC/target/$RELEASE_SUBDIR/kali-usb-deck:kali-usb-deck"
    "$SHELL_SRC/target/$RELEASE_SUBDIR/sysmon-app:flipctl-sysmon"
    "$SHELL_SRC/target/$RELEASE_SUBDIR/cz-term:cz-term"
    "$APPS_TARGET_DIR/$RELEASE_SUBDIR/recorder-app:flipctl-recorder"
    "$APPS_TARGET_DIR/$RELEASE_SUBDIR/radio-app:flipctl-radio"
    "$APPS_TARGET_DIR/$RELEASE_SUBDIR/disk-benchmark-app:flipctl-disk-bench"
    "$APPS_TARGET_DIR/$RELEASE_SUBDIR/usb-keyboard-touchpad-app:flipctl-bt-hid"
)
(( WITH_BOOT_MENU )) && BIN_MAP+=("$SHELL_SRC/target/$RELEASE_SUBDIR/flipper-boot-menu:cz-boot-menu")

for pair in "${BIN_MAP[@]}"; do
    BIN="${pair%%:*}"
    if [[ ! -x "$BIN" ]]; then
        echo "ERROR: Expected release binary not found at $BIN" >&2
        exit 1
    fi
done

echo "[4/5] Auditing all 9 binaries for unguarded ARMv8.1+ LSE atomic instructions ..."
if command -v "$OBJDUMP_ARM" >/dev/null 2>&1; then
    for pair in "${BIN_MAP[@]}"; do
        BIN="${pair%%:*}"
        # libgcc's outline-atomics helpers check `__aarch64_have_lse_atomics` via `cbz w16, <fallback>`
        # immediately before an LSE instruction and fall back to ARMv8.0 `ldxr/stxr` on Cortex-A53.
        # Any LSE instruction NOT preceded by `cbz w16,` is an unguarded inline LSE emission and is fatal.
        unguarded_lse="$("$OBJDUMP_ARM" -d "$BIN" | awk '
            {
                if ($3 ~ /^(ldadd|ldclr|ldeor|ldset|swp|cas)[a-z]*$/ && prev !~ /cbz[[:space:]]+w16,/) {
                    print $0
                }
                prev = $0
            }
        ' | head -n 5)"
        if [[ -n "$unguarded_lse" ]]; then
            echo "ERROR: Unguarded ARMv8.1+ LSE instructions detected in $BIN (unsafe for Cortex-A53 CM0):" >&2
            echo "$unguarded_lse" >&2
            exit 1
        fi
    done
else
    echo "ERROR: $OBJDUMP_ARM not found; cannot verify ARMv8.0 LSE safety" >&2
    exit 1
fi

echo "[5/5] Staging prebuilt Cortex-A53 binaries & assets into $PREBUILT_DIR ..."
rm -rf "$PREBUILT_DIR"
install -d -m 755 "$PREBUILT_DIR/bin" \
                  "$PREBUILT_DIR/share/czctl/assets" \
                  "$PREBUILT_DIR/share/czctl/apps" \
                  "$PREBUILT_DIR/share/czctl/payloads"

for pair in "${BIN_MAP[@]}"; do
    src_bin="${pair%%:*}"
    dst_name="${pair##*:}"
    cp -a "$src_bin" "$PREBUILT_DIR/bin/$dst_name"
    if command -v "$STRIP_ARM" >/dev/null 2>&1; then
        "$STRIP_ARM" --strip-unneeded "$PREBUILT_DIR/bin/$dst_name"
    fi
done

# Compatibility symlinks for existing .fap.sh bundles and AppRun scripts
ln -sfn czctl "$PREBUILT_DIR/bin/flipctl"
ln -sfn cz-term "$PREBUILT_DIR/bin/cz-flipper-term"
(( WITH_BOOT_MENU )) && ln -sfn cz-boot-menu "$PREBUILT_DIR/bin/flipper-boot-menu"
ln -sfn czctl "$PREBUILT_DIR/share/flipctl"

cp -a "$SHELL_SRC/crates/flipper-ui/src/remote" "$PREBUILT_DIR/share/czctl/assets/remote"
rm -f "$PREBUILT_DIR/share/czctl/assets/remote/mod.rs"

if [[ -d "$REPO_ROOT/overlays/apps" ]]; then
    install -m 755 "$REPO_ROOT/overlays/apps/"*.fap.sh "$PREBUILT_DIR/share/czctl/apps/"
fi
if [[ -d "$REPO_ROOT/overlays/payloads" ]]; then
    for f in "$REPO_ROOT/overlays/payloads/"*; do
        [[ -f "$f" ]] && install -m 644 "$f" "$PREBUILT_DIR/share/czctl/payloads/"
    done
fi

echo "[+] Staged Cortex-A53 binaries:"
for pair in "${BIN_MAP[@]}"; do
    b="${pair##*:}"
    echo "    - $PREBUILT_DIR/bin/$b ($(du -h "$PREBUILT_DIR/bin/$b" | awk '{print $1}'))"
done
