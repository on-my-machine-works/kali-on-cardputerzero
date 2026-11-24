//! Slint software renderer targeting the greyscale panel.
//!
//! Slint is taken with `renderer-software` alone and no backend, so we own the
//! window adapter, the frame buffer and the event loop. `Gray8` implements
//! Slint's public `TargetPixel` trait, so the renderer composites straight into
//! the surface the panel and every other sink already consume: no intermediate
//! RGB buffer, no format conversion in userspace.

use std::cell::RefCell;
use std::rc::Rc;

use slint::platform::software_renderer::{
    MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType, TargetPixel,
};
use slint::platform::{Platform, PlatformError, WindowAdapter};
use slint::PhysicalSize;

use crate::pixel::{Gray8, Rect};
use crate::theme::{PANEL_H, PANEL_W};

impl TargetPixel for Gray8 {
    /// Blend a premultiplied RGBA colour over this RGB565 sample.
    #[inline]
    fn blend(&mut self, colour: PremultipliedRgbaColor) {
        if colour.alpha == 0 {
            return;
        }
        if colour.alpha == u8::MAX {
            *self = Gray8::from_rgb(colour.red, colour.green, colour.blue);
            return;
        }
        let keep = (u8::MAX - colour.alpha) as u16;
        let (ur, ug, ub) = self.to_rgb8();
        let r = (((ur as u16 * keep + 127) / 255) + colour.red as u16).min(255) as u8;
        let g = (((ug as u16 * keep + 127) / 255) + colour.green as u16).min(255) as u8;
        let b = (((ub as u16 * keep + 127) / 255) + colour.blue as u16).min(255) as u8;
        *self = Gray8::from_rgb(r, g, b);
    }

    #[inline]
    fn from_rgb(r: u8, g: u8, b: u8) -> Self {
        Gray8::from_rgb(r, g, b)
    }

    #[inline]
    fn background() -> Self {
        Gray8::WHITE
    }
}

/// Minimal platform: one fixed-size window, a monotonic clock, no event loop.
///
/// flipctl drives the loop itself, because it also owns DRM and input and must
/// keep running when no component wants to redraw.
pub struct FlipperSlintPlatform {
    window: Rc<MinimalSoftwareWindow>,
    start: std::time::Instant,
}

impl FlipperSlintPlatform {
    /// Install the platform. Must be called once, before any component is
    /// created.
    ///
    /// `ReusedBuffer` would let Slint track partial damage across frames, but
    /// the panel driver re-transmits the whole framebuffer on every atomic
    /// commit regardless, so there is nothing to save yet.
    pub fn install() -> Rc<MinimalSoftwareWindow> {
        Self::install_with(RepaintBufferType::NewBuffer)
    }

    /// Install with `ReusedBuffer` so Slint tracks exact partial damage across
    /// frames into a persistent `Vec<Gray8>`, making `DIRTYFB` SPI transfers on
    /// CardputerZero 5x-40x smaller and faster on incremental UI updates.
    pub fn install_reused() -> Rc<MinimalSoftwareWindow> {
        Self::install_with(RepaintBufferType::ReusedBuffer)
    }

    fn install_with(buffer_type: RepaintBufferType) -> Rc<MinimalSoftwareWindow> {
        let window = MinimalSoftwareWindow::new(buffer_type);
        window.set_size(PhysicalSize::new(u32::from(PANEL_W), u32::from(PANEL_H)));

        let platform = Self { window: window.clone(), start: std::time::Instant::now() };
        slint::platform::set_platform(Box::new(platform)).expect("set_platform called twice");
        window
    }
}

impl Platform for FlipperSlintPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        Ok(self.window.clone())
    }

    fn duration_since_start(&self) -> core::time::Duration {
        self.start.elapsed()
    }
}

/// Render whatever the window currently holds into `into`, returning the damaged
/// region.
///
/// `None` means nothing needed repainting, so the caller can skip the commit
/// entirely rather than re-transmitting an identical frame over SPI. `into` is
/// reused across frames so the steady state allocates nothing.
pub fn render_into(window: &MinimalSoftwareWindow, into: &mut Vec<Gray8>) -> Option<Rect> {
    let len = usize::from(PANEL_W) * usize::from(PANEL_H);
    into.resize(len, Gray8::WHITE);

    let region = Rc::new(RefCell::new(None));
    let taken = {
        let region = region.clone();
        window.draw_if_needed(|renderer| {
            let damaged = renderer.render(into.as_mut_slice(), usize::from(PANEL_W));
            let origin = damaged.bounding_box_origin();
            let size = damaged.bounding_box_size();
            if size.width > 0 && size.height > 0 {
                let x = (origin.x.max(0) as u16).min(PANEL_W);
                let y = (origin.y.max(0) as u16).min(PANEL_H);
                let w = (size.width as u16).min(PANEL_W.saturating_sub(x));
                let h = (size.height as u16).min(PANEL_H.saturating_sub(y));
                if w > 0 && h > 0 {
                    *region.borrow_mut() = Some(Rect::new(x, y, w, h));
                }
            }
        })
    };

    if !taken {
        return None;
    }
    let damage = *region.borrow();
    damage
}

/// Convenience wrapper for callers that want an owned frame and do not care about
/// reusing the buffer, such as tests and the screenshot example.
pub fn render_frame(window: &MinimalSoftwareWindow) -> Option<Vec<Gray8>> {
    let mut frame = Vec::new();
    render_into(window, &mut frame).map(|_| frame)
}
