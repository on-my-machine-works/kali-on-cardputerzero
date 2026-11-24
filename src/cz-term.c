/*
 * cz-term.c — Monospace ProFont & Multi-Theme Framebuffer Terminal
 *             for Kali Cyberdeck Edition on M5Stack CardputerZero (320x170)
 *
 * Uses ProFont (`u8g2_font_profont*` — Flipper's official `FontKeyboard` monospace
 * pixel font family from `applications/services/gui/canvas.c`):
 *
 *   0 (--std, default): ProFont12  (6x12 monospaced cell -> 53 cols x 14 rows)
 *   1 (--large)       : ProFont15  (7x15 monospaced cell -> 45 cols x 11 rows)
 *   2 (--11)          : ProFont11  (6x11 monospaced cell -> 53 cols x 15 rows, exact Flipper FontKeyboard)
 *   3 (--80)          : Micro 3x6  (4x7  monospaced cell -> 80 cols x 24 rows, dense mode)
 *
 * Live font zoom shortcuts inside terminal:
 *   - Ctrl+Alt+F : Cycle font sizes (53x14 -> 45x11 -> 53x15 -> 80x24) with SIGWINCH
 *   - Ctrl+Alt+= : Jump to Large ProFont15 (45x11)
 *   - Ctrl+Alt+- : Jump to Dense 80x24
 *   - Ctrl+Alt+0 : Reset to Standard ProFont12 (53x14)
 *
 * Exit shortcuts:
 *   - Exit shell/program normally (`exit` / Ctrl+D)
 *   - Hold ESC for ~1.2 seconds, or press Ctrl+Alt+Q
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "flipper_term_fonts.h"

#define LCD_W 320
#define LCD_H 170
#define MAX_COLS 80
#define MAX_ROWS 24
#define CZ_MAX_INPUT_FDS 12
#define CZ_TCA8418_KEYMAP_PATH "/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map"
#define CZ_TCA8418_SYM_MAX 256

static inline uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

/* Dense 80x24 opt-in 3x6 micro-font */
static const uint8_t FONT3X6[95][6] = {
    {0,0,0,0,0,0},{2,2,2,2,0,2},{5,5,0,0,0,0},{5,7,5,7,5,0},{2,7,6,3,7,2},{5,1,2,4,5,0},
    {2,5,2,5,3,0},{2,2,0,0,0,0},{1,2,2,2,1,0},{4,2,2,2,4,0},{0,5,2,5,0,0},{0,2,7,2,0,0},
    {0,0,0,0,2,4},{0,0,7,0,0,0},{0,0,0,0,2,0},{1,1,2,4,4,0},{7,5,5,5,7,0},{2,6,2,2,7,0},
    {7,1,7,4,7,0},{7,1,3,1,7,0},{5,5,7,1,1,0},{7,4,7,1,7,0},{7,4,7,5,7,0},{7,1,1,2,2,0},
    {7,5,7,5,7,0},{7,5,7,1,7,0},{0,2,0,2,0,0},{0,2,0,2,4,0},{1,2,4,2,1,0},{0,7,0,7,0,0},
    {4,2,1,2,4,0},{7,1,2,0,2,0},{7,5,7,4,7,0},{2,5,7,5,5,0},{6,5,6,5,6,0},{3,4,4,4,3,0},
    {6,5,5,5,6,0},{7,4,6,4,7,0},{7,4,6,4,4,0},{3,4,5,5,3,0},{5,5,7,5,5,0},{7,2,2,2,7,0},
    {1,1,1,5,2,0},{5,5,6,5,5,0},{4,4,4,4,7,0},{5,7,7,5,5,0},{5,7,7,7,5,0},{2,5,5,5,2,0},
    {6,5,6,4,4,0},{2,5,5,7,3,0},{6,5,6,5,5,0},{3,4,2,1,6,0},{7,2,2,2,2,0},{5,5,5,5,7,0},
    {5,5,5,5,2,0},{5,5,7,7,5,0},{5,5,2,5,5,0},{5,5,2,2,2,0},{7,1,2,4,7,0},{3,2,2,2,3,0},
    {4,4,2,1,1,0},{6,2,2,2,6,0},{2,5,0,0,0,0},{0,0,0,0,0,7},{4,2,0,0,0,0},{0,3,5,5,3,0},
    {4,6,5,5,6,0},{0,3,4,4,3,0},{1,3,5,5,3,0},{0,7,5,6,3,0},{3,2,7,2,2,0},{0,3,5,3,1,6},
    {4,6,5,5,5,0},{2,0,2,2,2,0},{1,0,1,1,5,2},{4,5,6,5,5,0},{6,2,2,2,7,0},{0,7,7,5,5,0},
    {0,6,5,5,5,0},{0,2,5,5,2,0},{0,6,5,6,4,4},{0,3,5,3,1,1},{0,3,4,4,4,0},{0,3,6,1,6,0},
    {2,7,2,2,3,0},{0,5,5,5,3,0},{0,5,5,5,2,0},{0,5,5,7,5,0},{0,5,2,2,5,0},{0,5,5,3,1,6},
    {0,7,1,4,7,0},{1,2,6,2,1,0},{2,2,2,2,2,0},{4,2,3,2,4,0},{0,2,5,2,0,0},
};

enum theme_id {
    THEME_KALI_DARK = 0,
    THEME_OG_FLIPPER = 1,
    THEME_FLIPPER_MONO = 2,
};

enum font_mode {
    FONT_PROFONT12 = 0, /* 6x12 -> 53x14 (default) */
    FONT_PROFONT15 = 1, /* 7x15 -> 45x11 (--large) */
    FONT_PROFONT11 = 2, /* 6x11 -> 53x15 (--11, exact Flipper Zero FontKeyboard) */
    FONT_DENSE_4X7 = 3, /* 4x7  -> 80x24 (--80) */
    FONT_MODE_COUNT = 4
};

struct font_geom {
    int cols;
    int rows;
    int cw;
    int ch;
    int xpad;
    int ypad;
};

static const struct font_geom GEOMS[FONT_MODE_COUNT] = {
    { 53, 14, 6, 12, 1, 1 }, /* 53*6=318 (+2 -> pad 1), 14*12=168 (+2 -> pad 1) */
    { 45, 11, 7, 15, 2, 2 }, /* 45*7=315 (+5 -> pad 2), 11*15=165 (+5 -> pad 2) */
    { 53, 15, 6, 11, 1, 2 }, /* 53*6=318 (+2 -> pad 1), 15*11=165 (+5 -> pad 2) */
    { 80, 24, 4,  7, 0, 1 }, /* 80*4=320,               24*7 =168 (+2 -> pad 1) */
};

#define CSPEC_DEF_BG 0x0000U
#define CSPEC_DEF_FG 0x0001U
#define CSPEC_IDX(i) ((uint16_t)(0x0100U | ((unsigned int)(i) & 0xFFU)))
#define CSPEC_RGB(r, g, b) ((uint16_t)(0x8000U | (((r) >> 3) << 10) | (((g) >> 3) << 5) | ((b) >> 3)))

static uint16_t g_buf[LCD_H * LCD_W];
static volatile sig_atomic_t g_running = 1;
static volatile sig_atomic_t g_child_dead = 0;

static void on_sigterm(int sig) { (void)sig; g_running = 0; }
static void on_sigchld(int sig) { (void)sig; g_child_dead = 1; }

