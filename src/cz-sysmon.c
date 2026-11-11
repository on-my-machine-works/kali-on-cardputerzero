/*
 * cz-sysmon.c — Native 320x170 RGB565 Graphical System & Hardware Monitor
 *               for Kali Linux on M5Stack CardputerZero
 *
 * Targets the 1.9" ST7789v3 IPS LCD (320x170 @ /dev/fb_lcd).
 *
 * Controls (TCA8418 I2C keyboard, opened non-exclusively without EVIOCGRAB):
 *   1 / 2 / 3          Switch directly to [1:SYS] [2:NET/HW] [3:TOP]
 *   , . / Arrows / Tab Cycle tabs
 *   m                  Toggle CPU% / MEM% sort on [3:TOP]
 *   g / e              Toggle Grove 5V / Ext 14P 5V rails on [2:NET/HW]
 *   q / ESC / ` / Bksp Exit cleanly back to APPLaunch
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#define LCD_W 320
#define LCD_H 170
#define MAX_CORES 4
#define HIST_LEN 64
#define MAX_INPUT_FDS 12
#define MAX_PROCS 512
#define TOP_ROWS 11

static volatile sig_atomic_t g_running = 1;

static void on_sig(int sig)
{
    (void)sig;
    g_running = 0;
}

static inline uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

/* Kali Dark Palette */
#define COL_BG         rgb565(8, 12, 22)
#define COL_PANEL      rgb565(15, 22, 38)
#define COL_BORDER     rgb565(34, 56, 92)
#define COL_HDR_BG     rgb565(14, 34, 68)
#define COL_TAB_ACT    rgb565(44, 132, 245)
#define COL_TAB_IDLE   rgb565(22, 38, 66)
#define COL_TEXT       rgb565(235, 243, 255)
#define COL_DIM        rgb565(128, 152, 185)
#define COL_CYAN       rgb565(56, 188, 255)
#define COL_GREEN      rgb565(38, 218, 132)
#define COL_YELLOW     rgb565(250, 196, 48)
#define COL_RED        rgb565(248, 78, 92)
#define COL_PURPLE     rgb565(178, 102, 255)
#define COL_BAR_BG     rgb565(24, 34, 54)

