//! Raw evdev input source for CardputerZero's TCA8418 46-key I2C matrix keyboard,
//! external USB/Bluetooth keyboards, and Flipper One button devices.
//!
//! Preserves full compatibility with CardputerZero interactions (`cz_ui.h`):
//!   - Discovers `/dev/input/cardputer-zero-internal` (`platform-3f804000.i2c-event`)
//!     and any attached USB/Bluetooth keyboards, deduplicating symlinks by `st_rdev`
//!     while ignoring HDMI/audio/power-only dummy nodes.
//!   - Translates all 32 `TCA8418` `Sym` (`linux,keymap1`) keycodes and `/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map`
//!     entries plus `Shift` + US QWERTY so physical typing works natively inside `TextInput`
//!     (e.g. Wi-Fi passphrases, profile renames, and app prompts).
//!   - Tracks physical `ESC` hold duration so holding `ESC` rescues any hung foreground app.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::platform::{InputSource, Touch};
use crate::{FlipperKey, KeyEvent};

const EVENT_SIZE: usize = 24;
const EV_KEY: u16 = 1;
const TCA8418_KEYMAP_PATH: &str = "/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map";
const SYM_MAX: usize = 256; // not-a-panel-dimension

const KEY_ESC: u16 = 1;
const KEY_BACKSPACE: u16 = 14;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_LEFTCTRL: u16 = 29;
const KEY_RIGHTCTRL: u16 = 97;
const KEY_LEFTALT: u16 = 56;
const KEY_RIGHTALT: u16 = 100;
const KEY_BRIGHTNESSDOWN: u16 = 224;
const KEY_BRIGHTNESSUP: u16 = 225;
const KEY_MUTE: u16 = 113;
const KEY_VOLUMEDOWN: u16 = 114;
const KEY_VOLUMEUP: u16 = 115;

/// Raw keyboard typing events used by `Screen::TextInput` and `raw_keyboard` apps so
/// all 46 physical keys (including `4`..`8`, `Backspace`, `Enter`, `Shift`, `Sym`, and
/// `Fn` navigation chords) operate directly without an on-screen virtual keyboard.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum TypedEvent {
    Char(char),
    CtrlChar(char),
    Backspace,
    Delete,
    Enter,
    Esc,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    F6,
    F8,
}

struct DevEntry {
    file: File,
    is_tca8418: bool,
}

pub struct EvdevSource {
    devices: Vec<DevEntry>,
    queue: VecDeque<KeyEvent>,
    typed: VecDeque<TypedEvent>,
    sym_map: [u8; SYM_MAX],
    shift: bool,
    ctrl: bool,
    alt: bool,
    esc_down_since: Option<Instant>,
    buf: [u8; EVENT_SIZE * 32],
}

impl EvdevSource {
    pub fn open() -> std::io::Result<Self> {
        let candidates = Self::find_devices()?;
        if candidates.is_empty() {
            return Err(std::io::Error::other(
                "no CardputerZero keypad or keyboard input devices found",
            ));
        }

        let mut seen_rdev = Vec::new();
        let mut devices = Vec::new();
        for (path, is_tca8418) in candidates {
            let Ok(file) = OpenOptions::new().read(true).custom_flags(libc_o_nonblock()).open(&path)
            else {
                continue;
            };
            if let Ok(meta) = file.metadata() {
                let rdev = meta.rdev();
                if rdev != 0 && seen_rdev.contains(&rdev) {
                    continue;
                }
                seen_rdev.push(rdev);
            }
            devices.push(DevEntry { file, is_tca8418 });
        }

        if devices.is_empty() {
            return Err(std::io::Error::other(
                "found keyboard input devices but could not open any of them",
            ));
        }

        Ok(Self {
            devices,
            queue: VecDeque::new(),
            typed: VecDeque::new(),
            sym_map: load_tca8418_sym_map(Path::new(TCA8418_KEYMAP_PATH)),
            shift: false,
            ctrl: false,
            alt: false,
            esc_down_since: None,
            buf: [0; EVENT_SIZE * 32],
        })
    }

