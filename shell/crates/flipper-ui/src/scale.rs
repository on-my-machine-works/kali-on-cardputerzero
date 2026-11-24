//! Hijacking & scaling hosted Wayland apps (such as `256x144` Flipper Catalogue
//! `.AppImage` bundles) onto CardputerZero's `320x170` RGB565 panel.
//!
//! Supports four runtime-selectable modes persisted in `~/.config/flipctl/app_scale`
//! (`Menu -> Settings -> App Scaling`):
//! - `Reflow` *(default)*: detects monochrome `256x144` Flipper UI frames (`StatusBar`,
//!   content rows/frames/gauges, and 5-slot `SoftBar`), rearranges all chrome & widgets
//!   onto `320x170` at **100% `1:1` unscaled bitmap-font sharpness**, rebuilds the 5
//!   bottom softkeys as `52x14px` chamfered tabs directly above physical keys `4..8`
//!   (`X = 48, 104, 160, 216, 272`), and re-skins monochrome frames into the active
//!   `Kali Dark` / `OG Flipper` / `Flipper Mono` theme! Automatically falls back to
//!   `Fill` for full-color games/video like `Doom`.
//! - `Fill`: stretches landscape apps edge-to-edge across `320x170` via a sharp
//!   subpixel-area coverage filter in original colours.
//! - `Fit`: preserves exact source aspect ratio (`16:9` -> `302x170` centred).
//! - `Pixel1x`: renders unscaled `1:1` pixels centred on the panel.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, Ordering};

use crate::pixel::Gray8;
use crate::theme::Palette;

#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum AppScaleMode {
    #[default]
    Reflow = 0,
    Fill = 1,
    Fit = 2,
    Pixel1x = 3,
}

impl AppScaleMode {
    pub const ALL: [Self; 4] = [Self::Reflow, Self::Fill, Self::Fit, Self::Pixel1x];

    pub const fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Fill,
            2 => Self::Fit,
            3 => Self::Pixel1x,
            _ => Self::Reflow,
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "reflow" | "ui-reflow" | "hijack" | "smart" | "auto" => Some(Self::Reflow),
            "fill" | "stretch" | "full" => Some(Self::Fill),
            "fit" | "aspect" | "16:9" => Some(Self::Fit),
            "1:1" | "1x" | "pixel" | "center" | "centre" => Some(Self::Pixel1x),
            _ => None,
        }
    }

    pub const fn slug(self) -> &'static str {
        match self {
            Self::Reflow => "reflow",
            Self::Fill => "fill",
            Self::Fit => "fit",
            Self::Pixel1x => "1:1",
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Reflow => "UI Reflow",
            Self::Fill => "Fill Screen",
            Self::Fit => "Fit Aspect",
            Self::Pixel1x => "Pixel 1:1",
        }
    }

    pub const fn step(self, right: bool) -> Self {
        let idx = self as usize;
        let next = if right { (idx + 1) % 4 } else { (idx + 3) % 4 };
        Self::ALL[next]
    }
}

const UNLOADED: u8 = u8::MAX;
static MODE: AtomicU8 = AtomicU8::new(UNLOADED);

fn state_path() -> PathBuf {
    crate::app::xdg_home("XDG_CONFIG_HOME", ".config").join("flipctl/app_scale")
}

/// Load persisted scaling mode from disk (or `FLIPCTL_APP_SCALE` env override).
pub fn load_mode() -> AppScaleMode {
    if let Ok(env_val) = std::env::var("FLIPCTL_APP_SCALE") {
        if let Some(m) = AppScaleMode::parse(&env_val) {
            MODE.store(m as u8, Ordering::Relaxed);
            return m;
        }
    }
    for path in [state_path(), PathBuf::from("/tmp/flipctl-app-scale")] {
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Some(m) = AppScaleMode::parse(&text) {
                MODE.store(m as u8, Ordering::Relaxed);
                return m;
            }
        }
    }
    let default = AppScaleMode::Reflow;
    MODE.store(default as u8, Ordering::Relaxed);
    default
}

/// Fast atomic read of the active scaling mode (lazy-loading from disk on first call).
pub fn current_mode() -> AppScaleMode {
    let raw = MODE.load(Ordering::Relaxed);
    if raw == UNLOADED {
        load_mode()
    } else {
        AppScaleMode::from_u8(raw)
    }
}

pub fn save_mode(mode: AppScaleMode) {
    MODE.store(mode as u8, Ordering::Relaxed);
    let primary = state_path();
    if let Some(parent) = primary.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::write(&primary, format!("{}\n", mode.slug())).is_err() {
        let _ = std::fs::write("/tmp/flipctl-app-scale", format!("{}\n", mode.slug()));
    }
}

pub fn step_and_save_mode(right: bool) -> AppScaleMode {
    let next = current_mode().step(right);
    save_mode(next);
    next
}

pub fn status_text() -> String {
    format!("< {} >", current_mode().label())
}

