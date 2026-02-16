# Granular Synth Engine — Development Plan

A granular synthesis engine targeting ~1000 simultaneous grains, built on open-source FPGA tooling. Prototyped on iCE40UP5K (IceSugar v1.5), scaled to ECP5-85K for production. Controlled by an ESP32-S3 handling MIDI, UI, WiFi/BLE OTA, and FPGA bitstream programming.

Targets: standalone device + Eurorack variant (CV in for params, 8+ CV out for polyphony).

---

## Table of Contents

1. [Hardware Overview](#1-hardware-overview)
2. [Why These Parts](#2-why-these-parts)
3. [iCE40UP5K Resource Budget](#3-ice40up5k-resource-budget)
4. [ECP5 Scaling Path (1000 Grains)](#4-ecp5-scaling-path-1000-grains)
5. [System Architecture](#5-system-architecture)
6. [ESP32-S3 ↔ FPGA SPI Interface](#6-esp32-s3--fpga-spi-interface)
7. [ESP32-S3 FPGA Programming & OTA](#7-esp32-s3-fpga-programming--ota)
8. [Audio I/O — DAC, ADC, I2S Microphones](#8-audio-io--dac-adc-i2s-microphones)
9. [Pin Assignments](#9-pin-assignments)
10. [SPI Register Maps](#10-spi-register-maps)
11. [Phased Build Plan](#11-phased-build-plan)
12. [Sub-Build Index](#12-sub-build-index)
13. [Custom PCB BOM](#13-custom-pcb-bom)
14. [Open Questions & Future Work](#14-open-questions--future-work)

---

## 1. Hardware Overview

### Current Prototype Hardware

| Component | Part | Role |
|-----------|------|------|
| FPGA dev board | IceSugar v1.5 (iCE40UP5K-SG48) | Granular engine prototype |
| DAC breakout | PCM5102A | I2S stereo audio output (32-bit, 384 kHz capable) |
| ADC breakout | PCM1808 | I2S stereo audio input (24-bit, 96 kHz capable) |
| I2S microphone | ICS-43434 breakout | Digital MEMS mic (24-bit, up to 51.6 kHz) |
| MCU | ESP32-S3 (target: N16R8 module) | MIDI, UI, SPI control, OTA, FPGA programming |

### IceSugar v1.5 Board Details

The IceSugar has an APM32F103 (STM32F1 clone) running iCELink firmware that provides:

| Function | How |
|----------|-----|
| USB mass storage | Presents a FAT12 "iCELink" drive — drop a `.bin` to program |
| SPI flash programmer | Writes bitstream to the on-board W25Q16 (2 MB SPI flash) |
| FPGA reset control | Pulls CRESET_B low → writes flash → releases → FPGA boots |

It also provides the 12 MHz clock and a USB serial port.

**Key insight:** We don't need the iCELink for production. The iCE40UP5K has native SPI slave configuration mode. The ESP32-S3 can program it directly — 6 wires, no flash chip needed. The iCELink is only used during development for quick drag-and-drop flashing.

### Toolchain

Fully open-source, running in Docker:

```
Verilog source → yosys (synthesis) → nextpnr-ice40 (place & route) → icepack (bitstream)
```

Same flow for ECP5: `yosys → nextpnr-ecp5 → ecppack` (Project Trellis).

---

## 2. Why These Parts

### Why NOT Cyclone IV (EP4CE15)

Yosys can synthesize for Cyclone IV (`synth_intel -family cycloneive`) but there is no open-source place-and-route or bitstream generation. nextpnr doesn't support it. Project Mistral only covers Cyclone V. Dead end for open-source tooling.

### Why UP5K over HX4K

The supervisor's iCE40HX4K-TQ144 is actually less capable for audio DSP:

| | iCE40HX4K-TQ144 | iCE40UP5K-SG48 |
|---|---|---|
| LUTs | 3,520 | 5,280 |
| Block RAM | 80 Kbit EBR | 120 Kbit EBR |
| SPRAM | None | **1 Mbit (128 KB)** |
| DSP (multiply) | None | **8 x SB_MAC16** |
| I/O pins | 107 | 39 |
| Hard SPI/I2C | No | Yes |

The HX4K has more pins (good for parallel buses) but zero DSP blocks and no SPRAM. The UP5K is significantly better for audio work.

### Why ECP5 for Production

Only FPGA family with complete open-source tooling AND enough resources for serious DSP:

| | iCE40UP5K | ECP5-25K | ECP5-85K |
|---|---|---|---|
| LUTs | 5,280 | 24,000 | 84,000 |
| DSP (18x18 MAC) | 8 | 28 | 156 |
| Block RAM | 15 KB | 112 KB | 450 KB |
| Max clock | ~48 MHz | ~200 MHz | ~200 MHz |
| Open-source | Yes | Yes | Yes |

---

## 3. iCE40UP5K Resource Budget

### Available Resources

| Resource | Available | Audio use |
|----------|-----------|-----------|
| LUTs | 5,280 | ~200-300 per grain + I2S + SPI + glue |
| DSP blocks | 8 (16x16 MAC) | 2-3 multiplies per grain (envelope, interpolation) |
| SPRAM | 128 KB | ~0.7 sec mono @ 46,875 Hz / 16-bit (2 blocks), ~1.4 sec (all 4) |
| EBR | 15 KB | Envelope tables, coefficients |
| Max clock | ~48 MHz | 12M clock / 46,875 Hz SR = 256 cycles per sample at system clock |

### Realistic Grain Count: 8-16

With the grain engine running at 12 MHz and ~256 clock cycles per sample period (between I2S frames), and ~6 cycles per grain in the processing pipeline (address calc, SPRAM read, envelope multiply, accumulate), we can fit 8-16 grains comfortably. The 8 DSP blocks can be time-shared. SPRAM gives 0.7-1.4 seconds of sample buffer — short but enough to prove the concept.

### Clock and Sample Rate

The 12 MHz oscillator divided by 8 gives 1.5 MHz BCLK, divided by 32 bits per stereo frame gives a **46,875 Hz sample rate**. This is < 2% off from 48 kHz — inaudible difference. Between I2S frames, we have the full 12 MHz clock for grain processing.

---

## 4. ECP5 Scaling Path (1000 Grains)

### Can ECP5-85K Do 1000 Grains?

At 200 MHz with 48 kHz sample rate: **4,166 clock cycles per sample**.

**DSP capacity:** 156 DSP blocks x 4,166 cycles = 649k multiply ops per sample. At 2-3 multiplies per grain, DSP can handle 200k+ grains. **DSP is not the bottleneck.**

**Logic capacity:** 84k LUTs is enough for the grain scheduler, state machines, memory controller, and I/O. Comfortable.

**Memory bandwidth IS the bottleneck:**

- 1000 grains x 2 sample reads (interpolation) x 2 bytes = 4 KB per sample
- At 48 kHz: **192 MB/sec** required
- 16-bit SDRAM at 100 MHz: ~150 MB/sec practical — too tight
- **32-bit SDRAM at 100 MHz: ~300 MB/sec** — comfortable headroom
- Alternative: dual-bank 16-bit SDRAM or HyperRAM + caching

**Verdict: 1000 grains is achievable** on ECP5-85K with 32-bit SDRAM and a well-pipelined grain engine (~4 cycles per grain). Realistically, 500-1000 grains with simple envelopes and linear interpolation. Fewer if you add per-grain filtering.

### ECP5 Dev Boards

| Board | FPGA | SDRAM | Price | Notes |
|-------|------|-------|-------|-------|
| **ULX3S** | ECP5-12K/25K/85K | 32 MB SDRAM (32-bit!) | ~$100-150 | Best option — has 32-bit SDRAM, audio jack |
| OrangeCrab | ECP5-25K | 128 MB DDR3 | ~$50 | Feather form factor, DDR3 controller is complex |
| Colorlight i5 | ECP5-25K | 2x 16-bit SDRAM | ~$15-20 | Cheapest, needs adapter board |

**Recommendation: ULX3S with ECP5-85K** — it already has 32-bit SDRAM (the key bottleneck solved), a 3.5mm audio jack, and full open-source support.

---

## 5. System Architecture

```
┌─────────────────────────────────────────────────────────┐
│ ESP32-S3 (N16R8: 16 MB flash, 8 MB PSRAM)              │
│                                                         │
│  HW MIDI In ──► MIDI parser                             │
│  WiFi/BLE ──► OTA (FPGA bitstream + ESP32 firmware)     │
│  UI (knobs/encoder/display) ──► parameter control       │
│                                                         │
│  SPI Master ─────────────────────────┐                  │
│  (control params + bitstream load)   │                  │
│                                                         │
│  On boot: check FPGA version ──► program via SPI        │
│  Runtime: send MIDI/params ──► SPI register writes      │
└──────────────────────────────────────┼──────────────────┘
                                       │ SPI (4 wires)
                                       │ + CRESET_B + CDONE
                                       ▼
┌─────────────────────────────────────────────────────────┐
│ FPGA (iCE40UP5K now, ECP5-85K later)                    │
│                                                         │
│  SPI slave ──► parameter registers (grain ctrl, FX)     │
│                                                         │
│  Granular engine (8 grains on UP5K, 1000 on ECP5):      │
│    Grain scheduler ──► pipelined grain processor        │
│    Per grain: mem read → interpolate → envelope → mix   │
│                                                         │
│  Sample memory:                                         │
│    UP5K: SPRAM (128 KB, ~1.4 sec mono)                  │
│    ECP5: SDRAM (32 MB, ~5.5 min mono)                   │
│                                                         │
│  Effects bus: delay / reverb / filter (ECP5 phase)      │
│                                                         │
│  I2S master ──► DAC + ADC + I2S mics                    │
│                                                         │
│  Eurorack variant:                                      │
│    CV inputs (via ADC) ──► param modulation              │
│    8x PWM/DAC ──► CV outputs (1V/oct for polyphony)     │
└─────────────────────────────────────────────────────────┘
        │ I2S            │ I2S           │ I2S
        ▼                ▼              ▼
 ┌────────────┐   ┌────────────┐   ┌──────────┐
 │ PCM5102A   │   │ PCM1808    │   │ ICS-43434│
 │ DAC → Out  │   │ ADC ← In   │   │ Mic In   │
 └────────────┘   └────────────┘   └──────────┘
```

---

## 6. ESP32-S3 ↔ FPGA SPI Interface

### Why SPI Is All You Need

| Data type | Bandwidth | SPI utilisation at 1 MHz |
|-----------|-----------|-------------------------|
| MIDI events | ~30 bytes/sec typical, peaks ~1 KB/sec | < 0.1% |
| Parameter updates | 32-64 bytes per update at 100 Hz = ~6 KB/sec | < 1% |
| Bitstream programming | ~104 KB (UP5K), one-shot at boot | 85 ms at 10 MHz |

SPI mode 0 (CPOL=0, CPHA=0), 8-bit address + 8-bit data per transaction, MSB first.

### SPI Protocol

```
Transaction format (16 SCLK cycles per CS assertion):
  CS falls LOW
  ESP32 sends: [ADDR byte] [DATA byte]
  CS rises HIGH

Write: ADDR bit 7 = 0 → FPGA latches DATA into register[ADDR]
Read:  ADDR bit 7 = 1 → FPGA returns register[ADDR & 0x7F] on MISO
```

### ESP32 Arduino Example

```cpp
#include <SPI.h>

#define FPGA_CS  10
#define FPGA_SCK 12
#define FPGA_MOSI 11
#define FPGA_MISO 13

void fpga_write(uint8_t addr, uint8_t data) {
    SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
    digitalWrite(FPGA_CS, LOW);
    SPI.transfer(addr);        // address (bit 7 = 0 for write)
    SPI.transfer(data);        // data
    digitalWrite(FPGA_CS, HIGH);
    SPI.endTransaction();
}

uint8_t fpga_read(uint8_t addr) {
    SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
    digitalWrite(FPGA_CS, LOW);
    SPI.transfer(addr | 0x80); // address with read flag
    uint8_t val = SPI.transfer(0x00);
    digitalWrite(FPGA_CS, HIGH);
    SPI.endTransaction();
    return val;
}

// Set DDS frequency (module 04 example):
void set_frequency(float freq_hz) {
    uint32_t step = (uint32_t)(freq_hz * 4294967296.0 / 46875.0);
    fpga_write(0x00, (step >> 24) & 0xFF);
    fpga_write(0x01, (step >> 16) & 0xFF);
    fpga_write(0x02, (step >>  8) & 0xFF);
    fpga_write(0x03, (step >>  0) & 0xFF);
}
```

---

## 7. ESP32-S3 FPGA Programming & OTA

### Direct SPI Programming (No iCELink Needed)

The iCE40UP5K supports **SPI slave configuration mode**. The ESP32-S3 programs it directly at boot using 6 wires — no flash chip, no iCELink, no FTDI.

#### Wiring

| Signal | ESP32-S3 GPIO | FPGA Pin | Purpose |
|--------|--------------|----------|---------|
| CRESET_B | Any GPIO (output) | Pin 8 | Reset FPGA (active low) |
| SPI_SCK | SPI CLK | Pin 15 | Configuration clock |
| SPI_MOSI | SPI MOSI | Pin 14 | Bitstream data |
| CDONE | Any GPIO (input) | Pin 7 | HIGH when FPGA configured successfully |
| SPI_CS | Any GPIO (output) | Pin 16 | SPI slave select |
| GND | GND | GND | Common ground |

Note: these are the iCE40's dedicated configuration pins, separate from the user-I/O SPI pins used for runtime communication. The same physical SPI peripheral on the ESP32 could be re-used for both (switch CS lines), or use two separate SPI buses.

#### Programming Sequence

```
 Time
  │
  │  1. ESP32 pulls CRESET_B LOW (>200 ns)
  │     ─── FPGA is in reset, clears configuration memory ───
  │
  │  2. ESP32 releases CRESET_B HIGH
  │     ─── FPGA begins configuration startup ───
  │
  │  3. Wait ~1.2 ms (FPGA internal oscillator clearing)
  │
  │  4. ESP32 asserts SPI_CS LOW
  │
  │  5. ESP32 clocks out the bitstream over SPI_MOSI
  │     (104,090 bytes for UP5K, MSB first)
  │     At 10 MHz SPI: ~85 ms
  │     At 25 MHz SPI: ~35 ms
  │
  │  6. ESP32 sends 49 additional clock cycles (dummy bytes)
  │     ─── FPGA finishes configuration ───
  │
  │  7. CDONE goes HIGH → FPGA is running user logic
  │
  │  8. ESP32 releases SPI_CS HIGH
  │
  │  Total boot time: ~87 ms at 10 MHz SPI
  │
  ▼
```

#### ESP32 Arduino Implementation

```cpp
#include <SPI.h>
#include "esp_partition.h"

#define FPGA_CRESET  4   // GPIO to FPGA CRESET_B
#define FPGA_CDONE   5   // GPIO from FPGA CDONE
#define FPGA_CFG_CS  6   // GPIO to FPGA SPI config CS
#define FPGA_CFG_SCK 7   // SPI CLK to FPGA config
#define FPGA_CFG_MOSI 15 // SPI MOSI to FPGA config

// Bitstream stored in a custom ESP32 flash partition
const esp_partition_t* bs_partition = NULL;

bool program_fpga() {
    // Find the bitstream partition
    bs_partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, 0x40, "fpga_bs");
    if (!bs_partition) return false;

    // Read bitstream size from first 4 bytes of partition
    uint32_t bs_size;
    esp_partition_read(bs_partition, 0, &bs_size, 4);

    // 1. Reset FPGA
    pinMode(FPGA_CRESET, OUTPUT);
    pinMode(FPGA_CDONE, INPUT);
    digitalWrite(FPGA_CRESET, LOW);
    delayMicroseconds(1);  // >200 ns

    // 2. Release reset
    digitalWrite(FPGA_CRESET, HIGH);

    // 3. Wait for internal clear
    delay(2);  // 1.2 ms minimum

    // 4-5. Send bitstream over SPI
    SPI.begin(FPGA_CFG_SCK, -1, FPGA_CFG_MOSI, FPGA_CFG_CS);
    SPI.beginTransaction(SPISettings(10000000, MSBFIRST, SPI_MODE0));
    digitalWrite(FPGA_CFG_CS, LOW);

    // Stream from flash partition in 256-byte chunks
    uint8_t buf[256];
    for (uint32_t offset = 4; offset < bs_size + 4; offset += 256) {
        uint32_t chunk = min((uint32_t)256, bs_size + 4 - offset);
        esp_partition_read(bs_partition, offset, buf, chunk);
        SPI.transferBytes(buf, NULL, chunk);
    }

    // 6. Send 49 extra clocks (7 dummy bytes)
    for (int i = 0; i < 7; i++) SPI.transfer(0x00);

    digitalWrite(FPGA_CFG_CS, HIGH);
    SPI.endTransaction();

    // 7. Check CDONE
    delay(1);
    return digitalRead(FPGA_CDONE) == HIGH;
}
```

### OTA Bitstream Update Flow

```
┌──────────────────────────────────────────────────────────┐
│ OTA Update Process                                       │
│                                                          │
│  1. ESP32 connects to update server (WiFi/BLE)           │
│  2. Downloads new bitstream (~104 KB for UP5K,            │
│     ~2.5 MB for ECP5-85K)                                │
│  3. Writes to fpga_bs flash partition                    │
│  4. Stores new version number in NVS                     │
│  5. On next boot (or immediately on command):            │
│     → Reads bitstream from flash partition               │
│     → Programs FPGA via SPI slave config mode            │
│     → Verifies CDONE goes HIGH                           │
│                                                          │
│  Rollback: keep previous bitstream in a backup partition │
│  If CDONE fails → flash backup partition → retry         │
└──────────────────────────────────────────────────────────┘
```

### ESP32-S3 Flash Partition Table

```
# Name,    Type, SubType, Offset,   Size
nvs,       data, nvs,     0x9000,   0x6000    # 24 KB  — NVS (settings, FPGA version)
otadata,   data, ota,     0xf000,   0x2000    # 8 KB   — OTA state
phy_init,  data, phy,     0x11000,  0x1000    # 4 KB   — PHY calibration
ota_0,     app,  ota_0,   0x20000,  0x1E0000  # 1.9 MB — ESP32 firmware slot A
ota_1,     app,  ota_1,   0x200000, 0x1E0000  # 1.9 MB — ESP32 firmware slot B
fpga_bs,   data, 0x40,    0x3E0000, 0x300000  # 3 MB   — FPGA bitstream (active)
fpga_bak,  data, 0x41,    0x6E0000, 0x300000  # 3 MB   — FPGA bitstream (backup)
spiffs,    data, spiffs,  0x9E0000, 0x620000  # 6.1 MB — Sample storage / wavetables
```

This layout fits in a 16 MB flash (ESP32-S3-WROOM-1-N16R8) and supports:
- Dual ESP32 OTA (firmware A/B swap)
- Dual FPGA bitstream (active + backup rollback)
- 6 MB SPIFFS for sample storage / wavetables / presets

### Recommended ESP32-S3 Module

**ESP32-S3-WROOM-1-N16R8**:
- 16 MB flash — room for dual OTA + dual bitstream + samples
- 8 MB PSRAM — useful for buffering audio, grain tables, display framebuffer
- WiFi + BLE 5.0 — OTA and wireless MIDI
- Dual-core 240 MHz — one core for MIDI/UI, one for SPI communication
- Built-in USB — no external USB-UART needed

---

## 8. Audio I/O — DAC, ADC, I2S Microphones

### I2S Format Used

Philips I2S standard throughout:
- **Sample rate:** 46,875 Hz (12 MHz / 256)
- **Bit depth:** 16-bit per channel (32 bits per stereo frame)
- **BCLK:** 1.5 MHz (12 MHz / 8)
- **LRCK:** LOW = left channel, HIGH = right channel
- **Data:** MSB first, 1 BCLK delay after LRCK transition

### PCM5102A DAC (Audio Output)

The PCM5102A is a 32-bit/384 kHz stereo DAC with built-in voltage regulators and output filter. We drive it with 16-bit I2S at 46,875 Hz.

| PCM5102A Pin | Connection | Notes |
|-------------|------------|-------|
| BCK | FPGA BCLK | Bit clock input |
| DIN | FPGA DATA | Serial audio input |
| LCK | FPGA LRCK | Word select input |
| SCK | GND | Ties to GND — PCM5102A generates system clock internally |
| FMT | GND | Selects I2S format (vs left-justified) |
| XSMT | 3.3V | Soft mute off (unmuted) |
| VCC | 3.3V | Digital supply |

### PCM1808 ADC (Audio Input)

The PCM1808 is a 24-bit/96 kHz stereo ADC. In slave mode it accepts external BCK and LRC, but requires a system clock (SCKI) of 256x or 384x the sample rate.

| PCM1808 Pin | Connection | Notes |
|-------------|------------|-------|
| BCK | FPGA BCLK | Bit clock input (shared with DAC) |
| OUT | FPGA ADC_DATA | Serial audio output (24-bit, we capture top 16) |
| LRC | FPGA LRCK | Word select input (shared with DAC) |
| SCKI | FPGA 12 MHz out | System clock = 256 x 46,875 = 12 MHz exactly |
| FMT | GND | I2S format |
| MD0 | GND | Slave mode |
| MD1 | GND | Slave mode |

**Key trick:** The FPGA's 12 MHz main clock IS 256x our sample rate. We just route it out to a PMOD pin as the PCM1808's system clock. No PLL needed.

### ICS-43434 I2S Microphone

The ICS-43434 is a 24-bit I2S MEMS microphone with built-in ADC. It outputs digital audio directly — no external ADC needed. This is the simplest audio input option.

| ICS-43434 Pin | Connection | Notes |
|--------------|------------|-------|
| SCK | FPGA BCLK | I2S bit clock (shared) |
| WS | FPGA LRCK | I2S word select (shared) |
| SD | FPGA MIC_DATA | I2S serial data output |
| L/R | GND or 3.3V | LOW = left channel, HIGH = right channel |
| VDD | 3.3V | 1.62V to 3.6V supply |
| GND | GND | |

**Multi-mic setup:** The L/R pin lets you put 2 mics on one I2S data line (one outputs on left, one on right). For more mics, add more DATA lines — the FPGA captures them all on the same shared BCLK/LRCK.

| Mic count | DATA lines | Total FPGA pins |
|-----------|-----------|-----------------|
| 1 | 1 | 3 (BCLK + LRCK + DATA) |
| 2 | 1 | 3 (both on same DATA, L/R select) |
| 4 | 2 | 4 (shared BCLK/LRCK + 2 DATA) |
| 8 | 4 | 6 (shared BCLK/LRCK + 4 DATA) |

---

## 9. Pin Assignments

### IceSugar v1.5 PMOD Headers

```
PMOD 2 (no conflicts):          PMOD 3 (no conflicts):
 Pin  FPGA  Use                   Pin  FPGA  Use
 P2_1  46   SPI SCK / ADC BCK     P3_1  34   I2S BCLK (DAC BCK)
 P2_2  44   SPI MOSI / ADC OUT    P3_2  31   DAC DIN
 P2_3  42   SPI MISO              P3_3  27   I2S LRCK (DAC LCK)
 P2_4  37   SPI CS                P3_4  25   (available)
 P2_9  36   (available)           P3_9  23   ADC SCKI / mic
 P2_10 38   (available)           P3_10 26   ADC OUT / mic DATA
 P2_11 43   (available)           P3_11 28   (available)
 P2_12 45   (available)           P3_12 32   (available / old speaker)
```

### Pin Usage by Sub-Build

| Signal | 01 i2s_out | 02 passthru | 03 spi | 04 dds | 05 grain |
|--------|-----------|-------------|--------|--------|----------|
| i2s_bclk (34) | x | x | | x | x |
| i2s_lrck (27) | x | x | | x | x |
| dac_data (31) | x | x | | x | x |
| adc_data (44/26) | | x | | | x |
| adc_scki (46/23) | | x | | | x |
| spi_sck (46) | | | x | x | x |
| spi_mosi (44) | | | x | x | x |
| spi_miso (42) | | | x | x | x |
| spi_cs_n (37) | | | x | x | x |

**Note:** In modules 02 and 05, the ADC shares header pins with SPI. Module 05 solves this by putting the ADC on PMOD 3's bottom row (pins 23, 26) and SPI on PMOD 2. Module 02 uses PMOD 2 for the ADC (no SPI needed in that module).

---

## 10. SPI Register Maps

### Module 03 — SPI Slave (LED Control)

| Addr | R/W | Name | Description |
|------|-----|------|-------------|
| 0x00 | R/W | LED_R | Red LED brightness (0-255) |
| 0x01 | R/W | LED_G | Green LED brightness (0-255) |
| 0x02 | R/W | LED_B | Blue LED brightness (0-255) |
| 0x03 | R | STATUS | Returns 0xA5 (comms verification) |

### Module 04 — DDS Synth

| Addr | R/W | Name | Description |
|------|-----|------|-------------|
| 0x00 | R/W | PHASE_3 | Phase step byte 3 (MSB) — phase_step[31:24] |
| 0x01 | R/W | PHASE_2 | Phase step byte 2 — phase_step[23:16] |
| 0x02 | R/W | PHASE_1 | Phase step byte 1 — phase_step[15:8] |
| 0x03 | R/W | PHASE_0 | Phase step byte 0 (LSB) — phase_step[7:0] |
| 0x04 | R/W | GATE | 0 = silent, 1 = oscillator on |
| 0x05 | R/W | WAVEFORM | 0=sine, 1=saw, 2=square, 3=triangle |
| 0x10 | R | STATUS | Returns 0x42 |

Phase step formula: `step = (uint32_t)(freq_hz * 4294967296.0 / 46875.0)`

| Note | Frequency | Phase Step |
|------|-----------|-----------|
| C4 | 261.63 Hz | 23,938,780 |
| A4 | 440.00 Hz | 40,290,222 |
| C5 | 523.25 Hz | 47,877,560 |
| A5 | 880.00 Hz | 80,580,444 |

### Module 05 — Grain Engine

| Addr | R/W | Name | Description |
|------|-----|------|-------------|
| 0x00 | R/W | CONTROL | bit 0: record enable, bit 1: playback enable |
| 0x01 | R/W | REC_LEN_H | Record length MSB (samples, max 32768) |
| 0x02 | R/W | REC_LEN_L | Record length LSB |
| 0x70 | R | STATUS | Returns 0xBE |

**Per-grain registers** (8 grains, base = 0x10 + N*0x08, N = 0..7):

| Offset | R/W | Name | Description |
|--------|-----|------|-------------|
| +0x00 | R/W | POS_H | Grain start position MSB (in sample buffer) |
| +0x01 | R/W | POS_L | Grain start position LSB |
| +0x02 | R/W | SIZE_H | Grain length MSB (in samples) |
| +0x03 | R/W | SIZE_L | Grain length LSB |
| +0x04 | R/W | PITCH_H | Playback rate MSB (8.8 fixed point) |
| +0x05 | R/W | PITCH_L | Playback rate LSB (0x0100 = original pitch) |
| +0x06 | R/W | LEVEL | Amplitude 0-255 |
| +0x07 | R/W | ACTIVE | 0 = off, 1 = on |

Grain address map:

| Grain | Base addr | Registers |
|-------|-----------|-----------|
| 0 | 0x10 | 0x10-0x17 |
| 1 | 0x18 | 0x18-0x1F |
| 2 | 0x20 | 0x20-0x27 |
| 3 | 0x28 | 0x28-0x2F |
| 4 | 0x30 | 0x30-0x37 |
| 5 | 0x38 | 0x38-0x3F |
| 6 | 0x40 | 0x40-0x47 |
| 7 | 0x48 | 0x48-0x4F |

---

## 11. Phased Build Plan

### Phase 1 — Audio I/O on iCE40UP5K (current hardware)

- [x] **01_i2s_out:** I2S master driving PCM5102A (440 Hz sine)
- [x] **02_i2s_passthrough:** PCM1808 ADC → FPGA → PCM5102A DAC loopback
- [ ] Wire up PCM5102A and verify audio output
- [ ] Wire up PCM1808 and verify audio loopback
- [ ] ICS-43434 mic capture sub-build (future: between 02 and 03)

### Phase 2 — ESP32-S3 ↔ FPGA Link

- [x] **03_spi_slave:** SPI register interface (LED control proof-of-concept)
- [ ] Write ESP32 Arduino firmware for SPI register writes
- [ ] Verify read-back (status register 0xA5)
- [ ] ESP32 SPI bitstream programming (bypass iCELink)
- [ ] ESP32 OTA bitstream update over WiFi

### Phase 3 — Baby Granular on iCE40UP5K

- [x] **04_dds_synth:** SPI-controlled DDS oscillator → I2S DAC
- [x] **05_grain_engine:** SPRAM sample buffer + 8-grain playback
- [ ] Write ESP32 firmware: MIDI → SPI → DDS frequency
- [ ] Write ESP32 firmware: grain parameter control UI
- [ ] Record from ADC into SPRAM buffer
- [ ] Play back multiple grains simultaneously
- [ ] Test envelope shapes and pitch shifting

### Phase 4 — ECP5 Prototype (ULX3S or custom board)

- [ ] Set up ECP5 Docker toolchain (yosys + nextpnr-ecp5 + ecppack)
- [ ] Port I2S and SPI modules to ECP5
- [ ] SDRAM controller for large sample buffer
- [ ] Scale grain engine to 100+ grains
- [ ] Add effects (delay, reverb, filtering)

### Phase 5 — Beast Mode (1000 grains)

- [ ] Deeply pipelined grain processor (~4 cycles/grain)
- [ ] Optimised SDRAM access patterns (burst reads, grain scheduling by address locality)
- [ ] Per-grain envelope shapes (ADSR, Gaussian, custom)
- [ ] Pitch shifting with cubic interpolation
- [ ] Global effects bus (delay, reverb, filter)

### Phase 6 — Custom PCB

- [ ] ESP32-S3 + ECP5 + SDRAM + audio codec on one board
- [ ] Standalone version: MIDI jacks, audio I/O, knobs, display
- [ ] Eurorack version: CV/gate I/O, panel-mount jacks, 3U panel

---

## 12. Sub-Build Index

All sub-builds live in `projects/granular-synth-engine/` and produce bitstreams independently.

```
granular-synth-engine/
├── 01_i2s_out/            I2S master → PCM5102A DAC (440 Hz sine)
│   ├── i2s_out.v          Verilog source
│   ├── i2s_out.pcf        Pin constraints
│   └── Makefile
├── 02_i2s_passthrough/    PCM1808 ADC → FPGA → PCM5102A DAC loopback
│   ├── i2s_passthrough.v
│   ├── i2s_passthrough.pcf
│   └── Makefile
├── 03_spi_slave/          ESP32-S3 SPI → FPGA registers (RGB LED)
│   ├── spi_slave.v
│   ├── spi_slave.pcf
│   └── Makefile
├── 04_dds_synth/          SPI-controlled DDS oscillator → I2S DAC
│   ├── dds_synth.v
│   ├── dds_synth.pcf
│   └── Makefile
└── 05_grain_engine/       SPRAM buffer + 8-grain playback
    ├── grain_engine.v
    ├── grain_engine.pcf
    └── Makefile
```

### Building

```bash
# From repo root:
cd C:\Users\td0034\Projects\fpga

# Build any sub-project:
MSYS_NO_PATHCONV=1 docker compose run --rm fpga \
    make -C /workspace/granular-synth-engine/01_i2s_out

# Flash (Windows):
.\flash.bat build\01_i2s_out\top.bin
```

---

## 13. Custom PCB BOM

Minimum components for the final board:

| Component | Purpose | Notes |
|-----------|---------|-------|
| ECP5-85K (caBGA-381) | FPGA | Or ECP5-25K for cost savings |
| ESP32-S3-WROOM-1-N16R8 | MCU + WiFi/BLE | 16 MB flash, 8 MB PSRAM |
| W9825G6KH (x1) | 32-bit SDRAM | 32 MB, critical for grain count |
| WM8731 or CS4272 | Audio codec | Stereo ADC+DAC in one IC |
| 1.1V regulator | FPGA core supply | |
| 2.5V regulator | FPGA aux supply | |
| 3.3V regulator | FPGA I/O + ESP32 | |
| 25 MHz oscillator | FPGA PLL input | ECP5 PLLs multiply up to 400+ MHz |

**Eurorack variant adds:**

| Component | Purpose | Notes |
|-----------|---------|-------|
| MCP4728 (x2) | 8x CV output DACs | 12-bit, I2C, 1V/oct |
| MCP3208 | CV input ADC | 12-bit, SPI, 8 channels |
| TL074 (x2) | CV output buffers | Rail-to-rail op-amps |
| Eurorack power header | +/-12V, +5V | Standard 10-pin or 16-pin |
| 3.3V regulator from 12V | Board power | |

---

## 14. Open Questions & Future Work

### Near-term

- **PCM1808 SCKI routing:** Verify that routing the 12 MHz clock directly from an FPGA I/O pin (not a dedicated clock output) is clean enough for the PCM1808. May need a buffer or dedicated clock output. Test with module 02.
- **SPI bus sharing:** When ESP32 handles both FPGA programming (config SPI) and runtime control (user SPI), determine whether to use the same SPI peripheral with different CS lines, or two separate SPI buses.
- **ICS-43434 sub-build:** Add a mic capture module between 02 and 03. Test single mic, then dual-mic (L/R on one data line), then quad-mic.
- **Latency measurement:** Measure end-to-end latency from ADC input to DAC output in passthrough mode. Target < 1 ms.

### Medium-term

- **ADSR envelope:** Replace triangular envelope with proper ADSR per grain.
- **Linear interpolation:** Current grain engine does nearest-sample lookup. Add linear interpolation between samples for better pitch-shifting quality (needs 2 SPRAM reads per grain instead of 1).
- **Grain density control:** ESP32 firmware to automatically spawn/despawn grains based on density parameter.
- **Freeze/scrub:** Continuously record into circular buffer while playing grains from it.

### Long-term (ECP5 phase)

- **SDRAM controller:** Design a burst-read-optimised SDRAM controller that schedules grain reads by address locality to maximise bandwidth.
- **Per-grain filter:** Add a 2-pole SVF (state variable filter) per grain, controlled by SPI. This trades grain count for timbral control.
- **Effects bus:** Global delay line in SDRAM, reverb (Schroeder/Freeverb), and master filter.
- **Polyphonic CV output:** 8 channels of 1V/oct CV for driving analog oscillators from grain triggers.
- **Multi-channel audio:** Multiple I2S outputs for surround or multi-bus mixing.
