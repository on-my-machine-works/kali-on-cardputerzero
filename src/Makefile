CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Werror
LDFLAGS ?=

TARGET_ARCH := $(shell $(CC) -dumpmachine 2>/dev/null | cut -d- -f1)
ifeq ($(TARGET_ARCH),aarch64)
ARCH_CFLAGS := -march=armv8-a+crc
else
ARCH_CFLAGS :=
endif

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

TERM_APP := cz-term
SHIM := libcz_fb_lcd.so

.PHONY: all apps shim check install install-apps install-shim clean

all: shim apps

apps: $(APPS) $(TERM_APP)

shim: $(SHIM)

$(SHIM): libcz_fb_lcd.c
	$(CC) -O2 -Wall -Wextra $(ARCH_CFLAGS) -shared -fPIC $(LDFLAGS) $< -o $@ -ldl

cz-term80: cz-term80.c cz_ui.h
	$(CC) $(CFLAGS) $(ARCH_CFLAGS) -I. $< -o $@ $(LDFLAGS) -lutil

cz-term: cz-term.c flipper_term_fonts.h
	$(CC) -O2 -Wall -Wextra $(ARCH_CFLAGS) -I. $< -o $@ $(LDFLAGS) -lutil

cz-%: cz-%.c cz_ui.h
	$(CC) $(CFLAGS) $(ARCH_CFLAGS) -I. $< -o $@ $(LDFLAGS)

check: apps
	@set -e; \
	tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	for app in $(APPS); do \
		CZ_DUMP_PPM="$$tmp" "./$$app"; \
		test "$$(wc -c < "$$tmp")" -eq 163215; \
	done; \
	echo "[OK] All 6 320x170 apps rendered valid PPM frames (plus $(TERM_APP) compiled)"

install: install-shim install-apps

install-shim: $(SHIM)
	install -d -m 755 "$(DESTDIR)$(LIBDIR)"
	install -m 755 $(SHIM) "$(DESTDIR)$(LIBDIR)/$(SHIM)"

install-apps: $(APPS) $(TERM_APP)
	install -d -m 755 "$(DESTDIR)$(BINDIR)"
	install -m 755 $(APPS) $(TERM_APP) "$(DESTDIR)$(BINDIR)/"
	ln -sfn cz-term "$(DESTDIR)$(BINDIR)/cz-flipper-term"
	if [ -d "$(DESTDIR)/usr/bin" ] || [ -n "$(DESTDIR)" ]; then \
		install -d -m 755 "$(DESTDIR)/usr/bin"; \
		install -m 755 $(TERM_APP) "$(DESTDIR)/usr/bin/cz-term"; \
		ln -sfn cz-term "$(DESTDIR)/usr/bin/cz-flipper-term"; \
	fi

clean:
	rm -f $(APPS) $(TERM_APP) $(SHIM) *.o
