//! The browser view's wire protocol, exercised over a real socket.
//!
//! Only built with `--features remote`.

#![cfg(feature = "remote")]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use flipper_ui::pixel::{Gray8, Rect};
use flipper_ui::platform::{Frame, FrameSink, InputSource};
use flipper_ui::remote::RemoteView;
use flipper_ui::{FlipperKey, PANEL_H, PANEL_W};

fn view() -> RemoteView {
    RemoteView::bind(
        "127.0.0.1:0",
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/remote"),
    )
    .expect("bind")
}

fn request(addr: std::net::SocketAddr, request: &str) -> (String, Vec<u8>) {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream.write_all(request.as_bytes()).expect("write");
    let mut reader = BufReader::new(stream);

    let mut status = String::new();
    reader.read_line(&mut status).expect("status line");
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("header");
        if line.trim_end().is_empty() {
            break;
        }
    }
    let mut body = Vec::new();
    reader.read_to_end(&mut body).expect("body");
    (status, body)
}

#[test]
fn serves_the_page_and_the_device_photo() {
    let view = view();
    let addr = view.addr();

    let (status, body) = request(addr, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    assert!(status.contains("200"), "page status: {status}");
    let page = String::from_utf8_lossy(&body);
    assert!(page.contains("<canvas id=\"panel\""), "page has the panel canvas");
    // The hitmap's wire names must be names the device actually accepts.
    for key in FlipperKey::ALL {
        assert!(
            page.contains(&format!("'{}'", key.name())),
            "the page has no zone or keybinding for {}",
            key.name()
        );
    }

    let (status, body) = request(addr, "GET /device.png HTTP/1.1\r\nHost: x\r\n\r\n");
    assert!(status.contains("200"), "photo status: {status}");
    assert_eq!(&body[1..4], b"PNG", "device.png is a PNG");
}

/// With nobody watching, a commit must do no work. That is what lets the view be
/// compiled into flipctl without being a tax when unused.
#[test]
fn commits_are_free_while_unwatched() {
    let mut view = view();
    assert_eq!(view.viewers(), 0);

    let pixels = vec![Gray8::WHITE; usize::from(PANEL_W) * usize::from(PANEL_H)];
    view.commit(Frame::new(&pixels, PANEL_W, PANEL_H), Rect::new(0, 0, PANEL_W, PANEL_H))
        .expect("commit");
    assert_eq!(view.viewers(), 0);
}

/// A viewer gets a whole frame, header first, as soon as one is available.
///
/// Whole frames rather than damaged regions: a single shared damage accumulator
/// is drained by whichever viewer reads first, so a second viewer or a reconnect
/// would get a partial screen. 36 KB at 30fps is affordable; a wrong screen is
/// not.
#[test]
fn streams_whole_frames_with_a_header() {
    let mut view = view();
    let addr = view.addr();

    let mut pixels = vec![Gray8::WHITE; usize::from(PANEL_W) * usize::from(PANEL_H)];
    pixels[0] = Gray8::BLACK;

    // Damage accumulated while unwatched.
    view.commit(Frame::new(&pixels, PANEL_W, PANEL_H), Rect::new(0, 0, 10, 10))
        .expect("unwatched commit");

    let mut stream = TcpStream::connect(addr).expect("connect");
    stream.write_all(b"GET /stream HTTP/1.1\r\nHost: x\r\n\r\n").expect("write");
    stream.set_read_timeout(Some(Duration::from_secs(10))).expect("timeout");
    let mut reader = BufReader::new(stream);

    let mut status = String::new();
    reader.read_line(&mut status).expect("status");
    assert!(status.contains("200"), "stream status: {status}");
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("header");
        if line.trim_end().is_empty() {
            break;
        }
    }

    // Wait for the server to register the viewer before committing.
    for _ in 0..100 {
        if view.viewers() > 0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(view.viewers(), 1, "the stream must register as a viewer");

    view.commit(Frame::new(&pixels, PANEL_W, PANEL_H), Rect::new(20, 20, 8, 4))
        .expect("watched commit");

    // One chunk: hex length, CRLF, body, CRLF.
    let mut size_line = String::new();
    reader.read_line(&mut size_line).expect("chunk size");
    let size = usize::from_str_radix(size_line.trim_end(), 16).expect("hex chunk size");
    let mut body = vec![0; size];
    reader.read_exact(&mut body).expect("chunk body");

    let x = u16::from_le_bytes([body[0], body[1]]);
    let y = u16::from_le_bytes([body[2], body[3]]);
    let w = u16::from_le_bytes([body[4], body[5]]);
    let h = u16::from_le_bytes([body[6], body[7]]);

    assert_eq!((x, y), (0, 0), "whole frames always start at the origin");
    assert_eq!((w, h), (PANEL_W, PANEL_H), "a whole frame, not a sub-region");
    assert_eq!(size, 8 + usize::from(w) * usize::from(h) * 2, "header plus w*h*2 RGB565 bytes");
    assert_eq!(
        u16::from_le_bytes([body[8], body[9]]),
        Gray8::BLACK.0,
        "the ink pixel at (0,0) came through"
    );
}

/// A POST becomes a key event on the same queue the buttons feed.
#[test]
fn input_posts_become_key_events() {
    let mut view = view();
    let addr = view.addr();

    for (key, down) in [(FlipperKey::View, true), (FlipperKey::Run, false)] {
        let body = format!("{{\"key\":\"{}\",\"down\":{down}}}", key.name());
        let mut stream = TcpStream::connect(addr).expect("connect");
        write!(
            stream,
            "POST /input HTTP/1.1\r\nHost: x\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .expect("write");
        drop(stream);

        let mut got = None;
        for _ in 0..100 {
            if let Some(event) = view.poll() {
                got = Some(event);
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let event = got.expect("the POST should have produced an event");
        assert_eq!(event.key, key);
        assert_eq!(event.down, down);
    }

    // An unknown key name is ignored rather than crashing the connection.
    let body = "{\"key\":\"del\",\"down\":true}";
    let mut stream = TcpStream::connect(addr).expect("connect");
    write!(
        stream,
        "POST /input HTTP/1.1\r\nHost: x\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .expect("write");
    drop(stream);
    std::thread::sleep(Duration::from_millis(100));
    assert!(view.poll().is_none(), "there is no Del key");
}

/// The case a shared damage accumulator got wrong: a viewer that connects after
/// another has already drained it must still receive a complete screen.
#[test]
fn a_second_viewer_also_gets_a_whole_frame() {
    let mut view = view();
    let addr = view.addr();

    let mut pixels = vec![Gray8::WHITE; usize::from(PANEL_W) * usize::from(PANEL_H)];
    pixels[0] = Gray8::BLACK;

    let mut first_frames = Vec::new();
    for round in 0..2 {
        let mut stream = TcpStream::connect(addr).expect("connect");
        stream.write_all(b"GET /stream HTTP/1.1\r\nHost: x\r\n\r\n").expect("write");
        stream.set_read_timeout(Some(Duration::from_secs(10))).expect("timeout");
        let mut reader = BufReader::new(stream);

        let mut line = String::new();
        reader.read_line(&mut line).expect("status");
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).expect("header");
            if header.trim_end().is_empty() {
                break;
            }
        }

        for _ in 0..100 {
            if view.viewers() > 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        view.commit(Frame::new(&pixels, PANEL_W, PANEL_H), Rect::new(0, 0, PANEL_W, PANEL_H))
            .expect("commit");

        // Skip any keepalive and take the first real frame.
        let (w, h) = loop {
            let mut size_line = String::new();
            reader.read_line(&mut size_line).expect("chunk size");
            let size = usize::from_str_radix(size_line.trim_end(), 16).expect("hex");
            let mut body = vec![0; size];
            reader.read_exact(&mut body).expect("body");
            let mut crlf = [0; 2];
            reader.read_exact(&mut crlf).expect("chunk crlf");
            let w = u16::from_le_bytes([body[4], body[5]]);
            let h = u16::from_le_bytes([body[6], body[7]]);
            if w != 0 && h != 0 {
                break (w, h);
            }
        };
        first_frames.push((round, w, h));
        drop(reader);
        for _ in 0..100 {
            if view.viewers() == 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    assert_eq!(
        first_frames,
        vec![(0, PANEL_W, PANEL_H), (1, PANEL_W, PANEL_H)],
        "both viewers must receive a complete screen"
    );
}

#[test]
fn pin_auth_gates_stream_and_input_blocks_csrf_and_unbinds_on_drop() {
    use flipper_ui::remote::AuthConfig;

    let mut view = RemoteView::bind_secured(
        &["127.0.0.1:0"],
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/remote"),
        None,
        Some(AuthConfig::new("654321".into(), true)),
    )
    .expect("bind secured");
    let addr = view.addr();
    let host = format!("127.0.0.1:{}", addr.port());

    // 1. Unauthenticated `/` serves the PIN login gate, not the KVM canvas.
    let (status, body) = request(addr, &format!("GET / HTTP/1.1\r\nHost: {host}\r\n\r\n"));
    assert!(status.contains("200"), "login gate status: {status}");
    let html = String::from_utf8_lossy(&page_slice(&body));
    assert!(html.contains("Web KVM Locked"), "should serve PIN login gate");
    assert!(!html.contains("<canvas id=\"panel\""), "must not leak KVM page before login");

    // 2. Unauthenticated `/stream` and `/input` are rejected with 401.
    let (st_stream, _) = request(addr, &format!("GET /stream HTTP/1.1\r\nHost: {host}\r\n\r\n"));
    assert!(st_stream.contains("401"), "unauth stream must 401: {st_stream}");
    let payload = "{\"key\":\"ok\",\"down\":true}";
    let (st_in, _) = request(
        addr,
        &format!(
            "POST /input HTTP/1.1\r\nHost: {host}\r\nContent-Length: {}\r\n\r\n{payload}",
            payload.len()
        ),
    );
    assert!(st_in.contains("401"), "unauth input must 401: {st_in}");
    assert!(view.poll().is_none(), "unauthenticated POST must not inject keys");

    // 3. DNS-rebinding Host header is rejected with 403.
    let (st_rebind, _) = request(addr, "GET / HTTP/1.1\r\nHost: evil.example.com\r\n\r\n");
    assert!(st_rebind.contains("403"), "rebinding Host must 403: {st_rebind}");

    // 4. Login with valid PIN issues HttpOnly SameSite=Strict session cookie.
    let login_body = "{\"pin\":\"654321\"}";
    let mut stream = TcpStream::connect(addr).expect("connect login");
    write!(
        stream,
        "POST /login HTTP/1.1\r\nHost: {host}\r\nOrigin: http://{host}\r\nContent-Length: {}\r\n\r\n{login_body}",
        login_body.len()
    )
    .expect("write login");
    let mut reader = BufReader::new(stream);
    let mut status_line = String::new();
    reader.read_line(&mut status_line).expect("login status");
    assert!(status_line.contains("200"), "valid PIN should succeed: {status_line}");
    let mut cookie = String::new();
    loop {
        let mut h = String::new();
        reader.read_line(&mut h).expect("hdr");
        let ht = h.trim_end();
        if ht.is_empty() {
            break;
        }
        if let Some((_, v)) = ht.split_once(':').filter(|(k, _)| k.eq_ignore_ascii_case("set-cookie"))
        {
            cookie = v.split(';').next().unwrap_or("").trim().to_string();
            assert!(v.contains("HttpOnly") && v.contains("SameSite=Strict"));
        }
    }
    assert!(cookie.starts_with("cz_kvm="), "expected session cookie, got {cookie}");

    // 5. Cross-origin POST even with valid cookie is blocked (403).
    let (st_csrf, _) = request(
        addr,
        &format!(
            "POST /input HTTP/1.1\r\nHost: {host}\r\nOrigin: http://attacker.invalid\r\nCookie: {cookie}\r\nContent-Length: {}\r\n\r\n{payload}",
            payload.len()
        ),
    );
    assert!(st_csrf.contains("403"), "cross-origin POST must 403: {st_csrf}");
    assert!(view.poll().is_none());

    // 6. Same-origin authenticated POST /input succeeds.
    let (st_ok, _) = request(
        addr,
        &format!(
            "POST /input HTTP/1.1\r\nHost: {host}\r\nOrigin: http://{host}\r\nCookie: {cookie}\r\nContent-Length: {}\r\n\r\n{payload}",
            payload.len()
        ),
    );
    assert!(st_ok.contains("200"), "authenticated POST /input must 200: {st_ok}");
    assert_eq!(view.poll().map(|e| e.key), Some(FlipperKey::Ok));

    // 7. Dropping RemoteView immediately closes the TCP listener so the port can be rebound.
    drop(view);
    for _ in 0..50 {
        if std::net::TcpListener::bind(addr).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("listener port {addr} remained bound after dropping RemoteView");
}

fn page_slice(b: &[u8]) -> &[u8] {
    b
}
