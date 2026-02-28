# PCM5102 DAC Integration Plan — ULX3S 85F

## Overview

Upgrade the existing SD card WAV player (`examples/sdcard/`) from the onboard
4-bit resistor DAC (3.5mm jack) to an external PCM5102A breakout via I2S,
delivering true 16-bit audio output.

The existing design already handles the hard parts — SD card SPI init, FAT32
parsing, WAV header extraction, and sample-rate timing. The work is: replace
the delta-sigma DAC output stage with an I2S transmitter, and wire the
PCM5102A breakout to the GPIO header.

---

## 1. Voltage Compatibility — No Level Shifting Needed

| Parameter | ULX3S GPIO | PCM5102A (DVDD=3.3V) |
|-----------|------------|----------------------|
| **VCC** | 3.3V rail on J1/J2 | 3.3V (DVDD & AVDD) |
| **VOH** | ~3.3V (LVCMOS33) | VIH min = 2.31V (0.7 × 3.3) |
| **VOL** | ~0V | VIL max = 0.99V (0.3 × 3.3) |
| **I/O current** | 4 mA drive (configurable) | ~10 µA input |

The ECP5's core voltage (1.2V) is internal only. All I/O banks on the ULX3S
are powered at 3.3V (VCCIO = 3.3V), and every pin in the constraints file is
configured as `IO_TYPE=LVCMOS33`. **Direct wire connection, no level shifters
or resistors needed.**

---

## 2. PCM5102A Breakout Pin Configuration

Typical PCM5102A breakout boards (e.g. GY-PCM5102) have these pins:

| Breakout Pin | Connect To | Notes |
|--------------|------------|-------|
| **VCC** | ULX3S 3.3V (J1 pin 2) | Powers digital + analog sections |
| **GND** | ULX3S GND | Common ground — **critical** |
| **BCK** | FPGA GPIO (e.g. gp[0] = B11) | Bit clock, FPGA output |
| **DIN** | FPGA GPIO (e.g. gp[1] = A10) | Serial data, FPGA output |
| **LCK** | FPGA GPIO (e.g. gp[2] = A9) | Word select (LRCK), FPGA output |
| **FMT** | GND | I2S format (low = standard I2S) |
| **XSMT** | 3.3V (or FPGA GPIO) | Soft mute: high = unmuted |
| **FLT** | GND | Filter select: low = normal |
| **DEMP** | GND | De-emphasis: low = disabled |
| **SCK** | GND (or leave NC) | System clock: GND = auto-detect |

**Key points:**
- **FMT = GND** selects standard I2S format (MSB-first, 1-BCK delay after LRCK edge)
- **SCK = GND** tells the PCM5102 to use its internal PLL to derive MCLK from BCK
  (this is a huge simplification — no need to generate a precise MCLK from the FPGA)
- **XSMT** can be directly tied to 3.3V for always-unmuted, or driven by an FPGA
  GPIO for software mute control

---

## 3. GPIO Header Wiring Plan

### Recommended pins (J1 header, lower GPIO, Bank 0):

| Signal | GPIO Name | FPGA Pad | J1 Pin | Reason |
|--------|-----------|----------|--------|--------|
| BCK | gp[0] | B11 | 5+ | PCLK-capable, good for clocks |
| DIN | gp[1] | A10 | 6+ | Adjacent, clean routing |
| LRCK | gp[2] | A9 | 7+ | Adjacent, clean routing |
| XSMT | gp[3] | B9 | 8+ | Optional mute control |
| 3.3V | — | — | 2 | Power (3.3V rail) |
| GND | — | — | 1 | Ground |

All gp[0–7] are on Bank 0, same as the clock input (G2). This minimises
timing skew between the system clock and I2S outputs.

### Alternative: Use gn[] (negative pair) if gp[] conflicts with other peripherals.

---

## 4. I2S Protocol — What the FPGA Must Output

### Standard I2S Format (Philips I2S)

```
         ┌───┐   ┌───┐   ┌───┐   ┌───┐       ┌───┐   ┌───┐
BCK  ────┘   └───┘   └───┘   └───┘   └─ ... ──┘   └───┘   └───
         │       │       │       │               │       │
     ┌───────────────────────────────┐   ┌───────────────────────
LCK  ┘ LEFT CHANNEL                 └───┘ RIGHT CHANNEL
         │       │       │                       │
DIN  ──X─┤ MSB-1 ┤ MSB-2 ┤ MSB-3 ... ─────X─────┤ MSB-1 ┤──────
         │       │       │                       │       │
```

