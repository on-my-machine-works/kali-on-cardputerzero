//! The canonical pixel format for the M5Stack CardputerZero 320x170 ST7789v3 panel.
//!
//! CardputerZero's `panel-mipi-dbi` DRM driver natively accepts 16-bit `DRM_FORMAT_RGB565`
//! (`320 * 170 * 2 = 108,800` bytes per frame), matching `/dev/fb_lcd` and `cz_ui.h`.
//! Keeping the type name `Gray8` preserves compatibility across all upstream `flipctl`
//! modules while upgrading every screen, icon, hosted app, and remote stream to true
//! 16-bit RGB565 Kali Dark color with zero per-pixel format conversion on KMS commit.

/// One 16-bit RGB565 pixel (`rrrrrggggggbbbbb`).
#[repr(transparent)]
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Debug, Default, Hash)]
pub struct Gray8(pub u16);

/// Read little-endian RGB565 bytes as pixels without copying.
pub fn from_bytes(bytes: &[u8]) -> &[Gray8] {
    assert!(
        (bytes.as_ptr() as usize).is_multiple_of(std::mem::align_of::<Gray8>()),
        "RGB565 byte slice must be 2-byte aligned"
    );
    unsafe { std::slice::from_raw_parts(bytes.as_ptr().cast(), bytes.len() / 2) }
}

/// View RGB565 pixels as raw little-endian bytes without copying.
pub fn as_bytes(pixels: &[Gray8]) -> &[u8] {
    unsafe { std::slice::from_raw_parts(pixels.as_ptr().cast(), pixels.len() * 2) }
}

/// Mutable view of aligned little-endian bytes as RGB565 pixels.
pub fn from_bytes_mut(bytes: &mut [u8]) -> &mut [Gray8] {
    assert!(
        (bytes.as_ptr() as usize).is_multiple_of(std::mem::align_of::<Gray8>()),
        "RGB565 mutable byte slice must be 2-byte aligned"
    );
    unsafe { std::slice::from_raw_parts_mut(bytes.as_mut_ptr().cast(), bytes.len() / 2) }
}

impl Gray8 {
    /// Primary ink (`#ebf3ff` in Kali Dark palette).
    pub const BLACK: Self = Self::from_rgb(235, 243, 255);
    /// Canvas ground (`#080c16` in Kali Dark palette).
    pub const WHITE: Self = Self::from_rgb(8, 12, 22);

    /// Pack 8-bit RGB into 16-bit RGB565 (`cz_ui.h` `rgb565(r, g, b)`).
    #[inline]
    pub const fn from_rgb(r: u8, g: u8, b: u8) -> Self {
        Self((((r as u16 >> 3) << 11) | ((g as u16 >> 2) << 5) | (b as u16 >> 3)) as u16)
    }

    /// Expand 16-bit RGB565 back to 8-bit `(r, g, b)`.
    #[inline]
    pub const fn to_rgb8(self) -> (u8, u8, u8) {
        let r5 = ((self.0 >> 11) & 0x1f) as u32;
        let g6 = ((self.0 >> 5) & 0x3f) as u32;
        let b5 = (self.0 & 0x1f) as u32;
        (
            ((r5 * 255 + 15) / 31) as u8,
            ((g6 * 255 + 31) / 63) as u8,
            ((b5 * 255 + 15) / 31) as u8,
        )
    }

    /// Expand to little-endian `XRGB8888` (`0x00RRGGBB`) for fallback KMS / Wayland sinks.
    #[inline]
    pub const fn to_xrgb8888(self) -> u32 {
        let (r, g, b) = self.to_rgb8();
        ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
    }

    /// Blend `over` on top of `self` with `alpha` in `0..=255`.
    #[inline]
    pub fn blend(self, over: Gray8, alpha: u8) -> Gray8 {
        if alpha == 0 {
            return self;
        }
        if alpha == u8::MAX {
            return over;
        }
        let (sr, sg, sb) = self.to_rgb8();
        let (or, og, ob) = over.to_rgb8();
        let a = alpha as u16;
        let inv = 255 - a;
        Self::from_rgb(
            (((or as u16 * a) + (sr as u16 * inv) + 127) / 255) as u8,
            (((og as u16 * a) + (sg as u16 * inv) + 127) / 255) as u8,
            (((ob as u16 * a) + (sb as u16 * inv) + 127) / 255) as u8,
        )
    }
}

/// A rectangle in panel coordinates. Half-open: `x .. x + w`.
#[derive(Copy, Clone, PartialEq, Eq, Debug, Default)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

impl Rect {
    pub const fn new(x: u16, y: u16, w: u16, h: u16) -> Self {
        Self { x, y, w, h }
    }

    pub const fn is_empty(&self) -> bool {
        self.w == 0 || self.h == 0
    }

    /// Smallest rectangle covering both. An empty operand is ignored, so
    /// folding over damage rects starting from `Rect::default()` works.
    pub fn union(self, other: Rect) -> Rect {
        if self.is_empty() {
            return other;
        }
        if other.is_empty() {
            return self;
        }
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        let r = (self.x + self.w).max(other.x + other.w);
        let b = (self.y + self.h).max(other.y + other.h);
        Rect::new(x, y, r - x, b - y)
    }
}

#[cfg(test)]
mod byte_view {
    use super::{as_bytes, from_bytes, from_bytes_mut, Gray8};

    #[test]
    fn bytes_are_samples_in_place() {
        #[repr(align(2))]
        struct Aligned([u8; 6]);
        let buf = Aligned([0x00, 0x00, 0x34, 0x12, 0xff, 0xff]);
        assert_eq!(from_bytes(&buf.0), &[Gray8(0x0000), Gray8(0x1234), Gray8(0xffff)]);
        let mut more = Aligned([1, 0, 2, 0, 3, 0]);
        from_bytes_mut(&mut more.0)[1] = Gray8(0x0908);
        assert_eq!(as_bytes(from_bytes(&more.0)), &[1, 0, 0x08, 0x09, 3, 0]);
    }
}
