/*
 * cz-usbgadget.c — Native 320x170 RGB565 USB-C OTG Mode Switcher & SSH QR Panel
 *                  for Kali Linux on M5Stack CardputerZero
 *
 * Softkeys aligned to physical keys '4'..'8' (x = 48, 104, 160, 216, 272):
 *   4: NET      USB Ethernet tether (10.55.0.1/24) over USB-C OTG
 *   5: HID      USB HID Keyboard + Mouse (/dev/hidg0, /dev/hidg1)
 *   6: COMBO    Composite USB Ethernet + HID gadget
 *   7: OFF      Disable gadget & return USB mux to Host mode
 *   8 / ESC:    Exit to APPLaunch
 */

#include "cz_ui.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

#define QR_MAX 64

static volatile sig_atomic_t g_running = 1;

static void on_sig(int sig)
{
    (void)sig;
    g_running = 0;
}

struct usb_state {
    char mode[20];
    char udc_name[32];
    char udc_state[24];
    long mux_device;
    char usb_ip[20];
    char wlan_ip[20];
    char other_ip[20];
    int active_slot; /* 0=NET, 1=HID, 2=COMBO, 3=OFF */
};

static void read_usb_state(struct usb_state *s)
{
    memset(s, 0, sizeof(*s));
    snprintf(s->mode, sizeof(s->mode), "HOST / OFF");
    snprintf(s->udc_name, sizeof(s->udc_name), "-");
    snprintf(s->udc_state, sizeof(s->udc_state), "detached");
    snprintf(s->usb_ip, sizeof(s->usb_ip), "-");
    snprintf(s->wlan_ip, sizeof(s->wlan_ip), "-");
    snprintf(s->other_ip, sizeof(s->other_ip), "-");
    s->active_slot = 3;

    cz_read_int_file("/sys/class/leds/ext_usb_gpio_fun/brightness", &s->mux_device);

    DIR *ud = opendir("/sys/class/udc");
    if (ud) {
        struct dirent *de;
        while ((de = readdir(ud))) {
            if (de->d_name[0] == '.') continue;
            snprintf(s->udc_name, sizeof(s->udc_name), "%.31s", de->d_name);
            char sp[128];
            snprintf(sp, sizeof(sp), "/sys/class/udc/%.64s/state", de->d_name);
            cz_read_str_file(sp, s->udc_state, sizeof(s->udc_state));
            break;
        }
        closedir(ud);
    }

    char udc_bound[64] = "";
    if (cz_read_str_file("/sys/kernel/config/usb_gadget/kali_cz/UDC",
                         udc_bound, sizeof(udc_bound)) == 0 && udc_bound[0]) {
        struct stat st_net, st_hid;
        int has_net = (stat("/sys/kernel/config/usb_gadget/kali_cz/configs/c.1/ecm.usb0", &st_net) == 0 ||
                       stat("/sys/kernel/config/usb_gadget/kali_cz/configs/c.1/rndis.usb0", &st_net) == 0);
        int has_hid = (stat("/sys/kernel/config/usb_gadget/kali_cz/configs/c.1/hid.usb0", &st_hid) == 0);
        if (has_net && has_hid) {
            snprintf(s->mode, sizeof(s->mode), "COMBO (NET+HID)");
            s->active_slot = 2;
        } else if (has_net) {
            snprintf(s->mode, sizeof(s->mode), "USB ETHERNET");
            s->active_slot = 0;
        } else if (has_hid) {
            snprintf(s->mode, sizeof(s->mode), "USB HID (KB/MS)");
            s->active_slot = 1;
        } else {
            snprintf(s->mode, sizeof(s->mode), "CUSTOM GADGET");
            s->active_slot = -1;
        }
    }

    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) == 0) {
        for (struct ifaddrs *it = ifa; it; it = it->ifa_next) {
            if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET) continue;
            if (it->ifa_flags & IFF_LOOPBACK) continue;
            struct sockaddr_in *sa = (struct sockaddr_in *)it->ifa_addr;
            char ip[20];
            inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip));
            if (strncmp(it->ifa_name, "usb", 3) == 0)
                snprintf(s->usb_ip, sizeof(s->usb_ip), "%s", ip);
            else if (strncmp(it->ifa_name, "wlan", 4) == 0)
                snprintf(s->wlan_ip, sizeof(s->wlan_ip), "%s", ip);
            else
                snprintf(s->other_ip, sizeof(s->other_ip), "%s", ip);
        }
        freeifaddrs(ifa);
    }
}

struct qr_grid {
    int size;
    uint8_t mod[QR_MAX][QR_MAX];
    char payload[96];
};

