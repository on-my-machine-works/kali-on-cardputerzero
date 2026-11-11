# Kali Linux for M5Stack CardputerZero (`arm64`)

[![Latest Release](https://img.shields.io/github/v/release/on-my-machine-works/kali-on-cardputerzero?label=release)](https://github.com/on-my-machine-works/kali-on-cardputerzero/releases/latest)
[![Weekly Image Release](https://github.com/on-my-machine-works/kali-on-cardputerzero/actions/workflows/build.yml/badge.svg)](https://github.com/on-my-machine-works/kali-on-cardputerzero/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Reproducible **Kali Linux Rolling (`arm64`)** microSD image and build pipeline for the **M5Stack CardputerZero** handheld computer (Raspberry Pi Compute Module Zero Lite / `RP3A0` / Hardware Rev `v5`).

Built on the [Kali Linux Custom Raspberry Pi Image](https://www.kali.org/docs/development/custom-raspberry-pi-image/) workflow (`mmdebstrap`/`debootstrap` -> sparse MBR `FAT32` + `ext4` image -> loop-mount chroot -> CM0 bootloader & Raspberry Pi `rpt-rpi-v8` kernel -> out-of-tree M5Stack hardware drivers & Device Tree overlays -> native `320x170` LCD utilities & `APPLaunch` integration).

---

## Quick Start

### Option 1: Flash Prebuilt Release Image *(Recommended)*

1. Download `kali-cardputerzero-arm64.img.xz` and `kali-cardputerzero-arm64.img.xz.sha256` from [**Releases**](https://github.com/on-my-machine-works/kali-on-cardputerzero/releases/latest).
2. Flash to a **16 GB+ microSD card**:
   - **GUI**: **Raspberry Pi Imager** (*Choose OS -> Use custom*, and **skip OS customization** so `config.txt` / `cmdline.txt` remain intact) or **BalenaEtcher**.
   - **CLI (Linux / macOS)**:
     ```bash
     sha256sum -c kali-cardputerzero-arm64.img.xz.sha256
     xzcat kali-cardputerzero-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
     sync
     ```
3. Insert the microSD card and power on (first boot automatically expands the root filesystem). Default login: **`kali` / `kali`**.

### Option 2: Build From Source

[`build-kali-cardputerzero.sh`](build-kali-cardputerzero.sh), [`upstream.lock.json`](upstream.lock.json), [`src/`](src), and [`scripts/`](scripts) are self-contained—all Kali, Raspberry Pi, Debian, and M5Stack packages/commits are resolved and cryptographically verified automatically into `cache/`.

```bash
# 1. Install host prerequisites (Debian / Ubuntu / Kali — ~15 GB free disk space)
sudo apt update && sudo apt install -y \
  parted dosfstools e2fsprogs util-linux rsync xz-utils zstd binutils \
  dpkg curl git ca-certificates device-tree-compiler python3 \
  mmdebstrap debootstrap zerofree

# (On x86_64 hosts only, also install ARM64 binfmt emulation:)
sudo apt install -y qemu-user-static binfmt-support arch-test

# 2. Build, verify, finalize & compress:
sudo ./build-kali-cardputerzero.sh
```
Output is written to `output/kali-cardputerzero-arm64.img.xz` (+ `.img` and `.sha256`). To build or test only the native `320x170` C utilities standalone, run `make -C src && make -C src check`.

---

## 1. Hardware Support Matrix

Every onboard component and expansion bus of the CardputerZero is configured and verified out of the box:

| Subsystem | Hardware / Bus | Kernel Driver(s) & Firmware | User-Space Integration |
| :--- | :--- | :--- | :--- |
| **SoC & Boot** | Raspberry Pi CM0 Lite (`RP3A0` / `BCM2837`, Quad Cortex-A53 `arm64`, 512 MB LPDDR2) | `bcm2710-rpi-cm0.dtb`, `raspi-firmware`, Linux **`6.18.39+rpt-rpi-v8`** (`apt-mark hold` + APT-pinned), `zstd` ZRAM (75%) | First-boot rootfs auto-expand (`cz-firstboot-resize`) & SSH host keygen |
| **1.9" IPS LCD + Backlight** | `ST7789v3` **320x170** RGB565 on SPI0 CS0 (`GPIO25` DC) + `M5IOE1` PWM3 Backlight | `panel-mipi-dbi-m.ko`, `st7789v_m5stack.ko`, `pwm_bl_m5stack.ko`, `cardputerzero,st7789v_lcd.bin`, `fb_load.service` | `/dev/fb_lcd` (`320x170` px; `APPLaunch` PTY `45x10` + `Term80x24` `80x24`), Kali Dragon boot splash & lockscreen, `fbcon=map:99` |
| **Full-Size HDMI Output** | VideoCore IV KMS (`vc4-kms-v3d,cma-64`) | `vc4`, `98-vc4-no-glamor.conf` (saves 64 MB CMA), `zz-cardputerzero-hdmi-display.rules` | Independent **LightDM + LXDE** Kali desktop on HDMI + `fb-mirror.py` LCD mirror + `VT2..VT6` consoles |
| **46-Key Matrix Keyboard + LEDs** | `TCA8418` (`0x34` on I2C1, IRQ `GPIO27`) + Caps/Fn/Tab LEDs on `M5IOE1` | `tca8418_keypad_m5stack.ko` (3-layer keymap in `cardputerzero-v5-overlay.dtbo`) | Isolated on `seat1` (`99-ignore-i2c-key.rules` + Xorg `Ignore`) & `tty1` masked; bottom softkeys aligned to physical `4`–`8` keys |
| **Audio Codec, Speaker, Mic & 3.5mm Jack** | Everest `ES8389` (`0x10` I2C1 + I2S), 1W Speaker (`GPIO24`), MEMS Mic, 3.5mm TRS Detect (`GPIO17`) | `es8389_m5stack.ko`, `simple-amplifier.ko`, `cardputerzero-audio.ko` (auto speaker mute & mic switch on jack plug) | **PipeWire + WirePlumber + RTKit** (`50-cardputerzero-default-volume.conf` @ 60%, ES8389 prioritized over HDMI) |
| **2.4 GHz Wi-Fi** | `BCM43439` / `CYW4343A2` SDIO (`wlan0`) | `brcmfmac` + RPi CM0 `cyfmac43439-sdio.txt` (`boardflags3=0x04000000`; `nexmon` excluded) | `NetworkManager` (`nmcli` / `nmtui` / `WiFiScan` / `APPLaunch -> Settings -> Wi-Fi`) |
| **External USB Wireless** | USB-A Host / USB-C OTG (`wlan1`) | Patched `realtek-rtl88xxau-dkms` (`88XXau.ko` for Linux 6.18) + `atheros` / `mediatek` / `realtek` firmware | `WiFiScan`, `monstart` / `monstop`, `aircrack-ng`, `wifite`, `hcxdumptool`, `kismet`, `bettercap`, `mdk4`, `reaver` |
| **Bluetooth 5.0 / BLE** | `BCM4343A2` HCI UART (`/dev/serial1` -> `ttyAMA0`) | `BCM4343A2.raspberrypi,0-compute-module.hcd`, `pi-bluetooth` (`btuart` / `hciuart.service`), unblocked `rfkill` | `bluez`, `bluetoothctl`, `APPLaunch -> Settings -> Bluetooth` |
| **8 MP CSI Camera** | Sony `IMX219` (`dtoverlay=imx219`, `camera_auto_detect=0`) | `imx219`, `unicam`, `/dev/dma_heap/vidbuf_cached` (`60-dma-heap.rules`) | Kali `libcamera` + isolated `/opt/rpi-libcamera` runtime wrapper for M5 `Camera` |
| **Battery Fuel Gauge & Power** | TI `BQ27220` (`0x55` I2C1) / `ETA6965` + Power-Fail Shutdown (`GPIO6`) | `bq27xxx_battery.ko`, `bq27xxx_battery_i2c.ko` (`bq27220_v5.dtbo`), `powerfail_suo.ko`, `i2c-dev` | `/sys/class/power_supply/`, `APPLaunch` & native Kali app battery indicator, `cz-hw-status` |
| **9-Axis IMU + Magnetometer** | Bosch `BMI270` (`0x68` I2C1) + `BMM150` | `bmi270_core.ko`, `bmi270_i2c.ko`, `bmc150_magn.ko`, `bmc150_magn_bmi270.ko`, `bmi270-init-data.fw` | `/sys/bus/iio/devices/iio:device*`, M5 `Compass` app |
| **Hardware RTC** | Epson `RX8130CE` (`0x32` I2C1, coin-cell backed) | `rtc-ds1307` (`epson,rx8130`), udev rule auto-syncs `hwclock --hctosys` at boot | `/dev/rtc0` (`hwclock -r` / `hwclock -w`) |
| **Infrared TX & RX** | IR LED TX (`GPIO12`) + IR Receiver (`GPIO13`) | `gpio-ir-tx` & `gpio-ir` (`lirc` devices `/dev/lirc0` & `/dev/lirc1`, mode `0660` group `video`) | `ir-ctl`, M5 `IR Remote` & `IR Chat` |
| **USB OTG / Host + Power Mux** | `dwc2` USB 2.0 OTG + `M5IOE1` (`0x4f` I2C1) | `m5ioe1.ko`, `libcomposite`, `/sys/class/leds/{ext_usb_gpio_fun,ext_5v_out,grove_5v_out,grove_fun}` | `USBGadget` GUI (`cz-usbgadget`) + `cz-usb-gadget {net\|hid\|combo\|off\|status}`, `APPLaunch` OTG/5V/ADB toggles |
| **14-Pin Cap Bus & Grove HY2.0** | SPI0 (`CS1` + `GPIO22` forwarded `CS2`), UART0 (`/dev/ttyS0`), I2C1, GPIO + PWM | `gpio-forwarder.ko`, `spi0-spidev2-gpio22-overlay.dtbo`, `raspi-utils-dt` (`dtoverlay`), `pigpiod` | LoRa `SX1262` + `ATGM336H` GNSS (`gpsd.socket` on `/dev/ttyS0`, no serial getty), `CC1101` Sub-GHz + NFC (`libnfc`, `mfoc`, `mfcuk`) |

---

## 2. Repository Layout

- [`build-kali-cardputerzero.sh`](build-kali-cardputerzero.sh) — Stage-resumable Kali ARM64 image builder, verifier, SD flasher, and SSH key deployer.
- [`upstream.lock.json`](upstream.lock.json) — Verified lockfile for M5Stack kernel manifests, driver commits, and `.deb` releases used for per-component fallback.
- [`scripts/resolve-upstream.py`](scripts/resolve-upstream.py) — Resolves `InRelease`-verified Kali/RPi/Debian APT packages and validates M5Stack upstream updates with automatic fallback to `upstream.lock.json`.
- [`src/Makefile`](src/Makefile) — Standalone build, `320x170` headless render self-test (`make check`), and `install` rules for the native C apps and framebuffer shim.
- [`src/cz_ui.h`](src/cz_ui.h) — Shared `320x170` RGB565 framebuffer UI toolkit with `st_rdev`-deduplicated `evdev` input, battery/clock header, and physical **`4`–`8` bottom softkey bar** (`x = 48, 104, 160, 216, 272` px).
- [`src/cz-wifiscan.c`](src/cz-wifiscan.c) — **`WiFiScan`**: Native `320x170` wireless AP analyzer, 2.4G/5G channel occupancy graph, `wlan0`/`wlan1` switcher, and `monstart`/`monstop` toggle.
- [`src/cz-term80.c`](src/cz-term80.c) — **`Term80x24`**: Native `80x24` (`4x7` cell) `xterm-256color`/truecolor PTY terminal emulator for full-screen TUIs (`btop`, `htop`, `kismet`, `nmtui`, `tmux`) on the 1.9" LCD.
- [`src/cz-sysmon.c`](src/cz-sysmon.c) — **`SysMon`**: Native `320x170` CPU/RAM/ZRAM/SD sparkline monitor, battery & 5V rail switcher, live interface throughput, and process table.
- [`src/cz-lanscan.c`](src/cz-lanscan.c) — **`LanScan`**: Native `320x170` subnet host discovery (`arp-scan` / `nmap -sn`) and one-key top-100 TCP port inspector.
- [`src/cz-pktsniff.c`](src/cz-pktsniff.c) — **`PktSniff`**: Native `320x170` live `tcpdump` packet ticker, protocol counters (`TCP/UDP/DNS/ARP/EAPOL`), BPF filter cycling, and `.pcap` capture to `/home/kali/captures/`.
- [`src/cz-usbgadget.c`](src/cz-usbgadget.c) — **`USBGadget`**: Native `320x170` USB-C OTG gadget switcher (`NET` `10.55.0.1/24`, `HID` `/dev/hidg0`, `COMBO`, `HOST/OFF`) with live IPs and scannable SSH QR code.
- [`src/libcz_fb_lcd.c`](src/libcz_fb_lcd.c) — `LD_PRELOAD` `/dev/fb0` -> `/dev/fb_lcd` redirect helper (`/usr/lib/cz-kali/libcz_fb_lcd.so`).
- [`scripts/configure-kali-launcher.py`](scripts/configure-kali-launcher.py) — Generates `100x100` PNG icons, `.desktop` files, `/usr/share/APPLaunch/preinstalled-desktop-apps.tsv`, `/home/kali/.config/cardputerzero/config.json`, and patches `APPLaunch`'s carousel sort comparator.
- [`scripts/gen-kali-splash.py`](scripts/gen-kali-splash.py) — Generates the transposed `170x320` RGB565 Kali Dragon `/boot/firmware/splash.bmp` for `fb_load` plus `320x170` `logo_lcd.png` and `320x150` `lockscreen.png`.
- [`scripts/cz-kali-menu`](scripts/cz-kali-menu) — Quick-launch TUI menu formatted for `APPLaunch`'s `45x10` character grid (`KaliMenu`).
- [`scripts/cz-kali-pkgs`](scripts/cz-kali-pkgs) — Interactive `45x10`-compatible Kali metapackage & toolset installer (`KaliPkgs` / `kali-tweaks` launcher, free-space guard, and CM0 kernel/RAM service safeguards).
- [`scripts/cz-usb-gadget`](scripts/cz-usb-gadget) — Runtime USB-C OTG Host <-> Gadget switcher (`net`, `hid`, `combo`, `off`, `status`).
- [`scripts/cz-hw-status`](scripts/cz-hw-status) — Live CardputerZero hardware & bus status inspector.
- [`scripts/deploy-live.sh`](scripts/deploy-live.sh) — Live over-SSH deployment script to update the native `320x170` Kali apps, launcher configuration, and branding on a running CardputerZero without reflashing.
- `output/` — Generated raw and compressed disk images:
  - `kali-cardputerzero-arm64.img`
  - `kali-cardputerzero-arm64.img.xz`
  - `kali-cardputerzero-arm64.img.sha256`

---

## 3. Flashing & Live Deployment

### Flash to microSD Card (16 GB+ recommended)

Using `xzcat` + `dd` on Linux/macOS:
```bash
xzcat output/kali-cardputerzero-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```
Or directly via the build script (includes safety checks preventing host root disk overwrite):
```bash
sudo FLASH_DEV=/dev/sdX ./build-kali-cardputerzero.sh flash
# Optional: pre-seed an SSH public key onto the card before booting:
sudo DEPLOY_SSH_DEV=/dev/sdX DEPLOY_SSH_PUBKEY=~/.ssh/id_ed25519.pub ./build-kali-cardputerzero.sh deploy-ssh
```
You can also flash `kali-cardputerzero-arm64.img.xz` using **Raspberry Pi Imager** (*Use custom*, **skip OS customization** so `config.txt`/`cmdline.txt` are preserved) or **BalenaEtcher**.

### Live Over-SSH Deployment (Update a Running Device)
```bash
./scripts/deploy-live.sh kali@<cardputer-ip>
```

### Default Credentials
- **Username**: `kali`
- **Password**: `kali` (passwordless `sudo` enabled)
- **Hostname**: `kali-cardputerzero` (`ssh kali@kali-cardputerzero.local`)

> [!IMPORTANT]
> Matching official Kali Linux ARM images, the SSH server and passwordless `sudo` are enabled out of the box with the default credentials `kali` / `kali`. Run `passwd` on first login (and optionally disable password SSH logins in `/etc/ssh/sshd_config`) before connecting to untrusted networks.

---

## 4. Launcher Layout & App Configuration

### Default Home Carousel Order
`APPLaunch` opens with slot `[2]` centered (`slots [0..4]` visible across the 320px home screen), ordering the Kali utilities first followed by M5 hardware and system apps:

1. `[0]` **`WiFiScan`** (`cz-wifiscan`) — Keys `4:SCAN`, `5:VIEW`, `6:IFACE`, `7:MON`, `8:EXIT`
2. `[1]` **`Term80x24`** (`cz-term80`) — Full `80x24` terminal (`btop`, `htop`, `kismet`, `nmtui`, `tmux`); hold `ESC` 1.2s or `Ctrl+Alt+Q` to exit
3. `[2]` **`KaliZsh`** — Interactive Kali Zsh login shell (`45x10` large-font terminal, centered on boot)
4. `[3]` **`KaliMenu`** (`cz-kali-menu`) — Quick-key TUI (`nmap`, `nmcli`, `btop 80x`, `monstart`, `wifite`, `bettercap`, `bluetooth`, `gps`, `5V`, `gadget`)
5. `[4]` **`SysMon`** (`cz-sysmon`) — Keys `4:SYS`, `5:NET/HW`, `6:TOP`, `7:REFRESH/5V/SORT`, `8:EXIT`
6. `[5]` **`LanScan`** (`cz-lanscan`) — Keys `4:DISCOVER`, `5:PORTS`, `6:UP`, `7:DOWN`, `8:EXIT`
7. `[6]` **`PktSniff`** (`cz-pktsniff`) — Keys `4:START/PAUSE`, `5:IFACE`, `6:FILTER`, `7:PCAP`, `8:EXIT`
8. `[7]` **`USBGadget`** (`cz-usbgadget`) — Keys `4:NET`, `5:HID`, `6:COMBO`, `7:HOST/OFF`, `8:EXIT`
9. `[8]` **`KaliPkgs`** (`cz-kali-pkgs`) — Kali metapackage & toolset installer (`wireless`, `top10`, `sniff`, `hardware`, `webpass`, `headless`, `default`, plus `kali-tweaks` in `80x24`)
10. Followed by M5 system & hardware utilities: `Settings`, `Store`, `CLI`, `SSH`, `IP Panel`, `Camera`, `IR Remote`, `IR Chat`, `Compass`, `Rec`, `Files`, `LoRa`, `GPS`, `NFC`, `SubG Chat`. Built-in sample items (`Python`, `Snake`, `Tank`, `Calculator`) default to hidden and remain toggleable in `Settings -> Launcher`.

### Toggling Apps On/Off
Every preinstalled Kali and M5 main menu item is registered in `/usr/share/APPLaunch/preinstalled-desktop-apps.tsv` and seeded in `/home/kali/.config/cardputerzero/config.json` (`1000:1000`), so any item can be toggled directly from **`Settings -> Launcher`** on the device (or by setting `"app_desktop_...": 0` / `1` in `~/.config/cardputerzero/config.json`).

---

## 5. User Guide: LCD, HDMI Desktop, USB OTG & Wireless

### A. 1.9" LCD & 46-Key Keypad Navigation
- **Home Carousel**: Press `,` / `.` (Left / Right) to cycle cards, `Enter` to launch, and `` ` `` (`ESC`, top-left key) to go back (holding `ESC` for 5 seconds force-returns to `APPLaunch` from any app).
- **Native Kali `320x170` Apps (`WiFiScan`, `SysMon`, `LanScan`, `PktSniff`, `USBGadget`)**: The 5 bottom softkey pills align directly above physical number keys **`4`, `5`, `6`, `7`, `8`** (`8` always exits cleanly back to the launcher).
- **45x10 vs. 80x24 Terminals**:
  - **`KaliZsh`** uses `APPLaunch`'s `45x10` font for everyday shell commands.
  - **`Term80x24`** renders a full **`80x24`** `xterm-256color`/truecolor grid (`4x7` px cells) for full-screen TUIs (`btop`, `htop`, `kismet`, `nmtui`, `tmux`). Hold **`ESC` for 1.2s** (or press `Ctrl + Alt + Q`) to exit back to the launcher.

### B. Full-Size HDMI Desktop
The CardputerZero drives **both** displays simultaneously without conflict: the 1.9" SPI LCD stays on `APPLaunch`, while the full-size HDMI port runs an independent **Kali LXDE** desktop session (auto-logged in as `kali`).

- **Booting with HDMI connected**: Plug in HDMI before powering on and the Kali LXDE desktop starts automatically.
- **Hot-plugging HDMI after boot**: Because Xorg probes connected monitors when `lightdm` starts at boot, if HDMI is connected to an already-running unit, restart `lightdm` in `KaliZsh` (or over SSH) to start the desktop without rebooting:
  ```bash
  sudo systemctl restart lightdm
  ```
- **Controlling the HDMI Desktop**:
  - The built-in 46-key keypad is isolated to the 1.9" LCD (`seat1` / Xorg `Ignore`) so handheld use never sends keystrokes into HDMI windows.
  - Connect a **USB keyboard/mouse** (or 2.4 GHz wireless receiver / USB hub) to the **USB-A port**—or pair a Bluetooth keyboard/mouse—to control the HDMI desktop.
  - Press `Ctrl + Alt + F2`..`F6` on the USB keyboard for full-screen HDMI TTY consoles (`VT2`–`VT6`), and `Ctrl + Alt + F7` to return to LXDE.
- **Mirroring the 1.9" LCD onto HDMI**: Launch **CardputerZero LCD Mirror** (`fb-mirror.py`) from the LXDE application menu to view the 1.9" handheld UI in a live window on the HDMI monitor.
- **Audio Output**: PipeWire defaults to the onboard `ES8389` speaker / 3.5mm jack (`60%` volume, auto-muting the speaker when headphones are plugged in). Switch output to **HDMI Audio** anytime via `pavucontrol` or `wpctl`.

### C. USB-C OTG Gadget Mode (Ethernet-over-USB & USB HID)
Connect the **USB-C OTG** port to a host computer and switch modes either from the **`USBGadget`** launcher app (keys `4:NET`, `5:HID`, `6:COMBO`, `7:OFF`—which also displays a scannable SSH QR code) or from the CLI:
```bash
sudo cz-usb-gadget combo    # Enables BOTH usb0 (10.55.0.1/24) AND /dev/hidg0 USB HID keyboard
sudo cz-usb-gadget net      # Ethernet-over-USB only -> ssh kali@10.55.0.1
sudo cz-usb-gadget hid      # USB HID keyboard (/dev/hidg0) only
sudo cz-usb-gadget off      # Restores normal USB OTG Host mode
sudo cz-usb-gadget status   # Prints current UDC / interface / HID state
```

### D. Onboard Wi-Fi vs. External USB Wireless Adapters
- **Onboard 2.4 GHz Wi-Fi (`wlan0`)**: Connect via **`Settings -> Wi-Fi`** on the launcher, `nmtui` inside `Term80x24`, or `nmcli dev wifi connect "<SSID>" password "<PASS>"`.
- **External USB Wireless (`wlan1`, Monitor Mode & Injection)**: Plug a supported USB adapter (`RTL8812AU`/`RTL8821AU` via pre-patched `88XXau.ko`, `MT7612U`, `AR9271`, etc.) into the USB-A port and toggle monitor mode via **`WiFiScan`** (key `6:IFACE` -> `7:MON`) or CLI:
  ```bash
  sudo monstart          # Auto-selects external wlan1 and enables monitor mode
  sudo wifite            # Or kismet / airodump-ng / hcxdumptool / bettercap
  sudo monstop           # Returns interface to managed mode
  ```

### E. 5V Expansion Rails, Grove, Camera, IR & Caps
- **5V Power Rails (`grove_5v_out` / `ext_5v_out`)**: Toggle power to attached Grove sensors or 14-pin Caps from **`SysMon`** (`5:NET` tab -> key `7`), **`KaliMenu`** (`9`), or **`Settings`**.
- **Hardware & Bus Health Check**: Run `cz-hw-status` in any terminal to inspect CPU temp/throttling, `BQ27220` battery voltage/current, `RX8130CE` RTC, I2C/SPI/IIO sensors, 5V rails, and wireless/Gadget interfaces.

### F. Installing Kali Metapackages (`KaliPkgs` / `cz-kali-pkgs` / `kali-tweaks`)
Launch **`KaliPkgs`** from the home carousel (or press `p` in `KaliMenu`, or run `cz-kali-pkgs` in any shell) to install official Kali metapackages with free-space checks while keeping the CM0 kernel held and heavy server daemons (`apache2`, `mariadb`, `smbd`, etc.) disabled at boot on 512 MB RAM:
```bash
sudo cz-kali-pkgs install wireless   # kali-tools-802-11 + bluetooth + rfid (~2 GB)
sudo cz-kali-pkgs install top10      # kali-tools-top10: metasploit, sqlmap, hydra, john, wireshark... (~3 GB)
sudo cz-kali-pkgs install headless   # kali-linux-headless full CLI suite (~10 GB, 32 GB+ SD recommended)
sudo cz-kali-pkgs install default    # kali-linux-default full suite (~15 GB, 32 GB+ SD recommended)
cz-kali-pkgs                         # Interactive 45x10 menu (also launches kali-tweaks in 80x24)
```

---

## 6. Rebuilding & Upstream Lockfile Modes

On an `arm64` Debian/Ubuntu/Kali host (or `x86_64` host with `qemu-user-static` + `binfmt-support`):

```bash
# Default (M5_UPDATE_MODE=auto): resolves latest APT indices and validates newest
# M5Stack commits/releases, falling back per-component to upstream.lock.json if
# any upstream change breaks compilation, shared libraries, or launcher sort patching:
sudo ./build-kali-cardputerzero.sh

# Reproducible locked M5 build (uses exact M5 commits/packages in upstream.lock.json):
sudo M5_UPDATE_MODE=locked ./build-kali-cardputerzero.sh

# Individual stages during development:
sudo ./build-kali-cardputerzero.sh fetch
sudo ./build-kali-cardputerzero.sh rootfs image kernel drivers packages
sudo ./build-kali-cardputerzero.sh apps launcher boot configs tweaks
sudo ./build-kali-cardputerzero.sh verify
sudo ./build-kali-cardputerzero.sh finalize compress
```

> **Upgrading Packages on Device**: `sudo apt update && sudo apt full-upgrade` is safe to run — the Raspberry Pi kernel, `raspi-firmware`, and CM0 wireless firmware packages are pinned and held so `apt` preserves the out-of-tree CardputerZero `.ko` modules and `wlan0`/`hci0` firmware.

---

## 7. License

- The build scripts, configuration utilities, and native `320x170` C applications in this repository are released under the [**MIT License**](LICENSE).
- Generated microSD images distribute operating system packages, kernel modules, drivers, firmware, and applications from **Kali Linux**, **Debian**, **Raspberry Pi**, and **M5Stack** under their respective upstream licenses (including `GPL-2.0`, `GPL-3.0`, `LGPL`, `BSD-3-Clause`, `MIT`, and redistributable hardware firmware licenses).
