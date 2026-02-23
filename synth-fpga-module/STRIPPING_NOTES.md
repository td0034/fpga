# Stripping Notes — ULX3S → 50×50mm Synth FPGA Module

> **Goal:** Strip the ULX3S (full ECP5 dev board) down to a minimal stackable FPGA module.
> Keep: ECP5, SDRAM, SPI flash, power regulators, oscillator, JTAG.
> Remove: USB, FTDI, HDMI, LEDs, buttons, ESP32, ADC, audio jack, SD card, LVDS.
> Add: 2.54mm breakout headers, SPI/I2S/config headers for ESP32-S3 carrier.

**Open `ulx3s.kicad_sch` in KiCad 8 and work through each sub-sheet below.**
All component references verified against the actual `.kicad_sch` files.

---

## Root Sheet — `ulx3s.kicad_sch` (Page 1)

Contains 10 sub-sheet references and 4 mounting holes.

| Action | Component | Description |
|--------|-----------|-------------|
| KEEP   | H1, H2, H3 | Mounting holes (reposition for 50×50mm board) |
| DELETE | H4 | Mounting hole marked "Leave empty" |

---

## 1. `power.kicad_sch` (Page 2) — Power Supply

**Purpose:** 3× DCDC regulators (1.1V, 2.5V, 3.3V), RTC, soft-power circuit, FPGA power pins.

### KEEP — Core Power (essential for FPGA operation)

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (unit 9) | LFE5U-85F-6BG381C | FPGA power/ground pins |
| **U3** | TLV62569DBV | 3.3V DCDC regulator |
| **U4** | TLV62569DBV | 2.5V DCDC regulator |
| **U5** | TLV62569DBV | 1.1V DCDC regulator |
| **L1, L2, L3** | 2.2µH | Inductor per regulator |
| **RA1, RA2, RA3** | 15k | Feedback resistor top (one per regulator) |
| **RB1** | 18k | Feedback bottom (3.3V) |
| **RB2** | 4.7k | Feedback bottom (2.5V) |
| **RB3** | 3.3k | Feedback bottom (1.1V) |
| **C1, C3, C4, C5, C7, C8, C9, C11** | 22µF | Bulk input/output caps |
| **C2, C6, C10** | 100pF | HF decoupling per regulator |
| **C13** | 2.2µF | 5V rail cap |
| **C17, C19, C20, C22, C23, C24** | 2.2µF | Output filtering |
| **C25, C26** | 22nF | 1.1V decoupling |
| **C27–C32** | 22nF | Rail decoupling (1.1V/2.5V) |
| **C47–C51** | 22nF | DDR I/O supply decoupling |
| **RP1, RP2, RP3** | 0R (NC) | Rail selection jumpers (leave unpopulated) |

### DELETE — RTC / Soft-Power / Status LED

| Component | Value | Function |
|-----------|-------|----------|
| **U7** | MCP7940NT | RTC (not needed for synth module) |
| **BAT1** | CR1225 | Coin cell battery |
| **Y2** | 32768 Hz | RTC crystal |
| **C54, C56, C57** | 4.7pF | Crystal load caps |
| **C60** | 220nF | RTC supply filtering |
| **Q1** | BC857 | PNP soft-power control |
| **Q2** | 2N7002 | NMOS soft-power switch |
| **B0** | PTS645 | Power button |
| **D10** | 1N914 | Protection diode |
| **D11** | RED LED | Power status LED |
| **D12, D13, D14** | BAT54W / 1N914 | Battery protection diodes |
| **D15** | BAT54W | Power path Schottky |
| **D16, D17** | 1N914 | Supply protection diodes |
| **D27** | 1N914 | Soft-power protection |
| **R1, R2** | 4.7k, 18k | Soft-power divider |
| **R3, R4** | 4.7k | RTC pull-ups |
| **R5** | 2.2M | RTC oscillator damping |
| **R6, R8** | 1.1k | Transistor base drive |
| **R10** | 130 | LED current limit |
| **R13** | 15k | RTC enable pull-up |
| **R65** | 549 | Soft-power feedback |
| **R66** | 1.1k | Gate drive limit |
| **RC1** | 0R | Feedback jumper |
| **RC2** | 91k | Soft-power feedback |
| **C55** | 22µF | Soft-power bypass |

**Freed FPGA pins:** RTC I2C (SDA/SCL from U7), soft-power control lines.

---

## 2. `blinkey.kicad_sch` (Page 6) — LEDs, Buttons, OLED, DIP Switch

**Purpose:** User interface: 11 LEDs, 6 buttons, OLED display, DIP switch.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| **B1** | PTS645 | FPGA reset button (useful during dev) |
| **R7** | 130 | B1 pull-up resistor |

