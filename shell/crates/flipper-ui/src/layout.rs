//! Layout arithmetic shared between the Rust side and the tests.
//!
//! The .slint components mirror these rules inline; the tests here are what stop
//! the two drifting.

use crate::theme::metric;
use crate::FlipperKey;

/// The column a hosted app's gauge bar starts in, given its own label.
///
/// Only for an app: the label is the app's to choose, so the bar has to be placed
/// around it. A labelled bar clears its label and never starts before
/// the fixed column, and a gauge with no label starts at the margin and takes the
/// whole line.
///
/// A first-party screen does not call this. Those screens are fixed geometry and
/// their gauges sit at `metric::GAUGE_COL` whatever the label reads, which is what
/// keeps the battery and disk bars still.
pub fn gauge_col_fit(label_w: u16) -> i32 {
    if label_w == 0 {
        return 0;
    }
    metric::GAUGE_COL.max(i32::from(label_w) + metric::GAUGE_LABEL_GAP)
}

/// Left edge of bottom-bar slot `slot`, counting from 0.
///
/// A uniform grid, because the approved geometry adds up: 5 * 48 + 4 * 4 = 256,
/// so both outer edges land flush without special-casing either end.
///
/// ```text
///  0..47   52..99   104..151   156..203   208..255
/// ```
///
/// canvas.js did special-case it, tiling from the left with a 2px gap and then
/// anchoring the right button at `screenW - w`, which left a 10px hole before the
/// last slot. The approved design removes that asymmetry.
/// Left edge of bottom-bar slot `slot`, aligned to CardputerZero physical keys
/// `4`, `5`, `6`, `7`, `8` (`X = 48, 104, 160, 216, 272`).
pub fn soft_slot_x(slot: usize) -> i32 {
    metric::SOFT_BAR_X + slot as i32 * (metric::BUTTON_W + metric::BUTTON_GAP)
}

/// Center X coordinate of bottom-bar slot `slot`.
pub fn soft_slot_center_x(slot: usize) -> i32 {
    soft_slot_x(slot) + metric::BUTTON_W / 2
}

/// On CardputerZero `soft_bar_x = 22` leaves 22px margins on both sides so every
/// softkey sits directly above keys `4`..`8` with symmetric chamfered corners.
pub fn soft_slot_flush(_slot: usize) -> (bool, bool) {
    (false, false)
}

/// Total span of the five softkey slots (`5 * 52 + 4 * 4 = 276`).
pub fn soft_row_width() -> i32 {
    let n = FlipperKey::SOFT_ROW.len() as i32;
    n * metric::BUTTON_W + (n - 1) * metric::BUTTON_GAP
}
