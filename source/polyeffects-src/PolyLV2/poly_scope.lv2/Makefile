#!/usr/bin/make -f
OPTIMIZATIONS ?= -ffast-math -fomit-frame-pointer -O3 -fno-finite-math-only -DNDEBUG
PREFIX ?= /usr
CFLAGS ?= $(OPTIMIZATIONS) -Wall
URI_PREFIX = '"http://polyeffects.com/lv2"'

PKG_CONFIG ?= pkg-config
STRIP ?= strip
STRIPFLAGS ?= -s

LV2DIR ?= $(PREFIX)/lib/lv2
LOADLIBES = -lm
LV2NAME = poly_scope
BUNDLE = poly_scope.lv2
BUILDDIR = build/
targets =

UNAME := $(shell uname)
ifeq ($(UNAME),Darwin)
  LV2LDFLAGS = -dynamiclib
  LIB_EXT = .dylib
  STRIPFLAGS = -u -r -arch all -s lv2syms
  targets += lv2syms
else
  LV2LDFLAGS = -Wl,-Bstatic -Wl,-Bdynamic
  LIB_EXT = .so
endif

ifneq ($(XWIN),)
  CC = $(XWIN)-gcc
  STRIP = $(XWIN)-strip
  LV2LDFLAGS = -Wl,-Bstatic -Wl,-Bdynamic -Wl,--as-needed
  LIB_EXT = .dll
  override LDFLAGS += -static-libgcc -static-libstdc++
else
  override CFLAGS += -fPIC -fvisibility=hidden
endif

targets += $(BUILDDIR)$(LV2NAME)$(LIB_EXT)

ifeq ($(shell $(PKG_CONFIG) --exists lv2 || echo no),no)
  $(error "LV2 SDK was not found")
endif

override CFLAGS += `$(PKG_CONFIG) --cflags lv2`

default: all

all: $(BUILDDIR)manifest.ttl $(BUILDDIR)$(LV2NAME).ttl $(targets)

lv2syms:
	echo "_lv2_descriptor" > lv2syms

$(BUILDDIR)manifest.ttl: manifest.ttl
	@mkdir -p $(BUILDDIR)
	cat manifest.ttl > $(BUILDDIR)manifest.ttl

$(BUILDDIR)$(LV2NAME).ttl: $(LV2NAME).ttl
	@mkdir -p $(BUILDDIR)
	cat $(LV2NAME).ttl > $(BUILDDIR)$(LV2NAME).ttl

$(BUILDDIR)$(LV2NAME)$(LIB_EXT): $(LV2NAME).c
	@mkdir -p $(BUILDDIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) \
		-o $(BUILDDIR)$(LV2NAME)$(LIB_EXT) $(LV2NAME).c \
		-shared -DURI_PREFIX=$(URI_PREFIX) $(LV2LDFLAGS) $(LDFLAGS) $(LOADLIBES)
	$(STRIP) $(STRIPFLAGS) $(BUILDDIR)$(LV2NAME)$(LIB_EXT)

install: all
	install -d $(DESTDIR)$(LV2DIR)/$(BUNDLE)
	install -m755 $(BUILDDIR)$(LV2NAME)$(LIB_EXT) $(DESTDIR)$(LV2DIR)/$(BUNDLE)
	install -m644 $(BUILDDIR)manifest.ttl $(BUILDDIR)$(LV2NAME).ttl $(DESTDIR)$(LV2DIR)/$(BUNDLE)

uninstall:
	rm -f $(DESTDIR)$(LV2DIR)/$(BUNDLE)/manifest.ttl
	rm -f $(DESTDIR)$(LV2DIR)/$(BUNDLE)/$(LV2NAME).ttl
	rm -f $(DESTDIR)$(LV2DIR)/$(BUNDLE)/$(LV2NAME)$(LIB_EXT)
	-rmdir $(DESTDIR)$(LV2DIR)/$(BUNDLE)

clean:
	rm -f $(BUILDDIR)manifest.ttl $(BUILDDIR)$(LV2NAME).ttl $(BUILDDIR)$(LV2NAME).so $(BUILDDIR)$(LV2NAME).dylib $(BUILDDIR)$(LV2NAME).dll lv2syms
	-test -d $(BUILDDIR) && rmdir $(BUILDDIR) || true

.PHONY: clean all install uninstall
