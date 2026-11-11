/*
 * cz-term80.c — Native 320x170 RGB565 High-Density 80x24 Framebuffer Terminal
 *               for Kali Linux on M5Stack CardputerZero
 *
 * Renders an exact 80 columns x 24 rows VT100/xterm-256color terminal onto the
 * 320x170 ST7789v3 LCD (4x7 pixel cell = 320x168, centered with 1px top/bottom
 * margin) so standard 80x24-minimum Kali ncurses tools (btop, htop, kismet,
 * nmtui, alsamixer, tmux, vim) run natively on the built-in 1.9" display.
 *
 * Exit shortcuts:
 *   - Exit the shell/command normally (`exit` / Ctrl-D)
 *   - Hold ESC for ~1.2 seconds, or press Ctrl+Alt+Q
 */

#include "cz_ui.h"
#include <pty.h>
#include <sys/wait.h>
#include <termios.h>

#define TERM_COLS 80
#define TERM_ROWS 24
#define CELL_W 4
#define CELL_H 7
#define Y_PAD 1

static volatile sig_atomic_t g_running = 1;
static volatile sig_atomic_t g_child_dead = 0;

static void on_sigterm(int sig)
{
    (void)sig;
    g_running = 0;
}

static void on_sigchld(int sig)
{
    (void)sig;
    g_child_dead = 1;
}

/*
 * Crisp 3x6 micro-font for ASCII 0x20..0x7E (packed: 6 rows of 3-bit patterns,
 * bit2=left col, bit1=mid col, bit0=right col, rendered in a 4x7 cell).
 */
static const uint8_t FONT3X6[95][6] = {
    {0,0,0,0,0,0}, /* ' ' */ {2,2,2,2,0,2}, /* '!' */ {5,5,0,0,0,0}, /* '"' */
    {5,7,5,7,5,0}, /* '#' */ {2,7,6,3,7,2}, /* '$' */ {5,1,2,4,5,0}, /* '%' */
    {2,5,2,5,3,0}, /* '&' */ {2,2,0,0,0,0}, /* '\''*/ {1,2,2,2,1,0}, /* '(' */
    {4,2,2,2,4,0}, /* ')' */ {0,5,2,5,0,0}, /* '*' */ {0,2,7,2,0,0}, /* '+' */
    {0,0,0,0,2,4}, /* ',' */ {0,0,7,0,0,0}, /* '-' */ {0,0,0,0,2,0}, /* '.' */
    {1,1,2,4,4,0}, /* '/' */ {7,5,5,5,7,0}, /* '0' */ {2,6,2,2,7,0}, /* '1' */
    {7,1,7,4,7,0}, /* '2' */ {7,1,3,1,7,0}, /* '3' */ {5,5,7,1,1,0}, /* '4' */
    {7,4,7,1,7,0}, /* '5' */ {7,4,7,5,7,0}, /* '6' */ {7,1,1,2,2,0}, /* '7' */
    {7,5,7,5,7,0}, /* '8' */ {7,5,7,1,7,0}, /* '9' */ {0,2,0,2,0,0}, /* ':' */
    {0,2,0,2,4,0}, /* ';' */ {1,2,4,2,1,0}, /* '<' */ {0,7,0,7,0,0}, /* '=' */
    {4,2,1,2,4,0}, /* '>' */ {7,1,2,0,2,0}, /* '?' */ {7,5,7,4,7,0}, /* '@' */
    {2,5,7,5,5,0}, /* 'A' */ {6,5,6,5,6,0}, /* 'B' */ {3,4,4,4,3,0}, /* 'C' */
    {6,5,5,5,6,0}, /* 'D' */ {7,4,6,4,7,0}, /* 'E' */ {7,4,6,4,4,0}, /* 'F' */
    {3,4,5,5,3,0}, /* 'G' */ {5,5,7,5,5,0}, /* 'H' */ {7,2,2,2,7,0}, /* 'I' */
    {1,1,1,5,2,0}, /* 'J' */ {5,5,6,5,5,0}, /* 'K' */ {4,4,4,4,7,0}, /* 'L' */
    {5,7,7,5,5,0}, /* 'M' */ {5,7,7,7,5,0}, /* 'N' */ {2,5,5,5,2,0}, /* 'O' */
    {6,5,6,4,4,0}, /* 'P' */ {2,5,5,7,3,0}, /* 'Q' */ {6,5,6,5,5,0}, /* 'R' */
    {3,4,2,1,6,0}, /* 'S' */ {7,2,2,2,2,0}, /* 'T' */ {5,5,5,5,7,0}, /* 'U' */
    {5,5,5,5,2,0}, /* 'V' */ {5,5,7,7,5,0}, /* 'W' */ {5,5,2,5,5,0}, /* 'X' */
    {5,5,2,2,2,0}, /* 'Y' */ {7,1,2,4,7,0}, /* 'Z' */ {3,2,2,2,3,0}, /* '[' */
    {4,4,2,1,1,0}, /* '\\'*/ {6,2,2,2,6,0}, /* ']' */ {2,5,0,0,0,0}, /* '^' */
    {0,0,0,0,0,7}, /* '_' */ {4,2,0,0,0,0}, /* '`' */ {0,3,5,5,3,0}, /* 'a' */
    {4,6,5,5,6,0}, /* 'b' */ {0,3,4,4,3,0}, /* 'c' */ {1,3,5,5,3,0}, /* 'd' */
    {0,7,5,6,3,0}, /* 'e' */ {3,2,7,2,2,0}, /* 'f' */ {0,3,5,3,1,6}, /* 'g' */
    {4,6,5,5,5,0}, /* 'h' */ {2,0,2,2,2,0}, /* 'i' */ {1,0,1,1,5,2}, /* 'j' */
    {4,5,6,5,5,0}, /* 'k' */ {6,2,2,2,7,0}, /* 'l' */ {0,7,7,5,5,0}, /* 'm' */
    {0,6,5,5,5,0}, /* 'n' */ {0,2,5,5,2,0}, /* 'o' */ {0,6,5,6,4,4}, /* 'p' */
    {0,3,5,3,1,1}, /* 'q' */ {0,3,4,4,4,0}, /* 'r' */ {0,3,6,1,6,0}, /* 's' */
    {2,7,2,2,3,0}, /* 't' */ {0,5,5,5,3,0}, /* 'u' */ {0,5,5,5,2,0}, /* 'v' */
    {0,5,5,7,5,0}, /* 'w' */ {0,5,2,2,5,0}, /* 'x' */ {0,5,5,3,1,6}, /* 'y' */
    {0,7,1,4,7,0}, /* 'z' */ {1,2,6,2,1,0}, /* '{' */ {2,2,2,2,2,0}, /* '|' */
    {4,2,3,2,4,0}, /* '}' */ {0,2,5,2,0,0}, /* '~' */
};