/// Compute target `(w, h, ox, oy)` inside `(dw, dh)` for linear scaling modes.
fn target_box(sw: u32, sh: u32, dw: u32, dh: u32, mode: AppScaleMode) -> (u32, u32, u32, u32) {
    match mode {
        AppScaleMode::Reflow | AppScaleMode::Fill if sw >= sh => (dw, dh, 0, 0),
        AppScaleMode::Pixel1x if sw <= dw && sh <= dh => {
            (sw, sh, (dw - sw) / 2, (dh - sh) / 2)
        }
        _ => {
            let (w, h) = if sw * dh > dw * sh {
                (dw, (sh * dw / sw).max(1))
            } else {
                ((sw * dh / sh).max(1), dh)
            };
            (w, h, (dw - w) / 2, (dh - h) / 2)
        }
    }
}

/// Scale `src` to fit `(dw, dh)` keeping aspect ratio (`Fit`), used by unit tests & thumbnails.
pub fn fit(src: &[Gray8], sw: u32, sh: u32, dst: &mut [Gray8], dw: u32, dh: u32) {
    scale_gray8(src, sw, sh, dst, dw, dh, AppScaleMode::Fit);
}

/// Scale `src` (`Gray8` RGB565) into `dst` according to `mode`.
pub fn scale_gray8(
    src: &[Gray8],
    sw: u32,
    sh: u32,
    dst: &mut [Gray8],
    dw: u32,
    dh: u32,
    mode: AppScaleMode,
) {
    if sw == 0 || sh == 0 || dw == 0 || dh == 0 {
        return;
    }
    if src.len() < (sw * sh) as usize || dst.len() < (dw * dh) as usize {
        return;
    }
    if mode == AppScaleMode::Reflow {
        let pal = crate::theme_choice::current().palette();
        if try_reflow_gray8(src, sw, sh, dst, dw, dh, &pal) {
            return;
        }
    }

    let (w, h, ox, oy) = target_box(sw, sh, dw, dh, mode);
    if w == sw && h == sh {
        for y in 0..h {
            let srow = (y * sw) as usize;
            let drow = ((oy + y) * dw + ox) as usize;
            dst[drow..drow + w as usize].copy_from_slice(&src[srow..srow + w as usize]);
        }
        return;
    }

    if sw > w || sh > h {
        for y in 0..h {
            let y0 = y * sh / h;
            let y1 = (((y + 1) * sh / h).max(y0 + 1)).min(sh);
            for x in 0..w {
                let x0 = x * sw / w;
                let x1 = (((x + 1) * sw / w).max(x0 + 1)).min(sw);
                let (mut sr, mut sg, mut sb, mut n) = (0u32, 0u32, 0u32, 0u32);
                for sy in y0..y1 {
                    let row = (sy * sw) as usize;
                    for sx in x0..x1 {
                        let (r, g, b) = src[row + sx as usize].to_rgb8();
                        sr += u32::from(r);
                        sg += u32::from(g);
                        sb += u32::from(b);
                        n += 1;
                    }
                }
                let d = n.max(1);
                dst[((oy + y) * dw + ox + x) as usize] =
                    Gray8::from_rgb((sr / d) as u8, (sg / d) as u8, (sb / d) as u8);
            }
        }
        return;
    }

    const Q8: u32 = 1 << 8;
    let x_spans: Vec<(usize, usize, u32)> = (0..w).map(|x| subpixel_span(x, sw, w)).collect();

    for y in 0..h {
        let (iy0, iy1, wy0) = subpixel_span(y, sh, h);
        let wy1 = Q8 - wy0;
        let r0 = iy0 * sw as usize;
        let r1 = iy1 * sw as usize;
        let drow = ((oy + y) * dw + ox) as usize;

        for (x, &(ix0, ix1, wx0)) in x_spans.iter().enumerate() {
            if wx0 == Q8 && wy0 == Q8 {
                dst[drow + x] = src[r0 + ix0];
                continue;
            }
            let wx1 = Q8 - wx0;
            let (r00, g00, b00) = src[r0 + ix0].to_rgb8();
            let (r10, g10, b10) = src[r0 + ix1].to_rgb8();
            let (r01, g01, b01) = src[r1 + ix0].to_rgb8();
            let (r11, g11, b11) = src[r1 + ix1].to_rgb8();

            let w00 = wx0 * wy0;
            let w10 = wx1 * wy0;
            let w01 = wx0 * wy1;
            let w11 = wx1 * wy1;

            let r = (u32::from(r00) * w00
                + u32::from(r10) * w10
                + u32::from(r01) * w01
                + u32::from(r11) * w11
                + 32768)
                >> 16;
            let g = (u32::from(g00) * w00
                + u32::from(g10) * w10
                + u32::from(g01) * w01
                + u32::from(g11) * w11
                + 32768)
                >> 16;
            let b = (u32::from(b00) * w00
                + u32::from(b10) * w10
                + u32::from(b01) * w01
                + u32::from(b11) * w11
                + 32768)
                >> 16;
            dst[drow + x] = Gray8::from_rgb(r as u8, g as u8, b as u8);
        }
    }
}

