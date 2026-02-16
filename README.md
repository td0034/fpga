# IceSugar v1.5 Containerised Dev Environment

Docker-based FPGA toolchain for the Muselab IceSugar v1.5 board (Lattice iCE40UP5K).
Pin mappings sourced from the official [wuxx/icesugar](https://github.com/wuxx/icesugar) repository.

## Prerequisites

- Docker & Docker Compose
- IceSugar v1.5 board (for flashing)
- MuseLab PMOD Audio v1.2 (for audio examples — plugs into PMOD header 3)

## Quick Start

```bash
# Build the toolchain image (first time takes ~20 min)
docker compose build

# Build an example
docker compose run fpga make -C /workspace/examples/blinky

# Flash to board (Windows)
flash.bat build\blinky\top.bin

# Flash to board (Linux/Mac)
./flash.sh build/blinky/top.bin
```

> **Windows note:** If using Git Bash, prefix docker commands with
> `MSYS_NO_PATHCONV=1` to prevent path mangling of `/workspace`.

## Workflow

All synthesis runs inside the container. The resulting `.bin` file lands in
`build/<project>/` via a shared volume. You flash from the host by copying
the `.bin` to the iCELink USB mass-storage drive.

```
 Source files (projects/)          Build artifacts (build/)
        │                                  │
        ▼                                  ▼
┌─────────────────────────────────────────────────┐
│  Docker container                               │
│                                                 │
│  *.v ──► yosys ──► nextpnr-ice40 ──► icepack   │
│          synth      place & route      bitstream│
│         .json          .asc             .bin    │
└─────────────────────────────────────────────────┘
        │                                  │
        │         shared volumes           │
        ▼                                  ▼
┌─────────────────────────────────────────────────┐
│  Host                                           │
│                                                 │
│  flash.sh / flash.bat                           │
│  copies .bin ──► iCELink USB drive ──► FPGA     │
└─────────────────────────────────────────────────┘
```

### Step by step

1. **Edit** your Verilog source in `projects/` (any editor on the host).
2. **Build** inside the container:
   ```bash
   docker compose run fpga make -C /workspace/examples/blinky
   ```
3. **Flash** from the host:
   ```bash
   # Windows — the iCELink appears as a drive letter (e.g. D:)
   flash.bat build\blinky\top.bin

   # Linux/Mac — auto-detects the iCELink mount point
   ./flash.sh build/blinky/top.bin
   ```
4. The iCELink programmer loads the bitstream automatically — no drivers needed.

> **Note:** The iCELink programs via the USB-C port and also bridges UART to
> a virtual COM port on the same connection. When flashing, you'll see
> `@prog` / `@cdone` messages on the serial terminal — this is normal.

### Build output

Each example builds into its own subdirectory under `build/`, so examples
don't clobber each other:

```
build/
├── blinky/top.bin
├── tone/top.bin
├── sine_tone/top.bin
├── uart_hello/top.bin
└── sine_rgb/top.bin
```

You can switch between pre-built bitstreams instantly without recompiling:
```bash
flash.bat build\sine_rgb\top.bin    # switch to sine + RGB
flash.bat build\uart_hello\top.bin  # switch to UART
```

## Project Structure

```
fpga/
├── Dockerfile              # Toolchain (yosys 0.44, nextpnr 0.7, icestorm 1.1)
├── docker-compose.yml      # Mounts projects/ → /workspace, build/ → /build
├── Makefile                # Reusable build template (mounted as /workspace/Makefile.inc)
├── icesugar.pcf            # Full pin constraints for IceSugar v1.5
├── flash.sh                # Linux/Mac flash script
├── flash.bat               # Windows flash script
├── projects/               # ← mounted into container as /workspace
│   └── examples/
│       ├── blinky/         # RGB LED blinky
│       ├── tone/           # 440 Hz square wave tone
│       ├── sine_tone/      # 440 Hz sine wave tone (PWM + LUT)
│       ├── uart_hello/     # UART serial "Hello from iCE40!"
│       └── sine_rgb/       # Sine tone + RGB colour wheel (parallelism demo)
└── build/                  # ← build output, one subdir per example
```

## Examples

### blinky — RGB LED

Cycles the onboard RGB LED through colours at ~1 Hz. The "hello world" of
FPGA development — if the LED blinks, your toolchain and board are working.

**Concepts:** clock divider, bit slicing, active-low outputs.

```bash
docker compose run fpga make -C /workspace/examples/blinky
flash.bat build\blinky\top.bin
```

### tone — 440 Hz square wave (PMOD Audio v1.2)

Generates a 440 Hz (A4) square wave on the speaker. Sounds buzzy — that's
the nature of a square wave (rich in odd harmonics). Green LED blinks to
show the design is running.

**Concepts:** clock divider, frequency calculation from clock rate.

```bash
docker compose run fpga make -C /workspace/examples/tone
flash.bat build\tone\top.bin
```

### sine_tone — 440 Hz sine wave (PMOD Audio v1.2)

Plays the same A4 note but as a smooth sine wave using three stages:
phase accumulator → 256-entry sine lookup table → 8-bit PWM output. Much
cleaner sound than the square wave. Red LED glows to show PWM is working.

**Concepts:** phase accumulator (DDS), lookup tables (ROM in LUTs), PWM
as a crude DAC, the RC filter on the PMOD smoothing PWM into analog.

```bash
docker compose run fpga make -C /workspace/examples/sine_tone
flash.bat build\sine_tone\top.bin
```

### uart_hello — Serial output

Sends `Hello from iCE40!` over the USB serial port once per second. Open a
serial terminal (PuTTY, minicom, Arduino serial monitor) at **115200 baud
8N1** on the iCELink COM port. Green LED toggles with each message.

**Concepts:** UART protocol (start/stop bits, baud rate), shift registers,
state machines (idle → send → wait), ROM-based string storage.

```bash
docker compose run fpga make -C /workspace/examples/uart_hello
flash.bat build\uart_hello\top.bin
```

> The iCELink's `@prog` / `@cdone` messages appear on the same serial port
> before your design's output starts — this is the programmer's own debug
> output sharing the UART pins.

### sine_rgb — Sine tone + RGB colour wheel (parallelism demo)

Plays a 440 Hz sine wave AND smoothly fades the RGB LED through the full
colour wheel — both running truly in parallel. This demonstrates the key
difference between FPGAs and microcontrollers: there's no main loop, no
time-slicing. The audio circuit and LED circuit are physically separate
hardware that happen to share one PWM counter.

**Concepts:** FPGA parallelism, HSV-to-RGB conversion (6-segment hue
decode), resource sharing (single PWM counter serving 4 outputs), combining
independent subsystems.

```bash
docker compose run fpga make -C /workspace/examples/sine_rgb
flash.bat build\sine_rgb\top.bin
```

## Pin Reference

Pin mappings from [wuxx/icesugar `io.pcf`](https://github.com/wuxx/icesugar/blob/master/src/common/io.pcf):

| Signal   | FPGA Pin | Notes                          |
|----------|----------|--------------------------------|
| clk      | 35       | 12 MHz oscillator (GBIN0 — dedicated clock input) |
| LED_R    | 40       | Active low                     |
| LED_G    | 41       | Active low                     |
| LED_B    | 39       | Active low                     |
| SW0-SW3  | 18-21    | Shared with PMOD 4             |
| UART TX  | 6        | FPGA → PC (via iCELink USB-C)  |
| UART RX  | 4        | PC → FPGA (via iCELink USB-C)  |
| PMOD 1   | 10,6,3,48,47,2,4,9 | Shared with UART + USB — avoid |
| PMOD 2   | 46,44,42,37,36,38,43,45 | No conflicts      |
| PMOD 3   | 34,31,27,25,23,26,28,32 | No conflicts (audio examples use pin 32) |
| PMOD 4   | 21,20,19,18 | Half-width, shared with switches |

## Makefile Variables

| Variable | Default        | Description              |
|----------|----------------|--------------------------|
| `TOP`    | `top`          | Top-level module name    |
| `PCF`    | `icesugar.pcf` | Pin constraints file     |
| `FREQ`   | `12`           | Clock frequency (MHz)    |
| `SRC`    | `*.v`          | Verilog source files     |
| `PROJECT`| dir name       | Build output subdirectory|

## Make Targets

| Target      | Description                              |
|-------------|------------------------------------------|
| `make all`  | Full build (synth + pnr + pack)          |
| `make synth`| Yosys synthesis (.v -> .json)            |
| `make pnr`  | nextpnr place & route (.json -> .asc)    |
| `make pack` | icepack (.asc -> .bin)                   |
| `make sim`  | iverilog + vvp simulation                |
| `make clean`| Remove build artifacts                   |

## Creating a New Project

```bash
mkdir -p projects/myproject
```

Create `myproject.v` with a `top` module and a `myproject.pcf` pin
constraints file. Add a Makefile:

```makefile
TOP  = top
PCF  = myproject.pcf
SRC  = myproject.v

include /workspace/Makefile.inc
```

Build and flash:
```bash
docker compose run fpga make -C /workspace/myproject
flash.bat build\myproject\top.bin
```

## Toolchain Versions

| Tool         | Version    | Source |
|--------------|------------|--------|
| Yosys        | 0.44       | [YosysHQ/yosys](https://github.com/YosysHQ/yosys) |
| nextpnr      | 0.7        | [YosysHQ/nextpnr](https://github.com/YosysHQ/nextpnr) |
| IceStorm     | 1.1        | [YosysHQ/icestorm](https://github.com/YosysHQ/icestorm) |
| Icarus Verilog | apt (22.04) | Simulation only |
| Base image   | Ubuntu 22.04 | |
