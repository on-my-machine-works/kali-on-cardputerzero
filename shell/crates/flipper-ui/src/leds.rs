//! Hardware brightness & CardputerZero M5IOE1 expansion rail controls, plus
//! Flipper One LED group fallback.
//!
//! CardputerZero exposes its ST7789v3 PWM backlight at `/sys/class/backlight/backlight`
//! and its M5IOE1 I2C GPIO/power muxes under `/sys/class/leds/`:
//!   - `ext_5v_out`       : External 5V power rail (`0` = OFF, `1` = ON)
//!   - `grove_5v_out`     : HY2.0-4P Grove 5V rail (`0` = OFF, `1` = ON)
//!   - `grove_fun`        : Grove pin mux (`0` = I2C, `1` = UART)
//!   - `ext_usb_gpio_fun` : USB-C OTG mux (`0` = Host, `1` = Device/OTG)

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread;

const DRIVER: &str = "/sys/bus/platform/drivers/flipper-one-leds";

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Group {
    Link,
    Power,
    Wattmeter,
}

impl Group {
    pub const ALL: [Group; 3] = [Group::Link, Group::Power, Group::Wattmeter];

    fn file(self) -> &'static str {
        match self {
            Group::Link => "link_brightness",
            Group::Power => "power_brightness",
            Group::Wattmeter => "wattmeter_brightness",
        }
    }

    fn index(self) -> usize {
        self as usize
    }
}

fn device() -> Option<PathBuf> {
    std::fs::read_dir(DRIVER)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| p.join(Group::Link.file()).exists())
}

pub fn available() -> bool {
    device().is_some()
}

pub fn read(group: Group) -> Option<u8> {
    if let Some(v) = writer().held.lock().unwrap().values[group.index()] {
        return Some(v);
    }
    let text = std::fs::read_to_string(device()?.join(group.file())).ok()?;
    text.trim().parse().ok()
}

pub fn set(group: Group, value: u8) {
    let w = writer();
    w.held.lock().unwrap().values[group.index()] = Some(value);
    w.wake.notify_one();
}

pub fn raw(percent: u8) -> u8 {
    ((u32::from(percent.min(100)) * 255 + 50) / 100) as u8
}

pub fn percent(raw: u8) -> u8 {
    ((u32::from(raw) * 100 + 127) / 255) as u8
}

pub const STEPS: [u8; 12] = [0, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100];

pub fn step(raw_now: u8, up: bool) -> u8 {
    let steps = STEPS.iter().map(|&p| raw(p));
    if up {
        steps.into_iter().find(|&s| s > raw_now).unwrap_or(raw_now)
    } else {
        steps.rev().find(|&s| s < raw_now).unwrap_or(raw_now)
    }
}

pub fn label(raw: u8) -> String {
    if raw == 0 {
        "Off".into()
    } else {
        format!("{}%", percent(raw))
    }
}

struct Held {
    values: [Option<u8>; 3],
}

struct Writer {
    held: Mutex<Held>,
    wake: Condvar,
}

fn writer() -> &'static Writer {
    static WRITER: OnceLock<Writer> = OnceLock::new();
    let mut fresh = false;
    let w = WRITER.get_or_init(|| {
        fresh = true;
        Writer { held: Mutex::new(Held { values: [None; 3] }), wake: Condvar::new() }
    });
    if fresh {
        thread::spawn(move || flush(w));
    }
    w
}

fn flush(w: &'static Writer) {
    let mut held = w.held.lock().unwrap();
    loop {
        if held.values.iter().all(Option::is_none) {
            held = w.wake.wait(held).unwrap();
            continue;
        }
        let values = held.values;
        drop(held);
        let dir = device();
        for (group, value) in Group::ALL.into_iter().zip(values) {
            let (Some(v), Some(dir)) = (value, &dir) else { continue };
            if let Err(e) = crate::system::write_sysfs(&dir.join(group.file()), &v.to_string()) {
                eprintln!("leds           {e}");
            }
        }
        held = w.held.lock().unwrap();
        for (slot, written) in held.values.iter_mut().zip(values) {
            if *slot == written {
                *slot = None;
            }
        }
    }
}

