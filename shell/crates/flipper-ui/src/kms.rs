//! The panel sink: DRM/KMS straight to the CardputerZero 320x170 ST7789v3 SPI LCD
//! (with automatic fallback for Flipper One / generic XRGB8888 KMS displays).
//!
//! CardputerZero's `panel-mipi-dbi` driver (`/dev/dri/cardputer-zero-internal`)
//! natively advertises `DRM_FORMAT_RGB565` (16bpp) and `DRM_FORMAT_XRGB8888`, plus
//! `DIRTYFB` partial rectangle SPI transfers via `drm_atomic_helper_dirtyfb`.
//!
//! Crucial DRM/fbdev handoff detail on Linux (`drivers/gpu/drm/drm_file.c`):
//!   - `DRM_IOCTL_DROP_MASTER` requires `CAP_SYS_ADMIN` (`DRM_ROOT_ONLY`) AND does
//!     NOT call `drm_client_dev_restore()`! The kernel only restores `drm_fb_helper`
//!     (`/dev/fb_lcd`) onto the SPI CRTC inside `drm_lastclose()` when ALL open DRM
//!     file descriptors are closed (or via `FBIOPUT_VSCREENINFO` `FB_ACTIVATE_FORCE`).
//!   - Therefore `detach()` destroys our dumb framebuffer, closes the DRM fd
//!     completely, and triggers `FBIOPUT_VSCREENINFO` (`FB_ACTIVATE_FORCE`) on
//!     `/dev/fb_lcd` so Kali `cz-*` and M5 LVGL apps own the panel immediately.
//!   - `attach()` re-opens the DRM node (which automatically grants DRM master via
//!     `drm_open_helper` without needing root!) and commits `flipctl`'s full frame.

use std::fs::{File, OpenOptions};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use drm::buffer::{Buffer, DrmFourcc};
use drm::control::dumbbuffer::DumbBuffer;
use drm::control::{connector, crtc, framebuffer, Device as ControlDevice, Mode};
use drm::Device as DrmDevice;

use crate::pixel::Rect;
use crate::platform::{Frame, FrameSink};

/// Supported SPI / handheld panel DRM driver names (including CardputerZero's
/// `panel-mipi-dbi-spi` / `panel_mipi_dbi_m` inside early `initramfs8`).
const DRIVERS: &[&str] = &[
    "panel-mipi-dbi",
    "panel-mipi-dbi-spi",
    "panel_mipi_dbi_m",
    "mipi-dbi-spi",
    "st7789v",
    "mipi-dbi",
    "flipper_one_display",
];

/// CardputerZero udev symlink created by `99-cardputer-zero-lcd.rules`.
const CZ_DRM_SYMLINK: &str = "/dev/dri/cardputer-zero-internal";

/// How long start-up / attach waits to acquire DRM master before giving up.
const MASTER_WAIT: Duration = Duration::from_secs(15);
const ATTACH_WAIT: Duration = Duration::from_secs(3);

struct Card(File);

impl AsFd for Card {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}
impl DrmDevice for Card {}
impl ControlDevice for Card {}

struct KmsActive {
    card: Card,
    crtc: crtc::Handle,
    connector: connector::Handle,
    mode: Mode,
    buffer: DumbBuffer,
    rgb565: bool,
    fb: framebuffer::Handle,
    modeset_done: bool,
    flush: Flush,
}

pub struct KmsSink {
    path: PathBuf,
    size: (u16, u16),
    rgb565: bool,
    last_flush: Flush,
    active: Option<KmsActive>,
}

#[derive(Copy, Clone, PartialEq, Eq)]
enum Flush {
    Probe,
    DirtyFb,
    SetCrtc,
}

impl KmsSink {
    pub fn open(explicit: Option<&Path>) -> std::io::Result<Self> {
        let path = match explicit {
            Some(p) => p.to_path_buf(),
            None => Self::find_panel()?,
        };
        let active = Self::open_active(&path, explicit.is_some(), MASTER_WAIT)?;
        let size = active.mode.size();
        let rgb565 = active.rgb565;
        Ok(Self {
            path,
            size,
            rgb565,
            last_flush: active.flush,
            active: Some(active),
        })
    }

