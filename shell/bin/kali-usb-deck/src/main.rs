//! Native 320x170 Kali Dark Wayland Hosted Apps for CardputerZero (`flipctl-app`).
//!
//! Runs inside `flipctl`'s headless `sway` compositor with two modes:
//!   - Default (`kali-usb-deck`): **USB Arsenal** — live USB-C OTG mode switcher
//!     (Net, Combo Net+HID, MTP `/home/kali` + `ttyGS0`, Router LAN, Host/Off),
//!     bootable `.iso`/`.img` + read-write FAT32 loot image mounter, and DuckyScript
//!     BadUSB HID payload injector with live execution logs.
//!   - `--net-matrix`: **Net Matrix** — live Kali network & radio telemetry card
//!     (`wlan0`, `usb0`, `br-lan`, ARP neighbors, open TCP sockets, gateway), letting
//!     users test multi-app `Tab` **App Switcher** live cards immediately.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use flipctl_app::{heading, item, pair, redraw, rule, text, App, Item, Key, Page, Row, Ui};

fn main_entry() -> Box<dyn App> {
    let has = |f: &str| std::env::args().any(|a| a == f);
    if has("--net-matrix") {
        Box::new(NetMatrix::new())
    } else if has("--lan-scan") {
        Box::new(LanRecon::new())
    } else if has("--pkt-sniff") {
        Box::new(PktCapture::new())
    } else if has("--bt-deck") {
        Box::new(BtArsenal::new())
    } else if has("--wifi-recon") {
        Box::new(WifiRecon::new())
    } else if has("--ir-deck") {
        Box::new(IrArsenal::new())
    } else {
        Box::new(UsbArsenal::new())
    }
}

struct DynApp(Box<dyn App>);

impl App for DynApp {
    fn page(&self) -> Page {
        self.0.page()
    }
    fn buttons(&self) -> [&str; 5] {
        self.0.buttons()
    }
    fn key(&mut self, key: Key, ui: &mut Ui) -> bool {
        self.0.key(key, ui)
    }
    fn every(&self) -> Option<Duration> {
        self.0.every()
    }
    fn tick(&mut self, ui: &mut Ui) {
        self.0.tick(ui);
    }
    fn close(&mut self) {
        self.0.close();
    }
}

#[derive(Copy, Clone, PartialEq, Eq)]
enum Tab {
    Modes,
    Isos,
    Payloads,
    Log,
}

#[derive(Clone, Default)]
struct JobState {
    running: bool,
    title: String,
    lines: Vec<String>,
}

struct UsbArsenal {
    tab: Tab,
    prev_tab: Tab,
    isos: Vec<PathBuf>,
    payloads: Vec<PathBuf>,
    job: Arc<Mutex<JobState>>,
}

const MODES: &[(&str, &str, &[&str])] = &[
    ("Combo (Net+HID)", "10.55.0.1 + hidg0", &["combo"]),
    ("MTP + Serial", "/home/kali + ttyGS0", &["mtp"]),
    ("USB Net Only", "10.55.0.1/24", &["net"]),
    ("Router LAN", "usb0 -> br-lan", &["router-lan"]),
    ("Make 64M Loot", "FAT32 .img", &["create-loot", "64"]),
    ("Disable (Host)", "OTG off", &["off"]),
];

impl UsbArsenal {
    fn new() -> Self {
        let mut app = Self {
            tab: Tab::Modes,
            prev_tab: Tab::Modes,
            isos: Vec::new(),
            payloads: Vec::new(),
            job: Arc::new(Mutex::new(JobState::default())),
        };
        app.rescan();
        app
    }

    fn rescan(&mut self) {
        self.isos = scan_files(
            &["/home/kali/isos", "/root/isos"],
            &["iso", "img"],
        );
        self.payloads = scan_files(
            &["/home/kali/payloads", "/usr/share/czctl/payloads", "/usr/share/flipctl/payloads"],
            &["duck", "txt"],
        );
    }

    fn active_gadget_summary() -> String {
        let udc = std::fs::read_to_string("/sys/kernel/config/usb_gadget/kali_cz/UDC")
            .unwrap_or_default();
        let udc = udc.trim();
        if udc.is_empty() {
            return "HOST".into();
        }
        let funcs = std::fs::read_dir("/sys/kernel/config/usb_gadget/kali_cz/configs/c.1")
            .ok()
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        let has = |p: &str| funcs.iter().any(|f| f.starts_with(p));
        if has("ffs.mtp") {
            "MTP+NET".into()
        } else if has("mass_storage.") {
            "ISO+NET".into()
        } else if has("hid.") && (has("ncm.") || has("ecm.")) {
            "COMBO".into()
        } else if has("hid.") {
            "HID".into()
        } else if has("ncm.") || has("ecm.") {
            "NET".into()
        } else {
            "ACTIVE".into()
        }
    }

    fn current_lun_file() -> String {
        std::fs::read_to_string(
            "/sys/kernel/config/usb_gadget/kali_cz/functions/mass_storage.0/lun.0/file",
        )
        .unwrap_or_default()
        .trim()
        .to_string()
    }

    fn spawn_job(&mut self, title: impl Into<String>, prog: &str, args: Vec<String>) {
        {
            let Ok(mut st) = self.job.lock() else { return };
            if st.running {
                return;
            }
            st.running = true;
            st.title = title.into();
            st.lines = vec![format!("$ {} {}", prog, args.join(" "))];
        }
        self.prev_tab = if self.tab == Tab::Log { self.prev_tab } else { self.tab };
        self.tab = Tab::Log;

        let job = self.job.clone();
        let prog = prog.to_string();
        std::thread::spawn(move || {
            let mut cmd = if unsafe { libc_euid() } == 0 || prog == "/usr/local/bin/cz-badusb" {
                let mut c = Command::new(&prog);
                c.args(&args);
                c
            } else {
                let mut c = Command::new("sudo");
                c.arg("-n").arg(&prog).args(&args);
                c
            };
            cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());

            match cmd.spawn() {
                Ok(mut child) => {
                    let out = child.stdout.take();
                    let err = child.stderr.take();
                    let (tx, rx) = std::sync::mpsc::channel::<String>();
                    if let Some(out) = out {
                        let tx = tx.clone();
                        std::thread::spawn(move || {
                            for line in BufReader::new(out).lines().map_while(Result::ok) {
                                let _ = tx.send(line);
                            }
                        });
                    }
                    if let Some(err) = err {
                        let tx = tx.clone();
                        std::thread::spawn(move || {
                            for line in BufReader::new(err).lines().map_while(Result::ok) {
                                let _ = tx.send(line);
                            }
                        });
                    }
                    drop(tx);
                    for line in rx {
                        if line.trim().is_empty() {
                            continue;
                        }
                        if let Ok(mut st) = job.lock() {
                            st.lines.push(line);
                        }
                        redraw();
                    }
                    let status = child.wait();
                    if let Ok(mut st) = job.lock() {
                        match status {
                            Ok(s) if s.success() => st.lines.push("[OK] Completed.".into()),
                            Ok(s) => st.lines.push(format!("[ERR] Exited with {s}")),
                            Err(e) => st.lines.push(format!("[ERR] {e}")),
                        }
                        st.running = false;
                    }
                }
                Err(e) => {
                    if let Ok(mut st) = job.lock() {
                        st.lines.push(format!("[ERR] Failed to launch {prog}: {e}"));
                        st.running = false;
                    }
                }
            }
            redraw();
        });
    }

    fn activate_selected(&mut self, sel: usize) {
        match self.tab {
            Tab::Modes => {
                if let Some((label, _, args)) = MODES.get(sel) {
                    let vec_args = args.iter().map(|s| (*s).to_string()).collect();
                    self.spawn_job(*label, "/usr/local/bin/cz-flipper-gadget", vec_args);
                }
            }
            Tab::Isos => {
                if sel < self.isos.len() {
                    let path = self.isos[sel].clone();
                    let name = file_label(&path);
                    let is_loot = name.to_ascii_lowercase().contains("loot");
                    let subcmd = if is_loot { "loot" } else { "iso" };
                    self.spawn_job(
                        format!("Mount {name}"),
                        "/usr/local/bin/cz-flipper-gadget",
                        vec![subcmd.into(), path.to_string_lossy().into_owned()],
                    );
                } else {
                    self.spawn_job(
                        "Create 64MB Loot IMG",
                        "/usr/local/bin/cz-flipper-gadget",
                        vec!["create-loot".into(), "64".into()],
                    );
                }
            }
            Tab::Payloads => {
                if let Some(path) = self.payloads.get(sel).cloned() {
                    let name = file_label(&path);
                    self.spawn_job(
                        format!("BadUSB: {name}"),
                        "/usr/local/bin/cz-badusb",
                        vec![path.to_string_lossy().into_owned()],
                    );
                }
            }
            Tab::Log => {
                let running = self.job.lock().map(|s| s.running).unwrap_or(false);
                if !running {
                    self.rescan();
                    self.tab = self.prev_tab;
                }
            }
        }
    }
}

