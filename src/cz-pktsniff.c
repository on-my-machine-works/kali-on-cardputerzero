/*
 * cz-pktsniff.c — Native 320x170 RGB565 Live Packet Stream & PCAP Recorder
 *                 for Kali Linux on M5Stack CardputerZero
 *
 * Softkeys aligned to physical keys '4'..'8' (x = 48, 104, 160, 216, 272):
 *   4: RUN/PAUS  Start or pause live tcpdump stream
 *   5: FILTER    Cycle BPF presets (ALL -> DNS/DHCP -> HTTP/TLS -> ARP/ICMP -> EAPOL)
 *   6: IFACE     Cycle network / monitor interfaces
 *   7: PCAP      Toggle .pcap recording to /home/kali/captures/
 *   8 / ESC:     Stop capture & exit to APPLaunch
 */

#include "cz_ui.h"
#include <sys/wait.h>

#define RING_LINES 8
#define MAX_CAP_IFS 10

static volatile sig_atomic_t g_running = 1;

static void on_sig(int sig)
{
    (void)sig;
    g_running = 0;
}

struct pkt_line {
    char text[54];
    uint16_t col;
};

struct bpf_preset {
    const char *label;
    const char *expr;
};

static const struct bpf_preset PRESETS[] = {
    { "ALL",      "" },
    { "DNS/DHCP", "port 53 or port 67 or port 68" },
    { "WEB/TLS",  "tcp port 80 or tcp port 443 or tcp port 8080" },
    { "ARP/ICMP", "arp or icmp or icmp6" },
    { "EAPOL",    "ether proto 0x888e" },
};
#define N_PRESETS ((int)(sizeof(PRESETS) / sizeof(PRESETS[0])))

static int discover_cap_ifs(char ifs[MAX_CAP_IFS][20])
{
    int n = 0;
    DIR *d = opendir("/sys/class/net");
    if (d) {
        struct dirent *de;
        while (n < MAX_CAP_IFS - 1 && (de = readdir(d))) {
            if (de->d_name[0] == '.' || strcmp(de->d_name, "lo") == 0) continue;
            snprintf(ifs[n++], 20, "%.19s", de->d_name);
        }
        closedir(d);
    }
    snprintf(ifs[n++], 20, "any");
    return n;
}

static pid_t start_live_tcpdump(const char *ifname, const char *bpf, int *out_fd)
{
    int pfd[2];
    if (pipe(pfd) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pfd[0]); close(pfd[1]); return -1; }
    if (pid == 0) {
        setpgid(0, 0);
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); close(dn); }
        close(pfd[1]);
        char cmd[320];
        snprintf(cmd, sizeof(cmd),
                 "exec sudo -n tcpdump -l -n -q -tttt -i %.19s %s",
                 ifname, bpf ? bpf : "");
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(pfd[1]);
    int fl = fcntl(pfd[0], F_GETFL, 0);
    if (fl >= 0) fcntl(pfd[0], F_SETFL, fl | O_NONBLOCK);
    *out_fd = pfd[0];
    return pid;
}

static pid_t start_pcap_writer(const char *ifname, const char *bpf, char *out_path, size_t psz)
{
    mkdir("/home/kali/captures", 0755);
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    snprintf(out_path, psz, "/home/kali/captures/pkt_%02d%02d_%02d%02d%02d.pcap",
             tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setpgid(0, 0);
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) {
            dup2(dn, STDIN_FILENO);
            dup2(dn, STDOUT_FILENO);
            dup2(dn, STDERR_FILENO);
            close(dn);
        }
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
                 "exec sudo -n tcpdump -U -i %.19s -w '%s' %s",
                 ifname, out_path, bpf ? bpf : "");
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    return pid;
}

static void kill_proc_group(pid_t *pid)
{
    if (*pid > 0) {
        kill(-(*pid), SIGTERM);
        kill(*pid, SIGTERM);
        usleep(30000);
        waitpid(*pid, NULL, WNOHANG);
        *pid = -1;
    }
}

struct pkt_stats {
    unsigned long total;
    unsigned long tcp;
    unsigned long udp;
    unsigned long dns;
    unsigned long arp;
    unsigned long eapol;
};

static void ingest_tcpdump_line(const char *raw, struct pkt_line *ring, int *ring_cnt,
                                struct pkt_stats *st)
{
    if (!raw || !*raw) return;
    if (strncmp(raw, "tcpdump:", 8) == 0 || strncmp(raw, "listening on", 12) == 0)
        return;

    st->total++;
    uint16_t col = COL_TEXT;

