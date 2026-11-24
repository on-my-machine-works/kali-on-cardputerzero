//! Virtual Linux `/dev/uinput` keyboard injector for `:8899` Web Remote control
//! of foreground `/dev/fb_lcd` apps (`cz-flipper-term`, `cz-kali-menu`, M5 LVGL apps,
//! `camera_app`, and Cap tools).
//!
//! Opened once at `flipctl` startup as `"flipctl-remote-kbd"` so `/dev/input/event*`
//! already exists before any child `/dev/fb_lcd` process scans `/dev/input`, while
//! `EvdevSource::find_devices()` skips `"flipctl-remote"` to avoid feedback loops.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;

use crate::FlipperKey;

pub const UINPUT_DEVICE_NAME: &str = "flipctl-remote-kbd";

const O_NONBLOCK_OCT: i32 = 0o4000;
const BUS_VIRTUAL: u16 = 0x06;
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const SYN_REPORT: u16 = 0x00;
const MAX_KEYCODE: u16 = 248;

// Standard Linux <linux/uinput.h> ioctls:
//   UI_DEV_CREATE  = _IO('U', 1)
//   UI_DEV_DESTROY = _IO('U', 2)
//   UI_DEV_SETUP   = _IOW('U', 3, struct uinput_setup)  (sizeof == 92 == 0x5c)
//   UI_SET_EVBIT   = _IOW('U', 100, int)
//   UI_SET_KEYBIT  = _IOW('U', 101, int)
const UI_DEV_CREATE: libc::c_ulong = 0x5501;
const UI_DEV_DESTROY: libc::c_ulong = 0x5502;
const UI_DEV_SETUP: libc::c_ulong = 0x405c_5503;
const UI_SET_EVBIT: libc::c_ulong = 0x4004_5564;
const UI_SET_KEYBIT: libc::c_ulong = 0x4004_5565;

#[repr(C)]
struct InputId {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
}

#[repr(C)]
struct UinputSetup {
    id: InputId,
    name: [u8; 80],
    ff_effects_max: u32,
}

const _: () = assert!(std::mem::size_of::<UinputSetup>() == 92);

#[repr(C)]
struct RawInputEvent {
    tv_sec: libc::time_t,
    tv_usec: libc::suseconds_t,
    kind: u16,
    code: u16,
    value: i32,
}

pub struct UinputInjector {
    file: File,
    held: Vec<u16>,
}

impl UinputInjector {
    pub fn open() -> std::io::Result<Self> {
        let file = OpenOptions::new()
            .write(true)
            .custom_flags(O_NONBLOCK_OCT)
            .open("/dev/uinput")?;
        let fd = file.as_raw_fd();

        unsafe {
            if libc::ioctl(fd, UI_SET_EVBIT as _, libc::c_int::from(EV_KEY)) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(fd, UI_SET_EVBIT as _, libc::c_int::from(EV_SYN)) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            for kc in 1..=MAX_KEYCODE {
                let _ = libc::ioctl(fd, UI_SET_KEYBIT as _, libc::c_int::from(kc));
            }

            let mut setup = UinputSetup {
                id: InputId {
                    bustype: BUS_VIRTUAL,
                    vendor: 0x1d6b,
                    product: 0x0104,
                    version: 1,
                },
                name: [0u8; 80],
                ff_effects_max: 0,
            };
            let bytes = UINPUT_DEVICE_NAME.as_bytes();
            let copy_len = bytes.len().min(setup.name.len() - 1);
            setup.name[..copy_len].copy_from_slice(&bytes[..copy_len]);

            if libc::ioctl(fd, UI_DEV_SETUP as _, &setup as *const UinputSetup) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(fd, UI_DEV_CREATE as _) < 0 {
                return Err(std::io::Error::last_os_error());
            }
        }

        Ok(Self {
            file,
            held: Vec::with_capacity(8),
        })
    }

