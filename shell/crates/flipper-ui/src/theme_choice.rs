//! Runtime UI palette selection (`Kali Dark`, `OG Flipper`, `Flipper Mono`).
//!
//! All colour hex values originate solely in `tokens.toml` (`[color]`,
//! `[palette.og_flipper]`, `[palette.flipper_mono]`) and are compiled by
//! `flipper-tokens` into `theme::palette::*` and `apply_slint_palette!`.
//!
//! The chosen theme is persisted to `~/.config/flipctl/theme` (falling back to
//! `/tmp/flipctl-theme`) so both `flipctl` and hosted Wayland `flipctl-app`
//! clients stay in sync live without restarting services.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, Ordering};

use crate::pixel::Gray8;
use crate::theme::{palette, Palette};

#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum ThemeChoice {
    #[default]
    KaliDark = 0,
    OgFlipper = 1,
    FlipperMono = 2,
}

impl ThemeChoice {
    pub const ALL: [Self; 3] = [Self::KaliDark, Self::OgFlipper, Self::FlipperMono];

    pub const fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::OgFlipper,
            2 => Self::FlipperMono,
            _ => Self::KaliDark,
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "kali" | "kali-dark" | "kali_dark" | "dark" => Some(Self::KaliDark),
            "og" | "og-flipper" | "og_flipper" | "orange" | "flipper-zero" => Some(Self::OgFlipper),
            "mono" | "light" | "flipper-mono" | "flipper_mono" | "paper" => Some(Self::FlipperMono),
            _ => None,
        }
    }

    pub const fn slug(self) -> &'static str {
        match self {
            Self::KaliDark => "kali-dark",
            Self::OgFlipper => "og-flipper",
            Self::FlipperMono => "flipper-mono",
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::KaliDark => "Kali Dark",
            Self::OgFlipper => "OG Flipper",
            Self::FlipperMono => "Flipper Mono",
        }
    }

    pub const fn palette(self) -> Palette {
        match self {
            Self::KaliDark => palette::DEFAULT,
            Self::OgFlipper => palette::OG_FLIPPER,
            Self::FlipperMono => palette::FLIPPER_MONO,
        }
    }

    pub const fn step(self, right: bool) -> Self {
        let idx = self as usize;
        let next = if right { (idx + 1) % 3 } else { (idx + 2) % 3 };
        Self::ALL[next]
    }
}

static CURRENT: AtomicU8 = AtomicU8::new(0);

fn state_path() -> PathBuf {
    crate::app::xdg_home("XDG_CONFIG_HOME", ".config").join("flipctl/theme")
}

/// Load the saved theme from disk (or `FLIPCTL_THEME` env override) and cache it.
pub fn load() -> ThemeChoice {
    if let Ok(env_val) = std::env::var("FLIPCTL_THEME") {
        if let Some(choice) = ThemeChoice::parse(&env_val) {
            CURRENT.store(choice as u8, Ordering::Relaxed);
            return choice;
        }
    }
    for path in [state_path(), PathBuf::from("/tmp/flipctl-theme")] {
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Some(choice) = ThemeChoice::parse(&text) {
                CURRENT.store(choice as u8, Ordering::Relaxed);
                return choice;
            }
        }
    }
    ThemeChoice::from_u8(CURRENT.load(Ordering::Relaxed))
}

/// Current cached theme in this process.
pub fn current() -> ThemeChoice {
    ThemeChoice::from_u8(CURRENT.load(Ordering::Relaxed))
}

/// Set active theme in memory without writing to disk (for `--png --theme ...` & tests).
pub fn set_ephemeral(choice: ThemeChoice) {
    CURRENT.store(choice as u8, Ordering::Relaxed);
}

/// Persist `choice` to disk and update the in-process cache.
pub fn save(choice: ThemeChoice) {
    CURRENT.store(choice as u8, Ordering::Relaxed);
    let primary = state_path();
    if let Some(parent) = primary.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::write(&primary, format!("{}\n", choice.slug())).is_err() {
        let _ = std::fs::write("/tmp/flipctl-theme", format!("{}\n", choice.slug()));
    }
}

/// Step to the previous/next theme, persist it, and return the new choice.
pub fn step_and_save(right: bool) -> ThemeChoice {
    let next = current().step(right);
    save(next);
    next
}

///Formatted `< Theme >` status string for menu rows.
pub fn status_text() -> String {
    format!("< {} >", current().label())
}

/// Active canvas ground and primary ink as `Gray8` RGB565 (for QR codes & `sway.conf`).
pub fn ground_and_ink() -> (Gray8, Gray8) {
    let p = current().palette();
    (Gray8::from_rgb(p.white.0, p.white.1, p.white.2), Gray8::from_rgb(p.black.0, p.black.1, p.black.2))
}