/// Scale a 32-bit Wayland shm capture straight into RGB565 using the active [`AppScaleMode`].
pub fn fit_from_xrgb(
    src: &[u8],
    stride: u32,
    bgr: bool,
    sw: u32,
    sh: u32,
    dst: &mut [Gray8],
    dw: u32,
    dh: u32,
) {
    scale_from_xrgb(src, stride, bgr, sw, sh, dst, dw, dh, current_mode());
}

/// Scale a 32-bit capture straight into RGB565 according to `mode`.
#[allow(clippy::too_many_arguments)]
pub fn scale_from_xrgb(
    src: &[u8],
    stride: u32,
    bgr: bool,
    sw: u32,
    sh: u32,
    dst: &mut [Gray8],
    dw: u32,
    dh: u32,
    mode: AppScaleMode,
) {
    if sw == 0 || sh == 0 || dw == 0 || dh == 0 || dst.len() < (dw * dh) as usize {
        return;
    }
    if src.len() < (stride * sh) as usize {
        return;
    }

    #[inline(always)]
    fn unpack(src: &[u8], p: usize, bgr: bool) -> (u32, u32, u32) {
        let (first, third) = (u32::from(src[p]), u32::from(src[p + 2]));
        if bgr {
            (third, u32::from(src[p + 1]), first)
        } else {
            (first, u32::from(src[p + 1]), third)
        }
    }

    if mode == AppScaleMode::Reflow {
        let pal = crate::theme_choice::current().palette();
        if try_reflow_xrgb(src, stride, bgr, sw, sh, dst, dw, dh, &pal) {
            return;
        }
    }

    let (w, h, ox, oy) = target_box(sw, sh, dw, dh, mode);

    if w == sw && h == sh {
        for y in 0..h {
            let srow = (y * stride) as usize;
            let drow = ((oy + y) * dw + ox) as usize;
            for x in 0..w as usize {
                let (r, g, b) = unpack(src, srow + x * 4, bgr);
                dst[drow + x] = Gray8::from_rgb(r as u8, g as u8, b as u8);
            }
        }
        return;
    }

    if sw > w || sh > h {
        for y in 0..h {
            let y0 = y * sh / h;
            let y1 = (((y + 1) * sh / h).max(y0 + 1)).min(sh);
            for x in 0..w {
                let x0 = x * sw / w;
                let x1 = (((x + 1) * sw / w).max(x0 + 1)).min(sw);
                let (mut sr, mut sg, mut sb, mut n) = (0u32, 0u32, 0u32, 0u32);
                for sy in y0..y1 {
                    let row = (sy * stride) as usize;
                    for sx in x0..x1 {
                        let (r, g, b) = unpack(src, row + (sx * 4) as usize, bgr);
                        sr += r;
                        sg += g;
                        sb += b;
                        n += 1;
                    }
                }
                let d = n.max(1);
                dst[((oy + y) * dw + ox + x) as usize] =
                    Gray8::from_rgb((sr / d) as u8, (sg / d) as u8, (sb / d) as u8);
            }
        }
        return;
    }

    const Q8: u32 = 1 << 8;
    let x_spans: Vec<(usize, usize, u32)> = (0..w)
        .map(|x| {
            let (ix0, ix1, wx0) = subpixel_span(x, sw, w);
            (ix0 * 4, ix1 * 4, wx0)
        })
        .collect();

    for y in 0..h {
        let (iy0, iy1, wy0) = subpixel_span(y, sh, h);
        let wy1 = Q8 - wy0;
        let r0 = iy0 * stride as usize;
        let r1 = iy1 * stride as usize;
        let drow = ((oy + y) * dw + ox) as usize;

        for (x, &(px0, px1, wx0)) in x_spans.iter().enumerate() {
            if wx0 == Q8 && wy0 == Q8 {
                let (r, g, b) = unpack(src, r0 + px0, bgr);
                dst[drow + x] = Gray8::from_rgb(r as u8, g as u8, b as u8);
                continue;
            }
            let wx1 = Q8 - wx0;
            let (r00, g00, b00) = unpack(src, r0 + px0, bgr);
            let (r10, g10, b10) = unpack(src, r0 + px1, bgr);
            let (r01, g01, b01) = unpack(src, r1 + px0, bgr);
            let (r11, g11, b11) = unpack(src, r1 + px1, bgr);

            let w00 = wx0 * wy0;
            let w10 = wx1 * wy0;
            let w01 = wx0 * wy1;
            let w11 = wx1 * wy1;

            let r = (r00 * w00 + r10 * w10 + r01 * w01 + r11 * w11 + 32768) >> 16;
            let g = (g00 * w00 + g10 * w10 + g01 * w01 + g11 * w11 + 32768) >> 16;
            let b = (b00 * w00 + b10 * w10 + b01 * w01 + b11 * w11 + 32768) >> 16;
            dst[drow + x] = Gray8::from_rgb(r as u8, g as u8, b as u8);
        }
    }
}