### DELETE — Everything else

| Component | Value | Function |
|-----------|-------|----------|
| **D0–D7** | RED/ORANGE/GREEN/BLUE | 8× status LEDs |
| **D18** | GREEN | Additional LED |
| **D19** | RED | Additional LED |
| **D22** | BLUE | Additional LED |
| **B2, B3, B4, B5, B6** | PTS645 | 5× user buttons |
| **SW1** | SW_DIP_x04 | 4-position DIP switch |
| **LCD1** | ST7789 | OLED display header |
| **C46** | 2.2µF | LCD bypass cap |
| **R36, R37** | 549 | LED/LCD resistors |
| **R39** | 130 | LED resistor |
| **R41–R48** | 549 | LCD data line resistors (8×) |
| **R51** | 130 | LCD control resistor |
| **R62** | 549 | LCD control resistor |

**Freed FPGA pins:** 8 LED pins, 5 button pins, 4 DIP switch pins, ~10 OLED/LCD SPI pins. (~27 pins total — prime header breakout candidates.)

---

## 3. `ram.kicad_sch` (Page 8) — SDRAM

**Purpose:** 32 MB SDRAM (MT48LC16M16A2TG) + FPGA I/O banks 3 & 4.

### KEEP — Everything (do not touch this sheet)

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (units 3+4) | LFE5U-85F-6BG381C | FPGA SDRAM I/O banks |
| **U2** | MT48LC16M16A2TG | 32 MB SDRAM |
| **C16** | 2.2µF | SDRAM bulk decoupling |
| **C33, C34, C35, C52** | 22nF | SDRAM HF decoupling |

**Freed FPGA pins:** None — all used by SDRAM bus.

---

## 4. `flash.kicad_sch` (Page 11) — SPI Configuration Flash

**Purpose:** FPGA bitstream storage, config signals (PROGRAMN/INITN/DONE).

### KEEP — Everything (do not touch this sheet)

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (unit 7) | LFE5U-85F-6BG381C | FPGA config pins |
| **U10** | IS25LP128F-JBLE | 128 Mbit SPI flash |
| **R11** | 10k | Pull-up |
| **R12** | Resistor | Config resistor |
| **R27** | 10k | Pull-up |
| **R28** | 10k | Pull-up |
| **R29** | 1.1k | Current limit |
| **R30** | 4.7k | Pull-up |
| **R31, R32, R33** | Resistors | Config pull-ups/limits |
| **D28, D29** | Diodes | Config signal protection |

**Note:** The PROGRAMN/INITN/DONE signals here are what the ESP32-S3 will drive for FPGA configuration. You'll wire these to the **FPGA config header** (see "What to Add" section).

---

## 5. `usb.kicad_sch` (Page 4) — USB, FTDI, Oscillator, JTAG

**Purpose:** FTDI USB-UART bridge, 2× USB connectors, 25 MHz oscillator, JTAG header.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (units 5+10) | LFE5U-85F-6BG381C | FPGA I/O bank units on this sheet |
| **Y1** | FNETHE025 (25 MHz) | Main oscillator (ECP5 PLL reference) |
| **J4** | CONN_02X03 | JTAG header (essential for debug) |
| **R63, R64** | 15k | JTAG pull-ups |

### DELETE — FTDI and USB

| Component | Value | Function |
|-----------|-------|----------|
| **U6** | FT231XQ | FTDI USB-UART bridge |
| **US1** | MICRO_USB | USB OTG connector 1 |
| **US2** | MICRO_USB | USB OTG connector 2 |
| **AE1** | 433MHz | Antenna (FTDI-related) |
| **D8** | STPS2L40AF | USB power Schottky |
| **D9** | 0 (jumper) | Power path jumper |
| **D20, D21** | 3.6V | USB Zener clamps |
| **D23, D24, D25, D26** | 1N914 | Signal diodes |
| **R9** | 15k | FTDI pull-up |
| **R40** | 1.1k | USB current limit |
| **R49, R50** | 27 | USB differential termination |
| **R52, R53** | 27 | USB differential termination |
| **R54** | 1.1k | USB current limit |

**Freed FPGA pins:** FTDI UART TX/RX, USB data lines. These become available for header breakout or ESP32 SPI.

---

## 6. `gpio.kicad_sch` (Page 3) — GPIO Headers

**Purpose:** 2× 40-pin (2×20) headers exposing FPGA I/O banks 1 & 6.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (units 1+6) | LFE5U-85F-6BG381C | FPGA GPIO bank pin definitions |

### DELETE