/* Compact 5x7 ASCII font (0x20..0x7E), 5 columns per glyph, LSB = top row */
static const uint8_t FONT5X7[95][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x00,0x00,0x5F,0x00,0x00}, /* '!' */
    {0x00,0x07,0x00,0x07,0x00}, /* '"' */
    {0x14,0x7F,0x14,0x7F,0x14}, /* '#' */
    {0x24,0x2A,0x7F,0x2A,0x12}, /* '$' */
    {0x23,0x13,0x08,0x64,0x62}, /* '%' */
    {0x36,0x49,0x55,0x22,0x50}, /* '&' */
    {0x00,0x05,0x03,0x00,0x00}, /* '\'' */
    {0x00,0x1C,0x22,0x41,0x00}, /* '(' */
    {0x00,0x41,0x22,0x1C,0x00}, /* ')' */
    {0x14,0x08,0x3E,0x08,0x14}, /* '*' */
    {0x08,0x08,0x3E,0x08,0x08}, /* '+' */
    {0x00,0x50,0x30,0x00,0x00}, /* ',' */
    {0x08,0x08,0x08,0x08,0x08}, /* '-' */
    {0x00,0x60,0x60,0x00,0x00}, /* '.' */
    {0x20,0x10,0x08,0x04,0x02}, /* '/' */
    {0x3E,0x51,0x49,0x45,0x3E}, /* '0' */
    {0x00,0x42,0x7F,0x40,0x00}, /* '1' */
    {0x42,0x61,0x51,0x49,0x46}, /* '2' */
    {0x21,0x41,0x45,0x4B,0x31}, /* '3' */
    {0x18,0x14,0x12,0x7F,0x10}, /* '4' */
    {0x27,0x45,0x45,0x45,0x39}, /* '5' */
    {0x3C,0x4A,0x49,0x49,0x30}, /* '6' */
    {0x01,0x71,0x09,0x05,0x03}, /* '7' */
    {0x36,0x49,0x49,0x49,0x36}, /* '8' */
    {0x06,0x49,0x49,0x29,0x1E}, /* '9' */
    {0x00,0x36,0x36,0x00,0x00}, /* ':' */
    {0x00,0x56,0x36,0x00,0x00}, /* ';' */
    {0x08,0x14,0x22,0x41,0x00}, /* '<' */
    {0x14,0x14,0x14,0x14,0x14}, /* '=' */
    {0x00,0x41,0x22,0x14,0x08}, /* '>' */
    {0x02,0x01,0x51,0x09,0x06}, /* '?' */
    {0x32,0x49,0x79,0x41,0x3E}, /* '@' */
    {0x7E,0x11,0x11,0x11,0x7E}, /* 'A' */
    {0x7F,0x49,0x49,0x49,0x36}, /* 'B' */
    {0x3E,0x41,0x41,0x41,0x22}, /* 'C' */
    {0x7F,0x41,0x41,0x22,0x1C}, /* 'D' */
    {0x7F,0x49,0x49,0x49,0x41}, /* 'E' */
    {0x7F,0x09,0x09,0x09,0x01}, /* 'F' */
    {0x3E,0x41,0x49,0x49,0x7A}, /* 'G' */
    {0x7F,0x08,0x08,0x08,0x7F}, /* 'H' */
    {0x00,0x41,0x7F,0x41,0x00}, /* 'I' */
    {0x20,0x40,0x41,0x3F,0x01}, /* 'J' */
    {0x7F,0x08,0x14,0x22,0x41}, /* 'K' */
    {0x7F,0x40,0x40,0x40,0x40}, /* 'L' */
    {0x7F,0x02,0x0C,0x02,0x7F}, /* 'M' */
    {0x7F,0x04,0x08,0x10,0x7F}, /* 'N' */
    {0x3E,0x41,0x41,0x41,0x3E}, /* 'O' */
    {0x7F,0x09,0x09,0x09,0x06}, /* 'P' */
    {0x3E,0x41,0x51,0x21,0x5E}, /* 'Q' */
    {0x7F,0x09,0x19,0x29,0x46}, /* 'R' */
    {0x46,0x49,0x49,0x49,0x31}, /* 'S' */
    {0x01,0x01,0x7F,0x01,0x01}, /* 'T' */
    {0x3F,0x40,0x40,0x40,0x3F}, /* 'U' */
    {0x1F,0x20,0x40,0x20,0x1F}, /* 'V' */
    {0x3F,0x40,0x38,0x40,0x3F}, /* 'W' */
    {0x63,0x14,0x08,0x14,0x63}, /* 'X' */
    {0x07,0x08,0x70,0x08,0x07}, /* 'Y' */
    {0x61,0x51,0x49,0x45,0x43}, /* 'Z' */
    {0x00,0x7F,0x41,0x41,0x00}, /* '[' */
    {0x02,0x04,0x08,0x10,0x20}, /* '\\' */
    {0x00,0x41,0x41,0x7F,0x00}, /* ']' */
    {0x04,0x02,0x01,0x02,0x04}, /* '^' */
    {0x40,0x40,0x40,0x40,0x40}, /* '_' */
    {0x00,0x01,0x02,0x04,0x00}, /* '`' */
    {0x20,0x54,0x54,0x54,0x78}, /* 'a' */
    {0x7F,0x48,0x44,0x44,0x38}, /* 'b' */
    {0x38,0x44,0x44,0x44,0x20}, /* 'c' */
    {0x38,0x44,0x44,0x48,0x7F}, /* 'd' */
    {0x38,0x54,0x54,0x54,0x18}, /* 'e' */
    {0x08,0x7E,0x09,0x01,0x02}, /* 'f' */
    {0x0C,0x52,0x52,0x52,0x3E}, /* 'g' */
    {0x7F,0x08,0x04,0x04,0x78}, /* 'h' */
    {0x00,0x44,0x7D,0x40,0x00}, /* 'i' */
    {0x20,0x40,0x44,0x3D,0x00}, /* 'j' */
    {0x7F,0x10,0x28,0x44,0x00}, /* 'k' */
    {0x00,0x41,0x7F,0x40,0x00}, /* 'l' */
    {0x7C,0x04,0x18,0x04,0x78}, /* 'm' */
    {0x7C,0x08,0x04,0x04,0x78}, /* 'n' */
    {0x38,0x44,0x44,0x44,0x38}, /* 'o' */
    {0x7C,0x14,0x14,0x14,0x08}, /* 'p' */
    {0x08,0x14,0x14,0x18,0x7C}, /* 'q' */
    {0x7C,0x08,0x04,0x04,0x08}, /* 'r' */
    {0x48,0x54,0x54,0x54,0x20}, /* 's' */
    {0x04,0x3F,0x44,0x40,0x20}, /* 't' */
    {0x3C,0x40,0x40,0x20,0x7C}, /* 'u' */
    {0x1C,0x20,0x40,0x20,0x1C}, /* 'v' */
    {0x3C,0x40,0x30,0x40,0x3C}, /* 'w' */
    {0x44,0x28,0x10,0x28,0x44}, /* 'x' */
    {0x0C,0x50,0x50,0x50,0x3C}, /* 'y' */
    {0x44,0x64,0x54,0x4C,0x44}, /* 'z' */
    {0x00,0x08,0x36,0x41,0x00}, /* '{' */
    {0x00,0x00,0x7F,0x00,0x00}, /* '|' */
    {0x00,0x41,0x36,0x08,0x00}, /* '}' */
    {0x08,0x04,0x08,0x10,0x08}, /* '~' */
};

static uint16_t g_buf[LCD_H * LCD_W];

static void fill_rect(int x, int y, int w, int h, uint16_t col)
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

static void draw_rect(int x, int y, int w, int h, uint16_t col)
{
    fill_rect(x, y, w, 1, col);
    fill_rect(x, y + h - 1, w, 1, col);
    fill_rect(x, y, 1, h, col);
    fill_rect(x + w - 1, y, 1, h, col);
}

static void draw_str(int x, int y, const char *s, uint16_t col)
{
    for (; *s; s++, x += 6) {
        if (x > LCD_W - 5) break;
        unsigned char uc = (unsigned char)*s;
        if (uc < 32 || uc > 126) uc = '?';
        const uint8_t *g = FONT5X7[uc - 32];
        for (int cx = 0; cx < 5; cx++) {
            uint8_t bits = g[cx];
            int px = x + cx;
            if (px < 0 || px >= LCD_W) continue;
            for (int cy = 0; cy < 7; cy++) {
                if ((bits >> cy) & 1) {
                    int py = y + cy;
                    if (py >= 0 && py < LCD_H)
                        g_buf[py * LCD_W + px] = col;
                }
            }
        }
    }
}

static uint16_t pct_color(int pct)
{
    if (pct >= 85) return COL_RED;
    if (pct >= 65) return COL_YELLOW;
    return COL_GREEN;
}

static void draw_bar(int x, int y, int w, int h, int pct, uint16_t fg)
{
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    fill_rect(x, y, w, h, COL_BAR_BG);
    int fw = (w * pct) / 100;
    if (fw > 0) fill_rect(x, y, fw, h, fg);
    draw_rect(x, y, w, h, COL_BORDER);
}

/* ─── Metrics Collectors ─────────────────────────────────────────────────── */

struct cpu_snap {
    uint64_t total[MAX_CORES + 1];
    uint64_t busy[MAX_CORES + 1];
    int cores;
};

