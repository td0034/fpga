// =============================================================================
// I2S Passthrough — ULX3S + PCM1808 ADC + PCM5102A DAC
// =============================================================================
//
// Line-level audio input on the PCM1808 is captured and sent straight out
// through the PCM5102A DAC with minimal latency (one sample frame).
//
// Clock plan (25 MHz system clock):
//   SCK  = 25 MHz / 2 = 12.5 MHz  (256 × 48,828 Hz — PCM1808 system clock)
//   BCLK = 25 MHz / 16 = 1.5625 MHz  (toggle every 8 clocks)
//   LRCK = BCLK / 32 = 48,828 Hz  (sample rate)
//
// The FPGA is I2S master — it generates BCK, LRC, and SCK for the ADC,
// and BCK, LCK for the DAC. Both chips are clocked from the same timing.
//
// PCM1808 ADC wiring (GP0–GP3, GP7–GP9 on J1 header):
//   GP0 (B11) → SCK  = 12.5 MHz system clock output
//   GP1 (A10) → LRC  = I2S word select output
//   GP2 (A9)  ← OUT  = I2S data input (24-bit, we use top 16)
//   GP3 (B9)  → BCK  = I2S bit clock output
//   GP7 (A6)  → MDO  = LOW (slave mode, MD1)
//   GP8 (A4)  → MDI  = LOW (slave mode, MD0)
//   GP9 (A2)  → FMY  = LOW (I2S format)
//
// PCM5102A DAC wiring (GN0–GN7 on J1 header):
//   GN0 (C11) → FLT  = LOW   (normal latency filter)
//   GN1 (A11) → DMP  = LOW   (de-emphasis off)
//   GN2 (B10) → SCL  = LOW   (internal system clock)
//   GN3 (C10) → BCK  = BCLK  (I2S bit clock)
//   GN4 (A8)  → DIN  = DATA  (I2S serial data out)
//   GN5 (B8)  → LCK  = LRCK  (I2S word select)
//   GN6 (C7)  → FMT  = LOW   (I2S format)
//   GN7 (B6)  → XMT  = HIGH  (unmute)
//
// Status LEDs:
//   LED[0] = heartbeat (FPGA alive)
//   LED[1] = audio active (non-silence detected on ADC input)
//
// =============================================================================

