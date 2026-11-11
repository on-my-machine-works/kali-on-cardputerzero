#!/usr/bin/env python3
"""
configure-kali-launcher.py — Configure CardputerZero APPLaunch for Kali Linux:
  1. Generate 100x100 RGB PNG icons for all 9 Kali launcher entries.
  2. Write .desktop entries in /usr/share/APPLaunch/applications with deterministic
     mtimes for consistent home carousel ordering:
       [0] WiFiScan  [1] Term80x24  [[2] KaliZsh]  [3] KaliMenu  [4] SysMon
       [5] LanScan   [6] PktSniff   [7] USBGadget  [8] KaliPkgs  -> M5 apps.
  3. Populate /usr/share/APPLaunch/preinstalled-desktop-apps.tsv and verify 1:1
     identity parity so every item appears in Settings -> Launcher toggles.
  4. Seed /home/kali/.config/cardputerzero/config.json (and /etc/skel) with all
     configurable app_* and app_desktop_* keys.
  5. Patch M5CardputerZero-APPLaunch's launcher_sort_app_display_order comparator
     so custom preinstalled entries sort ahead of built-in M5 entries.
"""

import json
import os
import shutil
import stat
import struct
import sys
import zlib
from pathlib import Path

# Ordered so index 2 (APPLaunch's initial current_app = 2) is KaliZsh,
# surrounded by WiFiScan, Term80x24, KaliMenu, and SysMon across all 5 boot slots!
KALI_APPS = [
    {
        "filename": "kali-wifi.desktop",
        "name": "WiFiScan",
        "icon_file": "kali_wifi_100.png",
        "exec": "/usr/local/bin/cz-wifiscan",
        "terminal": False,
        "sysplause": True,
        "bg": (10, 24, 44),
        "fg": (48, 206, 255),
        "accent": (38, 224, 148),
        "glyph": [0x3C, 0x42, 0x99, 0xA5, 0x24, 0x18, 0x00, 0x18],
        "tag": "WIFI",
    },
    {
        "filename": "kali-term80.desktop",
        "name": "Term80x24",
        "icon_file": "kali_term80_100.png",
        "exec": "/usr/local/bin/cz-term80",
        "terminal": False,
        "sysplause": True,
        "bg": (10, 26, 26),
        "fg": (52, 232, 172),
        "accent": (96, 184, 255),
        "glyph": [0xFF, 0x81, 0xBD, 0xA5, 0xBD, 0x81, 0xFF, 0x00],
        "tag": "80x24",
    },
    {
        "filename": "kali-zsh.desktop",
        "name": "KaliZsh",
        "icon_file": "kali_zsh_100.png",
        "exec": "/usr/bin/zsh -l",
        "terminal": True,
        "sysplause": False,
        "bg": (14, 20, 32),
        "fg": (42, 236, 138),
        "accent": (54, 132, 255),
        "glyph": [0xC0, 0x60, 0x30, 0x60, 0xC0, 0x00, 0x1F, 0x1F],
        "tag": "ZSH",
    },
    {
        "filename": "kali-menu.desktop",
        "name": "KaliMenu",
        "icon_file": "kali_menu_100.png",
        "exec": "/usr/local/bin/cz-kali-menu",
        "terminal": True,
        "sysplause": False,
        "bg": (12, 22, 46),
        "fg": (64, 142, 255),
        "accent": (120, 212, 255),
        "glyph": [0x63, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0x63],
        "tag": "KALI",
    },
    {
        "filename": "kali-btop.desktop",
        "name": "SysMon",
        "icon_file": "kali_btop_100.png",
        "exec": "/usr/local/bin/cz-sysmon",
        "terminal": False,
        "sysplause": True,
        "bg": (24, 16, 40),
        "fg": (192, 102, 255),
        "accent": (64, 212, 255),
        "glyph": [0x08, 0x08, 0x2A, 0x2A, 0x6B, 0x6B, 0xFF, 0x00],
        "tag": "MON",
    },
    {
        "filename": "kali-lanscan.desktop",
        "name": "LanScan",
        "icon_file": "kali_lanscan_100.png",
        "exec": "/usr/local/bin/cz-lanscan",
        "terminal": False,
        "sysplause": True,
        "bg": (28, 22, 12),
        "fg": (255, 194, 52),
        "accent": (72, 224, 152),
        "glyph": [0x18, 0x18, 0x7E, 0xDB, 0xDB, 0x7E, 0x18, 0x18],
        "tag": "LAN",
    },
    {
        "filename": "kali-pktsniff.desktop",
        "name": "PktSniff",
        "icon_file": "kali_pktsniff_100.png",
        "exec": "/usr/local/bin/cz-pktsniff",
        "terminal": False,
        "sysplause": True,
        "bg": (32, 14, 22),
        "fg": (255, 98, 112),
        "accent": (255, 202, 72),
        "glyph": [0xF0, 0x90, 0xF7, 0x09, 0xEF, 0x80, 0xFF, 0x00],
        "tag": "PCAP",
    },
    {
        "filename": "kali-usbgadget.desktop",
        "name": "USBGadget",
        "icon_file": "kali_usbgadget_100.png",
        "exec": "/usr/local/bin/cz-usbgadget",
        "terminal": False,
        "sysplause": True,
        "bg": (12, 26, 38),
        "fg": (76, 184, 255),
        "accent": (255, 255, 255),
        "glyph": [0x18, 0x3C, 0x18, 0x5A, 0x7E, 0x18, 0x3C, 0x3C],
        "tag": "OTG",
    },
    {
        "filename": "kali-pkgs.desktop",
        "name": "KaliPkgs",
        "icon_file": "kali_pkgs_100.png",
        "exec": "/usr/local/bin/cz-kali-pkgs",
        "terminal": True,
        "sysplause": False,
        "bg": (14, 28, 22),
        "fg": (66, 232, 148),
        "accent": (255, 206, 72),
        "glyph": [0x7E, 0xDB, 0xFF, 0x99, 0x99, 0x81, 0x81, 0xFF],
        "tag": "PKGS",
    },
]

