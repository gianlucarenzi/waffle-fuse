# waffle-fuse Makefile
# Builds a standalone FUSE driver for DrawBridge/Waffle floppy reader.
# No Qt dependency; requires libfuse3-dev (Linux) or FUSE-T (macOS).

ifeq ($(shell uname -s),Darwin)
# macOS: FUSE-T (https://www.fuse-t.org) installs libfuse3 under /usr/local
CXX        := clang++
FUSE_CFLAGS ?= -I/usr/local/include -I/usr/local/include/fuse3
FUSE_LIBS   ?= -L/usr/local/lib -Wl,-rpath,/usr/local/lib -lfuse3
else
CXX        := g++
FUSE_CFLAGS ?= $(shell pkg-config --cflags fuse3)
# Release builds (CI) link libfuse3 statically: its soname changed from
# libfuse3.so.3 to libfuse3.so.4 in fuse 3.17, so a dynamic link only runs on
# distributions with the same fuse version as the build machine.
FUSE_LIBS   ?= $(shell pkg-config --libs fuse3)
endif

CXXFLAGS := -std=c++17 -O2 -Wall -Wextra \
            -D_FILE_OFFSET_BITS=64 \
            -DOUTPUT_TIME_IN_NS \
            -Isrc -Ilib -Ilib/capsapi -Iinc \
            $(FUSE_CFLAGS)
# EXTRA_CXXFLAGS / EXTRA_LDFLAGS: e.g. -arch arm64 -mmacosx-version-min=12.0
# (macOS release builds), -static-libstdc++ -static-libgcc (Linux release builds)
CXXFLAGS += $(EXTRA_CXXFLAGS)

LDFLAGS  := $(FUSE_LIBS) -lpthread
LDFLAGS  += $(EXTRA_LDFLAGS)

PREFIX   ?= /usr/local

# ── Source files ──────────────────────────────────────────────────────────────
LIB_SRCS := lib/ADFWriter.cpp \
            lib/ArduinoInterface.cpp \
            lib/SerialIO.cpp \
            lib/RotationExtractor.cpp \
            lib/pll.cpp \
            lib/ibm_sectors.cpp \
            lib/ftdi.cpp \
            lib/debugmsg.cpp

SRC_SRCS := src/disk_cache.cpp \
            src/format.cpp \
            src/fat_fs.cpp \
            src/affs_fs.cpp \
            src/waffle_fuse.cpp

ALL_SRCS := $(LIB_SRCS) $(SRC_SRCS)

OBJS     := $(ALL_SRCS:.cpp=.o)

TARGET   := waffle-fuse

.DEFAULT_GOAL := all

# Volume icons embedded in the binary (served as /.waffle-icon.svg)
src/icons_embedded.h: icons/amiga-floppy.svg icons/dos-floppy.svg
	{ echo '// Generated from icons/*.svg by the Makefile - do not edit'; \
	  printf 'static const char kAmigaVolumeIcon[] = R"SVG('; cat icons/amiga-floppy.svg; echo ')SVG";'; \
	  printf 'static const char kDosVolumeIcon[] = R"SVG('; cat icons/dos-floppy.svg; echo ')SVG";'; } > $@

src/waffle_fuse.o: src/icons_embedded.h

# ── Build rules ───────────────────────────────────────────────────────────────
.PHONY: all clean install test

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) -o $@ $^ $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

clean:
	rm -f $(OBJS) $(OBJS:.o=.d) $(TARGET) src/icons_embedded.h

install: $(TARGET)
	install -m 755 $(TARGET) $(PREFIX)/bin/$(TARGET)

# Filesystem tests on disk images (no hardware needed)
test: $(TARGET)
	tests/run-tests.sh

-include $(OBJS:.o=.d)