**Key timing rules:**
1. **LRCK transitions on BCK falling edge** (data valid on rising edge)
2. **DIN MSB appears 1 BCK cycle after LRCK transition** (the "I2S delay")
3. LRCK low = left channel, LRCK high = right channel
4. Data is MSB-first, 16 bits per channel (bits [15:0])
5. Remaining BCK cycles (if frame > 16 bits) are don't-care / zero-padded

### Clock Frequencies for 44.1 kHz / 16-bit Stereo

| Parameter | Formula | Value |
|-----------|---------|-------|
| Sample rate (fs) | — | 44,100 Hz |
| Bits per frame | 2 channels × 32 bits | 64 bits |
| BCK frequency | fs × 64 | 2,822,400 Hz |
| LRCK frequency | fs | 44,100 Hz |
| BCK period | 1 / 2.8224 MHz | ~354 ns |

**Note:** I2S convention uses 32 BCK cycles per channel even for 16-bit data.
The extra 16 cycles are zero-padded. This gives a clean 64× BCK-to-fs ratio.

### Clock Generation from 25 MHz

**Option A — Simple integer divider (recommended for first implementation):**

25 MHz / 2,822,400 Hz = 8.858... (not integer)

Nearest: 25 MHz / 8 = 3,125,000 Hz → fs = 3,125,000/64 = 48,828.125 Hz
This is ~4.8 kHz above 44.1 kHz — the PCM5102's internal PLL can lock to
BCK frequencies from ~1 MHz to ~50 MHz, so this will work. The audio will
play back ~10.7% fast. Acceptable for a first test; sounds slightly higher
pitched but recognisable.

**Option B — Fractional divider (production quality):**

Use the same fractional accumulator technique already in `sdcard.v`:

```
BCK_INC = round(2,822,400 × 2^32 / 25,000,000) = 484,710,981
```

This produces BCK edges with <0.2 ppm jitter averaged over time. The
PCM5102's internal PLL tolerates significant BCK jitter (it's designed for
noisy digital systems), so this works well in practice.

**Option C — ECP5 PLL:**

The ECP5 has PLLs that can multiply/divide the input clock. However,
44.1 kHz multiples from 25 MHz are not achievable with integer ratios:
- 25 MHz × 4 / 89 = 1.1236 MHz ≈ not close enough
- No integer M/D pair gives exactly 11.2896 MHz or 2.8224 MHz

The fractional accumulator approach (Option B) is simpler and sufficient
given the PCM5102 has its own PLL. **PLL is unnecessary for this design.**

### Recommended: Option B with the existing sample rate accumulator pattern

The existing code already demonstrates fractional accumulator timing
(SAMPLE_RATE_INC for 44.1 kHz). Adding a second accumulator for BCK
generation follows the same pattern.

---

## 5. Architecture — Modified SD Card WAV Player

### What stays the same:
- SPI SD controller (CMD0/CMD8/ACMD41/CMD58/CMD17)
- FAT32 reader (MBR → BPB → root directory scan)
- WAV header parser (44-byte skip, channel count detection)
- Sample rate fractional accumulator (44.1 kHz tick)
- Status LEDs
- Button replay/reset
- Overall FSM structure

### What changes:
- **Remove:** Delta-sigma DAC (ds_acc_l, ds_acc_r, audio_l[3:0], audio_r[3:0])
- **Add:** I2S transmitter module
- **Add:** 3 GPIO outputs (BCK, DIN, LRCK) + optional XSMT
- **Modify:** Constraints file to map GPIO pins instead of audio DAC pins
- **Modify:** Sample handoff — instead of loading delta-sigma accumulators,
  load I2S shift registers

### Block diagram:

```
 ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
 │   SD Card    │     │   FAT32 +    │     │    I2S       │
 │   SPI        │────>│   WAV Parse  │────>│  Transmitter │──> BCK, DIN, LRCK
 │   Controller │     │              │     │              │      to PCM5102
 └──────────────┘     └──────────────┘     └──────────────┘
                                                  ^
                                                  │
                                           sample_tick
                                           (44.1 kHz)
```

---

## 6. I2S Transmitter Module Design

### Interface:

```verilog
module i2s_tx (
    input  wire        clk,        // 25 MHz system clock
    input  wire        rst,        // synchronous reset

    // Audio sample interface (active at sample_tick rate)
    input  wire [15:0] left_sample,   // left channel (signed 16-bit)
    input  wire [15:0] right_sample,  // right channel (signed 16-bit)
    input  wire        sample_valid,  // pulse: new sample ready

    // I2S output pins
    output reg         bck,        // bit clock
    output reg         lrck,       // word select (left/right)
    output reg         din         // serial data (directly to PCM5102 DIN)
);
```

### Internal logic:

1. **BCK generator** — fractional accumulator producing 2.8224 MHz toggle
   rate from 25 MHz (same technique as SAMPLE_RATE_INC)
