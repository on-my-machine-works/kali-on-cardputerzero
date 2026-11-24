# Kali Cyberdeck Shell (`czctl`)

Rust/Slint UI workspace for **Kali Linux Cyberdeck Edition on M5Stack CardputerZero (`arm64`)**: drives the `320×170` RGB565 `ST7789v3` SPI display via DRM/KMS, reads the 46-key `TCA8418` matrix (`1:1` bezel-aligned `4`–`8` softkeys), hosts `320×170` Wayland apps in an isolated headless `sway` compositor, and serves the `:8899` browser-based **Kali CZ Web KVM**.

## Workspace Layout

| Path | Description |
| :--- | :--- |
| `crates/flipper-ui/tokens.toml` | Single source of truth for colours, layout metrics, timings, and panel dimensions (`320×170` Kali Dark RGB565 + runtime themes). |
| `crates/flipper-tokens/` | Build-time Rust & Slint theme code generator driven by `tokens.toml`. |
| `crates/flipper-ui/` | Shared UI library: DRM/KMS sink, `TCA8418` + `/dev/uinput` input, `:8899` Web KVM, headless `sway` Wayland host, Wi-Fi/Bluetooth/USB/sysinfo backends, and `.fap.sh` / AppImage discovery. |
| `crates/flipctl-app/` | Shared framework for hosted `320×170` Wayland apps. |
| `bin/flipctl/` | Primary `czctl` shell binary (`/usr/bin/czctl`). |
| `bin/kali-usb-deck/` | Native Wayland deck binary (`USB Arsenal`, `Wi-Fi Recon`, `Bluetooth & BLE`, `IR Arsenal`, `Net Matrix`, `LAN Recon`, `Packet Capture`). |
| `bin/flipper-boot-menu/` | Early-boot Btrfs profile selector (`cz-boot-menu`, built when `ROOT_FS=btrfs`). |
| `apps/` | In-tree Wayland apps (`sysmon`, `recorder`, `radio`, `disk-benchmark`, `usb-keyboard-touchpad`). |
| `ci/no-raw-colours.sh` | Enforces zero raw hex colours or hardcoded panel dimensions outside `tokens.toml`. |

## Build & Test

From the repository root:

```bash
sh shell/ci/no-raw-colours.sh
CARGO_PROFILE_TEST_DEBUG=0 cargo test --manifest-path shell/Cargo.toml --workspace
./scripts/build-cz-shell.sh
```

`scripts/build-cz-shell.sh` enforces `-C target-cpu=cortex-a53` and `-march=armv8-a+crc` and audits every produced binary via `objdump -d` to guarantee zero unguarded ARMv8.1+ LSE atomic instructions on the Raspberry Pi CM0 (`BCM2837` / `RP3A0`).

## Licensing

- Source code in this workspace is licensed under the [MIT License](LICENSE) (adapted from [`flipctl-slint`](https://github.com/flipperdevices/flipctl-slint) by Flipper Devices; see root `../LICENSE`).
- Distributed binaries statically link [Slint](https://github.com/slint-ui/slint) under the **GPL-3.0-only** arm of Slint's license (`LICENSES/GPL-3.0-only.txt`); third-party crate notices are recorded in `THIRD-PARTY-LICENSES.md`.
- Pixel fonts under `third_party/flipctl-fonts/` carry their respective licenses (`MIT` for Busy9px, `CC-BY-SA-3.0` for HaxrCorp 4090, and `Unlicense` for Born2bSportyV2), documented in `REUSE.toml`.
