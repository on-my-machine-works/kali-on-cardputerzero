#!/usr/bin/env python3
"""
gen-kali-splash.py — Generate Kali Linux boot splash & lockscreen assets
for the M5Stack CardputerZero 1.9" ST7789v3 LCD (320x170 RGB565).

Outputs:
  --emblem    Path to official Kali dragon PNG (256x256 RGBA/RGB PNG)
  --bmp       Output 170x320 16-bit BI_BITFIELDS RGB565 BMP transposed for fb_load
  --logo-png  Output 320x170 8-bit RGB PNG for APPLaunch (logo_lcd.png)
  --lock-png  Output 320x150 8-bit RGB PNG for APPLaunch (lockscreen.png)
"""
import argparse
import math
import struct
import zlib

# Crisp 5x7 uppercase/digit/symbol bitmap font (each char: 7 rows of 5-bit masks)
FONT_5X7 = {
    " ": [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    "A": [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    "B": [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
    "C": [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
    "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
    "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
    "F": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
    "G": [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
    "H": [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
    "K": [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
    "L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
    "M": [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
    "N": [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
    "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    "R": [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
    "S": [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
    "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "V": [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
    "W": [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
    "X": [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
    "Y": [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
    "Z": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
    "0": [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
    "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    "2": [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
    "3": [0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E],
    "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    "5": [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    "6": [0x0E, 0x10, 0x10, 0x1E, 0x11, 0x11, 0x0E],
    "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    "-": [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
    "/": [0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10],
    ".": [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
    ":": [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
}


def decode_png_rgba(path):
    """Pure-Python 8-bit RGB/RGBA non-interlaced PNG reader."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos = 8
    w = h = bit_depth = color_type = 0
    idat = bytearray()
    plte = None
    trns = None
    while pos < len(data):
        ln = struct.unpack_from(">I", data, pos)[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
        if ctype == b"IHDR":
            w, h, bit_depth, color_type, comp, filt, inter = struct.unpack(">IIBBBBB", chunk)
            if bit_depth != 8 or inter != 0:
                raise ValueError(f"Unsupported PNG format depth={bit_depth} interlace={inter}")
        elif ctype == b"PLTE":
            plte = chunk
        elif ctype == b"tRNS":
            trns = chunk
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break

    raw = zlib.decompress(bytes(idat))
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    stride = w * bpp
    recon = bytearray(h * stride)

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        if pa <= pb and pa <= pc:
            return a
        return b if pb <= pc else c

    in_off = 0
    for y in range(h):
        ftype = raw[in_off]
        in_off += 1
        row_out = y * stride
        prev_out = (y - 1) * stride
        for i in range(stride):
            x = raw[in_off + i]
            a = recon[row_out + i - bpp] if i >= bpp else 0
            b = recon[prev_out + i] if y > 0 else 0
            c = recon[prev_out + i - bpp] if (y > 0 and i >= bpp) else 0
            if ftype == 0:
                val = x
            elif ftype == 1:
                val = (x + a) & 0xFF
            elif ftype == 2:
                val = (x + b) & 0xFF
            elif ftype == 3:
                val = (x + ((a + b) >> 1)) & 0xFF
            elif ftype == 4:
                val = (x + paeth(a, b, c)) & 0xFF
            else:
                raise ValueError(f"Bad PNG filter {ftype}")
            recon[row_out + i] = val
        in_off += stride

    rgba = []
    for y in range(h):
        row = []
        off = y * stride
        for x in range(w):
            p = off + x * bpp
            if color_type == 6:
                row.append((recon[p], recon[p + 1], recon[p + 2], recon[p + 3]))
            elif color_type == 2:
                row.append((recon[p], recon[p + 1], recon[p + 2], 255))
            elif color_type == 4:
                g = recon[p]
                row.append((g, g, g, recon[p + 1]))
            elif color_type == 0:
                g = recon[p]
                row.append((g, g, g, 255))
            elif color_type == 3:
                idx = recon[p]
                r, g, b = plte[idx * 3 : idx * 3 + 3]
                a = trns[idx] if (trns and idx < len(trns)) else 255
                row.append((r, g, b, a))
        rgba.append(row)
    return w, h, rgba


def scale_rgba_box(src_w, src_h, src_rgba, dst_w, dst_h):
    """High-quality area-averaging downscaler with premultiplied alpha."""
    out = []
    sx = src_w / dst_w
    sy = src_h / dst_h
    for dy in range(dst_h):
        y0 = dy * sy
        y1 = (dy + 1) * sy
        iy0 = int(math.floor(y0))
        iy1 = min(src_h - 1, int(math.ceil(y1)) - 1)
        row = []
        for dx in range(dst_w):
            x0 = dx * sx
            x1 = (dx + 1) * sx
            ix0 = int(math.floor(x0))
            ix1 = min(src_w - 1, int(math.ceil(x1)) - 1)
            pr = pg = pb = pa = wsum = 0.0
            for sy_i in range(iy0, iy1 + 1):
                wy = min(sy_i + 1.0, y1) - max(float(sy_i), y0)
                if wy <= 0:
                    continue
                srow = src_rgba[sy_i]
                for sx_i in range(ix0, ix1 + 1):
                    wx = min(sx_i + 1.0, x1) - max(float(sx_i), x0)
                    if wx <= 0:
                        continue
                    w = wx * wy
                    r, g, b, a = srow[sx_i]
                    af = a / 255.0
                    pr += r * af * w
                    pg += g * af * w
                    pb += b * af * w
                    pa += af * w
                    wsum += w
            if wsum > 0 and pa > 1e-6:
                alpha = min(1.0, pa / wsum)
                r = min(255, int(round((pr / pa))))
                g = min(255, int(round((pg / pa))))
                b = min(255, int(round((pb / pa))))
                row.append((r, g, b, int(round(alpha * 255))))
            else:
                row.append((0, 0, 0, 0))
        out.append(row)
    return out


def draw_text(canvas, w, h, x, y, text, color, scale=1, spacing=1):
    cx = x
    for ch in text.upper():
        glyph = FONT_5X7.get(ch, FONT_5X7[" "])
        for gy in range(7):
            bits = glyph[gy]
            for gx in range(5):
                if (bits >> (4 - gx)) & 1:
                    for sy in range(scale):
                        py = y + gy * scale + sy
                        if 0 <= py < h:
                            for sx in range(scale):
                                px = cx + gx * scale + sx
                                if 0 <= px < w:
                                    canvas[py][px] = color
        cx += (5 + spacing) * scale


def render_splash_canvas(emblem_w, emblem_h, emblem_rgba):
    w, h = 320, 170
    canvas = [[(0, 0, 0) for _ in range(w)] for _ in range(h)]

    # Sleek Kali dark slate-blue background with subtle radial cyan-blue glow behind dragon
    glow_cx, glow_cy = 76.0, 85.0
    for y in range(h):
        for x in range(w):
            # Subtle diagonal dark gradient + tech grid accent
            dist = math.hypot(x - glow_cx, y - glow_cy)
            glow = max(0.0, 1.0 - dist / 115.0) ** 2.2
            r = int(7 + 12 * glow)
            g = int(11 + 38 * glow)
            b = int(20 + 82 * glow)
            if (x % 16 == 0 or y % 16 == 0) and dist > 55:
                r = min(255, r + 3)
                g = min(255, g + 5)
                b = min(255, b + 9)
            canvas[y][x] = (r, g, b)

    # Top and bottom Kali cyan-blue accent lines
    for x in range(w):
        fade = 1.0 - abs(x - w / 2.0) / (w / 2.0)
        col = (int(20 + 35 * fade), int(95 + 85 * fade), int(190 + 65 * fade))
        canvas[0][x] = col
        canvas[1][x] = (col[0] // 2, col[1] // 2, col[2] // 2)
        canvas[h - 1][x] = col
        canvas[h - 2][x] = (col[0] // 2, col[1] // 2, col[2] // 2)

    # Composite official Kali Dragon emblem at 116x116 on the left
    icon_sz = 116
    icon = scale_rgba_box(emblem_w, emblem_h, emblem_rgba, icon_sz, icon_sz)
    ox, oy = 16, (h - icon_sz) // 2
    for iy in range(icon_sz):
        py = oy + iy
        if not (0 <= py < h):
            continue
        for ix in range(icon_sz):
            px = ox + ix
            if not (0 <= px < w):
                continue
            sr, sg, sb, sa = icon[iy][ix]
            if sa == 0:
                continue
            af = sa / 255.0
            dr, dg, db = canvas[py][px]
            canvas[py][px] = (
                int(round(sr * af + dr * (1.0 - af))),
                int(round(sg * af + dg * (1.0 - af))),
                int(round(sb * af + db * (1.0 - af))),
            )

    # Right-side typography:
    # "KALI" (scale=4 -> 28px tall) + "LINUX" (scale=2 -> 14px tall)
    tx = 144
    draw_text(canvas, w, h, tx + 2, 42 + 2, "KALI", (8, 28, 62), scale=4, spacing=2)
    draw_text(canvas, w, h, tx, 42, "KALI", (242, 248, 255), scale=4, spacing=2)

    draw_text(canvas, w, h, tx, 78, "L I N U X", (54, 158, 255), scale=2, spacing=1)

    # Divider bar
    for x in range(tx, 302):
        t = (x - tx) / float(302 - tx)
        canvas[102][x] = (
            int(54 * (1 - t) + 18 * t),
            int(158 * (1 - t) + 35 * t),
            int(255 * (1 - t) + 65 * t),
        )
        canvas[103][x] = (14, 36, 70)

    # Subtitle: "CARDPUTER ZERO" & "ROLLING // ARM64"
    draw_text(canvas, w, h, tx, 112, "CARDPUTER ZERO", (195, 212, 232), scale=1, spacing=2)
    draw_text(canvas, w, h, tx, 125, "ROLLING // ARM64", (92, 142, 198), scale=1, spacing=2)

    return canvas


def render_lockscreen_canvas(emblem_w, emblem_h, emblem_rgba):
    w, h = 320, 150
    canvas = [[(0, 0, 0) for _ in range(w)] for _ in range(h)]
    cx, cy = 160.0, 75.0
    for y in range(h):
        for x in range(w):
            dist = math.hypot(x - cx, y - cy)
            glow = max(0.0, 1.0 - dist / 155.0) ** 2.0
            r = int(6 + 10 * glow)
            g = int(10 + 30 * glow)
            b = int(18 + 68 * glow)
            if (x + y) % 24 == 0:
                b = min(255, b + 5)
            canvas[y][x] = (r, g, b)

    # Subtle dimmed centered Kali Dragon watermark so lockscreen clock/PIN stays crisp
    icon_sz = 96
    icon = scale_rgba_box(emblem_w, emblem_h, emblem_rgba, icon_sz, icon_sz)
    ox, oy = (w - icon_sz) // 2, (h - icon_sz) // 2
    for iy in range(icon_sz):
        py = oy + iy
        for ix in range(icon_sz):
            px = ox + ix
            sr, sg, sb, sa = icon[iy][ix]
            if sa == 0:
                continue
            af = (sa / 255.0) * 0.42
            dr, dg, db = canvas[py][px]
            canvas[py][px] = (
                int(round(sr * af + dr * (1.0 - af))),
                int(round(sg * af + dg * (1.0 - af))),
                int(round(sb * af + db * (1.0 - af))),
            )
    return canvas


def write_png_rgb(path, canvas):
    h = len(canvas)
    w = len(canvas[0])
    rows = []
    for y in range(h):
        row = bytearray([0])
        for r, g, b in canvas[y]:
            row.extend((r, g, b))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


def rgb888_to_rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def write_fbload_bmp(path, landscape_canvas):
    """
    fb_load.c reads a 170x320 16-bit RGB565 BMP into src[y * 170 + x] and
    applies transform_image():
        dst_width = 320, dst_height = 170
        dst[x * 320 + y] = src[y * 170 + x]
    So to display landscape_canvas[ly][lx] (ly in 0..169, lx in 0..319)
    right-side up on the 320x170 LCD, we set:
        src[lx * 170 + ly] = rgb565(landscape_canvas[ly][lx])
    and store src as a standard bottom-up 170x320 BI_BITFIELDS RGB565 BMP
    matching fb_load.c's built-in header (dib_size=40, offset=66).
    """
    bmp_w, bmp_h = 170, 320
    row_stride = ((bmp_w * 16 + 31) // 32) * 4  # 340 bytes (already multiple of 4)
    pixel_bytes = bytearray(row_stride * bmp_h)

    for bmp_row in range(bmp_h):
        # Bottom-up BMP: bmp_row 0 in file corresponds to src y = bmp_h - 1
        src_y = bmp_h - 1 - bmp_row  # = lx in 0..319
        row_off = bmp_row * row_stride
        for src_x in range(bmp_w):  # = ly in 0..169
            r, g, b = landscape_canvas[src_x][src_y]
            px = rgb888_to_rgb565(r, g, b)
            struct.pack_into("<H", pixel_bytes, row_off + src_x * 2, px)

    dib_size = 40
    masks = struct.pack("<III", 0x0000F800, 0x000007E0, 0x0000001F)
    pixel_offset = 14 + dib_size + len(masks)  # 66
    file_size = pixel_offset + len(pixel_bytes)  # 108866

    file_hdr = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, pixel_offset)
    dib_hdr = struct.pack(
        "<IiiHHIIiiII",
        dib_size,
        bmp_w,
        bmp_h,
        1,
        16,
        3,  # BI_BITFIELDS
        len(pixel_bytes),
        2835,
        2835,
        0,
        0,
    )
    with open(path, "wb") as f:
        f.write(file_hdr)
        f.write(dib_hdr)
        f.write(masks)
        f.write(pixel_bytes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emblem", required=True)
    ap.add_argument("--bmp", required=True)
    ap.add_argument("--logo-png", required=True)
    ap.add_argument("--lock-png", required=True)
    args = ap.parse_args()

    ew, eh, ergba = decode_png_rgba(args.emblem)
    splash = render_splash_canvas(ew, eh, ergba)
    write_png_rgb(args.logo_png, splash)
    write_fbload_bmp(args.bmp, splash)

    lock = render_lockscreen_canvas(ew, eh, ergba)
    write_png_rgb(args.lock_png, lock)


if __name__ == "__main__":
    main()