static void read_cpu_snap(struct cpu_snap *s)
{
    memset(s, 0, sizeof(*s));
    FILE *fp = fopen("/proc/stat", "r");
    if (!fp) return;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        int idx = -1;
        uint64_t u=0, n=0, sy=0, id=0, io=0, ir=0, si=0, st=0;
        if (strncmp(line, "cpu ", 4) == 0) {
            idx = 0;
            if (sscanf(line + 4, "%lu %lu %lu %lu %lu %lu %lu %lu",
                       &u, &n, &sy, &id, &io, &ir, &si, &st) < 4)
                continue;
        } else if (strncmp(line, "cpu", 3) == 0 && isdigit((unsigned char)line[3])) {
            int c = atoi(line + 3);
            if (c < 0 || c >= MAX_CORES) continue;
            idx = c + 1;
            if (c + 1 > s->cores) s->cores = c + 1;
            char *sp = strchr(line, ' ');
            if (!sp || sscanf(sp, "%lu %lu %lu %lu %lu %lu %lu %lu",
                              &u, &n, &sy, &id, &io, &ir, &si, &st) < 4)
                continue;
        } else {
            continue;
        }
        uint64_t busy = u + n + sy + ir + si + st;
        uint64_t tot = busy + id + io;
        s->busy[idx] = busy;
        s->total[idx] = tot;
    }
    fclose(fp);
}

static int read_int_file(const char *path, long *out)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;
    int ok = (fscanf(fp, "%ld", out) == 1) ? 0 : -1;
    fclose(fp);
    return ok;
}

static int read_str_file(const char *path, char *buf, size_t sz)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;
    if (!fgets(buf, (int)sz, fp)) { fclose(fp); return -1; }
    fclose(fp);
    size_t l = strlen(buf);
    while (l > 0 && (buf[l - 1] == '\n' || buf[l - 1] == '\r')) buf[--l] = '\0';
    return 0;
}

struct sys_stats {
    int cpu_pct[MAX_CORES + 1]; /* [0]=avg, [1..4]=cores */
    int cores;
    int temp_c;
    int freq_mhz;
    long mem_used_mb, mem_tot_mb;
    long swp_used_mb, swp_tot_mb;
    double disk_used_gb, disk_tot_gb;
    int disk_pct;
    double load1, load5;
    long uptime_s;
};

static void collect_sys(const struct cpu_snap *prev, const struct cpu_snap *cur, struct sys_stats *st)
{
    memset(st, 0, sizeof(*st));
    st->cores = cur->cores > 0 ? cur->cores : 4;
    for (int i = 0; i <= MAX_CORES; i++) {
        uint64_t dt = cur->total[i] - prev->total[i];
        uint64_t db = cur->busy[i] - prev->busy[i];
        st->cpu_pct[i] = dt > 0 ? (int)((db * 100ULL + dt / 2) / dt) : 0;
        if (st->cpu_pct[i] > 100) st->cpu_pct[i] = 100;
    }

    long v = 0;
    if (read_int_file("/sys/class/thermal/thermal_zone0/temp", &v) == 0)
        st->temp_c = (int)((v + 500) / 1000);
    if (read_int_file("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", &v) == 0)
        st->freq_mhz = (int)(v / 1000);

    FILE *fp = fopen("/proc/meminfo", "r");
    if (fp) {
        long mt=0, ma=0, stot=0, sfree=0;
        char line[128];
        while (fgets(line, sizeof(line), fp)) {
            sscanf(line, "MemTotal: %ld kB", &mt);
            sscanf(line, "MemAvailable: %ld kB", &ma);
            sscanf(line, "SwapTotal: %ld kB", &stot);
            sscanf(line, "SwapFree: %ld kB", &sfree);
        }
        fclose(fp);
        st->mem_tot_mb = mt / 1024;
        st->mem_used_mb = (mt - ma) / 1024;
        st->swp_tot_mb = stot / 1024;
        st->swp_used_mb = (stot - sfree) / 1024;
    }

    struct statvfs vfs;
    if (statvfs("/", &vfs) == 0 && vfs.f_blocks > 0) {
        double tot = (double)vfs.f_blocks * vfs.f_frsize;
        double avail = (double)vfs.f_bavail * vfs.f_frsize;
        double used = tot - avail;
        st->disk_tot_gb = tot / (1024.0 * 1024.0 * 1024.0);
        st->disk_used_gb = used / (1024.0 * 1024.0 * 1024.0);
        st->disk_pct = (int)((used * 100.0) / tot + 0.5);
    }

    fp = fopen("/proc/loadavg", "r");
    if (fp) {
        if (fscanf(fp, "%lf %lf", &st->load1, &st->load5) != 2) {
            st->load1 = st->load5 = 0.0;
        }
        fclose(fp);
    }
    fp = fopen("/proc/uptime", "r");
    if (fp) {
        double up = 0;
        if (fscanf(fp, "%lf", &up) == 1) st->uptime_s = (long)up;
        fclose(fp);
    }
}

struct net_dev_snap {
    char name[16];
    uint64_t rx_bytes;
    uint64_t tx_bytes;
};

struct net_row {
    char name[16];
    char ip[24];
    int up;
    double rx_kbs;
    double tx_kbs;
};

static int read_net_snaps(struct net_dev_snap *out, int max_n)
{
    FILE *fp = fopen("/proc/net/dev", "r");
    if (!fp) return 0;
    char line[256];
    int n = 0;
    /* skip 2 header lines */
    if (!fgets(line, sizeof(line), fp) || !fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }
    while (n < max_n && fgets(line, sizeof(line), fp)) {
        char *colon = strchr(line, ':');
        if (!colon) continue;
        *colon = '\0';
        char *nm = line;
        while (*nm == ' ') nm++;
        if (strcmp(nm, "lo") == 0) continue;
        uint64_t rxb = 0, txb = 0, d;
        if (sscanf(colon + 1, "%lu %lu %lu %lu %lu %lu %lu %lu %lu",
                   &rxb, &d, &d, &d, &d, &d, &d, &d, &txb) == 9) {
            snprintf(out[n].name, sizeof(out[n].name), "%.15s", nm);
            out[n].rx_bytes = rxb;
            out[n].tx_bytes = txb;
            n++;
        }
    }
    fclose(fp);
    return n;
}