static void build_qr(const char *text, struct qr_grid *qr)
{
    memset(qr, 0, sizeof(*qr));
    snprintf(qr->payload, sizeof(qr->payload), "%s", text ? text : "");
    if (!text || !*text) return;

    char cmd[256];
    snprintf(cmd, sizeof(cmd), "qrencode -t ASCII -m 0 -l L '%s' 2>/dev/null", text);
    FILE *fp = popen(cmd, "r");
    if (!fp) return;

    char line[256];
    int row = 0;
    int cols = 0;
    while (row < QR_MAX && fgets(line, sizeof(line), fp)) {
        size_t l = strlen(line);
        while (l > 0 && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = '\0';
        if (l < 4) continue;
        int mcol = 0;
        /* qrencode -t ASCII emits "##" per dark module and "  " per light module */
        for (size_t i = 0; i + 1 < l && mcol < QR_MAX; i += 2) {
            qr->mod[row][mcol++] = (line[i] == '#') ? 1 : 0;
        }
        if (mcol > cols) cols = mcol;
        row++;
    }
    pclose(fp);
    qr->size = (row < cols) ? row : cols;
}

static void render_ui(const struct usb_state *s, const struct qr_grid *qr, const char *msg)
{
    fill_rect(0, 0, LCD_W, LCD_H, COL_BG);
    cz_draw_topbar("USBGADGET", s->mux_device ? "OTG-DEV" : "USB-HOST");

    /* Left status panel (x = 3..196, y = 18..149) */
    fill_rect(3, 18, 194, 131, COL_PANEL);
    draw_rect(3, 18, 194, 131, COL_BORDER);

    char ln[64];
    draw_str(8, 23, "GADGET MODE", COL_DIM);
    draw_str_clip(8, 33, s->mode, 30,
                  s->active_slot == 3 ? COL_YELLOW : COL_GREEN);

    fill_rect(7, 44, 186, 1, COL_BORDER);

    snprintf(ln, sizeof(ln), "UDC:   %-22.22s", s->udc_state);
    draw_str(8, 49, ln, COL_CYAN);

    snprintf(ln, sizeof(ln), "MUX:   %s", s->mux_device ? "OTG Gadget" : "Host Port");
    draw_str(8, 61, ln, COL_TEXT);

    snprintf(ln, sizeof(ln), "usb0:  %-18.18s", s->usb_ip);
    draw_str(8, 75, ln, s->usb_ip[0] != '-' ? COL_GREEN : COL_DIM);

    snprintf(ln, sizeof(ln), "wlan0: %-18.18s", s->wlan_ip);
    draw_str(8, 87, ln, s->wlan_ip[0] != '-' ? COL_GREEN : COL_DIM);

    snprintf(ln, sizeof(ln), "eth/o: %-18.18s", s->other_ip);
    draw_str(8, 99, ln, s->other_ip[0] != '-' ? COL_GREEN : COL_DIM);

    fill_rect(7, 111, 186, 1, COL_BORDER);
    draw_str(8, 116, "SSH: kali / kali (port 22)", COL_TEXT);
    draw_str_clip(8, 128, msg ? msg : "4..7:Switch  Space:Flip QR", 30, COL_YELLOW);
    draw_str_clip(8, 139, qr->payload, 30, COL_DIM);

    /* Right QR Code card (x = 200..316, y = 18..149 -> 117x131) */
    fill_rect(200, 18, 117, 131, COL_PANEL);
    draw_rect(200, 18, 117, 131, COL_BORDER);
    draw_str(222, 22, "SSH QR CONNECT", COL_CYAN);

    if (qr->size > 0) {
        int scale = 104 / (qr->size + 4);
        if (scale < 2) scale = 2;
        if (scale > 4) scale = 4;
        int box = (qr->size + 2) * scale;
        int qx = 200 + (117 - box) / 2;
        int qy = 33 + (112 - box) / 2;
        fill_rect(qx, qy, box, box, COL_WHITE);
        for (int r = 0; r < qr->size; r++) {
            for (int c = 0; c < qr->size; c++) {
                if (qr->mod[r][c]) {
                    fill_rect(qx + (c + 1) * scale, qy + (r + 1) * scale,
                              scale, scale, COL_BLACK);
                }
            }
        }
    } else {
        draw_str(214, 76, "No IP active", COL_DIM);
        draw_str(214, 88, "Enable NET/WiFi", COL_DIM);
    }

    cz_draw_softkeys("NET", "HID", "COMBO", "OFF", "EXIT", s->active_slot);
}

static void pick_qr_target(const struct usb_state *s, int prefer_wlan, char *out, size_t sz)
{
    const char *ip = NULL;
    if (prefer_wlan && s->wlan_ip[0] != '-') ip = s->wlan_ip;
    else if (s->usb_ip[0] != '-') ip = s->usb_ip;
    else if (s->wlan_ip[0] != '-') ip = s->wlan_ip;
    else if (s->other_ip[0] != '-') ip = s->other_ip;

    if (ip) snprintf(out, sz, "ssh://kali@%s:22", ip);
    else snprintf(out, sz, "ssh://kali@10.55.0.1:22");
}

static void apply_gadget_mode(const char *arg, struct cz_fb *fb,
                              struct usb_state *s, struct qr_grid *qr)
{
    char msg[32];
    snprintf(msg, sizeof(msg), "Applying %s...", arg);
    render_ui(s, qr, msg);
    cz_fb_blit(fb);

    char cmd[128];
    snprintf(cmd, sizeof(cmd), "sudo -n /usr/local/bin/cz-usb-gadget %s >/dev/null 2>&1", arg);
    int rc = system(cmd);
    (void)rc;
}

int main(void)
{
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    struct usb_state st;
    struct qr_grid qr;
    int prefer_wlan = 1;
    char target[96] = "";
    char msg[32] = "4-7:Mode  Space:QR IP";

    read_usb_state(&st);
    pick_qr_target(&st, prefer_wlan, target, sizeof(target));
    build_qr(target, &qr);

    const char *dump_path = getenv("CZ_DUMP_PPM");
    if (dump_path) {
        if (qr.size == 0) {
            /* Synthesize deterministic finder pattern if qrencode not on build host */
            qr.size = 21;
            snprintf(qr.payload, sizeof(qr.payload), "ssh://kali@10.55.0.1:22");
            for (int r = 0; r < 21; r++)
                for (int c = 0; c < 21; c++)
                    qr.mod[r][c] = (uint8_t)(((r * 7 + c * 3) % 5 == 0) ? 1 : 0);
        }
        render_ui(&st, &qr, msg);
        return cz_dump_ppm(dump_path) == 0 ? 0 : 1;
    }

    struct cz_fb fb;
    if (cz_fb_open(&fb) != 0) {
        fprintf(stderr, "cz-usbgadget: cannot open /dev/fb_lcd\n");
        return 1;
    }

    int in_fds[CZ_MAX_INPUT_FDS];
    int n_in = cz_inputs_open(in_fds, CZ_MAX_INPUT_FDS);

    double next_poll = 0.0;

    while (g_running) {
        double now = cz_mono_sec();
        if (now >= next_poll) {
            read_usb_state(&st);
            char nt[96];
            pick_qr_target(&st, prefer_wlan, nt, sizeof(nt));
            if (strcmp(nt, qr.payload) != 0)
                build_qr(nt, &qr);
            render_ui(&st, &qr, msg);
            cz_fb_blit(&fb);
            next_poll = now + 1.0;
        }

        struct pollfd pfds[CZ_MAX_INPUT_FDS];
        for (int i = 0; i < n_in; i++) {
            pfds[i].fd = in_fds[i];
            pfds[i].events = POLLIN;
            pfds[i].revents = 0;
        }

        if (n_in > 0 && poll(pfds, (nfds_t)n_in, 200) > 0) {
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
                            apply_gadget_mode("net", &fb, &st, &qr);
                            snprintf(msg, sizeof(msg), "USB Ethernet active");
                            next_poll = 0.0;
                            break;
                        case KEY_5:
                            apply_gadget_mode("hid", &fb, &st, &qr);
                            snprintf(msg, sizeof(msg), "USB HID active");
                            next_poll = 0.0;
                            break;
                        case KEY_6:
                            apply_gadget_mode("combo", &fb, &st, &qr);
                            snprintf(msg, sizeof(msg), "Combo NET+HID active");
                            next_poll = 0.0;
                            break;
                        case KEY_7:
                            apply_gadget_mode("off", &fb, &st, &qr);
                            snprintf(msg, sizeof(msg), "USB Gadget disabled");
                            next_poll = 0.0;
                            break;
                        case KEY_SPACE:
                        case KEY_TAB:
                            prefer_wlan = !prefer_wlan;
                            snprintf(msg, sizeof(msg), prefer_wlan ? "QR: Wi-Fi IP" : "QR: USB IP");
                            next_poll = 0.0;
                            break;
                    }
                }
            }
        } else if (n_in == 0) {
            usleep(200000);
        }
    }

    cz_inputs_close(in_fds, n_in);
    cz_fb_close(&fb);
    return 0;
}
