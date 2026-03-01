// =============================================================================
// SD Card WAV Player with I2S Output — ULX3S 85F + PCM5102A DAC
// =============================================================================
//
// Reads a 44.1 kHz, 16-bit WAV file from a FAT32-formatted SD card and plays
// it through a PCM5102A DAC breakout connected to the J1 header (GN0–GN7).
//
// Architecture:
//   1. SPI SD CONTROLLER — CMD0 → CMD8 → ACMD41 → CMD58 init, then CMD17 reads
//   2. FAT32 READER — MBR → BPB → root dir scan for first .WAV file
//   3. WAV PARSER — skips 44-byte header, streams raw PCM (mono or stereo)
//   4. I2S OUTPUT — drives PCM5102A at ~48.8 kHz (25 MHz / 16 / 32)
//      The SD card feeds samples at 44.1 kHz; the I2S engine just reads the
//      current sample register, so some samples repeat (~10% upsample).
//      The PCM5102A's reconstruction filter smooths this out.
//   5. FIRE1 button replays from start; in error state it retries from SD init
//
// PCM5102A wiring (GN0–GN7 on J1 header):
//   GN0 (C11) → FLT  = LOW   (normal latency filter)
//   GN1 (A11) → DMP  = LOW   (de-emphasis off)
//   GN2 (B10) → SCL  = LOW   (internal system clock)
//   GN3 (C10) → BCK  = BCLK  (I2S bit clock, 1.5625 MHz)
//   GN4 (A8)  → DIN  = DATA  (I2S serial data, MSB first)
//   GN5 (B8)  → LCK  = LRCK  (I2S word select)
//   GN6 (C7)  → FMT  = LOW   (I2S format)
//   GN7 (B6)  → XMT  = HIGH  (unmute)
//
// Status LEDs:
//   LED[0] = heartbeat        LED[4] = playing audio
//   LED[1] = SD card init OK  LED[5] = mono indicator
//   LED[2] = FAT32 found      LED[7:6] = error code
//   LED[3] = WAV file found
//
// =============================================================================

