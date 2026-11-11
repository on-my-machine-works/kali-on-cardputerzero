/*
 * cz-wifiscan.c — Native 320x170 RGB565 Wireless AP, Channel & Monitor Dashboard
 *                 for Kali Linux on M5Stack CardputerZero
 *
 * Softkeys aligned to physical keys '4'..'8' (x = 48, 104, 160, 216, 272):
 *   4: SCAN     Trigger fresh 802.11 scan on active interface
 *   5: CH/LIST  Toggle AP table <-> 2.4G/5G channel congestion graph
 *   6: IFACE    Cycle wireless adapters (wlan0, USB 88XXau wlan1, *mon)
 *   7: MON      Toggle monitor mode (/usr/local/bin/monstart | monstop)
 *   8 / ESC:    Exit back to APPLaunch
 */

#include "cz_ui.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/wait.h>

#define MAX_APS 64
#define MAX_IFS 8
#define VISIBLE_ROWS 7

static volatile sig_atomic_t g_running = 1;

static void on_sig(int sig)
{
    (void)sig;
    g_running = 0;
}

struct ap_entry {
    char bssid[20];
    char ssid[36];
    char sec[8];
    int freq;
    int chan;
    int dbm;
};

struct wifi_iface {
    char name[20];
    char mode[16];
    char ip[20];
    int chan;
    int up;
};

static int freq_to_chan(int freq)
{
    if (freq == 2484) return 14;
    if (freq >= 2412 && freq < 2484) return (freq - 2407) / 5;
    if (freq >= 5170 && freq <= 5885) return (freq - 5000) / 5;
    if (freq >= 5955 && freq <= 7115) return (freq - 5950) / 5;
    return 0;
}

static int cmp_ap(const void *a, const void *b)
{
    const struct ap_entry *pa = (const struct ap_entry *)a;
    const struct ap_entry *pb = (const struct ap_entry *)b;
    return pb->dbm - pa->dbm;
}

static int discover_wifi_ifaces(struct wifi_iface *ifs, int max_n)
{
    memset(ifs, 0, (size_t)max_n * sizeof(*ifs));
    int n = 0;
    DIR *d = opendir("/sys/class/net");
    if (!d) return 0;
    struct dirent *de;
    while (n < max_n && (de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char p[320];
        struct stat st;
        snprintf(p, sizeof(p), "/sys/class/net/%.64s/phy80211", de->d_name);
        if (stat(p, &st) != 0) {
            snprintf(p, sizeof(p), "/sys/class/net/%.64s/wireless", de->d_name);
            if (stat(p, &st) != 0) continue;
        }
        snprintf(ifs[n].name, sizeof(ifs[n].name), "%.19s", de->d_name);
        snprintf(ifs[n].mode, sizeof(ifs[n].mode), "managed");
        snprintf(ifs[n].ip, sizeof(ifs[n].ip), "-");

        long flags = 0;
        snprintf(p, sizeof(p), "/sys/class/net/%.64s/flags", de->d_name);
        if (cz_read_int_file(p, &flags) == 0 && (flags & IFF_UP)) ifs[n].up = 1;

        long type = 0;
        snprintf(p, sizeof(p), "/sys/class/net/%.64s/type", de->d_name);
        if (cz_read_int_file(p, &type) == 0 && type >= 800 && type <= 805)
            snprintf(ifs[n].mode, sizeof(ifs[n].mode), "monitor");

        char cmd[128];
        snprintf(cmd, sizeof(cmd), "iw dev %.19s info 2>/dev/null", ifs[n].name);
        FILE *fp = popen(cmd, "r");
        if (fp) {
            char line[160];
            while (fgets(line, sizeof(line), fp)) {
                char m[16];
                int ch = 0;
                if (sscanf(line, " type %15s", m) == 1)
                    snprintf(ifs[n].mode, sizeof(ifs[n].mode), "%s", m);
                else if (sscanf(line, " channel %d", &ch) == 1)
                    ifs[n].chan = ch;
            }
            pclose(fp);
        }
        n++;
    }
    closedir(d);

    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) == 0) {
        for (struct ifaddrs *it = ifa; it; it = it->ifa_next) {
            if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET) continue;
            for (int i = 0; i < n; i++) {
                if (strcmp(ifs[i].name, it->ifa_name) == 0) {
                    struct sockaddr_in *sa = (struct sockaddr_in *)it->ifa_addr;
                    inet_ntop(AF_INET, &sa->sin_addr, ifs[i].ip, sizeof(ifs[i].ip));
                }
            }
        }
        freeifaddrs(ifa);
    }
    return n;
}

