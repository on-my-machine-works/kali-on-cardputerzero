/*
 * libcz_fb_lcd.c — Redirect hardcoded "/dev/fb0" opens to "/dev/fb_lcd"
 *
 * On M5Stack CardputerZero with VC4 KMS enabled, vc4drmfb claims /dev/fb0
 * (HDMI) during initramfs while the internal 320x170 ST7789v3 SPI LCD is
 * /dev/fb1 (symlinked by udev to /dev/fb_lcd).
 *
 * Legacy framebuffer apps that hardcode "/dev/fb0" instead of reading
 * LV_LINUX_FBDEV_DEVICE can be launched with CZ_FORCE_FB_LCD=1 and LD_PRELOAD
 * set to this library. Once "/dev/fb0" is redirected to "/dev/fb_lcd", both
 * LD_PRELOAD and CZ_FORCE_FB_LCD are cleared from the environment so child
 * processes run unmodified.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*open_fn_t)(const char *, int, ...);
typedef int (*openat_fn_t)(int, const char *, int, ...);

static const char *resolve_fb_path(const char *pathname, int *redirected)
{
    *redirected = 0;
    if (!pathname || strcmp(pathname, "/dev/fb0") != 0)
        return pathname;

    const char *force = getenv("CZ_FORCE_FB_LCD");
    if (!force || strcmp(force, "1") != 0)
        return pathname;

    const char *target = getenv("CZ_FB_TARGET");
    if (!target || !*target)
        target = "/dev/fb_lcd";

    if (access(target, R_OK | W_OK) == 0) {
        *redirected = 1;
        return target;
    }
    return pathname;
}

static void clear_preload_after_redirect(void)
{
    unsetenv("CZ_FORCE_FB_LCD");
    unsetenv("LD_PRELOAD");
}

int open(const char *pathname, int flags, ...)
{
    static open_fn_t real_open = NULL;
    if (!real_open)
        real_open = (open_fn_t)dlsym(RTLD_NEXT, "open");

    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int redirected = 0;
    const char *target = resolve_fb_path(pathname, &redirected);
    int fd = real_open(target, flags, mode);
    if (redirected && fd >= 0)
        clear_preload_after_redirect();
    return fd;
}

int open64(const char *pathname, int flags, ...)
{
    static open_fn_t real_open64 = NULL;
    if (!real_open64)
        real_open64 = (open_fn_t)dlsym(RTLD_NEXT, "open64");
    if (!real_open64)
        real_open64 = (open_fn_t)dlsym(RTLD_NEXT, "open");

    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int redirected = 0;
    const char *target = resolve_fb_path(pathname, &redirected);
    int fd = real_open64(target, flags, mode);
    if (redirected && fd >= 0)
        clear_preload_after_redirect();
    return fd;
}

int openat(int dirfd, const char *pathname, int flags, ...)
{
    static openat_fn_t real_openat = NULL;
    if (!real_openat)
        real_openat = (openat_fn_t)dlsym(RTLD_NEXT, "openat");

    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int redirected = 0;
    const char *target = resolve_fb_path(pathname, &redirected);
    int fd = real_openat(dirfd, target, flags, mode);
    if (redirected && fd >= 0)
        clear_preload_after_redirect();
    return fd;
}

int openat64(int dirfd, const char *pathname, int flags, ...)
{
    static openat_fn_t real_openat64 = NULL;
    if (!real_openat64)
        real_openat64 = (openat_fn_t)dlsym(RTLD_NEXT, "openat64");
    if (!real_openat64)
        real_openat64 = (openat_fn_t)dlsym(RTLD_NEXT, "openat");

    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    int redirected = 0;
    const char *target = resolve_fb_path(pathname, &redirected);
    int fd = real_openat64(dirfd, target, flags, mode);
    if (redirected && fd >= 0)
        clear_preload_after_redirect();
    return fd;
}
