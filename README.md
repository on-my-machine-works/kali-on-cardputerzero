# Kali Linux for M5Stack CardputerZero (`arm64`)

[![Latest Release](https://img.shields.io/github/v/release/on-my-machine-works/kali-on-cardputerzero?label=release)](https://github.com/on-my-machine-works/kali-on-cardputerzero/releases/latest)
[![Image Release](https://github.com/on-my-machine-works/kali-on-cardputerzero/actions/workflows/build.yml/badge.svg)](https://github.com/on-my-machine-works/kali-on-cardputerzero/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Kali Linux Rolling (`arm64`) microSD image and build scripts for the M5Stack CardputerZero (Raspberry Pi Compute Module Zero Lite / `RP3A0`, hardware rev `v5`), based on the [Kali custom Raspberry Pi image](https://www.kali.org/docs/development/custom-raspberry-pi-image/) layout with M5Stack hardware overlays, drivers, `APPLaunch` integration, and `320x170` framebuffer utilities.

## Quick Start

### Flash Prebuilt Image

1. Download `kali-cardputerzero-arm64.img.xz` and `kali-cardputerzero-arm64.img.xz.sha256` from [Releases](https://github.com/on-my-machine-works/kali-on-cardputerzero/releases/latest).
2. Write the image to a 16 GB+ microSD card:
   - **Raspberry Pi Imager / BalenaEtcher**: select *Use custom* and skip OS customization so `config.txt` and `cmdline.txt` are not overwritten.
   - **Linux / macOS CLI**:
     ```bash
     sha256sum -c kali-cardputerzero-arm64.img.xz.sha256
     xzcat kali-cardputerzero-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
     sync
     ```
3. Boot the device. The root partition expands automatically on first boot.

### Default Login

- **User / Password**: `kali` / `kali` (passwordless `sudo` enabled)
- **Hostname**: `kali-cardputerzero` (`ssh kali@kali-cardputerzero.local`)

> [!IMPORTANT]
> Like upstream Kali ARM images, SSH and passwordless `sudo` are enabled by default with `kali` / `kali`. Run `passwd` on first login (and disable password auth in `/etc/ssh/sshd_config` if needed) before joining untrusted networks.

### Build from Source

Building requires a Debian, Ubuntu, or Kali host with ~15 GB free disk space. APT packages and M5Stack sources are fetched into `cache/` and verified against PGP `InRelease` metadata and [`upstream.lock.json`](upstream.lock.json).

```bash
sudo apt update && sudo apt install -y \
  parted dosfstools e2fsprogs util-linux rsync xz-utils zstd binutils \
  dpkg curl git ca-certificates device-tree-compiler python3 \
  mmdebstrap debootstrap zerofree

# Only needed when cross-building on x86_64:
sudo apt install -y qemu-user-static binfmt-support arch-test

sudo ./build-kali-cardputerzero.sh
```

Output images are written to `output/kali-cardputerzero-arm64.img.xz` (plus raw `.img` and `.sha256`).

```bash
# Flash directly with root-disk safety checks, and optionally pre-seed an SSH key:
sudo FLASH_DEV=/dev/sdX ./build-kali-cardputerzero.sh flash
sudo DEPLOY_SSH_DEV=/dev/sdX DEPLOY_SSH_PUBKEY=~/.ssh/id_ed25519.pub ./build-kali-cardputerzero.sh deploy-ssh

# Sync only the C utilities, scripts, and launcher config to a running device over SSH:
./scripts/deploy-live.sh kali@<cardputer-ip>

# Build and self-test only the 320x170 C utilities:
make -C src && make -C src check
```

## Hardware Support

| Subsystem | Hardware / Bus | Kernel Driver(s) & Firmware | User-Space |
| :--- | :--- | :--- | :--- |
| **SoC & Boot** | Raspberry Pi CM0 Lite (`RP3A0` / `BCM2837`, Cortex-A53 `arm64`, 512 MB LPDDR2) | `bcm2710-rpi-cm0.dtb`, `raspi-firmware`, Linux `6.18.39+rpt-rpi-v8` (`apt-mark hold` + APT-pinned), `zstd` ZRAM (75%) | First-boot rootfs resize (`cz-firstboot-resize`), SSH host keygen |
| **1.9" IPS LCD** | `ST7789v3` `320x170` RGB565 on SPI0 CS0 (`GPIO25` DC) + `M5IOE1` PWM3 backlight | `panel-mipi-dbi-m.ko`, `st7789v_m5stack.ko`, `pwm_bl_m5stack.ko`, `cardputerzero,st7789v_lcd.bin`, `fb_load.service` | `/dev/fb_lcd` (`APPLaunch` `45x10` PTY + `Term80x24` `80x24`), boot splash & lockscreen, `fbcon=map:99` |
| **HDMI Output** | VideoCore IV KMS (`vc4-kms-v3d,cma-64`) | `vc4`, `98-vc4-no-glamor.conf`, `zz-cardputerzero-hdmi-display.rules`, `91-cz-hdmi-hotplug.rules` | On-demand LightDM + LXDE (`cz-hdmi-hotplug`), `fb-mirror.py` LCD mirror, `VT2`-`VT6` consoles |
| **46-Key Keypad + LEDs** | `TCA8418` (`0x34` I2C1, IRQ `GPIO27`) + Caps/Fn/Tab LEDs on `M5IOE1` | `tca8418_keypad_m5stack.ko` (`cardputerzero-v5-overlay.dtbo`) | Isolated on `seat1` (`99-ignore-i2c-key.rules`, Xorg `Ignore`), `tty1` masked, softkeys aligned to keys `4`-`8` |
| **Audio** | Everest `ES8389` (`0x10` I2C1 + I2S), 1W speaker (`GPIO24`), mic, 3.5mm jack detect (`GPIO17`) | `es8389_m5stack.ko`, `simple-amplifier.ko`, `cardputerzero-audio.ko` | PipeWire + WirePlumber + RTKit (`50-cardputerzero-default-volume.conf` @ 60%, ES8389 prioritized over HDMI) |
| **Onboard Wi-Fi** | `BCM43439` / `CYW4343A2` SDIO (`wlan0`, 2.4 GHz) | `brcmfmac` + CM0 `cyfmac43439-sdio.txt` (`boardflags3=0x04000000`, `nexmon` excluded) | `NetworkManager` (`nmcli`, `nmtui`, `WiFiScan`, `APPLaunch -> Settings -> Wi-Fi`) |
| **USB Wireless** | USB-A Host / USB-C OTG (`wlan1`) | Patched `realtek-rtl88xxau-dkms` (`88XXau.ko` on Linux 6.18) + `atheros` / `mediatek` / `realtek` firmware | `WiFiScan`, `monstart` / `monstop`, `aircrack-ng`, `wifite`, `hcxdumptool`, `kismet`, `bettercap`, `mdk4`, `reaver` |
| **Bluetooth 5.0** | `BCM4343A2` HCI UART (`/dev/serial1` -> `ttyAMA0`) | `BCM4343A2.raspberrypi,0-compute-module.hcd`, `pi-bluetooth` (`btuart` / `hciuart.service`) | `bluez`, `bluetoothctl`, `APPLaunch -> Settings -> Bluetooth` |
| **CSI Camera** | Sony `IMX219` 8 MP (`dtoverlay=imx219`, `camera_auto_detect=0`) | `imx219`, `unicam`, `/dev/dma_heap/vidbuf_cached` (`60-dma-heap.rules`) | Kali `libcamera` + `/opt/rpi-libcamera` wrapper for M5 `Camera` |
| **Battery & Power** | TI `BQ27220` (`0x55` I2C1) / `ETA6965` + power-fail shutdown (`GPIO6`) | `bq27xxx_battery.ko`, `bq27xxx_battery_i2c.ko` (`bq27220_v5.dtbo`), `powerfail_suo.ko`, `i2c-dev` | `/sys/class/power_supply/`, battery indicator, `cz-hw-status` |
| **IMU + Mag** | Bosch `BMI270` (`0x68` I2C1) + `BMM150` | `bmi270_core.ko`, `bmi270_i2c.ko`, `bmc150_magn.ko`, `bmc150_magn_bmi270.ko`, `bmi270-init-data.fw` | `/sys/bus/iio/devices/iio:device*`, M5 `Compass` |
| **RTC** | Epson `RX8130CE` (`0x32` I2C1) | `rtc-ds1307` (`epson,rx8130`), udev `hwclock --hctosys` at boot | `/dev/rtc0` (`hwclock -r` / `hwclock -w`) |
| **Infrared** | IR TX (`GPIO12`) + IR RX (`GPIO13`) | `gpio-ir-tx` & `gpio-ir` (`/dev/lirc0`, `/dev/lirc1`, group `video`) | `ir-ctl`, M5 `IR Remote` & `IR Chat` |
| **USB OTG + Power Mux** | `dwc2` USB 2.0 OTG + `M5IOE1` (`0x4f` I2C1) | `m5ioe1.ko`, `libcomposite`, `/sys/class/leds/{ext_usb_gpio_fun,ext_5v_out,grove_5v_out,grove_fun}` | `USBGadget` (`cz-usbgadget`), `cz-usb-gadget`, `APPLaunch` OTG/5V/ADB toggles |
| **14-Pin Cap & Grove** | SPI0 (`CS1` + `GPIO22` `CS2`), UART0 (`/dev/ttyS0`), I2C1, GPIO + PWM | `gpio-forwarder.ko`, `spi0-spidev2-gpio22-overlay.dtbo`, `raspi-utils-dt`, `pigpiod` | LoRa `SX1262` + `ATGM336H` GNSS (`gpsd.socket` on `/dev/ttyS0`), `CC1101` Sub-GHz + NFC (`libnfc`, `mfoc`, `mfcuk`) |

## Launcher & LCD Apps

`APPLaunch` starts centered on slot `[2]` (`slots [0..4]` visible across the 320px screen), with the Kali apps listed before the M5 system and hardware apps:

1. `[0]` `WiFiScan` (`cz-wifiscan`): keys `4:SCAN`, `5:VIEW`, `6:IFACE`, `7:MON`, `8:EXIT`
2. `[1]` `Term80x24` (`cz-term80`): `80x24` terminal (`btop`, `htop`, `kismet`, `nmtui`, `tmux`); hold `ESC` 1.2s or press `Ctrl+Alt+Q` to exit
3. `[2]` `KaliZsh`: Zsh login shell in `APPLaunch`'s `45x10` large-font terminal
4. `[3]` `KaliMenu` (`cz-kali-menu`): quick-key TUI (`nmap`, `nmcli`, `btop`, `monstart`, `wifite`, `bettercap`, `bluetooth`, `gps`, `5V`, `gadget`)
5. `[4]` `SysMon` (`cz-sysmon`): keys `4:SYS`, `5:NET/HW`, `6:TOP`, `7:REFRESH/5V/SORT`, `8:EXIT`
6. `[5]` `LanScan` (`cz-lanscan`): keys `4:DISCOVER`, `5:PORTS`, `6:UP`, `7:DOWN`, `8:EXIT`
7. `[6]` `PktSniff` (`cz-pktsniff`): keys `4:START/PAUSE`, `5:IFACE`, `6:FILTER`, `7:PCAP`, `8:EXIT`
8. `[7]` `USBGadget` (`cz-usbgadget`): keys `4:NET`, `5:HID`, `6:COMBO`, `7:HOST/OFF`, `8:EXIT`
9. `[8]` `KaliPkgs` (`cz-kali-pkgs`): Kali metapackage installer (`wireless`, `top10`, `sniff`, `hardware`, `webpass`, `headless`, `default`, plus `kali-tweaks`)
10. M5 apps: `Settings`, `Store`, `CLI`, `SSH`, `IP Panel`, `Camera`, `IR Remote`, `IR Chat`, `Compass`, `Rec`, `Files`, `LoRa`, `GPS`, `NFC`, `SubG Chat`. Sample entries (`Python`, `Snake`, `Tank`, `Calculator`) default to off.

All entries are registered in `/usr/share/APPLaunch/preinstalled-desktop-apps.tsv` and `~/.config/cardputerzero/config.json`, and can be toggled on or off under `Settings -> Launcher`.

## Usage Notes

### 1.9" LCD & Keypad

- Use `,` / `.` (Left / Right) to scroll the launcher, `Enter` to open, and `` ` `` (`ESC`, top-left key) to go back. Holding `ESC` for 5 seconds force-closes the active app and returns to `APPLaunch`.
- In the `320x170` C utilities (`WiFiScan`, `SysMon`, `LanScan`, `PktSniff`, `USBGadget`), the five bottom labels line up above physical keys `4`, `5`, `6`, `7`, `8` (`8` exits).
- `KaliZsh` uses the `45x10` font for quick commands; `Term80x24` renders an `80x24` (`4x7` cell) `xterm-256color` grid for full-screen TUIs.

### HDMI Desktop

The 1.9" SPI LCD and the HDMI port run independently: `APPLaunch` stays on `/dev/fb_lcd` while HDMI runs a Kali LXDE session logged in as `kali`.

- **On-demand hotplug (`auto`, default)**:
  - **Unplugged**: `lightdm` and `Xorg` stay stopped so handheld tools keep the full 512 MB RAM.
  - **Plugged in**: `udev` starts `lightdm` automatically whether HDMI is connected before or after boot.
  - **Unplugged later**: after a 5-second debounce (so monitor sleep or mode switches are ignored), `lightdm` stops and frees ~75-90 MiB RAM.
  ```bash
  cz-hdmi-hotplug status        # Connector state, policy, and desktop RSS in MiB
  sudo cz-hdmi-hotplug always   # Keep LXDE running without HDMI (e.g. for VNC)
  sudo cz-hdmi-hotplug off      # Disable LXDE (TTY consoles only on HDMI)
  sudo cz-hdmi-hotplug auto     # Default hotplug behavior
  ```
- **Input & Consoles**: the internal keypad is isolated to `seat1` so handheld typing never goes into X11. Connect a USB or Bluetooth keyboard/mouse to control LXDE, use `Ctrl+Alt+F2`..`F6` for `VT2`-`VT6`, and `Ctrl+Alt+F7` to return to X11.
- **LCD Mirror & Audio**: open *CardputerZero LCD Mirror* (`fb-mirror.py`) from the LXDE menu to view `/dev/fb_lcd` in an X11 window. PipeWire defaults to the onboard `ES8389` codec (auto-muting the speaker when headphones are plugged in) and can be switched to HDMI audio via `pavucontrol` or `wpctl`.

### USB-C OTG Gadget Mode

Connect the USB-C OTG port to a host machine and switch modes from `USBGadget` (which also renders an SSH QR code) or from the shell:

```bash
sudo cz-usb-gadget combo    # usb0 (10.55.0.1/24) + /dev/hidg0 USB HID keyboard
sudo cz-usb-gadget net      # Ethernet-over-USB only (ssh kali@10.55.0.1)
sudo cz-usb-gadget hid      # USB HID keyboard (/dev/hidg0) only
sudo cz-usb-gadget off      # Return to USB OTG Host mode
sudo cz-usb-gadget status
```

### Wireless & Monitor Mode

- **Onboard `wlan0` (2.4 GHz)**: join networks via `Settings -> Wi-Fi`, `nmtui` in `Term80x24`, or `nmcli dev wifi connect "<SSID>" password "<PASS>"`.
- **External USB Wi-Fi (`wlan1`)**: `BCM43439` does not support monitor mode; plug a supported USB adapter (`RTL8812AU`/`RTL8821AU` via prebuilt `88XXau.ko`, `MT7612U`, `AR9271`, etc.) into USB-A and use `WiFiScan` (`6:IFACE` -> `7:MON`) or CLI:
  ```bash
  sudo monstart
  sudo wifite      # or kismet / airodump-ng / hcxdumptool / bettercap
  sudo monstop
  ```

### Kali Metapackages (`cz-kali-pkgs`)

`KaliPkgs` (`cz-kali-pkgs`) installs Kali toolsets after checking free SD space, keeping the CM0 kernel packages on hold, and leaving heavy background daemons (`apache2`, `mariadb`, `smbd`, etc.) disabled at boot:

```bash
sudo cz-kali-pkgs install wireless   # kali-tools-802-11 + bluetooth + rfid (~2 GB)
sudo cz-kali-pkgs install top10      # kali-tools-top10 (~3 GB)
sudo cz-kali-pkgs install headless   # kali-linux-headless (~10 GB, 32 GB+ SD)
sudo cz-kali-pkgs install default    # kali-linux-default (~15 GB, 32 GB+ SD)
cz-kali-pkgs                         # Interactive 45x10 menu (includes kali-tweaks)
```

### Hardware & Rail Status

Toggle `grove_5v_out` / `ext_5v_out` 5V power from `SysMon` (`5:NET` -> key `7`), `KaliMenu` (`9`), or `Settings`. Run `cz-hw-status` to check SoC temperature, `BQ27220` battery readings, `RX8130CE` RTC, IIO sensors, HDMI/LCD state, and 5V rails.

## Build Stages & Lockfile Modes

```bash
# Default (M5_UPDATE_MODE=auto): uses latest APT indices and tests newer M5Stack
# commits/releases, falling back per component to upstream.lock.json on build/ABI failure:
sudo ./build-kali-cardputerzero.sh

# Pin M5Stack components strictly to upstream.lock.json:
sudo M5_UPDATE_MODE=locked ./build-kali-cardputerzero.sh

# Run individual stages:
sudo ./build-kali-cardputerzero.sh fetch
sudo ./build-kali-cardputerzero.sh rootfs image kernel drivers packages
sudo ./build-kali-cardputerzero.sh apps launcher boot configs tweaks
sudo ./build-kali-cardputerzero.sh verify
sudo ./build-kali-cardputerzero.sh finalize compress
```

Running `sudo apt update && sudo apt full-upgrade` on the device is safe: the Raspberry Pi kernel, `raspi-firmware`, and CM0 wireless firmware packages are pinned and held so `apt` does not overwrite the out-of-tree CardputerZero modules or `wlan0`/`hci0` firmware.

## Repository Layout

- [`build-kali-cardputerzero.sh`](build-kali-cardputerzero.sh): stage-resumable ARM64 image builder, verifier, SD flasher, and SSH key installer.
- [`upstream.lock.json`](upstream.lock.json): pinned commits, URLs, and SHA-256 digests for M5Stack kernel manifests, drivers, and `.deb` packages.
- [`scripts/resolve-upstream.py`](scripts/resolve-upstream.py): resolves APT packages and M5Stack upstream artifacts with fallback to `upstream.lock.json`.
- [`src/Makefile`](src/Makefile): standalone build, `make check` PPM render test, and `install` targets.
- [`src/cz_ui.h`](src/cz_ui.h): `320x170` RGB565 framebuffer UI header (`evdev` input, status bar, `4`-`8` softkey bar).
- [`src/cz-wifiscan.c`](src/cz-wifiscan.c), [`src/cz-term80.c`](src/cz-term80.c), [`src/cz-sysmon.c`](src/cz-sysmon.c), [`src/cz-lanscan.c`](src/cz-lanscan.c), [`src/cz-pktsniff.c`](src/cz-pktsniff.c), [`src/cz-usbgadget.c`](src/cz-usbgadget.c): `320x170` LCD utilities and `80x24` terminal.
- [`src/libcz_fb_lcd.c`](src/libcz_fb_lcd.c): `LD_PRELOAD` `/dev/fb0` -> `/dev/fb_lcd` shim (`/usr/lib/cz-kali/libcz_fb_lcd.so`).
- [`scripts/configure-kali-launcher.py`](scripts/configure-kali-launcher.py): generates launcher icons, `.desktop` entries, manifest TSV, `config.json`, and patches `APPLaunch` card sorting.
- [`scripts/gen-kali-splash.py`](scripts/gen-kali-splash.py): generates `/boot/firmware/splash.bmp`, `logo_lcd.png`, and `lockscreen.png`.
- [`scripts/cz-kali-menu`](scripts/cz-kali-menu), [`scripts/cz-kali-pkgs`](scripts/cz-kali-pkgs), [`scripts/cz-usb-gadget`](scripts/cz-usb-gadget), [`scripts/cz-hdmi-hotplug`](scripts/cz-hdmi-hotplug), [`scripts/cz-hw-status`](scripts/cz-hw-status): on-device helper scripts.
- [`scripts/deploy-live.sh`](scripts/deploy-live.sh): updates C utilities, scripts, and launcher config on a running unit over SSH.

## License

- Repository scripts and C utilities are licensed under the [MIT License](LICENSE).
- Built microSD images include packages, kernel modules, firmware, and applications from Kali Linux, Debian, Raspberry Pi, and M5Stack under their respective upstream licenses (`GPL-2.0`, `GPL-3.0`, `LGPL`, `BSD-3-Clause`, `MIT`, and hardware firmware redistribution terms).
