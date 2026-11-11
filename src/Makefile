CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Werror
LDFLAGS ?=

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= /usr/lib/cz-kali

APPS := \
	cz-sysmon \
	cz-term80 \
	cz-wifiscan \
	cz-lanscan \
	cz-pktsniff \
	cz-usbgadget

SHIM := libcz_fb_lcd.so

.PHONY: all apps shim check install install-apps install-shim clean

all: shim apps

apps: $(APPS)

shim: $(SHIM)

$(SHIM): libcz_fb_lcd.c
	$(CC) -O2 -Wall -Wextra -shared -fPIC $(LDFLAGS) $< -o $@ -ldl

cz-term80: cz-term80.c cz_ui.h
	$(CC) $(CFLAGS) -I. $< -o $@ $(LDFLAGS) -lutil

cz-%: cz-%.c cz_ui.h
	$(CC) $(CFLAGS) -I. $< -o $@ $(LDFLAGS)

check: apps
	@set -e; \
	tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	for app in $(APPS); do \
		CZ_DUMP_PPM="$$tmp" "./$$app"; \
		test "$$(wc -c < "$$tmp")" -eq 163215; \
	done; \
	echo "[OK] All 6 320x170 apps rendered valid PPM frames"

install: install-shim install-apps

install-shim: $(SHIM)
	install -d -m 755 "$(DESTDIR)$(LIBDIR)"
	install -m 755 $(SHIM) "$(DESTDIR)$(LIBDIR)/$(SHIM)"

install-apps: $(APPS)
	install -d -m 755 "$(DESTDIR)$(BINDIR)"
	install -m 755 $(APPS) "$(DESTDIR)$(BINDIR)/"

clean:
	rm -f $(APPS) $(SHIM) *.o