| Component | Value | Function |
|-----------|-------|----------|
| **J1** | CONN_02X20 | 40-pin GPIO header 1 |
| **J2** | CONN_02X20 | 40-pin GPIO header 2 |
| **D51, D52** | 0 (jumpers) | Power path diodes/jumpers |
| All `#PWR` symbols | — | Header power rail symbols |

**Freed FPGA pins:** All GPIO from banks 1+6 — this is the main pool for your breakout headers. Count the pins on J1/J2 (minus power/ground) to determine how many FPGA I/O you have available.

---

## 7. `gpdi.kicad_sch` (Page 5) — HDMI / GPDI

**Purpose:** HDMI output via GPDI connector, PCA9306 I2C level shifter, FPGA I/O bank 2.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (unit 2) | LFE5U-85F-6BG381C | FPGA differential I/O bank |

### DELETE — Everything else

| Component | Value | Function |
|-----------|-------|----------|
| **GPDI1** | GPDI-D | HDMI connector |
| **U11** | PCA9306D | I2C level shifter |
| **C18** | 100pF | Filter cap |
| **C38–C45** | 22nF | HDMI coupling caps (8×) |
| **D30** | 3.6V | Zener clamp |
| **R22, R23** | 3.3k | Level shifter resistors |
| **R24** | 100k | Pull-up |
| **R25, R26** | 4.7k | Pull-ups |
| **R55** | 10k | Pull-up |
| **R61** | 549 | Resistor |
| **R67** | 549 | Resistor |

**Freed FPGA pins:** 4× TMDS differential pairs (8 pins) + HDMI clock pair (2 pins) + I2C (2 pins) = ~12 pins. These are high-speed differential pairs — excellent for I2S audio or fast SPI.

---

## 8. `analog.kicad_sch` (Page 7) — ADC + Audio Jack

**Purpose:** MAX11125 ADC, resistor-ladder DAC, audio TRS jack.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| (Any **U1** unit refs) | — | FPGA pins referenced on this sheet |

### DELETE — Everything

| Component | Value | Function |
|-----------|-------|----------|
| **U8** | MAX11125 | 16-channel ADC |
| **AUDIO1** | JACK_TRS_6PINS | Audio TRS jack |
| **L4, L5** | 33µH | Analog supply inductors |
| **C58, C61** | 22µF | Analog bulk caps |
| **C59, C62** | 220nF | Analog filter caps |
| **R14–R21** | 130/270/549/1.1k | Resistor ladder DAC (2 channels, 4 per channel) |
| **R57–R60** | 130/270/549/1.1k | Resistor ladder DAC (3rd channel) |

**Freed FPGA pins:** ADC SPI bus (~6 pins), DAC output pins (~6 pins), audio analog pins.

---

## 9. `wifi.kicad_sch` (Page 9) — ESP32 + SD Card

**Purpose:** ESP32 WiFi module, SD card slot, supporting passives.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| (Any **U1** unit refs) | — | FPGA pins referenced on this sheet |

### DELETE — Everything else

| Component | Value | Function |
|-----------|-------|----------|
| **U9** | ESP32 | WiFi/BT module |
| **SD1** | SD card | SD card connector |
| **J3** | WIFI_OFF | WiFi disable jumper |
| **R34** | 15k | ESP32 pull-up |
| **R35** | 549 | ESP32 resistor |
| **R38** | Resistor | ESP32 resistor |
| **R56** | Resistor | SD card resistor |
| **C15** | Capacitor | ESP32 bypass |
| **C21** | 22µF | ESP32 bulk cap |

**Freed FPGA pins:** ESP32 SPI bus, SD card SPI/SDIO bus, GPIO from ESP32 connections. These FPGA pins get reassigned to the new ESP32-S3 interface headers.

---

## 10. `serdes.kicad_sch` (Page 10) — LVDS / SerDes

**Purpose:** LVDS connector, coupling caps, FPGA SERDES unit 8.

### KEEP

| Component | Value | Function |
|-----------|-------|----------|
| **U1** (unit 8) | LFE5U-85F-6BG381C | FPGA SERDES pins |

### DELETE — Everything else

| Component | Value | Function |
|-----------|-------|----------|
| **US3** | Connector | LVDS connector |
| **C63–C72** | 22nF | LVDS coupling caps (10×) |

**Freed FPGA pins:** SERDES differential pairs — high-speed capable.

---

## After Stripping — What to ADD

Once all deletions are complete, add these new symbols/connections. Use the **gpio.kicad_sch** or **blinkey.kicad_sch** sheets (now mostly empty) as homes for the new connectors.

### 1. Main Breakout Headers (on `gpio.kicad_sch`)

Replace J1/J2 with new 2.54mm pin headers sized for the 50×50mm board. Wire freed FPGA pins using global labels matching the original net names.

