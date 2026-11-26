# Kali Linux Cyberdeck Edition for M5Stack CardputerZero (`arm64`)

[![Latest Release](https://img.shields.io/github/v/release/on-my-machine-works/kali-on-cardputerzero?label=release)](https://github.com/on-my-machine-works/kali-on-cardputerzero/releases/latest)
[![Image Release](https://github.com/on-my-machine-works/kali-on-cardputerzero/actions/workflows/build.yml/badge.svg)](https://github.com/on-my-machine-works/kali-on-cardputerzero/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Cyberdeck Edition brings together the best of three worlds: **[Kali Linux](https://www.kali.org/)**'s full `arm64` security toolset, the handheld Linux UI foundation from **[Flipper One](https://docs.flipper.net/one)** ([`flipctl-slint`](https://github.com/flipperdevices/flipctl-slint)), and **[M5Stack CardputerZero](https://docs.m5stack.com/en/core/Cardputer-Zero)**'s pocketable hardware (Cardputer Zero, Raspberry Pi Compute Module Zero Lite / `RP3A0`, 512 MB LPDDR2, hardware rev `v5`).

**Why this exists:** While looking forward to Flipper One, pairing its handheld UI ideas with full Kali Linux on the CardputerZero hardware I already carry turned out to be a magical combination, turning three separate ecosystems into one pocket cyberdeck.

Instead of treating the 1.9" SPI screen as a secondary status display, the image boots straight into a native **`320x170` RGB565 DRM/KMS shell (`czctl`)** built with [Slint](https://github.com/slint-ui/slint). It pairs `czctl` with a built-in **`:8899` Browser Web KVM**, **12 hosted Wayland offensive and hardware apps**, a **[ProFont](https://tobiasjung.name/profont/) multi-zoom terminal (`cz-term`)**, and a **composite USB-C OTG Arsenal**, while keeping full M5Stack hardware and Cap support, optional [`APPLaunch`](https://github.com/CardputerZero/launcher) switching, and an on-demand HDMI LXDE desktop within ~118 MiB idle RAM.

## What Defines Cyberdeck Edition

- **`czctl` `320x170` DRM/KMS Shell**: zero-tearing RGB565 interface in a Kali Dark palette (with runtime theme switching), live battery/thermal/power/IP idle dashboard, `1:1` bezel-aligned softkeys over physical keys `4`-`8`, visual `Tab` App Switcher, `Hold Tab` screen lock (`0 mA` backlight off), and `Hold Esc` hardware rescue.
- **`:8899` Browser Web KVM (PIN-Protected, Off by Default)**: turn it on from `Network -> Web KVM (:8899)` (`USB` for cable-only or `LAN` for Wi-Fi/Ethernet), then open `http://10.55.0.1:8899/` (or your LAN IP) and enter the 6-digit PIN shown on screen for a live pixel-exact display stream, mouse-clickable softkeys, full QWERTY `/dev/uinput` keyboard forwarding, and `/apps` bundle management.
- **Hostile-Network Stealth Mode (`cz-stealth`)**: one toggle in `Network -> Stealth mode` (or `sudo cz-stealth on`) silently drops incoming traffic and pings on Wi-Fi and Ethernet while keeping outgoing recon tools and the USB-C `10.55.0.1` management link working, randomizes your MAC address per connection, and never leaks your device hostname over DHCP.
- **12 Hosted Wayland Apps + `~/Apps` Extensibility**: isolated headless [`sway`](https://github.com/swaywm/sway) micro-compositor hosting `USB Arsenal`, `Wi-Fi Recon`, `Bluetooth & BLE`, `IR Arsenal`, `Net Matrix`, `LAN Recon`, `Packet Capture`, `System Monitor`, `Voice Recorder`, `Internet Radio`, `Disk Benchmark`, and `BT/USB HID Pad`.
- **Composite USB-C OTG Arsenal**: run non-routing `usb0` Ethernet (`10.55.0.1/24`, keeping your laptop's Wi-Fi internet intact) *simultaneously* alongside DuckyScript BadUSB HID injection (`cz-badusb`), [`uMTP-Responder`](https://github.com/Viveris/uMTP-Responder) (`umtprd`) `/home/kali` file sharing, read-only bootable `.iso` drives, or read-write FAT32 loot `.img` drives.
- **Full CardputerZero Hardware & Dual-UI Coexistence**: `IMX219` CSI camera (Raspberry Pi [`libcamera`](https://github.com/raspberrypi/libcamera) `0.7` ISP), `ES8389` [PipeWire](https://pipewire.org/) audio, `GPIO12/13` IR TX/RX, `BQ27220` fuel gauge, `RX8130CE` RTC, `BMI270`+`BMM150` IMU, `M5IOE1` 5V Grove/EXT rails, 14-pin `SX1262` LoRa/GNSS and `CC1101`/NFC Caps, plus one-command switching (`cz-ui-mode`) to M5's stock `APPLaunch` carousel or hotplug HDMI LXDE.

---

## Quick Start

### Flash Prebuilt Image

1. Download `kali-cardputerzero-arm64.img.xz` (~1.1 GiB) and `kali-cardputerzero-arm64.img.xz.sha256` from the latest GitHub Release (linked in the `release` badge above).
2. Write the image to a 16 GB+ microSD card:
   - **Raspberry Pi Imager / BalenaEtcher**: select *Use custom* and skip OS customization so `config.txt` and `cmdline.txt` are not overwritten.
   - **Linux / macOS CLI**:
     ```bash
     sha256sum -c kali-cardputerzero-arm64.img.xz.sha256
     xzcat kali-cardputerzero-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
     sync
     ```
3. Boot the CardputerZero. On first boot, `cz-firstboot-resize` expands the `ext4` root filesystem online to fill the card and `czctl` starts on the `320x170` LCD.

### Default Access

- **Login**: `kali` / `kali` (passwordless `sudo` enabled)
- **SSH**: `ssh kali@<cardputer-ip>` (or `ssh kali@10.55.0.1` over USB-C OTG)
- **Web KVM (`:8899`)**: **Off by default**. Enable `USB` or `LAN` in `Network -> Web KVM (:8899)` on the device and unlock in your browser with the 6-digit PIN shown on that menu line.

> [!IMPORTANT]
> Like upstream Kali ARM images, SSH and passwordless `sudo` ship with `kali` / `kali`. Run `passwd` on first login to set your own password, and turn on **Stealth Mode** before connecting to untrusted networks.

### Stealth Mode & Web KVM Security

Because a cyberdeck is often plugged into unknown or hostile Wi-Fi and Ethernet networks, you can lock down incoming access in seconds:

- **Turn on Stealth Mode**:
  - **On the screen**: open `Menu -> Network -> Stealth mode` (or `Settings -> Stealth mode`) and switch it to **`ON`**. The home screen will show **`[STEALTH]`** at the top.
  - **In a terminal**: run `sudo cz-stealth on` (use `sudo cz-stealth off` to turn it off, or `cz-stealth status` to check).
- **What Stealth Mode does**:
  - **Blocks incoming connections on Wi-Fi and Ethernet**: other people on the network cannot scan your open ports, connect to SSH, or ping your device.
  - **Keeps your own tools working**: all outgoing scans, web requests, and recon tools still work normally, and your USB-C cable (`10.55.0.1`) stays open so you never lock yourself out.
  - **Hides your identity**: uses a new random MAC address each time you join a Wi-Fi or Ethernet network, randomizes Wi-Fi scan probes, and never sends the `kali-cardputerzero` device name to DHCP routers.
  - **Turns off LAN Web KVM**: if Web KVM was set to `LAN`, Stealth Mode shuts it off automatically until Stealth Mode is turned back off (`USB` Web KVM over the cable still works).
- **Using Web KVM (`:8899`) safely**:
  - Web KVM is **off by default** so nothing listens on port `8899` until you ask for it.
  - Open `Menu -> Network -> Web KVM (:8899)` and press Left/Right to pick **`USB`** (reachable only over `10.55.0.1` USB-C and `127.0.0.1`) or **`LAN`** (reachable on Wi-Fi/Ethernet when Stealth Mode is off).
  - Read the **6-digit PIN** shown right on that menu line (for example, `USB: 482910`), open `http://10.55.0.1:8899/` in your browser, and enter the PIN to unlock. Switch it back to **`Off`** when you are done, and port `8899` closes right away.

### Over-The-Air (OTA) & Offline Updates (`cz-ota`)

You do not need to clone this repository or re-flash your microSD card to update the Cyberdeck shell, apps, or scripts:

- **Update from the screen**: open **`Menu -> Settings -> Update Kali CZ`** and press **`Update`**. It checks GitHub Releases for a newer Ed25519-signed bundle (~20 MB), verifies its signature and SHA-256 checksum, saves a rollback copy of your previous build, updates `czctl` and all built-in apps/scripts in place without touching `/home/kali` or your `apt` packages, and restarts the shell automatically (with an 8-second health check that auto-rolls back if the new UI fails to start).
- **Update or roll back from a terminal**:
  ```bash
  cz-ota status                                       # Show installed version and rollback backup
  cz-ota check                                        # Check GitHub Releases for signed updates
  sudo cz-ota update                                  # Download, verify, back up, and install
  sudo cz-ota rollback                                # Revert to the previous backed-up version
  sudo cz-ota install ~/kali-cz-ota-v*.tar.xz         # Offline install (with ota-manifest.json + .sig)
  ```

---

## Controls, Shell & App Deck

### Physical Keymap & Gestures

| Keys / Gesture | In `czctl` & Hosted Apps | In Text Inputs & Terminals |
| :--- | :--- | :--- |
| **`4` `5` `6` `7` `8`** | **1:1 bezel-aligned softkeys** (`WiFi`, `Menu`, `Term`, `SysMon`, `Kali` on Idle) | Digits `'4'`-`'8'` |
| **`F` / `Z` / `X` / `C`** *(or `,`/`/`/`;`/`.`)* | **Thumb D-Pad** (`Up` / `Left` / `Down` / `Right`) with hold repeat | Literal characters |
| **`Enter` / `` ` `` (`Esc`)** | Confirm (`OK`) / Back | `Enter` / `Escape` |
| **`Shift` / `Sym` / `Fn`** | Full 46-key + 32-symbol `TCA8418` hardware layers | Full punctuation & symbols |
| **Tap `Tab`** | Open live **App Switcher** across running Wayland apps | `Tab` completion |
| **Hold `Tab` (`1.2s`)** | **Lock Screen** (locks keypad + turns off LCD PWM backlight) | N/A |
| **Hold `Esc` (`2.8s`)** | **Hardware Rescue** (force-closes hung foreground app & reclaims LCD) | Hold `Esc` `1.2s` or `Ctrl+Alt+Q` exits `cz-term` / `cz-term80` |

### Built-In Menus, Terminals & Apps

- **Kali Arsenal (`[8]` from Idle)**:
  - **Hosted Wayland Deck**: `USB Arsenal`, `Wi-Fi Recon`, `Bluetooth & BLE`, `IR Arsenal` (`/dev/lirc0` TX + `/dev/lirc1` RX + `~/ir/*.ir` IR parser), `Net Matrix`, `LAN Recon`, `Packet Capture`, `System Monitor`.
  - **Terminals & TUIs**: `Terminal (Zsh)` (`cz-term` ProFont `53x14` / `45x11` / `53x15` / `80x24` from [`u8g2`](https://github.com/olikraus/u8g2) BDF glyphs with live `Ctrl+Alt+F` font zoom), `Term 80x24 (Dense)`, `Kali QuickMenu` (`cz-kali-menu`), `BadUSB & ISOs` (`cz-badusb --menu`), and `Kali Packages` (`cz-kali-pkgs`).
- **Cardputer HW**:
  - Live controls for `Audio Volume`, `LCD Backlight`, `LCD Timeout` (synced with `~/.config/cardputerzero/config.json`), `USB OTG Gadget`, `HDMI Desktop`, `EXT 5V Rail`, `Grove 5V Out`, `Grove Pin Mode`, `USB-C OTG Mux`, and `14P Cap UART` (`cz-cap-uart on|off|status` to switch `/dev/ttyS0` between 14-pin serial Cap mode and 150 MHz idle battery-save mode).
  - Direct launchers for `Voice Recorder`, `BT/USB HID Pad` (BLE GATT + USB HID touchpad/keyboard), and official [CardputerZero](https://github.com/CardputerZero) hardware apps (`Camera`, `Compass`, `IR Remote`, `IR Chat`, `LoRa SX1262`, `GPS`, `NFC`, `SubG Chat`, and `M5 Files`).
- **Switch Between `czctl` and Stock `APPLaunch` (`cz-ui-mode`)**:
  ```bash
  sudo cz-ui-mode czctl       # Primary Kali Cyberdeck Shell (default)
  sudo cz-ui-mode applaunch   # Stock M5Stack APPLaunch carousel (includes "Kali Deck" card to return)
  cz-ui-mode status           # Show active LCD owner, Stealth Mode, and Web KVM state
  ```

---

## Composite USB-C OTG Arsenal, Wireless & HDMI

### USB-C OTG Gadget & BadUSB (`cz-usb-gadget` / `cz-badusb`)

Connect the USB-C OTG port to a host or target. Composite modes keep `usb0` (`10.55.0.1/24` with point-to-point DHCP `--dhcp-option=3 --dhcp-option=6`) online alongside HID, MTP, or storage:

```bash
sudo cz-usb-gadget combo                            # usb0 (10.55.0.1/24) + /dev/hidg0 BadUSB HID
sudo cz-usb-gadget mtp                              # usb0 + MTP (/home/kali, isos, payloads) + ttyGS0
sudo cz-usb-gadget create-loot 64                   # Create 64 MB FAT32 loot image in ~/isos/
sudo cz-usb-gadget loot ~/isos/kali-loot-64m.img    # usb0 + read-write USB flash drive
sudo cz-usb-gadget iso ~/isos/netboot.iso           # usb0 + read-only bootable USB CD-ROM/drive
sudo cz-usb-gadget net                              # usb0 Ethernet only (ssh kali@10.55.0.1 | :8899)
sudo cz-usb-gadget hid                              # /dev/hidg0 USB HID keyboard only
sudo cz-usb-gadget off                              # Tear down gadget & return mux to USB Host mode

# Fire DuckyScript 1.0 payloads (auto-enables combo mode so SSH/:8899 stay reachable):
cz-badusb ~/payloads/01-linux-recon-terminal.duck
cz-badusb --menu
```

### Wireless, Monitor Mode & Kali Toolsets

- **Onboard `wlan0` (2.4 GHz)**: join networks from `Idle -> [4] WiFi`, `nmtui`, or `nmcli dev wifi connect "<SSID>" password "<PASS>"`.
- **External USB Wi-Fi Monitor/Injection (`wlan1`)**: plug a supported adapter (`RTL8812AU`/`RTL8821AU` via [`rtl8812au`](https://github.com/aircrack-ng/rtl8812au) `88XXau.ko`, `MT7612U`, `AR9271`) into USB-A and open `Wi-Fi Recon` or run `sudo monstart` / `sudo wifite` / `sudo monstop`.
- **Kali Metapackages & [`zero2zero`](https://github.com/on-my-machine-works/zero2zero) (`cz-kali-pkgs`)**:
  ```bash
  sudo cz-kali-pkgs install wireless   # kali-tools-802-11 + bluetooth + rfid (~2 GB)
  sudo cz-kali-pkgs install top10      # kali-tools-top10 (~3 GB)
  sudo cz-kali-pkgs install headless   # kali-linux-headless (~10 GB, 32 GB+ SD)
  sudo cz-kali-pkgs install default    # kali-linux-default (~15 GB, 32 GB+ SD)
  sudo cz-kali-pkgs install zero2zero  # Flipper Zero BLE companion (~140 KB, SHA-256 verified)
  ```
  Running `sudo apt update && sudo apt full-upgrade` is safe: the Raspberry Pi CM0 kernel, `raspi-firmware`, and wireless firmware are APT-pinned and held so upgrades never break out-of-tree M5Stack drivers.

### On-Demand HDMI LXDE Desktop (`cz-hdmi-hotplug`)

The 1.9" SPI LCD and Mini-HDMI run independently: `czctl` keeps the internal `TCA8418` keypad isolated on `seat1` while HDMI runs a full Kali LXDE session. When Mini-HDMI is unplugged, `lightdm` stays stopped (saving ~75-90 MiB RAM) and starts automatically on hotplug (`cz-hdmi-hotplug status|auto|always|off`).

---

## Hardware Support

Board support combines [Raspberry Pi Linux](https://github.com/raspberrypi/linux) (`6.18.39+rpt-rpi-v8`), out-of-tree drivers and Device Tree overlays from [`m5stack-linux-dtoverlays`](https://github.com/m5stack/m5stack-linux-dtoverlays), and audio/display/APT configuration from [`CardputerZero/pi-gen`](https://github.com/CardputerZero/pi-gen):

| Subsystem | Hardware / Bus | Kernel Driver(s) & Firmware | User-Space |
| :--- | :--- | :--- | :--- |
| **SoC & Boot** | Raspberry Pi CM0 Lite (`RP3A0` / `BCM2837`, Cortex-A53 `arm64`, 512 MB LPDDR2) | `bcm2710-rpi-cm0.dtb`, `raspi-firmware`, Linux `6.18.39+rpt-rpi-v8` (`apt-mark hold`), `zstd` ZRAM (75%) | `ext4` (`noatime`), `cz-firstboot-resize`, SSH host keygen, strict ARMv8.0 LSE gate |
| **1.9" IPS LCD** | `ST7789v3` `320x170` RGB565 on SPI0 CS0 (`GPIO25` DC) + `M5IOE1` PWM3 backlight | `panel-mipi-dbi-m.ko`, `st7789v_m5stack.ko`, `pwm_bl_m5stack.ko`, `cardputerzero,st7789v_lcd.bin`, `fb_load.service` | `czctl` DRM/KMS shell + headless `sway` Wayland host + `/dev/fb_lcd` (`cz-term`, `APPLaunch`), `fbcon=map:99` |
| **HDMI Output** | VideoCore IV KMS (`vc4-kms-v3d,cma-64`) | `vc4`, `98-vc4-no-glamor.conf`, `zz-cardputerzero-hdmi-display.rules`, `91-cz-hdmi-hotplug.rules` | On-demand LightDM + LXDE (`cz-hdmi-hotplug`), `fb-mirror.py` LCD mirror, `VT2`-`VT6` consoles |
| **46-Key Keypad + LEDs** | `TCA8418` (`0x34` I2C1, IRQ `GPIO27`) + Caps/Fn/Tab LEDs on `M5IOE1` | `tca8418_keypad_m5stack.ko` (`cardputerzero-v5-overlay.dtbo`) | Isolated on `seat1` (`72-seat-cardputer-czctl.rules`, Xorg `Ignore`), `tty1` masked, `/dev/uinput` Web KVM |
| **Audio** | Everest `ES8389` (`0x10` I2C1 + I2S), 1W speaker (`GPIO24`), mic, 3.5mm jack detect (`GPIO17`) | `es8389_m5stack.ko`, `simple-amplifier.ko`, `cardputerzero-audio.ko` | PipeWire + WirePlumber + RTKit (`Voice Recorder`, `Internet Radio`, ES8389 prioritized over HDMI) |
| **Onboard Wi-Fi** | `BCM43439` / `CYW4343A2` SDIO (`wlan0`, 2.4 GHz) | `brcmfmac` + CM0 `cyfmac43439-sdio.txt` (`boardflags3=0x04000000`, `nexmon` excluded) | `NetworkManager`, `czctl` Wi-Fi UI, `Wi-Fi Recon`, `WiFiScan` |
| **USB Wireless** | USB-A Host / USB-C OTG (`wlan1`) | Patched `realtek-rtl88xxau-dkms` (`88XXau.ko` on Linux 6.18, USB hotplug) + `atheros` / `mediatek` / `realtek` firmware | `Wi-Fi Recon`, `WiFiScan`, `monstart` / `monstop`, `aircrack-ng`, `wifite`, `hcxdumptool`, `kismet`, `bettercap` |
| **Bluetooth 5.0** | `BCM4343A2` HCI UART (`/dev/serial1` -> `ttyAMA0`) | `BCM4343A2.raspberrypi,0-compute-module.hcd`, `pi-bluetooth` (`btuart` / `hciuart.service`) | `bluez` (`AutoEnable=false` at boot), `Bluetooth & BLE`, `BT/USB HID Pad` (BLE HID over GATT) |
| **CSI Camera** | Sony `IMX219` 8 MP (`dtoverlay=imx219`, `camera_auto_detect=0`) | `imx219`, `unicam`, `/dev/dma_heap/vidbuf_cached` (`60-dma-heap.rules`) | SONAME-matched `/opt/rpi-libcamera` (`libcamera.so.0.7` + `ipa_rpi_vc4.so`) + `/dev/fb_lcd` `camera_app` wrapper |
| **Battery & Power** | TI `BQ27220` (`0x55` I2C1) / `ETA6965` + power-fail shutdown (`GPIO6`) | `bq27xxx_battery.ko`, `bq27xxx_battery_i2c.ko` (`bq27220_v5.dtbo`), `powerfail_suo.ko`, `i2c-dev` | `/sys/class/power_supply/`, `czctl` Battery Info, `cz-hw-status` |
| **IMU + Mag** | Bosch `BMI270` (`0x68` I2C1) + `BMM150` | `bmi270_core.ko`, `bmi270_i2c.ko`, `bmc150_magn.ko`, `bmc150_magn_bmi270.ko`, `bmi270-init-data.fw` | `/sys/bus/iio/devices/iio:device*`, M5 `Compass` |
| **RTC** | Epson `RX8130CE` (`0x32` I2C1) | `rtc-ds1307` (`epson,rx8130`), udev `hwclock --hctosys` at boot | `/dev/rtc0` (`hwclock -r` / `hwclock -w`) |
| **Infrared** | IR TX (`GPIO12`) + IR RX (`GPIO13`) | `gpio-ir-tx` & `gpio-ir` (`/dev/lirc0`, `/dev/lirc1`, group `video`) | `IR Arsenal` (LIRC TX/RX + `~/ir/tv-universal.ir`), `ir-ctl`, M5 `IR Remote` & `IR Chat` |
| **USB OTG + Power Mux** | `dwc2` USB 2.0 OTG + `M5IOE1` (`0x4f` I2C1) | `m5ioe1.ko`, `libcomposite`, `/sys/class/leds/{ext_usb_gpio_fun,ext_5v_out,grove_5v_out,grove_fun}` | `USB Arsenal`, `cz-usb-gadget` / `cz-flipper-gadget`, `cz-badusb`, `umtprd` MTP, `czctl` 5V/mux toggles |
| **14-Pin Cap & Grove** | SPI0 (`CS1` + `GPIO22` `CS2`), UART0 (`/dev/ttyS0`), I2C1, GPIO + PWM | `gpio-forwarder.ko`, `spi0-spidev2-gpio22-overlay.dtbo`, `raspi-utils-dt`, [`pigpio`](https://github.com/joan2937/pigpio) (`pigpiod`) | LoRa `SX1262` + `ATGM336H` GNSS (`gpsd.socket` on `/dev/ttyS0`), `CC1101` Sub-GHz + NFC (`libnfc`, `mfoc`, `mfcuk`) |

---

## Build from Source & Live Deployment

Building follows the [Kali custom Raspberry Pi image](https://www.kali.org/docs/development/custom-raspberry-pi-image/) layout on a Debian, Ubuntu, or Kali host (~15 GB free disk space). APT indices and M5Stack sources are verified against PGP `InRelease` metadata and [`upstream.lock.json`](upstream.lock.json), and every Cortex-A53 binary is audited via `objdump -d` to reject unguarded ARMv8.1+ LSE instructions.

```bash
sudo apt update && sudo apt install -y \
  parted dosfstools e2fsprogs btrfs-progs util-linux rsync xz-utils zstd binutils \
  dpkg curl git ca-certificates device-tree-compiler python3 mmdebstrap debootstrap \
  zerofree build-essential pkg-config cargo rustc \
  libudev-dev libdrm-dev libgbm-dev libwayland-dev libxkbcommon-dev \
  libfontconfig1-dev libpulse-dev libmp3lame-dev libogg-dev libvorbis-dev

# Only needed when cross-building on x86_64:
sudo apt install -y qemu-user-static binfmt-support arch-test \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu
rustup target add aarch64-unknown-linux-gnu   # if using rustup

# Build default ext4 image (zerofree-compacted) -> output/kali-cardputerzero-arm64.img.xz:
sudo ./build-kali-cardputerzero.sh

# Optional: strict lockfile mode or experimental Btrfs multi-profile mode:
sudo M5_UPDATE_MODE=locked ./build-kali-cardputerzero.sh
sudo ROOT_FS=btrfs ./build-kali-cardputerzero.sh
```

*(Optional `ROOT_FS=btrfs` builds adapt subvolume profile helpers from [`flipperos-btrfs-tools`](https://github.com/flipperdevices/flipperos-btrfs-tools) and [`flipperone-linux-build-scripts`](https://github.com/flipperdevices/flipperone-linux-build-scripts).)*

### Flash, Pre-Seed SSH Key, or Deploy Live Over SSH

```bash
# Flash directly with root-disk safety checks, and optionally pre-seed an SSH key:
sudo FLASH_DEV=/dev/sdX ./build-kali-cardputerzero.sh flash
sudo DEPLOY_SSH_DEV=/dev/sdX DEPLOY_SSH_PUBKEY=~/.ssh/id_ed25519.pub ./build-kali-cardputerzero.sh deploy-ssh

# Deploy czctl, Wayland apps, C utilities, OTG tools & camera fix live to a running unit:
./scripts/deploy-live.sh kali@<cardputer-ip>

# Run UI token checks, Rust workspace tests, and standalone C checks:
sh shell/ci/no-raw-colours.sh
CARGO_PROFILE_TEST_DEBUG=0 cargo test --manifest-path shell/Cargo.toml --workspace
./scripts/build-cz-shell.sh
make -C src && make -C src check
```

---

## Repository Layout

- [`build-kali-cardputerzero.sh`](build-kali-cardputerzero.sh): stage-resumable ARM64 image builder (`ROOT_FS=ext4|btrfs`, `DEFAULT_UI=czctl|applaunch`), 247-check hardware/ABI/LSE verifier, SD flasher, and SSH key installer.
- [`shell/`](shell/): Rust/Slint workspace for `czctl`, `:8899` Web KVM, headless `sway` Wayland host, `kali-usb-deck`, `cz-boot-menu`, and 5 native Wayland apps (`sysmon`, `recorder`, `radio`, `disk-benchmark`, `usb-keyboard-touchpad`).
- [`overlays/`](overlays/): Wayland `.fap.sh` app launchers (`apps/`), BadUSB `.duck` & IR `.ir` payloads (`payloads/`), Ed25519 OTA public key (`ota/ota-pub.pem`), `umtprd.conf` (`etc/umtprd/`), `czctl.service`, `cz-stealth.service` & `seat1` udev rules (`systemd/`), and optional Btrfs/router overlays.
- [`src/`](src/): `320x170` C utilities (`cz-term.c` ProFont terminal, `cz-wifiscan.c`, `cz-term80.c`, `cz-sysmon.c`, `cz-lanscan.c`, `cz-pktsniff.c`, `cz-usbgadget.c`) and `libcz_fb_lcd.c` framebuffer shim.
- [`scripts/`](scripts/): Cortex-A53 shell builder (`build-cz-shell.sh`), signed OTA bundle builder (`build-ota-bundle.sh`), upstream lockfile resolver (`resolve-upstream.py` + `upstream.lock.json`), launcher patcher (`configure-kali-launcher.py`), splash generator (`gen-kali-splash.py`), live SSH deployer (`deploy-live.sh`), and on-device tools (`cz-ota`, `cz-stealth`, `cz-cap-uart`, `cz-ui-mode`, `cz-usb-gadget`, `cz-flipper-gadget`, `cz-badusb`, `cz-kali-menu`, `cz-kali-pkgs`, `cz-hdmi-hotplug`, `cz-hw-status`).

## Shout-Out

Big shout-out to the **Flipper One** project at Flipper Devices for establishing a clean, well-engineered handheld Linux foundation (`flipctl-slint`, `flipperone-linux-build-scripts`, and `flipperos-btrfs-tools`). Its token-driven panel UI, `:8899` browser KVM design, Wayland app hosting model, and pixel fonts made `czctl` on the CardputerZero possible, alongside the work of the M5Stack / CardputerZero, Kali Linux, and Raspberry Pi communities.

## License & Attribution

- **Repository Source Code (`MIT`)**: build scripts, C utilities, and `shell/` / `overlays/` source files are licensed under the MIT License (`LICENSE`, [`shell/LICENSE`](shell/LICENSE), and [`overlays/btrfs-tools/LICENSE`](overlays/btrfs-tools/LICENSE)), with portions adapted from `flipctl-slint` and `flipperos-btrfs-tools` (Copyright 2026 Flipper Devices).
- **Compiled `czctl` & Slint Wayland Binaries (`GPL-3.0-only`)**: prebuilt binaries statically link Slint under the **GPL-3.0-only** arm of Slint's license ([`shell/LICENSES/GPL-3.0-only.txt`](shell/LICENSES/GPL-3.0-only.txt); crate notices in [`shell/THIRD-PARTY-LICENSES.md`](shell/THIRD-PARTY-LICENSES.md)).
- **Fonts & Boot Helper Notices**:
  - **HaxrCorp 4090 (FlipCTL)** (`title.rs`, adapted from [HaxrCorp 4089](https://fontstruct.com/fontstructions/show/192981/haxrcorp_4089) by `sahwar` and Flipper Devices): `CC-BY-SA-3.0` ([`shell/third_party/flipctl-fonts/HaxrCorp4090-FlipCTL/LICENSE`](shell/third_party/flipctl-fonts/HaxrCorp4090-FlipCTL/LICENSE)).
  - **Busy9px** (`MIT`), **Born2bSportyV2** (`Unlicense`), and **ProFont** (`MIT`, [`src/fonts/LICENSE-ProFont.txt`](src/fonts/LICENSE-ProFont.txt)).
  - **Optional BLS Staging Helper** ([`overlays/btrfs-tools/libs/flipper-bls.sh`](overlays/btrfs-tools/libs/flipper-bls.sh), derived from [systemd](https://github.com/systemd/systemd)): `LGPL-2.1-or-later`.
- **System Image Packages & Firmware**: built microSD images aggregate packages, kernel modules, and firmware from Kali Linux, Debian, Raspberry Pi, and M5Stack under their respective upstream licenses (`GPL-2.0`, `GPL-3.0`, `LGPL-2.1`, `BSD-3-Clause`, `MIT`, `Unlicense`, and hardware firmware redistribution terms).