module top (
    input  wire       clk,          // 25 MHz oscillator

    // PCM5102A on GN0–GN7
    output wire       pcm_flt,      // GN0 — filter select
    output wire       pcm_dmp,      // GN1 — de-emphasis
    output wire       pcm_scl,      // GN2 — system clock
    output wire       pcm_bck,      // GN3 — I2S bit clock
    output wire       pcm_din,      // GN4 — I2S serial data
    output wire       pcm_lck,      // GN5 — I2S word select
    output wire       pcm_fmt,      // GN6 — format select
    output wire       pcm_xmt,      // GN7 — mute control

    // SD card (SPI mode)
    output wire       sd_clk,
    output wire       sd_cmd,
    input  wire       sd_d0,
    output wire       sd_d3,

    // Status
    output wire [7:0] led,
    input  wire       btn_fire1
);

    // =========================================================================
    // PCM5102A static control pins
    // =========================================================================
    assign pcm_flt = 1'b0;
    assign pcm_dmp = 1'b0;
    assign pcm_scl = 1'b0;
    assign pcm_fmt = 1'b0;
    assign pcm_xmt = 1'b1;

    // =========================================================================
    // I2S output engine — runs independently at 48,828 Hz
    // =========================================================================
    //
    // BCLK = 25 MHz / 16 = 1.5625 MHz, 32 bits per frame → 48,828 Hz
    // Reads from i2s_left / i2s_right sample registers (signed 16-bit).
    //
    localparam BCLK_DIV = 8;  // toggle every 8 clocks

    reg [2:0] i2s_clk_div = 0;
    reg       i2s_bclk_reg = 0;
    wire      i2s_bclk_tick = (i2s_clk_div == BCLK_DIV - 1);

    always @(posedge clk) begin
        if (i2s_bclk_tick) begin
            i2s_clk_div <= 0;
            i2s_bclk_reg <= ~i2s_bclk_reg;
        end else begin
            i2s_clk_div <= i2s_clk_div + 1;
        end
    end

    reg i2s_bclk_prev = 0;
    always @(posedge clk) i2s_bclk_prev <= i2s_bclk_reg;
    wire i2s_bclk_fall = i2s_bclk_prev & ~i2s_bclk_reg;

    assign pcm_bck = i2s_bclk_reg;

    // Bit counter: 0–31 per stereo frame
    reg [4:0] i2s_bit_cnt = 0;
    reg       i2s_lrck_reg = 0;

    always @(posedge clk) begin
        if (i2s_bclk_fall) begin
            if (i2s_bit_cnt == 31)
                i2s_bit_cnt <= 0;
            else
                i2s_bit_cnt <= i2s_bit_cnt + 1;
            if (i2s_bit_cnt == 31)
                i2s_lrck_reg <= 0;
            else if (i2s_bit_cnt == 15)
                i2s_lrck_reg <= 1;
        end
    end

    assign pcm_lck = i2s_lrck_reg;

    // Sample registers — written by the SD card state machine
    reg signed [15:0] i2s_left  = 0;
    reg signed [15:0] i2s_right = 0;

    // Shift register (1/32 volume: arithmetic right shift by 5)
    reg [15:0] i2s_shift = 0;

    always @(posedge clk) begin
        if (i2s_bclk_fall) begin
            if (i2s_bit_cnt == 0)
                i2s_shift <= i2s_left >>> 5;
            else if (i2s_bit_cnt == 16)
                i2s_shift <= i2s_right >>> 5;
            else
                i2s_shift <= {i2s_shift[14:0], 1'b0};
        end
    end

    assign pcm_din = (i2s_bit_cnt == 0 || i2s_bit_cnt == 16) ? 1'b0 : i2s_shift[15];

    // =========================================================================
    // SPI clock divider
    // =========================================================================
    localparam [5:0] SPI_DIV_INIT = 6'd31;  // ~390 kHz during init
    localparam [5:0] SPI_DIV_FAST = 6'd1;   // ~6.25 MHz after init

    // =========================================================================
    // Sample rate timing — 44.1 kHz from 25 MHz (for SD card byte consumption)
    // =========================================================================
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
    // SPI engine — bit-bang SPI master (Mode 0)
    // =========================================================================
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
    reg        spi_phase = 0;

    assign sd_clk = spi_clk_out;
    assign sd_cmd = spi_mosi_out;
    assign sd_d3  = spi_cs_n;
    wire spi_miso = sd_d0;

    always @(posedge clk) begin
        spi_done <= 0;
        if (spi_start && !spi_active) begin
            spi_active  <= 1;
            spi_bit_idx <= 3'd7;
            spi_phase   <= 0;
            spi_cnt     <= 0;
            spi_mosi_out <= spi_tx_byte[7];
        end else if (spi_active) begin
            if (spi_cnt == spi_div) begin
                spi_cnt <= 0;
                if (!spi_phase) begin
                    spi_clk_out <= 1;
                    spi_phase   <= 1;
                    spi_rx_byte <= {spi_rx_byte[6:0], spi_miso};
                end else begin
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
    // Sector buffer — 512 bytes
    // =========================================================================
    reg [7:0]  sector_buf [0:511];
    reg [8:0]  sector_wr_idx;

    // =========================================================================
    // FAT32 filesystem state
    // =========================================================================
    reg [31:0] part_lba;
    reg [7:0]  spc;
    reg [15:0] reserved_sectors;
    reg [7:0]  num_fats;
    reg [31:0] sectors_per_fat;
    reg [31:0] root_cluster;
    reg [31:0] fat_lba;
    reg [31:0] data_lba;
    reg [31:0] file_cluster;
    reg [31:0] file_size;
    reg [31:0] bytes_read;
    reg        is_stereo;
    reg [31:0] cur_cluster;
    reg [7:0]  sec_in_cluster;
    reg [31:0] cur_sector_lba;

    // =========================================================================
    // Sample rate accumulator (44.1 kHz tick for byte consumption)
    // =========================================================================
    reg [31:0] sr_acc = 0;
    wire       sample_tick;
    reg [32:0] sr_next;

    always @(*) begin
        sr_next = {1'b0, sr_acc} + {1'b0, SAMPLE_RATE_INC};
    end

    assign sample_tick = sr_next[32];

    always @(posedge clk) begin
        sr_acc <= sr_next[31:0];
    end

    // =========================================================================
    // Status LEDs
    // =========================================================================
    reg [24:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1;

    // Button synchroniser + edge detector
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
    reg [7:0] debug_byte = 0;
    reg       in_error = 0;

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
    reg [7:0]  sub = 0;
    reg [15:0] wait_cnt = 0;
    reg [7:0]  retry_cnt = 0;
    reg [31:0] powerup_cnt = 0;
    reg [7:0]  cmd_r1;
    reg [31:0] cmd_r7;

    reg [3:0]  dir_entry;
    reg [9:0]  play_idx;
    reg [7:0]  sample_lo;
    reg        sample_hi_next;
    reg        sample_is_right;

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
        // CMD0 — GO_IDLE_STATE
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
        // CMD8 — SEND_IF_COND
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
        // =================================================================
        ST_ACMD41: begin
            case (sub)
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
        // CMD58 — READ_OCR
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
        // SD_READY — switch to fast clock
        // =================================================================
        ST_SD_READY: begin
            spi_div <= SPI_DIV_FAST;
            sub     <= 0;
            state   <= ST_READ_MBR;
        end

        // =================================================================
        // READ_MBR — read sector 0, find first FAT32 partition
        // =================================================================
        ST_READ_MBR: begin
            case (sub)
                0: begin cur_sector_lba <= 32'd0; sub <= 1; end
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
                13: if (spi_done) begin spi_cs_n <= 1; spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 14; end
                14: if (spi_done) begin
                        if (sector_buf[510] != 8'h55 || sector_buf[511] != 8'hAA) begin
                            debug_byte <= sector_buf[510];
                            led_err <= 2'b10; state <= ST_ERROR; sub <= 0;
                        end else begin
                            dir_entry <= 0; sub <= 15;
                        end
                    end
                15: begin
                        if (dir_entry < 4) begin
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
                            debug_byte <= sector_buf[450];
                            led_err <= 2'b10; state <= ST_ERROR; sub <= 0;
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // READ_BPB — read partition boot sector
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
        // SCAN_DIR — find first .WAV file in root directory
        // =================================================================
        ST_SCAN_DIR: begin
            case (sub)
                0:  begin
                        cur_sector_lba <= data_lba
                            + ((cur_cluster - 32'd2) * {24'd0, spc})
                            + {24'd0, sec_in_cluster};
                        sub <= 1;
                    end
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
                14: if (spi_done) begin dir_entry <= 0; sub <= 15; end
                15: begin
                        if (sector_buf[{dir_entry, 5'd0}] == 8'h00) begin
                            led_err <= 2'b11; state <= ST_ERROR; sub <= 0;
                        end else if (sector_buf[{dir_entry, 5'd0}] == 8'hE5 ||
                                     sector_buf[{dir_entry, 5'd11}] == 8'h0F ||
                                     sector_buf[{dir_entry, 5'd11}][3] ||
                                     sector_buf[{dir_entry, 5'd11}][4]) begin
                            sub <= 16;
                        end else if (sector_buf[{dir_entry, 5'd8}]  == 8'h57 &&  // 'W'
                                     sector_buf[{dir_entry, 5'd9}]  == 8'h41 &&  // 'A'
                                     sector_buf[{dir_entry, 5'd10}] == 8'h56) begin // 'V'
                            file_cluster <= {sector_buf[{dir_entry, 5'd21}],
                                             sector_buf[{dir_entry, 5'd20}],
                                             sector_buf[{dir_entry, 5'd27}],
                                             sector_buf[{dir_entry, 5'd26}]};
                            file_size    <= {sector_buf[{dir_entry, 5'd31}],
                                             sector_buf[{dir_entry, 5'd30}],
                                             sector_buf[{dir_entry, 5'd29}],
                                             sector_buf[{dir_entry, 5'd28}]};
                            led_wav_ok <= 1;
                            bytes_read      <= 0;
                            sample_hi_next  <= 0;
                            sample_is_right <= 0;
                            is_stereo       <= 0;
                            cur_cluster     <= 32'd0;
                            sec_in_cluster  <= 0;
                            sub   <= 0;
                            state <= ST_PLAY;
                        end else begin
                            sub <= 16;
                        end
                    end
                16: begin
                        if (dir_entry < 4'd15) begin
                            dir_entry <= dir_entry + 1;
                            sub <= 15;
                        end else begin
                            if ({1'b0, sec_in_cluster} + 9'd1 < {1'b0, spc}) begin
                                sec_in_cluster <= sec_in_cluster + 1;
                                sub <= 0;
                            end else begin
                                led_err <= 2'b11; state <= ST_ERROR; sub <= 0;
                            end
                        end
                    end
                default: sub <= 0;
            endcase
        end

        // =================================================================
        // PLAY — stream audio data from file clusters via I2S
        //
        // Samples are consumed at 44.1 kHz (sample_tick) and written into
        // i2s_left / i2s_right as signed 16-bit. The I2S engine reads them
        // asynchronously at 48.8 kHz.
        // =================================================================
        ST_PLAY: begin
            case (sub)
                0:  begin
                        if (cur_cluster == 32'd0)
                            cur_cluster <= file_cluster;
                        sub <= 1;
                    end
                1:  begin
                        cur_sector_lba <= data_lba
                            + ((cur_cluster - 32'd2) * {24'd0, spc})
                            + {24'd0, sec_in_cluster};
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
                12: if (spi_done) begin
                        sector_buf[sector_wr_idx] <= spi_rx_byte;
                        if (sector_wr_idx == 9'd511) begin
                            spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 13;
                        end else begin
                            sector_wr_idx <= sector_wr_idx + 1;
                            spi_tx_byte <= 8'hFF; spi_start <= 1;
                        end
                    end
                13: if (spi_done) begin spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= 14; end
                14: if (spi_done) begin spi_cs_n <= 1; sub <= 15; end

                15: begin
                        led_playing <= 1;
                        play_idx <= 0;
                        sub <= 16;
                    end

                // Process bytes: header skip then audio
                16: begin
                        if (bytes_read >= file_size) begin
                            led_playing <= 0;
                            state <= ST_DONE; sub <= 0;
                        end else if (play_idx >= 10'd512) begin
                            sub <= 20;
                        end else if (bytes_read < 32'd44) begin
                            if (bytes_read == 32'd22) begin
                                is_stereo <= (sector_buf[play_idx[8:0]] == 8'd2);
                                led_mono  <= (sector_buf[play_idx[8:0]] != 8'd2);
                            end
                            bytes_read <= bytes_read + 1;
                            play_idx   <= play_idx + 1;
                        end else begin
                            sub <= 17;
                        end
                    end

                // Wait for sample tick, read left low byte
                17: begin
                        if (bytes_read >= file_size) begin
                            led_playing <= 0;
                            state <= ST_DONE; sub <= 0;
                        end else if (play_idx >= 10'd512) begin
                            sub <= 20;
                        end else if (sample_tick) begin
                            sample_lo <= sector_buf[play_idx[8:0]];
                            play_idx  <= play_idx + 1;
                            bytes_read <= bytes_read + 1;
                            sub <= 18;
                        end
                    end

                // Left high byte — assemble signed 16-bit sample
                18: begin
                        if (play_idx >= 10'd512) begin
                            sub <= 20;
                        end else begin
                            // WAV stores signed 16-bit little-endian — use directly
                            i2s_left <= {sector_buf[play_idx[8:0]], sample_lo};
                            play_idx   <= play_idx + 1;
                            bytes_read <= bytes_read + 1;
                            if (is_stereo)
                                sub <= 19;
                            else begin
                                // Mono: duplicate to right
                                i2s_right <= {sector_buf[play_idx[8:0]], sample_lo};
                                sub <= 17;
                            end
                        end
                    end

                // Right channel (stereo): low + high bytes
                19: begin
                        if (play_idx >= 10'd510) begin
                            sub <= 20;
                        end else begin
                            i2s_right <= {sector_buf[play_idx[8:0] + 9'd1],
                                          sector_buf[play_idx[8:0]]};
                            play_idx   <= play_idx + 2;
                            bytes_read <= bytes_read + 2;
                            sub <= 17;
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
        // =================================================================
        ST_NEXT_CLUSTER: begin
            case (sub)
                0: begin
                    cur_sector_lba <= fat_lba + (cur_cluster >> 7);
                    sub <= 1;
                   end
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
                14: begin
                        cmd_r7 <= {sector_buf[{cur_cluster[6:0], 2'd3}],
                                   sector_buf[{cur_cluster[6:0], 2'd2}],
                                   sector_buf[{cur_cluster[6:0], 2'd1}],
                                   sector_buf[{cur_cluster[6:0], 2'd0}]};
                        sub <= 15;
                    end
                15: begin
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
        // DONE — silence, wait for FIRE1 to replay
        // =================================================================
        ST_DONE: begin
            i2s_left  <= 16'h0000;
            i2s_right <= 16'h0000;
            led_playing <= 0;
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
            i2s_left    <= 16'h0000;
            i2s_right   <= 16'h0000;
            in_error    <= 1;
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