static int parse_iw_scan_text(const char *buf, struct ap_entry *aps, int max_n)
{
    int n = 0;
    struct ap_entry cur;
    int have = 0;
    memset(&cur, 0, sizeof(cur));

    const char *p = buf;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char line[256];
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        p = nl ? (nl + 1) : (p + len);

        if (strncmp(line, "BSS ", 4) == 0 && isxdigit((unsigned char)line[4])) {
            if (have && n < max_n) aps[n++] = cur;
            memset(&cur, 0, sizeof(cur));
            snprintf(cur.bssid, sizeof(cur.bssid), "%.17s", line + 4);
            snprintf(cur.ssid, sizeof(cur.ssid), "<hidden>");
            snprintf(cur.sec, sizeof(cur.sec), "OPEN");
            cur.dbm = -95;
            have = 1;
        } else if (have) {
            char *t = line;
            while (*t == '\t' || *t == ' ') t++;
            double sig = 0.0;
            int fq = 0, ch = 0;
            if (strncmp(t, "freq:", 5) == 0 && sscanf(t + 5, "%d", &fq) == 1) {
                cur.freq = fq;
                cur.chan = freq_to_chan(fq);
            } else if (strncmp(t, "DS Parameter set: channel ", 26) == 0 &&
                       sscanf(t + 26, "%d", &ch) == 1) {
                cur.chan = ch;
            } else if (strncmp(t, "signal:", 7) == 0 && sscanf(t + 7, "%lf", &sig) == 1) {
                cur.dbm = (int)sig;
            } else if (strncmp(t, "SSID: ", 6) == 0) {
                if (t[6] != '\0')
                    snprintf(cur.ssid, sizeof(cur.ssid), "%.35s", t + 6);
            } else if (strncmp(t, "RSN:", 4) == 0) {
                if (strcmp(cur.sec, "WPA3") != 0)
                    snprintf(cur.sec, sizeof(cur.sec), "WPA2");
            } else if (strncmp(t, "WPA:", 4) == 0 && strcmp(cur.sec, "OPEN") == 0) {
                snprintf(cur.sec, sizeof(cur.sec), "WPA");
            } else if (strstr(t, "SAE") != NULL) {
                snprintf(cur.sec, sizeof(cur.sec), "WPA3");
            } else if (strstr(t, "Privacy") != NULL && strcmp(cur.sec, "OPEN") == 0) {
                snprintf(cur.sec, sizeof(cur.sec), "WEP");
            }
        }
    }
    if (have && n < max_n) aps[n++] = cur;
    qsort(aps, (size_t)n, sizeof(*aps), cmp_ap);
    return n;
}

static pid_t start_scan_proc(const char *ifname, int *out_fd)
{
    int pfd[2];
    if (pipe(pfd) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return -1;
    }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
        close(pfd[1]);
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
                 "sudo -n ip link set %.19s up 2>/dev/null; sudo -n iw dev %.19s scan 2>/dev/null",
                 ifname, ifname);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(pfd[1]);
    int fl = fcntl(pfd[0], F_GETFL, 0);
    if (fl >= 0) fcntl(pfd[0], F_SETFL, fl | O_NONBLOCK);
    *out_fd = pfd[0];
    return pid;
}

static uint16_t rssi_color(int dbm)
{
    if (dbm >= -60) return COL_GREEN;
    if (dbm >= -75) return COL_YELLOW;
    return COL_RED;
}

