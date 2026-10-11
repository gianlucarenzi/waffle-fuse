# waffle-fuse Makefile
# Builds a standalone FUSE driver for DrawBridge/Waffle floppy reader.
# No Qt dependency; requires libfuse3-dev (Linux), FUSE-T (macOS) or the
# WinFsp headers (Windows, built with MinGW-w64: MSYS2, or a cross compiler
# with e.g. make CXX=x86_64-w64-mingw32-g++-posix WINFSP_INC=.../winfsp/inc).

ifneq ($(filter Windows_NT,$(OS))$(findstring mingw,$(CXX)),)
WINDOWS    := 1
endif

ifdef WINDOWS
# Windows: WinFsp (https://winfsp.dev).  Only its headers are needed to build:
# the DLL is loaded at run time (src/winfsp_load.cpp).  Everything else is
# linked statically, so waffle-fuse.exe needs no MinGW DLLs.
WINFSP_INC  ?= C:/Program Files (x86)/WinFsp/inc
FUSE_CFLAGS ?= -I"$(WINFSP_INC)" -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0601 \
               -Wno-unknown-pragmas -Wno-cast-function-type
FUSE_LIBS   ?= -static -lsetupapi -lws2_32
WINDRES     ?= $(subst windres-posix,windres,$(subst windres-win32,windres,$(subst g++,windres,$(CXX))))
else ifeq ($(shell uname -s),Darwin)
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

ifdef WINDOWS
SRC_SRCS += src/winfsp_load.cpp
endif

ALL_SRCS := $(LIB_SRCS) $(SRC_SRCS)

OBJS     := $(ALL_SRCS:.cpp=.o)

ifdef WINDOWS
TARGET   := waffle-fuse.exe
RES_OBJ  := windows/waffle-fuse.res.o
else
TARGET   := waffle-fuse
RES_OBJ  :=
endif

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

$(TARGET): $(OBJS) $(RES_OBJ)
	$(CXX) -o $@ $^ $(LDFLAGS)

# Windows: manifest (UTF-8 code page, long paths), icon and version information
windows/waffle-fuse.res.o: windows/waffle-fuse.rc windows/waffle-fuse.exe.manifest windows/waffle-fuse.ico
	$(WINDRES) -O coff -I windows $< -o $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

clean:
	rm -f $(OBJS) $(OBJS:.o=.d) $(TARGET) $(RES_OBJ) src/icons_embedded.h

install: $(TARGET)
	install -m 755 $(TARGET) $(PREFIX)/bin/$(TARGET)

# Filesystem tests on disk images (no hardware needed)
test: $(TARGET)
	tests/run-tests.sh

-include $(OBJS:.o=.d)