struct cell {
    uint32_t ch;
    uint16_t fg;
    uint16_t bg;
    uint8_t attr; /* bit0=bold, bit1=rev, bit2=uline */
};

#define ATTR_BOLD  1
#define ATTR_REV   2
#define ATTR_ULINE 4

struct term_state {
    struct cell grid[TERM_ROWS][TERM_COLS];
    struct cell alt_grid[TERM_ROWS][TERM_COLS];
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

    /* Escape / UTF-8 parser state */
    int state; /* 0=norm, 1=esc, 2=csi, 3=osc, 4=osc_esc, 5=charset */
    char csi_buf[64];
    int csi_len;
    uint32_t utf8_cp;
    int utf8_rem;
};

static uint16_t ansi16_color(int idx)
{
    static const uint8_t pal[16][3] = {
        { 12,  16,  28}, /* 0 black (Kali bg) */
        {235,  72,  86}, /* 1 red */
        { 38, 214, 128}, /* 2 green */
        {245, 194,  48}, /* 3 yellow */
        { 54, 138, 255}, /* 4 blue */
        {182, 102, 255}, /* 5 magenta */
        { 56, 200, 250}, /* 6 cyan */
        {225, 234, 248}, /* 7 white */
        { 98, 114, 142}, /* 8 bright black */
        {255, 104, 116}, /* 9 bright red */
        { 78, 242, 158}, /* 10 bright green */
        {255, 220,  88}, /* 11 bright yellow */
        {102, 172, 255}, /* 12 bright blue */
        {212, 142, 255}, /* 13 bright magenta */
        {108, 232, 255}, /* 14 bright cyan */
        {255, 255, 255}, /* 15 bright white */
    };
    idx &= 15;
    return rgb565(pal[idx][0], pal[idx][1], pal[idx][2]);
}