static inline double mono_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static enum theme_id detect_theme(void)
{
    char buf[64] = "";
    const char *env = getenv("FLIPCTL_THEME");
    if (env && *env) {
        snprintf(buf, sizeof(buf), "%.63s", env);
    } else {
        const char *paths[4];
        char home_path[256] = "";
        const char *home = getenv("HOME");
        if (home && *home)
            snprintf(home_path, sizeof(home_path), "%s/.config/flipctl/theme", home);
        paths[0] = home_path[0] ? home_path : NULL;
        paths[1] = "/home/kali/.config/flipctl/theme";
        paths[2] = "/root/.config/flipctl/theme";
        paths[3] = "/tmp/flipctl-theme";
        for (int i = 0; i < 4; i++) {
            if (!paths[i]) continue;
            FILE *fp = fopen(paths[i], "r");
            if (fp) {
                if (fgets(buf, sizeof(buf), fp)) {
                    fclose(fp);
                    break;
                }
                fclose(fp);
            }
        }
    }
    for (char *p = buf; *p; p++) {
        if (*p == '\r' || *p == '\n' || isspace((unsigned char)*p)) { *p = '\0'; break; }
        *p = (char)tolower((unsigned char)*p);
    }
    if (strstr(buf, "og") != NULL) return THEME_OG_FLIPPER;
    if (strstr(buf, "mono") != NULL) return THEME_FLIPPER_MONO;
    return THEME_KALI_DARK;
}

static uint16_t theme_bg(enum theme_id th)
{
    switch (th) {
        case THEME_OG_FLIPPER:   return rgb565(0xff, 0x82, 0x00);
        case THEME_FLIPPER_MONO: return rgb565(0xff, 0xff, 0xff);
        default:                 return rgb565(0x08, 0x0c, 0x16);
    }
}

static uint16_t theme_fg(enum theme_id th)
{
    switch (th) {
        case THEME_OG_FLIPPER:   return rgb565(0x00, 0x00, 0x00);
        case THEME_FLIPPER_MONO: return rgb565(0x00, 0x00, 0x00);
        default:                 return rgb565(0xeb, 0xf3, 0xff);
    }
}

static uint16_t theme_cursor_bg(enum theme_id th)
{
    switch (th) {
        case THEME_OG_FLIPPER:   return rgb565(0x00, 0x00, 0x00);
        case THEME_FLIPPER_MONO: return rgb565(0x00, 0x00, 0x00);
        default:                 return rgb565(0x38, 0xbc, 0xff);
    }
}

static uint16_t theme_cursor_fg(enum theme_id th)
{
    switch (th) {
        case THEME_OG_FLIPPER:   return rgb565(0xff, 0x82, 0x00);
        case THEME_FLIPPER_MONO: return rgb565(0xff, 0xff, 0xff);
        default:                 return rgb565(0x08, 0x0c, 0x16);
    }
}

static uint16_t resolve_ansi16(enum theme_id th, int idx, int is_bg)
{
    idx &= 15;
    if (th == THEME_KALI_DARK) {
        static const uint8_t pal[16][3] = {
            {  8,  12,  22}, {235,  72,  86}, { 38, 214, 128}, {245, 194,  48},
            { 54, 138, 255}, {182, 102, 255}, { 56, 200, 250}, {235, 243, 255},
            {112, 132, 165}, {255, 104, 116}, { 78, 242, 158}, {255, 220,  88},
            {102, 172, 255}, {212, 142, 255}, {108, 232, 255}, {255, 255, 255},
        };
        return rgb565(pal[idx][0], pal[idx][1], pal[idx][2]);
    }
    if (th == THEME_OG_FLIPPER) {
        if (is_bg) {
            if (idx == 0) return rgb565(0xff, 0x82, 0x00);
            if (idx == 7 || idx == 15) return rgb565(0x00, 0x00, 0x00);
            return rgb565(0xd8, 0x68, 0x00);
        }
        static const uint8_t og_fg[16][3] = {
            {  0,   0,   0}, { 92,   0,   0}, {  0,  52,  18}, { 76,  28,   0},
            {  0,  28,  88}, { 68,   0,  72}, {  0,  46,  68}, {  0,   0,   0},
            { 84,  38,   0}, {112,   0,   0}, {  0,  62,  22}, { 64,  24,   0},
            {  0,  34, 104}, { 78,   0,  84}, {  0,  54,  78}, {  0,   0,   0},
        };
        return rgb565(og_fg[idx][0], og_fg[idx][1], og_fg[idx][2]);
    }
    if (is_bg) {
        if (idx == 0) return rgb565(0xff, 0xff, 0xff);
        if (idx == 7 || idx == 15) return rgb565(0x00, 0x00, 0x00);
        return rgb565(0xd8, 0xd8, 0xd8);
    }
    if (idx == 8) return rgb565(0x55, 0x55, 0x55);
    return rgb565(0x00, 0x00, 0x00);
}

static uint16_t resolve_cspec(enum theme_id th, uint16_t spec, int is_bg, int bold)
{
    if (spec == CSPEC_DEF_BG) return is_bg ? theme_bg(th) : theme_fg(th);
    if (spec == CSPEC_DEF_FG) return is_bg ? theme_fg(th) : theme_fg(th);
    if ((spec & 0xFF00U) == 0x0100U) {
        int idx = (int)(spec & 0xFFU);
        if (idx < 16) {
            if (!is_bg && bold && idx < 8) idx += 8;
            return resolve_ansi16(th, idx, is_bg);
        }
        uint8_t rv = 0, gv = 0, bv = 0;
        if (idx < 232) {
            int c = idx - 16;
            int r = (c / 36) % 6, g = (c / 6) % 6, b = c % 6;
            rv = r ? (uint8_t)(55 + r * 40) : 0;
            gv = g ? (uint8_t)(55 + g * 40) : 0;
            bv = b ? (uint8_t)(55 + b * 40) : 0;
        } else {
            rv = gv = bv = (uint8_t)(8 + (idx - 232) * 10);
        }
        if (th != THEME_KALI_DARK && !is_bg) {
            int lum = (rv * 30 + gv * 59 + bv * 11) / 100;
            if (lum > 95) return theme_fg(th);
        }
        return rgb565(rv, gv, bv);
    }
    if (spec & 0x8000U) {
        uint8_t rv = (uint8_t)(((spec >> 10) & 0x1FU) * 255U / 31U);
        uint8_t gv = (uint8_t)(((spec >> 5) & 0x1FU) * 255U / 31U);
        uint8_t bv = (uint8_t)((spec & 0x1FU) * 255U / 31U);
        if (th != THEME_KALI_DARK && !is_bg) {
            int lum = (rv * 30 + gv * 59 + bv * 11) / 100;
            if (lum > 95) return theme_fg(th);
        }
        return rgb565(rv, gv, bv);
    }
    return is_bg ? theme_bg(th) : theme_fg(th);
}

static inline void fill_rect(int x, int y, int w, int h, uint16_t col)
{
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > LCD_W) w = LCD_W - x;
    if (y + h > LCD_H) h = LCD_H - y;
    if (w <= 0 || h <= 0) return;
    for (int r = y; r < y + h; r++) {
        uint16_t *row = &g_buf[r * LCD_W + x];
        for (int c = 0; c < w; c++) row[c] = col;
    }
}

struct cell {
    uint32_t ch;
    uint16_t fg_spec;
    uint16_t bg_spec;
    uint8_t attr;
};

#define ATTR_BOLD  1
#define ATTR_REV   2
#define ATTR_ULINE 4

struct term_state {
    struct cell grid[MAX_ROWS][MAX_COLS];
    struct cell alt_grid[MAX_ROWS][MAX_COLS];
    int cols, rows;
    int cx, cy;
    int saved_cx, saved_cy;
    int alt_saved_cx, alt_saved_cy;
    int scroll_top, scroll_bot;
    uint16_t cur_fg, cur_bg;
    uint8_t cur_attr;
    int cursor_vis;
    int app_cursor;
    int autowrap;
    int wrap_pending;
    int in_alt;
    int g0_acs;

    int state;
    char csi_buf[64];
    int csi_len;
    uint32_t utf8_cp;
    int utf8_rem;
};

static struct cell blank_cell(const struct term_state *t)
{
    struct cell c;
    c.ch = ' ';
    c.fg_spec = t->cur_fg;
    c.bg_spec = t->cur_bg;
    c.attr = 0;
    return c;
}

static void term_clear_region(struct term_state *t, int r0, int c0, int r1, int c1)
{
    struct cell bl = blank_cell(t);
    for (int r = r0; r <= r1; r++) {
        if (r < 0 || r >= t->rows) continue;
        int sc = (r == r0) ? c0 : 0;
        int ec = (r == r1) ? c1 : (t->cols - 1);
        for (int c = sc; c <= ec; c++) {
            if (c >= 0 && c < t->cols) t->grid[r][c] = bl;
        }
    }
}

