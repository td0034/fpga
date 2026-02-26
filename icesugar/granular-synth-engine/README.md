# Granular Synth Engine — iCE40UP5K Prototype

Granular synthesis engine for the IceSugar v1.5 (iCE40UP5K), building toward
an ECP5-based 1000-grain beast. Each subdirectory is a standalone build that
tests one piece of the signal chain.

## Sub-builds

| # | Directory | What it tests | Hardware needed |
|---|-----------|---------------|-----------------|
| 01 | `01_i2s_out` | I2S master → PCM5102A DAC (440 Hz sine) | PCM5102A on PMOD 3 |
| 02 | `02_i2s_passthrough` | ADC → FPGA → DAC loopback | PCM1808 on PMOD 2, PCM5102A on PMOD 3 |
| 03 | `03_spi_slave` | ESP32-S3 SPI → FPGA registers (LED control) | ESP32-S3 on PMOD 2 |
| 04 | `04_dds_synth` | SPI-controlled DDS oscillator → I2S DAC | ESP32-S3 on PMOD 2, PCM5102A on PMOD 3 |
| 05 | `05_grain_engine` | 8-grain SPRAM playback with SPI control | All three: ESP32-S3, PCM1808, PCM5102A |

## Build

```bash
# From repo root (Windows/Git Bash):
cd C:\Users\td0034\Projects\fpga

# Build a specific sub-project:
MSYS_NO_PATHCONV=1 docker compose run --rm fpga make -C /workspace/granular-synth-engine/01_i2s_out

# Flash:
.\flash.bat build\01_i2s_out\top.bin
```

## PCM5102A DAC Wiring (PMOD 3, top row)

| PCM5102A Pin | FPGA Pin | PMOD 3 Pin | Signal |
|-------------|----------|------------|--------|
| BCK | 34 | P3_1 | I2S bit clock |
| DIN | 31 | P3_2 | I2S serial data |
| LCK | 27 | P3_3 | I2S word select (L/R) |
| SCK | GND | — | Tie to GND (internal clock gen) |
| FMT | GND | — | I2S format |
| XSMT | 3.3V | — | Unmute |

## PCM1808 ADC Wiring (PMOD 2 or PMOD 3 bottom row)

See individual module PCF files for exact pin assignments.

## ESP32-S3 SPI Wiring (PMOD 2)

| Signal | FPGA Pin | PMOD 2 Pin |
|--------|----------|------------|
| SCK | 46 | P2_1 |
| MOSI | 44 | P2_2 |
| MISO | 42 | P2_3 |
| CS | 37 | P2_4 |
