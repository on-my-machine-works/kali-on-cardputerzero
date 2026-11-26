//! USB & Bluetooth HID Deck for M5Stack CardputerZero.
//!
//! Forwards CardputerZero's physical 46-key keyboard (`a-z`, `A-Z`, `0-9`, `Sym`
//! symbols, `Ctrl` chords, `Enter`, `Backspace`, `Delete`, and `Fn+Arrows`) directly
//! over USB-C or Bluetooth LE HID without an on-screen virtual keyboard.
//! `Fn+6` toggles between Live Keyboard mode and Mouse + Media mode; `Fn+8` switches
//! between USB-C and Bluetooth; `Esc` closes the app.

mod bt;
mod hid;
mod usb;

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use flipctl_app::{EvdevSource, Haptic, Key, StatusSource, Touch, TouchpadSource, TypedEvent};
use slint::ComponentHandle;

use crate::bt::Bluetooth;
use crate::usb::Usb;

slint::include_modules!();

const TAP: Duration = Duration::from_millis(250);
const TAP_TRAVEL: i32 = 40;
const MOUSE_STEP: i8 = 14;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Link {
    Usb,
    Bluetooth,
}

struct Stroke {
    at: Instant,
    last: (i32, i32),
    travel: i32,
}

struct State {
    usb: Option<Usb>,
    bt: Option<Bluetooth>,
    ev: Option<EvdevSource>,
    pad: Option<TouchpadSource>,
    buzz: Option<Haptic>,
    pointer: hid::Pointer,
    stroke: Option<Stroke>,
    /// False = physical QWERTY keyboard forwarding; true = Mouse + Media mode.
    to_host: bool,
    link: Link,
    state: String,
    port: String,
    last_sent: String,
}

impl State {
    fn new() -> State {
        let port = flipctl_app::device_port_name();
        #[cfg(not(test))]
        let ev = EvdevSource::open().ok();
        #[cfg(test)]
        let ev = None;
        State {
            usb: Some(Usb::start()),
            bt: None,
            ev,
            pad: TouchpadSource::open().ok(),
            buzz: Haptic::open().ok(),
            pointer: hid::Pointer::default(),
            stroke: None,
            to_host: false,
            link: Link::Usb,
            state: "waiting".into(),
            port: if port.is_empty() { "USB-C".into() } else { port },
            last_sent: "Ready for physical keystrokes".into(),
        }
    }

    fn link_name(&self) -> String {
        match self.link {
            Link::Usb => self.port.clone(),
            Link::Bluetooth => "Bluetooth".into(),
        }
    }