static void term_scroll_up(struct term_state *t, int top, int bot, int n)
{
    if (top < 0) top = 0;
    if (bot >= t->rows) bot = t->rows - 1;
    if (n <= 0 || top > bot) return;
    if (n > bot - top + 1) n = bot - top + 1;
    for (int r = top; r <= bot - n; r++)
        memcpy(t->grid[r], t->grid[r + n], sizeof(t->grid[0]));
    struct cell bl = blank_cell(t);
    for (int r = bot - n + 1; r <= bot; r++)
        for (int c = 0; c < MAX_COLS; c++) t->grid[r][c] = bl;
}

static void term_scroll_down(struct term_state *t, int top, int bot, int n)
{
    if (top < 0) top = 0;
    if (bot >= t->rows) bot = t->rows - 1;
    if (n <= 0 || top > bot) return;
    if (n > bot - top + 1) n = bot - top + 1;
    for (int r = bot; r >= top + n; r--)
        memcpy(t->grid[r], t->grid[r - n], sizeof(t->grid[0]));
    struct cell bl = blank_cell(t);
    for (int r = top; r < top + n; r++)
        for (int c = 0; c < MAX_COLS; c++) t->grid[r][c] = bl;
}

static void term_init(struct term_state *t, int cols, int rows)
{
    memset(t, 0, sizeof(*t));
    t->cols = cols;
    t->rows = rows;
    t->cur_fg = CSPEC_DEF_FG;
    t->cur_bg = CSPEC_DEF_BG;
    t->scroll_top = 0;
    t->scroll_bot = rows - 1;
    t->cursor_vis = 1;
    t->autowrap = 1;
    struct cell bl = blank_cell(t);
    for (int r = 0; r < MAX_ROWS; r++)
        for (int c = 0; c < MAX_COLS; c++)
            t->grid[r][c] = t->alt_grid[r][c] = bl;
}

static void term_resize(struct term_state *t, int new_cols, int new_rows, int master_fd, pid_t child_pid)
{
    if (new_cols > MAX_COLS) new_cols = MAX_COLS;
    if (new_rows > MAX_ROWS) new_rows = MAX_ROWS;
    int old_rows = t->rows;
    if (t->cy >= new_rows) {
        int shift = t->cy - (new_rows - 1);
        term_scroll_up(t, 0, old_rows - 1, shift);
        t->cy = new_rows - 1;
    }
    if (t->cx >= new_cols) t->cx = new_cols - 1;
    t->cols = new_cols;
    t->rows = new_rows;
    t->scroll_top = 0;
    t->scroll_bot = new_rows - 1;
    t->wrap_pending = 0;

    if (master_fd >= 0) {
        struct winsize ws = {
            .ws_row = (unsigned short)new_rows,
            .ws_col = (unsigned short)new_cols,
            .ws_xpixel = LCD_W,
            .ws_ypixel = LCD_H,
        };
        (void)ioctl(master_fd, TIOCSWINSZ, &ws);
        if (child_pid > 0) kill(-child_pid, SIGWINCH);
    }
}

static uint32_t map_acs(uint32_t ch)
{
    switch (ch) {
        case 'j': return 0x2518;
        case 'k': return 0x2510;
        case 'l': return 0x250C;
        case 'm': return 0x2514;
        case 'n': return 0x253C;
        case 'q': return 0x2500;
        case 't': return 0x251C;
        case 'u': return 0x2524;
        case 'v': return 0x2534;
        case 'w': return 0x252C;
        case 'x': return 0x2502;
        case 'a': return 0x2592;
        case '`': case '+': case '-': case '.': return '*';
        default: return ch;
    }
}

static void term_put_cp(struct term_state *t, uint32_t cp)
{
    if (t->g0_acs && cp >= 0x5F && cp <= 0x7E)
        cp = map_acs(cp);

    if (t->wrap_pending) {
        if (t->autowrap) {
            t->cx = 0;
            if (t->cy == t->scroll_bot)
                term_scroll_up(t, t->scroll_top, t->scroll_bot, 1);
            else if (t->cy < t->rows - 1)
                t->cy++;
        }
        t->wrap_pending = 0;
    }

    t->grid[t->cy][t->cx].ch = cp;
    t->grid[t->cy][t->cx].fg_spec = t->cur_fg;
    t->grid[t->cy][t->cx].bg_spec = t->cur_bg;
    t->grid[t->cy][t->cx].attr = t->cur_attr;

    if (t->cx < t->cols - 1)
        t->cx++;
    else
        t->wrap_pending = 1;
}

static void term_handle_sgr(struct term_state *t, const int *p, int np)
{
    if (np == 0) {
        t->cur_fg = CSPEC_DEF_FG;
        t->cur_bg = CSPEC_DEF_BG;
        t->cur_attr = 0;
        return;
    }
    for (int i = 0; i < np; i++) {
        int v = p[i];
        if (v == 0) {
            t->cur_fg = CSPEC_DEF_FG;
            t->cur_bg = CSPEC_DEF_BG;
            t->cur_attr = 0;
        } else if (v == 1) t->cur_attr |= ATTR_BOLD;
        else if (v == 4) t->cur_attr |= ATTR_ULINE;
        else if (v == 7) t->cur_attr |= ATTR_REV;
        else if (v == 22) t->cur_attr &= (uint8_t)~ATTR_BOLD;
        else if (v == 24) t->cur_attr &= (uint8_t)~ATTR_ULINE;
        else if (v == 27) t->cur_attr &= (uint8_t)~ATTR_REV;
        else if (v >= 30 && v <= 37) t->cur_fg = CSPEC_IDX(v - 30);
        else if (v == 39) t->cur_fg = CSPEC_DEF_FG;
        else if (v >= 40 && v <= 47) t->cur_bg = CSPEC_IDX(v - 40);
        else if (v == 49) t->cur_bg = CSPEC_DEF_BG;
        else if (v >= 90 && v <= 97) t->cur_fg = CSPEC_IDX(v - 90 + 8);
        else if (v >= 100 && v <= 107) t->cur_bg = CSPEC_IDX(v - 100 + 8);
        else if ((v == 38 || v == 48) && i + 1 < np) {
            int is_fg = (v == 38);
            if (p[i + 1] == 5 && i + 2 < np) {
                uint16_t c = CSPEC_IDX(p[i + 2]);
                if (is_fg) t->cur_fg = c; else t->cur_bg = c;
                i += 2;
            } else if (p[i + 1] == 2 && i + 4 < np) {
                uint16_t c = CSPEC_RGB(p[i + 2] & 0xFF, p[i + 3] & 0xFF, p[i + 4] & 0xFF);
                if (is_fg) t->cur_fg = c; else t->cur_bg = c;
                i += 4;
            }
        }
    }
}

static void term_enter_alt(struct term_state *t, int enter)
{
    if (enter && !t->in_alt) {
        memcpy(t->alt_grid, t->grid, sizeof(t->grid));
        t->alt_saved_cx = t->cx;
        t->alt_saved_cy = t->cy;
        t->in_alt = 1;
        term_clear_region(t, 0, 0, t->rows - 1, t->cols - 1);
        t->cx = t->cy = 0;
    } else if (!enter && t->in_alt) {
        memcpy(t->grid, t->alt_grid, sizeof(t->grid));
        t->cx = t->alt_saved_cx < t->cols ? t->alt_saved_cx : t->cols - 1;
        t->cy = t->alt_saved_cy < t->rows ? t->alt_saved_cy : t->rows - 1;
        t->in_alt = 0;
    }
    t->wrap_pending = 0;
}