| Header | Symbol | Pins | Purpose |
|--------|--------|------|---------|
| J_GPIO1 | Conn_02x20 | 40 | Main FPGA I/O breakout (left side) |
| J_GPIO2 | Conn_02x20 | 40 | Main FPGA I/O breakout (right side) |

Pin assignment priority:
1. All Bank 1 + Bank 6 GPIO (from stripped J1/J2)
2. Freed LED/button/DIP pins from `blinkey`
3. Freed HDMI differential pairs from `gpdi`
4. Freed FTDI/USB pins from `usb`
5. Power rails: 3.3V, 2.5V, 1.1V, 5V, GND on multiple pins

### 2. Power Input Header (on `power.kicad_sch`)

| Header | Symbol | Pins | Signals |
|--------|--------|------|---------|
| J_PWR | Conn_01x04 | 4 | 5V, 3.3V, GND, GND |

The ESP32-S3 carrier provides 5V via USB-C. The module's onboard regulators derive 3.3V/2.5V/1.1V.

### 3. ESP32-S3 SPI Control Header (on `wifi.kicad_sch`)

| Header | Symbol | Pins | Signals |
|--------|--------|------|---------|
| J_SPI | Conn_01x06 | 6 | SCK, MOSI, MISO, CS, GND, 3.3V |

Runtime communication bus — ESP32-S3 sends synth parameters, wavetables, preset data to FPGA.

### 4. FPGA Configuration Header (on `flash.kicad_sch`)

| Header | Symbol | Pins | Signals |
|--------|--------|------|---------|
| J_CFG | Conn_01x07 | 7 | CRESET_B, CDONE, CFG_CS, CFG_SCK, CFG_MOSI, GND, 3.3V |

ESP32-S3 programs the FPGA bitstream via SPI slave config mode. Connect to the PROGRAMN/INITN/DONE nets already on this sheet.

### 5. I2S Audio Header (on `analog.kicad_sch`)

| Header | Symbol | Pins | Signals |
|--------|--------|------|---------|
| J_I2S | Conn_01x07 | 7 | BCLK, LRCK, DAC_DATA, ADC_DATA, ADC_SCKI, GND, 3.3V |

Routes to external audio codec (e.g. PCM5102A DAC + PCM1808 ADC) on the carrier board.

### 6. Board Outline (PCB)

1. Rename `ulx3s.kicad_pcb` → `ulx3s_reference.kicad_pcb`
2. Create a new blank `synth_fpga_module.kicad_pcb` with 50×50mm outline
3. Copy BGA fanout pattern and SDRAM routing from the reference PCB
4. Place headers along board edges (2.54mm pitch, stackable)
5. Reposition mounting holes H1–H3 for 50×50mm corners

---

## Pin Budget Summary

| Source Sheet | Freed Pins (approx) | Notes |
|-------------|---------------------|-------|
| blinkey | ~27 | LEDs, buttons, DIP, OLED |
| gpio | ~40 | Bank 1+6 GPIO (main pool) |
| gpdi | ~12 | HDMI differential pairs |
| usb | ~6 | FTDI UART, USB data |
| analog | ~12 | ADC SPI, DAC outputs |
| wifi | ~12 | ESP32 SPI, SD card |
| serdes | ~8 | LVDS differential |
| **Total** | **~117** | Available for headers + new interfaces |

Subtract allocations:
- SPI control: 4 pins
- FPGA config: 3 pins (CRESET/CDONE/CFG_CS share with flash sheet)
- I2S audio: 5 pins
- **Remaining for breakout headers: ~105 pins**

---

## Checklist

- [ ] Strip `power.kicad_sch` — delete RTC/soft-power section
- [ ] Strip `blinkey.kicad_sch` — delete all LEDs/buttons/OLED except B1
- [ ] Verify `ram.kicad_sch` — no changes needed
- [ ] Verify `flash.kicad_sch` — no changes needed
- [ ] Strip `usb.kicad_sch` — delete FTDI/USB, keep Y1/J4
- [ ] Strip `gpio.kicad_sch` — delete J1/J2 headers
- [ ] Strip `gpdi.kicad_sch` — delete HDMI connector and level shifters
- [ ] Strip `analog.kicad_sch` — delete ADC/audio jack/DAC
- [ ] Strip `wifi.kicad_sch` — delete ESP32/SD card
- [ ] Strip `serdes.kicad_sch` — delete LVDS connector and caps
- [ ] Add power input header
- [ ] Add SPI control header
- [ ] Add FPGA config header
- [ ] Add I2S audio header
- [ ] Add main breakout headers
- [ ] Rename PCB, create new 50×50mm board outline
- [ ] Run ERC after all changes
- [ ] Annotate and assign footprints to new components
