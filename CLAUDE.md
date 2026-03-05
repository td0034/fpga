# FPGA Project — Claude Code Instructions

## Project Overview
Multi-board FPGA development environment with containerised toolchains.
Each board has its own subdirectory with Dockerfile, build system, and examples.

## Boards

### iCESugar v1.5 (`icesugar/`)
- **FPGA:** Lattice iCE40UP5K, SG48 package
- **Clock:** 12 MHz onboard oscillator on GBIN0 (pin 35)
- **LEDs:** Active-low RGB (R=40, G=41, B=39)
- **Programmer:** iCELink (DAPLink v0254) — USB mass-storage device
- **Audio:** MuseLab PMOD Audio v1.2 on PMOD header 3 (speaker pin = FPGA pin 32)
- **Serial:** UART TX=pin 6, RX=pin 4, bridged via iCELink USB-C
- **Toolchain:** Yosys 0.44, nextpnr-ice40 0.7, IceStorm 1.1, iverilog
- **Pin mappings:** [wuxx/icesugar](https://github.com/wuxx/icesugar)

### ULX3S 85F (`ulx3s/`)
- **FPGA:** Lattice ECP5 LFE5U-85F, CABGA381 package
- **Clock:** 25 MHz onboard oscillator (pin G2)
- **LEDs:** 8 active-high LEDs (B2, C2, C1, D2, D1, E2, E1, H3)
- **Buttons:** 7 buttons (PWR=D6, FIRE1=R1, FIRE2=T1, UP=R18, DOWN=V1, LEFT=U1, RIGHT=H16)
- **Programmer:** openFPGALoader via USB (FTDI bridge)
- **Audio (onboard):** 4-bit resistor DAC per channel on 3.5mm jack
- **Audio (external):** PCM5102A DAC breakout on J1 header GN0–GN7:
  - GN0 (C11) = FLT (LOW), GN1 (A11) = DMP (LOW), GN2 (B10) = SCL (LOW)
  - GN3 (C10) = BCK, GN4 (A8) = DIN, GN5 (B8) = LCK
  - GN6 (C7) = FMT (LOW), GN7 (B6) = XMT (HIGH=unmute)
  - VCC → 3.3V, GND → GND (from J1 header pins 1–4)
- **Serial:** UART via FTDI bridge (RXD=M1, TXD=L4)
- **Toolchain:** Yosys 0.44, nextpnr-ecp5 0.7, Project Trellis, iverilog
- **Pin mappings:** [emard/ulx3s](https://github.com/emard/ulx3s)

## Toolchain
Native tools via [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) at `~/oss-cad-suite/`.
Sourced in `.zshrc` — tools are on PATH in every shell.

Docker images are also available per-board as a fallback (see Docker section below).

## Building (native — preferred)
```bash
cd icesugar && make -C examples/<name>     # iCESugar (iCE40)
cd ulx3s && make -C examples/<name>        # ULX3S (ECP5)
```

### Building (Docker — fallback)
```bash
cd icesugar && docker compose run fpga make -C examples/<name>
cd ulx3s && docker compose run fpga make -C examples/<name>

# Windows (Git Bash) — prefix to prevent /workspace path mangling
MSYS_NO_PATHCONV=1 docker compose run fpga make -C examples/<name>
```

## Flashing

### iCESugar
The iCELink appears as a USB mass-storage drive. Use `flash.sh` (handles both Mac and Linux):
```bash
cd icesugar && ./flash.sh build/<name>/top.bin
```

Windows alternative:
```bash
cmd //c "cd C:\Users\td0034\Projects\fpga\icesugar && flash.bat build\<name>\top.bin"
```

### ULX3S
Uses openFPGALoader (install with `brew install openfpgaloader` on macOS):
```bash
cd ulx3s && ./flash.sh build/<name>/top.bit
```

## Docker (fallback)
```bash
cd icesugar && docker compose build   # Rebuild iCE40 toolchain
cd ulx3s && docker compose build      # Rebuild ECP5 toolchain
```

## Project Structure
```
fpga/
├── icesugar/                     # iCESugar v1.5 (iCE40UP5K)
│   ├── Dockerfile                # iCE40 toolchain
│   ├── docker-compose.yml
│   ├── Makefile.inc              # iCE40 build template
│   ├── icesugar.pcf              # Full board pin constraints
│   ├── flash.sh / flash.bat      # Host-side flash scripts
│   ├── examples/
│   │   ├── blinky/               # RGB LED blinky
│   │   ├── tone/                 # 440 Hz square wave (PMOD Audio)
│   │   ├── sine_tone/            # 440 Hz sine wave via PWM + LUT
│   │   ├── uart_hello/           # UART serial output
│   │   └── sine_rgb/             # Sine tone + RGB colour wheel
│   ├── granular-synth-engine/    # Multi-stage synth project
│   └── build/                    # Build output
│
└── ulx3s/                        # ULX3S 85F (ECP5 LFE5U-85F)
    ├── Dockerfile                # ECP5 toolchain
    ├── docker-compose.yml
    ├── Makefile.inc              # ECP5 build template
    ├── ulx3s.lpf                 # Full board pin constraints
    ├── flash.sh                  # Host-side flash script (openFPGALoader)
    ├── examples/
    │   ├── blinky/               # 8-LED binary counter
    │   ├── i2s_tone/             # 440 Hz sine wave via I2S to PCM5102A
    │   ├── sdcard_i2s/           # SD card WAV player via I2S to PCM5102A
    │   ├── i2s_passthrough/      # ADC→DAC I2S passthrough (PCM1808 + PCM5102A)
    │   └── oled_wave/            # SD WAV player + I2C OLED waveform display
    └── build/                    # Build output
```

## Example Makefile Pattern

### iCESugar (iCE40)
```makefile
TOP  = top
PCF  = <name>.pcf
SRC  = <name>.v
include ../../Makefile.inc
```

### ULX3S (ECP5)
```makefile
TOP  = top
LPF  = <name>.lpf
SRC  = <name>.v
include ../../Makefile.inc
```

## Key Conventions
- Each example has its own constraints file (`.pcf` for iCE40, `.lpf` for ECP5)
- Build output goes to `<board>/build/<project_name>/` (derived from directory name)
- Verilog source files should have thorough comments explaining what/how/why
- Top module is always named `top`
- iCESugar examples use 12 MHz clock (`FREQ=12`), ULX3S uses 25 MHz (`FREQ=25`)

## macOS Notes
- No `MSYS_NO_PATHCONV` prefix needed — Docker volume mounts work natively
- **iCESugar flashing:** iCELink mounts at `/Volumes/iCELink`
  - **CRITICAL: Do NOT use `cp` or `dd` to flash the iCELink.** macOS writes files non-sequentially, breaking DAPLink. Use `cat file.bin > /Volumes/iCELink/top.bin` instead. The `flash.sh` script handles this automatically.
  - After a successful flash the iCELink unmounts and remounts (brief "Permission denied" is normal)
  - If `FAIL.TXT` appears on the iCELink drive, the flash failed — check its contents
- **ULX3S flashing:** Requires `brew install openfpgaloader`

## Windows / Git Bash Notes
- Use `MSYS_NO_PATHCONV=1` prefix on docker commands to prevent `/workspace` path mangling
- Use `cmd //c` to run .bat files from Git Bash
- iCELink drive is accessible as `/d/` in Git Bash (if drive letter is D:)