static void term_exec_csi(struct term_state *t, char final, int pty_fd)
{
    t->csi_buf[t->csi_len] = '\0';
    int priv = (t->csi_buf[0] == '?');
    const char *s = priv ? (t->csi_buf + 1) : t->csi_buf;

    int params[16] = {0};
    int np = 0;
    while (*s && np < 16) {
        if (isdigit((unsigned char)*s)) {
            params[np++] = (int)strtol(s, (char **)&s, 10);
            if (*s == ';' || *s == ':') s++;
        } else if (*s == ';' || *s == ':') {
            params[np++] = 0;
            s++;
        } else {
            s++;
        }
    }

    int p0 = (np >= 1 && params[0] > 0) ? params[0] : 1;
    int p1 = (np >= 2 && params[1] > 0) ? params[1] : 1;

    if (priv) {
        int set = (final == 'h');
        if (final == 'h' || final == 'l') {
            for (int i = 0; i < np; i++) {
                switch (params[i]) {
                    case 1: t->app_cursor = set; break;
                    case 7: t->autowrap = set; break;
                    case 25: t->cursor_vis = set; break;
                    case 47:
                    case 1047:
                    case 1049: term_enter_alt(t, set); break;
                }
            }
        }
        return;
    }

    switch (final) {
        case 'A': t->cy -= p0; if (t->cy < 0) t->cy = 0; t->wrap_pending = 0; break;
        case 'B': t->cy += p0; if (t->cy >= t->rows) t->cy = t->rows - 1; t->wrap_pending = 0; break;
        case 'C': t->cx += p0; if (t->cx >= t->cols) t->cx = t->cols - 1; t->wrap_pending = 0; break;
        case 'D': t->cx -= p0; if (t->cx < 0) t->cx = 0; t->wrap_pending = 0; break;
        case 'E': t->cy += p0; if (t->cy >= t->rows) t->cy = t->rows - 1; t->cx = 0; t->wrap_pending = 0; break;
        case 'F': t->cy -= p0; if (t->cy < 0) t->cy = 0; t->cx = 0; t->wrap_pending = 0; break;
        case 'G': t->cx = p0 - 1; if (t->cx >= t->cols) t->cx = t->cols - 1; t->wrap_pending = 0; break;
        case 'd': t->cy = p0 - 1; if (t->cy >= t->rows) t->cy = t->rows - 1; t->wrap_pending = 0; break;
        case 'H':
        case 'f':
            t->cy = p0 - 1;
            t->cx = p1 - 1;
            if (t->cy < 0) t->cy = 0;
            if (t->cy >= t->rows) t->cy = t->rows - 1;
            if (t->cx < 0) t->cx = 0;
            if (t->cx >= t->cols) t->cx = t->cols - 1;
            t->wrap_pending = 0;
            break;
        case 'J': {
            int mode = (np >= 1) ? params[0] : 0;
            if (mode == 0) term_clear_region(t, t->cy, t->cx, t->rows - 1, t->cols - 1);
            else if (mode == 1) term_clear_region(t, 0, 0, t->cy, t->cx);
            else term_clear_region(t, 0, 0, t->rows - 1, t->cols - 1);
            break;
        }
        case 'K': {
            int mode = (np >= 1) ? params[0] : 0;
            if (mode == 0) term_clear_region(t, t->cy, t->cx, t->cy, t->cols - 1);
            else if (mode == 1) term_clear_region(t, t->cy, 0, t->cy, t->cx);
            else term_clear_region(t, t->cy, 0, t->cy, t->cols - 1);
            break;
        }
        case 'X': {
            int end = t->cx + p0 - 1;
            if (end >= t->cols) end = t->cols - 1;
            term_clear_region(t, t->cy, t->cx, t->cy, end);
            break;
        }
        case 'L':
            if (t->cy >= t->scroll_top && t->cy <= t->scroll_bot)
                term_scroll_down(t, t->cy, t->scroll_bot, p0);
            break;
        case 'M':
            if (t->cy >= t->scroll_top && t->cy <= t->scroll_bot)
                term_scroll_up(t, t->cy, t->scroll_bot, p0);
            break;
        case '@': {
            int n = p0;
            if (t->cx + n > t->cols) n = t->cols - t->cx;
            for (int c = t->cols - 1; c >= t->cx + n; c--)
                t->grid[t->cy][c] = t->grid[t->cy][c - n];
            term_clear_region(t, t->cy, t->cx, t->cy, t->cx + n - 1);
            break;
        }
        case 'P': {
            int n = p0;
            if (t->cx + n > t->cols) n = t->cols - t->cx;
            for (int c = t->cx; c < t->cols - n; c++)
                t->grid[t->cy][c] = t->grid[t->cy][c + n];
            term_clear_region(t, t->cy, t->cols - n, t->cy, t->cols - 1);
            break;
        }
        case 'S': term_scroll_up(t, t->scroll_top, t->scroll_bot, p0); break;
        case 'T': term_scroll_down(t, t->scroll_top, t->scroll_bot, p0); break;
        case 'r': {
            int top = (np >= 1 && params[0] > 0) ? params[0] - 1 : 0;
            int bot = (np >= 2 && params[1] > 0) ? params[1] - 1 : t->rows - 1;
            if (top >= 0 && bot < t->rows && top < bot) {
                t->scroll_top = top;
                t->scroll_bot = bot;
                t->cx = t->cy = 0;
                t->wrap_pending = 0;
            }
            break;
        }
        case 's': t->saved_cx = t->cx; t->saved_cy = t->cy; break;
        case 'u': t->cx = t->saved_cx; t->cy = t->saved_cy; t->wrap_pending = 0; break;
        case 'm': term_handle_sgr(t, params, np); break;
        case 'n':
            if (pty_fd >= 0 && np >= 1 && params[0] == 6) {
                char rep[32];
                int rl = snprintf(rep, sizeof(rep), "\x1b[%d;%dR", t->cy + 1, t->cx + 1);
                ssize_t wr = write(pty_fd, rep, (size_t)rl);
                (void)wr;
            }
            break;
        case 'c':
            if (pty_fd >= 0) {
                ssize_t wr = write(pty_fd, "\x1b[?1;2c", 7);
                (void)wr;
            }
            break;
    }
}