impl App for UsbArsenal {
    fn page(&self) -> Page {
        match self.tab {
            Tab::Modes => {
                let active = Self::active_gadget_summary();
                let items: Vec<Item> = MODES
                    .iter()
                    .enumerate()
                    .map(|(idx, (label, desc, _))| {
                        let st = if idx == 0 {
                            active.as_str()
                        } else {
                            *desc
                        };
                        item(*label).status(st)
                    })
                    .collect();
                Page::menu(items).id("modes")
            }
            Tab::Isos => {
                let mounted = Self::current_lun_file();
                let mut items: Vec<Item> = self
                    .isos
                    .iter()
                    .map(|p| {
                        let name = file_label(p);
                        let active = !mounted.is_empty() && Path::new(&mounted) == p.as_path();
                        let st = if active {
                            "MOUNTED".into()
                        } else {
                            human_bytes(p.metadata().map(|m| m.len()).unwrap_or(0))
                        };
                        item(name).status(st)
                    })
                    .collect();
                items.push(item("+ Create Loot 64MB").status("FAT32"));
                Page::menu(items).id("isos")
            }
            Tab::Payloads => {
                let items: Vec<Item> = if self.payloads.is_empty() {
                    vec![item("No .duck in ~/payloads").dim()]
                } else {
                    self.payloads
                        .iter()
                        .map(|p| {
                            let name = file_label(p);
                            let lines = std::fs::read_to_string(p)
                                .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count())
                                .unwrap_or(0);
                            item(name).status(format!("{lines}L"))
                        })
                        .collect()
                };
                Page::menu(items).id("payloads")
            }
            Tab::Log => {
                let (title, lines) = self
                    .job
                    .lock()
                    .map(|s| (s.title.clone(), s.lines.clone()))
                    .unwrap_or_else(|_| ("Output".into(), Vec::new()));
                Page::log(title, lines).id("log")
            }
        }
    }

    fn buttons(&self) -> [&str; 5] {
        match self.tab {
            Tab::Modes => ["Close", "[Modes]", "ISOs", "BadUSB", "Apply"],
            Tab::Isos => ["Close", "Modes", "[ISOs]", "BadUSB", "Mount"],
            Tab::Payloads => ["Close", "Modes", "ISOs", "[BadUSB]", "Fire"],
            Tab::Log => {
                let running = self.job.lock().map(|s| s.running).unwrap_or(false);
                if running {
                    ["", "", "", "", "Running"]
                } else {
                    ["Back", "Modes", "ISOs", "BadUSB", "Done"]
                }
            }
        }
    }

    fn key(&mut self, key: Key, ui: &mut Ui) -> bool {
        match key {
            Key::Escape if self.tab == Tab::Log => {
                let running = self.job.lock().map(|s| s.running).unwrap_or(false);
                if !running {
                    self.rescan();
                    self.tab = self.prev_tab;
                }
                true
            }
            Key::View => {
                self.rescan();
                self.tab = Tab::Modes;
                true
            }
            Key::Power => {
                self.rescan();
                self.tab = Tab::Isos;
                true
            }
            Key::Edit => {
                self.rescan();
                self.tab = Tab::Payloads;
                true
            }
            Key::Ok | Key::Run => {
                self.activate_selected(ui.selected());
                true
            }
            Key::Left | Key::Right if self.tab != Tab::Log => {
                let order = [Tab::Modes, Tab::Isos, Tab::Payloads];
                let pos = order.iter().position(|t| *t == self.tab).unwrap_or(0);
                let next = if key == Key::Right {
                    (pos + 1) % order.len()
                } else {
                    (pos + order.len() - 1) % order.len()
                };
                self.rescan();
                self.tab = order[next];
                true
            }
            _ => false,
        }
    }
}

struct NetMatrix {
    rows: Vec<Row>,
}

impl NetMatrix {
    fn new() -> Self {
        let mut n = Self { rows: Vec::new() };
        n.refresh();
        n
    }

    fn refresh(&mut self) {
        let wlan = ipv4_of("wlan0");
        let usb = ipv4_of("usb0");
        let br = ipv4_of("br-lan");
        let gw = default_gateway();
        let arp = arp_neighbors();
        let tcp = tcp_listening_count();
        let gadget = UsbArsenal::active_gadget_summary();
        let profile = booted_subvol();

        let mut rows = Vec::new();
        if !profile.is_empty() {
            rows.push(heading("Profile", &profile));
        }
        rows.push(pair("wlan0", if wlan.is_empty() { "down" } else { &wlan }));
        rows.push(pair("usb0 OTG", if usb.is_empty() { &gadget } else { &usb }));
        if !br.is_empty() {
            rows.push(pair("br-lan AP", &br));
        }
        rows.push(rule());
        rows.push(pair("Gateway", if gw.is_empty() { "none" } else { &gw }));
        rows.push(pair("ARP Hosts", arp.to_string()));
        rows.push(pair("TCP Listen", tcp.to_string()));
        rows.push(text("Press Tab for Flipper App Switcher").dim());
        self.rows = rows;
    }
}

impl App for NetMatrix {
    fn page(&self) -> Page {
        Page::detail(self.rows.clone()).id("netmatrix")
    }

    fn buttons(&self) -> [&str; 5] {
        ["Close", "Refresh", "USB Net", "Combo", ""]
    }

    fn every(&self) -> Option<Duration> {
        Some(Duration::from_secs(2))
    }

    fn tick(&mut self, _: &mut Ui) {
        self.refresh();
    }

    fn key(&mut self, key: Key, _: &mut Ui) -> bool {
        match key {
            Key::View => {
                self.refresh();
                true
            }
            Key::Power => {
                let _ = Command::new("sudo")
                    .args(["-n", "/usr/local/bin/cz-flipper-gadget", "net"])
                    .status();
                self.refresh();
                true
            }
            Key::Edit => {
                let _ = Command::new("sudo")
                    .args(["-n", "/usr/local/bin/cz-flipper-gadget", "combo"])
                    .status();
                self.refresh();
                true
            }
            _ => false,
        }
    }
}

struct LanHost {
    ip: String,
    mac: String,
    ports: Vec<String>,
}

struct LanRecon {
    ifaces: Vec<(String, String)>,
    if_idx: usize,
    hosts: Vec<LanHost>,
    detail_idx: Option<usize>,
    sweeping: Arc<Mutex<bool>>,
    found: Arc<Mutex<Option<Vec<LanHost>>>>,
}

impl LanRecon {
    fn new() -> Self {
        let mut s = Self {
            ifaces: Vec::new(),
            if_idx: 0,
            hosts: Vec::new(),
            detail_idx: None,
            sweeping: Arc::new(Mutex::new(false)),
            found: Arc::new(Mutex::new(None)),
        };
        s.refresh_ifaces();
        s.hosts = read_arp_hosts();
        s
    }

    fn refresh_ifaces(&mut self) {
        let mut list = Vec::new();
        if let Ok(rd) = std::fs::read_dir("/sys/class/net") {
            let mut names: Vec<String> = rd
                .flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| n != "lo")
                .collect();
            names.sort();
            for n in names {
                let cidr = ipv4_of(&n);
                if !cidr.is_empty() {
                    list.push((n, cidr));
                }
            }
        }
        self.ifaces = list;
        if self.if_idx >= self.ifaces.len() {
            self.if_idx = 0;
        }
    }

    fn start_sweep(&mut self) {
        if self.sweeping.lock().map(|b| *b).unwrap_or(false) {
            return;
        }
        self.refresh_ifaces();
        let Some((iface, cidr)) = self.ifaces.get(self.if_idx).cloned() else {
            self.hosts = read_arp_hosts();
            return;
        };
        if let Ok(mut b) = self.sweeping.lock() {
            *b = true;
        }
        let sweeping = Arc::clone(&self.sweeping);
        let found = Arc::clone(&self.found);
        std::thread::spawn(move || {
            let prefix = cidr
                .split('/')
                .next()
                .and_then(|ip| ip.rsplit_once('.').map(|(p, _)| p.to_string()))
                .unwrap_or_default();
            if !prefix.is_empty() {
                let script = format!(
                    "for i in $(seq 1 254); do ping -c1 -W1 -I {} {}.$i >/dev/null 2>&1 & \
                     [ $((i % 32)) -eq 0 ] && wait; done; wait",
                    iface, prefix
                );
                let _ = Command::new("sh").args(["-c", &script]).status();
            }
            let hosts = read_arp_hosts();
            if let Ok(mut out) = found.lock() {
                *out = Some(hosts);
            }
            if let Ok(mut b) = sweeping.lock() {
                *b = false;
            }
            redraw();
        });
    }

    fn probe_ports(&mut self, idx: usize) {
        let Some(host) = self.hosts.get(idx) else { return };
        let ip = host.ip.clone();
        let common = [
            (22u16, "ssh"),
            (53, "dns"),
            (80, "http"),
            (443, "https"),
            (445, "smb"),
            (3389, "rdp"),
            (8080, "http-alt"),
            (8899, "flipctl"),
        ];
        let mut open_ports = Vec::new();
        for (port, svc) in common {
            if let Ok(addr) = format!("{ip}:{port}").parse::<std::net::SocketAddr>() {
                if std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(120)).is_ok() {
                    open_ports.push(format!("{port}/tcp  {svc}"));
                }
            }
        }
        if open_ports.is_empty() {
            open_ports.push("No common TCP ports open".into());
        }
        if let Some(h) = self.hosts.get_mut(idx) {
            h.ports = open_ports;
        }
        self.detail_idx = Some(idx);
    }
}

