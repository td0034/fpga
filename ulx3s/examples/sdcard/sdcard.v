// =============================================================================
// SD Card WAV Player — ULX3S 85F
// =============================================================================
//
// What this does:
//   Reads a 44.1 kHz, 16-bit WAV file from a FAT32-formatted SD card and plays
//   it through the 3.5mm headphone jack using delta-sigma modulation for better
//   audio quality than raw 4-bit output.
//
// Architecture overview:
//
//   1. SPI SD CONTROLLER — handles the SD card initialisation sequence
//      (CMD0 -> CMD8 -> ACMD41 -> CMD58) to put the card into SPI mode,
//      then issues CMD17 for single-block reads (512 bytes each).
//
//   2. FAT32 READER — reads sector 0 (MBR) to find the first FAT32 partition,
//      reads the partition's boot sector (BPB) to locate the FAT table and
//      data region, then scans root directory entries to find the first file
//      whose name ends in "WAV".
//
//   3. WAV PARSER — skips the standard 44-byte RIFF header, then streams
//      raw PCM sample data. Supports mono and stereo (auto-detected from
//      the WAV header's channel count at byte offset 22).
//
//   4. DELTA-SIGMA DAC — converts 16-bit PCM samples to 4-bit output using
//      first-order delta-sigma modulation running at 25 MHz. This gives
//      far better effective resolution than driving the 4 resistor-DAC bits
//      directly. The high oversampling ratio (25 MHz / 44.1 kHz = 567x)
//      pushes quantisation noise well above the audible range.
//
//   5. SAMPLE RATE CONTROL — a fractional accumulator generates precise
//      44,100 Hz timing from the 25 MHz clock.
//
//   6. STATUS LEDs — 8 LEDs show the current state:
//        LED[0]     = heartbeat (always blinks to show FPGA is alive)
//        LED[1]     = SD card initialised OK
//        LED[2]     = FAT32 partition found
//        LED[3]     = WAV file found
//        LED[4]     = currently playing audio
//        LED[5]     = mono (on) / stereo (off) indicator
//        LED[7:6]   = error code (00=none, 01=SD init fail,
//                     10=no FAT32, 11=no WAV file)
//
// Hardware:
//   - SD card in slot (accessed via SPI mode)
//   - 3.5mm headphone jack (4-bit resistor DAC per channel)
//   - 8 onboard LEDs for status
//
// Assumptions:
//   - FAT32 partition (first partition in MBR)
//   - Standard RIFF WAV file: 44.1 kHz, 16-bit, mono or stereo
//   - WAV file is in the root directory (first .WAV file found is played)
//   - SD card is SDHC/SDXC (block-addressed, as all modern cards are)
//
// =============================================================================