#[inline]
fn subpixel_span(d: u32, src_len: u32, dst_len: u32) -> (usize, usize, u32) {
    let a = u64::from(d) * u64::from(src_len);
    let b = u64::from(d + 1) * u64::from(src_len);
    let dl = u64::from(dst_len);
    let i0 = (a / dl) as usize;
    let boundary = ((i0 + 1) as u64) * dl;
    if b <= boundary || i0 + 1 >= src_len as usize {
        (i0, i0, 1 << 8)
    } else {
        let cov0 = boundary - a;
        let w0 = (((cov0 << 8) + u64::from(src_len) / 2) / u64::from(src_len)).min(1 << 8) as u32;
        (i0, i0 + 1, w0)
    }
}

// ============================================================================
// Smart UI Reflow & Theme Hijack Engine (`256x144` Flipper UI -> `320x170`)
// ============================================================================

const SRC_W: usize = 256; // not-a-panel-dimension: upstream Flipper bundle width
const SRC_H: usize = 144; // not-a-panel-dimension: upstream Flipper bundle height
const BAR_H: usize = 13;
const BTN_H: usize = 14;
const SRC_BODY_Y0: usize = BAR_H;
const SRC_BODY_Y1: usize = SRC_H - BTN_H; // 130

#[inline]
fn blend_rgb(c0: (u8, u8, u8), c1: (u8, u8, u8), t: u8) -> Gray8 {
    let t = u32::from(t);
    let inv = 255 - t;
    let r = (u32::from(c0.0) * inv + u32::from(c1.0) * t + 127) / 255;
    let g = (u32::from(c0.1) * inv + u32::from(c1.1) * t + 127) / 255;
    let b = (u32::from(c0.2) * inv + u32::from(c1.2) * t + 127) / 255;
    Gray8::from_rgb(r as u8, g as u8, b as u8)
}

#[allow(clippy::too_many_arguments)]
fn try_reflow_xrgb(
    src: &[u8],
    stride: u32,
    bgr: bool,
    sw: u32,
    sh: u32,
    dst: &mut [Gray8],
    dw: u32,
    dh: u32,
    pal: &Palette,
) -> bool {
    if sw as usize != SRC_W
        || sh as usize != SRC_H
        || dw != u32::from(crate::PANEL_W)
        || dh != u32::from(crate::PANEL_H)
    {
        return false;
    }

    let mut luma = [0u8; SRC_W * SRC_H];
    for y in 0..SRC_H {
        let row = y * stride as usize;
        for x in 0..SRC_W {
            let p = row + x * 4;
            let (r, g, b) = if bgr {
                (src[p + 2], src[p + 1], src[p])
            } else {
                (src[p], src[p + 1], src[p + 2])
            };
            // Colour games/video (`Doom`, `FPV`, `Video Player`) have chromatic pixels;
            // leave them untouched in `Fill` RGB mode instead of reflowing UI chrome.
            let max_c = r.max(g).max(b);
            let min_c = r.min(g).min(b);
            if max_c - min_c > 8 {
                return false;
            }
            luma[y * SRC_W + x] = g;
        }
    }
    reflow_monochrome_ui(&luma, dst, dw as usize, dh as usize, pal)
}

fn try_reflow_gray8(
    src: &[Gray8],
    sw: u32,
    sh: u32,
    dst: &mut [Gray8],
    dw: u32,
    dh: u32,
    pal: &Palette,
) -> bool {
    if sw as usize != SRC_W
        || sh as usize != SRC_H
        || dw != u32::from(crate::PANEL_W)
        || dh != u32::from(crate::PANEL_H)
    {
        return false;
    }
    let mut luma = [0u8; SRC_W * SRC_H];
    for (i, px) in src[..SRC_W * SRC_H].iter().enumerate() {
        let (r, g, b) = px.to_rgb8();
        if r.max(g).max(b) - r.min(g).min(b) > 12 {
            return false;
        }
        luma[i] = g;
    }
    reflow_monochrome_ui(&luma, dst, dw as usize, dh as usize, pal)
}