    fn open_active(path: &Path, explicit: bool, wait: Duration) -> std::io::Result<KmsActive> {
        let card = Self::open_as_master(path, wait)?;

        let name = card.get_driver()?.name;
        if !explicit && !DRIVERS.iter().any(|d| *d == name) {
            return Err(std::io::Error::other(format!(
                "{} is driven by {name:?}, expected one of {DRIVERS:?}",
                path.display()
            )));
        }

        let resources = card.resource_handles()?;

        let (connector, mode) = resources
            .connectors()
            .iter()
            .filter_map(|handle| card.get_connector(*handle, false).ok())
            .find(|info| info.state() == connector::State::Connected)
            .and_then(|info| info.modes().first().copied().map(|m| (info.handle(), m)))
            .ok_or_else(|| std::io::Error::other("no connected connector with a mode"))?;

        let crtc = *resources.crtcs().first().ok_or_else(|| std::io::Error::other("no CRTC"))?;

        let (w, h) = mode.size();

        let want_rgb565 =
            !std::env::var("FLIPPER_FB_FORMAT").is_ok_and(|v| v.eq_ignore_ascii_case("xrgb"));

        let (mut buffer, fb, rgb565) = if want_rgb565 {
            match card
                .create_dumb_buffer((u32::from(w), u32::from(h)), DrmFourcc::Rgb565, 16)
                .and_then(|b| card.add_framebuffer(&b, 16, 16).map(|fb| (b, fb)))
            {
                Ok((b, fb)) => (b, fb, true),
                Err(_) => {
                    let b = card.create_dumb_buffer(
                        (u32::from(w), u32::from(h)),
                        DrmFourcc::Xrgb8888,
                        32,
                    )?;
                    let fb = card.add_framebuffer(&b, 24, 32)?;
                    (b, fb, false)
                }
            }
        } else {
            let b =
                card.create_dumb_buffer((u32::from(w), u32::from(h)), DrmFourcc::Xrgb8888, 32)?;
            let fb = card.add_framebuffer(&b, 24, 32)?;
            (b, fb, false)
        };

        // Zero-initialize dumb buffer so no white flash appears before first commit.
        {
            let mut map = card.map_dumb_buffer(&mut buffer)?;
            map.as_mut().fill(0x00);
        }

        Ok(KmsActive {
            card,
            crtc,
            connector,
            mode,
            buffer,
            fb,
            rgb565,
            modeset_done: false,
            flush: Flush::Probe,
        })
    }

    fn find_panel() -> std::io::Result<PathBuf> {
        let cz_link = Path::new(CZ_DRM_SYMLINK);
        if cz_link.exists() {
            return Ok(cz_link.to_path_buf());
        }

        let mut candidates: Vec<PathBuf> = std::fs::read_dir("/dev/dri")?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| {
                p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("card"))
            })
            .collect();
        candidates.sort();

        for path in &candidates {
            let Ok(file) = OpenOptions::new().read(true).write(true).open(path) else {
                continue;
            };
            if Card(file).get_driver().is_ok_and(|d| DRIVERS.iter().any(|want| *want == d.name)) {
                return Ok(path.clone());
            }
        }

        Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!(
                "no /dev/dri/card* is driven by {DRIVERS:?} (tried {})",
                candidates.len()
            ),
        ))
    }

    pub fn size(&self) -> (u16, u16) {
        self.size
    }

    pub fn format(&self) -> &'static str {
        if self.rgb565 {
            "RGB565"
        } else {
            "XRGB8888"
        }
    }
}