impl App for LanRecon {
    fn page(&self) -> Page {
        if let Some(idx) = self.detail_idx.filter(|&i| i < self.hosts.len()) {
            let h = &self.hosts[idx];
            let mut rows = vec![
                heading("Host", &h.ip),
                pair("MAC", &h.mac),
                rule(),
            ];
            for p in &h.ports {
                rows.push(text(p));
            }
            return Page::detail(rows).id("lan-host");
        }

        let busy = self.sweeping.lock().map(|b| *b).unwrap_or(false);
        let iface_hdr = self
            .ifaces
            .get(self.if_idx)
            .map(|(n, c)| format!("{n} {c}"))
            .unwrap_or_else(|| "no active IPv4".into());
        let mut items = vec![
            item(if busy { "Sweeping subnet.." } else { "Active Interface" }).status(iface_hdr),
        ];
        if self.hosts.is_empty() {
            items.push(item("Press Sweep (Key 5)").status("ARP empty").dim());
        } else {
            for h in &self.hosts {
                let tail = h.mac.get(9..).unwrap_or(&h.mac);
                items.push(item(&h.ip).status(tail));
            }
        }
        Page::menu(items).id("lan-list")
    }

    fn buttons(&self) -> [&str; 5] {
        if self.detail_idx.is_some() {
            ["Back", "Rescan", "", "", ""]
        } else {
            ["Close", "Sweep", "Iface", "", "Ports"]
        }
    }

    fn every(&self) -> Option<Duration> {
        Some(Duration::from_millis(800))
    }

    fn tick(&mut self, _: &mut Ui) {
        let taken = self.found.lock().ok().and_then(|mut g| g.take());
        if let Some(h) = taken {
            self.hosts = h;
        }
    }

    fn key(&mut self, key: Key, ui: &mut Ui) -> bool {
        if let Some(idx) = self.detail_idx {
            match key {
                Key::Escape | Key::Back => {
                    self.detail_idx = None;
                    return true;
                }
                Key::View => {
                    self.probe_ports(idx);
                    return true;
                }
                _ => return false,
            }
        }
        match key {
            Key::View => {
                self.start_sweep();
                true
            }
            Key::Power => {
                self.refresh_ifaces();
                if !self.ifaces.is_empty() {
                    self.if_idx = (self.if_idx + 1) % self.ifaces.len();
                }
                true
            }
            Key::Ok | Key::Run => {
                let sel = ui.selected();
                if sel == 0 {
                    self.start_sweep();
                } else if sel - 1 < self.hosts.len() {
                    self.probe_ports(sel - 1);
                }
                true
            }
            _ => false,
        }
    }
}

const BPF_PRESETS: &[(&str, &str)] = &[
    ("ALL", ""),
    ("DNS/DHCP", "port 53 or port 67 or port 68"),
    ("WEB/TLS", "tcp port 80 or tcp port 443 or tcp port 8080"),
    ("ARP/ICMP", "arp or icmp or icmp6"),
    ("EAPOL", "ether proto 0x888e"),
];

struct PktCapture {
    ifaces: Vec<String>,
    if_idx: usize,
    preset_idx: usize,
    lines: Arc<Mutex<Vec<String>>>,
    child_pid: Arc<Mutex<Option<u32>>>,
    pcap_pid: Option<u32>,
    pcap_name: String,
}

impl PktCapture {
    fn new() -> Self {
        let mut ifaces = Vec::new();
        if let Ok(rd) = std::fs::read_dir("/sys/class/net") {
            for e in rd.flatten() {
                if let Ok(n) = e.file_name().into_string() {
                    if n != "lo" {
                        ifaces.push(n);
                    }
                }
            }
        }
        ifaces.sort();
        ifaces.push("any".into());
        Self {
            ifaces,
            if_idx: 0,
            preset_idx: 0,
            lines: Arc::new(Mutex::new(vec![
                "Press Run (Key 5) to stream packets.".into(),
                "Key 6 cycles filter; Key 7 cycles iface.".into(),
                "Key 8 records .pcap to ~/captures/.".into(),
            ])),
            child_pid: Arc::new(Mutex::new(None)),
            pcap_pid: None,
            pcap_name: String::new(),
        }
    }

    fn is_running(&self) -> bool {
        self.child_pid.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    fn stop_stream(&mut self) {
        if let Ok(mut g) = self.child_pid.lock() {
            if let Some(pid) = g.take() {
                let _ = Command::new("sudo").args(["-n", "kill", "-TERM", &pid.to_string()]).status();
            }
        }
    }

    fn toggle_stream(&mut self) {
        if self.is_running() {
            self.stop_stream();
            return;
        }
        let iface = self.ifaces.get(self.if_idx).cloned().unwrap_or_else(|| "any".into());
        let (_, bpf) = BPF_PRESETS[self.preset_idx];
        if let Ok(mut l) = self.lines.lock() {
            l.clear();
            l.push(format!("Listening on {iface} ({})..", BPF_PRESETS[self.preset_idx].0));
        }
        let lines = Arc::clone(&self.lines);
        let child_slot = Arc::clone(&self.child_pid);
        std::thread::spawn(move || {
            let mut cmd = Command::new("sudo");
            cmd.args(["-n", "tcpdump", "-l", "-n", "-q", "-t", "-i", &iface]);
            for tok in bpf.split_whitespace() {
                cmd.arg(tok);
            }
            cmd.stdout(Stdio::piped()).stderr(Stdio::null());
            let Ok(mut ch) = cmd.spawn() else {
                if let Ok(mut l) = lines.lock() {
                    l.push("tcpdump unavailable or sudo denied".into());
                }
                redraw();
                return;
            };
            if let Ok(mut slot) = child_slot.lock() {
                *slot = Some(ch.id());
            }
            if let Some(out) = ch.stdout.take() {
                for line in BufReader::new(out).lines().map_while(Result::ok) {
                    if let Ok(mut l) = lines.lock() {
                        let clean: String = line.chars().take(52).collect();
                        l.push(clean);
                        if l.len() > 160 {
                            l.drain(0..40);
                        }
                    }
                    redraw();
                    if child_slot.lock().map(|g| g.is_none()).unwrap_or(true) {
                        break;
                    }
                }
            }
            let _ = ch.kill();
            let _ = ch.wait();
            if let Ok(mut slot) = child_slot.lock() {
                *slot = None;
            }
            redraw();
        });
    }

    fn toggle_pcap(&mut self) {
        if let Some(pid) = self.pcap_pid.take() {
            let _ = Command::new("sudo").args(["-n", "kill", "-TERM", &pid.to_string()]).status();
            if let Ok(mut l) = self.lines.lock() {
                l.push(format!("Saved {}", self.pcap_name));
            }
            self.pcap_name.clear();
            return;
        }
        let _ = std::fs::create_dir_all("/home/kali/captures");
        let iface = self.ifaces.get(self.if_idx).cloned().unwrap_or_else(|| "any".into());
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() % 100_000)
            .unwrap_or(0);
        let path = format!("/home/kali/captures/cap_{iface}_{ts}.pcap");
        if let Ok(ch) = Command::new("sudo")
            .args(["-n", "tcpdump", "-U", "-i", &iface, "-w", &path])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            self.pcap_pid = Some(ch.id());
            self.pcap_name = path.clone();
            if let Ok(mut l) = self.lines.lock() {
                l.push(format!("REC -> {path}"));
            }
        }
    }
}

impl App for PktCapture {
    fn page(&self) -> Page {
        let iface = self.ifaces.get(self.if_idx).map(String::as_str).unwrap_or("any");
        let (flt, _) = BPF_PRESETS[self.preset_idx];
        let rec = if self.pcap_pid.is_some() { " [REC]" } else { "" };
        let title = format!("{iface} {flt}{rec}");
        let lines = self.lines.lock().map(|l| l.clone()).unwrap_or_default();
        Page::log(title, lines).id("pkt-log")
    }

    fn buttons(&self) -> [&str; 5] {
        [
            "Close",
            if self.is_running() { "Pause" } else { "Run" },
            "Filter",
            "Iface",
            if self.pcap_pid.is_some() { "StopRec" } else { "PCAP" },
        ]
    }

    fn key(&mut self, key: Key, _: &mut Ui) -> bool {
        match key {
            Key::View | Key::Ok => {
                self.toggle_stream();
                true
            }
            Key::Power => {
                let was = self.is_running();
                if was {
                    self.stop_stream();
                }
                self.preset_idx = (self.preset_idx + 1) % BPF_PRESETS.len();
                if was {
                    self.toggle_stream();
                }
                true
            }
            Key::Edit => {
                let was = self.is_running();
                if was {
                    self.stop_stream();
                }
                if !self.ifaces.is_empty() {
                    self.if_idx = (self.if_idx + 1) % self.ifaces.len();
                }
                if was {
                    self.toggle_stream();
                }
                true
            }
            Key::Run => {
                self.toggle_pcap();
                true
            }
            _ => false,
        }
    }

    fn close(&mut self) {
        self.stop_stream();
        if let Some(pid) = self.pcap_pid.take() {
            let _ = Command::new("sudo").args(["-n", "kill", "-TERM", &pid.to_string()]).status();
        }
    }
}

fn read_arp_hosts() -> Vec<LanHost> {
    let Ok(s) = std::fs::read_to_string("/proc/net/arp") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for line in s.lines().skip(1) {
        let mut cols = line.split_whitespace();
        let (Some(ip), _, Some(flags), Some(mac)) =
            (cols.next(), cols.next(), cols.next(), cols.next())
        else {
            continue;
        };
        if flags == "0x0" || mac == "00:00:00:00:00:00" {
            continue;
        }
        out.push(LanHost { ip: ip.to_string(), mac: mac.to_string(), ports: Vec::new() });
    }
    out.sort_by(|a, b| a.ip.cmp(&b.ip));
    out
}