// ── CardputerZero Hardware, Backlight, M5IOE1 Rails & Kali Helpers ─────────

pub mod cz {
    use super::*;

    #[derive(Copy, Clone, Debug, PartialEq, Eq)]
    pub enum Rail {
        Ext5v,
        Grove5v,
        GroveMode,
        UsbMux,
    }

    impl Rail {
        fn path(self) -> &'static str {
            match self {
                Rail::Ext5v => "/sys/class/leds/ext_5v_out/brightness",
                Rail::Grove5v => "/sys/class/leds/grove_5v_out/brightness",
                Rail::GroveMode => "/sys/class/leds/grove_fun/brightness",
                Rail::UsbMux => "/sys/class/leds/ext_usb_gpio_fun/brightness",
            }
        }

        pub fn status(self) -> String {
            let Ok(text) = std::fs::read_to_string(self.path()) else {
                return "N/A".into();
            };
            let on = text.trim().parse::<u32>().unwrap_or(0) != 0;
            match self {
                Rail::Ext5v | Rail::Grove5v => if on { "< ON >" } else { "< OFF >" }.into(),
                Rail::GroveMode => if on { "< UART >" } else { "< I2C >" }.into(),
                Rail::UsbMux => if on { "< OTG >" } else { "< Host >" }.into(),
            }
        }

