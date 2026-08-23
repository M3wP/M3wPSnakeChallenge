# Builds the Snake Challenge QUADRO server with lazbuild.
#
# Usage:
#   make                 build (default target)
#   make rebuild         force a full rebuild
#   make clean           remove build output
#   make run             build, then run the server
#
# If lazbuild isn't on your PATH, override LAZBUILD, e.g.:
#   make LAZBUILD=/usr/lib/lazarus/lazbuild
#
# Layout: server source lives in src/, compiled units land in obj/
# (set as the .lpi's UnitOutputDirectory), and the built binary lands
# right here in the project root.
#
# The MEGA65 client lives in src/M65/ with its own Makefile (ca65/cl65,
# not lazbuild) - these targets just step in and build there, so both
# are reachable from the repo root without having to cd first:
#   make m65             build the client
#   make m65-run          build, then push to hardware via etherload
#   make m65-dist         build a compressed, self-extracting distributable
#   make m65-clean        remove client build output

ifeq ($(OS),Windows_NT)
LAZBUILD ?= G:/lazarus/lazbuild.exe
else
LAZBUILD ?= lazbuild
endif
PROJECT  := SnakeQuadroCLIServer.lpi
TARGET   := SnakeQuadroCLIServer

.PHONY: all build rebuild clean run m65 m65-run m65-dist m65-clean

all: build

build:
	"$(LAZBUILD)" "$(PROJECT)"

rebuild:
	"$(LAZBUILD)" -B "$(PROJECT)"

clean:
	rm -rf obj
	rm -f "$(TARGET)"

run: build
	./"$(TARGET)"

m65:
	$(MAKE) -C src/M65

m65-run:
	$(MAKE) -C src/M65 run

m65-dist:
	$(MAKE) -C src/M65 dist

m65-clean:
	$(MAKE) -C src/M65 clean