# Tiny 3x5 uppercase/digit font for bottom badge inside 100x100 icons
TINY3X5 = {
    "0": [7, 5, 5, 5, 7], "2": [7, 1, 7, 4, 7], "4": [5, 5, 7, 1, 1],
    "8": [7, 5, 7, 5, 7], "x": [0, 5, 2, 5, 0],
    "A": [2, 5, 7, 5, 5], "C": [3, 4, 4, 4, 3], "F": [7, 4, 6, 4, 4],
    "G": [3, 4, 5, 5, 3], "H": [5, 5, 7, 5, 5], "I": [7, 2, 2, 2, 7],
    "K": [5, 5, 6, 5, 5], "L": [4, 4, 4, 4, 7], "M": [5, 7, 5, 5, 5],
    "N": [5, 7, 7, 5, 5], "O": [2, 5, 5, 5, 2], "P": [6, 5, 6, 4, 4],
    "S": [3, 4, 2, 1, 6], "T": [7, 2, 2, 2, 2], "W": [5, 5, 7, 7, 5],
    "Z": [7, 1, 2, 4, 7],
}


def desktop_config_key(filename: str) -> str:
    """Exact match to APPLaunch's desktop_config_key() in desktop_app_loader.cpp."""
    raw = filename.encode("utf-8")
    sanitized = []
    for b in raw:
        if (48 <= b <= 57) or (65 <= b <= 90) or (97 <= b <= 122):
            sanitized.append(chr(b))
        else:
            sanitized.append("_")
    h = 2166136261
    for b in raw:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return f"app_desktop_{''.join(sanitized)}_{h:08x}"