fn scan_files(dirs: &[&str], exts: &[&str]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for dir in dirs {
        let Ok(rd) = std::fs::read_dir(dir) else { continue };
        for entry in rd.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let ok_ext = path
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| exts.iter().any(|want| e.eq_ignore_ascii_case(want)));
            if ok_ext && !out.iter().any(|p: &PathBuf| p.file_name() == path.file_name()) {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

fn file_label(path: &Path) -> String {
    path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn human_bytes(bytes: u64) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        format!("{:.1}G", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if bytes >= 1024 * 1024 {
        format!("{}M", bytes / (1024 * 1024))
    } else if bytes >= 1024 {
        format!("{}K", bytes / 1024)
    } else {
        format!("{bytes}B")
    }
}

fn ipv4_of(iface: &str) -> String {
    let Ok(out) = Command::new("ip").args(["-4", "-br", "addr", "show", iface]).output() else {
        return String::new();
    };
    if !out.status.success() {
        return String::new();
    }
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .nth(2)
        .unwrap_or_default()
        .to_string()
}

fn default_gateway() -> String {
    let Ok(text) = std::fs::read_to_string("/proc/net/route") else { return String::new() };
    for line in text.lines().skip(1) {
        let mut cols = line.split_whitespace();
        let (Some(iface), Some(dest), Some(gw)) = (cols.next(), cols.next(), cols.next()) else {
            continue;
        };
        if dest == "00000000" {
            if let Ok(raw) = u32::from_str_radix(gw, 16) {
                let b = raw.to_le_bytes();
                return format!("{}.{}.{}.{} ({iface})", b[0], b[1], b[2], b[3]);
            }
        }
    }
    String::new()
}

fn arp_neighbors() -> usize {
    std::fs::read_to_string("/proc/net/arp")
        .map(|s| s.lines().skip(1).filter(|l| !l.contains("0x0")).count())
        .unwrap_or(0)
}

fn tcp_listening_count() -> usize {
    std::fs::read_to_string("/proc/net/tcp")
        .map(|s| s.lines().skip(1).filter(|l| l.split_whitespace().nth(3) == Some("0A")).count())
        .unwrap_or(0)
}

fn booted_subvol() -> String {
    let Ok(out) = Command::new("findmnt").args(["-no", "SOURCE", "/"]).output() else {
        return String::new();
    };
    let s = String::from_utf8_lossy(&out.stdout);
    s.trim()
        .split('[')
        .nth(1)
        .and_then(|r| r.strip_suffix(']'))
        .map(|r| r.trim_start_matches('/').to_string())
        .unwrap_or_default()
}

unsafe fn libc_euid() -> u32 {
    extern "C" {
        fn geteuid() -> u32;
    }
    geteuid()
}

// ── Bluetooth & BLE Manager (`--bt-deck`) ──────────────────────────────────

#[derive(Clone)]
struct BtDevice {
    mac: String,
    name: String,
    rssi: String,
    paired: bool,
    connected: bool,
    uuids: usize,
}

struct BtArsenal {
    powered: bool,
    scanning: Arc<Mutex<bool>>,
    devices: Vec<BtDevice>,
    found: Arc<Mutex<Option<(bool, Vec<BtDevice>)>>>,
    detail: Option<usize>,
    note: String,
}

impl BtArsenal {
    fn new() -> Self {
        let (powered, devices) = read_bt_snapshot();
        Self {
            powered,
            scanning: Arc::new(Mutex::new(false)),
            devices,
            found: Arc::new(Mutex::new(None)),
            detail: None,
            note: String::new(),
        }
    }

    fn toggle_power(&mut self) {
        let next = !self.powered;
        self.powered = next;
        let found = Arc::clone(&self.found);
        std::thread::spawn(move || {
            if next {
                let _ = Command::new("sudo").args(["-n", "rfkill", "unblock", "bluetooth"]).status();
                let _ = Command::new("sudo").args(["-n", "systemctl", "start", "bluetooth"]).status();
                let _ = Command::new("bluetoothctl").args(["power", "on"]).status();
            } else {
                let _ = Command::new("bluetoothctl").args(["power", "off"]).status();
                let _ = Command::new("sudo").args(["-n", "rfkill", "block", "bluetooth"]).status();
            }
            if let Ok(mut g) = found.lock() {
                *g = Some(read_bt_snapshot());
            }
            redraw();
        });
    }

    fn start_scan(&mut self) {
        if self.scanning.lock().map(|b| *b).unwrap_or(false) {
            return;
        }
        if let Ok(mut b) = self.scanning.lock() {
            *b = true;
        }
        self.powered = true;
        let scanning = Arc::clone(&self.scanning);
        let found = Arc::clone(&self.found);
        std::thread::spawn(move || {
            let _ = Command::new("sudo").args(["-n", "rfkill", "unblock", "bluetooth"]).status();
            let _ = Command::new("sudo").args(["-n", "systemctl", "start", "bluetooth"]).status();
            let _ = Command::new("bluetoothctl").args(["power", "on"]).status();
            let _ = Command::new("bluetoothctl").args(["--timeout", "5", "scan", "on"]).output();
            let snap = read_bt_snapshot();
            if let Ok(mut g) = found.lock() {
                *g = Some(snap);
            }
            if let Ok(mut b) = scanning.lock() {
                *b = false;
            }
            redraw();
        });
    }

    fn act_device(&mut self, idx: usize, subcmd: &'static str) {
        let Some(dev) = self.devices.get(idx) else { return };
        let mac = dev.mac.clone();
        self.note = format!("{subcmd} {mac}..");
        let found = Arc::clone(&self.found);
        std::thread::spawn(move || {
            if subcmd == "connect" {
                let _ = Command::new("bluetoothctl").args(["trust", &mac]).output();
                let _ = Command::new("bluetoothctl").args(["pair", &mac]).output();
            }
            let _ = Command::new("bluetoothctl").args([subcmd, &mac]).output();
            if let Ok(mut g) = found.lock() {
                *g = Some(read_bt_snapshot());
            }
            redraw();
        });
    }

    fn export_report(&mut self) {
        let _ = std::fs::create_dir_all("/home/kali/captures");
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() % 100_000)
            .unwrap_or(0);
        let path = format!("/home/kali/captures/bt_devices_{ts}.txt");
        let mut body = String::from("MAC\tNAME\tRSSI\tPAIRED\tCONNECTED\tUUIDS\n");
        for d in &self.devices {
            body.push_str(&format!(
                "{}\t{}\t{}\t{}\t{}\t{}\n",
                d.mac, d.name, d.rssi, d.paired, d.connected, d.uuids
            ));
        }
        self.note = if std::fs::write(&path, body).is_ok() {
            format!("Saved bt_devices_{ts}.txt")
        } else {
            "Save failed".into()
        };
    }
}

impl App for BtArsenal {
    fn page(&self) -> Page {
        if let Some(idx) = self.detail.filter(|&i| i < self.devices.len()) {
            let d = &self.devices[idx];
            let mut rows = vec![
                heading("Device", &d.name),
                pair("MAC", &d.mac),
                pair("Signal", if d.rssi.is_empty() { "-" } else { &d.rssi }),
                pair("State", match (d.connected, d.paired) {
                    (true, _) => "Connected",
                    (false, true) => "Paired",
                    _ => "Discovered",
                }),
                pair("Service UUIDs", d.uuids.to_string()),
            ];
            if !self.note.is_empty() {
                rows.push(rule());
                rows.push(text(&self.note).dim());
            }
            return Page::detail(rows).id("bt-detail");
        }

        let busy = self.scanning.lock().map(|b| *b).unwrap_or(false);
        let state = if busy {
            "SCANNING.."
        } else if self.powered {
            "ON"
        } else {
            "OFF"
        };
        let mut items = vec![item("Adapter hci0").status(state)];
        if !self.note.is_empty() {
            items.push(item(&self.note).dim());
        }
        if self.devices.is_empty() {
            items.push(item("Press Scan (Key 5)").status("0 devs").dim());
        } else {
            for d in &self.devices {
                let tag = if d.connected {
                    "CONN".into()
                } else if d.paired {
                    "PAIRED".into()
                } else if !d.rssi.is_empty() {
                    d.rssi.clone()
                } else {
                    d.mac.get(9..).unwrap_or(&d.mac).to_string()
                };
                items.push(item(&d.name).status(tag));
            }
        }
        Page::menu(items).id("bt-list")
    }

    fn buttons(&self) -> [&str; 5] {
        if let Some(idx) = self.detail.filter(|&i| i < self.devices.len()) {
            let conn = self.devices[idx].connected;
            ["Back", if conn { "Disconn" } else { "Connect" }, "Pair", "Remove", "Refresh"]
        } else {
            let busy = self.scanning.lock().map(|b| *b).unwrap_or(false);
            [
                "Close",
                if busy { "Wait.." } else { "Scan" },
                if self.powered { "PwrOff" } else { "PwrOn" },
                "SaveLog",
                "Info",
            ]
        }
    }

    fn every(&self) -> Option<Duration> {
        Some(Duration::from_millis(800))
    }

    fn tick(&mut self, _: &mut Ui) {
        let snap = self.found.lock().ok().and_then(|mut g| g.take());
        if let Some((p, devs)) = snap {
            self.powered = p;
            self.devices = devs;
        }
    }

    fn key(&mut self, key: Key, ui: &mut Ui) -> bool {
        if let Some(idx) = self.detail {
            match key {
                Key::Escape | Key::Back => {
                    self.detail = None;
                    return true;
                }
                Key::View => {
                    let connected = self.devices.get(idx).is_some_and(|d| d.connected);
                    self.act_device(idx, if connected { "disconnect" } else { "connect" });
                    return true;
                }
                Key::Power => {
                    self.act_device(idx, "pair");
                    return true;
                }
                Key::Edit => {
                    self.act_device(idx, "remove");
                    self.detail = None;
                    return true;
                }
                Key::Run | Key::Ok => {
                    let (p, devs) = read_bt_snapshot();
                    self.powered = p;
                    self.devices = devs;
                    return true;
                }
                _ => return false,
            }
        }
        match key {
            Key::View => {
                self.start_scan();
                true
            }
            Key::Power => {
                self.toggle_power();
                true
            }
            Key::Edit => {
                self.export_report();
                true
            }
            Key::Ok | Key::Run => {
                let sel = ui.selected();
                let hdr_rows = 1 + usize::from(!self.note.is_empty());
                if sel == 0 {
                    self.toggle_power();
                } else if sel >= hdr_rows && sel - hdr_rows < self.devices.len() {
                    self.detail = Some(sel - hdr_rows);
                } else {
                    self.start_scan();
                }
                true
            }
            _ => false,
        }
    }
}

fn read_bt_snapshot() -> (bool, Vec<BtDevice>) {
    let show = Command::new("bluetoothctl")
        .arg("show")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let powered = show.lines().any(|l| l.trim() == "Powered: yes");

    let list = Command::new("bluetoothctl")
        .arg("devices")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut devs = Vec::new();
    for line in list.lines() {
        let Some(rest) = line.trim().strip_prefix("Device ") else { continue };
        let Some((mac, name)) = rest.split_once(' ') else { continue };
        let mac = mac.trim().to_string();
        let info = Command::new("bluetoothctl")
            .args(["info", &mac])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        let mut rssi = String::new();
        let mut paired = false;
        let mut connected = false;
        let mut uuids = 0usize;
        for il in info.lines().map(str::trim) {
            if il == "Paired: yes" {
                paired = true;
            } else if il == "Connected: yes" {
                connected = true;
            } else if il.starts_with("UUID:") {
                uuids += 1;
            } else if let Some(r) = il.strip_prefix("RSSI:") {
                let dbm = r.split('(').nth(1).and_then(|s| s.strip_suffix(')')).unwrap_or(r.trim());
                rssi = format!("{dbm}dBm").replace(" dBmdBm", "dBm");
            }
        }
        devs.push(BtDevice {
            mac,
            name: name.trim().to_string(),
            rssi,
            paired,
            connected,
            uuids,
        });
    }
    (powered, devs)
}

// ── Wi-Fi Survey & Channel Map (`--wifi-recon`) ────────────────────────────

#[derive(Clone, Debug, PartialEq, Eq)]
struct WifiBss {
    bssid: String,
    ssid: String,
    channel: u8,
    freq: u16,
    signal_dbm: i32,
    security: String,
}

#[derive(Copy, Clone, PartialEq, Eq)]
enum WifiView {
    Aps,
    Channels,
    Detail(usize),
}

struct WifiRecon {
    ifaces: Vec<String>,
    if_idx: usize,
    view: WifiView,
    aps: Vec<WifiBss>,
    scanning: Arc<Mutex<bool>>,
    found: Arc<Mutex<Option<Vec<WifiBss>>>>,
}

impl WifiRecon {
    fn new() -> Self {
        let mut ifaces = wireless_ifaces();
        if ifaces.is_empty() {
            ifaces.push("wlan0".into());
        }
        Self {
            ifaces,
            if_idx: 0,
            view: WifiView::Aps,
            aps: Vec::new(),
            scanning: Arc::new(Mutex::new(false)),
            found: Arc::new(Mutex::new(None)),
        }
    }

    fn iface(&self) -> &str {
        self.ifaces.get(self.if_idx).map_or("wlan0", String::as_str)
    }

    fn start_scan(&mut self) {
        if self.scanning.lock().map(|b| *b).unwrap_or(false) {
            return;
        }
        if let Ok(mut b) = self.scanning.lock() {
            *b = true;
        }
        let iface = self.iface().to_string();
        let scanning = Arc::clone(&self.scanning);
        let found = Arc::clone(&self.found);
        std::thread::spawn(move || {
            let iw = if Path::new("/usr/sbin/iw").exists() { "/usr/sbin/iw" } else { "iw" };
            let out = Command::new("sudo")
                .args(["-n", iw, "dev", &iface, "scan"])
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                .unwrap_or_default();
            let parsed = parse_iw_scan(&out);
            if let Ok(mut g) = found.lock() {
                *g = Some(parsed);
            }
            if let Ok(mut b) = scanning.lock() {
                *b = false;
            }
            redraw();
        });
    }
}

impl App for WifiRecon {
    fn page(&self) -> Page {
        match self.view {
            WifiView::Detail(idx) if idx < self.aps.len() => {
                let ap = &self.aps[idx];
                let rows = vec![
                    heading("SSID", if ap.ssid.is_empty() { "<hidden>" } else { &ap.ssid }),
                    pair("BSSID", &ap.bssid),
                    pair("Channel", format!("Ch {} ({} MHz)", ap.channel, ap.freq)),
                    pair("Signal", format!("{} dBm", ap.signal_dbm)),
                    pair("Security", &ap.security),
                ];
                Page::detail(rows).id("wifi-ap")
            }
            WifiView::Channels => {
                let mut rows = vec![heading("2.4 GHz Channels", format!("{} APs", self.aps.len()))];
                for ch in 1u8..=13 {
                    let on_ch: Vec<&WifiBss> =
                        self.aps.iter().filter(|a| a.channel == ch).collect();
                    if on_ch.is_empty() && !matches!(ch, 1 | 6 | 11) {
                        continue;
                    }
                    let best = on_ch
                        .iter()
                        .map(|a| a.signal_dbm)
                        .max()
                        .map_or_else(|| "idle".into(), |s| format!("{s}dBm"));
                    rows.push(pair(format!("Ch {ch:02}"), format!("{} APs ({best})", on_ch.len())));
                }
                Page::detail(rows).id("wifi-ch")
            }
            _ => {
                let busy = self.scanning.lock().map(|b| *b).unwrap_or(false);
                let mut items = vec![
                    item(if busy { "Scanning RF.." } else { "Wireless Interface" })
                        .status(format!("{} ({})", self.iface(), self.aps.len())),
                ];
                if self.aps.is_empty() {
                    items.push(item("Press Scan (Key 5)").status("iw scan").dim());
                } else {
                    for ap in &self.aps {
                        let title = if ap.ssid.is_empty() {
                            format!("<hidden {}>", ap.bssid.get(9..).unwrap_or(&ap.bssid))
                        } else {
                            ap.ssid.clone()
                        };
                        items.push(
                            item(title).status(format!("C{:02} {}dB", ap.channel, ap.signal_dbm)),
                        );
                    }
                }
                Page::menu(items).id("wifi-list")
            }
        }
    }

    fn buttons(&self) -> [&str; 5] {
        match self.view {
            WifiView::Detail(_) => ["Back", "Rescan", "ChMap", "", ""],
            WifiView::Channels => ["Back", "Rescan", "APList", "Iface", ""],
            WifiView::Aps => ["Close", "Scan", "ChMap", "Iface", "Detail"],
        }
    }

    fn every(&self) -> Option<Duration> {
        Some(Duration::from_millis(700))
    }

    fn tick(&mut self, _: &mut Ui) {
        let taken = self.found.lock().ok().and_then(|mut g| g.take());
        if let Some(aps) = taken {
            self.aps = aps;
        }
    }

    fn key(&mut self, key: Key, ui: &mut Ui) -> bool {
        match key {
            Key::Escape | Key::Back if self.view != WifiView::Aps => {
                self.view = WifiView::Aps;
                true
            }
            Key::View => {
                self.start_scan();
                true
            }
            Key::Power => {
                self.view = match self.view {
                    WifiView::Channels => WifiView::Aps,
                    _ => WifiView::Channels,
                };
                true
            }
            Key::Edit => {
                self.ifaces = wireless_ifaces();
                if self.ifaces.is_empty() {
                    self.ifaces.push("wlan0".into());
                }
                self.if_idx = (self.if_idx + 1) % self.ifaces.len();
                true
            }
            Key::Ok | Key::Run if self.view == WifiView::Aps => {
                let sel = ui.selected();
                if sel == 0 {
                    self.start_scan();
                } else if sel - 1 < self.aps.len() {
                    self.view = WifiView::Detail(sel - 1);
                }
                true
            }
            _ => false,
        }
    }
}

fn wireless_ifaces() -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/sys/class/net") {
        for e in rd.flatten() {
            if e.path().join("wireless").exists() || e.path().join("phy80211").exists() {
                if let Ok(n) = e.file_name().into_string() {
                    out.push(n);
                }
            }
        }
    }
    out.sort();
    out
}

