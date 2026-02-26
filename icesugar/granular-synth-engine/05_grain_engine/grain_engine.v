// =============================================================================
// 8-Grain Engine — SPRAM sample buffer + granular playback
// =============================================================================
//
// What this does:
//   Records audio from the PCM1808 ADC into the iCE40UP5K's SPRAM (128 KB),
//   then plays it back as up to 8 simultaneous grains, each with independent
//   position, size, pitch, and envelope. Output goes to the PCM5102A DAC
//   via I2S. The ESP32-S3 controls everything over SPI.
//
// SPRAM usage:
//   The iCE40UP5K has 4 SPRAM blocks of 256 Kbit each = 128 KB total.
//   We use 2 blocks as a single 32K × 16-bit sample buffer.
//   At 46,875 Hz sample rate, that's ~0.7 seconds of mono audio.
//   (We could use all 4 blocks for ~1.4 sec, but 2 is enough to start.)
//
// Grain engine pipeline (per sample period):
//   Each grain needs: read sample from SPRAM → apply envelope → accumulate
//   With ~1000 clock cycles per sample and 8 grains, we have ~125 cycles
//   per grain — plenty of time.
//
//   Pipeline stages per grain:
//     1. Address calculation: base_pos + grain_phase → SPRAM address
//     2. SPRAM read (1 cycle latency)
//     3. Envelope multiply (using DSP block)
//     4. Accumulate into mix bus
//
// SPI register map (from ESP32-S3):
//   0x00: Control — bit 0: record enable, bit 1: playback enable
//   0x01: Record length MSB (in samples, max 32768)
//   0x02: Record length LSB
//
//   Grain N (base = 0x10 + N*0x08, N = 0..7):
//     +0x00: Position MSB (start offset in sample buffer)
//     +0x01: Position LSB
//     +0x02: Size MSB (grain length in samples)
//     +0x03: Size LSB
//     +0x04: Pitch MSB (phase increment, 8.8 fixed point)
//     +0x05: Pitch LSB (1.0 = original pitch = 0x0100)
//     +0x06: Level (0-255, envelope peak amplitude)
//     +0x07: Active (0=off, 1=on)
//
//   0x70: Status (read-only) — returns 0xGR ("GR" for grain)
//
// Envelope:
//   Simple triangular envelope per grain — ramps up for first half of the
//   grain size, ramps down for the second half. The peak amplitude is
//   scaled by the Level register.
//
// Wiring:
//   SPI on PMOD 2, I2S DAC on PMOD 3 pins 1-3, ADC on PMOD 3 pins 9-12
//   (Both DAC and ADC share the same PMOD header using different pin rows)
//
// =============================================================================

