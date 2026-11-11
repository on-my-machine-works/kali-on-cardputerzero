/*
 * cz-lanscan.c — Native 320x170 RGB565 Subnet & Port Inspector
 *                for Kali Linux on M5Stack CardputerZero
 *
 * Softkeys aligned to physical keys '4'..'8' (x = 48, 104, 160, 216, 272):
 *   4: SWEEP    Discover live hosts on active IPv4 subnet (arp-scan / nmap -sn)
 *   5: NEXT     Step host selection (Fn+Up/Dn also scrolls)
 *   6: PORTS    Run fast top-100 TCP port probe on selected host / view results
 *   7: IFACE    Cycle active IPv4 network interfaces
 *   8 / ESC:    Back (from port view) or Exit to APPLaunch
 */

#include "cz_ui.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/wait.h>

#define MAX_HOSTS 128
#define MAX_PORTS 24
#define MAX_NETIFS 8
#define HOST_VIS_ROWS 7

static volatile sig_atomic_t g_running = 1;

static void on_sig(int sig)
{
    (void)sig;
    g_running = 0;
}

struct net_if {
    char name[20];
    char ip[20];
    char cidr[24];
};

struct lan_host {
    char ip[20];
    char mac[20];
    char vendor[28];
    uint32_t ip_num;
    int port_cnt;
    char ports[MAX_PORTS][36];
};

static int cmp_host(const void *a, const void *b)
{
    const struct lan_host *ha = (const struct lan_host *)a;
    const struct lan_host *hb = (const struct lan_host *)b;
    if (ha->ip_num < hb->ip_num) return -1;
    if (ha->ip_num > hb->ip_num) return 1;
    return 0;
}

static int discover_net_ifs(struct net_if *out, int max_n)
{
    memset(out, 0, (size_t)max_n * sizeof(*out));
    int n = 0;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return 0;

    for (struct ifaddrs *it = ifa; it && n < max_n; it = it->ifa_next) {
        if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET) continue;
        if (it->ifa_flags & IFF_LOOPBACK) continue;
        if (!(it->ifa_flags & IFF_UP)) continue;

        struct sockaddr_in *sa = (struct sockaddr_in *)it->ifa_addr;
        struct sockaddr_in *nm = (struct sockaddr_in *)it->ifa_netmask;
        uint32_t ip = ntohl(sa->sin_addr.s_addr);
        uint32_t mask = nm ? ntohl(nm->sin_addr.s_addr) : 0xFFFFFF00U;
        int pfx = 0;
        for (int b = 31; b >= 0; b--) {
            if (mask & (1U << b)) pfx++;
            else break;
        }
        if (pfx < 16 || pfx > 30) pfx = 24;
        uint32_t net = ip & mask;
        struct in_addr na;
        na.s_addr = htonl(net);
        char net_s[20];
        inet_ntop(AF_INET, &na, net_s, sizeof(net_s));

        snprintf(out[n].name, sizeof(out[n].name), "%.19s", it->ifa_name);
        inet_ntop(AF_INET, &sa->sin_addr, out[n].ip, sizeof(out[n].ip));
        snprintf(out[n].cidr, sizeof(out[n].cidr), "%s/%d", net_s, pfx);
        n++;
    }
    freeifaddrs(ifa);
    return n;
}