fn freq_to_channel(freq: u16) -> u8 {
    match freq {
        2484 => 14,
        2412..=2472 => ((freq - 2407) / 5) as u8,
        5180..=5885 => ((freq - 5000) / 5) as u8,
        _ => 0,
    }
}

fn parse_iw_scan(text: &str) -> Vec<WifiBss> {
    let mut out: Vec<WifiBss> = Vec::new();
    let mut cur: Option<WifiBss> = None;
    let mut has_rsn = false;
    let mut has_wpa = false;
    let mut has_sae = false;
    let mut has_wps = false;
    let mut has_priv = false;

    let flush = |cur: &mut Option<WifiBss>,
                 out: &mut Vec<WifiBss>,
                 rsn: bool,
                 wpa: bool,
                 sae: bool,
                 wps: bool,
                 prv: bool| {
        if let Some(mut bss) = cur.take() {
            if bss.channel == 0 && bss.freq != 0 {
                bss.channel = freq_to_channel(bss.freq);
            }
            let mut sec = if sae {
                "WPA3".to_string()
            } else if rsn {
                "WPA2".to_string()
            } else if wpa {
                "WPA".to_string()
            } else if prv {
                "WEP".to_string()
            } else {
                "OPEN".to_string()
            };
            if wps {
                sec.push_str("+WPS");
            }
            bss.security = sec;
            out.push(bss);
        }
    };

    for raw in text.lines() {
        if let Some(rest) = raw.strip_prefix("BSS ") {
            flush(&mut cur, &mut out, has_rsn, has_wpa, has_sae, has_wps, has_priv);
            has_rsn = false;
            has_wpa = false;
            has_sae = false;
            has_wps = false;
            has_priv = false;
            let bssid = rest
                .split(['(', ' '])
                .next()
                .unwrap_or_default()
                .trim()
                .to_uppercase();
            if !bssid.is_empty() {
                cur = Some(WifiBss {
                    bssid,
                    ssid: String::new(),
                    channel: 0,
                    freq: 0,
                    signal_dbm: -100,
                    security: String::new(),
                });
            }
            continue;
        }
        let Some(bss) = cur.as_mut() else { continue };
        let t = raw.trim();
        if let Some(f) = t.strip_prefix("freq:") {
            bss.freq = f.trim().split('.').next().and_then(|s| s.parse().ok()).unwrap_or(0);
        } else if let Some(s) = t.strip_prefix("signal:") {
            bss.signal_dbm = s
                .split_whitespace()
                .next()
                .and_then(|v| v.parse::<f32>().ok())
                .map(|v| v.round() as i32)
                .unwrap_or(-100);
        } else if let Some(ssid) = t.strip_prefix("SSID:") {
            bss.ssid = ssid.trim().to_string();
        } else if let Some(ch) = t.strip_prefix("DS Parameter set: channel") {
            bss.channel = ch.trim().parse().unwrap_or(bss.channel);
        } else if t.starts_with("capability:") && t.contains("Privacy") {
            has_priv = true;
        } else if t.starts_with("RSN:") {
            has_rsn = true;
        } else if t.starts_with("WPA:") {
            has_wpa = true;
        } else if t.contains("SAE") {
            has_sae = true;
        } else if t.starts_with("WPS:") {
            has_wps = true;
        }
    }
    flush(&mut cur, &mut out, has_rsn, has_wpa, has_sae, has_wps, has_priv);
    out.sort_by(|a, b| b.signal_dbm.cmp(&a.signal_dbm));
    out
}