static int build_net_rows(const struct net_dev_snap *prev, int prev_n,
                          const struct net_dev_snap *cur, int cur_n,
                          double dt_sec, struct net_row *rows, int max_rows)
{
    struct ifaddrs *ifa = NULL;
    getifaddrs(&ifa);
    int out_n = 0;
    for (int i = 0; i < cur_n && out_n < max_rows; i++) {
        struct net_row *r = &rows[out_n++];
        memset(r, 0, sizeof(*r));
        snprintf(r->name, sizeof(r->name), "%.15s", cur[i].name);
        snprintf(r->ip, sizeof(r->ip), "-");
        for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
            if (!p->ifa_name || strcmp(p->ifa_name, r->name) != 0) continue;
            if (p->ifa_flags & IFF_UP) r->up = 1;
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
                inet_ntop(AF_INET, &sin->sin_addr, r->ip, sizeof(r->ip));
            }
        }
        if (dt_sec > 0.05) {
            for (int j = 0; j < prev_n; j++) {
                if (strcmp(prev[j].name, cur[i].name) == 0) {
                    if (cur[i].rx_bytes >= prev[j].rx_bytes)
                        r->rx_kbs = (double)(cur[i].rx_bytes - prev[j].rx_bytes) / 1024.0 / dt_sec;
                    if (cur[i].tx_bytes >= prev[j].tx_bytes)
                        r->tx_kbs = (double)(cur[i].tx_bytes - prev[j].tx_bytes) / 1024.0 / dt_sec;
                    break;
                }
            }
        }
    }
    if (ifa) freeifaddrs(ifa);
    return out_n;
}

struct batt_info {
    int present;
    int cap_pct;
    long volt_mv;
    long curr_ma;
    char status[20];
};

static void read_battery(struct batt_info *b)
{
    memset(b, 0, sizeof(*b));
    snprintf(b->status, sizeof(b->status), "N/A");
    DIR *d = opendir("/sys/class/power_supply");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char p[512], type[32];
        snprintf(p, sizeof(p), "/sys/class/power_supply/%.128s/type", de->d_name);
        if (read_str_file(p, type, sizeof(type)) != 0 || strcmp(type, "Battery") != 0)
            continue;
        b->present = 1;
        long v = 0;
        snprintf(p, sizeof(p), "/sys/class/power_supply/%.128s/capacity", de->d_name);
        if (read_int_file(p, &v) == 0) b->cap_pct = (int)v;
        snprintf(p, sizeof(p), "/sys/class/power_supply/%.128s/voltage_now", de->d_name);
        if (read_int_file(p, &v) == 0) b->volt_mv = v / 1000;
        snprintf(p, sizeof(p), "/sys/class/power_supply/%.128s/current_now", de->d_name);
        if (read_int_file(p, &v) == 0) b->curr_ma = v / 1000;
        snprintf(p, sizeof(p), "/sys/class/power_supply/%.128s/status", de->d_name);
        read_str_file(p, b->status, sizeof(b->status));
        break;
    }
    closedir(d);
}

static void toggle_led_rail(const char *rail)
{
    char p[128];
    snprintf(p, sizeof(p), "/sys/class/leds/%s/brightness", rail);
    long cur = 0;
    read_int_file(p, &cur);
    int fd = open(p, O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        const char *nv = (cur == 0) ? "1\n" : "0\n";
        ssize_t wr = write(fd, nv, 2);
        (void)wr;
        close(fd);
    }
}

/* ─── Top Processes Collector ────────────────────────────────────────────── */

struct proc_tick {
    int pid;
    uint64_t ticks;
    long rss_kb;
    char comm[24];
};

struct proc_row {
    int pid;
    double cpu_pct;
    double mem_pct;
    char comm[24];
};

static int g_sort_by_mem = 0;

static int read_proc_ticks(struct proc_tick *out, int max_n)
{
    DIR *d = opendir("/proc");
    if (!d) return 0;
    long page_kb = sysconf(_SC_PAGESIZE) / 1024;
    if (page_kb <= 0) page_kb = 4;
    struct dirent *de;
    int n = 0;
    while (n < max_n && (de = readdir(d))) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int pid = atoi(de->d_name);
        if (pid <= 0) continue;
        char path[64], buf[512];
        snprintf(path, sizeof(path), "/proc/%d/stat", pid);
        FILE *fp = fopen(path, "r");
        if (!fp) continue;
        size_t rd = fread(buf, 1, sizeof(buf) - 1, fp);
        fclose(fp);
        if (rd == 0) continue;
        buf[rd] = '\0';
        char *lp = strchr(buf, '(');
        char *rp = strrchr(buf, ')');
        if (!lp || !rp || rp <= lp) continue;
        size_t clen = (size_t)(rp - lp - 1);
        if (clen >= sizeof(out[n].comm)) clen = sizeof(out[n].comm) - 1;
        memcpy(out[n].comm, lp + 1, clen);
        out[n].comm[clen] = '\0';

        /* Fields after ") ": state(3) ppid(4) ... utime(14) stime(15) ... rss(24) */
        unsigned long utime = 0, stime = 0;
        long rss = 0;
        char *tok = rp + 2;
        int fld = 3;
        while (*tok && fld <= 24) {
            if (fld == 14) utime = strtoul(tok, NULL, 10);
            else if (fld == 15) stime = strtoul(tok, NULL, 10);
            else if (fld == 24) { rss = strtol(tok, NULL, 10); break; }
            while (*tok && *tok != ' ') tok++;
            while (*tok == ' ') tok++;
            fld++;
        }
        out[n].pid = pid;
        out[n].ticks = (uint64_t)utime + (uint64_t)stime;
        out[n].rss_kb = rss > 0 ? rss * page_kb : 0;
        n++;
    }
    closedir(d);
    return n;
}