static pid_t spawn_cmd(const char *cmd, int *out_fd)
{
    int pfd[2];
    if (pipe(pfd) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pfd[0]); close(pfd[1]); return -1; }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); close(dn); }
        close(pfd[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(pfd[1]);
    int fl = fcntl(pfd[0], F_GETFL, 0);
    if (fl >= 0) fcntl(pfd[0], F_SETFL, fl | O_NONBLOCK);
    *out_fd = pfd[0];
    return pid;
}

static int parse_sweep_output(const char *buf, struct lan_host *hosts, int max_n)
{
    int n = 0;
    const char *p = buf;
    while (*p && n < max_n) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char line[256];
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        p = nl ? (nl + 1) : (p + len);

        /* Format 1: arp-scan -> "192.168.1.1\taa:bb:cc:dd:ee:ff\tVendor" */
        if (isdigit((unsigned char)line[0])) {
            char ip[20] = "", mac[20] = "";
            int consumed = 0;
            if (sscanf(line, "%19[0-9.] %19[0-9a-fA-F:]%n", ip, mac, &consumed) == 2) {
                struct in_addr a;
                if (inet_pton(AF_INET, ip, &a) == 1) {
                    int dup = 0;
                    for (int i = 0; i < n; i++)
                        if (strcmp(hosts[i].ip, ip) == 0) { dup = 1; break; }
                    if (!dup) {
                        memset(&hosts[n], 0, sizeof(hosts[n]));
                        snprintf(hosts[n].ip, sizeof(hosts[n].ip), "%s", ip);
                        snprintf(hosts[n].mac, sizeof(hosts[n].mac), "%s", mac);
                        const char *v = line + consumed;
                        while (*v == ' ' || *v == '\t') v++;
                        snprintf(hosts[n].vendor, sizeof(hosts[n].vendor), "%.27s",
                                 *v ? v : "LAN Host");
                        hosts[n].ip_num = ntohl(a.s_addr);
                        n++;
                    }
                }
            }
        } else if (strncmp(line, "Host: ", 6) == 0 && strstr(line, "Status: Up")) {
            /* Format 2: nmap -sn -oG - -> "Host: 192.168.1.1 () Status: Up" */
            char ip[20] = "";
            if (sscanf(line + 6, "%19[0-9.]", ip) == 1) {
                struct in_addr a;
                if (inet_pton(AF_INET, ip, &a) == 1) {
                    int dup = 0;
                    for (int i = 0; i < n; i++)
                        if (strcmp(hosts[i].ip, ip) == 0) { dup = 1; break; }
                    if (!dup) {
                        memset(&hosts[n], 0, sizeof(hosts[n]));
                        snprintf(hosts[n].ip, sizeof(hosts[n].ip), "%s", ip);
                        snprintf(hosts[n].mac, sizeof(hosts[n].mac), "-");
                        snprintf(hosts[n].vendor, sizeof(hosts[n].vendor), "ICMP/ARP Up");
                        hosts[n].ip_num = ntohl(a.s_addr);
                        n++;
                    }
                }
            }
        }
    }
    qsort(hosts, (size_t)n, sizeof(*hosts), cmp_host);
    return n;
}

static void parse_nmap_ports(const char *buf, struct lan_host *h)
{
    h->port_cnt = 0;
    const char *p = buf;
    while (*p && h->port_cnt < MAX_PORTS) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char line[256];
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        p = nl ? (nl + 1) : (p + len);

        if (isdigit((unsigned char)line[0]) && strstr(line, "/tcp") && strstr(line, "open")) {
            char portproto[20] = "", state[16] = "", svc[24] = "";
            if (sscanf(line, "%19s %15s %23s", portproto, state, svc) >= 2) {
                snprintf(h->ports[h->port_cnt++], sizeof(h->ports[0]),
                         "%-10s %-6s %-16s", portproto, state, svc[0] ? svc : "tcp");
            }
        }
    }
}