static uint16_t xterm256_color(int idx)
{
    if (idx < 0) idx = 0;
    if (idx < 16) return ansi16_color(idx);
    if (idx < 232) {
        int c = idx - 16;
        int r = (c / 36) % 6;
        int g = (c / 6) % 6;
        int b = c % 6;
        uint8_t rv = r ? (uint8_t)(55 + r * 40) : 0;
        uint8_t gv = g ? (uint8_t)(55 + g * 40) : 0;
        uint8_t bv = b ? (uint8_t)(55 + b * 40) : 0;
        return rgb565(rv, gv, bv);
    }
    uint8_t v = (uint8_t)(8 + (idx - 232) * 10);
    return rgb565(v, v, v);
}

static struct cell blank_cell(const struct term_state *t)
{
    struct cell c;
    c.ch = ' ';
    c.fg = t->cur_fg;
    c.bg = t->cur_bg;
    c.attr = 0;
    return c;
}

static void term_clear_region(struct term_state *t, int r0, int c0, int r1, int c1)
{
    struct cell bl = blank_cell(t);
    for (int r = r0; r <= r1; r++) {
        if (r < 0 || r >= TERM_ROWS) continue;
        int sc = (r == r0) ? c0 : 0;
        int ec = (r == r1) ? c1 : (TERM_COLS - 1);
        for (int c = sc; c <= ec; c++) {
            if (c >= 0 && c < TERM_COLS) t->grid[r][c] = bl;
        }
    }
}

static void term_scroll_up(struct term_state *t, int top, int bot, int n)
{
    if (top < 0) top = 0;
    if (bot >= TERM_ROWS) bot = TERM_ROWS - 1;
    if (n <= 0 || top > bot) return;
    if (n > bot - top + 1) n = bot - top + 1;
    for (int r = top; r <= bot - n; r++)
        memcpy(t->grid[r], t->grid[r + n], sizeof(t->grid[0]));
    struct cell bl = blank_cell(t);
    for (int r = bot - n + 1; r <= bot; r++)
        for (int c = 0; c < TERM_COLS; c++) t->grid[r][c] = bl;
}

static void term_scroll_down(struct term_state *t, int top, int bot, int n)
{
    if (top < 0) top = 0;
    if (bot >= TERM_ROWS) bot = TERM_ROWS - 1;
    if (n <= 0 || top > bot) return;
    if (n > bot - top + 1) n = bot - top + 1;
    for (int r = bot; r >= top + n; r--)
        memcpy(t->grid[r], t->grid[r - n], sizeof(t->grid[0]));
    struct cell bl = blank_cell(t);
    for (int r = top; r < top + n; r++)
        for (int c = 0; c < TERM_COLS; c++) t->grid[r][c] = bl;
}

static void term_reset(struct term_state *t)
{
    memset(t, 0, sizeof(*t));
    t->cur_fg = ansi16_color(7);
    t->cur_bg = ansi16_color(0);
    t->scroll_top = 0;
    t->scroll_bot = TERM_ROWS - 1;
    t->cursor_vis = 1;
    t->autowrap = 1;
    struct cell bl = blank_cell(t);
    for (int r = 0; r < TERM_ROWS; r++)
        for (int c = 0; c < TERM_COLS; c++)
            t->grid[r][c] = t->alt_grid[r][c] = bl;
}

/* Map DEC Special Graphics (ESC ( 0) to Unicode box/symbol codepoints */
static uint32_t map_acs(uint32_t ch)
{
    switch (ch) {
        case 'j': return 0x2518; /* ┘ */
        case 'k': return 0x2510; /* ┐ */
        case 'l': return 0x250C; /* ┌ */
        case 'm': return 0x2514; /* └ */
        case 'n': return 0x253C; /* ┼ */
        case 'q': return 0x2500; /* ─ */
        case 't': return 0x251C; /* ├ */
        case 'u': return 0x2524; /* ┤ */
        case 'v': return 0x2534; /* ┴ */
        case 'w': return 0x252C; /* ┬ */
        case 'x': return 0x2502; /* │ */
        case 'a': return 0x2592; /* ▒ */
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
            else if (t->cy < TERM_ROWS - 1)
                t->cy++;
        }
        t->wrap_pending = 0;
    }

    t->grid[t->cy][t->cx].ch = cp;
    t->grid[t->cy][t->cx].fg = (t->cur_attr & ATTR_BOLD) && t->cur_fg == ansi16_color(7)
                               ? ansi16_color(15) : t->cur_fg;
    t->grid[t->cy][t->cx].bg = t->cur_bg;
    t->grid[t->cy][t->cx].attr = t->cur_attr;

    if (t->cx < TERM_COLS - 1)
        t->cx++;
    else
        t->wrap_pending = 1;
}