2. **Bit counter** — counts 0–63 per frame (32 left + 32 right)
3. **Shift register** — 32-bit, loaded with {sample[15:0], 16'd0} at frame
   boundaries (16-bit data, zero-padded to 32 bits)
4. **LRCK** — toggles every 32 BCK cycles
5. **DIN** — shifts out MSB-first on BCK falling edge, 1 cycle delayed from
   LRCK transition (standard I2S format)

### Timing detail:

```
BCK cycle:  0  1  2  3  4  5  ... 15 16 17 ... 31 32 33 ... 63
LRCK:       0  0  0  0  0  0  ...  0  0  0 ...  0  1  1 ...  1
DIN:        X  L15 L14 L13 L12 ... L1 L0  0 ...  0 X  R15 ... R0  0 ...
            ^                                      ^
            LRCK fell → 1 BCK delay → MSB          LRCK rose → 1 BCK delay → MSB
```

---

## 7. Implementation Steps

### Phase 1: Standalone I2S test tone (new example: `examples/i2s_tone/`)

Build a minimal project that generates a 440 Hz sine wave over I2S to
validate the wiring and PCM5102 configuration before touching the SD card
player.

1. Create `examples/i2s_tone/` with Makefile, LPF, and Verilog
2. I2S transmitter with hardcoded BCK/LRCK/DIN generation
3. 256-entry sine LUT (16-bit), phase accumulator for 440 Hz
4. Wire to PCM5102 breakout on gp[0:2]
5. Verify audio output on headphones connected to PCM5102's 3.5mm jack

**Success criteria:** Clean 440 Hz tone from the PCM5102 breakout.

### Phase 2: SD card WAV → I2S (new example: `examples/sdcard_i2s/`)

Fork the existing `examples/sdcard/` and replace the DAC output with I2S.

1. Copy `sdcard.v` → new `sdcard_i2s.v`
2. Remove delta-sigma DAC code (ds_acc_l/r, audio_l/r[3:0])
3. Integrate i2s_tx module (can be inlined or instantiated)
4. Feed `audio_left`/`audio_right` (already 16-bit in existing code) into I2S
5. Update LPF: remove audio_l/r, add gp[0:2] for BCK/DIN/LRCK
6. Build and test with a WAV file on SD card

**Success criteria:** Full WAV playback through PCM5102 at correct pitch and speed.

### Phase 3: Enhancements (optional, future work)

- Volume control via buttons (digital attenuation before I2S)
- Next/previous track (multi-file support)
- Loop playback
- XSMT mute control via button
- Dual output: keep onboard DAC for monitoring + I2S for quality output

---

## 8. Physical Wiring Reference

### Bill of Materials

| Item | Qty | Notes |
|------|-----|-------|
| PCM5102A breakout (GY-PCM5102 or similar) | 1 | Pre-soldered, ~$3 |
| Dupont jumper wires (F-F or F-M) | 6 | 3 signal + VCC + GND + XSMT |
| 3.5mm headphones or powered speaker | 1 | Plugs into PCM5102 jack |

### Wiring Diagram

```
    ULX3S J1 Header              PCM5102A Breakout
    ================              =================
    Pin 2 (3.3V)  ──────────────> VCC
    Pin 1 (GND)   ──────────────> GND
    gp[0] (B11)   ──────────────> BCK
    gp[1] (A10)   ──────────────> DIN
    gp[2] (A9)    ──────────────> LCK (LRCK)
    Pin 2 (3.3V)  ──────────────> XSMT (unmute)
                      GND ──────> FMT  (I2S format)
                      GND ──────> SCK  (use internal PLL)
                      GND ──────> FLT  (normal filter)
                      GND ──────> DEMP (no de-emphasis)
```

### J1 Header Physical Layout (top view, board USB-C at bottom)

```
             J1 (female header, top view)
    ┌─────────────────────────────────────────┐
    │  1(GND)  3(gn0)  5(gp0)  7(gp1)  ...   │
    │  2(3V3)  4(gn1)  6(gp2)  8(gp3)  ...   │
    └─────────────────────────────────────────┘
    Note: Exact pin numbering varies by header gender/orientation.
    Verify with ULX3S v2.0+ schematic before connecting.
```

**IMPORTANT:** Triple-check all connections before powering on.
Swapping 3.3V and GND will destroy the breakout board and possibly the FPGA.

---

## 9. Constraints File Template (for Phase 1)

```lpf
# I2S Tone Generator — Pin Constraints
# ULX3S 85F → PCM5102A breakout via GPIO header J1

# 25 MHz oscillator
LOCATE COMP "clk" SITE "G2";
IOBUF PORT "clk" PULLMODE=NONE IO_TYPE=LVCMOS33;
FREQUENCY PORT "clk" 25 MHZ;

# 8 LEDs (active high)
LOCATE COMP "led[0]" SITE "B2";
LOCATE COMP "led[1]" SITE "C2";
LOCATE COMP "led[2]" SITE "C1";
LOCATE COMP "led[3]" SITE "D2";
LOCATE COMP "led[4]" SITE "D1";
LOCATE COMP "led[5]" SITE "E2";
LOCATE COMP "led[6]" SITE "E1";
LOCATE COMP "led[7]" SITE "H3";
IOBUF PORT "led[0]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[1]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[2]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[3]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[4]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[5]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[6]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "led[7]" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;

# I2S output to PCM5102A (active GPIO header pins, active 3.3V, active 4mA drive)
LOCATE COMP "i2s_bck" SITE "B11";
LOCATE COMP "i2s_din" SITE "A10";
LOCATE COMP "i2s_lrck" SITE "A9";
IOBUF PORT "i2s_bck" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "i2s_din" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
IOBUF PORT "i2s_lrck" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=4;
```

---

## 10. Existing Code Reuse Map

The current `examples/sdcard/sdcard.v` (1145 lines) breaks down as:

| Section | Lines | Reuse in I2S version |
|---------|-------|---------------------|
| SPI engine (bit-bang master) | 57–191 | Keep as-is |
| Sector buffer (512B BRAM) | 196–202 | Keep as-is |
| FAT32 state (registers) | 204–222 | Keep as-is |
| Audio state + delta-sigma | 224–287 | **Replace** with I2S TX |
| Sample rate accumulator | 244–257 | Keep (drives sample_valid) |
| Status LEDs | 289–325 | Keep, add I2S lock indicator |
| Main FSM (SD init) | 327–564 | Keep as-is |
| Main FSM (MBR/BPB/dir) | 566–844 | Keep as-is |
| Main FSM (playback) | 846–1024 | **Modify** sample handoff |
| Main FSM (cluster chain) | 1026–1099 | Keep as-is |
| Main FSM (done/error) | 1101–1145 | Keep as-is |

**Net change: ~60 lines removed (delta-sigma), ~80 lines added (I2S TX).**
The overall FSM structure is unchanged.

---

## 11. Sample Data Path Comparison

### Current (delta-sigma → onboard 4-bit DAC):
```
sector_buf[byte] → assemble 16-bit → audio_left/right (unsigned)
                                          │
                         ds_acc += sample ─┤ @ 25 MHz
                         audio_l[3:0] = ds_acc[15:12]
                                          │
                                     3.5mm jack
```

### New (I2S → PCM5102A):
```
sector_buf[byte] → assemble 16-bit → left_sample/right_sample (signed)
                                          │
                         i2s_tx module ────┤ @ sample_tick
                         BCK/DIN/LRCK out  │ (fractional BCK clock)
                                          │
                                     PCM5102 → 3.5mm jack
```

**Note:** The existing code converts signed PCM to unsigned (XOR 0x80 on high
byte) for the delta-sigma DAC. For I2S the PCM5102 expects **signed** two's
complement, so that XOR needs to be removed.

---

## 12. Risk Assessment & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Incorrect wiring damages FPGA | High | Triple-check before power-on; measure with multimeter |
| BCK jitter causes audio artifacts | Medium | Fractional accumulator has sub-ppm average accuracy; PCM5102 PLL tolerant |
| SD card timing affected by I2S | Low | I2S runs independently; SPI and I2S use different pins |
| PCM5102 won't lock to BCK | Medium | Verify BCK is clean on scope; try integer divider first |
| WAV file format incompatible | Low | Existing parser handles 44.1k/16-bit/mono+stereo already |

---

## 13. Testing Checklist

### Phase 1 (I2S tone):
- [ ] Bitstream builds without errors
- [ ] LEDs show heartbeat (FPGA alive)
- [ ] BCK measures ~2.82 MHz on oscilloscope/logic analyser
- [ ] LRCK measures ~44.1 kHz
- [ ] Clean 440 Hz tone audible through PCM5102 headphone output
- [ ] No audible clicks/pops (indicates timing issues)

### Phase 2 (SD → I2S):
- [ ] SD card initialises (LED[1] lights)
- [ ] FAT32 partition found (LED[2] lights)
- [ ] WAV file found (LED[3] lights)
- [ ] Audio plays at correct pitch (not 10% fast/slow)
- [ ] Stereo separation correct (left/right not swapped)
- [ ] Multi-cluster files play without gaps
- [ ] FIRE1 button replays file
- [ ] Dramatically better audio quality vs onboard DAC