impl FrameSink for KmsSink {
    fn commit(&mut self, frame: Frame<'_>, damage: Rect) -> std::io::Result<()> {
        let Some(active) = self.active.as_mut() else {
            return Ok(());
        };
        if damage.is_empty() && active.modeset_done {
            return Ok(());
        }

        let (w, h) = active.mode.size();
        if (frame.w, frame.h) != (w, h) {
            return Err(std::io::Error::other(format!(
                "frame is {}x{}, panel is {w}x{h}",
                frame.w, frame.h
            )));
        }

        let damage = Rect::new(
            damage.x.min(w),
            damage.y.min(h),
            damage.w.min(w.saturating_sub(damage.x.min(w))),
            damage.h.min(h.saturating_sub(damage.y.min(h))),
        );
        if damage.is_empty() && active.modeset_done {
            return Ok(());
        }

        let pitch = active.buffer.pitch() as usize;
        {
            let mut map = active.card.map_dumb_buffer(&mut active.buffer)?;
            let dst = map.as_mut();

            for (row, pixels) in (damage.y..damage.y + damage.h).zip(frame.rows(damage)) {
                if active.rgb565 {
                    let start = usize::from(row) * pitch + usize::from(damage.x) * 2;
                    let bytes = crate::pixel::as_bytes(pixels);
                    dst[start..start + bytes.len()].copy_from_slice(bytes);
                } else {
                    let start = usize::from(row) * pitch + usize::from(damage.x) * 4;
                    let words = &mut dst[start..start + pixels.len() * 4];
                    for (word, px) in words.chunks_exact_mut(4).zip(pixels) {
                        word.copy_from_slice(&px.to_xrgb8888().to_le_bytes());
                    }
                }
            }
        }

        if !active.modeset_done {
            Self::set_crtc_on(active)?;
            active.modeset_done = true;
            return Ok(());
        }

        if active.flush != Flush::SetCrtc {
            let clip = drm::control::ClipRect::new(
                damage.x,
                damage.y,
                damage.x + damage.w,
                damage.y + damage.h,
            );
            match active.card.dirty_framebuffer(active.fb, &[clip]) {
                Ok(()) => {
                    active.flush = Flush::DirtyFb;
                    self.last_flush = Flush::DirtyFb;
                    return Ok(());
                }
                Err(e) if active.flush == Flush::Probe && is_unsupported(&e) => {
                    active.flush = Flush::SetCrtc;
                    self.last_flush = Flush::SetCrtc;
                }
                Err(e) => return Err(e),
            }
        }

        Self::set_crtc_on(active)
    }
}

impl KmsSink {
    /// Completely close our DRM fd + dumb buffer and force-restore `/dev/fb_lcd`
    /// onto the ST7789v3 CRTC so Kali `cz-*` and M5 LVGL apps render immediately.
    pub fn detach(&mut self) -> std::io::Result<()> {
        if let Some(active) = self.active.take() {
            self.last_flush = active.flush;
            let _ = active.card.destroy_framebuffer(active.fb);
            let _ = active.card.destroy_dumb_buffer(active.buffer);
            let _ = active.card.release_master_lock();
            drop(active.card);
        }
        force_restore_fbdev();
        Ok(())
    }

    pub fn is_detached(&self) -> bool {
        self.active.is_none()
    }