    fn find_devices() -> std::io::Result<Vec<(PathBuf, bool)>> {
        let mut found = Vec::new();

        if let Ok(explicit) = std::env::var("FLIPCTL_INPUT_DEVICE") {
            let p = PathBuf::from(&explicit);
            if p.exists() {
                found.push((p, explicit.contains("cardputer") || explicit.contains("3f804000")));
                return Ok(found);
            }
        }

        for primary in [
            "/dev/input/cardputer-zero-internal",
            "/dev/input/by-path/platform-3f804000.i2c-event",
        ] {
            let p = Path::new(primary);
            if p.exists() {
                found.push((p.to_path_buf(), true));
            }
        }

        if let Ok(entries) = std::fs::read_dir("/sys/class/input") {
            let mut sys_nodes: Vec<(PathBuf, bool)> = Vec::new();
            for entry in entries.flatten() {
                let node = entry.file_name();
                let Some(node) = node.to_str() else { continue };
                if !node.starts_with("event") {
                    continue;
                }
                let name = std::fs::read_to_string(entry.path().join("device/name"))
                    .unwrap_or_default();
                let name = name.trim();
                let lower = name.to_ascii_lowercase();

                // Skip non-keyboard input nodes and our own uinput virtual keyboard.
                if lower.contains("hdmi")
                    || lower.contains("vc4")
                    || lower.contains("headphone")
                    || lower.contains("ir_recv")
                    || lower.contains("gpio_ir")
                    || lower.contains("touchpad")
                    || lower.contains("flipctl-remote")
                {
                    continue;
                }

                let is_tca = lower.contains("tca8418") || lower.contains("cardputer");
                let is_flipper = name.starts_with("Flipper One") && name.ends_with("Buttons");
                let is_kbd = lower.contains("keyboard") || lower.contains("kbd") || lower.contains("hid");

                // Check capabilities/key bitmap for KEY_ENTER (bit 28) to catch generic USB keyboards.
                let has_enter = std::fs::read_to_string(entry.path().join("device/capabilities/key"))
                    .ok()
                    .is_some_and(|caps| has_key_bit(&caps, 28));

                if is_tca || is_flipper || is_kbd || has_enter {
                    sys_nodes.push((PathBuf::from("/dev/input").join(node), is_tca));
                }
            }
            sys_nodes.sort_by(|a, b| a.0.cmp(&b.0));
            found.extend(sys_nodes);
        }

        Ok(found)
    }