static void render_ui(const struct wifi_iface *ifs, int n_ifs, int cur_if,
                      const struct ap_entry *aps, int n_aps, int sel,
                      int view_mode, int scanning, const char *status_msg)
{
    fill_rect(0, 0, LCD_W, LCD_H, COL_BG);

    char sub[64] = "";
    if (n_ifs > 0) {
        snprintf(sub, sizeof(sub), "%s [%s]%s",
                 ifs[cur_if].name, ifs[cur_if].mode, scanning ? " *" : "");
    }
    cz_draw_topbar("WIFISCAN", sub);

    /* Adapter summary strip (y = 17..29) */
    fill_rect(3, 17, 314, 13, COL_PANEL);
    draw_rect(3, 17, 314, 13, COL_BORDER);
    char info[64];
    if (n_ifs > 0) {
        snprintf(info, sizeof(info), "APs:%-2d  IP:%-15s  %s",
                 n_aps, ifs[cur_if].ip, status_msg ? status_msg : "");
    } else {
        snprintf(info, sizeof(info), "No 802.11 adapter detected");
    }
    draw_str_clip(7, 20, info, 51, scanning ? COL_YELLOW : COL_CYAN);

    if (view_mode == 0) {
        /* AP Table View (y = 32..149) */
        fill_rect(3, 32, 314, 104, COL_PANEL);
        draw_rect(3, 32, 314, 104, COL_BORDER);
        draw_str(7, 35, "RSSI  CH  SEC   SSID", COL_DIM);
        fill_rect(5, 43, 310, 1, COL_BORDER);

        if (n_aps == 0) {
            draw_str(12, 74, scanning ? "Scanning 802.11 channels..."
                                      : "Press [4:SCAN] to sweep nearby APs",
                     scanning ? COL_YELLOW : COL_DIM);
        } else {
            int top = 0;
            if (sel >= VISIBLE_ROWS) top = sel - VISIBLE_ROWS + 1;
            for (int row = 0; row < VISIBLE_ROWS && (top + row) < n_aps; row++) {
                int idx = top + row;
                int y = 46 + row * 12;
                if (idx == sel)
                    fill_rect(5, y - 1, 310, 11, COL_SEL_BG);

                /* Mini 4-bar signal meter + dBm */
                int bars = (aps[idx].dbm >= -55) ? 4 :
                           (aps[idx].dbm >= -67) ? 3 :
                           (aps[idx].dbm >= -78) ? 2 : 1;
                uint16_t rc = rssi_color(aps[idx].dbm);
                for (int b = 0; b < 4; b++) {
                    int bh = 2 + b * 2;
                    fill_rect(7 + b * 3, y + 7 - bh, 2, bh, (b < bars) ? rc : COL_BAR_BG);
                }

                char line[64];
                snprintf(line, sizeof(line), "%3d %3d %-4.4s  %-28.28s",
                         aps[idx].dbm, aps[idx].chan, aps[idx].sec, aps[idx].ssid);
                draw_str_clip(21, y + 1, line, 49, (idx == sel) ? COL_WHITE : COL_TEXT);
            }
        }

        /* Selected AP detail strip (y = 138..150) */
        fill_rect(3, 138, 314, 12, COL_PANEL_ALT);
        draw_rect(3, 138, 314, 12, COL_BORDER);
        if (n_aps > 0 && sel >= 0 && sel < n_aps) {
            char det[64];
            snprintf(det, sizeof(det), "BSSID %s  %dMHz  [%d/%d]",
                     aps[sel].bssid, aps[sel].freq, sel + 1, n_aps);
            draw_str_clip(7, 141, det, 51, COL_GREEN);
        } else {
            draw_str(7, 141, "Fn+Up/Dn:Select  4:Scan 5:Graph 6:If 7:Mon", COL_DIM);
        }
    } else {
        /* 2.4 GHz + 5 GHz Channel Congestion Graph (y = 32..150) */
        fill_rect(3, 32, 314, 118, COL_PANEL);
        draw_rect(3, 32, 314, 118, COL_BORDER);
        draw_str(7, 36, "2.4GHz CH 1..14 & 5GHz OCCUPANCY", COL_CYAN);

        int cnt[16] = {0};
        int peak[16];
        for (int i = 0; i < 16; i++) peak[i] = -100;
        for (int i = 0; i < n_aps; i++) {
            int bucket = -1;
            if (aps[i].chan >= 1 && aps[i].chan <= 14) bucket = aps[i].chan - 1;
            else if (aps[i].chan > 14) bucket = 14; /* 5G+ aggregate */
            if (bucket >= 0) {
                cnt[bucket]++;
                if (aps[i].dbm > peak[bucket]) peak[bucket] = aps[i].dbm;
            }
        }

        int gx = 10, gy = 50, gh = 78;
        fill_rect(gx, gy, 300, gh, COL_BG);
        draw_rect(gx, gy, 300, gh, COL_BORDER);

        for (int b = 0; b < 15; b++) {
            int bx = gx + 5 + b * 19;
            if (cnt[b] > 0) {
                int pct = (peak[b] + 100) * 2;
                if (pct < 12) pct = 12;
                if (pct > 100) pct = 100;
                int bh = (pct * (gh - 14)) / 100;
                fill_rect(bx, gy + gh - 2 - bh, 13, bh, rssi_color(peak[b]));
                char cs[16];
                snprintf(cs, sizeof(cs), "%d", cnt[b]);
                draw_str(bx + 3, gy + gh - 11 - bh, cs, COL_WHITE);
            }
            char lbl[6];
            if (b < 14) snprintf(lbl, sizeof(lbl), "%d", b + 1);
            else snprintf(lbl, sizeof(lbl), "5G");
            draw_str(bx + (b < 9 ? 4 : 1), gy + gh + 4, lbl, (b == 14) ? COL_PURPLE : COL_DIM);
        }
    }

    const char *mon_lbl = (n_ifs > 0 && strcmp(ifs[cur_if].mode, "monitor") == 0)
                          ? "MANAGED" : "MON ON";
    cz_draw_softkeys("SCAN", view_mode ? "AP LIST" : "CH GRPH",
                     "IFACE", mon_lbl, "EXIT", scanning ? 0 : -1);
}