module top (
    input  clk,           // 12 MHz
    // SPI (PMOD 2)
    input  spi_sck,
    input  spi_mosi,
    output spi_miso,
    input  spi_cs_n,
    // I2S shared (PMOD 3, top row)
    output i2s_bclk,
    output i2s_lrck,
    // PCM5102A DAC (PMOD 3)
    output dac_data,
    // PCM1808 ADC (PMOD 3, bottom row)
    input  adc_data,
    output adc_scki,
    // LEDs
    output led_g,
    output led_r,
    output led_b
);

    // =========================================================================
    // PCM1808 system clock
    // =========================================================================
    assign adc_scki = clk;  // 12 MHz → PCM1808 SCKI (256fs for 46875 Hz)

    // =========================================================================
    // I2S master clocking
    // =========================================================================
    localparam BCLK_DIV = 4;
    reg [1:0] bclk_div = 0;
    reg bclk_reg = 0;
    wire bclk_tick = (bclk_div == BCLK_DIV - 1);

    always @(posedge clk) begin
        if (bclk_tick) begin
            bclk_div <= 0;
            bclk_reg <= ~bclk_reg;
        end else
            bclk_div <= bclk_div + 1;
    end

    reg bclk_p = 0;
    always @(posedge clk) bclk_p <= bclk_reg;
    wire bclk_fall = bclk_p & ~bclk_reg;
    wire bclk_rise = ~bclk_p & bclk_reg;

    assign i2s_bclk = bclk_reg;

    reg [4:0] bit_cnt = 0;
    reg lrck_reg = 0;
    always @(posedge clk) begin
        if (bclk_fall) begin
            bit_cnt <= (bit_cnt == 31) ? 5'd0 : bit_cnt + 1;
            if (bit_cnt == 31) lrck_reg <= 0;
            else if (bit_cnt == 15) lrck_reg <= 1;
        end
    end
    assign i2s_lrck = lrck_reg;

    // New sample period flag — triggers once per sample (start of left channel)
    wire new_sample = bclk_fall && (bit_cnt == 0);

    // =========================================================================
    // ADC input capture
    // =========================================================================
    reg [15:0] adc_shift = 0;
    reg [15:0] adc_sample = 0;

    always @(posedge clk) begin
        if (bclk_rise) begin
            if (bit_cnt >= 1 && bit_cnt <= 16)
                adc_shift <= {adc_shift[14:0], adc_data};
            if (bit_cnt == 16)
                adc_sample <= {adc_shift[14:0], adc_data};
        end
    end

    // =========================================================================
    // SPI slave (same pattern as modules 03/04)
    // =========================================================================
    reg [1:0] sck_sync = 0, mosi_sync = 0, cs_sync = 2'b11;
    always @(posedge clk) begin
        sck_sync  <= {sck_sync[0],  spi_sck};
        mosi_sync <= {mosi_sync[0], spi_mosi};
        cs_sync   <= {cs_sync[0],   spi_cs_n};
    end
    wire sck_s = sck_sync[1], mosi_s = mosi_sync[1], cs_s = cs_sync[1];

    reg sck_prev = 0;
    always @(posedge clk) sck_prev <= sck_s;
    wire sck_rise_spi = ~sck_prev & sck_s;
    wire sck_fall_spi = sck_prev & ~sck_s;

    reg [3:0] spi_bcnt = 0;
    reg [7:0] spi_addr = 0, spi_rxd = 0;
    reg spi_addr_done = 0, spi_wr = 0;

    always @(posedge clk) begin
        spi_wr <= 0;
        if (cs_s) begin
            spi_bcnt <= 0;
            spi_addr_done <= 0;
        end else if (sck_rise_spi) begin
            if (!spi_addr_done) begin
                spi_addr <= {spi_addr[6:0], mosi_s};
                if (spi_bcnt == 7) begin spi_addr_done <= 1; spi_bcnt <= 0; end
                else spi_bcnt <= spi_bcnt + 1;
            end else begin
                spi_rxd <= {spi_rxd[6:0], mosi_s};
                if (spi_bcnt == 7) begin spi_wr <= 1; spi_bcnt <= 0; end
                else spi_bcnt <= spi_bcnt + 1;
            end
        end
    end

    // MISO (simplified — just status register for now)
    reg [7:0] miso_shift = 0;
    always @(posedge clk) begin
        if (cs_s)
            miso_shift <= 0;
        else if (spi_addr_done && spi_bcnt == 0 && sck_fall_spi)
            miso_shift <= (spi_addr[6:0] == 7'h70) ? 8'hBE : 8'h00;
        else if (sck_fall_spi && spi_addr_done)
            miso_shift <= {miso_shift[6:0], 1'b0};
    end
    assign spi_miso = cs_s ? 1'bz : miso_shift[7];

    // =========================================================================
    // Control registers
    // =========================================================================
    reg rec_enable = 0;
    reg play_enable = 0;
    reg [15:0] rec_length = 16'd32768;  // default: full buffer

    // Per-grain parameters (8 grains)
    reg [14:0] grain_pos   [0:7];  // start position in buffer (15 bits = 0..32767)
    reg [14:0] grain_size  [0:7];  // grain length in samples
    reg [15:0] grain_pitch [0:7];  // phase increment (8.8 fixed point, 0x0100 = 1.0)
    reg [7:0]  grain_level [0:7];  // amplitude 0-255
    reg        grain_active[0:7];  // on/off

    integer i;
    initial begin
        for (i = 0; i < 8; i = i + 1) begin
            grain_pos[i]    = 0;
            grain_size[i]   = 15'd4096;
            grain_pitch[i]  = 16'h0100;  // 1.0x
            grain_level[i]  = 0;
            grain_active[i] = 0;
        end
    end

    // SPI register write decoder
    wire [2:0] grain_idx = spi_addr[5:3];  // which grain (0-7)
    wire [2:0] grain_reg = spi_addr[2:0];  // which register within grain

    always @(posedge clk) begin
        if (spi_wr && !spi_addr[7]) begin
            case (spi_addr[6:0])
                7'h00: {rec_enable, play_enable} <= {spi_rxd[0], spi_rxd[1]};
                7'h01: rec_length[15:8] <= spi_rxd;
                7'h02: rec_length[7:0]  <= spi_rxd;
                default: begin
                    if (spi_addr[6:0] >= 7'h10 && spi_addr[6:0] < 7'h50) begin
                        case (grain_reg)
                            3'd0: grain_pos[grain_idx][14:8]   <= spi_rxd[6:0];
                            3'd1: grain_pos[grain_idx][7:0]    <= spi_rxd;
                            3'd2: grain_size[grain_idx][14:8]  <= spi_rxd[6:0];
                            3'd3: grain_size[grain_idx][7:0]   <= spi_rxd;
                            3'd4: grain_pitch[grain_idx][15:8] <= spi_rxd;
                            3'd5: grain_pitch[grain_idx][7:0]  <= spi_rxd;
                            3'd6: grain_level[grain_idx]       <= spi_rxd;
                            3'd7: grain_active[grain_idx]      <= spi_rxd[0];
                        endcase
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // SPRAM — 2 blocks used as 32K × 16-bit sample buffer
    // =========================================================================
    //
    // iCE40UP5K SPRAM: SB_SPRAM256KA primitive
    // Each block is 16K × 16-bit. We use 2 blocks for 32K × 16-bit.
    // Block select via address bit 14.
    //
    reg [14:0] spram_addr;
    reg [15:0] spram_wdata;
    reg spram_we;

    wire [15:0] spram0_rdata, spram1_rdata;

    SB_SPRAM256KA spram0 (
        .ADDRESS(spram_addr[13:0]),
        .DATAIN(spram_wdata),
        .MASKWREN(4'b1111),
        .WREN(spram_we & ~spram_addr[14]),
        .CHIPSELECT(~spram_addr[14]),
        .CLOCK(clk),
        .STANDBY(1'b0),
        .SLEEP(1'b0),
        .POWEROFF(1'b1),  // active low — 1 = power ON
        .DATAOUT(spram0_rdata)
    );

    SB_SPRAM256KA spram1 (
        .ADDRESS(spram_addr[13:0]),
        .DATAIN(spram_wdata),
        .MASKWREN(4'b1111),
        .WREN(spram_we & spram_addr[14]),
        .CHIPSELECT(spram_addr[14]),
        .CLOCK(clk),
        .STANDBY(1'b0),
        .SLEEP(1'b0),
        .POWEROFF(1'b1),
        .DATAOUT(spram1_rdata)
    );

    wire [15:0] spram_rdata = spram_addr[14] ? spram1_rdata : spram0_rdata;

    // =========================================================================
    // Recording state machine
    // =========================================================================
    reg [14:0] rec_ptr = 0;
    reg recording = 0;

    always @(posedge clk) begin
        if (rec_enable && !recording) begin
            recording <= 1;
            rec_ptr <= 0;
        end
        if (recording && new_sample) begin
            if (rec_ptr >= rec_length[14:0] - 1) begin
                recording <= 0;
                rec_ptr <= 0;
            end else begin
                rec_ptr <= rec_ptr + 1;
            end
        end
        if (!rec_enable)
            recording <= 0;
    end

    // =========================================================================
    // Grain playback state machine
    // =========================================================================
    //
    // Runs between sample periods. Each grain is processed sequentially:
    //   - Calculate read address from grain position + phase
    //   - Read SPRAM (1 cycle)
    //   - Multiply by envelope
    //   - Accumulate into mixer
    //
    // Grain phase: 24-bit (8.16 fixed point) — wraps at grain_size
    //
    reg [23:0] grain_phase [0:7];  // current playback position within grain
    initial begin
        for (i = 0; i < 8; i = i + 1)
            grain_phase[i] = 0;
    end

    // Grain processing pipeline
    localparam GS_IDLE   = 0;
    localparam GS_ADDR   = 1;
    localparam GS_READ   = 2;
    localparam GS_MULT   = 3;
    localparam GS_ACCUM  = 4;
    localparam GS_NEXT   = 5;
    localparam GS_DONE   = 6;

    reg [2:0] gs_state = GS_IDLE;
    reg [2:0] gs_grain = 0;       // current grain being processed
    reg signed [15:0] gs_sample = 0;
    reg signed [19:0] mix_accum = 0;
    reg signed [15:0] mix_out = 0;
    reg [7:0] gs_envelope = 0;

    // Envelope calculation — triangular
    // For grain at phase P with size S:
    //   first half (P < S/2): envelope = 2*P*255/S
    //   second half:          envelope = 2*(S-P)*255/S
    // Simplified: use the top bits of a comparison
    reg [14:0] gs_phase_int;  // integer part of grain phase
    reg [14:0] gs_half_size;

    always @(posedge clk) begin
        case (gs_state)
            GS_IDLE: begin
                if (new_sample && play_enable) begin
                    gs_grain <= 0;
                    mix_accum <= 0;
                    gs_state <= GS_ADDR;
                end
            end

            GS_ADDR: begin
                // Calculate SPRAM read address
                gs_phase_int <= grain_phase[gs_grain][23:9]; // integer part (15 bits)
                gs_half_size <= {1'b0, grain_size[gs_grain][14:1]}; // size / 2
                if (grain_active[gs_grain]) begin
                    // Address = grain_pos + integer(grain_phase) mod buffer
                    spram_addr <= grain_pos[gs_grain] + grain_phase[gs_grain][23:9];
                    spram_we <= 0;
                    gs_state <= GS_READ;
                end else begin
                    gs_state <= GS_NEXT;
                end
            end

            GS_READ: begin
                // SPRAM data available on next cycle
                gs_state <= GS_MULT;
            end

            GS_MULT: begin
                // Read the sample
                gs_sample <= $signed(spram_rdata);

                // Triangular envelope
                if (gs_phase_int < gs_half_size) begin
                    // Rising: scale 0..255 over first half
                    // Approximate: use top 8 bits of (phase / half_size)
                    gs_envelope <= (gs_half_size != 0) ?
                        (gs_phase_int[14:7] < grain_level[gs_grain] ?
                         gs_phase_int[14:7] : grain_level[gs_grain]) :
                        grain_level[gs_grain];
                end else begin
                    // Falling
                    gs_envelope <= ((grain_size[gs_grain] - gs_phase_int) > {7'd0, grain_level[gs_grain]}) ?
                        grain_level[gs_grain] :
                        grain_size[gs_grain][7:0] - gs_phase_int[7:0];
                end

                gs_state <= GS_ACCUM;
            end

            GS_ACCUM: begin
                // Multiply sample by envelope and accumulate
                // sample * envelope / 256 (envelope is 0-255)
                mix_accum <= mix_accum + (($signed(gs_sample) * $signed({1'b0, gs_envelope})) >>> 8);

                // Advance grain phase
                grain_phase[gs_grain] <= grain_phase[gs_grain] +
                    {8'd0, grain_pitch[gs_grain]};

                // Wrap phase if it exceeds grain size
                if (grain_phase[gs_grain][23:9] >= grain_size[gs_grain])
                    grain_phase[gs_grain] <= 0;

                gs_state <= GS_NEXT;
            end

            GS_NEXT: begin
                if (gs_grain == 7) begin
                    gs_state <= GS_DONE;
                end else begin
                    gs_grain <= gs_grain + 1;
                    gs_state <= GS_ADDR;
                end
            end

            GS_DONE: begin
                // Saturate mix to 16-bit
                if (mix_accum > 20'sd32767)
                    mix_out <= 16'sd32767;
                else if (mix_accum < -20'sd32768)
                    mix_out <= -16'sd32768;
                else
                    mix_out <= mix_accum[15:0];
                gs_state <= GS_IDLE;
            end

            default: gs_state <= GS_IDLE;
        endcase

        // Recording takes priority over playback for SPRAM access
        if (recording && new_sample) begin
            spram_addr <= rec_ptr;
            spram_wdata <= adc_sample;
            spram_we <= 1;
        end
    end

    // =========================================================================
    // DAC output — I2S shift register
    // =========================================================================
    wire signed [15:0] dac_sample = play_enable ? mix_out : adc_sample; // passthrough when not playing
    reg [15:0] dac_shift = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 0 || bit_cnt == 16)
                dac_shift <= dac_sample;
            else
                dac_shift <= {dac_shift[14:0], 1'b0};
        end
    end

    assign dac_data = (bit_cnt == 0 || bit_cnt == 16) ? 1'b0 : dac_shift[15];

    // =========================================================================
    // LED indicators
    // =========================================================================
    reg [23:0] hb = 0;
    always @(posedge clk) hb <= hb + 1;

    assign led_g = ~hb[23];         // heartbeat
    assign led_r = ~recording;      // red when recording (active low)
    assign led_b = ~play_enable;    // blue when playing (active low)

endmodule