    fn switch_hint(&self) -> &'static str {
        match self.link {
            Link::Usb => "Fn+8: BT",
            Link::Bluetooth => "Fn+8: USB",
        }
    }

    fn toggle_mode(&mut self) {
        self.to_host = !self.to_host;
        self.stroke = None;
        self.pointer.reset();
        self.last_sent = if self.to_host {
            "Mouse + Media mode active".into()
        } else {
            "Ready for physical keystrokes".into()
        };
        if let Some(buzz) = self.buzz.as_mut() {
            if self.to_host {
                buzz.play(108, 0);
            } else {
                buzz.play(97, 100);
            }
        }
    }

    fn switch(&mut self) {
        self.link = if self.link == Link::Usb { Link::Bluetooth } else { Link::Usb };
        self.usb = None;
        self.bt = None;
        match self.link {
            Link::Usb => self.usb = Some(Usb::start()),
            Link::Bluetooth => self.bt = Some(Bluetooth::start()),
        }
        self.last_sent = format!("Switched to {}", self.link_name());
    }

    fn send(&mut self, report: &[u8]) {
        if let Some(usb) = self.usb.as_mut() {
            usb.send(report);
        }
        if let Some(bt) = self.bt.as_mut() {
            bt.send(report);
        }
    }

    fn tap_key(&mut self, modifiers: u8, keycode: u8) {
        self.send(&hid::keyboard(modifiers, keycode));
        self.send(&hid::keyboard(0, 0));
    }

    fn tap_consumer(&mut self, usage: u16) {
        self.send(&hid::consumer(usage));
        self.send(&hid::consumer(0));
    }

    fn handle_typed(&mut self, tev: TypedEvent) -> bool {
        match tev {
            TypedEvent::Esc => return false,
            TypedEvent::F6 => {
                self.toggle_mode();
                return true;
            }
            TypedEvent::F8 => {
                self.switch();
                return true;
            }
            _ => {}
        }

        if !self.to_host {
            match tev {
                TypedEvent::Char(ch) => {
                    if let Some((mods, keycode)) = hid::usage(ch) {
                        self.tap_key(mods, keycode);
                        self.last_sent = if ch == ' ' {
                            "Sent: Space".into()
                        } else {
                            format!("Sent: '{ch}'")
                        };
                    }
                }
                TypedEvent::CtrlChar(ch) => {
                    if let Some((_, keycode)) = hid::usage(ch) {
                        self.tap_key(hid::CTRL, keycode);
                        self.last_sent = format!("Sent: Ctrl+{}", ch.to_ascii_uppercase());
                    }
                }
                TypedEvent::Enter => {
                    self.tap_key(0, hid::ENTER);
                    self.last_sent = "Sent: Enter".into();
                }
                TypedEvent::Backspace => {
                    self.tap_key(0, hid::BACKSPACE);
                    self.last_sent = "Sent: Backspace".into();
                }
                TypedEvent::Delete => {
                    self.tap_key(0, hid::DELETE);
                    self.last_sent = "Sent: Delete".into();
                }
                TypedEvent::Left => {
                    self.tap_key(0, hid::LEFT);
                    self.last_sent = "Sent: Left".into();
                }
                TypedEvent::Right => {
                    self.tap_key(0, hid::RIGHT);
                    self.last_sent = "Sent: Right".into();
                }
                TypedEvent::Up => {
                    self.tap_key(0, hid::UP);
                    self.last_sent = "Sent: Up".into();
                }
                TypedEvent::Down => {
                    self.tap_key(0, hid::DOWN);
                    self.last_sent = "Sent: Down".into();
                }
                TypedEvent::Home => {
                    self.tap_key(0, hid::HOME);
                    self.last_sent = "Sent: Home".into();
                }
                TypedEvent::End => {
                    self.tap_key(0, hid::END);
                    self.last_sent = "Sent: End".into();
                }
                TypedEvent::Esc | TypedEvent::F6 | TypedEvent::F8 => {}
            }
        } else {
            match tev {
                TypedEvent::Up | TypedEvent::Char('f' | 'F' | 'w' | 'W' | 'k' | 'K') => {
                    self.send(&hid::mouse(0, 0, -MOUSE_STEP, 0));
                    self.last_sent = "Mouse: Up".into();
                }
                TypedEvent::Down | TypedEvent::Char('x' | 'X' | 's' | 'S' | 'j' | 'J') => {
                    self.send(&hid::mouse(0, 0, MOUSE_STEP, 0));
                    self.last_sent = "Mouse: Down".into();
                }
                TypedEvent::Left | TypedEvent::Char('z' | 'Z' | 'a' | 'A' | 'h' | 'H') => {
                    self.send(&hid::mouse(0, -MOUSE_STEP, 0, 0));
                    self.last_sent = "Mouse: Left".into();
                }
                TypedEvent::Right | TypedEvent::Char('c' | 'C' | 'd' | 'D' | 'l' | 'L') => {
                    self.send(&hid::mouse(0, MOUSE_STEP, 0, 0));
                    self.last_sent = "Mouse: Right".into();
                }
                TypedEvent::Enter | TypedEvent::Char(' ') => {
                    self.send(&hid::mouse(1, 0, 0, 0));
                    self.send(&hid::mouse(0, 0, 0, 0));
                    self.last_sent = "Mouse: Left Click".into();
                }
                TypedEvent::Backspace => {
                    self.send(&hid::mouse(2, 0, 0, 0));
                    self.send(&hid::mouse(0, 0, 0, 0));
                    self.last_sent = "Mouse: Right Click".into();
                }
                TypedEvent::Char('7' | '+' | '=') => {
                    self.tap_consumer(hid::VOLUME_UP);
                    self.last_sent = "Media: Volume +".into();
                }
                TypedEvent::Char('5' | '-' | '_') => {
                    self.tap_consumer(hid::VOLUME_DOWN);
                    self.last_sent = "Media: Volume -".into();
                }
                _ => {}
            }
        }
        true
    }

    fn touch(&mut self, t: Touch) -> bool {
        let previous = self.stroke.as_ref().map(|s| s.last);
        if t.down {
            let stroke = self.stroke.get_or_insert(Stroke {
                at: Instant::now(),
                last: (t.x, t.y),
                travel: 0,
            });
            stroke.travel += (t.x - stroke.last.0).abs() + (t.y - stroke.last.1).abs();
            stroke.last = (t.x, t.y);
            if let Some((x, y)) = previous {
                for (dx, dy) in self.pointer.moved(t.x - x, t.y - y) {
                    self.send(&hid::mouse(0, dx, dy, 0));
                }
            }
            return false;
        }
        let tap =
            self.stroke.take().is_some_and(|s| s.at.elapsed() < TAP && s.travel < TAP_TRAVEL);
        self.pointer.reset();
        if tap {
            self.send(&hid::mouse(1, 0, 0, 0));
            self.send(&hid::mouse(0, 0, 0, 0));
            self.last_sent = "Mouse: Left Click".into();
            return true;
        }
        false
    }

    fn poll(&mut self) -> (bool, bool) {
        let mut alive = true;
        let mut changed = false;
        while let Some(tev) = self.ev.as_mut().and_then(EvdevSource::poll_typed) {
            changed = true;
            if !self.handle_typed(tev) {
                alive = false;
                break;
            }
        }
        if let Some(ev) = self.ev.as_mut() {
            ev.discard_navigation();
        }
        let state = match (self.usb.as_mut(), self.bt.as_ref()) {
            (Some(usb), _) => {
                usb.poll();
                usb.state()
            }
            (None, Some(bt)) => bt.state(),
            (None, None) => String::new(),
        };
        if state != self.state {
            self.state = state;
            changed = true;
        }
        (alive, changed)
    }
}