    fn drain(&mut self) {
        for i in 0..self.devices.len() {
            let is_tca8418 = self.devices[i].is_tca8418;
            loop {
                let read = match self.devices[i].file.read(&mut self.buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                for chunk in self.buf[..read].chunks_exact(EVENT_SIZE) {
                    let kind = u16::from_ne_bytes([chunk[16], chunk[17]]);
                    let code = u16::from_ne_bytes([chunk[18], chunk[19]]);
                    let value = i32::from_ne_bytes([chunk[20], chunk[21], chunk[22], chunk[23]]);
                    if kind != EV_KEY {
                        continue;
                    }

                    match code {
                        KEY_LEFTSHIFT | KEY_RIGHTSHIFT => {
                            self.shift = value != 0;
                            continue;
                        }
                        KEY_LEFTCTRL | KEY_RIGHTCTRL => {
                            self.ctrl = value != 0;
                            continue;
                        }
                        KEY_LEFTALT | KEY_RIGHTALT => {
                            self.alt = value != 0;
                            continue;
                        }
                        KEY_ESC => {
                            if value == 1 {
                                self.esc_down_since = Some(Instant::now());
                            } else if value == 0 {
                                self.esc_down_since = None;
                            }
                        }
                        KEY_BRIGHTNESSDOWN | KEY_BRIGHTNESSUP if value == 1 || value == 2 => {
                            let _ = crate::leds::cz::step_backlight(code == KEY_BRIGHTNESSUP);
                            continue;
                        }
                        KEY_VOLUMEDOWN | KEY_VOLUMEUP if value == 1 || value == 2 => {
                            let _ = crate::audio::step_volume(code == KEY_VOLUMEUP);
                            continue;
                        }
                        KEY_MUTE if value == 1 => {
                            let _ = crate::audio::toggle_mute();
                            continue;
                        }
                        _ => {}
                    }

                    // Track physical character & editing keys (including auto-repeat value == 2).
                    if (value == 1 || value == 2) && !self.alt {
                        if self.ctrl {
                            if value == 1 {
                                if let Some(ch) =
                                    evdev_to_ascii(&self.sym_map, is_tca8418, code, false)
                                {
                                    self.typed
                                        .push_back(TypedEvent::CtrlChar(ch.to_ascii_lowercase()));
                                }
                            }
                        } else {
                            match code {
                                KEY_ESC if value == 1 => self.typed.push_back(TypedEvent::Esc),
                                KEY_BACKSPACE => self.typed.push_back(TypedEvent::Backspace),
                                111 => self.typed.push_back(TypedEvent::Delete),
                                28 | 96 if value == 1 => self.typed.push_back(TypedEvent::Enter),
                                105 => self.typed.push_back(TypedEvent::Left),
                                106 => self.typed.push_back(TypedEvent::Right),
                                103 | 104 => self.typed.push_back(TypedEvent::Up),
                                108 | 109 => self.typed.push_back(TypedEvent::Down),
                                102 => self.typed.push_back(TypedEvent::Home),
                                107 => self.typed.push_back(TypedEvent::End),
                                64 if value == 1 => self.typed.push_back(TypedEvent::F6),
                                66 if value == 1 => self.typed.push_back(TypedEvent::F8),
                                _ => {
                                    if let Some(ch) =
                                        evdev_to_ascii(&self.sym_map, is_tca8418, code, self.shift)
                                    {
                                        self.typed.push_back(TypedEvent::Char(ch));
                                    }
                                }
                            }
                        }
                        if self.typed.len() > 64 {
                            self.typed.pop_front();
                        }
                    }

                    // On TCA8418, if `Sym` (`linux,keymap1`) is latched, physical keys `4..8`
                    // emit keycodes 40, 41, 43, 51, 52; map them to `SOFT_ROW` so `4..8`
                    // always work as softkeys in menus regardless of `Fn` or `Sym` LED state!
                    let mapped = if is_tca8418 {
                        match code {
                            40 => Some(FlipperKey::Escape),
                            41 => Some(FlipperKey::View),
                            43 => Some(FlipperKey::Power),
                            51 => Some(FlipperKey::Edit),
                            52 => Some(FlipperKey::Run),
                            _ => FlipperKey::from_evdev(code),
                        }
                    } else {
                        FlipperKey::from_evdev(code)
                    };

                    if let Some(key) = mapped {
                        if value != 0 && (self.ctrl || self.alt) {
                            continue;
                        }
                        let is_nav = matches!(
                            key,
                            FlipperKey::Up
                                | FlipperKey::Down
                                | FlipperKey::Left
                                | FlipperKey::Right
                        );
                        let down = match value {
                            0 => false,
                            1 => true,
                            2 if is_nav => true,
                            _ => continue,
                        };
                        self.queue.push_back(KeyEvent { key, down });
                    }
                }
                if read < EVENT_SIZE {
                    break;
                }
            }
        }
    }

    /// Pop the next physical character/key typing event (for `Screen::TextInput`).
    pub fn poll_typed(&mut self) -> Option<TypedEvent> {
        if self.typed.is_empty() {
            self.drain();
        }
        self.typed.pop_front()
    }

    /// Clear queued semantic navigation events when consuming `poll_typed` directly.
    pub fn discard_navigation(&mut self) {
        self.queue.clear();
    }

    /// Discard buffered events (e.g., when transitioning into or out of a foreground `/dev/fb_lcd` app).
    pub fn clear_queues(&mut self) {
        self.drain();
        self.queue.clear();
        self.typed.clear();
        self.esc_down_since = None;
    }

    /// Pump non-blocking reads and check whether physical `ESC` has been held for `limit`.
    pub fn poll_esc_held(&mut self, limit: Duration) -> bool {
        self.drain();
        self.queue.clear();
        self.typed.clear();
        self.esc_down_since.is_some_and(|t| t.elapsed() >= limit)
    }

    pub fn fds(&self) -> Vec<std::os::fd::BorrowedFd<'_>> {
        use std::os::fd::AsFd;
        self.devices.iter().map(|d| d.file.as_fd()).collect()
    }

    /// Block up to `timeout` until any keyboard evdev fd becomes readable (`POLLIN`),
    /// waking the UI loop in <0.1ms on physical TCA8418 keypresses while keeping CPU idle.
    pub fn wait(&self, timeout: Duration) {
        use std::os::fd::AsRawFd;
        if !self.queue.is_empty() || !self.typed.is_empty() {
            return;
        }
        let mut pfds: Vec<libc::pollfd> = self
            .devices
            .iter()
            .map(|d| libc::pollfd {
                fd: d.file.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            })
            .collect();
        if pfds.is_empty() {
            std::thread::sleep(timeout);
            return;
        }
        let ms = timeout.as_millis().min(1000) as libc::c_int;
        unsafe {
            let _ = libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, ms);
        }
    }
}

impl InputSource for EvdevSource {
    fn poll(&mut self) -> Option<KeyEvent> {
        if self.queue.is_empty() {
            self.drain();
        }
        self.queue.pop_front()
    }
}