static int cmp_proc_row(const void *a, const void *b)
{
    const struct proc_row *pa = (const struct proc_row *)a;
    const struct proc_row *pb = (const struct proc_row *)b;
    double va = g_sort_by_mem ? pa->mem_pct : pa->cpu_pct;
    double vb = g_sort_by_mem ? pb->mem_pct : pb->cpu_pct;
    if (vb > va) return 1;
    if (vb < va) return -1;
    return (pb->mem_pct > pa->mem_pct) ? 1 : -1;
}

static int build_top_procs(const struct proc_tick *prev, int prev_n,
                           const struct proc_tick *cur, int cur_n,
                           uint64_t total_cpu_dt, int ncores, long mem_tot_kb,
                           struct proc_row *rows, int max_out)
{
    struct proc_row *tmp = calloc((size_t)(cur_n > 0 ? cur_n : 1), sizeof(*tmp));
    if (!tmp) return 0;
    int cnt = 0;
    for (int i = 0; i < cur_n; i++) {
        uint64_t dt = 0;
        for (int j = 0; j < prev_n; j++) {
            if (prev[j].pid == cur[i].pid) {
                if (cur[i].ticks >= prev[j].ticks)
                    dt = cur[i].ticks - prev[j].ticks;
                break;
            }
        }
        tmp[cnt].pid = cur[i].pid;
        snprintf(tmp[cnt].comm, sizeof(tmp[cnt].comm), "%s", cur[i].comm);
        tmp[cnt].cpu_pct = (total_cpu_dt > 0)
            ? ((double)dt * 100.0 * (double)(ncores > 0 ? ncores : 1)) / (double)total_cpu_dt
            : 0.0;
        tmp[cnt].mem_pct = (mem_tot_kb > 0)
            ? ((double)cur[i].rss_kb * 100.0) / (double)mem_tot_kb
            : 0.0;
        cnt++;
    }
    qsort(tmp, (size_t)cnt, sizeof(*tmp), cmp_proc_row);
    int out_n = cnt < max_out ? cnt : max_out;
    memcpy(rows, tmp, (size_t)out_n * sizeof(*rows));
    free(tmp);
    return out_n;
}

/* ─── UI Renderer (320x170) ──────────────────────────────────────────────── */

static void draw_softkeys_bar(int tab)
{
    static const int kx[5] = { 48, 104, 160, 216, 272 };
    const char *k7 = (tab == 1) ? "5V RAIL" : ((tab == 2) ? "SORT" : "REFRESH");
    const char *labels[5] = { "SYS", "NET/HW", "TOP", k7, "EXIT" };

    fill_rect(0, 152, LCD_W, 18, COL_HDR_BG);
    fill_rect(0, 152, LCD_W, 1, COL_BORDER);

    for (int i = 0; i < 5; i++) {
        int cx = kx[i];
        int bw = 52;
        int bx = cx - bw / 2;
        int is_act = (i == tab);
        int is_exit = (i == 4);

        uint16_t bg = is_act ? COL_TAB_ACT : (is_exit ? rgb565(64, 24, 36) : COL_TAB_IDLE);
        uint16_t brd = is_act ? COL_CYAN : (is_exit ? COL_RED : COL_BORDER);
        uint16_t fg = is_act ? rgb565(255, 255, 255) : COL_TEXT;

        fill_rect(bx, 154, bw, 12, bg);
        draw_rect(bx, 154, bw, 12, brd);
        int len = (int)strlen(labels[i]);
        int tx = cx - (len * 6 - 1) / 2;
        draw_str(tx, 157, labels[i], fg);
        fill_rect(cx - 1, 167, 2, 3, is_act ? COL_CYAN : COL_DIM);
    }
}

static void draw_chrome(int tab)
{
    fill_rect(0, 0, LCD_W, LCD_H, COL_BG);
    fill_rect(0, 0, LCD_W, 15, COL_HDR_BG);
    fill_rect(0, 15, LCD_W, 1, COL_CYAN);

    fill_rect(3, 2, 28, 11, COL_TAB_ACT);
    draw_str(5, 4, "KALI", rgb565(255, 255, 255));
    draw_str(35, 4, "SYSMON", COL_CYAN);

    const char *tabs[3] = {"4:SYS", "5:NET", "6:TOP"};
    for (int i = 0; i < 3; i++) {
        int tx = 86 + i * 42;
        fill_rect(tx, 2, 38, 11, (tab == i) ? COL_TAB_ACT : COL_TAB_IDLE);
        draw_str(tx + 4, 4, tabs[i], (tab == i) ? COL_TEXT : COL_DIM);
    }

    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char clk[16];
    strftime(clk, sizeof(clk), "%H:%M:%S", &tmv);
    draw_str(LCD_W - 52, 4, clk, COL_TEXT);

    draw_softkeys_bar(tab);
}

