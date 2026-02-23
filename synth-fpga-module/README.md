# Synth FPGA Module

50×50mm stackable ECP5 FPGA module for the granular synthesiser project.

## What is this?

A stripped-down derivative of the [ULX3S](https://github.com/emard/ulx3s) (EMARD, Radiona.org) — the full-featured Lattice ECP5 development board. We keep the core FPGA subsystem and expose everything else via 2.54mm headers for stacking onto an ESP32-S3 carrier board.

## Core retained from ULX3S

- **ECP5 FPGA** — LFE5U-85F-6BG381C (BGA-381)
- **32 MB SDRAM** — MT48LC16M16A2TG (wavetable/delay buffer)
- **128 Mbit SPI flash** — IS25LP128F (bitstream storage)
- **25 MHz oscillator** — PLL reference clock
- **3× DCDC regulators** — TLV62569DBV (3.3V, 2.5V, 1.1V)
- **JTAG header** — 6-pin programming/debug

## Stripped from ULX3S

USB connectors, FTDI USB-UART, HDMI output, ESP32, SD card slot, MAX11125 ADC, audio jack, resistor-ladder DAC, LEDs, buttons, DIP switch, OLED display, LVDS connector, RTC, coin cell battery.

## Header interfaces (to be added)

| Header | Pins | Purpose |
|--------|------|---------|
| J_GPIO1/2 | 2×40 | Main FPGA I/O breakout (2.54mm, stackable) |
| J_PWR | 4 | 5V/3.3V power input from carrier |
| J_SPI | 6 | ESP32-S3 runtime SPI bus |
| J_CFG | 7 | ESP32-S3 FPGA configuration (SPI slave) |
| J_I2S | 7 | I2S audio (BCLK/LRCK/DAC/ADC) |

## How to use

1. Open `ulx3s.kicad_sch` in KiCad 8
2. Follow `STRIPPING_NOTES.md` — strip components sheet by sheet
3. Add new header connectors per the notes
4. Create fresh 50×50mm PCB layout, copying BGA fanout from reference

## Original project

Based on [ULX3S by EMARD](https://github.com/emard/ulx3s), licensed under the original project's terms. See `LICENSE.md`.