        pub fn toggle(self) -> bool {
            let p = Path::new(self.path());
            let Ok(text) = std::fs::read_to_string(p) else {
                return false;
            };
            let cur = text.trim().parse::<u32>().unwrap_or(0);
            let next = if cur == 0 { "1" } else { "0" };
            if std::fs::write(p, next).is_err() {
                let _ = crate::system::write_sysfs(p, next);
            }
            true
        }
    }

    fn backlight_dir() -> Option<PathBuf> {
        let primary = Path::new("/sys/class/backlight/backlight");
        if primary.exists() {
            return Some(primary.to_path_buf());
        }
        std::fs::read_dir("/sys/class/backlight")
            .ok()?
            .flatten()
            .map(|e| e.path())
            .next()
    }

    fn saved_backlight_raw() -> &'static Mutex<Option<u32>> {
        static SAVED: OnceLock<Mutex<Option<u32>>> = OnceLock::new();
        SAVED.get_or_init(|| Mutex::new(None))
    }

    pub fn backlight_percent() -> Option<u8> {
        let dir = backlight_dir()?;
        let cur: u32 = std::fs::read_to_string(dir.join("brightness")).ok()?.trim().parse().ok()?;
        let max: u32 = std::fs::read_to_string(dir.join("max_brightness"))
            .ok()?
            .trim()
            .parse()
            .ok()
            .filter(|&m| m > 0)?;
        let effective = if cur == 0 {
            saved_backlight_raw()
                .lock()
                .ok()
                .and_then(|g| *g)
                .unwrap_or_else(|| (80 * max + 50) / 100)
        } else {
            if let Ok(mut g) = saved_backlight_raw().lock() {
                *g = Some(cur);
            }
            cur
        };
        Some(((effective * 100 + max / 2) / max).clamp(5, 100) as u8)
    }

    pub fn backlight_status() -> String {
        match backlight_percent() {
            Some(pct) => format!("< {pct}% >"),
            None => String::new(),
        }
    }

    pub fn backlight_ends() -> (bool, bool) {
        match backlight_percent() {
            Some(pct) => (pct <= 10, pct >= 100),
            None => (false, false),
        }
    }

    fn write_backlight_raw(dir: &Path, raw_val: u32) {
        let bpath = dir.join("brightness");
        let val_str = raw_val.to_string();
        if std::fs::write(&bpath, &val_str).is_err() {
            let _ = crate::system::write_sysfs(&bpath, &val_str);
        }
    }

    pub fn step_backlight(up: bool) -> bool {
        let Some(dir) = backlight_dir() else { return false };
        let Some(cur_pct) = backlight_percent() else { return false };
        let Ok(max_txt) = std::fs::read_to_string(dir.join("max_brightness")) else { return false };
        let Ok(max) = max_txt.trim().parse::<u32>() else { return false };
        if max == 0 {
            return false;
        }
        const BL_STEPS: [u8; 10] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
        let next_pct = if up {
            BL_STEPS.into_iter().find(|&p| p > cur_pct).unwrap_or(100)
        } else {
            BL_STEPS.into_iter().rev().find(|&p| p < cur_pct).unwrap_or(10)
        };
        if next_pct == cur_pct {
            return false;
        }
        let raw_val = ((u32::from(next_pct) * max + 50) / 100).clamp(1, max);
        if let Ok(mut g) = saved_backlight_raw().lock() {
            *g = Some(raw_val);
        }
        write_backlight_raw(&dir, raw_val);
        true
    }

    pub fn cycle_backlight() -> bool {
        let Some(dir) = backlight_dir() else { return false };
        let Some(cur_pct) = backlight_percent() else { return false };
        let Ok(max_txt) = std::fs::read_to_string(dir.join("max_brightness")) else { return false };
        let Ok(max) = max_txt.trim().parse::<u32>() else { return false };
        if max == 0 {
            return false;
        }
        const CYCLE: [u8; 5] = [20, 40, 60, 80, 100];
        let next_pct = CYCLE.into_iter().find(|&p| p > cur_pct + 5).unwrap_or(CYCLE[0]);
        let raw_val = ((u32::from(next_pct) * max + 50) / 100).clamp(1, max);
        if let Ok(mut g) = saved_backlight_raw().lock() {
            *g = Some(raw_val);
        }
        write_backlight_raw(&dir, raw_val);
        true
    }

    /// Turn off the ST7789v3 PWM backlight (`brightness = 0`), remembering the working level.
    pub fn sleep_backlight() -> bool {
        let Some(dir) = backlight_dir() else { return false };
        let Ok(cur_txt) = std::fs::read_to_string(dir.join("brightness")) else { return false };
        let cur = cur_txt.trim().parse::<u32>().unwrap_or(0);
        if cur > 0 {
            if let Ok(mut g) = saved_backlight_raw().lock() {
                *g = Some(cur);
            }
            write_backlight_raw(&dir, 0);
        }
        true
    }

    /// Restore the ST7789v3 PWM backlight after sleep or screen lock.
    pub fn wake_backlight() -> bool {
        let Some(dir) = backlight_dir() else { return false };
        let Ok(cur_txt) = std::fs::read_to_string(dir.join("brightness")) else { return false };
        let cur = cur_txt.trim().parse::<u32>().unwrap_or(0);
        if cur > 0 {
            return false;
        }
        let max = std::fs::read_to_string(dir.join("max_brightness"))
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
            .filter(|&m| m > 0)
            .unwrap_or(100);
        let restore = saved_backlight_raw()
            .lock()
            .ok()
            .and_then(|g| *g)
            .unwrap_or_else(|| (80 * max + 50) / 100)
            .clamp(1, max);
        write_backlight_raw(&dir, restore);
        true
    }

    // ── LCD Idle Timeout (`dark_time` synced with M5 CardputerZero config.json) ──

    pub const TIMEOUT_STEPS: [u32; 7] = [0, 10, 30, 60, 120, 300, 600];
    const CZ_CONFIG_JSON: &str = "/home/kali/.config/cardputerzero/config.json";
    const FALLBACK_TIMEOUT_FILE: &str = "/var/lib/flipctl/lcd-timeout";

    pub fn parse_dark_time_json(json: &str) -> Option<u32> {
        let key_pos = json.find("\"dark_time\"")?;
        let after_key = &json[key_pos + "\"dark_time\"".len()..];
        let colon = after_key.find(':')?;
        let val_part = after_key[colon + 1..].trim_start();
        let digits: String = val_part.chars().take_while(|c| c.is_ascii_digit()).collect();
        digits.parse::<u32>().ok()
    }

    pub fn update_dark_time_json(json: &str, secs: u32) -> String {
        if let Some(key_pos) = json.find("\"dark_time\"") {
            let after_key = &json[key_pos + "\"dark_time\"".len()..];
            if let Some(colon_rel) = after_key.find(':') {
                let val_start = key_pos + "\"dark_time\"".len() + colon_rel + 1;
                let rest = &json[val_start..];
                let ws_len = rest.len() - rest.trim_start().len();
                let num_start = val_start + ws_len;
                let num_len = json[num_start..]
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .map(char::len_utf8)
                    .sum::<usize>();
                if num_len > 0 {
                    let mut out = String::with_capacity(json.len() + 8);
                    out.push_str(&json[..num_start]);
                    out.push_str(&secs.to_string());
                    out.push_str(&json[num_start + num_len..]);
                    return out;
                }
            }
        }
        let trimmed = json.trim_end();
        if let Some(without_brace) = trimmed.strip_suffix('}') {
            let body = without_brace.trim_end();
            let sep = if body.ends_with('{') { "\n" } else { ",\n" };
            format!("{body}{sep}  \"dark_time\": {secs}\n}}\n")
        } else {
            format!("{{\n  \"dark_time\": {secs}\n}}\n")
        }
    }

    fn normalize_timeout(raw: u32) -> u32 {
        if raw == 0 {
            return 0;
        }
        TIMEOUT_STEPS
            .iter()
            .copied()
            .skip(1)
            .min_by_key(|&s| s.abs_diff(raw))
            .unwrap_or(120)
    }

    fn timeout_cache() -> &'static Mutex<u32> {
        static TIMEOUT: OnceLock<Mutex<u32>> = OnceLock::new();
        TIMEOUT.get_or_init(|| {
            let initial = std::fs::read_to_string(CZ_CONFIG_JSON)
                .ok()
                .and_then(|s| parse_dark_time_json(&s))
                .or_else(|| {
                    std::fs::read_to_string(FALLBACK_TIMEOUT_FILE)
                        .ok()
                        .and_then(|s| s.trim().parse::<u32>().ok())
                })
                .map(normalize_timeout)
                .unwrap_or(120);
            Mutex::new(initial)
        })
    }

    pub fn lcd_timeout_secs() -> u32 {
        timeout_cache().lock().map(|g| *g).unwrap_or(120)
    }

    pub fn format_timeout(secs: u32) -> &'static str {
        match secs {
            0 => "Never",
            1..=15 => "10s",
            16..=45 => "30s",
            46..=90 => "1m",
            91..=200 => "2m",
            201..=450 => "5m",
            _ => "10m",
        }
    }

    pub fn lcd_timeout_status() -> String {
        format!("< {} >", format_timeout(lcd_timeout_secs()))
    }

    pub fn lcd_timeout_ends() -> (bool, bool) {
        let s = lcd_timeout_secs();
        (s == 0, s >= 600)
    }

    fn persist_lcd_timeout(secs: u32) {
        if let Ok(mut g) = timeout_cache().lock() {
            *g = secs;
        }
        thread::spawn(move || {
            let cfg_path = Path::new(CZ_CONFIG_JSON);
            if let Some(parent) = cfg_path.parent() {
                if parent.exists() || Path::new("/home/kali").exists() {
                    let _ = std::fs::create_dir_all(parent);
                    let existing = std::fs::read_to_string(cfg_path).unwrap_or_default();
                    let updated = update_dark_time_json(&existing, secs);
                    if std::fs::write(cfg_path, &updated).is_ok() {
                        return;
                    }
                }
            }
            if let Some(parent) = Path::new(FALLBACK_TIMEOUT_FILE).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(FALLBACK_TIMEOUT_FILE, format!("{secs}\n"));
        });
    }

    pub fn step_lcd_timeout(up: bool) -> bool {
        let cur = lcd_timeout_secs();
        let next = if up {
            TIMEOUT_STEPS.into_iter().find(|&s| s > cur).unwrap_or(600)
        } else {
            TIMEOUT_STEPS.into_iter().rev().find(|&s| s < cur).unwrap_or(0)
        };
        if next == cur {
            return false;
        }
        persist_lcd_timeout(next);
        true
    }

    pub fn cycle_lcd_timeout() -> bool {
        let cur = lcd_timeout_secs();
        let idx = TIMEOUT_STEPS.iter().position(|&s| s == cur).unwrap_or(0);
        let next = TIMEOUT_STEPS[(idx + 1) % TIMEOUT_STEPS.len()];
        persist_lcd_timeout(next);
        true
    }

    const GADGET_MODES: [&str; 5] = ["off", "net", "hid", "combo", "mtp"];

    fn pending_gadget() -> &'static Mutex<Option<(&'static str, std::time::Instant)>> {
        static PENDING: OnceLock<Mutex<Option<(&'static str, std::time::Instant)>>> =
            OnceLock::new();
        PENDING.get_or_init(|| Mutex::new(None))
    }

    pub fn usb_gadget_mode() -> &'static str {
        if let Ok(mut guard) = pending_gadget().lock() {
            if let Some((mode, until)) = *guard {
                if std::time::Instant::now() < until {
                    return mode;
                }
                *guard = None;
            }
        }
        let cfg = Path::new("/sys/kernel/config/usb_gadget/kali_cz/configs/c.1");
        if !cfg.exists() {
            // Also check legacy cz-usb-gadget directory.
            let legacy = Path::new("/sys/kernel/config/usb_gadget/cz_kali/configs/c.1");
            if !legacy.exists() {
                return "off";
            }
            return detect_gadget_dir(legacy);
        }
        detect_gadget_dir(cfg)
    }

    fn detect_gadget_dir(cfg: &Path) -> &'static str {
        let mut has_net = false;
        let mut has_hid = false;
        let mut has_mtp = false;
        if let Ok(entries) = std::fs::read_dir(cfg) {
            for e in entries.flatten() {
                let s = e.file_name();
                let name = s.to_string_lossy();
                if name.starts_with("ncm.") || name.starts_with("ecm.") || name.starts_with("rndis.") {
                    has_net = true;
                } else if name.starts_with("hid.") {
                    has_hid = true;
                } else if name.starts_with("ffs.") || name.starts_with("acm.") {
                    has_mtp = true;
                }
            }
        }
        match (has_net, has_hid, has_mtp) {
            (_, _, true) => "mtp",
            (true, true, false) => "combo",
            (false, true, false) => "hid",
            (true, false, false) => "net",
            _ => "off",
        }
    }

    pub fn usb_gadget_status() -> String {
        format!("< {} >", usb_gadget_mode().to_uppercase())
    }

    pub fn step_usb_gadget(forward: bool) -> bool {
        let cur = usb_gadget_mode();
        let idx = GADGET_MODES.iter().position(|&m| m == cur).unwrap_or(0);
        let next = if forward {
            (idx + 1) % GADGET_MODES.len()
        } else {
            (idx + GADGET_MODES.len() - 1) % GADGET_MODES.len()
        };
        let mode = GADGET_MODES[next];
        let tool = if Path::new("/usr/local/bin/cz-flipper-gadget").exists() {
            "/usr/local/bin/cz-flipper-gadget"
        } else if Path::new("/usr/local/bin/cz-usb-gadget").exists() {
            "/usr/local/bin/cz-usb-gadget"
        } else {
            return false;
        };
        if let Ok(mut guard) = pending_gadget().lock() {
            *guard = Some((mode, std::time::Instant::now() + std::time::Duration::from_millis(2500)));
        }
        thread::spawn(move || {
            let _ = Command::new("sudo").arg("-n").arg(tool).arg(mode).status();
        });
        true
    }

    const HDMI_MODES: [&str; 3] = ["auto", "always", "off"];

    fn pending_hdmi() -> &'static Mutex<Option<(&'static str, std::time::Instant)>> {
        static PENDING: OnceLock<Mutex<Option<(&'static str, std::time::Instant)>>> =
            OnceLock::new();
        PENDING.get_or_init(|| Mutex::new(None))
    }

    pub fn hdmi_mode() -> &'static str {
        if let Ok(mut guard) = pending_hdmi().lock() {
            if let Some((mode, until)) = *guard {
                if std::time::Instant::now() < until {
                    return mode;
                }
                *guard = None;
            }
        }
        if let Ok(text) = std::fs::read_to_string("/etc/default/cz-hdmi-desktop") {
            for line in text.lines() {
                if let Some(val) = line.trim().strip_prefix("HDMI_DESKTOP_MODE=") {
                    return match val.trim_matches('"') {
                        "always" => "always",
                        "off" => "off",
                        _ => "auto",
                    };
                }
            }
        }
        "auto"
    }

    pub fn hdmi_status() -> String {
        format!("< {} >", hdmi_mode())
    }

    pub fn step_hdmi_mode(forward: bool) -> bool {
        if !Path::new("/usr/local/bin/cz-hdmi-hotplug").exists() {
            return false;
        }
        let cur = hdmi_mode();
        let idx = HDMI_MODES.iter().position(|&m| m == cur).unwrap_or(0);
        let next = if forward {
            (idx + 1) % HDMI_MODES.len()
        } else {
            (idx + HDMI_MODES.len() - 1) % HDMI_MODES.len()
        };
        let mode = HDMI_MODES[next];
        if let Ok(mut guard) = pending_hdmi().lock() {
            *guard = Some((mode, std::time::Instant::now() + std::time::Duration::from_millis(2500)));
        }
        thread::spawn(move || {
            let _ = Command::new("sudo")
                .args(["-n", "/usr/local/bin/cz-hdmi-hotplug", mode])
                .status();
        });
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_are_tenths() {
        let mut at = 0;
        let mut seen = vec![label(at)];
        while step(at, true) != at {
            at = step(at, true);
            seen.push(label(at));
        }
        assert_eq!(
            seen,
            ["Off", "5%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%"]
        );
        assert_eq!(at, 255);
        assert_eq!(step(0, false), 0);
    }

    #[test]
    fn off_step_value_moves_to_the_next_step() {
        assert_eq!(label(140), "55%");
        assert_eq!(label(step(140, true)), "60%");
        assert_eq!(label(step(140, false)), "50%");
    }

    #[test]
    fn round_trips() {
        for p in STEPS {
            assert_eq!(percent(raw(p)), p);
        }
    }

    #[test]
    fn dark_time_json_round_trips_preserving_other_keys() {
        let sample = "{\n  \"app_CLI\": 1,\n  \"dark_time\": 300,\n  \"volume\": 50\n}\n";
        assert_eq!(cz::parse_dark_time_json(sample), Some(300));
        let updated = cz::update_dark_time_json(sample, 60);
        assert_eq!(cz::parse_dark_time_json(&updated), Some(60));
        assert!(updated.contains("\"app_CLI\": 1"));
        assert!(updated.contains("\"volume\": 50"));

        let fresh = cz::update_dark_time_json("", 0);
        assert_eq!(cz::parse_dark_time_json(&fresh), Some(0));
        assert_eq!(cz::format_timeout(0), "Never");
        assert_eq!(cz::format_timeout(300), "5m");
    }
}
