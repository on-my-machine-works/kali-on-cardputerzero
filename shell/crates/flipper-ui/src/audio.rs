//! Onboard ES8389 / PipeWire audio volume & mute controls for CardputerZero.
//!
//! Queries PipeWire/WirePlumber (`wpctl` against `/run/user/1000`, falling back to
//! ALSA `amixer -c 0`) off the render thread so menu redraws stay lock-step at 60 fps.

use std::path::Path;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
struct AudioSnapshot {
    percent: u8,
    muted: bool,
    at: Option<Instant>,
    inflight: bool,
}

fn cache() -> &'static Mutex<AudioSnapshot> {
    static CACHE: OnceLock<Mutex<AudioSnapshot>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(AudioSnapshot {
            percent: 60,
            muted: false,
            at: None,
            inflight: false,
        })
    })
}

fn runtime_dir() -> String {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() && Path::new(&dir).is_dir() {
            return dir;
        }
    }
    if Path::new("/run/user/1000").is_dir() {
        return "/run/user/1000".into();
    }
    let uid = unsafe { libc::getuid() };
    format!("/run/user/{uid}")
}

/// Parse `wpctl get-volume @DEFAULT_AUDIO_SINK@` output, e.g.:
///   `Volume: 0.51` -> `Some((51, false))`
///   `Volume: 0.70 [MUTED]` -> `Some((70, true))`
pub fn parse_wpctl_volume(out: &str) -> Option<(u8, bool)> {
    let line = out.lines().find(|l| l.contains("Volume:"))?;
    let after = line.split("Volume:").nth(1)?.trim();
    let num_tok = after.split_whitespace().next()?;
    let val: f32 = num_tok.parse().ok()?;
    let pct = (val * 100.0).round().clamp(0.0, 100.0) as u8;
    let muted = after.contains("[MUTED]");
    Some((pct, muted))
}

/// Parse `amixer -c 0 sget Master` output, e.g. `Mono: Playback 192 [75%] [on]`.
pub fn parse_amixer_volume(out: &str) -> Option<(u8, bool)> {
    let mut pct: Option<u8> = None;
    let mut muted = false;
    for line in out.lines() {
        if let Some(rest) = line.split('[').nth(1) {
            if let Some(num) = rest.split("%]").next() {
                if let Ok(v) = num.trim().parse::<u8>() {
                    pct = Some(v.min(100));
                }
            }
        }
        if line.contains("[off]") {
            muted = true;
        }
    }
    pct.map(|p| (p, muted))
}

fn query_live() -> Option<(u8, bool)> {
    let xdg = runtime_dir();
    if Path::new("/usr/bin/wpctl").exists() {
        if let Ok(out) = Command::new("/usr/bin/wpctl")
            .args(["get-volume", "@DEFAULT_AUDIO_SINK@"])
            .env("XDG_RUNTIME_DIR", &xdg)
            .output()
        {
            if out.status.success() {
                if let Some(parsed) = parse_wpctl_volume(&String::from_utf8_lossy(&out.stdout)) {
                    return Some(parsed);
                }
            }
        }
    }
    if Path::new("/usr/bin/amixer").exists() {
        if let Ok(out) = Command::new("/usr/bin/amixer").args(["-c", "0", "sget", "Master"]).output()
        {
            if out.status.success() {
                if let Some(parsed) = parse_amixer_volume(&String::from_utf8_lossy(&out.stdout)) {
                    return Some(parsed);
                }
            }
        }
    }
    None
}

fn ensure_fresh() -> (u8, bool) {
    let mut should_spawn = false;
    let snap = {
        let mut g = cache().lock().unwrap_or_else(|e| e.into_inner());
        let stale = g.at.is_none_or(|t| t.elapsed() >= Duration::from_secs(3));
        if stale && !g.inflight {
            if g.at.is_none() {
                // Seed synchronously once on first visit so initial render shows true volume.
                g.inflight = true;
                drop(g);
                let initial = query_live().unwrap_or((60, false));
                let mut g2 = cache().lock().unwrap_or_else(|e| e.into_inner());
                g2.percent = initial.0;
                g2.muted = initial.1;
                g2.at = Some(Instant::now());
                g2.inflight = false;
                return initial;
            }
            g.inflight = true;
            should_spawn = true;
        }
        (g.percent, g.muted)
    };
    if should_spawn {
        thread::spawn(|| {
            let res = query_live();
            let mut g = cache().lock().unwrap_or_else(|e| e.into_inner());
            if let Some((pct, muted)) = res {
                g.percent = pct;
                g.muted = muted;
                g.at = Some(Instant::now());
            } else {
                g.at = Some(Instant::now());
            }
            g.inflight = false;
        });
    }
    snap
}