module top (
    input  wire       clk,          // 25 MHz oscillator

    // PCM1808 ADC on GP0–GP3, GP7–GP9
    output wire       adc_sck,      // GP0 — 12.5 MHz system clock
    output wire       adc_lrc,      // GP1 — I2S word select
    input  wire       adc_out,      // GP2 — I2S data from ADC
    output wire       adc_bck,      // GP3 — I2S bit clock
    output wire       adc_mdo,      // GP7 — mode 1 (slave)
    output wire       adc_mdi,      // GP8 — mode 0 (slave)
    output wire       adc_fmy,      // GP9 — format (I2S)

    // PCM5102A DAC on GN0–GN7
    output wire       dac_flt,      // GN0 — filter select
    output wire       dac_dmp,      // GN1 — de-emphasis
    output wire       dac_scl,      // GN2 — system clock
    output wire       dac_bck,      // GN3 — I2S bit clock
    output wire       dac_din,      // GN4 — I2S serial data
    output wire       dac_lck,      // GN5 — I2S word select
    output wire       dac_fmt,      // GN6 — format select
    output wire       dac_xmt,      // GN7 — mute control

    output wire [7:0] led
);

    // =========================================================================
    // Static control pins
    // =========================================================================

    // PCM1808 ADC
    assign adc_mdo = 1'b0;   // slave mode (MD1=0)
    assign adc_mdi = 1'b0;   // slave mode (MD0=0)
    assign adc_fmy = 1'b0;   // I2S format

    // PCM5102A DAC
    assign dac_flt = 1'b0;   // normal latency filter
    assign dac_dmp = 1'b0;   // de-emphasis off
    assign dac_scl = 1'b0;   // internal system clock
    assign dac_fmt = 1'b0;   // I2S format
    assign dac_xmt = 1'b1;   // unmute

    // =========================================================================
    // SCK — 12.5 MHz system clock for PCM1808 (25 MHz / 2)
    // =========================================================================
    // 12.5 MHz = 256 × 48,828 Hz — within the PCM1808's 256fs requirement.
    //
    reg sck_reg = 0;
    always @(posedge clk)
        sck_reg <= ~sck_reg;

    assign adc_sck = sck_reg;

    // =========================================================================
    // BCLK — 1.5625 MHz (25 MHz / 16, toggle every 8 clocks)
    // =========================================================================
    localparam BCLK_DIV = 8;

    reg [2:0] clk_div = 0;
    reg       bclk_reg = 0;
    wire      bclk_tick = (clk_div == BCLK_DIV - 1);

    always @(posedge clk) begin
        if (bclk_tick) begin
            clk_div <= 0;
            bclk_reg <= ~bclk_reg;
        end else begin
            clk_div <= clk_div + 1;
        end
    end

    // BCLK edge detection
    reg bclk_prev = 0;
    always @(posedge clk) bclk_prev <= bclk_reg;
    wire bclk_fall = bclk_prev & ~bclk_reg;
    wire bclk_rise = ~bclk_prev & bclk_reg;

    // Shared BCLK to both ADC and DAC
    assign adc_bck = bclk_reg;
    assign dac_bck = bclk_reg;

    // =========================================================================
    // LRCK — word select, shared between ADC and DAC
    // =========================================================================
    reg [4:0] bit_cnt = 0;
    reg       lrck_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 31)
                bit_cnt <= 0;
            else
                bit_cnt <= bit_cnt + 1;
            if (bit_cnt == 31)
                lrck_reg <= 0;
            else if (bit_cnt == 15)
                lrck_reg <= 1;
        end
    end

    assign adc_lrc = lrck_reg;
    assign dac_lck = lrck_reg;

    // =========================================================================
    // ADC capture — read 24-bit I2S data from PCM1808, keep top 16 bits
    // =========================================================================
    //
    // PCM1808 outputs 24-bit data MSB first. We sample on BCLK rising edge
    // (data transitions on falling edge). We capture bits 1–16 of each
    // channel (bit 0 is the I2S delay bit).
    //
    reg [23:0] adc_shift_l = 0;
    reg [23:0] adc_shift_r = 0;
    reg signed [15:0] cap_left  = 0;
    reg signed [15:0] cap_right = 0;

    always @(posedge clk) begin
        if (bclk_rise) begin
            if (bit_cnt >= 1 && bit_cnt <= 15) begin
                // Left channel: bits 1–15 (we capture into a shift reg)
                adc_shift_l <= {adc_shift_l[22:0], adc_out};
            end else if (bit_cnt == 0) begin
                // Bit 0 of left channel = I2S delay bit, start fresh
                adc_shift_l <= {23'b0, adc_out};
            end

            if (bit_cnt >= 17 && bit_cnt <= 31) begin
                // Right channel: bits 17–31
                adc_shift_r <= {adc_shift_r[22:0], adc_out};
            end else if (bit_cnt == 16) begin
                // Bit 16 = I2S delay bit for right, latch left result
                adc_shift_r <= {23'b0, adc_out};
                // Latch completed left channel (top 16 of 24 bits captured)
                cap_left <= adc_shift_l[15:0];
            end
        end

        // Latch right channel at end of frame
        if (bclk_fall && bit_cnt == 31) begin
            cap_right <= adc_shift_r[15:0];
        end
    end

    // =========================================================================
    // DAC output — shift out 16-bit samples to PCM5102A
    // =========================================================================
    reg [15:0] dac_shift = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 0)
                dac_shift <= cap_left;
            else if (bit_cnt == 16)
                dac_shift <= cap_right;
            else
                dac_shift <= {dac_shift[14:0], 1'b0};
        end
    end

    assign dac_din = (bit_cnt == 0 || bit_cnt == 16) ? 1'b0 : dac_shift[15];

    // =========================================================================
    // Status LEDs
    // =========================================================================
    reg [24:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1;

    // Audio activity: detect non-silence (any sample with magnitude > threshold)
    reg audio_active = 0;
    reg [19:0] activity_timer = 0;

    always @(posedge clk) begin
        if (bclk_fall && bit_cnt == 0) begin
            // Check if left sample has significant amplitude
            if (cap_left > 16'sd256 || cap_left < -16'sd256) begin
                audio_active <= 1;
                activity_timer <= {20{1'b1}};  // ~42 ms timeout at 25 MHz
            end else if (activity_timer != 0) begin
                activity_timer <= activity_timer - 1;
            end else begin
                audio_active <= 0;
            end
        end
    end

    assign led = {6'b0, audio_active, heartbeat[24]};

endmodule