fn reflow_monochrome_ui(
    luma: &[u8; SRC_W * SRC_H],
    dst: &mut [Gray8],
    dw: usize,
    dh: usize,
    pal: &Palette,
) -> bool {
    // Verify Flipper UI chrome signature: the four 4px gaps between the five `48x14`
    // softkey slots (`48..52`, `100..104`, `152..156`, `204..208`) sit on uniform light
    // canvas ground (`>= 180`, covering both normal `#ffffff` and `Modal`'s 75% overlay).
    for gap_x in [48usize, 100, 152, 204] {
        for sy in SRC_BODY_Y1..SRC_H {
            for sx in gap_x..gap_x + 4 {
                if luma[sy * SRC_W + sx] < 180 {
                    return false;
                }
            }
        }
    }

    let extra_w = dw - SRC_W; // +64 px
    let dst_body_y1 = dh - BTN_H; // 156
    let dst_body_h = dst_body_y1 - SRC_BODY_Y0; // 143
    let src_body_h = SRC_BODY_Y1 - SRC_BODY_Y0; // 117
    let extra_h = dst_body_h - src_body_h; // +26 px

    let canvas = Gray8::from_rgb(pal.white.0, pal.white.1, pal.white.2);
    dst[..dw * dh].fill(canvas);

    // 1. Top StatusBar (`y = 0..13` -> `dy = 0..13`, 1:1 crisp icons & battery!).
    let inverted_bar = (0..BAR_H).all(|y| luma[y * SRC_W + 128] < 80);
    for y in 0..BAR_H {
        let srow = y * SRC_W;
        let drow = y * dw;
        let map_px = |g: u8| -> Gray8 {
            if inverted_bar {
                blend_rgb(pal.bar_bg, pal.bar_fg, g)
            } else {
                blend_rgb(pal.black, pal.white, g)
            }
        };
        for x in 0..128 {
            dst[drow + x] = map_px(luma[srow + x]);
        }
        let mid = map_px(luma[srow + 128]);
        for x in 128..128 + extra_w {
            dst[drow + x] = mid;
        }
        for x in 128..SRC_W {
            dst[drow + x + extra_w] = map_px(luma[srow + x]);
        }
    }

    // 2. Middle Content Body (`sy = 13..130` -> `dy = 13..156`, 1:1 glyphs & borders!).
    // First reflow every source row `sy in 13..130` horizontally from `256 -> 320`
    // in column-coherent horizontal bands so vertical borders, frames, scrollbars,
    // and gauges never tear.
    let mut body_rows = vec![[canvas; 320]; src_body_h];
    let mut is_sep_row = [false; SRC_BODY_Y1 - SRC_BODY_Y0];
    for (idx, sy) in (SRC_BODY_Y0..SRC_BODY_Y1).enumerate() {
        let ref_v = luma[sy * SRC_W + 128];
        // A separator row is uniform across the content area (`0..248`, ignoring the
        // optional 3px dotted scrollbar gutter at `251..254`).
        is_sep_row[idx] = ref_v >= 180 && (0..248).all(|x| luma[sy * SRC_W + x] == ref_v);
    }

    let mut b0 = 0usize;
    while b0 < src_body_h {
        if is_sep_row[b0] {
            reflow_band_horizontal(luma, SRC_BODY_Y0 + b0, SRC_BODY_Y0 + b0 + 1, &mut body_rows[b0..b0 + 1], pal);
            b0 += 1;
            continue;
        }
        let mut b1 = b0 + 1;
        while b1 < src_body_h && !is_sep_row[b1] {
            b1 += 1;
        }
        reflow_band_horizontal(luma, SRC_BODY_Y0 + b0, SRC_BODY_Y0 + b1, &mut body_rows[b0..b1], pal);
        b0 = b1;
    }

    // Distribute `+26` vertical pixels ONLY into vertically-identical light rows
    // (`row[i] == row[i + 1]` across all `320` columns and center luma >= 180), so
    // every glyph, border, chamfer, and dotted scrollbar stays 100% 1:1 vertically!
    let mut v_runs: Vec<(usize, usize)> = Vec::new(); // (row_index, run_len)
    let mut r = 0usize;
    while r + 1 < src_body_h {
        let light = luma[(SRC_BODY_Y0 + r) * SRC_W + 128] >= 180;
        if light && body_rows[r] == body_rows[r + 1] {
            let start = r;
            while r + 1 < src_body_h
                && luma[(SRC_BODY_Y0 + r) * SRC_W + 128] >= 180
                && body_rows[r] == body_rows[r + 1]
            {
                r += 1;
            }
            v_runs.push((start, r - start + 1));
        }
        r += 1;
    }

    let mut row_repeats = vec![1usize; src_body_h];
    if v_runs.is_empty() {
        // Dense full-height frame: pad evenly top (+13) and bottom (+13).
        let top_pad = extra_h / 2;
        for (i, row) in body_rows.iter().enumerate() {
            let dy = SRC_BODY_Y0 + top_pad + i;
            dst[dy * dw..dy * dw + dw].copy_from_slice(&row[..dw]);
        }
    } else {
        // Give inter-row whitespace gaps up to +3px extra breathing room first, then
        // pour the remaining vertical space into the largest stretchable span (either
        // the bottom canvas area on `DetailBody`, or the interior of `CanvasBody`'s
        // outer `round_frame` so bordered canvases expand cleanly to the bottom!).
        let mut rem = extra_h;
        let largest_idx = v_runs
            .iter()
            .enumerate()
            .max_by_key(|(_, (_, len))| *len)
            .map(|(idx, _)| idx)
            .unwrap_or(0);

        for (idx, &(start, _len)) in v_runs.iter().enumerate() {
            if idx == largest_idx {
                continue;
            }
            let add = rem.min(3);
            row_repeats[start] += add;
            rem -= add;
        }
        row_repeats[v_runs[largest_idx].0] += rem;

        let mut dy = SRC_BODY_Y0;
        for (i, row) in body_rows.iter().enumerate() {
            for _ in 0..row_repeats[i] {
                if dy < dst_body_y1 {
                    dst[dy * dw..dy * dw + dw].copy_from_slice(&row[..dw]);
                    dy += 1;
                }
            }
        }
    }

    // 3. Bottom 5-Slot SoftBar (`sy = 130..144` -> `dy = 156..170`):
    // Lift each `48x14` slot (`sx = 0, 52, 104, 156, 208`) and rebuild it as a crisp
    // `52x14` chamfered CardputerZero tab at `dx = 22, 78, 134, 190, 246` (centres
    // `48, 104, 160, 216, 272` right over physical keys `4, 5, 6, 7, 8`!).
    for slot in 0..5usize {
        let sx0 = slot * 52;
        let dx0 = crate::layout::soft_slot_x(slot) as usize; // 22, 78, 134, 190, 246
        let top_dark = (sx0 + 6..sx0 + 42)
            .filter(|&sx| luma[SRC_BODY_Y1 * SRC_W + sx] < 200)
            .count();
        if top_dark < 20 {
            continue; // Empty softkey slot: leave clean canvas!
        }

        // Row `sy = 132` (`rel_y = 2`) sits inside the button above the 7px label caps:
        // dark (< 128) means momentarily pressed/inverted; light means unpressed.
        let interior_sum: u32 = (sx0 + 6..sx0 + 42)
            .map(|sx| u32::from(luma[(SRC_BODY_Y1 + 2) * SRC_W + sx]))
            .sum();
        let pressed = interior_sum / 36 < 128;
        let border_avg: u32 = (sx0 + 6..sx0 + 42)
            .map(|sx| u32::from(luma[SRC_BODY_Y1 * SRC_W + sx]))
            .sum::<u32>()
            / 36;
        let disabled = !pressed && border_avg > 80;

        let (bg_rgb, edge_rgb, ink_rgb) = if pressed {
            (pal.press_bg, pal.press_bg, pal.press_fg)
        } else if disabled {
            (pal.disabled_bg, pal.divider, pal.disabled_fg)
        } else {
            (pal.soft_bg, pal.soft_edge, pal.black)
        };
        let bg_px = Gray8::from_rgb(bg_rgb.0, bg_rgb.1, bg_rgb.2);
        let edge_px = Gray8::from_rgb(edge_rgb.0, edge_rgb.1, edge_rgb.2);

        // Paint symmetric `52x14` 45-degree 3px chamfered tab (`SoftButton` geometry).
        const TAB_W: usize = 52;
        for ry in 0..BTN_H {
            let drow = (dst_body_y1 + ry) * dw + dx0;
            match ry {
                0 => {
                    for x in 3..TAB_W - 3 {
                        dst[drow + x] = edge_px;
                    }
                }
                1 => {
                    dst[drow + 2] = edge_px;
                    for x in 3..TAB_W - 3 {
                        dst[drow + x] = bg_px;
                    }
                    dst[drow + TAB_W - 3] = edge_px;
                }
                2 => {
                    dst[drow + 1] = edge_px;
                    for x in 2..TAB_W - 2 {
                        dst[drow + x] = bg_px;
                    }
                    dst[drow + TAB_W - 2] = edge_px;
                }
                _ => {
                    dst[drow] = edge_px;
                    for x in 1..TAB_W - 1 {
                        dst[drow + x] = bg_px;
                    }
                    dst[drow + TAB_W - 1] = edge_px;
                }
            }
        }

        // Blit the original `1:1` unscaled label/icon (`rel_x = 3..45`, `rel_y = 2..13`)
        // centred at `+2px` inside the `52x14` tab (`48 + 4 = 52`).
        for ry in 2..BTN_H - 1 {
            let srow = (SRC_BODY_Y1 + ry) * SRC_W + sx0;
            let drow = (dst_body_y1 + ry) * dw + dx0;
            for rx in 3..45usize {
                let g = luma[srow + rx];
                let cov = if pressed { g } else { 255 - g };
                if cov > 12 {
                    dst[drow + rx + 2] = blend_rgb(bg_rgb, ink_rgb, cov);
                }
            }
        }
    }

    true
}

