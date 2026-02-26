# sdcard — SD card WAV player

Reads a 44.1 kHz 16-bit WAV file from a FAT32 SD card and plays it through
the 3.5mm headphone jack using delta-sigma modulation.

## Architecture

Five main blocks running in a single FSM:

1. **SPI SD controller** — initialises the card (CMD0 → CMD8 → ACMD41 → CMD58)
   then issues CMD17 single-block reads (512 bytes each). Init runs at ~390 kHz
   (25 MHz / 64); data transfer runs at ~6.25 MHz (25 MHz / 4).

2. **FAT32 reader** — reads sector 0 (MBR) to find the first FAT32 partition,
   reads the BPB to locate the FAT table and data region, then scans root
   directory entries to find the first file whose name ends in `WAV`.

3. **WAV parser** — skips the standard 44-byte RIFF header, then streams raw
   PCM data. Mono/stereo is auto-detected from the channel count at header
   byte offset 22.

4. **Delta-sigma DAC** — first-order modulator running at 25 MHz converts
   16-bit samples to the 4-bit resistor DAC. Oversampling ratio ~567x
   (25 MHz / 44.1 kHz) pushes quantisation noise well above the audible range.

5. **Sample rate timer** — fractional accumulator generates 44,100 Hz ticks
   from 25 MHz with 0.16 ppm error (increment = 7,578,071).

## SD card preparation

1. Format the card as FAT32 (MBR partition table, not GPT).
2. Copy a WAV file to the root directory. It must be:
   - 44,100 Hz sample rate
   - 16-bit PCM (signed)
   - Mono or stereo
   - Standard RIFF format (44-byte header)
3. The first file whose name ends in `.WAV` (case-insensitive match against the
   8.3 directory entry) is played. Rename it if you want to control ordering.

Modern SD cards are SDHC/SDXC (block-addressed); older SDSC cards are not
supported.

## LED status

| LED      | Normal state              | Error state               |
|----------|---------------------------|---------------------------|
| `LED[0]` | Heartbeat (always blinks) | Heartbeat (always blinks) |
| `LED[1]` | SD card initialised OK    | `debug_byte[1]`           |
| `LED[2]` | FAT32 partition found     | `debug_byte[2]`           |
| `LED[3]` | WAV file found            | `debug_byte[3]`           |
| `LED[4]` | Currently playing         | `debug_byte[4]`           |
| `LED[5]` | Mono (on) / stereo (off)  | `debug_byte[5]`           |
| `LED[7:6]` | Error code (see below)  | `debug_byte[7:6]`         |

Error codes (`LED[7:6]`):

| `LED[7:6]` | Meaning              |
|------------|----------------------|
| `00`       | No error             |
| `01`       | SD initialisation failed |
| `10`       | No FAT32 partition found |
| `11`       | No WAV file found in root directory |

In the error state `LED[7:1]` shows the raw `debug_byte` — the actual byte
the FSM read from the sector buffer at the point of failure. This is useful
for diagnosing read reliability issues without a logic analyser.

## Button

**FIRE1** — behaviour depends on current state:

- From `DONE` (finished playing): replays the WAV from the start, skipping
  SD init and filesystem scan.
- From `ERROR`: triggers a full re-initialisation (power-up sequence,
  SD init, filesystem scan, playback).

## Build and flash

```bash
cd ulx3s

# Build
make -C examples/sdcard

# Flash to SRAM (lost on power cycle — good for testing)
./flash.sh build/sdcard/top.bit

# Flash to SPI flash (survives power cycle)
# --unprotect-flash is required on first write: the ISSI IS25LP128 chip
# ships with block protection enabled and openFPGALoader must clear it first.
openFPGALoader --board=ulx3s --unprotect-flash build/sdcard/top.bit
```

Build output: `ulx3s/build/sdcard/top.bit`

## Key concepts

- **SPI protocol** — synchronous serial; MOSI/MISO/CLK/CS. SD cards in SPI
  mode use Mode 0 (CPOL=0, CPHA=0).
- **SD init sequence** — CMD0 resets to idle, CMD8 checks voltage range,
  ACMD41 polls until card leaves idle, CMD58 reads OCR to confirm SDHC.
- **FAT32** — MBR at sector 0 holds up to 4 partition entries; the BPB
  (BIOS Parameter Block) at the partition's first sector describes cluster
  size, FAT location, and root directory cluster.
- **Delta-sigma modulation** — noise-shaping technique; the quantisation
  error from each cycle is fed back into the next, spreading noise across
  the full spectrum. High oversampling keeps audible-band noise very low.
- **Fractional sample rate** — a 32-bit accumulator overflows at precisely
  the target sample rate without needing a PLL or fractional divider.

## Debugging note

During development, the initial MBR parser only checked the first of the four
partition entries, and only for FAT32 type codes `0x0B`/`0x0C`. This proved
unreliable. The fixes that resolved it:

1. Verify the MBR boot signature (`0x55AA` at byte offsets 510–511) before
   trusting any partition entry.
2. Scan all four partition entries instead of stopping at the first.
3. Use the error-state LED display: in `ST_ERROR` the FSM latches the
   problematic byte into `debug_byte`, which appears on `LED[7:1]`. Reading
   the raw byte off the LEDs made it immediately clear when a sector read was
   returning garbage rather than a genuine filesystem error.