    fn write_event(&mut self, kind: u16, code: u16, value: i32) {
        let ev = RawInputEvent {
            tv_sec: 0,
            tv_usec: 0,
            kind,
            code,
            value,
        };
        let bytes = unsafe {
            std::slice::from_raw_parts(
                (&ev as *const RawInputEvent).cast::<u8>(),
                std::mem::size_of::<RawInputEvent>(),
            )
        };
        let _ = self.file.write_all(bytes);
    }

    /// Inject a raw Linux evdev keycode (`1..=248`) press or release.
    pub fn send_code(&mut self, code: u16, down: bool) {
        if code == 0 || code > MAX_KEYCODE {
            return;
        }
        if down {
            if self.held.contains(&code) {
                return;
            }
            self.held.push(code);
            self.write_event(EV_KEY, code, 1);
            self.write_event(EV_SYN, SYN_REPORT, 0);
        } else if let Some(pos) = self.held.iter().position(|&k| k == code) {
            self.held.swap_remove(pos);
            self.write_event(EV_KEY, code, 0);
            self.write_event(EV_SYN, SYN_REPORT, 0);
        }
    }

    /// Inject a semantic `FlipperKey` mapped to CardputerZero's physical keycodes.
    pub fn send_flipper_key(&mut self, key: FlipperKey, down: bool) {
        self.send_code(fb_evdev_for_flipper(key), down);
    }

    /// Release any keys still held (called when a foreground `/dev/fb_lcd` app exits).
    pub fn release_all(&mut self) {
        let codes: Vec<u16> = self.held.drain(..).collect();
        if codes.is_empty() {
            return;
        }
        for code in codes {
            self.write_event(EV_KEY, code, 0);
        }
        self.write_event(EV_SYN, SYN_REPORT, 0);
    }
}

impl Drop for UinputInjector {
    fn drop(&mut self) {
        self.release_all();
        unsafe {
            let _ = libc::ioctl(self.file.as_raw_fd(), UI_DEV_DESTROY as _);
        }
    }
}

/// Map `FlipperKey` buttons to CardputerZero physical evdev keycodes (`4..8`, arrows,
/// `Enter`, `Esc`, `Tab`, `Grave`) so `/dev/fb_lcd` apps (`cz-flipper-term`, M5 LVGL apps,
/// `whiptail` menus) respond identically to physical button presses.
pub const fn fb_evdev_for_flipper(key: FlipperKey) -> u16 {
    use crate::key::code;
    match key {
        FlipperKey::Up => code::KEY_UP,
        FlipperKey::Down => code::KEY_DOWN,
        FlipperKey::Left => code::KEY_LEFT,
        FlipperKey::Right => code::KEY_RIGHT,
        FlipperKey::Ok => code::KEY_ENTER,
        FlipperKey::Back => code::KEY_ESC,
        FlipperKey::AppSwitch => code::KEY_TAB,
        FlipperKey::Ptt => code::KEY_GRAVE,
        FlipperKey::Escape => code::KEY_4,
        FlipperKey::View => code::KEY_5,
        FlipperKey::Power => code::KEY_6,
        FlipperKey::Edit => code::KEY_7,
        FlipperKey::Run => code::KEY_8,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::key::code;

    #[test]
    fn maps_every_flipper_key_to_valid_cardputer_evdev() {
        for k in FlipperKey::ALL {
            let ev = fb_evdev_for_flipper(k);
            assert!(ev >= 1 && ev <= MAX_KEYCODE, "invalid keycode {ev} for {k:?}");
        }
        assert_eq!(fb_evdev_for_flipper(FlipperKey::Back), code::KEY_ESC);
        assert_eq!(fb_evdev_for_flipper(FlipperKey::Ok), code::KEY_ENTER);
        assert_eq!(fb_evdev_for_flipper(FlipperKey::Escape), code::KEY_4);
        assert_eq!(fb_evdev_for_flipper(FlipperKey::Run), code::KEY_8);
    }
}