static void term_feed(struct term_state *t, const uint8_t *buf, size_t len, int pty_fd)
{
    for (size_t i = 0; i < len; i++) {
        uint8_t b = buf[i];
        if (t->state == 3) {
            if (b == 0x07) t->state = 0;
            else if (b == 0x1B) t->state = 4;
            continue;
        }
        if (t->state == 4) {
            t->state = (b == '\\') ? 0 : 3;
            continue;
        }
        if (b == 0x1B) {
            t->state = 1;
            t->utf8_rem = 0;
            continue;
        }
        if (t->state == 1) {
            t->state = 0;
            if (b == '[') { t->state = 2; t->csi_len = 0; }
            else if (b == ']') { t->state = 3; }
            else if (b == '(') { t->state = 5; }
            else if (b == ')' || b == '*' || b == '+') { t->state = 6; }
            else if (b == '7') { t->saved_cx = t->cx; t->saved_cy = t->cy; }
            else if (b == '8') { t->cx = t->saved_cx; t->cy = t->saved_cy; t->wrap_pending = 0; }
            else if (b == 'D') {
                if (t->cy == t->scroll_bot) term_scroll_up(t, t->scroll_top, t->scroll_bot, 1);
                else if (t->cy < t->rows - 1) t->cy++;
            } else if (b == 'M') {
                if (t->cy == t->scroll_top) term_scroll_down(t, t->scroll_top, t->scroll_bot, 1);
                else if (t->cy > 0) t->cy--;
            } else if (b == 'E') {
                t->cx = 0;
                if (t->cy == t->scroll_bot) term_scroll_up(t, t->scroll_top, t->scroll_bot, 1);
                else if (t->cy < t->rows - 1) t->cy++;
            } else if (b == 'c') {
                term_init(t, t->cols, t->rows);
            }
            continue;
        }
        if (t->state == 5) { t->g0_acs = (b == '0'); t->state = 0; continue; }
        if (t->state == 6) { t->state = 0; continue; }
        if (t->state == 2) {
            if (b >= 0x40 && b <= 0x7E) {
                term_exec_csi(t, (char)b, pty_fd);
                t->state = 0;
            } else if (t->csi_len < (int)sizeof(t->csi_buf) - 1) {
                t->csi_buf[t->csi_len++] = (char)b;
            }
            continue;
        }

        if (b == '\r') { t->cx = 0; t->wrap_pending = 0; continue; }
        if (b == '\n' || b == '\v' || b == '\f') {
            t->wrap_pending = 0;
            if (t->cy == t->scroll_bot) term_scroll_up(t, t->scroll_top, t->scroll_bot, 1);
            else if (t->cy < t->rows - 1) t->cy++;
            continue;
        }
        if (b == '\b' || b == 0x7F) {
            if (t->cx > 0) t->cx--;
            t->wrap_pending = 0;
            continue;
        }
        if (b == '\t') {
            int next = (t->cx + 8) & ~7;
            if (next >= t->cols) next = t->cols - 1;
            t->cx = next;
            t->wrap_pending = 0;
            continue;
        }
        if (b == 0x0E) { t->g0_acs = 1; continue; }
        if (b == 0x0F) { t->g0_acs = 0; continue; }
        if (b < 0x20) continue;

        if (t->utf8_rem > 0) {
            if ((b & 0xC0) == 0x80) {
                t->utf8_cp = (t->utf8_cp << 6) | (b & 0x3F);
                if (--t->utf8_rem == 0) {
                    if (!(t->utf8_cp >= 0x0300 && t->utf8_cp <= 0x036F) &&
                        t->utf8_cp != 0xFE0F && t->utf8_cp != 0x200B)
                        term_put_cp(t, t->utf8_cp);
                }
                continue;
            }
            t->utf8_rem = 0;
        }
        if ((b & 0x80) == 0) {
            term_put_cp(t, b);
        } else if ((b & 0xE0) == 0xC0) {
            t->utf8_cp = b & 0x1F;
            t->utf8_rem = 1;
        } else if ((b & 0xF0) == 0xE0) {
            t->utf8_cp = b & 0x0F;
            t->utf8_rem = 2;
        } else if ((b & 0xF8) == 0xF0) {
            t->utf8_cp = b & 0x07;
            t->utf8_rem = 3;
        }
    }
}

static void draw_cell(int px, int py, enum font_mode fm, enum theme_id th, const struct cell *c, int is_cursor)
{
    int cw = GEOMS[fm].cw;
    int ch = GEOMS[fm].ch;
    int bold = (c->attr & ATTR_BOLD) != 0;
    uint16_t fg = resolve_cspec(th, c->fg_spec, 0, bold);
    uint16_t bg = resolve_cspec(th, c->bg_spec, 1, 0);
    if (c->attr & ATTR_REV) { uint16_t tmp = fg; fg = bg; bg = tmp; }
    if (is_cursor) { fg = theme_cursor_fg(th); bg = theme_cursor_bg(th); }

    fill_rect(px, py, cw, ch, bg);
    uint32_t cp = c->ch;

    if (cp >= 0x20 && cp <= 0x7E) {
        if (fm == FONT_PROFONT12) {
            const uint8_t *g = PROFONT_6X12[cp - 0x20];
            for (int ry = 0; ry < 12; ry++) {
                uint8_t bits = g[ry];
                if (!bits) continue;
                uint16_t *row = &g_buf[(py + ry) * LCD_W + px];
                for (int rx = 0; rx < 6; rx++) {
                    if (bits & (1U << (5 - rx))) row[rx] = fg;
                }
            }
        } else if (fm == FONT_PROFONT15) {
            const uint8_t *g = PROFONT_7X15[cp - 0x20];
            for (int ry = 0; ry < 15; ry++) {
                uint8_t bits = g[ry];
                if (!bits) continue;
                uint16_t *row = &g_buf[(py + ry) * LCD_W + px];
                for (int rx = 0; rx < 7; rx++) {
                    if (bits & (1U << (6 - rx))) row[rx] = fg;
                }
            }
        } else if (fm == FONT_PROFONT11) {
            const uint8_t *g = PROFONT_6X11[cp - 0x20];
            for (int ry = 0; ry < 11; ry++) {
                uint8_t bits = g[ry];
                if (!bits) continue;
                uint16_t *row = &g_buf[(py + ry) * LCD_W + px];
                for (int rx = 0; rx < 6; rx++) {
                    if (bits & (1U << (5 - rx))) row[rx] = fg;
                }
            }
        } else {
            const uint8_t *g = FONT3X6[cp - 0x20];
            for (int ry = 0; ry < 6; ry++) {
                uint8_t bits = g[ry];
                if (!bits) continue;
                uint16_t *row = &g_buf[(py + ry) * LCD_W + px];
                if (bits & 4) row[0] = fg;
                if (bits & 2) row[1] = fg;
                if (bits & 1) row[2] = fg;
            }
        }
    } else if (cp >= 0x2500 && cp <= 0x257F) {
        int h_left = 0, h_right = 0, v_up = 0, v_dn = 0;
        switch (cp) {
            case 0x2500: case 0x2501: case 0x254C: case 0x2550: h_left = h_right = 1; break;
            case 0x2502: case 0x2503: case 0x254E: case 0x2551: v_up = v_dn = 1; break;
            case 0x250C: case 0x250F: case 0x2554: case 0x256D: h_right = v_dn = 1; break;
            case 0x2510: case 0x2513: case 0x2557: case 0x256E: h_left = v_dn = 1; break;
            case 0x2514: case 0x2517: case 0x255A: case 0x2570: h_right = v_up = 1; break;
            case 0x2518: case 0x251B: case 0x255D: case 0x256F: h_left = v_up = 1; break;
            case 0x251C: case 0x2523: case 0x2560: v_up = v_dn = h_right = 1; break;
            case 0x2524: case 0x252B: case 0x2563: v_up = v_dn = h_left = 1; break;
            case 0x252C: case 0x2533: case 0x2566: h_left = h_right = v_dn = 1; break;
            case 0x2534: case 0x253B: case 0x2569: h_left = h_right = v_up = 1; break;
            default: h_left = h_right = v_up = v_dn = 1; break;
        }
        int mx = cw / 2;
        int my = ch / 2;
        if (h_left)  fill_rect(px, py + my, mx + 1, 1, fg);
        if (h_right) fill_rect(px + mx, py + my, cw - mx, 1, fg);
        if (v_up)    fill_rect(px + mx, py, 1, my + 1, fg);
        if (v_dn)    fill_rect(px + mx, py + my, 1, ch - my, fg);
    } else if (cp >= 0x2580 && cp <= 0x259F) {
        if (cp == 0x2580) fill_rect(px, py, cw, ch / 2, fg);
        else if (cp >= 0x2581 && cp <= 0x2588) {
            int h = ((int)(cp - 0x2580) * ch + 4) / 8;
            if (h < 1) h = 1;
            fill_rect(px, py + ch - h, cw, h, fg);
        } else if (cp >= 0x2589 && cp <= 0x258F) {
            int w = ((int)(0x2590 - cp) * cw + 4) / 8;
            if (w < 1) w = 1;
            fill_rect(px, py, w, ch, fg);
        } else if (cp == 0x2590) fill_rect(px + cw / 2, py, cw - cw / 2, ch, fg);
        else if (cp == 0x2591 || cp == 0x2592 || cp == 0x2593) {
            int step = (cp == 0x2591) ? 3 : 2;
            for (int ry = 0; ry < ch; ry++)
                for (int rx = 0; rx < cw; rx++)
                    if (((rx + ry) % step) == 0)
                        g_buf[(py + ry) * LCD_W + px + rx] = fg;
        } else {
            fill_rect(px, py, cw, ch, fg);
        }
    } else if (cp >= 0x2800 && cp <= 0x28FF) {
        uint8_t br = (uint8_t)(cp - 0x2800);
        int x0 = cw / 4, x1 = (cw * 3) / 4;
        int dy[4] = { ch / 8, (ch * 3) / 8, (ch * 5) / 8, (ch * 7) / 8 };
        for (int row = 0; row < 3; row++) {
            if (br & (1 << row))       g_buf[(py + dy[row]) * LCD_W + px + x0] = fg;
            if (br & (1 << (row + 3))) g_buf[(py + dy[row]) * LCD_W + px + x1] = fg;
        }
        if (br & 0x40) g_buf[(py + dy[3]) * LCD_W + px + x0] = fg;
        if (br & 0x80) g_buf[(py + dy[3]) * LCD_W + px + x1] = fg;
    } else if (cp > 0x7E) {
        fill_rect(px + cw / 2 - 1, py + ch / 2 - 1, 2, 2, fg);
    }

    if (c->attr & ATTR_ULINE)
        fill_rect(px, py + ch - 2, cw - 1, 1, fg);
}

