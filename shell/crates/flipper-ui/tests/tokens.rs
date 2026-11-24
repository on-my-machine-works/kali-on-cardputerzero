//! Invariants on the generated Kali x CardputerZero theme (320x170 RGB565).

use flipper_ui::pixel::Gray8;
use flipper_ui::theme;

#[test]
fn colours_round_trip_through_rgb565_and_xrgb8888() {
    for (name, hex, r, g, b) in theme::ALL_COLORS {
        let px = Gray8::from_rgb(r, g, b);
        let word = px.to_xrgb8888();
        let back = Gray8::from_rgb(
            ((word >> 16) & 0xff) as u8,
            ((word >> 8) & 0xff) as u8,
            (word & 0xff) as u8,
        );
        assert_eq!(back, px, "token `{name}` = {hex} does not round-trip through XRGB8888");
    }
}

#[test]
fn metrics_are_sane_pixel_counts() {
    for (name, value) in theme::ALL_METRIC {
        assert!(
            value > -32 && value < 512,
            "metric `{name}` = {value} is not a plausible pixel count for a 320x170 panel"
        );
    }
    for (name, value) in theme::ALL_RADIUS {
        let allowed: &[i32] = if name == "popup" { &[5] } else { &[0, 2, 3, 4] };
        assert!(allowed.contains(&value), "radius `{name}` = {value}, expected one of {allowed:?}");
    }
    for (name, value) in theme::ALL_TIMING {
        assert!(value > 0, "timing `{name}` = {value} must be positive");
    }
}

#[test]
fn rust_and_slint_themes_declare_the_same_tokens() {
    let slint = include_str!(concat!(env!("OUT_DIR"), "/theme.slint"));

    for (name, ..) in theme::ALL_COLORS {
        assert!(
            slint.contains(&format!(" {name}: ")),
            "colour `{name}` is in the Rust theme but not the Slint theme"
        );
    }
    for (name, _) in theme::ALL_METRIC {
        assert!(
            slint.contains(&format!(" {name}: ")),
            "metric `{name}` is in the Rust theme but not the Slint theme"
        );
    }
    for (name, _) in theme::ALL_TIMING {
        assert!(
            slint.contains(&format!(" {name}: ")),
            "timing `{name}` is in the Rust theme but not the Slint theme"
        );
    }
}

#[test]
fn panel_geometry_matches_cardputerzero_st7789v3() {
    assert_eq!((theme::PANEL_W, theme::PANEL_H), (320, 170));
}

#[test]
fn soft_key_row_matches_cardputerzero_keys_4_to_8() {
    use flipper_ui::FlipperKey;

    let names: Vec<&str> = FlipperKey::SOFT_ROW.iter().map(|k| k.name()).collect();
    assert_eq!(names, ["esc", "view", "power", "edit", "run"]);

    // KEY_4, KEY_5, KEY_6, KEY_7, KEY_8 (`5..=9`) directly beneath the 320x170 LCD.
    let codes = [5u16, 6, 7, 8, 9];
    for (code, expected) in codes.iter().zip(FlipperKey::SOFT_ROW) {
        assert_eq!(
            FlipperKey::from_evdev(*code),
            Some(expected),
            "keycode {code} should be {}",
            expected.name()
        );
    }
}

#[test]
fn fzxc_keys_act_as_arrows_in_menus() {
    use flipper_ui::key::code;
    use flipper_ui::FlipperKey;

    assert_eq!(FlipperKey::from_evdev(code::KEY_F), Some(FlipperKey::Up));
    assert_eq!(FlipperKey::from_evdev(code::KEY_Z), Some(FlipperKey::Left));
    assert_eq!(FlipperKey::from_evdev(code::KEY_X), Some(FlipperKey::Down));
    assert_eq!(FlipperKey::from_evdev(code::KEY_C), Some(FlipperKey::Right));
}

#[test]
fn soft_keys_emit_flipper_wire_codes_for_hosted_apps() {
    use flipper_ui::key::code;
    use flipper_ui::FlipperKey;

    // Physical `4..8` -> `Escape..Run`, which forward to hosted Wayland apps as
    // `z/x/c/v/b` (`KEY_Z..KEY_B`) and `~` (`Ptt`) as `a` (`KEY_A`), matching
    // Flipper Catalogue `.AppImage` bundles, Doom, and Python/JS runtimes.
    assert_eq!(FlipperKey::Escape.to_evdev(), code::KEY_Z);
    assert_eq!(FlipperKey::View.to_evdev(), code::KEY_X);
    assert_eq!(FlipperKey::Power.to_evdev(), code::KEY_C);
    assert_eq!(FlipperKey::Edit.to_evdev(), code::KEY_V);
    assert_eq!(FlipperKey::Run.to_evdev(), code::KEY_B);
    assert_eq!(FlipperKey::Ptt.to_evdev(), code::KEY_A);
}

#[test]
fn key_names_round_trip() {
    use flipper_ui::FlipperKey;

    let mut seen = std::collections::HashSet::new();
    for key in FlipperKey::ALL {
        assert!(seen.insert(key.name()), "duplicate key name {}", key.name());
        assert_eq!(FlipperKey::from_name(key.name()), Some(key));
    }
    assert_eq!(FlipperKey::from_name("del"), None);
}

#[test]
fn button_bar_centers_align_with_physical_keys_4_to_8() {
    use flipper_ui::layout::{soft_slot_center_x, soft_slot_x};
    use flipper_ui::FlipperKey;

    assert_eq!(FlipperKey::SOFT_ROW.len(), 5);
    assert_eq!([0, 1, 2, 3, 4].map(soft_slot_x), [22, 78, 134, 190, 246]);
    // Exact centers from `cz_ui.h` `CZ_SOFTKEY_X = {48, 104, 160, 216, 272}`.
    assert_eq!([0, 1, 2, 3, 4].map(soft_slot_center_x), [48, 104, 160, 216, 272]);
}

#[test]
fn the_list_fits_above_the_soft_button_strip() {
    use flipper_ui::theme::{count, metric};

    let rows = count::LIST_VISIBLE_ROWS;
    let viewport = rows * metric::MENU_LINE_H + (rows - 1);
    assert_eq!(viewport, metric::LIST_VIEWPORT_H, "{rows} rows plus dividers");

    let main_bottom = metric::LIST_CONTAINER_Y + viewport;
    let sub_bottom = metric::SUBMENU_CONTAINER_Y + viewport;
    let strip_top = i32::from(flipper_ui::PANEL_H) - metric::BUTTON_H;
    assert!(main_bottom <= strip_top);
    assert!(sub_bottom <= strip_top);
}