    if (strstr(raw, "EAPOL") || strstr(raw, "802.1X")) {
        st->eapol++;
        col = COL_RED;
    } else if (strstr(raw, "ARP,")) {
        st->arp++;
        col = COL_YELLOW;
    } else if (strstr(raw, ".53:") || strstr(raw, ".53 ") || strstr(raw, "domain")) {
        st->dns++;
        st->udp++;
        col = COL_CYAN;
    } else if (strstr(raw, "UDP") || strstr(raw, ".67") || strstr(raw, ".68")) {
        st->udp++;
        col = COL_PURPLE;
    } else if (strstr(raw, "ICMP")) {
        col = COL_GREEN;
    } else if (strstr(raw, "tcp")) {
        st->tcp++;
        col = COL_TEXT;
    }

    /* Strip leading YYYY-MM-DD date if present ("2026-11-11 15:20:01.123456 IP ...") */
    const char *s = raw;
    if (strlen(s) > 20 && s[4] == '-' && s[7] == '-' && s[10] == ' ')
        s += 11;
    /* Compact microseconds: keep HH:MM:SS then skip ".123456" */
    char compact[128];
    if (strlen(s) > 15 && s[2] == ':' && s[5] == ':' && s[8] == '.') {
        const char *after = strchr(s + 8, ' ');
        if (after) {
            while (*after == ' ') after++;
            if (strncmp(after, "IP ", 3) == 0) after += 3;
            else if (strncmp(after, "IP6 ", 4) == 0) after += 4;
            snprintf(compact, sizeof(compact), "%.8s %s", s, after);
            s = compact;
        }
    }

    struct pkt_line pl;
    snprintf(pl.text, sizeof(pl.text), "%.51s", s);
    pl.col = col;

    if (*ring_cnt < RING_LINES) {
        ring[(*ring_cnt)++] = pl;
    } else {
        memmove(&ring[0], &ring[1], (RING_LINES - 1) * sizeof(*ring));
        ring[RING_LINES - 1] = pl;
    }
}

static void render_ui(const char *ifname, int preset_idx, int running_cap,
                      int pcap_active, const char *pcap_path,
                      const struct pkt_stats *st,
                      const struct pkt_line *ring, int ring_cnt)
{
    fill_rect(0, 0, LCD_W, LCD_H, COL_BG);

    char sub[32];
    snprintf(sub, sizeof(sub), "%s [%s]", ifname, PRESETS[preset_idx].label);
    cz_draw_topbar("PKTSNIFF", sub);

    /* Counter strip (y = 17..29) */
    fill_rect(3, 17, 314, 13, COL_PANEL);
    draw_rect(3, 17, 314, 13, COL_BORDER);
    char cnts[64];
    snprintf(cnts, sizeof(cnts), "TOT:%-5lu TCP:%-4lu UDP:%-4lu DNS:%-3lu ARP:%-3lu EAP:%lu",
             st->total, st->tcp, st->udp, st->dns, st->arp, st->eapol);
    draw_str_clip(6, 20, cnts, 51, COL_CYAN);

    /* Packet stream box (y = 32..136) */
    fill_rect(3, 32, 314, 104, COL_PANEL);
    draw_rect(3, 32, 314, 104, COL_BORDER);

    if (ring_cnt == 0) {
        draw_str(12, 76, running_cap ? "Listening for packets..."
                                     : "Paused - press [4:RUN] to capture",
                 running_cap ? COL_YELLOW : COL_DIM);
    } else {
        for (int i = 0; i < ring_cnt; i++) {
            draw_str_clip(6, 36 + i * 12, ring[i].text, 51, ring[i].col);
        }
    }

    /* PCAP writer status strip (y = 138..150) */
    fill_rect(3, 138, 314, 12, COL_PANEL_ALT);
    draw_rect(3, 138, 314, 12, COL_BORDER);
    if (pcap_active) {
        struct stat pst;
        long kb = (stat(pcap_path, &pst) == 0) ? (long)(pst.st_size / 1024) : 0;
        const char *bn = strrchr(pcap_path, '/');
        bn = bn ? (bn + 1) : pcap_path;
        char ps[96];
        snprintf(ps, sizeof(ps), "REC * %s (%ld KB)", bn, kb);
        draw_str_clip(7, 141, ps, 51, COL_RED);
    } else {
        draw_str(7, 141, "PCAP idle (/home/kali/captures) - [7:PCAP] to record", COL_DIM);
    }

    cz_draw_softkeys(running_cap ? "PAUSE" : "RUN",
                     "FILTER", "IFACE",
                     pcap_active ? "STOPREC" : "PCAP",
                     "EXIT", pcap_active ? 3 : (running_cap ? 0 : -1));
}