static void render_term(const struct term_state *t, enum font_mode fm, enum theme_id th)
{
    fill_rect(0, 0, LCD_W, LCD_H, theme_bg(th));
    int cw = GEOMS[fm].cw, ch = GEOMS[fm].ch;
    int xpad = GEOMS[fm].xpad, ypad = GEOMS[fm].ypad;
    for (int r = 0; r < t->rows; r++) {
        int py = ypad + r * ch;
        for (int c = 0; c < t->cols; c++) {
            int is_cur = t->cursor_vis && (r == t->cy && c == t->cx);
            draw_cell(xpad + c * cw, py, fm, th, &t->grid[r][c], is_cur);
        }
    }
}

struct cz_fb {
    int fd;
    struct fb_fix_screeninfo fix;
    struct fb_var_screeninfo var;
    uint8_t *map;
    size_t map_len;
};

static int cz_fb_open(struct cz_fb *fb)
{
    memset(fb, 0, sizeof(*fb));
    fb->fd = -1;
    const char *devs[] = { "/dev/fb_lcd", "/dev/fb0", "/dev/fb1", NULL };
    for (int i = 0; devs[i]; i++) {
        int fd = open(devs[i], O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, FBIOGET_FSCREENINFO, &fb->fix) == 0 &&
            ioctl(fd, FBIOGET_VSCREENINFO, &fb->var) == 0 &&
            fb->fix.smem_len > 0) {
            void *m = mmap(NULL, fb->fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (m != MAP_FAILED) {
                fb->fd = fd;
                fb->map = (uint8_t *)m;
                fb->map_len = fb->fix.smem_len;
                return 0;
            }
        }
        close(fd);
    }
    return -1;
}