pub fn status() -> String {
    let (pct, muted) = ensure_fresh();
    if muted {
        "< Muted >".into()
    } else {
        format!("< {pct}% >")
    }
}

pub fn ends() -> (bool, bool) {
    let (pct, muted) = ensure_fresh();
    (!muted && pct == 0, !muted && pct >= 100)
}

pub fn step_volume(up: bool) -> bool {
    const STEPS: [u8; 11] = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
    let (cur_pct, cur_muted) = ensure_fresh();
    let next_pct = if up {
        STEPS.into_iter().find(|&s| s > cur_pct).unwrap_or(100)
    } else {
        STEPS.into_iter().rev().find(|&s| s < cur_pct).unwrap_or(0)
    };
    if next_pct == cur_pct && !cur_muted {
        return false;
    }
    {
        let mut g = cache().lock().unwrap_or_else(|e| e.into_inner());
        g.percent = next_pct;
        g.muted = false;
        g.at = Some(Instant::now());
    }
    thread::spawn(move || {
        let xdg = runtime_dir();
        let arg = format!("{next_pct}%");
        let mut applied = false;
        if Path::new("/usr/bin/wpctl").exists() {
            let _ = Command::new("/usr/bin/wpctl")
                .args(["set-mute", "@DEFAULT_AUDIO_SINK@", "0"])
                .env("XDG_RUNTIME_DIR", &xdg)
                .status();
            applied = Command::new("/usr/bin/wpctl")
                .args(["set-volume", "@DEFAULT_AUDIO_SINK@", &arg])
                .env("XDG_RUNTIME_DIR", &xdg)
                .status()
                .is_ok_and(|s| s.success());
        }
        if !applied && Path::new("/usr/bin/amixer").exists() {
            let _ = Command::new("/usr/bin/amixer")
                .args(["-c", "0", "sset", "Master", &arg, "unmute"])
                .status();
        }
    });
    true
}

pub fn toggle_mute() -> bool {
    let (_, cur_muted) = ensure_fresh();
    let next_muted = !cur_muted;
    {
        let mut g = cache().lock().unwrap_or_else(|e| e.into_inner());
        g.muted = next_muted;
        g.at = Some(Instant::now());
    }
    thread::spawn(move || {
        let xdg = runtime_dir();
        let mut applied = false;
        if Path::new("/usr/bin/wpctl").exists() {
            applied = Command::new("/usr/bin/wpctl")
                .args(["set-mute", "@DEFAULT_AUDIO_SINK@", if next_muted { "1" } else { "0" }])
                .env("XDG_RUNTIME_DIR", &xdg)
                .status()
                .is_ok_and(|s| s.success());
        }
        if !applied && Path::new("/usr/bin/amixer").exists() {
            let _ = Command::new("/usr/bin/amixer")
                .args(["-c", "0", "sset", "Master", if next_muted { "mute" } else { "unmute" }])
                .status();
        }
    });
    true
}

/// Non-blocking Bluetooth adapter status for the `Network -> Bluetooth` row.
pub fn bluetooth_status() -> String {
    if !Path::new("/sys/class/bluetooth/hci0").exists() {
        return "N/A".into();
    }
    if let Ok(entries) = std::fs::read_dir("/sys/class/rfkill") {
        for e in entries.flatten() {
            let ty = std::fs::read_to_string(e.path().join("type")).unwrap_or_default();
            if ty.trim() == "bluetooth" {
                let soft = std::fs::read_to_string(e.path().join("soft")).unwrap_or_default();
                if soft.trim() == "1" {
                    return "OFF".into();
                }
            }
        }
    }
    "ON".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wpctl_and_amixer_outputs() {
        assert_eq!(parse_wpctl_volume("Volume: 0.51\n"), Some((51, false)));
        assert_eq!(parse_wpctl_volume("Volume: 0.70 [MUTED]\n"), Some((70, true)));
        assert_eq!(parse_wpctl_volume("Volume: 1.25\n"), Some((100, false)));

        let amix = "Simple mixer control 'Master',0\n  Front Left: Playback 192 [75%] [on]\n";
        assert_eq!(parse_amixer_volume(amix), Some((75, false)));
        let amix_mute = "Simple mixer control 'Master',0\n  Mono: Playback 0 [0%] [off]\n";
        assert_eq!(parse_amixer_volume(amix_mute), Some((0, true)));
    }
}
