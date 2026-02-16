# FPGA Project — Claude Code Instructions

## Project Overview
Containerised FPGA toolchain for the Muselab IceSugar v1.5 board (Lattice iCE40UP5K).
12 MHz onboard oscillator on GBIN0 (pin 35). Active-low RGB LEDs (R=40, G=41, B=39).
Pin mappings from the official [wuxx/icesugar](https://github.com/wuxx/icesugar) repository.

## Hardware
- **Board:** Muselab IceSugar v1.5 (iCE40UP5K, SG48 package)
- **Programmer:** iCELink — USB mass-storage device, appears as drive letter (typically D:)
- **Audio:** MuseLab PMOD Audio v1.2 on PMOD header 3 (speaker pin = FPGA pin 32)
- **Serial:** UART TX=pin 6, RX=pin 4, bridged via iCELink USB-C (shares port with programmer)

## Toolchain (Docker)
- Yosys 0.44, nextpnr-ice40 0.7, IceStorm 1.1, iverilog (Ubuntu 22.04)
- Source in `projects/` mounted as `/workspace` in container
- Build output in `build/` mounted as `/build` in container
- Root `Makefile` mounted as `/workspace/Makefile.inc` (read-only)

## Allowed Operations

### Building
```bash
# Always prefix with MSYS_NO_PATHCONV=1 on Git Bash (Windows)
MSYS_NO_PATHCONV=1 docker compose run fpga make -C /workspace/examples/<name>
```

### Flashing
The iCELink appears as a USB mass-storage drive. Flash by copying the .bin file:
```bash
# Windows — find iCELink drive letter, copy .bin to it
cmd //c "cd C:\Users\td0034\Projects\fpga && flash.bat build\<name>\top.bin"

# Or directly copy to drive (typically D:)
cp build/<name>/top.bin /d/
```

### Docker
```bash
docker compose build          # Rebuild toolchain image
docker compose run fpga ...   # Run commands inside container
```

## Project Structure
```
fpga/
├── Dockerfile, docker-compose.yml
├── Makefile                  # Build template (mounted as /workspace/Makefile.inc)
├── icesugar.pcf              # Full board pin constraints
├── flash.sh / flash.bat      # Host-side flash scripts
├── projects/examples/        # All examples (mounted as /workspace/examples/)
│   ├── blinky/               # RGB LED blinky
│   ├── tone/                 # 440 Hz square wave (PMOD Audio)
│   ├── sine_tone/            # 440 Hz sine wave via PWM + LUT (PMOD Audio)
│   ├── uart_hello/           # UART serial output
│   └── sine_rgb/             # Sine tone + RGB colour wheel (parallelism)
└── build/                    # One subdir per example (build/blinky/, build/tone/, etc.)
```

## Example Makefile Pattern
Each example has its own Makefile:
```makefile
TOP  = top
PCF  = <name>.pcf
SRC  = <name>.v
include /workspace/Makefile.inc
```

## Key Conventions
- Each example has its own `.pcf` file (not the shared root `icesugar.pcf`)
- Build output goes to `/build/<project_name>/` (derived from directory name)
- Verilog source files should have thorough comments explaining what/how/why
- Top module is always named `top`
- All examples use 12 MHz clock (`FREQ=12`)

## Windows / Git Bash Notes
- Use `MSYS_NO_PATHCONV=1` prefix on docker commands to prevent `/workspace` path mangling
- Use `cmd //c` to run .bat files from Git Bash
- iCELink drive is accessible as `/d/` in Git Bash (if drive letter is D:)