int main(void)
{
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    struct wifi_iface ifs[MAX_IFS];
    struct ap_entry aps[MAX_APS];
    int n_ifs = discover_wifi_ifaces(ifs, MAX_IFS);
    int cur_if = 0;
    int n_aps = 0;
    int sel = 0;
    int view_mode = 0;
    char status_msg[32] = "Ready";

    const char *dump_path = getenv("CZ_DUMP_PPM");
    if (dump_path) {
        if (n_ifs == 0) {
            snprintf(ifs[0].name, sizeof(ifs[0].name), "wlan0");
            snprintf(ifs[0].mode, sizeof(ifs[0].mode), "managed");
            snprintf(ifs[0].ip, sizeof(ifs[0].ip), "192.168.1.42");
            n_ifs = 1;
        }
        const char *sample =
            "BSS aa:bb:cc:11:22:33(on wlan0)\n\tfreq: 2437\n\tsignal: -48.00 dBm\n\tSSID: Kali-Lab-5G\n\tRSN:\n\t\t * Authentication suites: SAE\n"
            "BSS dd:ee:ff:44:55:66(on wlan0)\n\tfreq: 2412\n\tsignal: -64.00 dBm\n\tSSID: CardputerFieldNet\n\tRSN:\n"
            "BSS 12:34:56:78:9a:bc(on wlan0)\n\tfreq: 2462\n\tsignal: -79.00 dBm\n\tSSID: Guest_Hotspot\n";
        n_aps = parse_iw_scan_text(sample, aps, MAX_APS);
        render_ui(ifs, n_ifs, 0, aps, n_aps, 0, 0, 0, "Demo OK");
        return cz_dump_ppm(dump_path) == 0 ? 0 : 1;
    }

    struct cz_fb fb;
    if (cz_fb_open(&fb) != 0) {
        fprintf(stderr, "cz-wifiscan: cannot open /dev/fb_lcd\n");
        return 1;
    }

    int in_fds[CZ_MAX_INPUT_FDS];
    int n_in = cz_inputs_open(in_fds, CZ_MAX_INPUT_FDS);

    int scan_fd = -1;
    pid_t scan_pid = -1;
    char *scan_buf = NULL;
    size_t scan_len = 0, scan_cap = 0;

    if (n_ifs > 0 && strcmp(ifs[cur_if].mode, "monitor") != 0) {
        scan_pid = start_scan_proc(ifs[cur_if].name, &scan_fd);
        snprintf(status_msg, sizeof(status_msg), "Scanning...");
    }

    double last_ui = 0.0;

    while (g_running) {
        if (scan_fd >= 0) {
            char tmp[4096];
            ssize_t rd;
            while ((rd = read(scan_fd, tmp, sizeof(tmp))) > 0) {
                if (scan_len + (size_t)rd + 1 > scan_cap) {
                    size_t ncap = scan_cap ? scan_cap * 2 : 16384;
                    while (ncap < scan_len + (size_t)rd + 1) ncap *= 2;
                    char *nb = realloc(scan_buf, ncap);
                    if (!nb) break;
                    scan_buf = nb;
                    scan_cap = ncap;
                }
                memcpy(scan_buf + scan_len, tmp, (size_t)rd);
                scan_len += (size_t)rd;
                scan_buf[scan_len] = '\0';
            }
            int wstatus = 0;
            if (waitpid(scan_pid, &wstatus, WNOHANG) == scan_pid) {
                close(scan_fd);
                scan_fd = -1;
                scan_pid = -1;
                if (scan_buf && scan_len > 0) {
                    n_aps = parse_iw_scan_text(scan_buf, aps, MAX_APS);
                    if (sel >= n_aps) sel = n_aps > 0 ? n_aps - 1 : 0;
                    snprintf(status_msg, sizeof(status_msg), "Scan OK");
                } else {
                    snprintf(status_msg, sizeof(status_msg), "0 APs / Busy");
                }
                scan_len = 0;
            }
        }

        double now = cz_mono_sec();
        if (now - last_ui >= 0.1) {
            render_ui(ifs, n_ifs, cur_if, aps, n_aps, sel, view_mode,
                      scan_fd >= 0, status_msg);
            cz_fb_blit(&fb);
            last_ui = now;
        }

        struct pollfd pfds[CZ_MAX_INPUT_FDS + 1];
        nfds_t nf = 0;
        for (int i = 0; i < n_in; i++) {
            pfds[nf].fd = in_fds[i];
            pfds[nf].events = POLLIN;
            pfds[nf].revents = 0;
            nf++;
        }
        if (scan_fd >= 0) {
            pfds[nf].fd = scan_fd;
            pfds[nf].events = POLLIN;
            pfds[nf].revents = 0;
            nf++;
        }

        if (poll(pfds, nf, 120) <= 0) continue;

        for (int i = 0; i < n_in; i++) {
            if (!(pfds[i].revents & POLLIN)) continue;
            struct input_event ev;
            while (read(in_fds[i], &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type != EV_KEY || ev.value != 1) continue;
                switch (ev.code) {
                    case KEY_ESC:
                    case KEY_Q:
                    case KEY_BACKSPACE:
                    case KEY_8:
                        g_running = 0;
                        break;
                    case KEY_4:
                    case KEY_R:
                        if (scan_fd < 0 && n_ifs > 0) {
                            scan_len = 0;
                            scan_pid = start_scan_proc(ifs[cur_if].name, &scan_fd);
                            snprintf(status_msg, sizeof(status_msg), "Scanning...");
                            last_ui = 0.0;
                        }
                        break;
                    case KEY_5:
                    case KEY_TAB:
                        view_mode = !view_mode;
                        last_ui = 0.0;
                        break;
                    case KEY_6:
                        n_ifs = discover_wifi_ifaces(ifs, MAX_IFS);
                        if (n_ifs > 0) cur_if = (cur_if + 1) % n_ifs;
                        last_ui = 0.0;
                        break;
                    case KEY_7:
                        if (n_ifs > 0 && scan_fd < 0) {
                            char cmd[128];
                            if (strcmp(ifs[cur_if].mode, "monitor") == 0)
                                snprintf(cmd, sizeof(cmd), "sudo -n /usr/local/bin/monstop %.19s >/dev/null 2>&1", ifs[cur_if].name);
                            else
                                snprintf(cmd, sizeof(cmd), "sudo -n /usr/local/bin/monstart %.19s >/dev/null 2>&1", ifs[cur_if].name);
                            snprintf(status_msg, sizeof(status_msg), "Switching...");
                            render_ui(ifs, n_ifs, cur_if, aps, n_aps, sel, view_mode, 0, status_msg);
                            cz_fb_blit(&fb);
                            int rc = system(cmd);
                            (void)rc;
                            n_ifs = discover_wifi_ifaces(ifs, MAX_IFS);
                            if (cur_if >= n_ifs) cur_if = 0;
                            snprintf(status_msg, sizeof(status_msg), "Mode updated");
                            last_ui = 0.0;
                        }
                        break;
                    case KEY_UP:
                    case KEY_K:
                        if (sel > 0) { sel--; last_ui = 0.0; }
                        break;
                    case KEY_DOWN:
                    case KEY_J:
                    case KEY_SPACE:
                        if (sel + 1 < n_aps) { sel++; last_ui = 0.0; }
                        break;
                }
            }
        }
    }

    if (scan_pid > 0) {
        kill(scan_pid, SIGTERM);
        waitpid(scan_pid, NULL, WNOHANG);
    }
    if (scan_fd >= 0) close(scan_fd);
    free(scan_buf);
    cz_inputs_close(in_fds, n_in);
    cz_fb_close(&fb);
    return 0;
}