static void term_handle_sgr(struct term_state *t, const int *p, int np)
{
    if (np == 0) {
        t->cur_fg = ansi16_color(7);
        t->cur_bg = ansi16_color(0);
        t->cur_attr = 0;
        return;
    }
    for (int i = 0; i < np; i++) {
        int v = p[i];
        if (v == 0) {
            t->cur_fg = ansi16_color(7);
            t->cur_bg = ansi16_color(0);
            t->cur_attr = 0;
        } else if (v == 1) t->cur_attr |= ATTR_BOLD;
        else if (v == 4) t->cur_attr |= ATTR_ULINE;
        else if (v == 7) t->cur_attr |= ATTR_REV;
        else if (v == 22) t->cur_attr &= (uint8_t)~ATTR_BOLD;
        else if (v == 24) t->cur_attr &= (uint8_t)~ATTR_ULINE;
        else if (v == 27) t->cur_attr &= (uint8_t)~ATTR_REV;
        else if (v >= 30 && v <= 37)
            t->cur_fg = ansi16_color((v - 30) + ((t->cur_attr & ATTR_BOLD) ? 8 : 0));
        else if (v == 39) t->cur_fg = ansi16_color(7);
        else if (v >= 40 && v <= 47) t->cur_bg = ansi16_color(v - 40);
        else if (v == 49) t->cur_bg = ansi16_color(0);
        else if (v >= 90 && v <= 97) t->cur_fg = ansi16_color(v - 90 + 8);
        else if (v >= 100 && v <= 107) t->cur_bg = ansi16_color(v - 100 + 8);
        else if ((v == 38 || v == 48) && i + 1 < np) {
            int is_fg = (v == 38);
            if (p[i + 1] == 5 && i + 2 < np) {
                uint16_t c = xterm256_color(p[i + 2]);
                if (is_fg) t->cur_fg = c; else t->cur_bg = c;
                i += 2;
            } else if (p[i + 1] == 2 && i + 4 < np) {
                uint16_t c = rgb565((uint8_t)p[i + 2], (uint8_t)p[i + 3], (uint8_t)p[i + 4]);
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
        term_clear_region(t, 0, 0, TERM_ROWS - 1, TERM_COLS - 1);
        t->cx = t->cy = 0;
    } else if (!enter && t->in_alt) {
        memcpy(t->grid, t->alt_grid, sizeof(t->grid));
        t->cx = t->alt_saved_cx;
        t->cy = t->alt_saved_cy;
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
        case 'B': t->cy += p0; if (t->cy >= TERM_ROWS) t->cy = TERM_ROWS - 1; t->wrap_pending = 0; break;
        case 'C': t->cx += p0; if (t->cx >= TERM_COLS) t->cx = TERM_COLS - 1; t->wrap_pending = 0; break;
        case 'D': t->cx -= p0; if (t->cx < 0) t->cx = 0; t->wrap_pending = 0; break;
        case 'E': t->cy += p0; if (t->cy >= TERM_ROWS) t->cy = TERM_ROWS - 1; t->cx = 0; t->wrap_pending = 0; break;
        case 'F': t->cy -= p0; if (t->cy < 0) t->cy = 0; t->cx = 0; t->wrap_pending = 0; break;
        case 'G': t->cx = p0 - 1; if (t->cx >= TERM_COLS) t->cx = TERM_COLS - 1; t->wrap_pending = 0; break;
        case 'd': t->cy = p0 - 1; if (t->cy >= TERM_ROWS) t->cy = TERM_ROWS - 1; t->wrap_pending = 0; break;
        case 'H':
        case 'f':
            t->cy = p0 - 1;
            t->cx = p1 - 1;
            if (t->cy < 0) t->cy = 0;
            if (t->cy >= TERM_ROWS) t->cy = TERM_ROWS - 1;
            if (t->cx < 0) t->cx = 0;
            if (t->cx >= TERM_COLS) t->cx = TERM_COLS - 1;
            t->wrap_pending = 0;
            break;
        case 'J': {
            int mode = (np >= 1) ? params[0] : 0;
            if (mode == 0) term_clear_region(t, t->cy, t->cx, TERM_ROWS - 1, TERM_COLS - 1);
            else if (mode == 1) term_clear_region(t, 0, 0, t->cy, t->cx);
            else term_clear_region(t, 0, 0, TERM_ROWS - 1, TERM_COLS - 1);
            break;
        }
        case 'K': {
            int mode = (np >= 1) ? params[0] : 0;
            if (mode == 0) term_clear_region(t, t->cy, t->cx, t->cy, TERM_COLS - 1);
            else if (mode == 1) term_clear_region(t, t->cy, 0, t->cy, t->cx);
            else term_clear_region(t, t->cy, 0, t->cy, TERM_COLS - 1);
            break;
        }
        case 'X': {
            int end = t->cx + p0 - 1;
            if (end >= TERM_COLS) end = TERM_COLS - 1;
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
            if (t->cx + n > TERM_COLS) n = TERM_COLS - t->cx;
            for (int c = TERM_COLS - 1; c >= t->cx + n; c--)
                t->grid[t->cy][c] = t->grid[t->cy][c - n];
            term_clear_region(t, t->cy, t->cx, t->cy, t->cx + n - 1);
            break;
        }
        case 'P': {
            int n = p0;
            if (t->cx + n > TERM_COLS) n = TERM_COLS - t->cx;
            for (int c = t->cx; c < TERM_COLS - n; c++)
                t->grid[t->cy][c] = t->grid[t->cy][c + n];
            term_clear_region(t, t->cy, TERM_COLS - n, t->cy, TERM_COLS - 1);
            break;
        }
        case 'S': term_scroll_up(t, t->scroll_top, t->scroll_bot, p0); break;
        case 'T': term_scroll_down(t, t->scroll_top, t->scroll_bot, p0); break;
        case 'r': {
            int top = (np >= 1 && params[0] > 0) ? params[0] - 1 : 0;
            int bot = (np >= 2 && params[1] > 0) ? params[1] - 1 : TERM_ROWS - 1;
            if (top >= 0 && bot < TERM_ROWS && top < bot) {
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
        if (t->state == 3) { /* OSC */
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
                else if (t->cy < TERM_ROWS - 1) t->cy++;
            } else if (b == 'M') {
                if (t->cy == t->scroll_top) term_scroll_down(t, t->scroll_top, t->scroll_bot, 1);
                else if (t->cy > 0) t->cy--;
            } else if (b == 'E') {
                t->cx = 0;
                if (t->cy == t->scroll_bot) term_scroll_up(t, t->scroll_top, t->scroll_bot, 1);
                else if (t->cy < TERM_ROWS - 1) t->cy++;
            } else if (b == 'c') {
                term_reset(t);
            }
            continue;
        }
        if (t->state == 5) {
            t->g0_acs = (b == '0');
            t->state = 0;
            continue;
        }
        if (t->state == 6) {
            t->state = 0;
            continue;
        }
        if (t->state == 2) {
            if (b >= 0x40 && b <= 0x7E) {
                term_exec_csi(t, (char)b, pty_fd);
                t->state = 0;
            } else if (t->csi_len < (int)sizeof(t->csi_buf) - 1) {
                t->csi_buf[t->csi_len++] = (char)b;
            }
            continue;
        }

        /* C0 control characters */
        if (b == '\r') { t->cx = 0; t->wrap_pending = 0; continue; }
        if (b == '\n' || b == '\v' || b == '\f') {
            t->wrap_pending = 0;
            if (t->cy == t->scroll_bot) term_scroll_up(t, t->scroll_top, t->scroll_bot, 1);
            else if (t->cy < TERM_ROWS - 1) t->cy++;
            continue;
        }
        if (b == '\b' || b == 0x7F) {
            if (t->cx > 0) t->cx--;
            t->wrap_pending = 0;
            continue;
        }
        if (b == '\t') {
            int next = (t->cx + 8) & ~7;
            if (next >= TERM_COLS) next = TERM_COLS - 1;
            t->cx = next;
            t->wrap_pending = 0;
            continue;
        }
        if (b == 0x0E) { t->g0_acs = 1; continue; }
        if (b == 0x0F) { t->g0_acs = 0; continue; }
        if (b < 0x20) continue;

        /* UTF-8 decoding */
        if (t->utf8_rem > 0) {
            if ((b & 0xC0) == 0x80) {
                t->utf8_cp = (t->utf8_cp << 6) | (b & 0x3F);
                if (--t->utf8_rem == 0) {
                    /* Ignore zero-width / combining marks */
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

/* Render a single 4x7 cell including box-drawing & block-element codepoints */
static void draw_cell4x7(int px, int py, const struct cell *c, int is_cursor)
{
    uint16_t fg = c->fg;
    uint16_t bg = c->bg;
    if (c->attr & ATTR_REV) { uint16_t tmp = fg; fg = bg; bg = tmp; }
    if (is_cursor) { fg = COL_BLACK; bg = COL_GREEN; }

    fill_rect(px, py, CELL_W, CELL_H, bg);
    uint32_t cp = c->ch;

    if (cp >= 0x20 && cp <= 0x7E) {
        const uint8_t *g = FONT3X6[cp - 0x20];
        for (int ry = 0; ry < 6; ry++) {
            uint8_t bits = g[ry];
            if (!bits) continue;
            uint16_t *row = &g_buf[(py + ry) * LCD_W + px];
            if (bits & 4) row[0] = fg;
            if (bits & 2) row[1] = fg;
            if (bits & 1) row[2] = fg;
        }
    } else if (cp >= 0x2500 && cp <= 0x257F) {
        /* Box-drawing primitives */
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
        if (h_left)  fill_rect(px, py + 3, 2, 1, fg);
        if (h_right) fill_rect(px + 1, py + 3, 3, 1, fg);
        if (v_up)    fill_rect(px + 1, py, 1, 4, fg);
        if (v_dn)    fill_rect(px + 1, py + 3, 1, 4, fg);
    } else if (cp >= 0x2580 && cp <= 0x259F) {
        /* Block elements (used heavily by btop / htop / progress bars) */
        if (cp == 0x2580) fill_rect(px, py, 4, 3, fg);
        else if (cp >= 0x2581 && cp <= 0x2588) {
            int h = ((int)(cp - 0x2580) * 7 + 4) / 8;
            if (h < 1) h = 1;
            fill_rect(px, py + 7 - h, 4, h, fg);
        } else if (cp >= 0x2589 && cp <= 0x258F) {
            int w = ((int)(0x2590 - cp) * 4 + 4) / 8;
            if (w < 1) w = 1;
            fill_rect(px, py, w, 7, fg);
        } else if (cp == 0x2590) fill_rect(px + 2, py, 2, 7, fg);
        else if (cp == 0x2591 || cp == 0x2592 || cp == 0x2593) {
            int step = (cp == 0x2591) ? 3 : 2;
            for (int ry = 0; ry < 7; ry++)
                for (int rx = 0; rx < 4; rx++)
                    if (((rx + ry) % step) == 0)
                        g_buf[(py + ry) * LCD_W + px + rx] = fg;
        } else {
            fill_rect(px, py, 4, 7, fg);
        }
    } else if (cp >= 0x2800 && cp <= 0x28FF) {
        /* Unicode Braille patterns (used by btop CPU/net graphs!) */
        uint8_t br = (uint8_t)(cp - 0x2800);
        static const int dy[4] = { 0, 2, 4, 5 };
        for (int row = 0; row < 3; row++) {
            if (br & (1 << row))       g_buf[(py + dy[row]) * LCD_W + px] = fg;
            if (br & (1 << (row + 3))) g_buf[(py + dy[row]) * LCD_W + px + 2] = fg;
        }
        if (br & 0x40) g_buf[(py + dy[3]) * LCD_W + px] = fg;
        if (br & 0x80) g_buf[(py + dy[3]) * LCD_W + px + 2] = fg;
    } else if (cp > 0x7E) {
        /* Generic bullet/symbol fallback */
        fill_rect(px + 1, py + 2, 2, 2, fg);
    }

    if (c->attr & ATTR_ULINE)
        fill_rect(px, py + 6, 3, 1, fg);
}

static void render_term(const struct term_state *t)
{
    fill_rect(0, 0, LCD_W, LCD_H, t->cur_bg);
    for (int r = 0; r < TERM_ROWS; r++) {
        int py = Y_PAD + r * CELL_H;
        for (int c = 0; c < TERM_COLS; c++) {
            int is_cur = t->cursor_vis && (r == t->cy && c == t->cx);
            draw_cell4x7(c * CELL_W, py, &t->grid[r][c], is_cur);
        }
    }
}

/* Evdev keycode -> ASCII (unshifted, shifted) */
static int keycode_to_ascii(int code, int shift)
{
    switch (code) {
        case KEY_A: return shift ? 'A' : 'a';
        case KEY_B: return shift ? 'B' : 'b';
        case KEY_C: return shift ? 'C' : 'c';
        case KEY_D: return shift ? 'D' : 'd';
        case KEY_E: return shift ? 'E' : 'e';
        case KEY_F: return shift ? 'F' : 'f';
        case KEY_G: return shift ? 'G' : 'g';
        case KEY_H: return shift ? 'H' : 'h';
        case KEY_I: return shift ? 'I' : 'i';
        case KEY_J: return shift ? 'J' : 'j';
        case KEY_K: return shift ? 'K' : 'k';
        case KEY_L: return shift ? 'L' : 'l';
        case KEY_M: return shift ? 'M' : 'm';
        case KEY_N: return shift ? 'N' : 'n';
        case KEY_O: return shift ? 'O' : 'o';
        case KEY_P: return shift ? 'P' : 'p';
        case KEY_Q: return shift ? 'Q' : 'q';
        case KEY_R: return shift ? 'R' : 'r';
        case KEY_S: return shift ? 'S' : 's';
        case KEY_T: return shift ? 'T' : 't';
        case KEY_U: return shift ? 'U' : 'u';
        case KEY_V: return shift ? 'V' : 'v';
        case KEY_W: return shift ? 'W' : 'w';
        case KEY_X: return shift ? 'X' : 'x';
        case KEY_Y: return shift ? 'Y' : 'y';
        case KEY_Z: return shift ? 'Z' : 'z';
        case KEY_1: return shift ? '!' : '1';
        case KEY_2: return shift ? '@' : '2';
        case KEY_3: return shift ? '#' : '3';
        case KEY_4: return shift ? '$' : '4';
        case KEY_5: return shift ? '%' : '5';
        case KEY_6: return shift ? '^' : '6';
        case KEY_7: return shift ? '&' : '7';
        case KEY_8: return shift ? '*' : '8';
        case KEY_9: return shift ? '(' : '9';
        case KEY_0: return shift ? ')' : '0';
        case KEY_MINUS: return shift ? '_' : '-';
        case KEY_EQUAL: return shift ? '+' : '=';
        case KEY_LEFTBRACE: return shift ? '{' : '[';
        case KEY_RIGHTBRACE: return shift ? '}' : ']';
        case KEY_BACKSLASH: return shift ? '|' : '\\';
        case KEY_SEMICOLON: return shift ? ':' : ';';
        case KEY_APOSTROPHE: return shift ? '"' : '\'';
        case KEY_GRAVE: return shift ? '~' : '`';
        case KEY_COMMA: return shift ? '<' : ',';
        case KEY_DOT: return shift ? '>' : '.';
        case KEY_SLASH: return shift ? '?' : '/';
        case KEY_SPACE: return ' ';
        default: return 0;
    }
}

static void send_key_to_pty(int pty_fd, const struct term_state *t,
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
        case KEY_PAGEUP:   memcpy(seq, "\x1b[5~", 4); slen = 4; break;
        case KEY_PAGEDOWN: memcpy(seq, "\x1b[6~", 4); slen = 4; break;
        case KEY_DELETE:   memcpy(seq, "\x1b[3~", 4); slen = 4; break;
        default: {
            int ch = keycode_to_ascii(code, shift);
            if (ch > 0) {
                if (ctrl) {
                    if (ch >= 'a' && ch <= 'z') ch = ch - 'a' + 1;
                    else if (ch >= 'A' && ch <= 'Z') ch = ch - 'A' + 1;
                    else if (ch == ' ' || ch == '@') ch = 0;
                    else if (ch == '[') ch = 27;
                    else if (ch == '\\') ch = 28;
                    else if (ch == ']') ch = 29;
                }
                if (alt) {
                    seq[0] = 0x1B;
                    seq[1] = (char)ch;
                    slen = 2;
                } else {
                    seq[0] = (char)ch;
                    slen = 1;
                }
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

    struct term_state *ts = calloc(1, sizeof(*ts));
    if (!ts) return 1;
    term_reset(ts);

    const char *dump_path = getenv("CZ_DUMP_PPM");
    if (dump_path) {
        const char *demo =
            "\x1b[1;36m┌─── KALI TERM80x24 (320x170 @ 4x7px) ─────────────────────────────────────────┐\x1b[0m\r\n"
            "\x1b[1;34m│\x1b[0m \x1b[1;32mkali@cardputerzero\x1b[0m:\x1b[1;34m~\x1b[0m$ stty size                                              \x1b[1;34m│\x1b[0m\r\n"
            "\x1b[1;34m│\x1b[0m 24 80  (btop / htop / kismet / nmtui / tmux ready — Hold ESC 1.2s to exit)   \x1b[1;34m│\x1b[0m\r\n"
            "\x1b[1;36m└──────────────────────────────────────────────────────────────────────────────┘\x1b[0m\r\n";
        term_feed(ts, (const uint8_t *)demo, strlen(demo), -1);
        render_term(ts);
        int rc = cz_dump_ppm(dump_path);
        free(ts);
        return rc == 0 ? 0 : 1;
    }

    struct cz_fb fb;
    if (cz_fb_open(&fb) != 0) {
        fprintf(stderr, "cz-term80: cannot open /dev/fb_lcd\n");
        free(ts);
        return 1;
    }

    struct winsize ws = {
        .ws_row = TERM_ROWS,
        .ws_col = TERM_COLS,
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
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("COLUMNS", "80", 1);
        setenv("LINES", "24", 1);
        unsetenv("LD_PRELOAD");
        if (argc > 1) {
            execvp(argv[1], &argv[1]);
        } else {
            const char *sh = getenv("SHELL");
            if (!sh || !*sh) sh = "/usr/bin/zsh";
            execl(sh, sh, "-l", (char *)NULL);
            execl("/bin/bash", "bash", "-l", (char *)NULL);
        }
        _exit(127);
    }

    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

    int in_fds[CZ_MAX_INPUT_FDS];
    int n_in = cz_inputs_open(in_fds, CZ_MAX_INPUT_FDS);

    int shift = 0, ctrl = 0, alt = 0;
    double esc_down_at = 0.0;
    int dirty = 1;

    while (g_running && !g_child_dead) {
        if (dirty) {
            render_term(ts);
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
        if (esc_down_at > 0.0 && (cz_mono_sec() - esc_down_at) >= 1.2) {
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
                if (ev.code == KEY_LEFTSHIFT || ev.code == KEY_RIGHTSHIFT) {
                    shift = (ev.value != 0);
                    continue;
                }
                if (ev.code == KEY_LEFTCTRL || ev.code == KEY_RIGHTCTRL) {
                    ctrl = (ev.value != 0);
                    continue;
                }
                if (ev.code == KEY_LEFTALT || ev.code == KEY_RIGHTALT) {
                    alt = (ev.value != 0);
                    continue;
                }
                if (ev.code == KEY_ESC) {
                    if (ev.value == 1) esc_down_at = cz_mono_sec();
                    else if (ev.value == 0) esc_down_at = 0.0;
                }
                if (ev.value != 1 && ev.value != 2) continue;
                if (ctrl && alt && ev.code == KEY_Q) {
                    g_running = 0;
                    break;
                }
                send_key_to_pty(master_fd, ts, ev.code, shift, ctrl, alt);
            }
        }
    }

    kill(pid, SIGHUP);
    waitpid(pid, NULL, WNOHANG);
    close(master_fd);
    cz_inputs_close(in_fds, n_in);
    cz_fb_close(&fb);
    free(ts);
    return 0;
}