static void render_tab_sys(const struct sys_stats *st, const int *hist, int hist_pos)
{
    char line[80];
    /* Left column: 4 CPU core bars + sparkline */
    fill_rect(3, 18, 154, 88, COL_PANEL);
    draw_rect(3, 18, 154, 88, COL_BORDER);

    snprintf(line, sizeof(line), "CPU %2d%% %2dC %4dMHz",
             st->cpu_pct[0], st->temp_c, st->freq_mhz);
    draw_str(7, 22, line, COL_CYAN);

    for (int c = 0; c < 4; c++) {
        int y = 33 + c * 10;
        int pct = st->cpu_pct[c + 1];
        snprintf(line, sizeof(line), "C%d", c);
        draw_str(7, y, line, COL_TEXT);
        draw_bar(22, y, 102, 7, pct, pct_color(pct));
        snprintf(line, sizeof(line), "%3d%%", pct);
        draw_str(127, y, line, COL_DIM);
    }

    /* Sparkline graph at bottom of CPU panel */
    int gx = 7, gy = 75, gw = 146, gh = 27;
    fill_rect(gx, gy, gw, gh, COL_BG);
    draw_rect(gx, gy, gw, gh, COL_BORDER);
    for (int i = 0; i < HIST_LEN; i++) {
        int v = hist[(hist_pos + i) % HIST_LEN];
        int bh = (v * (gh - 2)) / 100;
        int bx = gx + 1 + (i * (gw - 2)) / HIST_LEN;
        int bw = ((i + 1) * (gw - 2)) / HIST_LEN - (i * (gw - 2)) / HIST_LEN;
        if (bw < 1) bw = 1;
        if (bh > 0)
            fill_rect(bx, gy + gh - 1 - bh, bw, bh, pct_color(v));
    }

    /* Right column: RAM, ZRAM, Disk */
    fill_rect(160, 18, 157, 88, COL_PANEL);
    draw_rect(160, 18, 157, 88, COL_BORDER);

    int mem_pct = st->mem_tot_mb > 0 ? (int)(st->mem_used_mb * 100 / st->mem_tot_mb) : 0;
    snprintf(line, sizeof(line), "RAM  %3ld/%3ld MiB", st->mem_used_mb, st->mem_tot_mb);
    draw_str(165, 22, line, COL_TEXT);
    draw_bar(165, 32, 147, 8, mem_pct, pct_color(mem_pct));

    int swp_pct = st->swp_tot_mb > 0 ? (int)(st->swp_used_mb * 100 / st->swp_tot_mb) : 0;
    snprintf(line, sizeof(line), "ZRAM %3ld/%3ld MiB", st->swp_used_mb, st->swp_tot_mb);
    draw_str(165, 46, line, COL_TEXT);
    draw_bar(165, 56, 147, 8, swp_pct, COL_PURPLE);

    snprintf(line, sizeof(line), "SD / %.1f/%.1f GiB", st->disk_used_gb, st->disk_tot_gb);
    draw_str(165, 70, line, COL_TEXT);
    draw_bar(165, 80, 147, 8, st->disk_pct, COL_CYAN);

    /* Bottom summary strip */
    fill_rect(3, 108, 314, 42, COL_PANEL);
    draw_rect(3, 108, 314, 42, COL_BORDER);

    long up_h = st->uptime_s / 3600;
    long up_m = (st->uptime_s % 3600) / 60;
    long up_s = st->uptime_s % 60;
    snprintf(line, sizeof(line), "LOAD %.2f %.2f   UP %02ld:%02ld:%02ld",
             st->load1, st->load5, up_h, up_m, up_s);
    draw_str(8, 112, line, COL_TEXT);

    struct batt_info b;
    read_battery(&b);
    if (b.present) {
        snprintf(line, sizeof(line), "BATT %3d%% %.2fV %+ldmA (%s)",
                 b.cap_pct, b.volt_mv / 1000.0, b.curr_ma, b.status);
        draw_str(8, 124, line, b.cap_pct <= 20 ? COL_RED : COL_GREEN);
        draw_bar(8, 136, 304, 7, b.cap_pct, b.cap_pct <= 20 ? COL_RED : COL_GREEN);
    } else {
        draw_str(8, 128, "BATT Fuel gauge ETA6965/BQ27220 N/A", COL_DIM);
    }
}

static void render_tab_net(const struct net_row *rows, int nrows)
{
    char line[80];
    struct batt_info b;
    read_battery(&b);

    /* Power & 5V Rail Box */
    fill_rect(3, 18, 314, 46, COL_PANEL);
    draw_rect(3, 18, 314, 46, COL_BORDER);

    if (b.present) {
        snprintf(line, sizeof(line), "BATTERY: %3d%%  %4ldmV  %+5ldmA  [%s]",
                 b.cap_pct, b.volt_mv, b.curr_ma, b.status);
        draw_str(7, 22, line, COL_GREEN);
        draw_bar(7, 32, 306, 7, b.cap_pct, b.cap_pct <= 20 ? COL_RED : COL_GREEN);
    } else {
        draw_str(7, 24, "Battery Gauge: external 5V / N/A", COL_YELLOW);
    }

    long g5 = 0, e5 = 0, gf = 0, us = 0;
    read_int_file("/sys/class/leds/grove_5v_out/brightness", &g5);
    read_int_file("/sys/class/leds/ext_5v_out/brightness", &e5);
    read_int_file("/sys/class/leds/grove_fun/brightness", &gf);
    read_int_file("/sys/class/leds/usb_switch/brightness", &us);
    snprintf(line, sizeof(line), "Grove5V:%s  Ext14P:%s  Grove:%s  USB:%ld",
             g5 ? "ON " : "OFF", e5 ? "ON " : "OFF", gf ? "UART" : "I2C ", us);
    draw_str(7, 44, line, COL_CYAN);

    /* Network Interfaces Box */
    fill_rect(3, 67, 314, 83, COL_PANEL);
    draw_rect(3, 67, 314, 83, COL_BORDER);
    draw_str(7, 71, "IFACE      STATE IPv4            RX/TX KB/s", COL_CYAN);

    if (nrows == 0) {
        draw_str(7, 87, "No active network interfaces.", COL_DIM);
    } else {
        int lim = nrows > 5 ? 5 : nrows;
        for (int i = 0; i < lim; i++) {
            int y = 83 + i * 13;
            snprintf(line, sizeof(line), "%-10.10s %-4s  %-15.15s %4.0f/%-4.0f",
                     rows[i].name, rows[i].up ? "UP" : "DOWN",
                     rows[i].ip, rows[i].rx_kbs, rows[i].tx_kbs);
            draw_str(7, y, line, rows[i].up ? COL_TEXT : COL_DIM);
        }
    }
}