fn apply(ui: &AppWindow, s: &State) {
    ui.set_to_host(s.to_host);
    ui.set_link(s.link_name().as_str().into());
    ui.set_state(s.state.as_str().into());
    ui.set_last_sent(s.last_sent.as_str().into());
    ui.set_switch_hint(s.switch_hint().into());
}

/// Web Remote / Wayland semantic key fallback. Returns false when the app should close.
fn key(s: &mut State, key: Key, down: bool) -> bool {
    if !down {
        return true;
    }
    match key {
        Key::Escape | Key::Back => return false,
        Key::Ptt | Key::Power => s.toggle_mode(),
        Key::Run => s.switch(),
        Key::Up => {
            let _ = s.handle_typed(TypedEvent::Up);
        }
        Key::Down => {
            let _ = s.handle_typed(TypedEvent::Down);
        }
        Key::Left => {
            let _ = s.handle_typed(TypedEvent::Left);
        }
        Key::Right => {
            let _ = s.handle_typed(TypedEvent::Right);
        }
        Key::Ok => {
            let _ = s.handle_typed(TypedEvent::Enter);
        }
        Key::Edit => {
            let _ = s.handle_typed(TypedEvent::Backspace);
        }
        Key::View => {
            if s.to_host {
                s.tap_consumer(hid::VOLUME_DOWN);
                s.last_sent = "Media: Volume -".into();
            }
        }
    }
    true
}

