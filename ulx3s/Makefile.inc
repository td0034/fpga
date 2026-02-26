# FPGA Build Makefile for ECP5 (ULX3S)
# Override these variables per-project
TOP    ?= top
LPF    ?= ulx3s.lpf
FREQ   ?= 25
SRC    ?= $(wildcard *.v)
DEVICE ?= --85k
PACKAGE ?= CABGA381

# Each project builds into its own subdirectory under build/,
# e.g. build/blinky/, so examples don't clobber each other.
# The directory name comes from the current working directory.
# Relative path works both natively and inside Docker.
PROJECT  ?= $(notdir $(CURDIR))
BUILDDIR ?= ../../build/$(PROJECT)

JSON   = $(BUILDDIR)/$(TOP).json
CONFIG = $(BUILDDIR)/$(TOP).config
BIT    = $(BUILDDIR)/$(TOP).bit

.PHONY: all synth pnr pack sim clean

all: pack

synth: $(JSON)
$(JSON): $(SRC)
	@mkdir -p $(BUILDDIR)
	yosys -p "synth_ecp5 -top $(TOP) -json $@" $(SRC)

pnr: $(CONFIG)
$(CONFIG): $(JSON) $(LPF)
	nextpnr-ecp5 $(DEVICE) --package $(PACKAGE) --freq $(FREQ) --lpf $(LPF) --json $(JSON) --textcfg $@

pack: $(BIT)
$(BIT): $(CONFIG)
	ecppack $< $@
	@echo "Bitstream ready: $@"

sim: $(SRC)
	iverilog -o $(BUILDDIR)/$(TOP)_tb.vvp $(SRC)
	vvp $(BUILDDIR)/$(TOP)_tb.vvp

clean:
	rm -f $(BUILDDIR)/$(TOP).json $(BUILDDIR)/$(TOP).config $(BUILDDIR)/$(TOP).bit $(BUILDDIR)/$(TOP)_tb.vvp