static void render_ui(const struct net_if *ifs, int n_ifs, int cur_if,
                      const struct lan_host *hosts, int n_hosts, int sel,
                      int detail_view, int busy_mode, const char *status_msg)
{
    fill_rect(0, 0, LCD_W, LCD_H, COL_BG);

    char sub[32] = "";
    if (n_ifs > 0)
        snprintf(sub, sizeof(sub), "%s %s", ifs[cur_if].name, busy_mode ? "*" : "");
    cz_draw_topbar("LANSCAN", sub);

    /* Subnet summary bar */
    fill_rect(3, 17, 314, 13, COL_PANEL);
    draw_rect(3, 17, 314, 13, COL_BORDER);
    char hdr[64];
    if (n_ifs > 0) {
        snprintf(hdr, sizeof(hdr), "NET %-17s Hosts:%-3d %s",
                 ifs[cur_if].cidr, n_hosts, status_msg ? status_msg : "");
    } else {
        snprintf(hdr, sizeof(hdr), "No active IPv4 subnet (connect Wi-Fi/USB)");
    }
    draw_str_clip(7, 20, hdr, 51, busy_mode ? COL_YELLOW : COL_CYAN);

    if (!detail_view) {
        fill_rect(3, 32, 314, 104, COL_PANEL);
        draw_rect(3, 32, 314, 104, COL_BORDER);
        draw_str(7, 35, "IPv4 ADDRESS     MAC / STATE         VENDOR", COL_DIM);
        fill_rect(5, 43, 310, 1, COL_BORDER);

        if (n_hosts == 0) {
            draw_str(12, 74, busy_mode ? "Sweeping local subnet..."
                                       : "Press [4:SWEEP] to discover hosts",
                     busy_mode ? COL_YELLOW : COL_DIM);
        } else {
            int top = (sel >= HOST_VIS_ROWS) ? (sel - HOST_VIS_ROWS + 1) : 0;
            for (int r = 0; r < HOST_VIS_ROWS && (top + r) < n_hosts; r++) {
                int idx = top + r;
                int y = 46 + r * 12;
                if (idx == sel)
                    fill_rect(5, y - 1, 310, 11, COL_SEL_BG);
                char row[64];
                snprintf(row, sizeof(row), "%-15.15s  %-17.17s  %-15.15s",
                         hosts[idx].ip, hosts[idx].mac, hosts[idx].vendor);
                draw_str_clip(7, y + 1, row, 51, (idx == sel) ? COL_WHITE : COL_TEXT);
            }
        }

        fill_rect(3, 138, 314, 12, COL_PANEL_ALT);
        draw_rect(3, 138, 314, 12, COL_BORDER);
        if (n_hosts > 0 && sel >= 0 && sel < n_hosts) {
            char foot[64];
            snprintf(foot, sizeof(foot), "Target %s  OpenPorts:%d  [6/Enter:Probe]",
                     hosts[sel].ip, hosts[sel].port_cnt);
            draw_str_clip(7, 141, foot, 51, COL_GREEN);
        } else {
            draw_str(7, 141, "4:Sweep  5/Arrows:Select  6:Ports  7:If", COL_DIM);
        }

        cz_draw_softkeys("SWEEP", "NEXT", "PORTS", "IFACE", "EXIT",
                         busy_mode == 1 ? 0 : -1);
    } else {
        /* Host Open Ports Detail View */
        fill_rect(3, 32, 314, 118, COL_PANEL);
        draw_rect(3, 32, 314, 118, COL_BORDER);
        const struct lan_host *h = (n_hosts > 0 && sel < n_hosts) ? &hosts[sel] : NULL;
        char th[96];
        snprintf(th, sizeof(th), "HOST %s (%s) - TOP TCP PORTS",
                 h ? h->ip : "-", h ? h->mac : "-");
        draw_str_clip(7, 35, th, 51, COL_GREEN);
        fill_rect(5, 44, 310, 1, COL_BORDER);

        if (!h) {
            draw_str(12, 78, "No host selected.", COL_DIM);
        } else if (busy_mode == 2) {
            draw_str(12, 78, "Probing top 100 TCP ports with nmap...", COL_YELLOW);
        } else if (h->port_cnt == 0) {
            draw_str(12, 78, "0 open ports in top-100 (press 6 to rescan)", COL_DIM);
        } else {
            int lim = h->port_cnt > 8 ? 8 : h->port_cnt;
            for (int i = 0; i < lim; i++) {
                draw_str_clip(9, 48 + i * 12, h->ports[i], 50, COL_TEXT);
            }
        }
        cz_draw_softkeys("SWEEP", "PREV", "RESCAN", "LIST", "BACK",
                         busy_mode == 2 ? 2 : -1);
    }
}