static void render_tab_top(const struct proc_row *procs, int nprocs)
{
    char line[80];
    fill_rect(3, 18, 314, 132, COL_PANEL);
    draw_rect(3, 18, 314, 132, COL_BORDER);

    snprintf(line, sizeof(line), "   PID   %s   %s  COMMAND",
             g_sort_by_mem ? "CPU%" : "CPU*",
             g_sort_by_mem ? "MEM*" : "MEM%");
    draw_str(7, 22, line, COL_CYAN);
    fill_rect(5, 31, 310, 1, COL_BORDER);

    int lim = nprocs > 11 ? 11 : nprocs;
    for (int i = 0; i < lim; i++) {
        int y = 34 + i * 10;
        snprintf(line, sizeof(line), "%6d %5.1f %5.1f  %-23.23s",
                 procs[i].pid, procs[i].cpu_pct, procs[i].mem_pct, procs[i].comm);
        draw_str(7, y, line, (i == 0) ? COL_YELLOW : COL_TEXT);
    }
}

/* ─── Framebuffer & Input Setup ──────────────────────────────────────────── */

struct fb_ctx {
    int fd;
    uint8_t *map;
    size_t map_len;
    struct fb_fix_screeninfo fix;
    struct fb_var_screeninfo var;
};

static int open_lcd_fb(struct fb_ctx *fb)
{
    memset(fb, 0, sizeof(*fb));
    fb->fd = -1;

    char discovered[128] = "";
    DIR *d = opendir("/sys/class/graphics");
    if (d) {
        struct dirent *de;
        while ((de = readdir(d))) {
            if (strncmp(de->d_name, "fb", 2) != 0 || !isdigit((unsigned char)de->d_name[2]))
                continue;
            char np[320], nm[64];
            snprintf(np, sizeof(np), "/sys/class/graphics/%.64s/name", de->d_name);
            if (read_str_file(np, nm, sizeof(nm)) == 0 &&
                (strstr(nm, "st7789") || strstr(nm, "panel-mipi-dbi"))) {
                snprintf(discovered, sizeof(discovered), "/dev/%.64s", de->d_name);
                break;
            }
        }
        closedir(d);
    }

    const char *cands[4] = {
        getenv("LV_LINUX_FBDEV_DEVICE"),
        "/dev/fb_lcd",
        discovered[0] ? discovered : NULL,
        "/dev/fb0",
    };

    for (int i = 0; i < 4; i++) {
        if (!cands[i] || !*cands[i]) continue;
        int fd = open(cands[i], O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, FBIOGET_FSCREENINFO, &fb->fix) == 0 &&
            ioctl(fd, FBIOGET_VSCREENINFO, &fb->var) == 0 &&
            (fb->var.bits_per_pixel == 16 || fb->var.bits_per_pixel == 32)) {
            fb->map_len = fb->fix.smem_len ? fb->fix.smem_len
                                           : (size_t)fb->fix.line_length * fb->var.yres_virtual;
            void *m = mmap(NULL, fb->map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (m != MAP_FAILED) {
                fb->fd = fd;
                fb->map = (uint8_t *)m;
                return 0;
            }
        }
        close(fd);
    }
    return -1;
}