module top (
    input  wire       clk,          // 25 MHz oscillator
    output wire [7:0] led,          // 8 onboard LEDs (active high)

    // SD card (SPI mode)
    // On the ULX3S, the SD card pins map to SPI as follows:
    //   sd_clk  -> SPI CLK
    //   sd_cmd  -> SPI MOSI (active output active to card)
    //   sd_d[0] -> SPI MISO (active input active from card)
    //   sd_d[3] -> SPI CS_n (active low chip select — directly active output)
    // sd_d[1] and sd_d[2] are unused in SPI mode (active high via pullups).
    output wire       sd_clk,       // SPI clock
    output wire       sd_cmd,       // SPI MOSI
    input  wire       sd_d0,        // SPI MISO (active input)
    output wire       sd_d3,        // SPI CS_n (active output)

    // Audio DAC (4-bit resistor DAC per channel)
    output reg  [3:0] audio_l,      // left channel
    output reg  [3:0] audio_r,      // right channel

    // Buttons
    input  wire       btn_fire1     // replay WAV from start (active high, PULLMODE=DOWN)
);

    // =========================================================================
    // SPI clock divider
    // =========================================================================
    //
    // During init, SD cards require <= 400 kHz.
    //   25 MHz / (2 * 32) = ~390 kHz
    // After init, we speed up for data transfer.
    //   25 MHz / (2 * 2) = ~6.25 MHz

    localparam [5:0] SPI_DIV_INIT = 6'd31;
    localparam [5:0] SPI_DIV_FAST = 6'd1;

    // =========================================================================
    // Sample rate timing — 44.1 kHz from 25 MHz
    // =========================================================================
    //
    // Fractional accumulator: each overflow of the 32-bit accumulator
    // produces one sample_tick. Increment chosen so overflows occur at 44.1 kHz.
    //
    //   inc = round(44100 * 2^32 / 25000000) = 7,578,071
    //   Actual rate = 7578071 * 25e6 / 2^32 = 44,099.993 Hz (0.16 ppm error)

    localparam [31:0] SAMPLE_RATE_INC = 32'd7578071;

    // =========================================================================
    // Main state machine states
    // =========================================================================

    localparam [3:0]
        ST_POWER_UP    = 4'd0,
        ST_CMD0        = 4'd1,
        ST_CMD8        = 4'd2,
        ST_ACMD41      = 4'd3,
        ST_CMD58       = 4'd4,
        ST_SD_READY    = 4'd5,
        ST_READ_MBR    = 4'd6,
        ST_READ_BPB    = 4'd7,
        ST_SCAN_DIR    = 4'd8,
        ST_PLAY        = 4'd9,
        ST_NEXT_CLUSTER = 4'd10,
        ST_DONE        = 4'd11,
        ST_ERROR       = 4'd12;

    reg [3:0] state = ST_POWER_UP;

    // =========================================================================
    // SPI engine — bit-bang SPI master (Mode 0: CPOL=0, CPHA=0)
    // =========================================================================
    //
    // Byte-level interface: load spi_tx_byte, pulse spi_start, wait for
    // spi_done. Received byte appears in spi_rx_byte.
    //
    // Clock idles low. Data is set up on MOSI before the rising edge.
    // MISO is sampled on the rising edge.

    reg [5:0]  spi_div = SPI_DIV_INIT;
    reg [5:0]  spi_cnt = 0;
    reg        spi_clk_out = 0;
    reg        spi_mosi_out = 1;
    reg        spi_cs_n = 1;

    reg [7:0]  spi_tx_byte;
    reg [7:0]  spi_rx_byte;
    reg        spi_start = 0;
    reg        spi_done = 0;
    reg        spi_active = 0;
    reg [2:0]  spi_bit_idx;
    reg        spi_phase = 0;    // 0 = rising edge next, 1 = falling edge next

    assign sd_clk = spi_clk_out;
    assign sd_cmd = spi_mosi_out;
    assign sd_d3  = spi_cs_n;

    wire spi_miso = sd_d0;

    always @(posedge clk) begin
        spi_done <= 0;

        if (spi_start && !spi_active) begin
            // Begin a new byte transfer
            spi_active  <= 1;
            spi_bit_idx <= 3'd7;
            spi_phase   <= 0;
            spi_cnt     <= 0;
            // Set up MSB on MOSI (clock is low, data changes on falling edge/idle)
            spi_mosi_out <= spi_tx_byte[7];
        end else if (spi_active) begin
            if (spi_cnt == spi_div) begin
                spi_cnt <= 0;
                if (!spi_phase) begin
                    // Rising edge: sample MISO
                    spi_clk_out <= 1;
                    spi_phase   <= 1;
                    spi_rx_byte <= {spi_rx_byte[6:0], spi_miso};
                end else begin
                    // Falling edge: update MOSI or finish
                    spi_clk_out <= 0;
                    spi_phase   <= 0;
                    if (spi_bit_idx == 0) begin
                        spi_active <= 0;
                        spi_done   <= 1;
                    end else begin
                        spi_bit_idx  <= spi_bit_idx - 1;
                        spi_mosi_out <= spi_tx_byte[spi_bit_idx - 1];
                    end
                end
            end else begin
                spi_cnt <= spi_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Sector buffer — 512 bytes of block RAM
    // =========================================================================
    //
    // Stores one complete 512-byte sector for random-access parsing of
    // MBR, BPB, directory entries, and FAT entries. During playback it also
    // buffers audio data.

    reg [7:0]  sector_buf [0:511];
    reg [8:0]  sector_wr_idx;       // write index during sector read

    // =========================================================================
    // FAT32 filesystem state
    // =========================================================================

    reg [31:0] part_lba;            // LBA of FAT32 partition start
    reg [7:0]  spc;                 // sectors per cluster
    reg [15:0] reserved_sectors;
    reg [7:0]  num_fats;
    reg [31:0] sectors_per_fat;
    reg [31:0] root_cluster;
    reg [31:0] fat_lba;             // absolute LBA of FAT region start
    reg [31:0] data_lba;            // absolute LBA of data region start
    reg [31:0] file_cluster;        // first cluster of the WAV file
    reg [31:0] file_size;           // WAV file size in bytes
    reg [31:0] bytes_read;          // bytes read from file so far
    reg        is_stereo;
    reg [31:0] cur_cluster;         // cluster currently being read
    reg [7:0]  sec_in_cluster;      // sector index within current cluster
    reg [31:0] cur_sector_lba;      // LBA of the sector being read

    // =========================================================================
    // Audio state
    // =========================================================================

    reg [15:0] audio_left  = 16'h8000;  // unsigned 16-bit (mid = silence)
    reg [15:0] audio_right = 16'h8000;

    // Delta-sigma accumulators: 13 bits (the residual below the 4-bit output)
    // plus 4 carry bits = 17 total. But we only need 13+1 = 14 bits to
    // detect one carry bit, then output the top 4 bits of the full sum.
    // Actually, for 16-bit input -> 4-bit output, the accumulator is 16 bits
    // wide (matching the input), and the carry into bit 16 produces the
    // quantised output. We keep the bottom 12 bits as error (16 - 4 = 12).
    //
    // Simpler approach: accumulator = accumulator[11:0] + sample[15:0]
    // Output = accumulator[15:12] (top 4 bits of 16-bit sum)
    // Residual = accumulator[11:0] (bottom 12 bits, carries forward)
    reg [15:0] ds_acc_l = 0;
    reg [15:0] ds_acc_r = 0;

    // Sample rate accumulator
    reg [31:0] sr_acc = 0;
    wire        sample_tick;
    reg [32:0] sr_next;

    always @(*) begin
        sr_next = {1'b0, sr_acc} + {1'b0, SAMPLE_RATE_INC};
    end

    assign sample_tick = sr_next[32];

    always @(posedge clk) begin
        sr_acc <= sr_next[31:0];
    end

    // =========================================================================
    // Delta-sigma DAC — first-order, 25 MHz
    // =========================================================================
    //
    // Each clock cycle we add the 16-bit input sample to the 12-bit residual
    // from the previous cycle. The result is 16 bits wide:
    //   - Top 4 bits [15:12] = quantised output for the DAC
    //   - Bottom 12 bits [11:0] = residual error, carried to next cycle
    //
    // This effectively performs: output = floor((residual + sample) / 4096)
    // The residual accumulates the sub-LSB error across cycles.
    //
    // Over many cycles the time-averaged output converges to:
    //   sample / 65536 * 16 = sample / 4096
    // which is exactly the value the 4-bit DAC should represent.
    //
    // With 25 MHz clock and 44.1 kHz sample rate, there are ~567 DAC cycles
    // per sample — enough oversampling to push quantisation noise far above
    // the audible range.

    always @(posedge clk) begin
        ds_acc_l <= {4'b0, ds_acc_l[11:0]} + audio_left;
        ds_acc_r <= {4'b0, ds_acc_r[11:0]} + audio_right;
    end

    always @(posedge clk) begin
        audio_l <= ds_acc_l[15:12];
        audio_r <= ds_acc_r[15:12];
    end

    // =========================================================================
    // Status LEDs
    // =========================================================================

    reg [24:0] heartbeat = 0;
    always @(posedge clk)
        heartbeat <= heartbeat + 1;

    // Button synchroniser + edge detector for FIRE1 (replay)
    reg [1:0] sync_fire1 = 0;
    reg       prev_fire1 = 0;
    always @(posedge clk) begin
        sync_fire1 <= {sync_fire1[0], btn_fire1};
        prev_fire1 <= sync_fire1[1];
    end
    wire rise_fire1 = sync_fire1[1] & ~prev_fire1;

    reg led_sd_ok   = 0;
    reg led_fat_ok  = 0;
    reg led_wav_ok  = 0;
    reg led_playing = 0;
    reg led_mono    = 0;
    reg [1:0] led_err = 0;
    reg [7:0] debug_byte = 0;      // diagnostic byte shown on LEDs during error
    reg       in_error = 0;        // 1 = we're in error state

    // In error state: blink heartbeat on LED[0], show debug_byte on LED[7:1]
    // so we can read what the FPGA actually saw.
    // Normal state: standard status LEDs.
    assign led[0] = heartbeat[24];
    assign led[1] = in_error ? debug_byte[1] : led_sd_ok;
    assign led[2] = in_error ? debug_byte[2] : led_fat_ok;
    assign led[3] = in_error ? debug_byte[3] : led_wav_ok;
    assign led[4] = in_error ? debug_byte[4] : led_playing;
    assign led[5] = in_error ? debug_byte[5] : led_mono;
    assign led[6] = in_error ? debug_byte[6] : led_err[0];
    assign led[7] = in_error ? debug_byte[7] : led_err[1];

    // =========================================================================
    // Main FSM
    // =========================================================================
    //
    // sub tracks the current sub-step within each state. Many states share
    // a common "send CMD17 -> wait R1 -> wait token -> read 512 bytes -> CRC"
    // sequence, but the simplicity of inlining it per-state outweighs the
    // code duplication.

    reg [7:0]  sub = 0;
    reg [15:0] wait_cnt = 0;
    reg [7:0]  retry_cnt = 0;
    reg [31:0] powerup_cnt = 0;
    reg [7:0]  cmd_r1;
    reg [31:0] cmd_r7;

    // Directory scanning
    reg [3:0]  dir_entry;           // 0..15 entries per sector

    // Playback byte streaming
    reg [9:0]  play_idx;            // byte index in sector_buf during playback (10 bits for >= 512 check)
    reg [7:0]  sample_lo;           // low byte of 16-bit sample
    reg        sample_hi_next;      // 1 = next byte is high byte
    reg        sample_is_right;     // 1 = assembling right channel

    always @(posedge clk) begin
        spi_start <= 0;

        case (state)

        // =================================================================
        // POWER_UP — wait >1 ms then send 80 clocks with CS high
        // =================================================================
        ST_POWER_UP: begin
            spi_cs_n <= 1;
            if (powerup_cnt < 32'd50000) begin
                powerup_cnt <= powerup_cnt + 1;
            end else if (sub < 8'd20) begin
                // Send 10 bytes of 0xFF = 80 clock pulses
                if (!sub[0]) begin
                    spi_tx_byte <= 8'hFF;
                    spi_start   <= 1;
                    sub         <= sub + 1;
                end else if (spi_done) begin
                    sub <= sub + 1;
                end
            end else begin
                sub   <= 0;
                state <= ST_CMD0;
            end
        end

        // =================================================================
        // CMD0 — GO_IDLE_STATE (0x40 0x00000000 0x95)
        // Expected R1: 0x01 (in idle state)
        // =================================================================
        ST_CMD0: begin
            spi_cs_n <= 0;
            case (sub)
                0:  begin spi_tx_byte <= 8'h40; spi_start <= 1; sub <= 1; end
                1:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= 8'h95; spi_start <= 1; sub <= 6; end
                // Poll for R1 (first non-0xFF byte)
                6:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin
                            cmd_r1 <= spi_rx_byte;
                            spi_cs_n <= 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8;
                        end else if (wait_cnt < 16'd32) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                8:  if (spi_done) begin
                        if (cmd_r1 == 8'h01) begin sub <= 0; state <= ST_CMD8; end
                        else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // CMD8 — SEND_IF_COND (0x48 0x000001AA 0x87)
        // R7 response: R1 + 4 bytes. Check echo = 0x1AA.
        // =================================================================
        ST_CMD8: begin
            spi_cs_n <= 0;
            case (sub)
                0:  begin spi_tx_byte <= 8'h48; spi_start <= 1; sub <= 1; end
                1:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= 8'h01; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= 8'hAA; spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= 8'h87; spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin
                            cmd_r1 <= spi_rx_byte;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8;
                        end else if (wait_cnt < 16'd32) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                // Read 4 bytes of R7
                8:  if (spi_done) begin cmd_r7[31:24] <= spi_rx_byte; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 9; end
                9:  if (spi_done) begin cmd_r7[23:16] <= spi_rx_byte; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin cmd_r7[15:8]  <= spi_rx_byte; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11; end
                11: if (spi_done) begin
                        cmd_r7[7:0] <= spi_rx_byte;
                        spi_cs_n <= 1;
                        spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                    end
                12: if (spi_done) begin
                        if (cmd_r1 == 8'h01 && cmd_r7[11:0] == 12'h1AA) begin
                            retry_cnt <= 0; sub <= 0; state <= ST_ACMD41;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // ACMD41 — CMD55 + ACMD41 loop until card ready
        // CMD55: 0x77 0x00000000 0xFF
        // ACMD41: 0x69 0x40000000 0xFF (HCS bit set for SDHC)
        // Card ready when R1 = 0x00.
        // =================================================================
        ST_ACMD41: begin
            case (sub)
                // --- CMD55 ---
                0:  begin spi_cs_n <= 0; spi_tx_byte <= 8'h77; spi_start <= 1; sub <= 1; end
                1:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin
                            spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8;
                        end else if (wait_cnt < 16'd32) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                8:  if (spi_done) begin spi_cs_n <= 0; sub <= 9; end
                // --- ACMD41 (0x40|41 = 0x69, arg = 0x40000000) ---
                9:  begin spi_tx_byte <= 8'h69; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin spi_tx_byte <= 8'h40; spi_start <= 1; sub <= 11; end
                11: if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 12; end
                12: if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 13; end
                13: if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 14; end
                14: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 15; end
                15: if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 16; end
                16: if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin
                            cmd_r1 <= spi_rx_byte;
                            spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 17;
                        end else if (wait_cnt < 16'd32) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                17: if (spi_done) begin
                        if (cmd_r1 == 8'h00) begin
                            sub <= 0; state <= ST_CMD58;
                        end else if (retry_cnt < 8'd255) begin
                            retry_cnt <= retry_cnt + 1; sub <= 0;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // CMD58 — READ_OCR (confirm SDHC via CCS bit 30)
        // =================================================================
        ST_CMD58: begin
            spi_cs_n <= 0;
            case (sub)
                0:  begin spi_tx_byte <= 8'h7A; spi_start <= 1; sub <= 1; end
                1:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin
                            cmd_r1 <= spi_rx_byte;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8;
                        end else if (wait_cnt < 16'd32) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin
                            led_err <= 2'b01; state <= ST_ERROR; sub <= 0;
                        end
                    end
                8:  if (spi_done) begin cmd_r7[31:24] <= spi_rx_byte; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 9; end
                9:  if (spi_done) begin cmd_r7[23:16] <= spi_rx_byte; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin cmd_r7[15:8]  <= spi_rx_byte; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11; end
                11: if (spi_done) begin
                        cmd_r7[7:0] <= spi_rx_byte;
                        spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                    end
                12: if (spi_done) begin
                        led_sd_ok <= 1;
                        sub <= 0; state <= ST_SD_READY;
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // SD_READY — switch to fast clock, proceed to read MBR
        // =================================================================
        ST_SD_READY: begin
            spi_div <= SPI_DIV_FAST;
            sub     <= 0;
            state   <= ST_READ_MBR;
        end

        // =================================================================
        // READ_MBR — read sector 0, find first FAT32 partition
        //
        // MBR partition table at offset 446 (16 bytes per entry).
        // Entry type at offset 450: 0x0B or 0x0C = FAT32.
        // Entry LBA start at offset 454 (32-bit little-endian).
        // =================================================================
        ST_READ_MBR: begin
            case (sub)
                0: begin cur_sector_lba <= 32'd0; sub <= 1; end
                // --- CMD17 sequence (reused pattern) ---
                1:  begin spi_cs_n <= 0; spi_tx_byte <= 8'h51; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[31:24]; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[23:16]; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[15:8];  spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[7:0];   spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                // Wait for R1
                7:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin sub <= 9; end
                        else if (wait_cnt < 16'd64) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                // Wait for data token 0xFE
                9:  begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin
                        if (spi_rx_byte == 8'hFE) begin
                            sector_wr_idx <= 0;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11;
                        end else if (wait_cnt < 16'd8192) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                // Read 512 data bytes
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx] <= spi_rx_byte;
                        if (sector_wr_idx == 9'd511) begin
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                        end else begin
                            sector_wr_idx <= sector_wr_idx + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end
                    end
                // CRC1
                12: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 13; end
                // CRC2 + deassert CS
                13: if (spi_done) begin spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 14; end
                // Parse MBR — check boot signature then scan all 4 partition entries
                // for FAT32 type codes: 0x0B (FAT32), 0x0C (FAT32 LBA),
                // 0x07 (sometimes used by exFAT/NTFS but also seen on FAT32)
                14: if (spi_done) begin
                        // Verify MBR boot signature (0x55AA at offset 510-511)
                        if (sector_buf[510] != 8'h55 || sector_buf[511] != 8'hAA) begin
                            debug_byte <= sector_buf[510]; // show what we got instead of 0x55
                            led_err <= 2'b10; state <= ST_ERROR; sub <= 0;
                        end else begin
                            dir_entry <= 0; sub <= 15;
                        end
                    end
                // Scan partition entries (each 16 bytes starting at offset 446)
                15: begin
                        if (dir_entry < 4) begin
                            // Type byte is at offset 4 within each 16-byte entry
                            case (sector_buf[446 + {dir_entry, 4'h4}])
                                8'h0B, 8'h0C: begin
                                    part_lba <= {sector_buf[446 + {dir_entry, 4'hB}],
                                                 sector_buf[446 + {dir_entry, 4'hA}],
                                                 sector_buf[446 + {dir_entry, 4'h9}],
                                                 sector_buf[446 + {dir_entry, 4'h8}]};
                                    led_fat_ok <= 1;
                                    sub <= 0; state <= ST_READ_BPB;
                                end
                                default: dir_entry <= dir_entry + 1;
                            endcase
                        end else begin
                            debug_byte <= sector_buf[450]; // show first partition type
                            led_err <= 2'b10; state <= ST_ERROR; sub <= 0;
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // READ_BPB — read partition boot sector, extract FAT32 layout
        //
        // Key offsets in the BPB (relative to sector start):
        //   13: sectors per cluster (1 byte)
        //   14: reserved sector count (2 bytes LE)
        //   16: number of FATs (1 byte, usually 2)
        //   36: sectors per FAT (4 bytes LE, FAT32)
        //   44: root cluster (4 bytes LE, usually 2)
        // =================================================================
        ST_READ_BPB: begin
            case (sub)
                0:  begin cur_sector_lba <= part_lba; sub <= 1; end
                1:  begin spi_cs_n <= 0; spi_tx_byte <= 8'h51; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[31:24]; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[23:16]; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[15:8];  spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[7:0];   spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin sub <= 9; end
                        else if (wait_cnt < 16'd64) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b10; state <= ST_ERROR; sub <= 0; end
                    end
                9:  begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin
                        if (spi_rx_byte == 8'hFE) begin
                            sector_wr_idx <= 0;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11;
                        end else if (wait_cnt < 16'd8192) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b10; state <= ST_ERROR; sub <= 0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx] <= spi_rx_byte;
                        if (sector_wr_idx == 9'd511) begin
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                        end else begin
                            sector_wr_idx <= sector_wr_idx + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end
                    end
                12: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 13; end
                13: if (spi_done) begin spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 14; end
                // Parse BPB fields
                14: if (spi_done) begin
                        spc              <= sector_buf[13];
                        reserved_sectors <= {sector_buf[15], sector_buf[14]};
                        num_fats         <= sector_buf[16];
                        sectors_per_fat  <= {sector_buf[39], sector_buf[38],
                                             sector_buf[37], sector_buf[36]};
                        root_cluster     <= {sector_buf[47], sector_buf[46],
                                             sector_buf[45], sector_buf[44]};
                        sub <= 15;
                    end
                // Compute derived LBAs
                15: begin
                        fat_lba <= part_lba + {16'd0, reserved_sectors};
                        sub <= 16;
                    end
                16: begin
                        data_lba <= fat_lba + ({24'd0, num_fats} * sectors_per_fat);
                        cur_cluster     <= root_cluster;
                        sec_in_cluster  <= 0;
                        dir_entry       <= 0;
                        sub <= 0;
                        state <= ST_SCAN_DIR;
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // SCAN_DIR — read root directory, find first .WAV file
        //
        // Directory entries are 32 bytes each, 16 per 512-byte sector.
        // 8.3 filename format: 8 bytes name + 3 bytes extension (uppercase).
        // We match extension "WAV".
        //
        // Special first bytes: 0x00 = end of dir, 0xE5 = deleted.
        // Attribute byte (offset 11): 0x0F = LFN, bit3 = volume, bit4 = subdir.
        // =================================================================
        ST_SCAN_DIR: begin
            case (sub)
                // Calculate sector LBA: data_lba + (cluster-2)*spc + sec_in_cluster
                0:  begin
                        cur_sector_lba <= data_lba
                            + ((cur_cluster - 32'd2) * {24'd0, spc})
                            + {24'd0, sec_in_cluster};
                        sub <= 1;
                    end
                // CMD17
                1:  begin spi_cs_n <= 0; spi_tx_byte <= 8'h51; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[31:24]; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[23:16]; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[15:8];  spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[7:0];   spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin sub <= 9; end
                        else if (wait_cnt < 16'd64) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b11; state <= ST_ERROR; sub <= 0; end
                    end
                9:  begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin
                        if (spi_rx_byte == 8'hFE) begin
                            sector_wr_idx <= 0;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11;
                        end else if (wait_cnt < 16'd8192) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b11; state <= ST_ERROR; sub <= 0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx] <= spi_rx_byte;
                        if (sector_wr_idx == 9'd511) begin
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                        end else begin
                            sector_wr_idx <= sector_wr_idx + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end
                    end
                12: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 13; end
                13: if (spi_done) begin spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 14; end
                // Scan directory entries
                14: if (spi_done) begin dir_entry <= 0; sub <= 15; end
                15: begin
                        // Use dir_entry * 32 = {dir_entry, 5'd0} as byte offset
                        // Check first byte for end-of-dir or deleted
                        if (sector_buf[{dir_entry, 5'd0}] == 8'h00) begin
                            // End of directory
                            led_err <= 2'b11; state <= ST_ERROR; sub <= 0;
                        end else if (sector_buf[{dir_entry, 5'd0}] == 8'hE5 ||
                                     sector_buf[{dir_entry, 5'd11}] == 8'h0F ||
                                     sector_buf[{dir_entry, 5'd11}][3] ||
                                     sector_buf[{dir_entry, 5'd11}][4]) begin
                            // Skip: deleted, LFN, volume label, or subdirectory
                            sub <= 16;
                        end else if (sector_buf[{dir_entry, 5'd8}]  == 8'h57 &&  // 'W'
                                     sector_buf[{dir_entry, 5'd9}]  == 8'h41 &&  // 'A'
                                     sector_buf[{dir_entry, 5'd10}] == 8'h56) begin // 'V'
                            // Found .WAV file!
                            file_cluster <= {sector_buf[{dir_entry, 5'd21}],
                                             sector_buf[{dir_entry, 5'd20}],
                                             sector_buf[{dir_entry, 5'd27}],
                                             sector_buf[{dir_entry, 5'd26}]};
                            file_size    <= {sector_buf[{dir_entry, 5'd31}],
                                             sector_buf[{dir_entry, 5'd30}],
                                             sector_buf[{dir_entry, 5'd29}],
                                             sector_buf[{dir_entry, 5'd28}]};
                            led_wav_ok <= 1;
                            // Prepare for playback
                            bytes_read      <= 0;
                            sample_hi_next  <= 0;
                            sample_is_right <= 0;
                            is_stereo       <= 0;
                            cur_cluster     <= 32'd0;   // sentinel: set in ST_PLAY
                            sec_in_cluster  <= 0;
                            sub   <= 0;
                            state <= ST_PLAY;
                        end else begin
                            // Not a WAV — next entry
                            sub <= 16;
                        end
                    end
                // Next entry
                16: begin
                        if (dir_entry < 4'd15) begin
                            dir_entry <= dir_entry + 1;
                            sub <= 15;
                        end else begin
                            // Next sector in cluster
                            if ({1'b0, sec_in_cluster} + 9'd1 < {1'b0, spc}) begin
                                sec_in_cluster <= sec_in_cluster + 1;
                                sub <= 0;
                            end else begin
                                // Would need FAT chain for multi-cluster root dir.
                                // For typical SD cards the root dir fits in one cluster.
                                led_err <= 2'b11; state <= ST_ERROR; sub <= 0;
                            end
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // PLAY — stream audio data from file clusters
        //
        // Reads one sector at a time into sector_buf, then feeds bytes
        // out as 16-bit PCM samples at 44.1 kHz.
        //
        // WAV header (first 44 bytes): parsed for channel count (byte 22),
        // then skipped. Everything after is raw PCM.
        //
        // For stereo files: samples interleave L_lo L_hi R_lo R_hi.
        // For mono: samples are S_lo S_hi, duplicated to both channels.
        //
        // We process bytes at sample_tick rate (44.1 kHz), consuming
        // 2 bytes (mono) or 4 bytes (stereo) per tick.
        // =================================================================
        ST_PLAY: begin
            case (sub)
                // Set up cluster
                0:  begin
                        if (cur_cluster == 32'd0)
                            cur_cluster <= file_cluster;
                        sub <= 1;
                    end
                // Calculate sector LBA
                1:  begin
                        cur_sector_lba <= data_lba
                            + ((cur_cluster - 32'd2) * {24'd0, spc})
                            + {24'd0, sec_in_cluster};
                        // If cur_cluster is still 0 (first call before reg update),
                        // use file_cluster directly
                        if (cur_cluster == 32'd0)
                            cur_sector_lba <= data_lba
                                + ((file_cluster - 32'd2) * {24'd0, spc})
                                + {24'd0, sec_in_cluster};
                        sub <= 2;
                    end
                // CMD17
                2:  begin spi_cs_n <= 0; spi_tx_byte <= 8'h51; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[31:24]; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[23:16]; spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[15:8];  spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[7:0];   spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8; end
                8:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 9; end
                9:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin sub <= 10; end
                        else if (wait_cnt < 16'd64) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                10: begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11; end
                11: if (spi_done) begin
                        if (spi_rx_byte == 8'hFE) begin
                            sector_wr_idx <= 0;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                        end else if (wait_cnt < 16'd8192) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                // Read 512 bytes
                12: if (spi_done) begin
                        sector_buf[sector_wr_idx] <= spi_rx_byte;
                        if (sector_wr_idx == 9'd511) begin
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 13;
                        end else begin
                            sector_wr_idx <= sector_wr_idx + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end
                    end
                // CRC + CS deassert
                13: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 14; end
                14: if (spi_done) begin spi_cs_n <= 1; sub <= 15; end

                // --- Sector loaded, now stream bytes ---
                15: begin
                        led_playing <= 1;
                        play_idx <= 0;
                        sub <= 16;
                    end

                // Process bytes: header skip then audio
                16: begin
                        if (bytes_read >= file_size) begin
                            // End of file
                            led_playing <= 0;
                            state <= ST_DONE; sub <= 0;
                        end else if (play_idx >= 10'd512) begin
                            // Sector exhausted — load next sector
                            sub <= 20;
                        end else if (bytes_read < 32'd44) begin
                            // Still in WAV header — consume bytes without waiting
                            // for sample_tick (header is parsed, not played)
                            if (bytes_read == 32'd22) begin
                                is_stereo <= (sector_buf[play_idx[8:0]] == 8'd2);
                                led_mono  <= (sector_buf[play_idx[8:0]] != 8'd2);
                            end
                            bytes_read <= bytes_read + 1;
                            play_idx   <= play_idx + 1;
                        end else begin
                            // Audio data — wait for sample_tick then consume a full
                            // sample frame (2 bytes for mono, 4 bytes for stereo).
                            // We use a sub-sub-state (sub=17..19) for byte assembly.
                            sub <= 17;
                        end
                    end

                // Wait for sample tick, then consume sample frame
                17: begin
                        if (bytes_read >= file_size) begin
                            led_playing <= 0;
                            state <= ST_DONE; sub <= 0;
                        end else if (play_idx >= 10'd512) begin
                            sub <= 20;
                        end else if (sample_tick) begin
                            // Read left (or only) channel: low byte
                            sample_lo <= sector_buf[play_idx[8:0]];
                            play_idx  <= play_idx + 1;
                            bytes_read <= bytes_read + 1;
                            sub <= 18;
                        end
                    end

                // Left channel high byte (or mono high byte)
                18: begin
                        if (play_idx >= 10'd512) begin
                            // Need to load next sector mid-sample.
                            // For simplicity we just handle the common case where
                            // samples don't span sector boundaries (they do at 512,
                            // but 512/4 = 128 stereo frames fit exactly in one sector).
                            // 512/2 = 256 mono frames also fit exactly.
                            // So this case should rarely occur with aligned WAV data.
                            sub <= 20;
                        end else begin
                            // Assemble 16-bit sample: {high, low}, convert signed to unsigned
                            audio_left <= {sector_buf[play_idx[8:0]][7:0] ^ 8'h80, sample_lo};
                            play_idx   <= play_idx + 1;
                            bytes_read <= bytes_read + 1;
                            if (is_stereo)
                                sub <= 19;  // Read right channel
                            else begin
                                // Mono: duplicate to right channel
                                audio_right <= {sector_buf[play_idx[8:0]][7:0] ^ 8'h80, sample_lo};
                                sub <= 17;  // Wait for next sample tick
                            end
                        end
                    end

                // Right channel (stereo only): low byte then high byte
                19: begin
                        if (play_idx >= 10'd510) begin
                            // Not enough bytes for the right channel in this sector.
                            // With 4-byte frames and 512-byte sectors, 512/4=128 frames
                            // fit exactly, so this shouldn't happen with standard WAV.
                            sub <= 20;
                        end else begin
                            // Read two bytes: right_lo and right_hi
                            audio_right <= {sector_buf[play_idx[8:0] + 9'd1][7:0] ^ 8'h80,
                                            sector_buf[play_idx[8:0]]};
                            play_idx   <= play_idx + 2;
                            bytes_read <= bytes_read + 2;
                            sub <= 17;  // Back to waiting for next sample tick
                        end
                    end

                // Advance to next sector
                20: begin
                        if ({1'b0, sec_in_cluster} + 9'd1 < {1'b0, spc}) begin
                            sec_in_cluster <= sec_in_cluster + 1;
                            sub <= 1;
                        end else begin
                            sec_in_cluster <= 0;
                            state <= ST_NEXT_CLUSTER; sub <= 0;
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // NEXT_CLUSTER — follow FAT chain
        //
        // FAT32 entry for cluster N:
        //   FAT sector = fat_lba + (N >> 7)     (128 entries per sector)
        //   Byte offset = (N & 0x7F) << 2       (4 bytes per entry)
        //
        // Entry value >= 0x0FFFFFF8 = end of chain.
        // =================================================================
        ST_NEXT_CLUSTER: begin
            case (sub)
                0: begin
                    cur_sector_lba <= fat_lba + (cur_cluster >> 7);
                    sub <= 1;
                   end
                // CMD17
                1:  begin spi_cs_n <= 0; spi_tx_byte <= 8'h51; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[31:24]; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[23:16]; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[15:8];  spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= cur_sector_lba[7:0];   spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 7; end
                7:  if (spi_done) begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin sub <= 9; end
                        else if (wait_cnt < 16'd64) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                9:  begin wait_cnt <= 0; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 10; end
                10: if (spi_done) begin
                        if (spi_rx_byte == 8'hFE) begin
                            sector_wr_idx <= 0;
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 11;
                        end else if (wait_cnt < 16'd8192) begin
                            wait_cnt <= wait_cnt + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end else begin led_err <= 2'b01; state <= ST_ERROR; sub <= 0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx] <= spi_rx_byte;
                        if (sector_wr_idx == 9'd511) begin
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 12;
                        end else begin
                            sector_wr_idx <= sector_wr_idx + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end
                    end
                12: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 13; end
                13: if (spi_done) begin spi_cs_n <= 1; sub <= 14; end
                // Extract FAT entry
                14: begin
                        // Byte index = {cur_cluster[6:0], 2'b00}
                        cmd_r7 <= {sector_buf[{cur_cluster[6:0], 2'd3}],
                                   sector_buf[{cur_cluster[6:0], 2'd2}],
                                   sector_buf[{cur_cluster[6:0], 2'd1}],
                                   sector_buf[{cur_cluster[6:0], 2'd0}]};
                        sub <= 15;
                    end
                15: begin
                        // Mask top 4 bits (FAT32 uses 28-bit cluster numbers)
                        if ({4'd0, cmd_r7[27:0]} >= 32'h0FFFFFF8) begin
                            led_playing <= 0;
                            state <= ST_DONE; sub <= 0;
                        end else begin
                            cur_cluster    <= {4'd0, cmd_r7[27:0]};
                            sec_in_cluster <= 0;
                            state <= ST_PLAY; sub <= 1;
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // DONE — playback finished, output silence
        // =================================================================
        ST_DONE: begin
            audio_left  <= 16'h8000;
            audio_right <= 16'h8000;
            led_playing <= 0;
            // FIRE1 — replay from start (SD already initialised, just re-scan)
            if (rise_fire1) begin
                led_fat_ok  <= 0;
                led_wav_ok  <= 0;
                led_mono    <= 0;
                in_error    <= 0;
                sub         <= 0;
                state       <= ST_READ_MBR;
            end
        end

        // =================================================================
        // ERROR — halt, show error on LEDs
        // =================================================================
        ST_ERROR: begin
            spi_cs_n    <= 1;
            audio_left  <= 16'h8000;
            audio_right <= 16'h8000;
            in_error    <= 1;
            // FIRE1 — retry from SD init (full reset)
            if (rise_fire1) begin
                led_sd_ok   <= 0;
                led_fat_ok  <= 0;
                led_wav_ok  <= 0;
                led_mono    <= 0;
                led_err     <= 0;
                in_error    <= 0;
                sub         <= 0;
                powerup_cnt <= 0;
                state       <= ST_POWER_UP;
            end
        end

        default: begin state <= ST_POWER_UP; sub <= 0; end
        endcase
    end

endmodule