def write_icon_png(out_path: Path, bg, fg, accent, glyph, tag: str) -> None:
    w, h = 100, 100
    buf = [[bg for _ in range(w)] for _ in range(h)]

    for y in range(h):
        for x in range(w):
            dx = min(x, w - 1 - x)
            dy = min(y, h - 1 - y)
            if dx + dy < 10:
                buf[y][x] = (0, 0, 0)
            elif x in (2, 3, w - 3, w - 4) or y in (2, 3, h - 3, h - 4):
                buf[y][x] = fg
            elif y == 74 and 10 <= x < w - 10:
                buf[y][x] = (fg[0] // 2, fg[1] // 2, fg[2] // 2)

    # 8x8 main glyph scaled 6x (48x48) at (26, 16)
    for gy in range(8):
        for gx in range(8):
            if (glyph[gy] >> (7 - gx)) & 1:
                for sy in range(5):
                    for sx in range(5):
                        buf[16 + gy * 6 + sy][26 + gx * 6 + sx] = fg

    # Bottom mini-label scaled 2x at y=80
    tw = len(tag) * 8 - 2
    tx0 = (w - tw) // 2
    for idx, ch in enumerate(tag):
        pat = TINY3X5.get(ch)
        if not pat:
            continue
        for ry in range(5):
            for rx in range(3):
                if (pat[ry] >> (2 - rx)) & 1:
                    for sy in range(2):
                        for sx in range(2):
                            px = tx0 + idx * 8 + rx * 2 + sx
                            py = 80 + ry * 2 + sy
                            if 0 <= px < w and 0 <= py < h:
                                buf[py][px] = accent

    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for r, g, b in buf[y]:
            raw.extend((r, g, b))

    def chunk(ctype: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + ctype
            + data
            + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    out_path.write_bytes(png)


def parse_desktop_identity(path: Path):
    vals = {}
    in_de = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line[0] in "#;":
            continue
        if line[0] == "[":
            in_de = line.strip() == "[Desktop Entry]"
            continue
        if not in_de or "=" not in line:
            continue
        k, v = line.split("=", 1)
        vals[k.strip()] = v.strip()
    pbool = lambda s: s in {"true", "True", "1"}
    return (
        vals["Name"],
        vals.get("Icon", ""),
        vals["Exec"],
        "true" if pbool(vals.get("Terminal", "false")) else "false",
        "true" if pbool(vals.get("Sysplause", "true")) else "false",
    )


def patch_applaunch_elf64(elf_path: Path) -> None:
    """
    Pure-Python ELF64 symbol-verified patcher for M5CardputerZero-APPLaunch:
    Changes `mov w0, #0x7fffffff` (0x12b00000) -> `mov w0, #-1` (0x12800000)
    at +0x48 and +0x64 inside launcher_sort_app_display_order's comparator lambda.
    """
    data = bytearray(elf_path.read_bytes())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise RuntimeError(f"{elf_path}: not a 64-bit little-endian ELF")

    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_align, sh_entsize = (
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        )
        sections.append((sh_name, sh_type, sh_addr, sh_offset, sh_size, sh_link, sh_entsize))

    shstr_off = sections[e_shstrndx][3]

    def sec_name(name_off: int) -> str:
        end = data.index(0, shstr_off + name_off)
        return data[shstr_off + name_off : end].decode("ascii", errors="replace")

    text_vma = text_off = None
    symtab_sec = None
    for s in sections:
        nm = sec_name(s[0])
        if nm == ".text":
            text_vma, text_off = s[2], s[3]
        elif s[1] == 2:  # SHT_SYMTAB
            symtab_sec = s

    if text_vma is None or symtab_sec is None:
        raise RuntimeError(f"{elf_path}: missing .text or .symtab section (stripped?)")

    _, _, _, sym_off, sym_size, str_idx, sym_entsize = symtab_sec
    str_off = sections[str_idx][3]

    target_vma = None
    prefix = b"_ZZ31launcher_sort_app_display_order"
    for pos in range(sym_off, sym_off + sym_size, sym_entsize):
        st_name, st_info, st_other, st_shndx, st_value, st_sz = struct.unpack_from("<IBBHQQ", data, pos)
        if st_name == 0:
            continue
        end = data.index(0, str_off + st_name)
        sname = bytes(data[str_off + st_name : end])
        if sname.startswith(prefix):
            target_vma = st_value
            break

    if target_vma is None:
        raise RuntimeError(f"{elf_path}: comparator symbol {prefix.decode()} not found")

    fn_file_off = target_vma - text_vma + text_off
    old_insn = bytes.fromhex("0000b012")  # mov w0, #0x7fffffff
    new_insn = bytes.fromhex("00008012")  # mov w0, #-1

    for rel in (0x48, 0x64):
        p = fn_file_off + rel
        cur = bytes(data[p : p + 4])
        if cur == old_insn:
            data[p : p + 4] = new_insn
        elif cur == new_insn:
            pass
        else:
            raise RuntimeError(f"{elf_path}: unexpected instruction at +{hex(rel)}: {cur.hex()}")

    tmp = elf_path.with_suffix(".patching")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o755)
    tmp.replace(elf_path)


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path("/")
    applaunch_dir = root / "usr/share/APPLaunch"
    apps_dir = applaunch_dir / "applications"
    imgs_dir = applaunch_dir / "share/images"
    tsv_path = applaunch_dir / "preinstalled-desktop-apps.tsv"

    apps_dir.mkdir(parents=True, exist_ok=True)
    imgs_dir.mkdir(parents=True, exist_ok=True)

    # 1 & 2. Write icons + .desktop files + deterministic mtimes
    tsv_lines = ["# filename\tName\tIcon\tExec\tTerminal\tSysplause"]
    base_kali_ts = 1767225600  # 2026-01-01T00:00:00Z

    for idx, app in enumerate(KALI_APPS):
        write_icon_png(
            imgs_dir / app["icon_file"],
            app["bg"],
            app["fg"],
            app["accent"],
            app["glyph"],
            app["tag"],
        )
        icon_rel = f"share/images/{app['icon_file']}"
        term_str = "true" if app["terminal"] else "false"
        sysp_str = "true" if app["sysplause"] else "false"

        dpath = apps_dir / app["filename"]
        dpath.write_text(
            "[Desktop Entry]\n"
            f"Name={app['name']}\n"
            f"Exec={app['exec']}\n"
            f"Terminal={term_str}\n"
            f"Sysplause={sysp_str}\n"
            f"Icon={icon_rel}\n"
            "Type=Application\n",
            encoding="utf-8",
        )
        os.chmod(dpath, 0o644)
        ts = base_kali_ts + (idx + 1) * 10
        os.utime(dpath, (ts, ts))

        tsv_lines.append(
            f"{app['filename']}\t{app['name']}\t{icon_rel}\t{app['exec']}\t{term_str}\t{sysp_str}"
        )

    # Ensure M5 .desktop files have later mtimes than Kali .desktop files
    # and register them in preinstalled-desktop-apps.tsv so they are toggleable too
    kali_names = {a["filename"] for a in KALI_APPS}
    m5_ts = 1780272000  # 2026-06-01T00:00:00Z
    for idx, dfile in enumerate(sorted(apps_dir.glob("*.desktop"))):
        if dfile.name not in kali_names:
            os.utime(dfile, (m5_ts + idx * 10, m5_ts + idx * 10))
            m_name, m_icon, m_exec, m_term, m_sysp = parse_desktop_identity(dfile)
            tsv_lines.append(
                f"{dfile.name}\t{m_name}\t{m_icon}\t{m_exec}\t{m_term}\t{m_sysp}"
            )

    # 3. Write preinstalled-desktop-apps.tsv & verify 1:1 identity
    tsv_path.write_text("\n".join(tsv_lines) + "\n", encoding="utf-8")
    for app in KALI_APPS:
        actual = parse_desktop_identity(apps_dir / app["filename"])
        expected = (
            app["name"],
            f"share/images/{app['icon_file']}",
            app["exec"],
            "true" if app["terminal"] else "false",
            "true" if app["sysplause"] else "false",
        )
        if actual != expected:
            raise RuntimeError(f"Manifest mismatch for {app['filename']}: {actual} != {expected}")

    # 4. Seed / update config.json with all built-in + desktop app_* toggle keys
    default_toggles = {
        "app_CLI": 1,
        "app_Game": 0,
        "app_IP_Panel": 1,
        "app_Math": 0,
        "app_Python": 0,
        "app_SSH": 1,
        "app_Tank": 0,
    }
    for app in KALI_APPS:
        default_toggles[desktop_config_key(app["filename"])] = 1
    for dfile in sorted(apps_dir.glob("*.desktop")):
        if dfile.name not in kali_names:
            default_toggles[desktop_config_key(dfile.name)] = 1

    for cfg_dir in (
        root / "home/kali/.config/cardputerzero",
        root / "etc/skel/.config/cardputerzero",
    ):
        cfg_dir.mkdir(parents=True, exist_ok=True)
        cfg_file = cfg_dir / "config.json"
        existing = {}
        if cfg_file.exists():
            try:
                existing = json.loads(cfg_file.read_text(encoding="utf-8"))
            except Exception:
                existing = {}
        merged = dict(default_toggles)
        # Preserve non-app settings (brightness, volume, dark_time, etc.)
        for k, v in existing.items():
            if not k.startswith("app_"):
                merged[k] = v
        cfg_file.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    # 5. Patch M5CardputerZero-APPLaunch carousel sort order
    applaunch_bin = applaunch_dir / "bin/M5CardputerZero-APPLaunch"
    diverted_orig = root / "usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5"
    if diverted_orig.exists():
        shutil.copy2(diverted_orig, applaunch_bin)
    if applaunch_bin.exists():
        patch_applaunch_elf64(applaunch_bin)

    print(f"[OK] Configured {len(KALI_APPS)} Kali launcher apps + manifest + config.json + carousel sort order")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