fn has_key_bit(caps: &str, bit: usize) -> bool {
    let words: Vec<u64> = caps
        .split_whitespace()
        .filter_map(|w| u64::from_str_radix(w, 16).ok())
        .collect();
    if words.is_empty() {
        return false;
    }
    let word_idx = bit / 64;
    if word_idx >= words.len() {
        return false;
    }
    let from_right = words[words.len() - 1 - word_idx];
    ((from_right >> (bit % 64)) & 1) != 0
}

fn load_tca8418_sym_map(path: &Path) -> [u8; SYM_MAX] {
    let mut m = [0u8; SYM_MAX];
    // Defaults matched to `cz_tca8418_sym_defaults()` in `src/cz_ui.h`.
    m[26] = b'!';
    m[27] = b'@';
    m[39] = b'#';
    m[40] = b'$';
    m[41] = b'%';
    m[43] = b'^';
    m[51] = b'&';
    m[52] = b'*';
    m[53] = b'(';
    m[94] = b')';
    m[55] = b'~';
    m[69] = b'`';
    m[70] = b'_';
    m[71] = b'-';
    m[72] = b'+';
    m[73] = b'=';
    m[74] = b'[';
    m[75] = b']';
    m[76] = b'{';
    m[77] = b'}';
    m[79] = b';';
    m[80] = b':';
    m[81] = b'\'';
    m[82] = b'"';
    m[83] = b'<';
    m[85] = b'>';
    m[86] = b'\\';
    m[89] = b'|';
    m[90] = b',';
    m[91] = b'.';
    m[92] = b'/';
    m[93] = b'?';

    if let Ok(text) = std::fs::read_to_string(path) {
        for raw in text.lines() {
            let line = raw.split('#').next().unwrap_or("").trim();
            let Some(rest) = line.strip_prefix("keycode") else { continue };
            let Some((lhs, rhs)) = rest.split_once('=') else { continue };
            let Ok(kc) = lhs.trim().parse::<usize>() else { continue };
            let Some(sym) = rhs.split_whitespace().next() else { continue };
            if kc < SYM_MAX {
                if let Some(ch) = keysym_to_ascii(sym) {
                    m[kc] = ch;
                }
            }
        }
    }
    m
}

fn keysym_to_ascii(name: &str) -> Option<u8> {
    if name.len() == 1 {
        let b = name.as_bytes()[0];
        if (0x20..=0x7e).contains(&b) {
            return Some(b);
        }
    }
    Some(match name {
        "space" => b' ',
        "exclam" => b'!',
        "quotedbl" => b'"',
        "numbersign" => b'#',
        "dollar" => b'$',
        "percent" => b'%',
        "ampersand" => b'&',
        "apostrophe" | "quoteright" => b'\'',
        "parenleft" => b'(',
        "parenright" => b')',
        "asterisk" => b'*',
        "plus" => b'+',
        "comma" => b',',
        "minus" => b'-',
        "period" => b'.',
        "slash" => b'/',
        "colon" => b':',
        "semicolon" => b';',
        "less" => b'<',
        "equal" => b'=',
        "greater" => b'>',
        "question" => b'?',
        "at" => b'@',
        "bracketleft" => b'[',
        "backslash" => b'\\',
        "bracketright" => b']',
        "asciicircum" => b'^',
        "underscore" => b'_',
        "grave" | "quoteleft" => b'`',
        "braceleft" => b'{',
        "bar" => b'|',
        "braceright" => b'}',
        "asciitilde" => b'~',
        _ => return None,
    })
}

