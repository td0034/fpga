# FPGA Project — Claude Code Instructions

## Project Overview
Containerised FPGA toolchain for the Muselab IceSugar v1.5 board (Lattice iCE40UP5K).
12 MHz onboard oscillator on GBIN0 (pin 35). Active-low RGB LEDs (R=40, G=41, B=39).
Pin mappings from the official [wuxx/icesugar](https://github.com/wuxx/icesugar) repository.

## Hardware
- **Board:** Muselab IceSugar v1.5 (iCE40UP5K, SG48 package)
- **Programmer:** iCELink (DAPLink v0254) — USB mass-storage device. Mounts as `/Volumes/iCELink` on Mac, drive letter (typically D:) on Windows
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
# Mac / Linux — no prefix needed
docker compose run fpga make -C /workspace/examples/<name>

# Windows (Git Bash) — prefix to prevent /workspace path mangling
MSYS_NO_PATHCONV=1 docker compose run fpga make -C /workspace/examples/<name>
```

### Flashing
The iCELink appears as a USB mass-storage drive. Use `flash.sh` (handles both Mac and Linux):
```bash
./flash.sh build/<name>/top.bin
```

Windows alternative:
```bash
cmd //c "cd C:\Users\td0034\Projects\fpga && flash.bat build\<name>\top.bin"
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

## macOS Notes
- No `MSYS_NO_PATHCONV` prefix needed — Docker volume mounts work natively
- iCELink mounts at `/Volumes/iCELink`
- **CRITICAL: Do NOT use `cp` or `dd` to flash the iCELink.** macOS writes files non-sequentially, which breaks the DAPLink protocol (error: "File sent out of order by PC"). Use `cat file.bin > /Volumes/iCELink/top.bin` instead — this does a simple sequential write that DAPLink accepts. The `flash.sh` script handles this automatically.
- After a successful flash the iCELink unmounts and remounts (brief "Permission denied" is normal)
- If `FAIL.TXT` appears on the iCELink drive, the flash failed — check its contents for the error

## Windows / Git Bash Notes
- Use `MSYS_NO_PATHCONV=1` prefix on docker commands to prevent `/workspace` path mangling
- Use `cmd //c` to run .bat files from Git Bash
- iCELink drive is accessible as `/d/` in Git Bash (if drive letter is D:)