int main(void)
{
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    char ifs[MAX_CAP_IFS][20];
    int n_ifs = discover_cap_ifs(ifs);
    int cur_if = 0;
    int preset = 0;

    struct pkt_stats st;
    memset(&st, 0, sizeof(st));
    struct pkt_line ring[RING_LINES];
    int ring_cnt = 0;

    const char *dump_path = getenv("CZ_DUMP_PPM");
    if (dump_path) {
        ingest_tcpdump_line("2026-11-11 15:20:01.102341 IP 192.168.1.42.53120 > 1.1.1.1.53: UDP, length 44", ring, &ring_cnt, &st);
        ingest_tcpdump_line("2026-11-11 15:20:01.208910 ARP, Request who-has 192.168.1.1 tell 192.168.1.42", ring, &ring_cnt, &st);
        ingest_tcpdump_line("2026-11-11 15:20:01.415002 IP 192.168.1.42.49812 > 140.82.121.4.443: tcp 64", ring, &ring_cnt, &st);
        render_ui(ifs[0], 0, 1, 0, "", &st, ring, ring_cnt);
        return cz_dump_ppm(dump_path) == 0 ? 0 : 1;
    }

    struct cz_fb fb;
    if (cz_fb_open(&fb) != 0) {
        fprintf(stderr, "cz-pktsniff: cannot open /dev/fb_lcd\n");
        return 1;
    }

    int in_fds[CZ_MAX_INPUT_FDS];
    int n_in = cz_inputs_open(in_fds, CZ_MAX_INPUT_FDS);

    int cap_fd = -1;
    pid_t cap_pid = start_live_tcpdump(ifs[cur_if], PRESETS[preset].expr, &cap_fd);
    pid_t pcap_pid = -1;
    char pcap_path[128] = "";

    char linebuf[512];
    int linelen = 0;
    double last_ui = 0.0;

    while (g_running) {
        if (cap_fd >= 0) {
            char tmp[1024];
            ssize_t rd;
            while ((rd = read(cap_fd, tmp, sizeof(tmp))) > 0) {
                for (ssize_t i = 0; i < rd; i++) {
                    if (tmp[i] == '\n') {
                        linebuf[linelen] = '\0';
                        ingest_tcpdump_line(linebuf, ring, &ring_cnt, &st);
                        linelen = 0;
                    } else if (tmp[i] != '\r' && linelen < (int)sizeof(linebuf) - 1) {
                        linebuf[linelen++] = tmp[i];
                    }
                }
            }
            int wst = 0;
            if (cap_pid > 0 && waitpid(cap_pid, &wst, WNOHANG) == cap_pid) {
                close(cap_fd);
                cap_fd = -1;
                cap_pid = -1;
            }
        }

        double now = cz_mono_sec();
        if (now - last_ui >= 0.1) {
            render_ui(ifs[cur_if], preset, cap_fd >= 0,
                      pcap_pid > 0, pcap_path, &st, ring, ring_cnt);
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
        if (cap_fd >= 0) {
            pfds[nf].fd = cap_fd;
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
                int restart = 0;
                switch (ev.code) {
                    case KEY_ESC:
                    case KEY_Q:
                    case KEY_BACKSPACE:
                    case KEY_8:
                        g_running = 0;
                        break;
                    case KEY_4:
                    case KEY_SPACE:
                        if (cap_fd >= 0) {
                            kill_proc_group(&cap_pid);
                            close(cap_fd);
                            cap_fd = -1;
                        } else {
                            cap_pid = start_live_tcpdump(ifs[cur_if], PRESETS[preset].expr, &cap_fd);
                        }
                        last_ui = 0.0;
                        break;
                    case KEY_5:
                        preset = (preset + 1) % N_PRESETS;
                        restart = 1;
                        break;
                    case KEY_6:
                        cur_if = (cur_if + 1) % n_ifs;
                        restart = 1;
                        break;
                    case KEY_7:
                        if (pcap_pid > 0) {
                            kill_proc_group(&pcap_pid);
                        } else {
                            pcap_pid = start_pcap_writer(ifs[cur_if], PRESETS[preset].expr,
                                                         pcap_path, sizeof(pcap_path));
                        }
                        last_ui = 0.0;
                        break;
                    case KEY_C:
                        memset(&st, 0, sizeof(st));
                        ring_cnt = 0;
                        last_ui = 0.0;
                        break;
                }
                if (restart) {
                    if (cap_fd >= 0) {
                        kill_proc_group(&cap_pid);
                        close(cap_fd);
                        cap_fd = -1;
                    }
                    memset(&st, 0, sizeof(st));
                    ring_cnt = 0;
                    linelen = 0;
                    cap_pid = start_live_tcpdump(ifs[cur_if], PRESETS[preset].expr, &cap_fd);
                    last_ui = 0.0;
                }
            }
        }
    }

    if (cap_fd >= 0) close(cap_fd);
    kill_proc_group(&cap_pid);
    kill_proc_group(&pcap_pid);
    cz_inputs_close(in_fds, n_in);
    cz_fb_close(&fb);
    return 0;
}