    fn open_as_master(path: &Path, limit: Duration) -> std::io::Result<Card> {
        let began = Instant::now();
        let mut waited = false;
        loop {
            let file = OpenOptions::new().read(true).write(true).open(path)?;
            let card = Card(file);
            // Note: on Linux, opening /dev/dri/cardX when no master exists ALREADY
            // makes `card` DRM master via `drm_open_helper()` without needing
            // `CAP_SYS_ADMIN`! We probe whether master operations work via a dummy
            // check or `acquire_master_lock()`: if `acquire_master_lock()` returns
            // Ok OR returns PermissionDenied while we ALREADY got master on open
            // (`auth_magic(0)` / `resource_handles` + `create_dumb_buffer` test),
            // let's check via `set_crtc` readiness or `drmIsMaster`!
            if is_drm_master(&card) || card.acquire_master_lock().is_ok() {
                if waited {
                    crate::logline!(
                        "panel          DRM master granted after {}ms",
                        began.elapsed().as_millis()
                    );
                }
                return Ok(card);
            }

            if began.elapsed() >= limit {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    format!(
                        "{}: no DRM master after {}ms (another client holds master)",
                        path.display(),
                        began.elapsed().as_millis(),
                    ),
                ));
            }
            if !waited {
                crate::logline!("panel          waiting for DRM master on {}", path.display());
                waited = true;
            }
            drop(card);
            std::thread::sleep(Duration::from_millis(80));
        }
    }

    /// Re-open the DRM device after a `/dev/fb_lcd` app exits; the next `commit()`
    /// performs `set_crtc()` with `flipctl`'s full frame.
    pub fn attach(&mut self) -> std::io::Result<()> {
        if self.active.is_some() {
            return Ok(());
        }
        let began = Instant::now();
        let active = Self::open_active(&self.path, true, ATTACH_WAIT)?;
        self.rgb565 = active.rgb565;
        self.active = Some(active);
        eprintln!("panel          reclaimed DRM node in {}ms", began.elapsed().as_millis());
        Ok(())
    }

    fn set_crtc_on(active: &KmsActive) -> std::io::Result<()> {
        active.card.set_crtc(
            active.crtc,
            Some(active.fb),
            (0, 0),
            &[active.connector],
            Some(active.mode),
        )
    }

    pub fn flush_path(&self) -> &'static str {
        let f = self.active.as_ref().map_or(self.last_flush, |a| a.flush);
        match f {
            Flush::Probe => "unprobed",
            Flush::DirtyFb => "DIRTYFB",
            Flush::SetCrtc => "set_crtc (driver has no dirty_fb)",
        }
    }
}

/// Non-root check for whether `card` already holds DRM master (`drm_open_helper`
/// grants master automatically on `open()` when no other master exists, whereas
/// `DRM_IOCTL_SET_MASTER` requires `CAP_SYS_ADMIN` and returns `EACCES` even if we
/// are already master!). `DRM_IOCTL_AUTH_MAGIC` (`0x6411`) with magic=0 returns
/// `EINVAL` (22) when we ARE master and `EACCES` (13) when we are NOT master!
fn is_drm_master(card: &Card) -> bool {
    const DRM_IOCTL_AUTH_MAGIC: libc::c_ulong = 0x4004_6411;
    let mut magic: u32 = 0;
    let rc = unsafe { libc::ioctl(card.0.as_raw_fd(), DRM_IOCTL_AUTH_MAGIC, &mut magic) };
    if rc == 0 {
        return true;
    }
    let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    err == libc::EINVAL
}

/// Explicitly force `drm_fb_helper_set_par` on `/dev/fb_lcd` via `FBIOPUT_VSCREENINFO`
/// with `FB_ACTIVATE_FORCE` (`0x80`) so `/dev/fb_lcd` immediately re-binds to the
/// ST7789v3 CRTC when `flipctl` detaches.
fn force_restore_fbdev() {
    const FBIOGET_VSCREENINFO: libc::c_ulong = 0x4600;
    const FBIOPUT_VSCREENINFO: libc::c_ulong = 0x4601;
    const FBIOBLANK: libc::c_ulong = 0x4611;
    const FB_ACTIVATE_FORCE: u32 = 0x80;

    let Ok(fb) = OpenOptions::new().read(true).write(true).open("/dev/fb_lcd") else {
        return;
    };
    let fd = fb.as_raw_fd();
    let mut var = [0u32; 40]; // 160 bytes == sizeof(struct fb_var_screeninfo) on LP64
    unsafe {
        let _ = libc::ioctl(fd, FBIOBLANK, 0 as libc::c_ulong);
        if libc::ioctl(fd, FBIOGET_VSCREENINFO, var.as_mut_ptr()) == 0 {
            // `activate` is at byte offset 24 (`var[6]`) in `struct fb_var_screeninfo`.
            var[6] |= FB_ACTIVATE_FORCE;
            let _ = libc::ioctl(fd, FBIOPUT_VSCREENINFO, var.as_ptr());
        }
    }
}

fn is_unsupported(e: &std::io::Error) -> bool {
    matches!(e.raw_os_error(), Some(38) | Some(95))
}