int main(void)
{
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    struct net_if ifs[MAX_NETIFS];
    struct lan_host *hosts = calloc(MAX_HOSTS, sizeof(*hosts));
    if (!hosts) return 1;

    int n_ifs = discover_net_ifs(ifs, MAX_NETIFS);
    int cur_if = 0;
    int n_hosts = 0;
    int sel = 0;
    int detail_view = 0;
    char status_msg[24] = "Ready";

    const char *dump_path = getenv("CZ_DUMP_PPM");
    if (dump_path) {
        if (n_ifs == 0) {
            snprintf(ifs[0].name, sizeof(ifs[0].name), "wlan0");
            snprintf(ifs[0].ip, sizeof(ifs[0].ip), "192.168.1.42");
            snprintf(ifs[0].cidr, sizeof(ifs[0].cidr), "192.168.1.0/24");
            n_ifs = 1;
        }
        const char *sample =
            "192.168.1.1\t24:5a:4c:10:20:30\tUbiquiti Gateway\n"
            "192.168.1.15\tdc:a6:32:aa:bb:cc\tRaspberry Pi Lab\n"
            "192.168.1.42\te4:5f:01:11:22:33\tCardputerZero\n";
        n_hosts = parse_sweep_output(sample, hosts, MAX_HOSTS);
        render_ui(ifs, n_ifs, 0, hosts, n_hosts, 0, 0, 0, "3 up");
        int rc = cz_dump_ppm(dump_path);
        free(hosts);
        return rc == 0 ? 0 : 1;
    }

    struct cz_fb fb;
    if (cz_fb_open(&fb) != 0) {
        fprintf(stderr, "cz-lanscan: cannot open /dev/fb_lcd\n");
        free(hosts);
        return 1;
    }

    int in_fds[CZ_MAX_INPUT_FDS];
    int n_in = cz_inputs_open(in_fds, CZ_MAX_INPUT_FDS);

    int job_fd = -1;
    pid_t job_pid = -1;
    int busy_mode = 0; /* 0=idle, 1=sweep, 2=ports */
    int port_target_idx = 0;
    char *job_buf = NULL;
    size_t job_len = 0, job_cap = 0;

    /* Trigger automatic initial sweep if we have an active subnet */
    if (n_ifs > 0) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
                 "sudo -n arp-scan --interface=%.19s --localnet -q 2>/dev/null || "
                 "nmap -sn -n %.23s -oG - 2>/dev/null",
                 ifs[cur_if].name, ifs[cur_if].cidr);
        job_pid = spawn_cmd(cmd, &job_fd);
        if (job_pid > 0) {
            busy_mode = 1;
            snprintf(status_msg, sizeof(status_msg), "Sweeping");
        }
    }

    double last_ui = 0.0;

    while (g_running) {
        if (job_fd >= 0) {
            char tmp[4096];
            ssize_t rd;
            while ((rd = read(job_fd, tmp, sizeof(tmp))) > 0) {
                if (job_len + (size_t)rd + 1 > job_cap) {
                    size_t ncap = job_cap ? job_cap * 2 : 8192;
                    while (ncap < job_len + (size_t)rd + 1) ncap *= 2;
                    char *nb = realloc(job_buf, ncap);
                    if (!nb) break;
                    job_buf = nb;
                    job_cap = ncap;
                }
                memcpy(job_buf + job_len, tmp, (size_t)rd);
                job_len += (size_t)rd;
                job_buf[job_len] = '\0';
            }
            int wst = 0;
            if (waitpid(job_pid, &wst, WNOHANG) == job_pid) {
                close(job_fd);
                job_fd = -1;
                job_pid = -1;
                if (busy_mode == 1) {
                    n_hosts = job_buf ? parse_sweep_output(job_buf, hosts, MAX_HOSTS) : 0;
                    if (sel >= n_hosts) sel = n_hosts > 0 ? n_hosts - 1 : 0;
                    snprintf(status_msg, sizeof(status_msg), "%d up", n_hosts);
                } else if (busy_mode == 2 && port_target_idx < n_hosts) {
                    if (job_buf) parse_nmap_ports(job_buf, &hosts[port_target_idx]);
                    snprintf(status_msg, sizeof(status_msg), "%d open",
                             hosts[port_target_idx].port_cnt);
                }
                busy_mode = 0;
                job_len = 0;
                last_ui = 0.0;
            }
        }

        double now = cz_mono_sec();
        if (now - last_ui >= 0.1) {
            render_ui(ifs, n_ifs, cur_if, hosts, n_hosts, sel,
                      detail_view, busy_mode, status_msg);
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
        if (job_fd >= 0) {
            pfds[nf].fd = job_fd;
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
                    case KEY_BACKSPACE:
                    case KEY_8:
                        if (detail_view) { detail_view = 0; last_ui = 0.0; }
                        else g_running = 0;
                        break;
                    case KEY_Q:
                        g_running = 0;
                        break;
                    case KEY_4:
                        if (job_fd < 0 && n_ifs > 0) {
                            detail_view = 0;
                            job_len = 0;
                            char cmd[256];
                            snprintf(cmd, sizeof(cmd),
                                     "sudo -n arp-scan --interface=%.19s --localnet -q 2>/dev/null || "
                                     "nmap -sn -n %.23s -oG - 2>/dev/null",
                                     ifs[cur_if].name, ifs[cur_if].cidr);
                            job_pid = spawn_cmd(cmd, &job_fd);
                            if (job_pid > 0) {
                                busy_mode = 1;
                                snprintf(status_msg, sizeof(status_msg), "Sweeping");
                            }
                            last_ui = 0.0;
                        }
                        break;
                    case KEY_5:
                        if (n_hosts > 0) {
                            if (detail_view) sel = (sel + n_hosts - 1) % n_hosts;
                            else sel = (sel + 1) % n_hosts;
                            last_ui = 0.0;
                        }
                        break;
                    case KEY_6:
                    case KEY_ENTER:
                        if (n_hosts > 0 && job_fd < 0) {
                            detail_view = 1;
                            port_target_idx = sel;
                            job_len = 0;
                            char cmd[256];
                            snprintf(cmd, sizeof(cmd),
                                     "nmap -Pn -n --top-ports 100 -T4 --open %.19s 2>/dev/null",
                                     hosts[sel].ip);
                            job_pid = spawn_cmd(cmd, &job_fd);
                            if (job_pid > 0) {
                                busy_mode = 2;
                                snprintf(status_msg, sizeof(status_msg), "Probing");
                            }
                            last_ui = 0.0;
                        }
                        break;
                    case KEY_7:
                        if (detail_view) {
                            detail_view = 0;
                        } else {
                            n_ifs = discover_net_ifs(ifs, MAX_NETIFS);
                            if (n_ifs > 0) cur_if = (cur_if + 1) % n_ifs;
                        }
                        last_ui = 0.0;
                        break;
                    case KEY_UP:
                    case KEY_K:
                        if (sel > 0) { sel--; last_ui = 0.0; }
                        break;
                    case KEY_DOWN:
                    case KEY_J:
                        if (sel + 1 < n_hosts) { sel++; last_ui = 0.0; }
                        break;
                }
            }
        }
    }

    if (job_pid > 0) {
        kill(job_pid, SIGTERM);
        waitpid(job_pid, NULL, WNOHANG);
    }
    if (job_fd >= 0) close(job_fd);
    free(job_buf);
    free(hosts);
    cz_inputs_close(in_fds, n_in);
    cz_fb_close(&fb);
    return 0;
}