/// Expand a horizontal band `[y0..y1)` of `luma` (`256` cols) into `out_rows` (`320` cols)
/// by adding `+64` columns strictly inside column-identical runs (`col[x] == col[x+1]`),
/// preserving 100% `1:1` bitmap glyphs, `45°` corners, vertical borders, and gauges.
fn reflow_band_horizontal(
    luma: &[u8; SRC_W * SRC_H],
    y0: usize,
    y1: usize,
    out_rows: &mut [[Gray8; 320]],
    pal: &Palette,
) {
    const EXTRA: usize = 64;

    // Find maximal runs `(start, len)` where every column in `start..start+len` has
    // the exact same vertical slice across `y0..y1`.
    let mut runs: Vec<(usize, usize, bool)> = Vec::new(); // (start, len, has_ink)
    let mut x = 0usize;
    while x < SRC_W {
        let start = x;
        while x + 1 < SRC_W && (y0..y1).all(|y| luma[y * SRC_W + x] == luma[y * SRC_W + x + 1]) {
            x += 1;
        }
        let len = x - start + 1;
        if len >= 2 {
            let has_ink = (y0..y1).any(|y| luma[y * SRC_W + start] < 180);
            runs.push((start, len, has_ink));
        }
        x += 1;
    }

    let mut col_repeats = [1usize; SRC_W];

    // Case 1: Dual-segment gauge (`[████░░░░]` — two adjacent ink-bearing runs `>= 6px`
    // separated by `<= 2px`, total width `>= 40px`). Stretch both proportionally so
    // fill percentage stays accurate!
    let mut applied = false;
    for w in runs.windows(2) {
        let (s0, l0, ink0) = w[0];
        let (s1, l1, ink1) = w[1];
        if ink0 && ink1 && l0 >= 6 && l1 >= 6 && l0 + l1 >= 40 && s1 <= s0 + l0 + 2 {
            let add0 = (EXTRA * l0 + (l0 + l1) / 2) / (l0 + l1);
            let add1 = EXTRA - add0;
            col_repeats[s0 + l0 / 2] += add0;
            col_repeats[s1 + l1 / 2] += add1;
            applied = true;
            break;
        }
    }

    // Case 2: Symmetric / centred widget (`Modal`, `TextInputBody`, or centred `CanvasBody`
    // elements inside or outside a `round_frame`).
    if !applied {
        let left_margin = runs.iter().copied().find(|&(s, l, _)| s <= 4 && l >= 8);
        let right_margin = runs
            .iter()
            .copied()
            .rev()
            .find(|&(s, l, _)| s + l >= SRC_W - 4 && l >= 8);
        let max_interior = runs
            .iter()
            .filter(|&&(s, _, _)| s > 4 && s < SRC_W - 20)
            .map(|&(_, l, _)| l)
            .max()
            .unwrap_or(0);

        if let (Some((ls, ll, _)), Some((rs, rl, _))) = (left_margin, right_margin) {
            if ls < rs && (max_interior < 24 || (ll >= 20 && rl >= 20 && ll.abs_diff(rl) <= 24)) {
                col_repeats[ls + ll / 2] += EXTRA / 2;
                col_repeats[rs + rl / 2] += EXTRA - EXTRA / 2;
                applied = true;
            }
        }
    }

    // Case 3: Standard UI row (`MenuLine`, `SelectorFrame`, `DetailRow`, `rule()` divider,
    // or left-aligned title). Expand the widest uniform run inside `2..254`.
    if !applied {
        if let Some(&(s, l, _)) = runs
            .iter()
            .filter(|&&(s, l, _)| l >= 14 && s + l > 6 && s < SRC_W - 2)
            .max_by_key(|&&(_, l, _)| l)
        {
            let anchor = (s + l / 2).clamp(2, SRC_W - 3);
            col_repeats[anchor] += EXTRA;
            applied = true;
        }
    }

    // Case 4: Fallback — centre `256px` at `1:1` with `+32px` margins on each side.
    if !applied {
        col_repeats[0] += EXTRA / 2;
        col_repeats[SRC_W - 1] += EXTRA - EXTRA / 2;
    }

    for (ry, sy) in (y0..y1).enumerate() {
        let srow = sy * SRC_W;
        let out = &mut out_rows[ry];
        let mut dx = 0usize;
        for sx in 0..SRC_W {
            let px = blend_rgb(pal.black, pal.white, luma[srow + sx]);
            for _ in 0..col_repeats[sx] {
                if dx < 320 {
                    out[dx] = px;
                    dx += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{fit, scale_from_xrgb, scale_gray8, AppScaleMode};
    use crate::pixel::Gray8;

    #[test]
    fn a_frame_of_one_value_keeps_it() {
        let (pw, ph) = (u32::from(crate::PANEL_W), u32::from(crate::PANEL_H));
        let col = Gray8::from_rgb(44, 132, 245);
        let src = vec![col; 320 * 200];
        let mut dst = vec![Gray8(0); (pw * ph) as usize];
        fit(&src, 320, 200, &mut dst, pw, ph);
        let middle = (ph / 2 * pw + pw / 2) as usize;
        assert_eq!(dst[middle], col, "the middle is the image");
        assert_eq!(dst[(ph / 2 * pw) as usize].0, 0, "the left margin is untouched");
    }

    #[test]
    fn reflow_repositions_soft_buttons_over_cardputer_keys_4_to_8() {
        let (pw, ph) = (u32::from(crate::PANEL_W), u32::from(crate::PANEL_H));
        let (uw, uh) = (256usize, 144usize); // not-a-panel-dimension
        let white = Gray8::from_rgb(255, 255, 255);
        let black = Gray8::from_rgb(0, 0, 0);
        let mut src = vec![white; uw * uh];

        // Top 13px inverted status bar.
        for y in 0..13 {
            for x in 0..uw {
                src[y * uw + x] = black;
            }
        }
        // Slot 0 (`0..48`) and Slot 4 (`208..256`) unpressed soft buttons at `y = 130..144`.
        for sx0 in [0usize, 208] {
            for x in sx0 + 3..sx0 + 45 {
                src[130 * uw + x] = black;
            }
        }

        let mut dst = vec![Gray8(0); (pw * ph) as usize];
        scale_gray8(&src, uw as u32, uh as u32, &mut dst, pw, ph, AppScaleMode::Reflow);

        let pal = crate::theme_choice::current().palette();
        let want_edge = Gray8::from_rgb(pal.soft_edge.0, pal.soft_edge.1, pal.soft_edge.2);
        let want_canvas = Gray8::from_rgb(pal.white.0, pal.white.1, pal.white.2);

        // Slot 0 now sits centred at X = 48 (`dx = 22..74`), Slot 4 at X = 272 (`dx = 246..298`),
        // while Slot 2 (`X = 160`) stays empty canvas!
        assert_eq!(dst[(156 * pw + 48) as usize], want_edge, "Slot 0 top edge over Key 4");
        assert_eq!(dst[(156 * pw + 160) as usize], want_canvas, "Empty Slot 2 stays clear");
        assert_eq!(dst[(156 * pw + 272) as usize], want_edge, "Slot 4 top edge over Key 8");
    }

    #[test]
    fn fill_mode_expands_upstream_bundle_across_entire_320x170_panel() {
        let (pw, ph) = (u32::from(crate::PANEL_W), u32::from(crate::PANEL_H));
        let col = Gray8::from_rgb(255, 255, 255);
        let (uw, uh) = (256u32, 144u32); // not-a-panel-dimension
        let src = vec![col; (uw * uh) as usize];
        let mut dst = vec![Gray8(0); (pw * ph) as usize];
        scale_gray8(&src, uw, uh, &mut dst, pw, ph, AppScaleMode::Fill);
        assert_eq!(dst[0], col, "top-left corner filled");
        assert_eq!(dst[(pw * ph - 1) as usize], col, "bottom-right corner filled");
    }

    #[test]
    fn pixel_1x_mode_centres_upstream_bundle_inside_320x170() {
        let (pw, ph) = (u32::from(crate::PANEL_W), u32::from(crate::PANEL_H));
        let col = Gray8::from_rgb(255, 255, 255);
        let (uw, uh) = (256u32, 144u32); // not-a-panel-dimension
        let src = vec![col; (uw * uh) as usize];
        let mut dst = vec![Gray8(0); (pw * ph) as usize];
        scale_gray8(&src, uw, uh, &mut dst, pw, ph, AppScaleMode::Pixel1x);
        assert_eq!(dst[0], Gray8(0), "top-left margin stays clear");
        assert_eq!(dst[(13 * pw + 32) as usize], col, "centred image starts at (32, 13)");
        assert_eq!(dst[(156 * pw + 287) as usize], col, "centred image ends at (287, 156)");
        assert_eq!(dst[(157 * pw + 288) as usize], Gray8(0), "bottom-right margin stays clear");
    }

    #[test]
    fn averaging_halves_a_checkerboard() {
        let a = Gray8(0);
        let b = Gray8::from_rgb(255, 255, 255);
        let src = vec![a, b, a, b, b, a, b, a, a, b, a, b, b, a, b, a];
        let mut dst = vec![Gray8(9); 4];
        fit(&src, 4, 4, &mut dst, 2, 2);
        let want = Gray8::from_rgb(127, 127, 127);
        assert!(dst.iter().all(|p| *p == want));
    }

    #[test]
    fn a_capture_packs_rgb565() {
        let (r, g, b) = (200u8, 100u8, 50u8);
        let src: Vec<u8> = std::iter::repeat([b, g, r, 0]).take(4).flatten().collect();
        let mut dst = vec![Gray8(0); 4];
        scale_from_xrgb(&src, 8, true, 2, 2, &mut dst, 2, 2, AppScaleMode::Fill);
        let want = Gray8::from_rgb(r, g, b);
        assert!(dst.iter().all(|p| *p == want));
    }
}
