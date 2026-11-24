//! Semantic buttons mapped to M5Stack CardputerZero's physical keyboard & softkeys.
//!
//! CardputerZero places five number keys directly beneath the 320x170 LCD:
//! **`4`, `5`, `6`, `7`, `8`** (`KEY_4..KEY_8 = 5..9`, or `KEY_F4..KEY_F8 = 62..66`
//! when `Fn` is active/locked on `TCA8418`) at horizontal centers
//! `48, 104, 160, 216, 272`. `SOFT_ROW` maps 1:1 onto those five physical keys,
//! while navigation works with BOTH `Fn + F/Z/X/C` hardware arrows AND unmodified
//! `F/Z/X/C` (`Up/Left/Down/Right`), `W/A/S/D`, or `H/J/K/L` keys in menus
//! (`TextInput` intercepts literal typing first).

/// A semantic button in the UI.
#[derive(Copy, Clone, PartialEq, Eq, Debug, Hash)]
pub enum FlipperKey {
    Up,
    Down,
    Left,
    Right,
    /// Confirm / Enter / Space.
    Ok,
    /// Back (`Esc`, `Backspace`, or `Q` in menus).
    Back,
    /// App switcher (`Tab`).
    AppSwitch,
    /// Push-to-talk / auxiliary action (`~` / `Grave`).
    Ptt,
    /// Bottom softkey row, aligned over physical keys `4`, `5`, `6`, `7`, `8`.
    Escape,
    View,
    Power,
    Edit,
    Run,
}

/// Linux evdev keycodes (`<linux/input-event-codes.h>`).
pub mod code {
    pub const KEY_ESC: u16 = 1;
    pub const KEY_4: u16 = 5;
    pub const KEY_5: u16 = 6;
    pub const KEY_6: u16 = 7;
    pub const KEY_7: u16 = 8;
    pub const KEY_8: u16 = 9;
    pub const KEY_BACKSPACE: u16 = 14;
    pub const KEY_TAB: u16 = 15;
    pub const KEY_Q: u16 = 16;
    pub const KEY_W: u16 = 17;
    pub const KEY_ENTER: u16 = 28;
    pub const KEY_A: u16 = 30;
    pub const KEY_S: u16 = 31;
    pub const KEY_D: u16 = 32;
    pub const KEY_F: u16 = 33;
    pub const KEY_H: u16 = 35;
    pub const KEY_J: u16 = 36;
    pub const KEY_K: u16 = 37;
    pub const KEY_L: u16 = 38;
    pub const KEY_GRAVE: u16 = 41;
    pub const KEY_Z: u16 = 44;
    pub const KEY_X: u16 = 45;
    pub const KEY_C: u16 = 46;
    pub const KEY_V: u16 = 47;
    pub const KEY_B: u16 = 48;
    pub const KEY_SPACE: u16 = 57;
    pub const KEY_F1: u16 = 59;
    pub const KEY_F2: u16 = 60;
    pub const KEY_F3: u16 = 61;
    pub const KEY_F4: u16 = 62;
    pub const KEY_F5: u16 = 63;
    pub const KEY_F6: u16 = 64;
    pub const KEY_F7: u16 = 65;
    pub const KEY_F8: u16 = 66;
    pub const KEY_KPENTER: u16 = 96;
    pub const KEY_UP: u16 = 103;
    pub const KEY_PAGEUP: u16 = 104;
    pub const KEY_LEFT: u16 = 105;
    pub const KEY_RIGHT: u16 = 106;
    pub const KEY_DOWN: u16 = 108;
    pub const KEY_PAGEDOWN: u16 = 109;
}

impl FlipperKey {
    /// Evdev code emitted when forwarding this key over the virtual Wayland keyboard
    /// to a hosted app (`sway`). Must match Flipper One's universal app wire contract
    /// (`KEYMAP` in `wl.rs`: arrows + `z/x/c/v/b` softkeys + `a` PTT) so prebuilt
    /// Flipper Catalogue `.AppImage` apps, `Doom`, `Python/JS` runtimes, and native
    /// `flipctl-app` apps all respond to CardputerZero's physical `4..8` & `F/Z/X/C` keys.
    pub const fn to_evdev(self) -> u16 {
        match self {
            Self::Up => code::KEY_UP,
            Self::Down => code::KEY_DOWN,
            Self::Left => code::KEY_LEFT,
            Self::Right => code::KEY_RIGHT,
            Self::Ok => code::KEY_ENTER,
            Self::Back => code::KEY_ESC,
            Self::AppSwitch => code::KEY_TAB,
            Self::Ptt => code::KEY_A,
            Self::Escape => code::KEY_Z,
            Self::View => code::KEY_X,
            Self::Power => code::KEY_C,
            Self::Edit => code::KEY_V,
            Self::Run => code::KEY_B,
        }
    }

    /// Map a raw `EV_KEY` code from CardputerZero's TCA8418 keypad or USB keyboard.
    pub fn from_evdev(keycode: u16) -> Option<Self> {
        Some(match keycode {
            code::KEY_UP | code::KEY_PAGEUP | code::KEY_F | code::KEY_W | code::KEY_K => Self::Up,
            code::KEY_DOWN | code::KEY_PAGEDOWN | code::KEY_X | code::KEY_S | code::KEY_J => {
                Self::Down
            }
            code::KEY_LEFT | code::KEY_Z | code::KEY_A | code::KEY_H => Self::Left,
            code::KEY_RIGHT | code::KEY_C | code::KEY_D | code::KEY_L => Self::Right,
            code::KEY_ENTER | code::KEY_KPENTER | code::KEY_SPACE => Self::Ok,
            code::KEY_ESC | code::KEY_BACKSPACE | code::KEY_Q => Self::Back,
            code::KEY_TAB => Self::AppSwitch,
            code::KEY_GRAVE => Self::Ptt,
            code::KEY_4 | code::KEY_F4 => Self::Escape,
            code::KEY_5 | code::KEY_F5 => Self::View,
            code::KEY_6 | code::KEY_F6 => Self::Power,
            code::KEY_7 | code::KEY_F7 => Self::Edit,
            code::KEY_8 | code::KEY_F8 => Self::Run,
            _ => return None,
        })
    }

    /// Stable wire name used by `:8899` Web Remote and tests.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Up => "up",
            Self::Down => "down",
            Self::Left => "left",
            Self::Right => "right",
            Self::Ok => "ok",
            Self::Back => "back",
            Self::AppSwitch => "appsw",
            Self::Ptt => "ptt",
            Self::Escape => "esc",
            Self::View => "view",
            Self::Power => "power",
            Self::Edit => "edit",
            Self::Run => "run",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|k| k.name() == name)
    }

    pub const ALL: [FlipperKey; 13] = [
        Self::Up,
        Self::Down,
        Self::Left,
        Self::Right,
        Self::Ok,
        Self::Back,
        Self::AppSwitch,
        Self::Ptt,
        Self::Escape,
        Self::View,
        Self::Power,
        Self::Edit,
        Self::Run,
    ];

    /// Bottom softkey row in physical left-to-right order (`4`, `5`, `6`, `7`, `8`).
    pub const SOFT_ROW: [FlipperKey; 5] =
        [Self::Escape, Self::View, Self::Power, Self::Edit, Self::Run];
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub struct KeyEvent {
    pub key: FlipperKey,
    pub down: bool,
}
