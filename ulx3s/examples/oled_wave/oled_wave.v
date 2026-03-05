// =============================================================================
// SD Card WAV Player + OLED Oscilloscope — ULX3S 85F
// =============================================================================
//
// Plays a .WAV file from FAT32 SD card via I2S to PCM5102A DAC, while
// displaying the live waveform on a 2.42" 128x64 I2C OLED (SSD1309/SSD1306).
// Shows 128 consecutive audio samples per frame as an oscilloscope-style
// display. FIRE1 button replays from start.
//
// PCM5102A DAC on GN0–GN7 (J1), OLED on GP22/GN22 (J2 right side).
//
// =============================================================================

module top (
    input  wire       clk,          // 25 MHz

    // PCM5102A DAC
    output wire       pcm_flt, pcm_dmp, pcm_scl,
    output wire       pcm_bck, pcm_din, pcm_lck,
    output wire       pcm_fmt, pcm_xmt,

    // SD card (SPI mode)
    output wire       sd_clk, sd_cmd, sd_d3,
    input  wire       sd_d0,

    // OLED I2C
    output wire       oled_scl, oled_sda,

    // Controls
    input  wire       btn_fire1,
    output wire [7:0] led
);

    // =========================================================================
    // PCM5102A static pins
    // =========================================================================
    assign pcm_flt = 1'b0;
    assign pcm_dmp = 1'b0;
    assign pcm_scl = 1'b0;
    assign pcm_fmt = 1'b0;
    assign pcm_xmt = 1'b1;

    // =========================================================================
    // I2S output engine — 48,828 Hz
    // =========================================================================
    localparam BCLK_DIV = 8;

    reg [2:0] i2s_clk_div = 0;
    reg       i2s_bclk_reg = 0;
    wire      i2s_bclk_tick = (i2s_clk_div == BCLK_DIV - 1);

    always @(posedge clk) begin
        if (i2s_bclk_tick) begin
            i2s_clk_div <= 0;
            i2s_bclk_reg <= ~i2s_bclk_reg;
        end else
            i2s_clk_div <= i2s_clk_div + 1;
    end

    reg i2s_bclk_prev = 0;
    always @(posedge clk) i2s_bclk_prev <= i2s_bclk_reg;
    wire i2s_bclk_fall = i2s_bclk_prev & ~i2s_bclk_reg;

    assign pcm_bck = i2s_bclk_reg;

    reg [4:0] i2s_bit_cnt = 0;
    reg       i2s_lrck_reg = 0;

    always @(posedge clk) begin
        if (i2s_bclk_fall) begin
            i2s_bit_cnt <= (i2s_bit_cnt == 31) ? 0 : i2s_bit_cnt + 1;
            if (i2s_bit_cnt == 31) i2s_lrck_reg <= 0;
            else if (i2s_bit_cnt == 15) i2s_lrck_reg <= 1;
        end
    end

    assign pcm_lck = i2s_lrck_reg;

    reg signed [15:0] i2s_left  = 0;
    reg signed [15:0] i2s_right = 0;

    // Volume: >>> 5 = 1/32 (matches original sdcard_i2s)
    reg [15:0] i2s_shift = 0;

    always @(posedge clk) begin
        if (i2s_bclk_fall) begin
            if (i2s_bit_cnt == 0)       i2s_shift <= i2s_left >>> 5;
            else if (i2s_bit_cnt == 16) i2s_shift <= i2s_right >>> 5;
            else                        i2s_shift <= {i2s_shift[14:0], 1'b0};
        end
    end

    assign pcm_din = (i2s_bit_cnt == 0 || i2s_bit_cnt == 16) ? 1'b0 : i2s_shift[15];

    // =========================================================================
    // SPI engine — bit-bang SPI master (Mode 0)
    // =========================================================================
    localparam [5:0] SPI_DIV_INIT = 6'd31;
    localparam [5:0] SPI_DIV_FAST = 6'd1;

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
            spi_active <= 1; spi_bit_idx <= 3'd7; spi_phase <= 0;
            spi_cnt <= 0; spi_mosi_out <= spi_tx_byte[7];
        end else if (spi_active) begin
            if (spi_cnt == spi_div) begin
                spi_cnt <= 0;
                if (!spi_phase) begin
                    spi_clk_out <= 1; spi_phase <= 1;
                    spi_rx_byte <= {spi_rx_byte[6:0], spi_miso};
                end else begin
                    spi_clk_out <= 0; spi_phase <= 0;
                    if (spi_bit_idx == 0) begin
                        spi_active <= 0; spi_done <= 1;
                    end else begin
                        spi_bit_idx <= spi_bit_idx - 1;
                        spi_mosi_out <= spi_tx_byte[spi_bit_idx - 1];
                    end
                end
            end else
                spi_cnt <= spi_cnt + 1;
        end
    end

    // =========================================================================
    // Sector buffer, FAT32 state, sample rate
    // =========================================================================
    reg [7:0]  sector_buf [0:511];
    reg [8:0]  sector_wr_idx;

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

    // 44.1 kHz sample tick
    localparam [31:0] SAMPLE_RATE_INC = 32'd7578071;
    reg [31:0] sr_acc = 0;
    reg [32:0] sr_next;
    always @(*) sr_next = {1'b0, sr_acc} + {1'b0, SAMPLE_RATE_INC};
    wire sample_tick = sr_next[32];
    always @(posedge clk) sr_acc <= sr_next[31:0];

    // =========================================================================
    // Button sync + edge detect
    // =========================================================================
    reg [1:0] sync_fire1 = 0;
    reg       prev_fire1 = 0;
    always @(posedge clk) begin
        sync_fire1 <= {sync_fire1[0], btn_fire1};
        prev_fire1 <= sync_fire1[1];
    end
    wire rise_fire1 = sync_fire1[1] & ~prev_fire1;

    // =========================================================================
    // Status LEDs
    // =========================================================================
    reg [24:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1;

    reg led_sd_ok = 0, led_fat_ok = 0, led_wav_ok = 0;
    reg led_playing = 0, led_mono = 0;
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
    // Main SD card / WAV FSM (identical to sdcard_i2s)
    // =========================================================================
    localparam [3:0]
        ST_POWER_UP     = 4'd0,  ST_CMD0        = 4'd1,
        ST_CMD8         = 4'd2,  ST_ACMD41      = 4'd3,
        ST_CMD58        = 4'd4,  ST_SD_READY    = 4'd5,
        ST_READ_MBR     = 4'd6,  ST_READ_BPB    = 4'd7,
        ST_SCAN_DIR     = 4'd8,  ST_PLAY        = 4'd9,
        ST_NEXT_CLUSTER = 4'd10, ST_DONE        = 4'd11,
        ST_ERROR        = 4'd12;

    reg [3:0]  state = ST_POWER_UP;
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

    // Pulse when a new left sample is written (for OLED capture)
    reg        new_left_sample = 0;

    always @(posedge clk) begin
        spi_start <= 0;
        new_left_sample <= 0;

        case (state)

        ST_POWER_UP: begin
            spi_cs_n <= 1;
            if (powerup_cnt < 32'd50000)
                powerup_cnt <= powerup_cnt + 1;
            else if (sub < 8'd20) begin
                if (!sub[0]) begin
                    spi_tx_byte <= 8'hFF; spi_start <= 1; sub <= sub + 1;
                end else if (spi_done) sub <= sub + 1;
            end else begin sub <= 0; state <= ST_CMD0; end
        end

        ST_CMD0: begin
            spi_cs_n <= 0;
            case (sub)
                0:  begin spi_tx_byte <= 8'h40; spi_start <= 1; sub <= 1; end
                1:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 2; end
                2:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 3; end
                3:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 4; end
                4:  if (spi_done) begin spi_tx_byte <= 8'h00; spi_start <= 1; sub <= 5; end
                5:  if (spi_done) begin spi_tx_byte <= 8'h95; spi_start <= 1; sub <= 6; end
                6:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte != 8'hFF) begin
                            cmd_r1<=spi_rx_byte; spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8;
                        end else if (wait_cnt<16'd32) begin
                            wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1;
                        end else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                8:  if (spi_done) begin
                        if (cmd_r1==8'h01) begin sub<=0; state<=ST_CMD8; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                default: sub <= 0;
            endcase
        end

        ST_CMD8: begin
            spi_cs_n <= 0;
            case (sub)
                0:  begin spi_tx_byte<=8'h48; spi_start<=1; sub<=1; end
                1:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=8'h01; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=8'hAA; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=8'h87; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) begin
                            cmd_r1<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8;
                        end else if (wait_cnt<16'd32) begin
                            wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1;
                        end else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                8:  if (spi_done) begin cmd_r7[31:24]<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=9; end
                9:  if (spi_done) begin cmd_r7[23:16]<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=10; end
                10: if (spi_done) begin cmd_r7[15:8]<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                11: if (spi_done) begin
                        cmd_r7[7:0]<=spi_rx_byte; spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=12;
                    end
                12: if (spi_done) begin
                        if (cmd_r1==8'h01 && cmd_r7[11:0]==12'h1AA) begin retry_cnt<=0; sub<=0; state<=ST_ACMD41; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                default: sub <= 0;
            endcase
        end

        ST_ACMD41: begin
            case (sub)
                0:  begin spi_cs_n<=0; spi_tx_byte<=8'h77; spi_start<=1; sub<=1; end
                1:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) begin
                            spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8;
                        end else if (wait_cnt<16'd32) begin
                            wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1;
                        end else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                8:  if (spi_done) begin spi_cs_n<=0; sub<=9; end
                9:  begin spi_tx_byte<=8'h69; spi_start<=1; sub<=10; end
                10: if (spi_done) begin spi_tx_byte<=8'h40; spi_start<=1; sub<=11; end
                11: if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=12; end
                12: if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=13; end
                13: if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=14; end
                14: if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=15; end
                15: if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=16; end
                16: if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) begin
                            cmd_r1<=spi_rx_byte; spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=17;
                        end else if (wait_cnt<16'd32) begin
                            wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1;
                        end else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                17: if (spi_done) begin
                        if (cmd_r1==8'h00) begin sub<=0; state<=ST_CMD58; end
                        else if (retry_cnt<8'd255) begin retry_cnt<=retry_cnt+1; sub<=0; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                default: sub <= 0;
            endcase
        end

        ST_CMD58: begin
            spi_cs_n <= 0;
            case (sub)
                0:  begin spi_tx_byte<=8'h7A; spi_start<=1; sub<=1; end
                1:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=8'h00; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) begin
                            cmd_r1<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8;
                        end else if (wait_cnt<16'd32) begin
                            wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1;
                        end else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                8:  if (spi_done) begin cmd_r7[31:24]<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=9; end
                9:  if (spi_done) begin cmd_r7[23:16]<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=10; end
                10: if (spi_done) begin cmd_r7[15:8]<=spi_rx_byte; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                11: if (spi_done) begin
                        cmd_r7[7:0]<=spi_rx_byte; spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=12;
                    end
                12: if (spi_done) begin led_sd_ok<=1; sub<=0; state<=ST_SD_READY; end
                default: sub <= 0;
            endcase
        end

        ST_SD_READY: begin spi_div<=SPI_DIV_FAST; sub<=0; state<=ST_READ_MBR; end

        ST_READ_MBR: begin
            case (sub)
                0: begin cur_sector_lba<=32'd0; sub<=1; end
                1:  begin spi_cs_n<=0; spi_tx_byte<=8'h51; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[31:24]; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[23:16]; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[15:8]; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[7:0]; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) sub<=9;
                        else if (wait_cnt<16'd64) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                9:  begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=10; end
                10: if (spi_done) begin
                        if (spi_rx_byte==8'hFE) begin sector_wr_idx<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                        else if (wait_cnt<16'd8192) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx]<=spi_rx_byte;
                        if (sector_wr_idx==9'd511) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=12; end
                        else begin sector_wr_idx<=sector_wr_idx+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                    end
                12: if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=13; end
                13: if (spi_done) begin spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=14; end
                14: if (spi_done) begin
                        if (sector_buf[510]!=8'h55||sector_buf[511]!=8'hAA) begin
                            debug_byte<=sector_buf[510]; led_err<=2'b10; state<=ST_ERROR; sub<=0;
                        end else begin dir_entry<=0; sub<=15; end
                    end
                15: begin
                        if (dir_entry<4) begin
                            case (sector_buf[446+{dir_entry,4'h4}])
                                8'h0B, 8'h0C: begin
                                    part_lba<={sector_buf[446+{dir_entry,4'hB}],sector_buf[446+{dir_entry,4'hA}],
                                               sector_buf[446+{dir_entry,4'h9}],sector_buf[446+{dir_entry,4'h8}]};
                                    led_fat_ok<=1; sub<=0; state<=ST_READ_BPB;
                                end
                                default: dir_entry<=dir_entry+1;
                            endcase
                        end else begin debug_byte<=sector_buf[450]; led_err<=2'b10; state<=ST_ERROR; sub<=0; end
                    end
                default: sub<=0;
            endcase
        end

        ST_READ_BPB: begin
            case (sub)
                0:  begin cur_sector_lba<=part_lba; sub<=1; end
                1:  begin spi_cs_n<=0; spi_tx_byte<=8'h51; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[31:24]; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[23:16]; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[15:8]; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[7:0]; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) sub<=9;
                        else if (wait_cnt<16'd64) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b10; state<=ST_ERROR; sub<=0; end
                    end
                9:  begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=10; end
                10: if (spi_done) begin
                        if (spi_rx_byte==8'hFE) begin sector_wr_idx<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                        else if (wait_cnt<16'd8192) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b10; state<=ST_ERROR; sub<=0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx]<=spi_rx_byte;
                        if (sector_wr_idx==9'd511) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=12; end
                        else begin sector_wr_idx<=sector_wr_idx+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                    end
                12: if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=13; end
                13: if (spi_done) begin spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=14; end
                14: if (spi_done) begin
                        spc<=sector_buf[13]; reserved_sectors<={sector_buf[15],sector_buf[14]};
                        num_fats<=sector_buf[16];
                        sectors_per_fat<={sector_buf[39],sector_buf[38],sector_buf[37],sector_buf[36]};
                        root_cluster<={sector_buf[47],sector_buf[46],sector_buf[45],sector_buf[44]};
                        sub<=15;
                    end
                15: begin fat_lba<=part_lba+{16'd0,reserved_sectors}; sub<=16; end
                16: begin
                        data_lba<=fat_lba+({24'd0,num_fats}*sectors_per_fat);
                        cur_cluster<=root_cluster; sec_in_cluster<=0; dir_entry<=0;
                        sub<=0; state<=ST_SCAN_DIR;
                    end
                default: sub<=0;
            endcase
        end

        ST_SCAN_DIR: begin
            case (sub)
                0:  begin
                        cur_sector_lba<=data_lba+((cur_cluster-32'd2)*{24'd0,spc})+{24'd0,sec_in_cluster};
                        sub<=1;
                    end
                1:  begin spi_cs_n<=0; spi_tx_byte<=8'h51; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[31:24]; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[23:16]; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[15:8]; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[7:0]; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) sub<=9;
                        else if (wait_cnt<16'd64) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b11; state<=ST_ERROR; sub<=0; end
                    end
                9:  begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=10; end
                10: if (spi_done) begin
                        if (spi_rx_byte==8'hFE) begin sector_wr_idx<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                        else if (wait_cnt<16'd8192) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b11; state<=ST_ERROR; sub<=0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx]<=spi_rx_byte;
                        if (sector_wr_idx==9'd511) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=12; end
                        else begin sector_wr_idx<=sector_wr_idx+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                    end
                12: if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=13; end
                13: if (spi_done) begin spi_cs_n<=1; spi_tx_byte<=8'hFF; spi_start<=1; sub<=14; end
                14: if (spi_done) begin dir_entry<=0; sub<=15; end
                15: begin
                        if (sector_buf[{dir_entry,5'd0}]==8'h00) begin
                            led_err<=2'b11; state<=ST_ERROR; sub<=0;
                        end else if (sector_buf[{dir_entry,5'd0}]==8'hE5 ||
                                     sector_buf[{dir_entry,5'd11}]==8'h0F ||
                                     sector_buf[{dir_entry,5'd11}][3] ||
                                     sector_buf[{dir_entry,5'd11}][4]) begin
                            sub<=16;
                        end else if (sector_buf[{dir_entry,5'd8}]==8'h57 &&
                                     sector_buf[{dir_entry,5'd9}]==8'h41 &&
                                     sector_buf[{dir_entry,5'd10}]==8'h56) begin
                            file_cluster<={sector_buf[{dir_entry,5'd21}],sector_buf[{dir_entry,5'd20}],
                                           sector_buf[{dir_entry,5'd27}],sector_buf[{dir_entry,5'd26}]};
                            file_size<={sector_buf[{dir_entry,5'd31}],sector_buf[{dir_entry,5'd30}],
                                        sector_buf[{dir_entry,5'd29}],sector_buf[{dir_entry,5'd28}]};
                            led_wav_ok<=1; bytes_read<=0; sample_hi_next<=0;
                            sample_is_right<=0; is_stereo<=0;
                            cur_cluster<=32'd0; sec_in_cluster<=0;
                            sub<=0; state<=ST_PLAY;
                        end else sub<=16;
                    end
                16: begin
                        if (dir_entry<4'd15) begin dir_entry<=dir_entry+1; sub<=15; end
                        else begin
                            if ({1'b0,sec_in_cluster}+9'd1<{1'b0,spc}) begin
                                sec_in_cluster<=sec_in_cluster+1; sub<=0;
                            end else begin led_err<=2'b11; state<=ST_ERROR; sub<=0; end
                        end
                    end
                default: sub<=0;
            endcase
        end

        ST_PLAY: begin
            case (sub)
                0:  begin
                        if (cur_cluster==32'd0) cur_cluster<=file_cluster;
                        sub<=1;
                    end
                1:  begin
                        cur_sector_lba<=data_lba+((cur_cluster-32'd2)*{24'd0,spc})+{24'd0,sec_in_cluster};
                        if (cur_cluster==32'd0)
                            cur_sector_lba<=data_lba+((file_cluster-32'd2)*{24'd0,spc})+{24'd0,sec_in_cluster};
                        sub<=2;
                    end
                2:  begin spi_cs_n<=0; spi_tx_byte<=8'h51; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[31:24]; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[23:16]; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[15:8]; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[7:0]; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=8; end
                8:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=9; end
                9:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) sub<=10;
                        else if (wait_cnt<16'd64) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                10: begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                11: if (spi_done) begin
                        if (spi_rx_byte==8'hFE) begin sector_wr_idx<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=12; end
                        else if (wait_cnt<16'd8192) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                12: if (spi_done) begin
                        sector_buf[sector_wr_idx]<=spi_rx_byte;
                        if (sector_wr_idx==9'd511) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=13; end
                        else begin sector_wr_idx<=sector_wr_idx+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                    end
                13: if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=14; end
                14: if (spi_done) begin spi_cs_n<=1; sub<=15; end
                15: begin led_playing<=1; play_idx<=0; sub<=16; end
                16: begin
                        if (bytes_read>=file_size) begin led_playing<=0; state<=ST_DONE; sub<=0; end
                        else if (play_idx>=10'd512) sub<=20;
                        else if (bytes_read<32'd44) begin
                            if (bytes_read==32'd22) begin
                                is_stereo<=(sector_buf[play_idx[8:0]]==8'd2);
                                led_mono<=(sector_buf[play_idx[8:0]]!=8'd2);
                            end
                            bytes_read<=bytes_read+1; play_idx<=play_idx+1;
                        end else sub<=17;
                    end
                17: begin
                        if (bytes_read>=file_size) begin led_playing<=0; state<=ST_DONE; sub<=0; end
                        else if (play_idx>=10'd512) sub<=20;
                        else if (sample_tick) begin
                            sample_lo<=sector_buf[play_idx[8:0]];
                            play_idx<=play_idx+1; bytes_read<=bytes_read+1; sub<=18;
                        end
                    end
                18: begin
                        if (play_idx>=10'd512) sub<=20;
                        else begin
                            i2s_left<={sector_buf[play_idx[8:0]],sample_lo};
                            new_left_sample <= 1;
                            play_idx<=play_idx+1; bytes_read<=bytes_read+1;
                            if (is_stereo) sub<=19;
                            else begin
                                i2s_right<={sector_buf[play_idx[8:0]],sample_lo};
                                sub<=17;
                            end
                        end
                    end
                19: begin
                        if (play_idx>=10'd510) sub<=20;
                        else begin
                            i2s_right<={sector_buf[play_idx[8:0]+9'd1],sector_buf[play_idx[8:0]]};
                            play_idx<=play_idx+2; bytes_read<=bytes_read+2; sub<=17;
                        end
                    end
                20: begin
                        if ({1'b0,sec_in_cluster}+9'd1<{1'b0,spc}) begin
                            sec_in_cluster<=sec_in_cluster+1; sub<=1;
                        end else begin sec_in_cluster<=0; state<=ST_NEXT_CLUSTER; sub<=0; end
                    end
                default: sub<=0;
            endcase
        end

        ST_NEXT_CLUSTER: begin
            case (sub)
                0:  begin cur_sector_lba<=fat_lba+(cur_cluster>>7); sub<=1; end
                1:  begin spi_cs_n<=0; spi_tx_byte<=8'h51; spi_start<=1; sub<=2; end
                2:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[31:24]; spi_start<=1; sub<=3; end
                3:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[23:16]; spi_start<=1; sub<=4; end
                4:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[15:8]; spi_start<=1; sub<=5; end
                5:  if (spi_done) begin spi_tx_byte<=cur_sector_lba[7:0]; spi_start<=1; sub<=6; end
                6:  if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=7; end
                7:  if (spi_done) begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=8; end
                8:  if (spi_done) begin
                        if (spi_rx_byte!=8'hFF) sub<=9;
                        else if (wait_cnt<16'd64) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                9:  begin wait_cnt<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=10; end
                10: if (spi_done) begin
                        if (spi_rx_byte==8'hFE) begin sector_wr_idx<=0; spi_tx_byte<=8'hFF; spi_start<=1; sub<=11; end
                        else if (wait_cnt<16'd8192) begin wait_cnt<=wait_cnt+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                        else begin led_err<=2'b01; state<=ST_ERROR; sub<=0; end
                    end
                11: if (spi_done) begin
                        sector_buf[sector_wr_idx]<=spi_rx_byte;
                        if (sector_wr_idx==9'd511) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=12; end
                        else begin sector_wr_idx<=sector_wr_idx+1; spi_tx_byte<=8'hFF; spi_start<=1; end
                    end
                12: if (spi_done) begin spi_tx_byte<=8'hFF; spi_start<=1; sub<=13; end
                13: if (spi_done) begin spi_cs_n<=1; sub<=14; end
                14: begin
                        cmd_r7<={sector_buf[{cur_cluster[6:0],2'd3}],sector_buf[{cur_cluster[6:0],2'd2}],
                                 sector_buf[{cur_cluster[6:0],2'd1}],sector_buf[{cur_cluster[6:0],2'd0}]};
                        sub<=15;
                    end
                15: begin
                        if ({4'd0,cmd_r7[27:0]}>=32'h0FFFFFF8) begin led_playing<=0; state<=ST_DONE; sub<=0; end
                        else begin cur_cluster<={4'd0,cmd_r7[27:0]}; sec_in_cluster<=0; state<=ST_PLAY; sub<=1; end
                    end
                default: sub<=0;
            endcase
        end

        ST_DONE: begin
            i2s_left<=16'h0000; i2s_right<=16'h0000; led_playing<=0;
            if (rise_fire1) begin
                led_fat_ok<=0; led_wav_ok<=0; led_mono<=0; in_error<=0;
                sub<=0; state<=ST_READ_MBR;
            end
        end

        ST_ERROR: begin
            spi_cs_n<=1; i2s_left<=16'h0000; i2s_right<=16'h0000; in_error<=1;
            if (rise_fire1) begin
                led_sd_ok<=0; led_fat_ok<=0; led_wav_ok<=0; led_mono<=0;
                led_err<=0; in_error<=0; sub<=0; powerup_cnt<=0; state<=ST_POWER_UP;
            end
        end

        default: begin state<=ST_POWER_UP; sub<=0; end
        endcase
    end

    // =========================================================================
    // OLED waveform capture — continuous 128-sample window
    // =========================================================================
    // Map signed 16-bit audio to 6-bit display Y (0=top, 63=bottom)
    wire [5:0] display_y = {~i2s_left[15], i2s_left[14:10]};

    localparam CAP_CAPTURE = 1'd0, CAP_HOLD = 1'd1;

    reg        cap_state = CAP_CAPTURE;
    reg [6:0]  cap_idx = 0;
    reg [5:0]  cap_buf [0:127];
    reg        cap_done = 0;
    reg        oled_frame_done = 0;

    always @(posedge clk) begin
        if (new_left_sample) begin
            case (cap_state)
                CAP_CAPTURE: begin
                    cap_buf[cap_idx] <= display_y;
                    if (cap_idx == 127) begin
                        cap_state <= CAP_HOLD;
                        cap_done <= 1;
                    end else
                        cap_idx <= cap_idx + 1;
                end
                CAP_HOLD: begin
                    if (oled_frame_done) begin
                        cap_state <= CAP_CAPTURE;
                        cap_idx <= 0;
                        cap_done <= 0;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // OLED pixel computation from capture buffer
    // =========================================================================
    reg [9:0] oled_send_idx = 0;

    wire [2:0] oled_page = oled_send_idx[9:7];
    wire [6:0] oled_col  = oled_send_idx[6:0];
    wire [5:0] buf_y = cap_buf[oled_col];
    wire [2:0] pixel_page = buf_y[5:3];
    wire [2:0] pixel_bit  = buf_y[2:0];
    wire [7:0] pixel_byte = (oled_page == pixel_page) ? (8'd1 << pixel_bit) : 8'd0;

    // =========================================================================
    // I2C engine — ~1.04 MHz
    // =========================================================================
    localparam QDIV = 6;
    reg [2:0] q_cnt = 0;
    wire q_tick = (q_cnt == QDIV - 1);
    always @(posedge clk) q_cnt <= q_tick ? 3'd0 : q_cnt + 3'd1;

    reg scl_r = 1, sda_r = 1;
    assign oled_scl = scl_r;
    assign oled_sda = sda_r;

    reg       i2c_go = 0;
    reg [7:0] i2c_data = 0;
    reg       i2c_do_start = 0, i2c_do_stop = 0;
    reg       i2c_busy = 0;
    reg [3:0] i2c_ph = 0;
    reg [7:0] i2c_sr = 0;
    reg [2:0] i2c_bit = 0;
    reg       i2c_stop_f = 0;

    always @(posedge clk) begin
        if (q_tick) begin
            if (!i2c_busy) begin
                if (i2c_go) begin
                    i2c_busy<=1; i2c_sr<=i2c_data; i2c_bit<=3'd7; i2c_stop_f<=i2c_do_stop;
                    if (i2c_do_start) begin i2c_ph<=4'd1; sda_r<=1; scl_r<=1; end
                    else begin i2c_ph<=4'd5; scl_r<=0; sda_r<=i2c_data[7]; end
                end else begin scl_r<=1; sda_r<=1; end
            end else begin
                case (i2c_ph)
                    4'd1: begin sda_r<=1; scl_r<=1; i2c_ph<=4'd2; end
                    4'd2: begin sda_r<=0;           i2c_ph<=4'd3; end
                    4'd3: begin           scl_r<=0; i2c_ph<=4'd4; end
                    4'd4: begin sda_r<=i2c_sr[7];   i2c_ph<=4'd5; end
                    4'd5: begin                     i2c_ph<=4'd6; end
                    4'd6: begin           scl_r<=1; i2c_ph<=4'd7; end
                    4'd7: begin                     i2c_ph<=4'd8; end
                    4'd8: begin scl_r<=0;
                        if (i2c_bit==0) begin sda_r<=1; i2c_ph<=4'd9; end
                        else begin i2c_bit<=i2c_bit-3'd1; i2c_sr<={i2c_sr[6:0],1'b0}; sda_r<=i2c_sr[6]; i2c_ph<=4'd5; end
                    end
                    4'd9:  begin sda_r<=1;           i2c_ph<=4'd10; end
                    4'd10: begin           scl_r<=1; i2c_ph<=4'd11; end
                    4'd11: begin                     i2c_ph<=4'd12; end
                    4'd12: begin scl_r<=0;
                        if (i2c_stop_f) begin sda_r<=0; i2c_ph<=4'd13; end
                        else begin i2c_busy<=0; i2c_ph<=4'd0; end
                    end
                    4'd13: begin sda_r<=0;           i2c_ph<=4'd14; end
                    4'd14: begin           scl_r<=1; i2c_ph<=4'd15; end
                    4'd15: begin sda_r<=1; i2c_busy<=0; i2c_ph<=4'd0; end
                    default: begin i2c_busy<=0; i2c_ph<=4'd0; end
                endcase
            end
        end
    end

    // =========================================================================
    // SSD1309 init ROM
    // =========================================================================
    localparam INIT_LEN = 31;
    reg [7:0] init_rom [0:30];
    initial begin
        init_rom[ 0]=8'hAE; init_rom[ 1]=8'hD5; init_rom[ 2]=8'h80;
        init_rom[ 3]=8'hA8; init_rom[ 4]=8'h3F; init_rom[ 5]=8'hD3;
        init_rom[ 6]=8'h00; init_rom[ 7]=8'h40; init_rom[ 8]=8'h8D;
        init_rom[ 9]=8'h14; init_rom[10]=8'h20; init_rom[11]=8'h00;
        init_rom[12]=8'hA1; init_rom[13]=8'hC8; init_rom[14]=8'hDA;
        init_rom[15]=8'h12; init_rom[16]=8'h81; init_rom[17]=8'hCF;
        init_rom[18]=8'hD9; init_rom[19]=8'hF1; init_rom[20]=8'hDB;
        init_rom[21]=8'h40; init_rom[22]=8'hA4; init_rom[23]=8'hA6;
        init_rom[24]=8'h21; init_rom[25]=8'h00; init_rom[26]=8'h7F;
        init_rom[27]=8'h22; init_rom[28]=8'h00; init_rom[29]=8'h07;
        init_rom[30]=8'hAF;
    end

    // =========================================================================
    // OLED sequencer
    // =========================================================================
    localparam OH_IDLE=2'd0, OH_SEND=2'd1, OH_WAIT=2'd2;
    localparam OM_RESET=4'd0, OM_INIT_ADDR=4'd1, OM_INIT_CTRL=4'd2,
               OM_INIT_DATA=4'd3, OM_INIT_NEXT=4'd4, OM_WAIT_TRIG=4'd5,
               OM_CUR_ADDR=4'd11, OM_CUR_CTRL=4'd12, OM_CUR_DATA=4'd13, OM_CUR_NEXT=4'd14,
               OM_SEND_ADDR=4'd6, OM_SEND_CTRL=4'd7,
               OM_SEND_DATA=4'd8, OM_SEND_NEXT=4'd9, OM_FRAME_DONE=4'd10;

    // Cursor reset ROM: set column 0-127, page 0-7 before each frame
    reg [2:0] cursor_idx = 0;
    reg [7:0] cursor_cmd;
    always @(*) begin
        case (cursor_idx)
            3'd0: cursor_cmd = 8'h21;  // set column address
            3'd1: cursor_cmd = 8'h00;  // start = 0
            3'd2: cursor_cmd = 8'h7F;  // end = 127
            3'd3: cursor_cmd = 8'h22;  // set page address
            3'd4: cursor_cmd = 8'h00;  // start = 0
            3'd5: cursor_cmd = 8'h07;  // end = 7
            default: cursor_cmd = 8'h00;
        endcase
    end

    reg [1:0]  oh_state = OH_IDLE;
    reg [3:0]  om_state = OM_RESET;
    reg [3:0]  om_next  = OM_RESET;
    reg [21:0] oled_delay = 0;
    reg [4:0]  oled_init_idx = 0;

    always @(posedge clk) begin
        case (oh_state)
            OH_IDLE: begin
                case (om_state)
                    OM_RESET: begin
                        oled_delay<=oled_delay+1;
                        if (oled_delay[21]) om_state<=OM_INIT_ADDR;
                    end
                    OM_INIT_ADDR: begin
                        i2c_data<=8'h78; i2c_do_start<=1; i2c_do_stop<=0;
                        om_next<=OM_INIT_CTRL; oh_state<=OH_SEND;
                    end
                    OM_INIT_CTRL: begin
                        i2c_data<=8'h00; i2c_do_start<=0; i2c_do_stop<=0;
                        oled_init_idx<=0; om_next<=OM_INIT_DATA; oh_state<=OH_SEND;
                    end
                    OM_INIT_DATA: begin
                        i2c_data<=init_rom[oled_init_idx]; i2c_do_start<=0;
                        i2c_do_stop<=(oled_init_idx==INIT_LEN-1);
                        om_next<=OM_INIT_NEXT; oh_state<=OH_SEND;
                    end
                    OM_INIT_NEXT: begin
                        if (oled_init_idx==INIT_LEN-1) om_state<=OM_WAIT_TRIG;
                        else begin oled_init_idx<=oled_init_idx+1; om_state<=OM_INIT_DATA; end
                    end
                    OM_WAIT_TRIG: begin
                        // Clear frame_done only after capture FSM acknowledges (cap_done drops)
                        if (!cap_done) oled_frame_done <= 0;
                        if (cap_done && !oled_frame_done) om_state<=OM_CUR_ADDR;
                    end
                    // Cursor reset: send column/page address commands before each frame
                    OM_CUR_ADDR: begin
                        i2c_data<=8'h78; i2c_do_start<=1; i2c_do_stop<=0;
                        om_next<=OM_CUR_CTRL; oh_state<=OH_SEND;
                    end
                    OM_CUR_CTRL: begin
                        i2c_data<=8'h00; i2c_do_start<=0; i2c_do_stop<=0;
                        cursor_idx<=0; om_next<=OM_CUR_DATA; oh_state<=OH_SEND;
                    end
                    OM_CUR_DATA: begin
                        i2c_data<=cursor_cmd; i2c_do_start<=0;
                        i2c_do_stop<=(cursor_idx==3'd5);
                        om_next<=OM_CUR_NEXT; oh_state<=OH_SEND;
                    end
                    OM_CUR_NEXT: begin
                        if (cursor_idx==3'd5) om_state<=OM_SEND_ADDR;
                        else begin cursor_idx<=cursor_idx+1; om_state<=OM_CUR_DATA; end
                    end
                    OM_SEND_ADDR: begin
                        i2c_data<=8'h78; i2c_do_start<=1; i2c_do_stop<=0;
                        om_next<=OM_SEND_CTRL; oh_state<=OH_SEND;
                    end
                    OM_SEND_CTRL: begin
                        i2c_data<=8'h40; i2c_do_start<=0; i2c_do_stop<=0;
                        oled_send_idx<=0; om_next<=OM_SEND_DATA; oh_state<=OH_SEND;
                    end
                    OM_SEND_DATA: begin
                        i2c_data<=pixel_byte; i2c_do_start<=0;
                        i2c_do_stop<=(oled_send_idx==10'd1023);
                        om_next<=OM_SEND_NEXT; oh_state<=OH_SEND;
                    end
                    OM_SEND_NEXT: begin
                        if (oled_send_idx==10'd1023) om_state<=OM_FRAME_DONE;
                        else begin oled_send_idx<=oled_send_idx+10'd1; om_state<=OM_SEND_DATA; end
                    end
                    OM_FRAME_DONE: begin
                        oled_frame_done<=1; om_state<=OM_WAIT_TRIG;
                    end
                endcase
            end
            OH_SEND: begin
                i2c_go<=1;
                if (i2c_busy) begin i2c_go<=0; oh_state<=OH_WAIT; end
            end
            OH_WAIT: begin
                if (!i2c_busy) begin oh_state<=OH_IDLE; om_state<=om_next; end
            end
        endcase
    end

endmodule
