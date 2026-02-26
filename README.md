# FPGA Projects

Multi-board FPGA development environment. Native toolchain via [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build); Docker images available as a fallback.

## Boards

| Board | FPGA | Clock | Directory |
|-------|------|-------|-----------|
| [Muselab iCESugar v1.5](https://github.com/wuxx/icesugar) | Lattice iCE40UP5K | 12 MHz | `icesugar/` |
| [ULX3S 85F](https://github.com/emard/ulx3s) | Lattice ECP5 LFE5U-85F | 25 MHz | `ulx3s/` |

## Examples

### iCESugar (iCE40UP5K)

| Example | Description |
|---------|-------------|
| `blinky` | RGB LED blinky — cycles through colours using a free-running counter |
| `tone` | 440 Hz square wave output via PMOD Audio |
| `sine_tone` | 440 Hz sine wave via PWM + 256-entry lookup table |
| `uart_hello` | Sends "Hello, World!" repeatedly over UART at 9600 baud |
| `sine_rgb` | Sine tone combined with an RGB colour wheel |

#### granular-synth-engine (work in progress)

| Stage | Description |
|-------|-------------|
| `01_i2s_out` | I2S digital audio output |
| `02_i2s_passthrough` | I2S loopback (ADC → DAC passthrough) |
| `03_spi_slave` | SPI slave for control parameter updates |
| `04_dds_synth` | Direct digital synthesis oscillator |
| `05_grain_engine` | Granular synthesis engine |

### ULX3S (ECP5 LFE5U-85F)

| Example | Description |
|---------|-------------|
| `blinky` | 8-LED binary counter driven from a 26-bit free-running counter |
| `buttons` | Move a single LED across the bar with directional buttons |
| `sdcard` | Read a 44.1 kHz 16-bit WAV from FAT32 SD card and play via 3.5mm jack |

## Quick Start

### Prerequisites

- **Native toolchain (preferred):** [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) installed at `~/oss-cad-suite/` and sourced in your shell
- **Docker** — fallback if native tools are unavailable
- **iCESugar programmer:** iCELink USB mass-storage (built into board)
- **ULX3S programmer:** `openFPGALoader` (`brew install openfpgaloader` on macOS)

### Build

```bash
# iCESugar
cd icesugar && make -C examples/<name>

# ULX3S
cd ulx3s && make -C examples/<name>
```

### Flash

```bash
# iCESugar — copies bitstream to iCELink mass-storage drive
cd icesugar && ./flash.sh build/<name>/top.bin

# ULX3S — loads into SRAM (volatile, lost on power-off)
cd ulx3s && ./flash.sh build/<name>/top.bit

# ULX3S — programs SPI flash (persistent, directly via openFPGALoader)
openFPGALoader --board=ulx3s --write-flash build/<name>/top.bit
```

> **macOS iCELink note:** Do not use `cp` or `dd` — macOS writes non-sequentially and breaks DAPLink. `flash.sh` uses `cat` to write sequentially. If `FAIL.TXT` appears on the drive, the flash failed.

### Docker fallback

```bash
cd icesugar && docker compose run fpga make -C examples/<name>
cd ulx3s   && docker compose run fpga make -C examples/<name>
```

## Project Structure

```
fpga/
├── icesugar/                     # iCESugar v1.5 (iCE40UP5K)
│   ├── Makefile.inc              # iCE40 build template
│   ├── icesugar.pcf              # Full board pin constraints
│   ├── flash.sh / flash.bat
│   ├── examples/
│   │   ├── blinky/
│   │   ├── tone/
│   │   ├── sine_tone/
│   │   ├── uart_hello/
│   │   └── sine_rgb/
│   └── granular-synth-engine/
│       ├── 01_i2s_out/
│       ├── 02_i2s_passthrough/
│       ├── 03_spi_slave/
│       ├── 04_dds_synth/
│       └── 05_grain_engine/
│
└── ulx3s/                        # ULX3S 85F (ECP5 LFE5U-85F)
    ├── Makefile.inc              # ECP5 build template
    ├── ulx3s.lpf                 # Full board pin constraints
    ├── flash.sh
    └── examples/
        ├── blinky/
        ├── buttons/
        └── sdcard/
```

## Adding a New Example

```makefile
# icesugar/examples/myproject/Makefile
TOP = top
PCF = myproject.pcf
SRC = myproject.v
include ../../Makefile.inc
```

```makefile
# ulx3s/examples/myproject/Makefile
TOP = top
LPF = myproject.lpf
SRC = myproject.v
include ../../Makefile.inc
```

Build output goes to `<board>/build/<project_name>/`. Top module is always named `top`.
