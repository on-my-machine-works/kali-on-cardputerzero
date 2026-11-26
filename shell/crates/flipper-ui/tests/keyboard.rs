//! CardputerZero physical-keyboard `TextInput` field tests: direct typing, caret
//! movement, horizontal windowing, `Enter` confirmation, and `Esc` discard guard.

use flipper_ui::key::FlipperKey::{Back, Down, Edit, Left, Ok, Right, Run, Up};
use flipper_ui::keyboard::{self, Exit, Focus, Grid, Layout, TextInput};

fn press(input: &mut TextInput, key: flipper_ui::key::FlipperKey) -> Option<Exit> {
    input.key(key, true)
}

#[test]
fn grid_geometry_invariants_remain_sound() {
    let grid = Grid::new(Layout::Abc);
    assert_eq!(grid.width(), 235);
    assert_eq!(grid.row_width(0), 200);
    assert_eq!(grid.row_width(1), 235);
    assert_eq!((grid.cell_x(1, 0), grid.cell_x(2, 1), grid.cell_x(3, 1)), (35, 35, 35));
}

#[test]
fn text_input_opens_focused_on_field_without_virtual_cells() {
    let input = TextInput::new("Password for cybercats", "abc");
    assert_eq!(input.focus, Focus::Field);
    assert_eq!(input.cursor, 3, "the caret starts after the seeded text");
    assert!(input.placed().is_empty(), "standard field prompts place no virtual keyboard cells");
}

#[test]
fn enter_and_ok_always_confirm_when_valid_from_anywhere() {
    let mut input = TextInput::new("Profile name", "default");
    // Even before typing or after pressing Up/Down, focus stays on Field and Enter saves.
    press(&mut input, Down);
    press(&mut input, Up);
    assert_eq!(input.focus, Focus::Field);
    assert_eq!(input.key(Ok, false), None);
    assert_eq!(input.type_enter(false), None);
    assert_eq!(input.key(Ok, true), Some(Exit::Save("default".into())));
    assert_eq!(input.type_enter(true), Some(Exit::Save("default".into())));
    assert_eq!(input.key(Run, true), Some(Exit::Save("default".into())));
}

#[test]
fn caret_editing_moves_deletes_and_clears_inside_field() {
    let mut input = TextInput::new("Password", "abcd");
    input.move_left();
    input.move_left();
    assert_eq!(input.cursor, 2);
    input.type_char('8');
    assert_eq!(input.text, "ab8cd");
    input.type_delete();
    assert_eq!(input.text, "ab8d");
    input.move_home();
    assert_eq!(input.cursor, 0);
    input.type_char('4');
    assert_eq!(input.text, "4ab8d");
    input.move_end();
    assert_eq!(input.cursor, 5);
    press(&mut input, Left);
    press(&mut input, Edit);
    assert_eq!(input.text, "4abd");
    press(&mut input, Right);
    assert_eq!(input.cursor, 4);
    input.clear_line();
    assert_eq!(input.text, "");
    assert_eq!(input.cursor, 0);
}

#[test]
fn leaving_asks_only_when_there_is_something_to_lose() {
    let mut unchanged = TextInput::new("t", "abc");
    assert_eq!(press(&mut unchanged, Back), Some(Exit::Cancel));

    let mut changed = TextInput::new("t", "abc");
    changed.type_char('q');
    assert_eq!(press(&mut changed, Back), None);
    assert_eq!(changed.discard, Some(0), "Keep is highlighted first");
    // Keep dismisses and the text survives.
    assert_eq!(changed.type_enter(true), None);
    assert_eq!(changed.discard, None);
    assert!(changed.text.ends_with('q'));
    // Discard leaves via either arrow or letter nav + Enter.
    press(&mut changed, Back);
    changed.type_char('x');
    assert_eq!(changed.discard, Some(1));
    assert_eq!(changed.type_enter(true), Some(Exit::Cancel));
}

#[test]
fn short_text_is_not_truncated() {
    let fitted = keyboard::fit_input("abc", 3, 138);
    assert_eq!(fitted.visible, "abc");
    assert_eq!(fitted.cursor_dx, i32::from(flipper_ui::font::TITLE.text_width("abc")) + 1);
}

#[test]
fn long_text_is_windowed_around_the_caret() {
    let long = "abcdefghijklmnopqrstuvwxyz0123456789";
    let inner = 60;

    let at_start = keyboard::fit_input(long, 0, inner);
    assert!(at_start.visible.starts_with('a'), "{}", at_start.visible);
    assert!(at_start.visible.ends_with("...>"), "{}", at_start.visible);

    let at_end = keyboard::fit_input(long, long.len(), inner);
    assert!(at_end.visible.starts_with("<..."), "{}", at_end.visible);
    assert!(at_end.visible.ends_with('9'), "{}", at_end.visible);

    let middle = keyboard::fit_input(long, 18, inner);
    assert!(middle.visible.starts_with("<..."), "{}", middle.visible);
    assert!(middle.visible.ends_with("...>"), "{}", middle.visible);
    for f in [&at_start, &at_end, &middle] {
        assert!(
            i32::from(flipper_ui::font::TITLE.text_width(&f.visible)) <= inner,
            "{} overruns the field",
            f.visible
        );
    }
}

#[test]
fn the_field_grows_with_the_text() {
    assert_eq!(keyboard::field_w(0), 160, "the minimum");
    assert_eq!(keyboard::field_w(200), 212);
    assert_eq!(keyboard::field_w(1000), 296, "the cap");
}

#[test]
fn physical_cardputer_typing_inserts_digits_4_to_8_and_fzxc_and_commits() {
    let mut input = TextInput::new("Wi-Fi passphrase", "");
    for ch in "fzxcFZXC#45678!".chars() {
        input.type_char(ch);
    }
    assert_eq!(input.text, "fzxcFZXC#45678!");
    input.type_backspace();
    assert_eq!(input.text, "fzxcFZXC#45678");
    assert_eq!(input.type_enter(false), None);
    assert_eq!(input.type_enter(true), Some(Exit::Save("fzxcFZXC#45678".into())));
}