static void blit_fb(struct fb_ctx *fb)
{
    int bpp = (int)(fb->var.bits_per_pixel / 8);
    int xoff = ((int)fb->var.xres > LCD_W) ? ((int)fb->var.xres - LCD_W) / 2 : 0;
    int yoff = ((int)fb->var.yres > LCD_H) ? ((int)fb->var.yres - LCD_H) / 2 : 0;
    int cw = ((int)fb->var.xres < LCD_W) ? (int)fb->var.xres : LCD_W;
    int ch = ((int)fb->var.yres < LCD_H) ? (int)fb->var.yres : LCD_H;

    for (int y = 0; y < ch; y++) {
        uint8_t *dst = fb->map + (size_t)(y + yoff + (int)fb->var.yoffset) * fb->fix.line_length
                               + (size_t)(xoff + (int)fb->var.xoffset) * (size_t)bpp;
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

static int open_inputs(int *fds, int max_fds)
{
    dev_t seen[MAX_INPUT_FDS];
    struct stat st;
    int n = 0;
    const char *primary = "/dev/input/by-path/platform-3f804000.i2c-event";
    int pfd = open(primary, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (pfd >= 0) {
        if (fstat(pfd, &st) == 0 && n < max_fds) {
            seen[n] = st.st_rdev;
            fds[n++] = pfd;
        } else {
            close(pfd);
        }
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
            for (int i = 0; i < n; i++) {
                if (seen[i] == st.st_rdev) { dup = 1; break; }
            }
            unsigned long evbit = 0;
            if (!dup &&
                ioctl(fd, EVIOCGBIT(0, sizeof(evbit)), &evbit) >= 0 &&
                (evbit & (1UL << EV_KEY))) {
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

static double mono_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    const char *dump_path = getenv("CZ_SYSMON_DUMP_PPM");
    if (!dump_path) dump_path = getenv("CZ_DUMP_PPM");
    struct fb_ctx fb;
    int have_fb = (open_lcd_fb(&fb) == 0);
    if (!have_fb && !dump_path) {
        fprintf(stderr, "cz-sysmon: unable to open /dev/fb_lcd or fallback framebuffer\n");
        return 1;
    }

    int in_fds[MAX_INPUT_FDS];
    int n_in = dump_path ? 0 : open_inputs(in_fds, MAX_INPUT_FDS);

    struct cpu_snap cpu_prev, cpu_cur;
    struct net_dev_snap net_prev[12], net_cur[12];
    int net_prev_n = 0, net_cur_n = 0;
    struct proc_tick *pt_prev = calloc(MAX_PROCS, sizeof(*pt_prev));
    struct proc_tick *pt_cur = calloc(MAX_PROCS, sizeof(*pt_cur));
    int pt_prev_n = 0, pt_cur_n = 0;

    read_cpu_snap(&cpu_prev);
    net_prev_n = read_net_snaps(net_prev, 12);
    if (pt_prev) pt_prev_n = read_proc_ticks(pt_prev, MAX_PROCS);
    double t_prev = mono_sec();
    usleep(80000);

    int hist[HIST_LEN] = {0};
    int hist_pos = 0;
    int tab = 0;
    if (getenv("CZ_SYSMON_TAB"))
        tab = atoi(getenv("CZ_SYSMON_TAB")) % 3;

    struct sys_stats st;
    struct net_row net_rows[8];
    int n_net_rows = 0;
    struct proc_row top_rows[TOP_ROWS];
    int n_top_rows = 0;

    double next_sample = 0.0;

    while (g_running) {
        double now = mono_sec();
        if (now >= next_sample) {
            double dt = now - t_prev;
            read_cpu_snap(&cpu_cur);
            collect_sys(&cpu_prev, &cpu_cur, &st);
            hist[hist_pos] = st.cpu_pct[0];
            hist_pos = (hist_pos + 1) % HIST_LEN;

            net_cur_n = read_net_snaps(net_cur, 12);
            n_net_rows = build_net_rows(net_prev, net_prev_n, net_cur, net_cur_n, dt, net_rows, 8);
            memcpy(net_prev, net_cur, sizeof(net_cur));
            net_prev_n = net_cur_n;

            if (pt_prev && pt_cur) {
                pt_cur_n = read_proc_ticks(pt_cur, MAX_PROCS);
                uint64_t cpu_dt = cpu_cur.total[0] - cpu_prev.total[0];
                n_top_rows = build_top_procs(pt_prev, pt_prev_n, pt_cur, pt_cur_n,
                                             cpu_dt, st.cores, st.mem_tot_mb * 1024,
                                             top_rows, TOP_ROWS);
                memcpy(pt_prev, pt_cur, (size_t)pt_cur_n * sizeof(*pt_cur));
                pt_prev_n = pt_cur_n;
            }

            cpu_prev = cpu_cur;
            t_prev = now;
            next_sample = now + 0.75;
        }

        draw_chrome(tab);
        if (tab == 0) render_tab_sys(&st, hist, hist_pos);
        else if (tab == 1) render_tab_net(net_rows, n_net_rows);
        else render_tab_top(top_rows, n_top_rows);

        if (dump_path) {
            int rc = dump_ppm(dump_path);
            free(pt_prev);
            free(pt_cur);
            if (have_fb) { munmap(fb.map, fb.map_len); close(fb.fd); }
            return rc == 0 ? 0 : 1;
        }

        if (have_fb) blit_fb(&fb);

        struct pollfd pfds[MAX_INPUT_FDS];
        for (int i = 0; i < n_in; i++) {
            pfds[i].fd = in_fds[i];
            pfds[i].events = POLLIN;
            pfds[i].revents = 0;
        }

        int wait_ms = (int)((next_sample - mono_sec()) * 1000.0);
        if (wait_ms < 20) wait_ms = 20;
        if (wait_ms > 250) wait_ms = 250;

        if (n_in > 0 && poll(pfds, (nfds_t)n_in, wait_ms) > 0) {
            for (int i = 0; i < n_in; i++) {
                if (!(pfds[i].revents & POLLIN)) continue;
                struct input_event ev;
                while (read(in_fds[i], &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                    if (ev.type != EV_KEY || ev.value != 1) continue; /* key press only */
                    switch (ev.code) {
                        case KEY_ESC:
                        case KEY_GRAVE:
                        case KEY_Q:
                        case KEY_BACKSPACE:
                        case KEY_8:
                            g_running = 0;
                            break;
                        case KEY_4:
                        case KEY_1:
                            tab = 0;
                            break;
                        case KEY_5:
                        case KEY_2:
                            tab = 1;
                            break;
                        case KEY_6:
                        case KEY_3:
                            tab = 2;
                            break;
                        case KEY_7:
                            if (tab == 1) {
                                static int rail_step = 0;
                                rail_step = (rail_step + 1) & 3;
                                long g5 = (rail_step & 1) ? 1 : 0;
                                long e5 = (rail_step & 2) ? 1 : 0;
                                long cur_g = 0, cur_e = 0;
                                read_int_file("/sys/class/leds/grove_5v_out/brightness", &cur_g);
                                read_int_file("/sys/class/leds/ext_5v_out/brightness", &cur_e);
                                if ((cur_g != 0) != g5) toggle_led_rail("grove_5v_out");
                                if ((cur_e != 0) != e5) toggle_led_rail("ext_5v_out");
                            } else if (tab == 2) {
                                g_sort_by_mem = !g_sort_by_mem;
                                next_sample = 0.0;
                            } else {
                                next_sample = 0.0;
                            }
                            break;
                        case KEY_LEFT:
                        case KEY_COMMA:
                        case KEY_UP:
                            tab = (tab + 2) % 3;
                            break;
                        case KEY_RIGHT:
                        case KEY_DOT:
                        case KEY_SLASH:
                        case KEY_DOWN:
                        case KEY_TAB:
                        case KEY_SPACE:
                            tab = (tab + 1) % 3;
                            break;
                        case KEY_M:
                            g_sort_by_mem = !g_sort_by_mem;
                            next_sample = 0.0;
                            break;
                        case KEY_G:
                            if (tab == 1) toggle_led_rail("grove_5v_out");
                            break;
                        case KEY_E:
                            if (tab == 1) toggle_led_rail("ext_5v_out");
                            break;
                        case KEY_R:
                            next_sample = 0.0;
                            break;
                    }
                }
            }
        } else {
            usleep((useconds_t)wait_ms * 1000U);
        }
    }

    for (int i = 0; i < n_in; i++) close(in_fds[i]);
    if (have_fb) {
        munmap(fb.map, fb.map_len);
        close(fb.fd);
    }
    free(pt_prev);
    free(pt_cur);
    return 0;
}
