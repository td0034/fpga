# oled_wave — SD card WAV player with OLED waveform display

Plays a 16-bit WAV file from a FAT32 SD card via I2S to a PCM5102A DAC,
while displaying the live audio waveform on a 2.42" 128x64 I2C OLED
(SSD1309 or SSD1306). FIRE1 button replays from start.

## Hardware

### PCM5102A DAC (J1 header, GN0-GN7)

| Pin  | Site | Signal | Setting       |
|------|------|--------|---------------|
| GN0  | C11  | FLT    | LOW (normal)  |
| GN1  | A11  | DMP    | LOW (no deemphasis) |
| GN2  | B10  | SCL    | LOW (auto clock) |
| GN3  | C10  | BCK    | I2S bit clock |
| GN4  | A8   | DIN    | I2S data      |
| GN5  | B8   | LCK    | I2S word select |
| GN6  | C7   | FMT    | LOW (I2S fmt) |
| GN7  | B6   | XMT    | HIGH (unmute) |

Power the DAC from J1 3.3V and GND pins.

### I2C OLED (J2 header, pin 22)

| Pin  | Site | Signal   |
|------|------|----------|
| GP22 | B15  | SCL      |
| GN22 | C15  | SDA      |

The OLED is driven push-pull (not open-drain) since we only write to the
display and ignore ACKs. PULLMODE=UP is set in the constraints for idle-high.
Tested with a 2.42" 128x64 SSD1309 module at I2C address 0x3C (0x78 write).

### SD card

Standard SD card slot on the ULX3S, directly connected via SPI mode.

## Architecture

Six main blocks in a single Verilog module:

1. **I2S master** — generates BCK (~1.56 MHz), LRCK (~48.8 kHz) and shifts
   16-bit left/right samples out to the PCM5102A. BCLK = 25 MHz / 16,
   sample rate = 25 MHz / 512 = 48,828 Hz.

2. **SPI SD controller** — bit-bang SPI master (Mode 0). Init at ~390 kHz,
   data transfer at ~6.25 MHz. Handles CMD0/CMD8/ACMD41/CMD58 init sequence.

3. **FAT32 reader** — parses MBR, BPB, scans root directory for the first
   `.WAV` file, follows FAT cluster chain for multi-cluster files.

4. **WAV parser** — skips the 44-byte RIFF header, streams raw PCM samples.
   Auto-detects mono/stereo from the header. Sample rate is resampled to
   the fixed 48,828 Hz I2S output.

5. **OLED I2C engine** — ~1 MHz I2C master with a handshake-based byte
   sender. Uses `i2c_go`/`i2c_busy` protocol to avoid missed transmissions
   across clock domains.

6. **OLED waveform display** — captures 128 consecutive left-channel audio
   samples into a buffer, then renders them to the OLED as a single-pixel-
   per-column oscilloscope trace. Signed 16-bit samples are mapped to the
   64-pixel display height: `display_y = {~sample[15], sample[14:10]}`.
   A cursor-reset command sequence (column 0-127, page 0-7) is sent before
   each frame to prevent drift.

## SD card preparation

1. Format the card as FAT32 (MBR partition table, not GPT).
2. Copy a WAV file to the root directory:
   - 16-bit PCM (signed), mono or stereo
   - Any standard sample rate (44.1 kHz, 48 kHz, etc.)
   - Standard RIFF format (44-byte header)
3. The first file ending in `.WAV` (8.3 name match) is played.

SDHC/SDXC cards only (block-addressed). Older SDSC cards are not supported.

## LED status

| LED       | Meaning                              |
|-----------|--------------------------------------|
| `LED[0]`  | Heartbeat (always blinks)            |
| `LED[1]`  | SD card initialised                  |
| `LED[2]`  | FAT32 partition found                |
| `LED[3]`  | WAV file found                       |
| `LED[4]`  | Currently playing                    |
| `LED[5]`  | Mono (on) / stereo (off)             |
| `LED[7]`  | Error indicator                      |

## Button

**FIRE1** — replays the WAV file:
- From `DONE`: replays from MBR read (skips SD init)
- From `ERROR`: full re-initialisation

## Build and flash

```bash
cd ulx3s

# Build
make -C examples/oled_wave

# Flash to SRAM (lost on power cycle)
./flash.sh build/oled_wave/top.bit
```

Build output: `ulx3s/build/oled_wave/top.bit`

## Key implementation details

- **I2C handshake**: The I2C engine runs on a divided clock (QDIV=6, ~4.17 MHz
  quarter-rate). To avoid missed byte sends, the sequencer holds `i2c_go` high
  until `i2c_busy` asserts, then waits for `i2c_busy` to deassert.

- **Push-pull SDA**: Yosys has limited tristate support for ECP5. Since we
  never read from the OLED (write-only, ACKs ignored), SDA is driven as a
  normal push-pull output.

- **Capture/display handshake**: The 128-sample capture buffer and OLED
  sequencer use a two-flag handshake (`cap_done` / `oled_frame_done`) to
  avoid tearing. The capture FSM fills the buffer, then holds while the OLED
  reads it. After the OLED finishes, the capture FSM refills immediately.

- **Cursor reset**: Column and page address commands (0x21/0x22) are sent
  before each data frame to ensure the OLED write pointer starts at (0,0),
  preventing cumulative drift across frames.
