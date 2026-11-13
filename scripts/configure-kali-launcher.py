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
  5. Patch M5CardputerZero-APPLaunch's ELF64 binary for carousel sort order and
     handheld battery/CPU/RAM efficiency:
       - Custom preinstalled entries sort ahead of built-in M5 entries.
       - Disable Cp0SystemSoundPlayer's always-open 50 Hz miniaudio silence stream
         and startup float32 SFX cache decode (keeps ES8389 DAC/I2S and PipeWire idle).
       - Eliminate infinite 30 FPS LVGL animations (carousel title scrolling, charging
         highlight shimmer bar, and unbounded overflowing label/guide scroll loops).
       - Relax LVGL background timers and worker poll intervals (Wi-Fi nmcli, BQ27220
         battery cache, BlueZ retry, directory watcher, watchdog, keypad/pipe poll).
"""

import json
import os
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


def patch_applaunch_elf64(elf_path: Path, *, source_path: Path | None = None) -> None:
    """
    Pure-Python ELF64 symbol-bounded patcher for M5CardputerZero-APPLaunch:
      1. launcher_sort_app_display_order comparator lambda:
         `mov w0, #0x7fffffff` -> `mov w0, #-1` so custom preinstalled apps sort first.
      2. Cp0SystemSoundPlayer::Impl::Impl() & decode_cache():
         disable miniaudio's continuous 48 kHz 50 Hz silence stream and skip decoding
         19 WAV/MP3 SFX files into float32 heap buffers.
      3. UI animations that would otherwise spin LVGL + lv_draw_sw at 30 FPS forever:
         - create_carousel_title() & snap_label_to_slot(): LV_LABEL_LONG_SCROLL_CIRCULAR (#3)
           -> LV_LABEL_LONG_DOT (#1) so carousel titles truncate statically with "...".
         - AppTopBarBatteryComponent::set_charging(bool): keep the #fff2a8 gold text color
           indicator when charging, but skip the infinite 30 FPS 8px highlight bar animation
           (which kept rendering 30 FPS on two threads even when locked / screen off).
         - lv_label_refr_text() & LvSettingAdbGuidePage3::start_animation(): bound
           LV_ANIM_REPEAT_INFINITE (-1) scroll/guide animations to finite repeat counts so
           locking the device on a settings page never leaves a 30 FPS render loop running.
      4. Background timers & polling threads:
         relax lv_indev_create read timer (33ms -> 50ms), WifiSystem nmcli x3 poll (3s -> 60s),
         cp0_sudo coordinator timer (20ms -> 250ms), EscUiWatchdog (50ms -> 250ms),
         keyboard_read_thread poll timeout (100ms -> 500ms), cp0_runner pipe poll timeout
         (20ms -> 100ms), cp0_external_app_runner wait sleep (10ms -> 50ms), battery warning
         timer (250ms -> 2000ms), screensaver idle timer (500ms -> 1000ms), top-bar HH:MM clock
         timer (1s -> 5s), top-bar fallback status timer (5s -> 15s), BluezWorker retry
         (2s -> 30s), AppDirectoryWatcher RPC scan (3s -> 30s), and BQ27220 battery sampling
         (3s -> 15s, within the 60s SnapshotCache::kStaleAfter window).
    """
    src = source_path if source_path is not None else elf_path
    data = bytearray(src.read_bytes())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise RuntimeError(f"{elf_path}: not a 64-bit little-endian ELF")

    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_name, sh_type, _sh_flags, sh_addr, sh_offset, sh_size, sh_link, _sh_info, _sh_align, sh_entsize = (
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        )
        sections.append((sh_name, sh_type, sh_addr, sh_offset, sh_size, sh_link, sh_entsize))

    shstr_off = sections[e_shstrndx][3]

    def sec_name(name_off: int) -> str:
        end = data.index(0, shstr_off + name_off)
        return data[shstr_off + name_off : end].decode("ascii", errors="replace")

    rodata_sec = None
    symtab_sec = None
    has_text = False
    for s in sections:
        nm = sec_name(s[0])
        if nm == ".text":
            has_text = True
        elif nm == ".rodata":
            rodata_sec = s
        elif s[1] == 2:  # SHT_SYMTAB
            symtab_sec = s

    if not has_text or rodata_sec is None or symtab_sec is None:
        raise RuntimeError(f"{elf_path}: missing .text, .rodata, or .symtab section (stripped?)")

    _, _, _, sym_off, sym_size, str_idx, sym_entsize = symtab_sec
    str_off = sections[str_idx][3]

    def u32(pos: int) -> int:
        return struct.unpack_from("<I", data, pos)[0]

    def w32(pos: int, val: int) -> None:
        struct.pack_into("<I", data, pos, val)

    def find_symbol(name_or_prefix: bytes, *, exact: bool = False) -> tuple[int, int, int]:
        hits = []
        for pos in range(sym_off, sym_off + sym_size, sym_entsize):
            st_name, _st_info, _st_other, st_shndx, st_value, st_sz = struct.unpack_from(
                "<IBBHQQ", data, pos
            )
            if st_name == 0 or st_value == 0 or st_sz == 0 or st_shndx >= len(sections):
                continue
            end = data.index(0, str_off + st_name)
            sname = bytes(data[str_off + st_name : end])
            matched = (sname == name_or_prefix) if exact else sname.startswith(name_or_prefix)
            if matched:
                sec_vma, sec_off = sections[st_shndx][2], sections[st_shndx][3]
                hits.append((st_value - sec_vma + sec_off, st_sz, st_value))
        if len(hits) != 1:
            raise RuntimeError(
                f"{elf_path}: expected 1 symbol for {name_or_prefix.decode()}, found {len(hits)}"
            )
        return hits[0]

    def is_bl_to(call_vma: int, insn: int, target_vma: int) -> bool:
        if (insn & 0xFC000000) != 0x94000000:
            return False
        imm26 = insn & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= 1 << 26
        return (call_vma + imm26 * 4) == target_vma

    def patch_guarded_u32(
        fn_off: int,
        fn_sz: int,
        orig_words: tuple[int, ...],
        new_word: int,
        guard_fn,
        desc: str,
        *,
        expected_count: int = 1,
    ) -> None:
        orig_hits = []
        new_hits = []
        for rel in range(0, fn_sz - 4 + 1, 4):
            if not guard_fn(rel):
                continue
            p = fn_off + rel
            cur = u32(p)
            if cur in orig_words:
                orig_hits.append(p)
            elif cur == new_word:
                new_hits.append(p)
        if len(orig_hits) == expected_count and len(new_hits) == 0:
            for p in orig_hits:
                w32(p, new_word)
        elif len(orig_hits) == 0 and len(new_hits) == expected_count:
            pass
        else:
            raise RuntimeError(
                f"{elf_path}: unexpected match count for {desc} "
                f"(orig={len(orig_hits)}, new={len(new_hits)}, expected={expected_count})"
            )

    def patch_int64_const(
        const_off: int, const_sz: int, orig_vals: tuple[int, ...], new_val: int, desc: str
    ) -> None:
        if const_sz != 8:
            raise RuntimeError(f"{elf_path}: unexpected size {const_sz} for {desc}")
        cur = struct.unpack_from("<q", data, const_off)[0]
        if cur in orig_vals:
            struct.pack_into("<q", data, const_off, new_val)
        elif cur == new_val:
            pass
        else:
            raise RuntimeError(f"{elf_path}: unexpected value {cur} for {desc}")

    # 1. Carousel sort order: custom preinstalled apps before built-in M5 apps
    sort_off, sort_sz, _ = find_symbol(b"_ZZ31launcher_sort_app_display_order")
    for rel in (0x48, 0x64):
        if rel + 4 > sort_sz:
            raise RuntimeError(f"{elf_path}: comparator symbol smaller than expected ({hex(sort_sz)})")
        p = sort_off + rel
        cur = u32(p)
        if cur == 0x12B00000:  # mov w0, #0x7fffffff
            w32(p, 0x12800000)  # mov w0, #-1
        elif cur == 0x12800000:
            pass
        else:
            raise RuntimeError(f"{elf_path}: unexpected sort instruction at +{hex(rel)}: {cur:#010x}")

    # 2. Cp0SystemSoundPlayer::Impl::Impl(): enabled_ = false (no idle 50 Hz silence stream)
    snd_off, snd_sz, _ = find_symbol(b"_ZN20Cp0SystemSoundPlayer4ImplC1Ev", exact=True)
    patch_guarded_u32(
        snd_off,
        snd_sz,
        (0x52800021,),  # mov w1, #1
        0x52800001,     # mov w1, #0
        lambda rel: rel >= 4 and u32(snd_off + rel - 4) == 0x91032000,  # add x0, x0, #0xc8
        "Cp0SystemSoundPlayer::Impl::enabled_ default",
    )

    # 3. Cp0SystemSoundPlayer::Impl::decode_cache(): early `ret` (skip SFX PCM cache in RAM)
    dec_off, _, _ = find_symbol(b"_ZN20Cp0SystemSoundPlayer4Impl12decode_cache")
    dec_entry = u32(dec_off)
    if (dec_entry & 0xFFC003FF) == 0xD10003FF:  # sub sp, sp, #imm12
        w32(dec_off, 0xD65F03C0)  # ret
    elif dec_entry == 0xD65F03C0:
        pass
    else:
        raise RuntimeError(f"{elf_path}: unexpected decode_cache prologue: {dec_entry:#010x}")

    # 4. Home carousel title labels: LV_LABEL_LONG_SCROLL_CIRCULAR (#3) -> LV_LABEL_LONG_DOT (#1)
    _, _, long_mode_vma = find_symbol(b"lv_label_set_long_mode", exact=True)
    for sym_prefix, label_desc in (
        (b"_ZN12_GLOBAL__N_121create_carousel_titleE", "create_carousel_title long_mode"),
        (b"_ZN12_GLOBAL__N_1L18snap_label_to_slotE", "snap_label_to_slot long_mode"),
    ):
        fn_off, fn_sz, fn_vma = find_symbol(sym_prefix)
        patch_guarded_u32(
            fn_off,
            fn_sz,
            (0x52800061,),  # mov w1, #3 (LV_LABEL_LONG_SCROLL_CIRCULAR)
            0x52800021,     # mov w1, #1 (LV_LABEL_LONG_DOT)
            lambda rel, o=fn_off, s=fn_sz, v=fn_vma: (
                rel + 12 <= s
                and (u32(o + rel + 4) & 0xFFC003FF) == 0xF94003E0  # ldr x0, [sp, #uimm]
                and is_bl_to(v + rel + 8, u32(o + rel + 8), long_mode_vma)
            ),
            label_desc,
        )

    # 4b. AppTopBarBatteryComponent::set_charging(bool): keep #fff2a8 gold text color when
    #     charging, skip the infinite 30 FPS 8px highlight bar animation (`lv_anim_start`)
    _, _, anim_delete_vma = find_symbol(b"lv_anim_delete", exact=True)
    chg_off, chg_sz, chg_vma = find_symbol(b"_ZN25AppTopBarBatteryComponent12set_chargingEb", exact=True)
    patch_guarded_u32(
        chg_off,
        chg_sz,
        (0x540001C0,),  # b.eq +0x38 (branch to unhide shimmer bar & start infinite lv_anim)
        0xD503201F,     # nop (keep shimmer bar hidden; text color is already updated above)
        lambda rel: (
            rel >= 4
            and rel + 20 <= chg_sz
            and u32(chg_off + rel - 4) == 0x7100001F  # cmp w0, #0
            and is_bl_to(chg_vma + rel + 16, u32(chg_off + rel + 16), anim_delete_vma)
        ),
        "AppTopBarBatteryComponent::set_charging shimmer anim",
    )

    # 4c. Cap remaining infinite LVGL UI animations (LV_ANIM_REPEAT_INFINITE = -1) so leaving
    #     or locking on a settings page with long labels / ADB guide stops cleanly at 0% CPU
    _, _, anim_repeat_vma = find_symbol(b"lv_anim_set_repeat_count", exact=True)
    for sym_key, new_rep_word, exp_cnt, rep_desc in (
        (b"lv_label_refr_text", 0x52800041, 2, "lv_label_refr_text scroll repeat_count"),
        (b"_ZN22LvSettingAdbGuidePage315start_animationEv", 0x52800061, 1, "LvSettingAdbGuidePage3 repeat_count"),
    ):
        fn_off, fn_sz, fn_vma = find_symbol(sym_key, exact=True)
        patch_guarded_u32(
            fn_off,
            fn_sz,
            (0x12800001,),  # mov w1, #-1 (LV_ANIM_REPEAT_INFINITE)
            new_rep_word,   # mov w1, #2 or #3
            lambda rel, o=fn_off, s=fn_sz, v=fn_vma: (
                rel + 8 <= s and is_bl_to(v + rel + 4, u32(o + rel + 4), anim_repeat_vma)
            ),
            rep_desc,
            expected_count=exp_cnt,
        )

    # 5. WifiSystem::poll_loop(): 3s (or 15s) -> 60s background nmcli x3 poll interval
    wifi_off, wifi_sz, _ = find_symbol(b"_ZN10WifiSystem9poll_loopEv", exact=True)
    patch_guarded_u32(
        wifi_off,
        wifi_sz,
        (0x52800060, 0x528001E0),  # mov w0, #3 or mov w0, #15
        0x52800780,                # mov w0, #60
        lambda rel: rel + 8 <= wifi_sz and (u32(wifi_off + rel + 4) & 0xFFC003FF) == 0xB90003E0,
        "WifiSystem::poll_loop interval",
    )

    # 6. Relax LVGL background periodic timers (`mov w1, #ms ; adrp ; add ; bl lv_timer_create`)
    _, _, timer_create_vma = find_symbol(b"lv_timer_create", exact=True)
    for sym_key, is_exact, orig_ms_word, new_ms_word, timer_desc in (
        # LVGL input device read timer: 33ms (30 Hz) -> 50ms (20 Hz)
        (b"lv_indev_create", True, 0x52800421, 0x52800641, "lv_indev_create read timer"),
        # cp0_sudo coordinator timer: 20ms (50 Hz) -> 250ms (4 Hz)
        (b"_ZN12_GLOBAL__N_115execute_actionsESt6vectorIN8cp0_sudo6ActionE", False, 0x52800281, 0x52801F41, "cp0_sudo coordinator timer"),
        # Low-battery warning check: 250ms (4 Hz) -> 2000ms (0.5 Hz)
        (b"_ZN19launcher_battery_ui12init_warningEv", True, 0x52801F41, 0x5280FA01, "battery warning timer"),
        # Screensaver idle poll: 500ms (2 Hz) -> 1000ms (1 Hz)
        (b"ui_screensaver_init", True, 0x52803E81, 0x52807D01, "ui_screensaver_init timer"),
        # Top-bar HH:MM clock refresh (no seconds shown): 1000ms -> 5000ms
        (b"_ZZN15AppTopBarRegion6enableEvENKUlvE0_clEv", True, 0x52807D01, 0x52827101, "AppTopBarRegion clock timer"),
        # Top-bar fallback status refresh (signals push immediately): 5000ms -> 15000ms
        (b"_ZZN15AppTopBarRegion6enableEvENKUlvE1_clEv", True, 0x52827101, 0x52875301, "AppTopBarRegion status timer"),
        # AppDirectoryWatcher .desktop RPC scan: 3000ms -> 30000ms
        (b"_ZN19AppDirectoryWatcher5startE", False, 0x52817701, 0x528EA601, "AppDirectoryWatcher timer"),
        # Battery UI model poll: 3000ms -> 15000ms
        (b"_ZZ12init_batteryENKUlvE0_clEv", True, 0x52817701, 0x52875301, "init_battery timer"),
    ):
        fn_off, fn_sz, fn_vma = find_symbol(sym_key, exact=is_exact)
        patch_guarded_u32(
            fn_off,
            fn_sz,
            (orig_ms_word,),
            new_ms_word,
            lambda rel, o=fn_off, s=fn_sz, v=fn_vma: (
                rel + 16 <= s and is_bl_to(v + rel + 12, u32(o + rel + 12), timer_create_vma)
            ),
            timer_desc,
        )

    # Keep screensaver update_timer_period() idle period matched at 1000ms (hold_pending stays 100ms)
    _, _, timer_set_period_vma = find_symbol(b"lv_timer_set_period", exact=True)
    utp_off, utp_sz, utp_vma = find_symbol(b"_ZN12_GLOBAL__N_119update_timer_periodEv", exact=True)
    patch_guarded_u32(
        utp_off,
        utp_sz,
        (0x52803E80,),  # mov w0, #500
        0x52807D00,     # mov w0, #1000
        lambda rel: rel + 16 <= utp_sz and is_bl_to(utp_vma + rel + 12, u32(utp_off + rel + 12), timer_set_period_vma),
        "screensaver update_timer_period idle period",
    )

    # 7. EscUiWatchdog::run() condition_variable::wait_for duration: 50ms -> 250ms
    wd_off, wd_sz, wd_vma = find_symbol(b"_ZN13EscUiWatchdog3runEv", exact=True)
    wd_ro_vma = None
    for rel in range(0, wd_sz - 12 + 1, 4):
        i0, i1, i2 = u32(wd_off + rel), u32(wd_off + rel + 4), u32(wd_off + rel + 8)
        if (i0 & 0x9F00001F) == 0x90000000 and (i1 & 0xFFC003FF) == 0x91000002 and i2 == 0xAA0303E0:
            imm = (((i0 >> 5) & 0x7FFFF) << 2) | ((i0 >> 29) & 0x3)
            if imm & (1 << 20):
                imm -= 1 << 21
            wd_ro_vma = ((wd_vma + rel) & ~0xFFF) + (imm << 12) + ((i1 >> 10) & 0xFFF)
            break
    if wd_ro_vma is None or not (rodata_sec[2] <= wd_ro_vma <= rodata_sec[2] + rodata_sec[4] - 8):
        raise RuntimeError(f"{elf_path}: could not resolve EscUiWatchdog::kPollInterval in .rodata")
    patch_int64_const(
        wd_ro_vma - rodata_sec[2] + rodata_sec[3],
        8,
        (50,),
        250,
        "EscUiWatchdog::kPollInterval",
    )

    # 8. Bq27220System::kSamplePeriod (.rodata int64 seconds): 3s -> 15s (kStaleAfter is 60s)
    bq_off, bq_sz, _ = find_symbol(b"_ZN12_GLOBAL__N_113Bq27220System13kSamplePeriodE", exact=True)
    patch_int64_const(bq_off, bq_sz, (3,), 15, "Bq27220System::kSamplePeriod")

    # 9. poll() shutdown-check timeouts (events still wake immediately on fd activity):
    #    - keyboard_read_thread: 100ms -> 500ms
    #    - cp0_runner::run (PTY/pipe reader): 20ms -> 100ms
    for sym_key, is_exact, orig_poll_word, new_poll_word, poll_desc in (
        (b"keyboard_read_thread", True, 0x52800C82, 0x52803E82, "keyboard_read_thread poll timeout"),
        (b"_ZN10cp0_runner3runE", False, 0x52800282, 0x52800C82, "cp0_runner::run poll timeout"),
    ):
        fn_off, fn_sz, _ = find_symbol(sym_key, exact=is_exact)
        patch_guarded_u32(
            fn_off,
            fn_sz,
            (orig_poll_word,),
            new_poll_word,
            lambda rel, o=fn_off, s=fn_sz: (
                rel + 12 <= s
                and u32(o + rel + 4) == 0xD2800041  # mov x1, #2
                and (u32(o + rel + 8) & 0xFC000000) == 0x94000000  # bl poll@plt
            ),
            poll_desc,
        )

    # 10. BluezWorker::schedule_manager_retry(): 2s -> 30s when Bluetooth adapter is off/absent
    bz_off, bz_sz, _ = find_symbol(b"_ZN12_GLOBAL__N_111BluezWorker22schedule_manager_retryEv", exact=True)
    patch_guarded_u32(
        bz_off,
        bz_sz,
        (0x52800040,),  # mov w0, #2
        0x528003C0,     # mov w0, #30
        lambda rel: (
            rel + 12 <= bz_sz
            and (u32(bz_off + rel + 4) & 0xFC000000) == 0x94000000  # bl g_timeout_source_new_seconds@plt
            and (u32(bz_off + rel + 8) & 0xFFC003FF) == 0xF90003E0  # str x0, [sp, #uimm]
        ),
        "BluezWorker::schedule_manager_retry interval",
    )

    # 11. cp0_external_app_runner::run(): 10ms -> 50ms child-app wait loop sleep
    run_off, run_sz, _ = find_symbol(b"_ZN23cp0_external_app_runner3runEPKcb", exact=True)
    patch_guarded_u32(
        run_off,
        run_sz,
        (0x52800140,),  # mov w0, #10
        0x52800640,     # mov w0, #50
        lambda rel: rel + 8 <= run_sz and (u32(run_off + rel + 4) & 0xFFC003FF) == 0xB90003E0,
        "cp0_external_app_runner::run sleep",
    )

    tmp = elf_path.with_suffix(".patching")
    try:
        tmp.write_bytes(data)
        os.chmod(tmp, 0o755)
        tmp.replace(elf_path)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path("/")
    applaunch_dir = root / "usr/share/APPLaunch"
    apps_dir = applaunch_dir / "applications"
    imgs_dir = applaunch_dir / "share/images"
    tsv_path = applaunch_dir / "preinstalled-desktop-apps.tsv"

    apps_dir.mkdir(parents=True, exist_ok=True)
    imgs_dir.mkdir(parents=True, exist_ok=True)
    kali_names = {a["filename"] for a in KALI_APPS}
    for stale in apps_dir.glob("kali-*.desktop"):
        if stale.name not in kali_names:
            stale.unlink(missing_ok=True)

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

    # 5. Patch M5CardputerZero-APPLaunch sort order & idle-power behavior.
    #    Read directly from the diverted pristine .m5 binary when available and
    #    atomically replace the destination once (avoids ETXTBSY while running).
    applaunch_bin = applaunch_dir / "bin/M5CardputerZero-APPLaunch"
    diverted_orig = root / "usr/lib/cz-kali/M5CardputerZero-APPLaunch.m5"
    if diverted_orig.exists():
        applaunch_bin.parent.mkdir(parents=True, exist_ok=True)
        patch_applaunch_elf64(applaunch_bin, source_path=diverted_orig)
    elif applaunch_bin.exists():
        patch_applaunch_elf64(applaunch_bin)

    print(
        f"[OK] Configured {len(KALI_APPS)} Kali launcher apps + manifest + config.json "
        "+ APPLaunch sort & idle-power patches"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