// ── LIRC Infrared Remote & Learner (`--ir-deck`) ───────────────────────────

#[derive(Clone, Debug, PartialEq, Eq)]
struct IrSignal {
    name: String,
    carrier_hz: u32,
    duty_cycle: u32,
    pulses: Vec<u32>,
    label: String,
}

struct IrArsenal {
    files: Vec<PathBuf>,
    file_idx: usize,
    signals: Vec<IrSignal>,
    status_msg: Arc<Mutex<String>>,
    busy: Arc<Mutex<bool>>,
    reload: Arc<Mutex<bool>>,
    tx_dev: Option<String>,
    rx_dev: Option<String>,
}

impl IrArsenal {
    fn new() -> Self {
        let (tx_dev, rx_dev) = discover_lirc_nodes();
        let mut app = Self {
            files: Vec::new(),
            file_idx: 0,
            signals: Vec::new(),
            status_msg: Arc::new(Mutex::new(String::new())),
            busy: Arc::new(Mutex::new(false)),
            reload: Arc::new(Mutex::new(false)),
            tx_dev,
            rx_dev,
        };
        app.rescan();
        app
    }

    fn rescan(&mut self) {
        self.files = scan_files(&["/home/kali/ir", "/usr/share/czctl/payloads", "/usr/share/flipctl/payloads"], &["ir"]);
        if self.file_idx >= self.files.len() {
            self.file_idx = 0;
        }
        self.signals = self
            .files
            .get(self.file_idx)
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|s| parse_flipper_ir(&s))
            .unwrap_or_default();
    }

    fn send_signal(&mut self, idx: usize) {
        if self.busy.lock().map(|b| *b).unwrap_or(false) {
            return;
        }
        let Some(sig) = self.signals.get(idx).cloned() else { return };
        let Some(tx_path) = self.tx_dev.clone() else {
            if let Ok(mut m) = self.status_msg.lock() {
                *m = "No IR TX node (/dev/lirc0)".into();
            }
            return;
        };
        if let Ok(mut b) = self.busy.lock() {
            *b = true;
        }
        let busy = Arc::clone(&self.busy);
        let msg = Arc::clone(&self.status_msg);
        std::thread::spawn(move || {
            let res = lirc_transmit(&tx_path, sig.carrier_hz, sig.duty_cycle, &sig.pulses);
            if let Ok(mut m) = msg.lock() {
                *m = match res {
                    Ok(()) => format!("TX OK: {} ({}kHz)", sig.name, sig.carrier_hz / 1000),
                    Err(e) => format!("TX err: {e}"),
                };
            }
            if let Ok(mut b) = busy.lock() {
                *b = false;
            }
            redraw();
        });
    }

    fn learn_raw(&mut self) {
        if self.busy.lock().map(|b| *b).unwrap_or(false) {
            return;
        }
        let Some(rx_path) = self.rx_dev.clone() else {
            if let Ok(mut m) = self.status_msg.lock() {
                *m = "No IR RX node (/dev/lirc1)".into();
            }
            return;
        };
        if let Ok(mut b) = self.busy.lock() {
            *b = true;
        }
        if let Ok(mut m) = self.status_msg.lock() {
            *m = "Point remote at IR RX (6s)..".into();
        }
        let busy = Arc::clone(&self.busy);
        let msg = Arc::clone(&self.status_msg);
        let reload = Arc::clone(&self.reload);
        std::thread::spawn(move || {
            match lirc_capture_raw(&rx_path, Duration::from_secs(6)) {
                Ok(pulses) => {
                    let _ = std::fs::create_dir_all("/home/kali/ir");
                    let ts = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() % 100_000)
                        .unwrap_or(0);
                    let name = format!("Learned_{ts}");
                    let data: Vec<String> = pulses.iter().map(u32::to_string).collect();
                    let block = format!(
                        "#\nname: {name}\ntype: raw\nfrequency: 38000\nduty_cycle: 0.330000\ndata: {}\n",
                        data.join(" ")
                    );
                    let out_path = PathBuf::from("/home/kali/ir/learned.ir");
                    let hdr = "Filetype: IR signals file\nVersion: 1\n";
                    // Prepend newest learned signal so Row 1 (`signals[0]`) is always the latest capture!
                    let saved = if out_path.exists() {
                        let prev = std::fs::read_to_string(&out_path).unwrap_or_default();
                        let body = prev
                            .strip_prefix(hdr)
                            .unwrap_or(&prev)
                            .trim_start_matches('\n');
                        std::fs::write(&out_path, format!("{hdr}{block}{body}"))
                    } else {
                        std::fs::write(&out_path, format!("{hdr}{block}"))
                    };
                    if let Ok(mut m) = msg.lock() {
                        *m = if saved.is_ok() {
                            format!("Saved {name}")
                        } else {
                            "Save err ~/ir".into()
                        };
                    }
                    if let Ok(mut r) = reload.lock() {
                        *r = true;
                    }
                }
                Err(e) => {
                    if let Ok(mut m) = msg.lock() {
                        *m = e;
                    }
                }
            }
            if let Ok(mut b) = busy.lock() {
                *b = false;
            }
            redraw();
        });
    }
}

impl App for IrArsenal {
    fn page(&self) -> Page {
        let cur_file = self
            .files
            .get(self.file_idx)
            .map(|p| file_label(p))
            .unwrap_or_else(|| "no .ir files".into());
        let hw = match (&self.tx_dev, &self.rx_dev) {
            (Some(_), Some(_)) => "TX+RX OK",
            (Some(_), None) => "TX ONLY",
            (None, Some(_)) => "RX ONLY",
            (None, None) => "NO LIRC",
        };
        let note = self.status_msg.lock().map(|m| m.clone()).unwrap_or_default();
        // Keep header strictly 1 row (`Row 0`) so signal indices (`Row 1..N`) NEVER shift
        // when `status_msg` updates after `Learn` or `Send`!
        let top_status = if note.is_empty() { hw.to_string() } else { note };
        let mut items = vec![item(format!("File: {cur_file}")).status(top_status)];
        if self.signals.is_empty() {
            items.push(item("Press Learn (Key 5) to capture").dim());
        } else {
            for sig in &self.signals {
                items.push(item(&sig.name).status(&sig.label));
            }
        }
        Page::menu(items).id("ir-menu")
    }

    fn buttons(&self) -> [&str; 5] {
        let busy = self.busy.lock().map(|b| *b).unwrap_or(false);
        if busy {
            ["Close", "Wait..", "", "", ""]
        } else {
            ["Close", "Learn", "Next.ir", "Reload", "Send"]
        }
    }