fn main() -> Result<(), slint::PlatformError> {
    let ui = AppWindow::new()?;
    let state = Rc::new(RefCell::new(State::new()));
    apply(&ui, &state.borrow());

    let mut status = StatusSource::new(Duration::from_secs(2));
    flipctl_app::apply_status!(&ui, PanelStatus, status.current());

    let tick = slint::Timer::default();
    let ticking = ui.as_weak();
    let ticked = Rc::clone(&state);
    tick.start(slint::TimerMode::Repeated, Duration::from_millis(30), move || {
        let Some(ui) = ticking.upgrade() else { return };
        let mut s = ticked.borrow_mut();
        let (alive, mut changed) = s.poll();
        if !alive {
            let _ = slint::quit_event_loop();
            return;
        }
        while let Some(t) = s.pad.as_mut().and_then(TouchpadSource::poll) {
            changed |= s.touch(t);
        }
        if changed {
            apply(&ui, &s);
        }
        if let Some(now) = status.poll() {
            flipctl_app::apply_status!(&ui, PanelStatus, now);
        }
    });

    let keys = ui.as_weak();
    let keyed = Rc::clone(&state);
    ui.on_keyed(move |text, down| {
        let Some(ui) = keys.upgrade() else { return };
        let Some(pressed) = Key::from_slint(text.as_str()) else { return };
        let mut s = keyed.borrow_mut();
        if !key(&mut s, pressed, down) {
            let _ = slint::quit_event_loop();
            return;
        }
        apply(&ui, &s);
    });

    ui.run()
}

#[cfg(test)]
mod tests {
    use super::*;
    use flipctl_app::theme;
    use flipper_ui::slint_render::{render_frame, FlipperSlintPlatform};
    use slint::platform::software_renderer::MinimalSoftwareWindow;

    fn panel() -> Rc<MinimalSoftwareWindow> {
        thread_local! {
            static WINDOW: Rc<MinimalSoftwareWindow> = FlipperSlintPlatform::install();
        }
        WINDOW.with(Rc::clone)
    }

    fn shot(name: &str, s: &State) -> Vec<u8> {
        let window = panel();
        let ui = AppWindow::new().expect("create AppWindow");
        apply(&ui, s);
        ui.show().expect("show");
        slint::platform::update_timers_and_animations();
        let raw = render_frame(&window).expect("frame");
        let mut frame = Vec::with_capacity(raw.len() * 3);
        for px in &raw {
            let (r, g, b) = px.to_rgb8();
            frame.extend_from_slice(&[r, g, b]);
        }
        drop(ui);
        if std::env::var_os("HID_RENDER").is_some() {
            let dir = std::path::Path::new("target/render");
            std::fs::create_dir_all(dir).expect("create target/render");
            let file = std::fs::File::create(dir.join(format!("{name}.png"))).expect("png");
            let mut enc = png::Encoder::new(
                std::io::BufWriter::new(file),
                u32::from(theme::PANEL_W),
                u32::from(theme::PANEL_H),
            );
            enc.set_color(png::ColorType::Rgb);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().expect("header").write_image_data(&frame).expect("data");
        }
        frame
    }

    #[test]
    fn both_modes_draw_and_type_directly() {
        let mut s = State::new();
        s.usb = None;
        s.port = "USB-C1".into();
        s.state = "ready".into();
        assert!(s.handle_typed(TypedEvent::Char('k')));
        assert_eq!(s.last_sent, "Sent: 'k'");
        shot("keys", &s);
        assert!(s.handle_typed(TypedEvent::F6));
        assert!(s.to_host);
        s.link = Link::Bluetooth;
        s.state = "waiting".into();
        shot("host", &s);
        s.to_host = false;
        s.state = "failed".into();
        shot("failed", &s);
        assert!(!s.handle_typed(TypedEvent::Esc));
    }
}