fn evdev_to_ascii(sym_map: &[u8; SYM_MAX], is_tca8418: bool, code: u16, shift: bool) -> Option<char> {
    let idx = usize::from(code);
    if is_tca8418 && idx < SYM_MAX && sym_map[idx] != 0 {
        return Some(sym_map[idx] as char);
    }
    let ch = match code {
        30 => if shift { 'A' } else { 'a' },
        48 => if shift { 'B' } else { 'b' },
        46 => if shift { 'C' } else { 'c' },
        32 => if shift { 'D' } else { 'd' },
        18 => if shift { 'E' } else { 'e' },
        33 => if shift { 'F' } else { 'f' },
        34 => if shift { 'G' } else { 'g' },
        35 => if shift { 'H' } else { 'h' },
        23 => if shift { 'I' } else { 'i' },
        36 => if shift { 'J' } else { 'j' },
        37 => if shift { 'K' } else { 'k' },
        38 => if shift { 'L' } else { 'l' },
        50 => if shift { 'M' } else { 'm' },
        49 => if shift { 'N' } else { 'n' },
        24 => if shift { 'O' } else { 'o' },
        25 => if shift { 'P' } else { 'p' },
        16 => if shift { 'Q' } else { 'q' },
        19 => if shift { 'R' } else { 'r' },
        31 => if shift { 'S' } else { 's' },
        20 => if shift { 'T' } else { 't' },
        22 => if shift { 'U' } else { 'u' },
        47 => if shift { 'V' } else { 'v' },
        17 => if shift { 'W' } else { 'w' },
        45 => if shift { 'X' } else { 'x' },
        21 => if shift { 'Y' } else { 'y' },
        44 => if shift { 'Z' } else { 'z' },
        2 => if shift { '!' } else { '1' },
        3 => if shift { '@' } else { '2' },
        4 => if shift { '#' } else { '3' },
        5 => if shift { '$' } else { '4' },
        6 => if shift { '%' } else { '5' },
        7 => if shift { '^' } else { '6' },
        8 => if shift { '&' } else { '7' },
        9 => if shift { '*' } else { '8' },
        10 => if shift { '(' } else { '9' },
        11 => if shift { ')' } else { '0' },
        12 => if shift { '_' } else { '-' },
        13 => if shift { '+' } else { '=' },
        26 => if shift { '{' } else { '[' },
        27 => if shift { '}' } else { ']' },
        43 => if shift { '|' } else { '\\' },
        39 => if shift { ':' } else { ';' },
        40 => if shift { '"' } else { '\'' },
        41 => if shift { '~' } else { '`' },
        51 => if shift { '<' } else { ',' },
        52 => if shift { '>' } else { '.' },
        53 => if shift { '?' } else { '/' },
        57 => ' ',
        _ => return None,
    };
    Some(ch)
}

/// Optional single-touch pad source (kept for upstream Flipper One compatibility).
pub struct TouchpadSource {
    device: File,
    queue: VecDeque<Touch>,
    buf: [u8; EVENT_SIZE * 32],
    at: Touch,
    sent: Option<Touch>,
}

const TOUCHPAD_NAME: &str = "Flipper One Touchpad";
const EV_SYN: u16 = 0;
const EV_ABS: u16 = 3;
const ABS_X: u16 = 0;
const ABS_Y: u16 = 1;
const BTN_TOUCH: u16 = 0x14a;

impl TouchpadSource {
    pub fn open() -> std::io::Result<Self> {
        let mut path = None;
        for entry in std::fs::read_dir("/sys/class/input")? {
            let entry = entry?;
            let node = entry.file_name();
            let Some(node) = node.to_str() else { continue };
            if !node.starts_with("event") {
                continue;
            }
            let Ok(name) = std::fs::read_to_string(entry.path().join("device/name")) else {
                continue;
            };
            if name.trim() == TOUCHPAD_NAME {
                path = Some(PathBuf::from("/dev/input").join(node));
                break;
            }
        }
        let Some(path) = path else {
            return Err(std::io::Error::other(format!("no input device named {TOUCHPAD_NAME}")));
        };
        let device = OpenOptions::new().read(true).custom_flags(libc_o_nonblock()).open(path)?;
        Ok(Self {
            device,
            queue: VecDeque::new(),
            buf: [0; EVENT_SIZE * 32],
            at: Touch { x: 0, y: 0, down: false },
            sent: None,
        })
    }

    pub fn poll(&mut self) -> Option<Touch> {
        if self.queue.is_empty() {
            self.drain();
        }
        self.queue.pop_front()
    }

    fn drain(&mut self) {
        loop {
            let read = match self.device.read(&mut self.buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            for chunk in self.buf[..read].chunks_exact(EVENT_SIZE) {
                let kind = u16::from_ne_bytes([chunk[16], chunk[17]]);
                let code = u16::from_ne_bytes([chunk[18], chunk[19]]);
                let value = i32::from_ne_bytes([chunk[20], chunk[21], chunk[22], chunk[23]]);
                match (kind, code) {
                    (EV_ABS, ABS_X) => self.at.x = value,
                    (EV_ABS, ABS_Y) => self.at.y = value,
                    (EV_KEY, BTN_TOUCH) => self.at.down = value != 0,
                    (EV_SYN, 0) => {
                        if self.sent != Some(self.at) {
                            self.sent = Some(self.at);
                            self.queue.push_back(self.at);
                        }
                    }
                    _ => {}
                }
            }
            if read < EVENT_SIZE {
                break;
            }
        }
    }

    pub fn fd(&self) -> std::os::fd::BorrowedFd<'_> {
        use std::os::fd::AsFd;
        self.device.as_fd()
    }
}

const fn libc_o_nonblock() -> i32 {
    0o4000
}