    fn every(&self) -> Option<Duration> {
        Some(Duration::from_millis(600))
    }

    fn tick(&mut self, _: &mut Ui) {
        let need = self.reload.lock().map(|mut r| std::mem::replace(&mut *r, false)).unwrap_or(false);
        if need {
            self.rescan();
            if let Some(pos) = self.files.iter().position(|p| file_label(p) == "learned.ir") {
                self.file_idx = pos;
                self.rescan();
            }
        }
    }

    fn key(&mut self, key: Key, ui: &mut Ui) -> bool {
        match key {
            Key::View => {
                self.learn_raw();
                true
            }
            Key::Power => {
                if !self.files.is_empty() {
                    self.file_idx = (self.file_idx + 1) % self.files.len();
                    if let Ok(mut m) = self.status_msg.lock() {
                        m.clear();
                    }
                    self.rescan();
                }
                true
            }
            Key::Edit => {
                if let Ok(mut m) = self.status_msg.lock() {
                    m.clear();
                }
                self.rescan();
                true
            }
            Key::Run => {
                let sel = ui.selected();
                if sel >= 1 && sel - 1 < self.signals.len() {
                    self.send_signal(sel - 1);
                } else if !self.signals.is_empty() {
                    // Pressing `Send` (Key 8) while on Row 0 transmits the first signal
                    // immediately instead of unexpectedly switching `.ir` files!
                    self.send_signal(0);
                }
                true
            }
            Key::Ok => {
                let sel = ui.selected();
                if sel == 0 && !self.files.is_empty() {
                    self.file_idx = (self.file_idx + 1) % self.files.len();
                    if let Ok(mut m) = self.status_msg.lock() {
                        m.clear();
                    }
                    self.rescan();
                } else if sel >= 1 && sel - 1 < self.signals.len() {
                    self.send_signal(sel - 1);
                }
                true
            }
            _ => false,
        }
    }
}

fn lirc_query_features(path: &str) -> Option<u32> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    const LIRC_GET_FEATURES: libc::c_ulong = 0x8004_6900;
    for (rd, wr) in [(true, true), (true, false), (false, true)] {
        let Ok(file) = std::fs::OpenOptions::new()
            .read(rd)
            .write(wr)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)
        else {
            continue;
        };
        let mut feat: u32 = 0;
        let rc = unsafe { libc::ioctl(file.as_raw_fd(), LIRC_GET_FEATURES as _, &mut feat as *mut u32) };
        if rc == 0 {
            return Some(feat);
        }
    }
    None
}

fn discover_lirc_nodes() -> (Option<String>, Option<String>) {
    const LIRC_CAN_SEND_PULSE: u32 = 0x0000_0002;
    const LIRC_CAN_REC_MODE2: u32 = 0x0004_0000;

    let mut tx = None;
    let mut rx = None;
    for idx in 0..8 {
        let node = format!("/dev/lirc{idx}");
        if !Path::new(&node).exists() {
            continue;
        }
        if let Some(feat) = lirc_query_features(&node) {
            if tx.is_none() && (feat & LIRC_CAN_SEND_PULSE) != 0 {
                tx = Some(node.clone());
            }
            if rx.is_none() && (feat & LIRC_CAN_REC_MODE2) != 0 {
                rx = Some(node.clone());
            }
            continue;
        }
        let uevent = format!("/sys/class/lirc/lirc{idx}/device/uevent");
        let text = std::fs::read_to_string(&uevent)
            .or_else(|_| std::fs::read_to_string(format!("/sys/class/rc/rc{idx}/lirc{idx}/device/uevent")))
            .unwrap_or_default();
        if text.contains("gpio-ir-tx") || text.contains("ir-tx") {
            tx = Some(node);
        } else if text.contains("gpio_ir_recv") || text.contains("ir_recv") {
            rx = Some(node);
        }
    }
    (tx, rx)
}

fn lirc_transmit(dev: &str, carrier_hz: u32, duty: u32, pulses: &[u32]) -> Result<(), String> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    const LIRC_GET_FEATURES: libc::c_ulong = 0x8004_6900;
    const LIRC_MODE_PULSE: u32 = 0x0000_0002;
    const LIRC_CAN_SET_SEND_CARRIER: u32 = 0x0000_0100;
    const LIRC_CAN_SET_SEND_DUTY_CYCLE: u32 = 0x0000_0200;
    const LIRC_SET_SEND_MODE: libc::c_ulong = 0x4004_6911;
    const LIRC_SET_SEND_CARRIER: libc::c_ulong = 0x4004_6913;
    const LIRC_SET_SEND_DUTY_CYCLE: libc::c_ulong = 0x4004_6915;
    const LIRC_VAL_MASK: u32 = 0x00ff_ffff;

    if pulses.is_empty() {
        return Err("empty pulse train".into());
    }
    // Sanitize and clamp durations to LIRC's 24-bit microsecond limit (`0x00ff_ffff`),
    // ensuring an odd sample count (starts & ends with a pulse).
    let mut clean: Vec<u32> = pulses
        .iter()
        .copied()
        .map(|d| d.clamp(1, LIRC_VAL_MASK))
        .collect();
    if clean.len() % 2 == 0 {
        clean.pop();
    }
    if clean.is_empty() {
        return Err("short pulse train".into());
    }

    let file = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_CLOEXEC)
        .open(dev)
        .map_err(|e| format!("{dev}: {e}"))?;
    let fd = file.as_raw_fd();
    let mut features: u32 = 0;
    unsafe {
        let _ = libc::ioctl(fd, LIRC_GET_FEATURES as _, &mut features as *mut u32);
    }
    let mode = LIRC_MODE_PULSE;
    let freq = carrier_hz.clamp(20_000, 60_000);
    let duty = duty.clamp(10, 90);
    unsafe {
        if libc::ioctl(fd, LIRC_SET_SEND_MODE as _, &mode as *const u32) < 0 {
            return Err(format!("SEND_MODE: {}", std::io::Error::last_os_error()));
        }
        if features == 0 || (features & LIRC_CAN_SET_SEND_CARRIER) != 0 {
            let _ = libc::ioctl(fd, LIRC_SET_SEND_CARRIER as _, &freq as *const u32);
        }
        if features == 0 || (features & LIRC_CAN_SET_SEND_DUTY_CYCLE) != 0 {
            let _ = libc::ioctl(fd, LIRC_SET_SEND_DUTY_CYCLE as _, &duty as *const u32);
        }
    }
    let byte_len = clean.len() * std::mem::size_of::<u32>();
    let written = unsafe { libc::write(fd, clean.as_ptr().cast(), byte_len) };
    if written < 0 {
        return Err(format!("write: {}", std::io::Error::last_os_error()));
    }
    if written as usize != byte_len {
        return Err(format!("short write {written}/{byte_len}"));
    }
    Ok(())
}

fn lirc_capture_raw(dev: &str, timeout: Duration) -> Result<Vec<u32>, String> {
    use std::io::Read;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    const LIRC_MODE_MODE2: u32 = 0x0000_0004;
    const LIRC_SET_REC_MODE: libc::c_ulong = 0x4004_6912;
    const LIRC_VAL_MASK: u32 = 0x00ff_ffff;
    const LIRC_MODE2_MASK: u32 = 0xff00_0000;
    const LIRC_MODE2_PULSE: u32 = 0x0100_0000;
    const LIRC_MODE2_SPACE: u32 = 0x0000_0000;
    const LIRC_MODE2_TIMEOUT: u32 = 0x0300_0000;

    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(dev)
        .map_err(|e| format!("{dev}: {e}"))?;
    let fd = file.as_raw_fd();
    let mode = LIRC_MODE_MODE2;
    unsafe {
        let _ = libc::ioctl(fd, LIRC_SET_REC_MODE as _, &mode as *const u32);
    }
    // Drain stale RX edges first.
    let mut drain = [0u8; 256]; // not-a-panel-dimension
    while file.read(&mut drain).unwrap_or(0) > 0 {}

    let deadline = std::time::Instant::now() + timeout;
    let mut pulses: Vec<u32> = Vec::new();
    let mut raw_buf = [0u8; 256]; // not-a-panel-dimension

    while std::time::Instant::now() < deadline {
        let wait_ms = if pulses.is_empty() { 200 } else { 80 };
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let rc = unsafe { libc::poll(&mut pfd, 1, wait_ms) };
        if rc == 0 {
            if !pulses.is_empty() {
                break;
            }
            continue;
        }
        if rc < 0 {
            break;
        }
        let Ok(n) = file.read(&mut raw_buf) else { break };
        if n < 4 {
            continue;
        }
        let mut saw_gap = false;
        for chunk in raw_buf[..n - (n % 4)].chunks_exact(4) {
            let sample = u32::from_ne_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            let kind = sample & LIRC_MODE2_MASK;
            let dur = sample & LIRC_VAL_MASK;
            if dur == 0 {
                continue;
            }
            match kind {
                LIRC_MODE2_PULSE => {
                    if pulses.len() % 2 == 0 {
                        pulses.push(dur);
                    } else if let Some(last) = pulses.last_mut() {
                        // Consecutive pulse -> merge
                        *last = last.saturating_add(dur);
                    }
                }
                LIRC_MODE2_SPACE | LIRC_MODE2_TIMEOUT => {
                    if pulses.is_empty() {
                        continue;
                    }
                    if dur >= 60_000 {
                        saw_gap = true;
                        break;
                    }
                    if pulses.len() % 2 == 1 {
                        pulses.push(dur);
                    } else if let Some(last) = pulses.last_mut() {
                        *last = last.saturating_add(dur);
                    }
                }
                _ => {}
            }
        }
        if saw_gap || pulses.len() >= 512 {
            break;
        }
    }

    if pulses.len() % 2 == 0 {
        pulses.pop();
    }
    if pulses.len() < 5 {
        return Err("No IR signal detected".into());
    }
    Ok(pulses)
}

