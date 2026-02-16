# FPGA Build Makefile for iCE40UP5K (IceSugar v1.5)
# Override these variables per-project
TOP    ?= top
PCF    ?= icesugar.pcf
FREQ   ?= 12
SRC    ?= $(wildcard *.v)

# Each project builds into its own subdirectory under /build,
# e.g. /build/blinky/, /build/tone/, so examples don't clobber each other.
# The directory name comes from the current working directory.
PROJECT  ?= $(notdir $(CURDIR))
BUILDDIR ?= /build/$(PROJECT)

JSON   = $(BUILDDIR)/$(TOP).json
ASC    = $(BUILDDIR)/$(TOP).asc
BIN    = $(BUILDDIR)/$(TOP).bin

.PHONY: all synth pnr pack sim clean

all: pack

synth: $(JSON)
$(JSON): $(SRC)
	@mkdir -p $(BUILDDIR)
	yosys -p "synth_ice40 -top $(TOP) -json $@" $(SRC)

pnr: $(ASC)
$(ASC): $(JSON) $(PCF)
	nextpnr-ice40 --up5k --package sg48 --freq $(FREQ) --pcf $(PCF) --json $(JSON) --asc $@

pack: $(BIN)
$(BIN): $(ASC)
	icepack $< $@
	@echo "Bitstream ready: $@"

sim: $(SRC)
	iverilog -o $(BUILDDIR)/$(TOP)_tb.vvp $(SRC)
	vvp $(BUILDDIR)/$(TOP)_tb.vvp

clean:
	rm -f $(BUILDDIR)/$(TOP).json $(BUILDDIR)/$(TOP).asc $(BUILDDIR)/$(TOP).bin $(BUILDDIR)/$(TOP)_tb.vvp