static void cz_fb_blit(struct cz_fb *fb)
{
    if (!fb || fb->fd < 0 || !fb->map) return;
    int bpp = (int)(fb->var.bits_per_pixel / 8);
    int cw = ((int)fb->var.xres < LCD_W) ? (int)fb->var.xres : LCD_W;
    int ch = ((int)fb->var.yres < LCD_H) ? (int)fb->var.yres : LCD_H;
    for (int y = 0; y < ch; y++) {
        uint8_t *dst = fb->map + (size_t)(y + (int)fb->var.yoffset) * fb->fix.line_length
                               + (size_t)fb->var.xoffset * (size_t)bpp;
        const uint16_t *src = &g_buf[y * LCD_W];
        if (bpp == 2) {
            memcpy(dst, src, (size_t)cw * 2);
        } else {
            uint32_t *d32 = (uint32_t *)dst;
            for (int x = 0; x < cw; x++) {
                uint16_t p = src[x];
                uint32_t r = ((p >> 11) & 0x1F) * 255 / 31;
                uint32_t g = ((p >> 5) & 0x3F) * 255 / 63;
                uint32_t b = (p & 0x1F) * 255 / 31;
                d32[x] = (0xFFU << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }
}

static void cz_fb_close(struct cz_fb *fb)
{
    if (!fb) return;
    if (fb->map && fb->map != MAP_FAILED) munmap(fb->map, fb->map_len);
    if (fb->fd >= 0) close(fb->fd);
    fb->fd = -1;
    fb->map = NULL;
}

static int dump_ppm(const char *path)
{
    FILE *fp = fopen(path, "wb");
    if (!fp) return -1;
    fprintf(fp, "P6\n%d %d\n255\n", LCD_W, LCD_H);
    for (int i = 0; i < LCD_W * LCD_H; i++) {
        uint16_t p = g_buf[i];
        uint8_t rgb[3] = {
            (uint8_t)(((p >> 11) & 0x1F) * 255 / 31),
            (uint8_t)(((p >> 5) & 0x3F) * 255 / 63),
            (uint8_t)((p & 0x1F) * 255 / 31),
        };
        fwrite(rgb, 1, 3, fp);
    }
    fclose(fp);
    return 0;
}

static int inputs_open(int *fds, int max_fds)
{
    dev_t seen[CZ_MAX_INPUT_FDS];
    int n = 0;
    struct stat st;
    int pfd = open("/dev/input/by-path/platform-3f804000.i2c-event", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (pfd >= 0) {
        if (fstat(pfd, &st) == 0 && n < max_fds) { seen[n] = st.st_rdev; fds[n++] = pfd; }
        else close(pfd);
    }
    DIR *d = opendir("/dev/input");
    if (d) {
        struct dirent *de;
        while (n < max_fds && (de = readdir(d))) {
            if (strncmp(de->d_name, "event", 5) != 0) continue;
            char p[128];
            snprintf(p, sizeof(p), "/dev/input/%.64s", de->d_name);
            int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            if (fd < 0) continue;
            if (fstat(fd, &st) != 0) { close(fd); continue; }
            int dup = 0;
            for (int i = 0; i < n; i++) if (seen[i] == st.st_rdev) { dup = 1; break; }
            unsigned long evbit = 0;
            if (!dup && ioctl(fd, EVIOCGBIT(0, sizeof(evbit)), &evbit) >= 0 && (evbit & (1UL << EV_KEY))) {
                seen[n] = st.st_rdev;
                fds[n++] = fd;
            } else {
                close(fd);
            }
        }
        closedir(d);
    }
    return n;
}

static void tca8418_sym_defaults(char sym_map[CZ_TCA8418_SYM_MAX])
{
    memset(sym_map, 0, CZ_TCA8418_SYM_MAX);
    sym_map[26] = '!'; sym_map[27] = '@'; sym_map[39] = '#'; sym_map[40] = '$'; sym_map[41] = '%';
    sym_map[43] = '^'; sym_map[51] = '&'; sym_map[52] = '*'; sym_map[53] = '('; sym_map[94] = ')';
    sym_map[55] = '~'; sym_map[69] = '`'; sym_map[70] = '_'; sym_map[71] = '-'; sym_map[72] = '+';
    sym_map[73] = '='; sym_map[74] = '['; sym_map[75] = ']'; sym_map[76] = '{'; sym_map[77] = '}';
    sym_map[79] = ';'; sym_map[80] = ':'; sym_map[81] = '\''; sym_map[82] = '"'; sym_map[83] = '<';
    sym_map[85] = '>'; sym_map[86] = '\\'; sym_map[89] = '|';
    sym_map[90] = ','; sym_map[91] = '.'; sym_map[92] = '/'; sym_map[93] = '?';
}

static char keysym_to_ascii(const char *name)
{
    static const struct { const char *name; char ch; } tbl[] = {
        {"space",' '},{"exclam",'!'},{"quotedbl",'"'},{"numbersign",'#'},{"dollar",'$'},
        {"percent",'%'},{"ampersand",'&'},{"apostrophe",'\''},{"quoteright",'\''},{"parenleft",'('},
        {"parenright",')'},{"asterisk",'*'},{"plus",'+'},{"comma",','},{"minus",'-'},
        {"period",'.'},{"slash",'/'},{"colon",':'},{"semicolon",';'},{"less",'<'},
        {"equal",'='},{"greater",'>'},{"question",'?'},{"at",'@'},{"bracketleft",'['},
        {"backslash",'\\'},{"bracketright",']'},{"asciicircum",'^'},{"underscore",'_'},{"grave",'`'},
        {"quoteleft",'`'},{"braceleft",'{'},{"bar",'|'},{"braceright",'}'},{"asciitilde",'~'},
    };
    if (!name || !*name) return 0;
    if (name[1] == '\0' && (unsigned char)name[0] >= 0x20 && (unsigned char)name[0] <= 0x7E)
        return name[0];
    for (size_t i = 0; i < sizeof(tbl) / sizeof(tbl[0]); i++)
        if (strcmp(name, tbl[i].name) == 0) return tbl[i].ch;
    return 0;
}

static void tca8418_keymap_load(const char *path, char sym_map[CZ_TCA8418_SYM_MAX])
{
    tca8418_sym_defaults(sym_map);
    FILE *fp = path ? fopen(path, "r") : NULL;
    if (!fp) return;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = '\0';
        char *p = line;
        while (*p && isspace((unsigned char)*p)) p++;
        unsigned int kc = 0;
        char sym[64] = "";
        if (*p && sscanf(p, "keycode %u = %63s", &kc, sym) == 2 && kc < CZ_TCA8418_SYM_MAX) {
            char ch = keysym_to_ascii(sym);
            if (ch != 0) sym_map[kc] = ch;
        }
    }
    fclose(fp);
}

static int is_tca8418_fd(int fd)
{
    struct stat st, ref;
    if (fstat(fd, &st) == 0) {
        if (stat("/dev/input/by-path/platform-3f804000.i2c-event", &ref) == 0 && st.st_rdev == ref.st_rdev) return 1;
        if (stat("/dev/input/cardputer-zero-internal", &ref) == 0 && st.st_rdev == ref.st_rdev) return 1;
    }
    char name[64] = "";
    if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0) {
        for (const char *p = name; *p; p++)
            if (tolower((unsigned char)p[0]) == 't' && tolower((unsigned char)p[1]) == 'c' &&
                tolower((unsigned char)p[2]) == 'a' && p[3] == '8' && p[4] == '4') return 1;
    }
    return 0;
}

static int us_qwerty_to_ascii(int code, int shift)
{
    switch (code) {
        case KEY_A: return shift ? 'A' : 'a'; case KEY_B: return shift ? 'B' : 'b';
        case KEY_C: return shift ? 'C' : 'c'; case KEY_D: return shift ? 'D' : 'd';
        case KEY_E: return shift ? 'E' : 'e'; case KEY_F: return shift ? 'F' : 'f';
        case KEY_G: return shift ? 'G' : 'g'; case KEY_H: return shift ? 'H' : 'h';
        case KEY_I: return shift ? 'I' : 'i'; case KEY_J: return shift ? 'J' : 'j';
        case KEY_K: return shift ? 'K' : 'k'; case KEY_L: return shift ? 'L' : 'l';
        case KEY_M: return shift ? 'M' : 'm'; case KEY_N: return shift ? 'N' : 'n';
        case KEY_O: return shift ? 'O' : 'o'; case KEY_P: return shift ? 'P' : 'p';
        case KEY_Q: return shift ? 'Q' : 'q'; case KEY_R: return shift ? 'R' : 'r';
        case KEY_S: return shift ? 'S' : 's'; case KEY_T: return shift ? 'T' : 't';
        case KEY_U: return shift ? 'U' : 'u'; case KEY_V: return shift ? 'V' : 'v';
        case KEY_W: return shift ? 'W' : 'w'; case KEY_X: return shift ? 'X' : 'x';
        case KEY_Y: return shift ? 'Y' : 'y'; case KEY_Z: return shift ? 'Z' : 'z';
        case KEY_1: return shift ? '!' : '1'; case KEY_2: return shift ? '@' : '2';
        case KEY_3: return shift ? '#' : '3'; case KEY_4: return shift ? '$' : '4';
        case KEY_5: return shift ? '%' : '5'; case KEY_6: return shift ? '^' : '6';
        case KEY_7: return shift ? '&' : '7'; case KEY_8: return shift ? '*' : '8';
        case KEY_9: return shift ? '(' : '9'; case KEY_0: return shift ? ')' : '0';
        case KEY_MINUS: return shift ? '_' : '-'; case KEY_EQUAL: return shift ? '+' : '=';
        case KEY_LEFTBRACE: return shift ? '{' : '['; case KEY_RIGHTBRACE: return shift ? '}' : ']';
        case KEY_BACKSLASH: return shift ? '|' : '\\'; case KEY_SEMICOLON: return shift ? ':' : ';';
        case KEY_APOSTROPHE: return shift ? '"' : '\''; case KEY_GRAVE: return shift ? '~' : '`';
        case KEY_COMMA: return shift ? '<' : ','; case KEY_DOT: return shift ? '>' : '.';
        case KEY_SLASH: return shift ? '?' : '/'; case KEY_SPACE: return ' ';
        default: return 0;
    }
}

static void send_key_to_pty(int pty_fd, const struct term_state *t,
                            const char sym_map[CZ_TCA8418_SYM_MAX], int is_tca8418,
                            int code, int shift, int ctrl, int alt)
{
    char seq[16];
    int slen = 0;
    char pfx = t->app_cursor ? 'O' : '[';

    switch (code) {
        case KEY_ENTER:
        case KEY_KPENTER: seq[0] = '\r'; slen = 1; break;
        case KEY_BACKSPACE: seq[0] = 0x7F; slen = 1; break;
        case KEY_TAB:
            if (shift) { memcpy(seq, "\x1b[Z", 3); slen = 3; }
            else { seq[0] = '\t'; slen = 1; }
            break;
        case KEY_ESC: seq[0] = 0x1B; slen = 1; break;
        case KEY_UP:    slen = snprintf(seq, sizeof(seq), "\x1b%cA", pfx); break;
        case KEY_DOWN:  slen = snprintf(seq, sizeof(seq), "\x1b%cB", pfx); break;
        case KEY_RIGHT: slen = snprintf(seq, sizeof(seq), "\x1b%cC", pfx); break;
        case KEY_LEFT:  slen = snprintf(seq, sizeof(seq), "\x1b%cD", pfx); break;
        case KEY_HOME:  memcpy(seq, "\x1b[H", 3); slen = 3; break;
        case KEY_END:   memcpy(seq, "\x1b[F", 3); slen = 3; break;
        case KEY_INSERT:   memcpy(seq, "\x1b[2~", 4); slen = 4; break;
        case KEY_DELETE:   memcpy(seq, "\x1b[3~", 4); slen = 4; break;
        case KEY_PAGEUP:   memcpy(seq, "\x1b[5~", 4); slen = 4; break;
        case KEY_PAGEDOWN: memcpy(seq, "\x1b[6~", 4); slen = 4; break;
        default: {
            int ch = (is_tca8418 && code >= 0 && code < CZ_TCA8418_SYM_MAX && sym_map[code] != 0)
                   ? (unsigned char)sym_map[code]
                   : us_qwerty_to_ascii(code, shift);
            if (ch > 0) {
                if (ctrl) {
                    if (ch >= 'a' && ch <= 'z') ch = ch - 'a' + 1;
                    else if (ch >= 'A' && ch <= 'Z') ch = ch - 'A' + 1;
                    else if (ch == ' ' || ch == '@') ch = 0;
                    else if (ch == '[') ch = 27;
                    else if (ch == '\\') ch = 28;
                    else if (ch == ']') ch = 29;
                    else if (ch == '^' || ch == '~') ch = 30;
                    else if (ch == '_' || ch == '/') ch = 31;
                    else if (ch == '?') ch = 127;
                }
                if (alt) { seq[0] = 0x1B; seq[1] = (char)ch; slen = 2; }
                else { seq[0] = (char)ch; slen = 1; }
            }
            break;
        }
    }
    if (slen > 0 && pty_fd >= 0) {
        ssize_t wr = write(pty_fd, seq, (size_t)slen);
        (void)wr;
    }
}

int main(int argc, char **argv)
{
    signal(SIGINT, on_sigterm);
    signal(SIGTERM, on_sigterm);
    signal(SIGCHLD, on_sigchld);

    enum font_mode fm = FONT_PROFONT12;
    int keep_cwd = 0;
    int argi = 1;
    while (argi < argc && argv[argi][0] == '-') {
        if (strcmp(argv[argi], "--std") == 0) { fm = FONT_PROFONT12; argi++; }
        else if (strcmp(argv[argi], "--large") == 0) { fm = FONT_PROFONT15; argi++; }
        else if (strcmp(argv[argi], "--11") == 0) { fm = FONT_PROFONT11; argi++; }
        else if (strcmp(argv[argi], "--80") == 0) { fm = FONT_DENSE_4X7; argi++; }
        else if (strcmp(argv[argi], "--keep-cwd") == 0) { keep_cwd = 1; argi++; }
        else if (strcmp(argv[argi], "--") == 0) { argi++; break; }
        else break;
    }

    enum theme_id th = detect_theme();
    struct term_state *ts = calloc(1, sizeof(*ts));
    if (!ts) return 1;
    term_init(ts, GEOMS[fm].cols, GEOMS[fm].rows);

    const char *dump_path = getenv("CZ_DUMP_PPM");
    if (dump_path) {
        const char *demo =
            "\x1b[1;36m┌─ Kali Cyberdeck Term (ProFont Mono) ──────┐\x1b[0m\r\n"
            "\x1b[1;32mkali@cardputerzero\x1b[0m:\x1b[1;34m~\x1b[0m$ ip -br -4 a\r\n"
            "wlan0  UP  192.168.1.42/24\r\n"
            "usb0   UP  10.55.0.1/24  (OTG Net+HID)\r\n"
            "\x1b[1;32mkali@cardputerzero\x1b[0m:\x1b[1;34m~\x1b[0m$ uname -sr\r\n"
            "Linux 6.18.39+rpt-rpi-v8\r\n"
            "\x1b[1;33m[Ctrl+Alt+F]\x1b[0m Font  \x1b[1;33m[Hold ESC]\x1b[0m Exit\r\n"
            "\x1b[1;32mkali@cardputerzero\x1b[0m:\x1b[1;34m~\x1b[0m$ ";
        term_feed(ts, (const uint8_t *)demo, strlen(demo), -1);
        render_term(ts, fm, th);
        int rc = dump_ppm(dump_path);
        free(ts);
        return rc == 0 ? 0 : 1;
    }

    struct cz_fb fb;
    if (cz_fb_open(&fb) != 0) {
        fprintf(stderr, "cz-term: cannot open /dev/fb_lcd\n");
        free(ts);
        return 1;
    }

    struct winsize ws = {
        .ws_row = (unsigned short)GEOMS[fm].rows,
        .ws_col = (unsigned short)GEOMS[fm].cols,
        .ws_xpixel = LCD_W,
        .ws_ypixel = LCD_H,
    };

    int master_fd = -1;
    pid_t pid = forkpty(&master_fd, NULL, NULL, &ws);
    if (pid < 0) {
        cz_fb_close(&fb);
        free(ts);
        return 1;
    }
    if (pid == 0) {
        char cols_s[16], rows_s[16];
        snprintf(cols_s, sizeof(cols_s), "%d", GEOMS[fm].cols);
        snprintf(rows_s, sizeof(rows_s), "%d", GEOMS[fm].rows);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("COLUMNS", cols_s, 1);
        setenv("LINES", rows_s, 1);
        unsetenv("LD_PRELOAD");
        if (!keep_cwd) {
            const char *home = getenv("HOME");
            if (!home || !*home) home = "/home/kali";
            if (chdir(home) == 0)
                setenv("PWD", home, 1);
        }
        if (argi < argc) {
            execvp(argv[argi], &argv[argi]);
        } else {
            const char *sh = getenv("SHELL");
            if (!sh || !*sh) sh = "/usr/bin/zsh";
            if (access(sh, X_OK) == 0)
                execl(sh, sh, "-l", (char *)NULL);
            execl("/bin/bash", "bash", "-l", (char *)NULL);
        }
        _exit(127);
    }

    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

    int in_fds[CZ_MAX_INPUT_FDS];
    int in_tca8418[CZ_MAX_INPUT_FDS];
    int n_in = inputs_open(in_fds, CZ_MAX_INPUT_FDS);

    char tca_sym_map[CZ_TCA8418_SYM_MAX];
    tca8418_keymap_load(CZ_TCA8418_KEYMAP_PATH, tca_sym_map);
    for (int i = 0; i < n_in; i++) in_tca8418[i] = is_tca8418_fd(in_fds[i]);

    int shift = 0, ctrl = 0, alt = 0;
    double esc_down_at = 0.0;
    double last_theme_check = mono_sec();
    int dirty = 1;

    while (g_running && !g_child_dead) {
        double now = mono_sec();
        if (now - last_theme_check >= 1.0) {
            last_theme_check = now;
            enum theme_id next_th = detect_theme();
            if (next_th != th) {
                th = next_th;
                dirty = 1;
            }
        }
        if (dirty) {
            render_term(ts, fm, th);
            cz_fb_blit(&fb);
            dirty = 0;
        }

        struct pollfd pfds[CZ_MAX_INPUT_FDS + 1];
        pfds[0].fd = master_fd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        for (int i = 0; i < n_in; i++) {
            pfds[i + 1].fd = in_fds[i];
            pfds[i + 1].events = POLLIN;
            pfds[i + 1].revents = 0;
        }

        int prc = poll(pfds, (nfds_t)(n_in + 1), 40);
        if (esc_down_at > 0.0 && (mono_sec() - esc_down_at) >= 1.2) {
            g_running = 0;
            break;
        }
        if (prc <= 0) continue;

        if (pfds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t rbuf[4096];
            ssize_t rd;
            int got = 0;
            while ((rd = read(master_fd, rbuf, sizeof(rbuf))) > 0) {
                term_feed(ts, rbuf, (size_t)rd, master_fd);
                got = 1;
            }
            if (got) dirty = 1;
            if ((pfds[0].revents & (POLLHUP | POLLERR)) && !got) break;
        }

        for (int i = 0; i < n_in; i++) {
            if (!(pfds[i + 1].revents & POLLIN)) continue;
            struct input_event ev;
            while (read(in_fds[i], &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type != EV_KEY) continue;
                if (ev.code == KEY_LEFTSHIFT || ev.code == KEY_RIGHTSHIFT) { shift = (ev.value != 0); continue; }
                if (ev.code == KEY_LEFTCTRL || ev.code == KEY_RIGHTCTRL)   { ctrl  = (ev.value != 0); continue; }
                if (ev.code == KEY_LEFTALT || ev.code == KEY_RIGHTALT)     { alt   = (ev.value != 0); continue; }
                if (ev.code == KEY_ESC) {
                    if (ev.value == 1) esc_down_at = mono_sec();
                    else if (ev.value == 0) esc_down_at = 0.0;
                }
                if (ev.value != 1 && ev.value != 2) continue;
                if (ctrl && alt && ev.code == KEY_Q) {
                    g_running = 0;
                    break;
                }
                if (ctrl && alt && ev.value == 1 &&
                    (ev.code == KEY_F || ev.code == KEY_EQUAL || ev.code == KEY_MINUS || ev.code == KEY_0)) {
                    if (ev.code == KEY_0) fm = FONT_PROFONT12;
                    else if (ev.code == KEY_EQUAL) fm = FONT_PROFONT15;
                    else if (ev.code == KEY_MINUS) fm = FONT_DENSE_4X7;
                    else fm = (enum font_mode)((fm + 1) % FONT_MODE_COUNT);
                    term_resize(ts, GEOMS[fm].cols, GEOMS[fm].rows, master_fd, pid);
                    dirty = 1;
                    continue;
                }
                send_key_to_pty(master_fd, ts, tca_sym_map, in_tca8418[i], ev.code, shift, ctrl, alt);
            }
        }
    }

    kill(pid, SIGHUP);
    waitpid(pid, NULL, WNOHANG);
    for (int i = 0; i < n_in; i++) if (in_fds[i] >= 0) close(in_fds[i]);
    close(master_fd);
    cz_fb_close(&fb);
    free(ts);
    return 0;
}