fn parse_hex_bytes4(s: &str) -> [u8; 4] {
    let mut out = [0u8; 4];
    for (i, tok) in s.split_whitespace().take(4).enumerate() {
        out[i] = u8::from_str_radix(tok, 16).unwrap_or(0);
    }
    out
}

fn encode_nec_bits(word: u32, hdr_pulse: u32, hdr_space: u32) -> Vec<u32> {
    let mut v = Vec::with_capacity(67);
    v.push(hdr_pulse);
    v.push(hdr_space);
    for bit in 0..32 {
        v.push(560);
        if ((word >> bit) & 1) != 0 {
            v.push(1690);
        } else {
            v.push(560);
        }
    }
    v.push(560);
    v
}

fn parse_flipper_ir(text: &str) -> Vec<IrSignal> {
    let mut out = Vec::new();
    for block in text.split("\n#") {
        let mut name = String::new();
        let mut kind = String::new();
        let mut proto = String::new();
        let mut addr = [0u8; 4];
        let mut cmd = [0u8; 4];
        let mut freq: u32 = 38_000;
        let mut duty: u32 = 33;
        let mut raw_data: Vec<u32> = Vec::new();

        for line in block.lines().map(str::trim) {
            if let Some(v) = line.strip_prefix("name:") {
                name = v.trim().to_string();
            } else if let Some(v) = line.strip_prefix("type:") {
                kind = v.trim().to_ascii_lowercase();
            } else if let Some(v) = line.strip_prefix("protocol:") {
                proto = v.trim().to_string();
            } else if let Some(v) = line.strip_prefix("address:") {
                addr = parse_hex_bytes4(v);
            } else if let Some(v) = line.strip_prefix("command:") {
                cmd = parse_hex_bytes4(v);
            } else if let Some(v) = line.strip_prefix("frequency:") {
                freq = v.trim().parse().unwrap_or(38_000);
            } else if let Some(v) = line.strip_prefix("duty_cycle:") {
                if let Ok(f) = v.trim().parse::<f32>() {
                    duty = if f <= 1.0 { (f * 100.0).round() as u32 } else { f.round() as u32 };
                }
            } else if let Some(v) = line.strip_prefix("data:") {
                raw_data = v.split_whitespace().filter_map(|t| t.parse::<u32>().ok()).collect();
            }
        }

        if name.is_empty() {
            continue;
        }
        if kind == "raw" && !raw_data.is_empty() {
            if raw_data.len() % 2 == 0 {
                raw_data.pop();
            }
            if !raw_data.is_empty() {
                out.push(IrSignal {
                    name,
                    carrier_hz: freq,
                    duty_cycle: duty,
                    label: format!("RAW {}k", freq / 1000),
                    pulses: raw_data,
                });
            }
        } else if kind == "parsed" {
            let p_low = proto.to_ascii_lowercase();
            if p_low == "nec" {
                let word = u32::from(addr[0])
                    | (u32::from(!addr[0]) << 8)
                    | (u32::from(cmd[0]) << 16)
                    | (u32::from(!cmd[0]) << 24);
                out.push(IrSignal {
                    name,
                    carrier_hz: 38_000,
                    duty_cycle: 33,
                    label: "NEC".into(),
                    pulses: encode_nec_bits(word, 9000, 4500),
                });
            } else if p_low == "necext" {
                let word = u32::from(addr[0])
                    | (u32::from(addr[1]) << 8)
                    | (u32::from(cmd[0]) << 16)
                    | (u32::from(cmd[1]) << 24);
                out.push(IrSignal {
                    name,
                    carrier_hz: 38_000,
                    duty_cycle: 33,
                    label: "NECext".into(),
                    pulses: encode_nec_bits(word, 9000, 4500),
                });
            } else if p_low == "samsung32" {
                let word = u32::from(addr[0])
                    | (u32::from(addr[0]) << 8)
                    | (u32::from(cmd[0]) << 16)
                    | (u32::from(!cmd[0]) << 24);
                out.push(IrSignal {
                    name,
                    carrier_hz: 38_000,
                    duty_cycle: 33,
                    label: "Samsung".into(),
                    pulses: encode_nec_bits(word, 4500, 4500),
                });
            } else if p_low == "sirc" || p_low == "sirc15" || p_low == "sirc20" {
                let (nbits, word): (u32, u32) = if p_low == "sirc20" {
                    let w = u32::from(cmd[0] & 0x7f)
                        | (u32::from(addr[0] & 0x1f) << 7)
                        | (u32::from(addr[1]) << 12);
                    (20, w)
                } else if p_low == "sirc15" {
                    let w = u32::from(cmd[0] & 0x7f) | (u32::from(addr[0]) << 7);
                    (15, w)
                } else {
                    let w = u32::from(cmd[0] & 0x7f) | (u32::from(addr[0] & 0x1f) << 7);
                    (12, w)
                };
                // Sony SIRC receivers require 3 consecutive frames separated by ~25 ms space.
                let mut frame = Vec::with_capacity((nbits as usize) * 2 + 1);
                frame.push(2400);
                for bit in 0..nbits {
                    frame.push(600);
                    frame.push(if ((word >> bit) & 1) != 0 { 1200 } else { 600 });
                }
                let mut pulses = Vec::with_capacity(frame.len() * 3 + 2);
                for rep in 0..3 {
                    if rep > 0 {
                        pulses.push(25_000);
                    }
                    pulses.extend_from_slice(&frame);
                }
                out.push(IrSignal {
                    name,
                    carrier_hz: 40_000,
                    duty_cycle: 33,
                    label: "SIRC".into(),
                    pulses,
                });
            }
        }
    }
    out
}

flipctl_app::main!(DynApp(main_entry()));

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_usb_arsenal_and_net_matrix_320x170() {
        let usb_frame = flipctl_pages::shot(UsbArsenal::new(), flipctl_app::Status::default());
        assert_eq!(usb_frame.len(), 320 * 170 * 3);

        let net_frame = flipctl_pages::shot(NetMatrix::new(), flipctl_app::Status::default());
        assert_eq!(net_frame.len(), 320 * 170 * 3);

        let lan_frame = flipctl_pages::shot(LanRecon::new(), flipctl_app::Status::default());
        assert_eq!(lan_frame.len(), 320 * 170 * 3);

        let pkt_frame = flipctl_pages::shot(PktCapture::new(), flipctl_app::Status::default());
        assert_eq!(pkt_frame.len(), 320 * 170 * 3);

        let bt_frame = flipctl_pages::shot(BtArsenal::new(), flipctl_app::Status::default());
        assert_eq!(bt_frame.len(), 320 * 170 * 3);

        let wifi_frame = flipctl_pages::shot(WifiRecon::new(), flipctl_app::Status::default());
        assert_eq!(wifi_frame.len(), 320 * 170 * 3);

        let ir_frame = flipctl_pages::shot(IrArsenal::new(), flipctl_app::Status::default());
        assert_eq!(ir_frame.len(), 320 * 170 * 3);

        let sample_ir = include_str!("../../../../overlays/payloads/tv-universal.ir");
        let ir_sigs = parse_flipper_ir(sample_ir);
        assert!(ir_sigs.len() >= 6);
        for sig in &ir_sigs {
            assert_eq!(sig.pulses.len() % 2, 1, "LIRC TX requires odd pulse count");
        }

        let iw_sample = "\
BSS aa:bb:cc:dd:ee:01(on wlan0)\n\
\tfreq: 2437\n\
\tsignal: -48.00 dBm\n\
\tcapability: ESS Privacy ShortSlotTime\n\
\tSSID: LabNet\n\
\tRSN:\t * Version: 1\n";
        let bss = parse_iw_scan(iw_sample);
        assert_eq!(bss.len(), 1);
        assert_eq!(bss[0].channel, 6);
        assert_eq!(bss[0].security, "WPA2");

        if let Some(dir) = std::env::var_os("CZ_SHOT_DIR") {
            let dir = PathBuf::from(dir);
            for (slug, name) in [
                ("kali-dark", "kali_flipper_usb_arsenal.png"),
                ("og-flipper", "og_flipper_usb_arsenal.png"),
                ("flipper-mono", "flipper_mono_usb_arsenal.png"),
            ] {
                std::env::set_var("FLIPCTL_THEME", slug);
                let frame = flipctl_pages::shot(UsbArsenal::new(), flipctl_app::Status::default());
                flipctl_app::render::save(&dir.join(name), &frame);
            }
            std::env::set_var("FLIPCTL_THEME", "kali-dark");
            let usb_dark = flipctl_pages::shot(UsbArsenal::new(), flipctl_app::Status::default());
            let net_dark = flipctl_pages::shot(NetMatrix::new(), flipctl_app::Status::default());
            flipctl_app::render::save(&dir.join("cz_kali_usb_arsenal.png"), &usb_dark);
            flipctl_app::render::save(&dir.join("cz_kali_net_matrix.png"), &net_dark);
            std::env::remove_var("FLIPCTL_THEME");
        }
    }
}
